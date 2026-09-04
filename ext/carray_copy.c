/* ---------------------------------------------------------------------------

  Duplication and template allocation: `copy` (always-copy entity),
  `to_ca` (entity self / view materialise sentinel), and `template`
  (same-shape blank result, optionally retyped or block-initialised).
  Sibling of carray_generate.c (factory builders) and carray_access.c
  (`store_all` broadcast path used by the 0-arity template block).

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"   /* CA_FACE_LIFT_IF_FACE */
#include "carray_internal.h"   /* ca_gc_hold_push / ca_gc_hold_pop_to */
#include <stdarg.h>

/* ------------------------------------------------------------------- */

/* Allocates a fresh entity (or scalar) of the same shape, data_type,
 * and bytes as `ca`, copies the element payload, and reproduces the
 * mask state.  Always copies even when `ca` is an entity; for view
 * sources the data path goes through `ca_copy_data`, otherwise a flat
 * memcpy of `ca_length(ca)` bytes.
 *
 * Backs `CArray#copy` and is also reachable as a C-level utility from
 * other ext files that need an owned snapshot. */
CArray *
ca_copy (void *ap)
{
  CArray *ca = (CArray *) ap;
  CArray *co;

  if ( ca_is_scalar(ca) ) {
    co = (CArray *) cscalar_new(ca->data_type, ca->bytes, 0);
  }
  else {
    co = carray_new(ca->data_type, ca->ndim, ca->dim, ca->bytes, 0);
  }

  if ( ca_is_attached(ca) ) {
    memcpy(co->ptr, ca->ptr, ca_length(ca));
  }
  else {
    ca_copy_data(ca, co->ptr);
  }

  ca_update_mask(ca);
  if ( ca->mask ) {
    ca_copy_mask(co, ca);
  }

  return co;
}

/* Ruby entry for `CArray#copy`.  Wraps `ca_copy` and, when `self` is a
 * Face (e.g. CARecord), lifts the wrapped result so the derived class
 * identity is preserved on the copy. */
VALUE
rb_ca_copy (VALUE self)
{
  volatile VALUE obj;
  CArray *ca, *co;
  int guard = -1;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  co = ca_copy(ca);
  /* The copy holds VALUEs that so far exist only in co->ptr, and
     ca_wrap_struct allocates.  Keep them reachable until the wrapper
     that owns them exists. */
  if ( ca_is_object_type(co) ) {
    guard = ca_gc_hold_push(co->ptr, co->elements);
  }
  obj = ca_wrap_struct(co);
  ca_gc_hold_pop_to(guard);
  CA_FACE_LIFT_IF_FACE(obj, self, ca);
  return obj;
}

/* Reads the `writable:` keyword every `to_ca` implementation accepts.
 * Returns non-zero when the caller demands a result whose writes reach
 * the source, so a `to_ca` that can only hand back a copy must refuse
 * instead of returning one silently.
 *
 * Exported for `to_ca` implementations written in C, in this tree and
 * in ext gems; the Ruby-side equivalent is a `writable: false` keyword
 * on the method definition. */
int
ca_to_ca_writable_arg (int argc, VALUE *argv)
{
  VALUE opts;
  ID kw_ids[1];
  VALUE kw_vals[1];

  rb_scan_args(argc, argv, "0:", &opts);
  if ( NIL_P(opts) ) {
    return 0;
  }
  kw_ids[0] = rb_intern("writable");
  rb_get_kwargs(opts, kw_ids, 0, 1, kw_vals);
  return ( kw_vals[0] == Qundef ) ? 0 : RTEST(kw_vals[0]);
}

/* Refusal an implementation raises when `writable: true` was asked of a
 * `to_ca` that only ever produces a detached copy. */
void
ca_to_ca_refuse_writable (VALUE self)
{
  volatile VALUE inspect = rb_inspect(CLASS_OF(self));
  rb_raise(rb_eRuntimeError,
           "%s#to_ca can only return a copy; it can't satisfy `writable: true'",
           StringValuePtr(inspect));
}

/* Ruby entry for `CArray#to_ca`.  Returns `self` unchanged — for any
 * CArray (entity or data view) the receiver is already a CArray.
 *
 * `writable: true` states that the caller is going to write through the
 * result into the source.  `self` shares its storage by construction, so
 * the only way to fail here is a read-only receiver.
 *
 * Other classes override `to_ca` for their own semantics: a Ruby
 * `Array` builds a new CArray, and lazy views (CAMonOp / CABinOp /
 * CAMonCmp / CABinCmp / CALazyMarker) force evaluation into a fresh
 * entity; both are copies and so refuse `writable: true`.  When an
 * independent owned copy is required, callers use `copy`. */
VALUE
rb_ca_to_ca (int argc, VALUE *argv, VALUE self)
{
  if ( ca_to_ca_writable_arg(argc, argv) ) {
    CArray *ca;
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    if ( ca_is_readonly(ca) ) {
      rb_raise(rb_eRuntimeError, "can't modify read-only carray");
    }
  }
  return self;
}

/* ------------------------------------------------------------------- */

/* Allocates a fresh entity (or scalar) with the same shape,
 * data_type, and bytes as `ca`, without a mask and with the payload
 * left uninitialised.  Used by ext code that is about to overwrite
 * every element (e.g. kernel outputs, casts, element-wise results). */
CArray *
ca_template (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_is_scalar(ca) ) {
    return (CArray*) cscalar_new(ca->data_type, ca->bytes, NULL);
  }
  else {
    return carray_new(ca->data_type, ca->ndim, ca->dim, ca->bytes, NULL);
  }
}

/* Variant of `ca_template` that zero-fills the payload (entity path
 * uses `carray_new_safe`).  Used when the caller may leave some cells
 * untouched and needs a defined initial value. */
CArray *
ca_template_safe (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_is_scalar(ca) ) {
    return (CArray*) cscalar_new(ca->data_type, ca->bytes, NULL);
  }
  else {
    return carray_new_safe(ca->data_type, ca->ndim, ca->dim, ca->bytes, NULL);
  }
}

/* `ca_template_safe` with an explicit target `data_type` / `bytes`
 * (i.e. shape is taken from `ca` but the element type is overridden).
 * The `bytes` argument is required for fixlen, ignored for numeric
 * data types. */
CArray *
ca_template_safe2 (void *ap, int8_t data_type, ca_size_t bytes)
{
  CArray *ca = (CArray *) ap;
  CA_CHECK_DATA_TYPE(data_type);
  if ( ca_is_scalar(ca) ) {
    return (CArray*) cscalar_new(data_type, bytes, NULL);
  }
  else {
    return carray_new_safe(data_type, ca->ndim, ca->dim, bytes, NULL);
  }
}

/* Ruby entry for `CArray#template`.  Allocates a same-shape blank
 * result, retypes it when `data_type` is given, and optionally runs a
 * block initialiser:
 *   - block arity == 0: evaluate once, broadcast via `rb_ca_store_all`
 *     (scalar-fill fast path, the dominant idiom)
 *   - block arity != 0: per-cell walk yielding the multi-dimensional
 *     subscript as individual integer arguments
 * The arity dispatch matches `CArray.new` (ca_obj_array.c) so the two
 * factories behave the same for block-driven initialisation. */
static VALUE
rb_ca_template_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE ropt = rb_pop_options(&argc, &argv);
  volatile VALUE obj, rtype, rbytes = Qnil;
  CArray *ca, *co;
  int8_t data_type;
  ca_size_t bytes;

  rb_scan_args(argc, argv, "01", (VALUE *) &rtype);
  rb_scan_options(ropt, "bytes", &rbytes);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( NIL_P(rtype) ) {
    co  = ca_template_safe(ca);
    obj = ca_wrap_struct(co);
  }
  else {
    rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
    co  = ca_template_safe2(ca, data_type, bytes);
    obj = ca_wrap_struct(co);
  }

  if ( rb_block_given_p() ) {
    if ( rb_proc_arity(rb_block_proc()) == 0 ) {
      volatile VALUE rval = rb_yield_values2(0, NULL);
      if ( rval != self ) {
        rb_ca_store_all(obj, rval);
      }
    }
    else {
      CArray *co;
      TypedData_Get_Struct(obj, CArray, &carray_data_type, co);
      if ( co->ndim > 0 ) {
        ca_size_t idx[CA_RANK_MAX];
        volatile VALUE ridx = rb_ary_new2(co->ndim);
        ca_attach(co);
        rb_ca_index_walk(obj, co, 0, idx, ridx, CA_LOOP_STORE);
        ca_sync(co);
        ca_detach(co);
      }
      else {
        volatile VALUE rval = rb_yield_values2(0, NULL);
        rb_ca_store_addr(obj, 0, rval);
      }
    }
  }

  /* Preserve the Face identity only for a same-type template (no explicit
   * retype).  A retype (template(:boolean)) is a different-typed buffer and
   * must not be re-wrapped as the Face.  A same-type template of a Face with
   * a valid blank form (CARecord carries its data_class through the struct
   * tail; identity Faces alias same-type storage) is lifted so the class is
   * preserved.  A Face with no valid blank form (CAConstString's content-
   * defined offset+buffer) overrides `template` in Ruby to return a plain
   * array instead of a broken same-class shell. */
  if ( NIL_P(rtype) ) {
    CA_FACE_LIFT_IF_FACE(obj, self, ca);
  }

  return obj;
}

VALUE
rb_ca_template (VALUE self)
{
  return rb_ca_template_method(0, NULL, self);
}

VALUE
rb_ca_template_with_type (VALUE self, VALUE rtype, VALUE rbytes)
{
  VALUE ropt = rb_hash_new();
  VALUE args[2] = { rtype, ropt };
  rb_set_options(ropt, "bytes", rbytes);
  return rb_ca_template_method(2, args, self);
}

/* Picks the largest-shape CArray among `n` variadic CArray arguments
 * and returns `template(largest)`.  Used by `carray_call_cfunc.c` to
 * size the output of vectorised scalar C-function calls, where the
 * inputs may be a mix of scalars and arrays. */
VALUE
rb_ca_template_n (int n, ...)
{
  volatile VALUE varg, obj;
  CArray *ca;
  ca_size_t elements = -1;
  va_list vargs;
  int i;

  va_start(vargs, n);
  for (i=0; i<n; i++) {
    varg = va_arg(vargs, VALUE);
    if ( ! rb_obj_is_carray(varg) ) {
      rb_raise(rb_eRuntimeError, "[BUG] not-carray object given to rb_ca_template_n");
    }
    TypedData_Get_Struct(varg, CArray, &carray_data_type, ca);
    if ( i == 0 ) {
      obj = varg;
      elements = ca->elements;
    }
    else {
      if ( rb_obj_is_cscalar(varg) ) {
        continue;
      }
      if ( rb_obj_is_cscalar(obj) ) {
        obj = varg;
        elements = ca->elements;
      }
      else if ( ca->elements != elements ) {
        rb_raise(rb_eRuntimeError, "size mismatch");
      }
    }
  }
  va_end(vargs);

  return rb_ca_template(obj);
}

/* ------------------------------------------------------------------- */
/* [MOVED] sub-region copy `crop(offset, dst)` / `paste(offset, src)`
 *         -> lib/extras/crop_paste.rb (Ruby wrappers over CAWindow,
 *            opt-in via `require "extras/crop_paste"`, not autoloaded).
 *
 * The names `clip` / `clip!` now mean value clamp (clamp to a min/max
 * range) and live in ext/carray_generate.c.  The old `clip` argument
 * order was reversed in the sub-region API, so the moved entry is
 * renamed to `crop`; `paste` keeps its name. */

/* ------------------------------------------------------------------- */

void
Init_carray_copy (void)
{
  rb_define_method(rb_cCArray, "to_ca", rb_ca_to_ca, -1);
  rb_define_method(rb_cCArray, "copy", rb_ca_copy, 0);
  rb_define_method(rb_cCArray, "template", rb_ca_template_method, -1);
}
