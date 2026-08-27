/* ---------------------------------------------------------------------------

  Predicates and equality/hash for CArray:
    - internal check_* / has_same_* helpers used across ext/ sources
    - Ruby surface: valid_index? / valid_addr? / same_shape? / == /
      eql? / hash / freeze (docs in yard-stubs/carray_test.rb)
    - per-type element-equality table `ca_eql[CA_NTYPE]`
    - `ca_compare_common` shared body for `==` and `eql?`

---------------------------------------------------------------------------- */

#include "carray.h"

static ID id_equal;
static ID id_eql;

/* Internal checking routines: raise on structural mismatch.  Used
   throughout ext/ sources at API boundaries; not exposed to Ruby. */

void
ca_check_type (void *ap, int8_t data_type)
{
  CArray *ca = (CArray *) ap;
  if ( ca->data_type != data_type ) {
    rb_raise(rb_eCADataTypeError, "data_type mismatch");
  }
}

void
ca_check_ndim (void *ap, int ndim)
{
  CArray *ca = (CArray *) ap;
  if ( ! ca_is_scalar(ca) ) {
    if ( ca->ndim != ndim ) {
      rb_raise(rb_eRuntimeError, "ndim mismatch");
    }
  }
}

void
ca_check_shape (void *ap, int ndim, ca_size_t *dim)
{
  CArray *ca = (CArray *) ap;
  int i;
  if ( ! ca_is_scalar(ca) ) {
    if ( ca->ndim != ndim ) {
      rb_raise(rb_eRuntimeError, "shape mismatch");
    }
    for (i=0; i<ndim; i++) {
      if ( ca->dim[i] != dim[i] ) {
        rb_raise(rb_eRuntimeError, "shape mismatch");
      }
    }
  }
}

void
ca_check_same_data_type (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( ca1->data_type != ca2->data_type ) {
    rb_raise(rb_eCADataTypeError, "data_type mismatch");
  }
}

void
ca_check_same_ndim (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( ca1->ndim != ca2->ndim ) {
    rb_raise(rb_eRuntimeError, "ndim mismatch");
  }
}

void
ca_check_same_elements (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( ca1->elements != ca2->elements ) {
    rb_raise(rb_eRuntimeError, "elements mismatch");
  }
}

void
ca_check_same_shape (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  int i;
  if ( ( ! ca_is_scalar(ca1) ) && ( ! ca_is_scalar(ca2) ) ) {
    if ( ca1->ndim != ca2->ndim ) {
      rb_raise(rb_eRuntimeError, "shape mismatch");
    }
    for (i=0; i<ca1->ndim; i++) {
      if ( ca1->dim[i] != ca2->dim[i] ) {
        rb_raise(rb_eRuntimeError, "shape mismatch");
      }
    }
  }
}

void
ca_check_index (void *ap, ca_size_t *idx)
{
  CArray *ca = (CArray *) ap;
  int i;
  for (i=0; i<ca->ndim; i++) {
    if ( idx[i] < 0 || idx[i] >= ca->dim[i] ) {
      rb_raise(rb_eRuntimeError, "invalid index");
    }
  }
}

void
rb_check_carray_object (VALUE arg)
{
  if ( ! rb_obj_is_carray(arg) ) {
    rb_raise(rb_eRuntimeError, "CArray required");
  }
}

/* Internal predicate routines: return 0/1, do not raise. */

int
ca_has_same_shape (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  int i;
  if ( ca_is_scalar(ca1) || ca_is_scalar(ca2) ) {
    return 1;
  }
  else if ( ca1->ndim != ca2->ndim ) {
    return 0;
  }
  else {
    for (i=0; i<ca1->ndim; i++) {
      if ( ca1->dim[i] != ca2->dim[i] ) {
        return 0;
      }
    }
    return 1;
  }
}

int
ca_is_valid_index (void *ap, ca_size_t *idx)
{
  CArray *ca = (CArray *) ap;
  int8_t i;
  for (i=0; i<ca->ndim; i++) {
    if ( idx[i] < 0 || idx[i] >= ca->dim[i] ) {
      return 0;
    }
  }
  return 1;
}

/* rb_ca_is_type(arg, type) — returns 1 if arg is a CArray whose
   data_type equals `type`, else raises if not a CArray. */
int
rb_ca_is_type (VALUE arg, int type)
{
  CArray *ca;
  if ( ! rb_obj_is_carray(arg) ) {
    rb_raise(rb_eRuntimeError, "CArray required");
  }
  TypedData_Get_Struct(arg, CArray, &carray_data_type, ca);
  return ca->data_type == type;
}

/* [MOVED] data_class identity predicates
   (ca_check_data_class / rb_obj_is_data_class / rb_ca_s_is_data_class)
   live in ca_obj_record.c; signatures stay in carray.h for cross-file
   extern use. */

/* CArray#valid_index?(*idx) — 1 if the index tuple is in range, else 0.
 * The number of indices must equal ndim (raises otherwise). */
static VALUE
rb_ca_is_valid_index (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  ca_size_t idx;
  int i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( argc != ca->ndim ) {
    rb_raise(rb_eArgError,
             "invalid # of arguments (%i for %i)", argc, ca->ndim);
  }
  for (i=0; i<ca->ndim; i++) {
    idx = NUM2SIZE(argv[i]);
    if ( idx < 0 || idx >= ca->dim[i] ) {
      return Qfalse;
    }
  }

  return Qtrue;
}

/* CArray#valid_addr?(addr) — 1 if addr is in range 0...elements, else 0. */
static VALUE
rb_ca_is_valid_addr (VALUE self, VALUE raddr)
{
  CArray *ca;
  ca_size_t addr;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  addr = NUM2SIZE(raddr);
  if ( addr < 0 || addr >= ca->elements ) {
    return Qfalse;
  }
  else {
    return Qtrue;
  }
}

/* CArray#same_shape?(other) — 1 if self and other share ndim and dim[].
 * Scalars compare true against any array (see ca_has_same_shape). */
static VALUE
rb_ca_has_same_shape (VALUE self, VALUE other)
{
  CArray *ca, *cb;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  cb = ca_wrap_readonly(other, ca->data_type);
  return ca_has_same_shape(ca, cb) ? Qtrue : Qfalse;
}

/* ----------------------------------------------------------------------- */

typedef int (*ca_eql_func)(const char *, const char *, ca_size_t);

#define eql_type(type)         \
static int                      \
eql_## type (const char *a, const char *b, ca_size_t bytes) \
{                               \
  return ( *(const type*)a == *(const type*)b ); \
}

static int
eql_VALUE (const char *a, const char *b, ca_size_t bytes)
{
  return RTEST(rb_funcall(*(const VALUE*)a, id_equal, 1, *(const VALUE*)b)) ? 1 : 0;
}

static int
eql_data (const char *a, const char *b, ca_size_t bytes)
{
  return ( memcmp(a, b, (size_t)bytes) ) ? 0 : 1;
}

eql_type(boolean8_t)
eql_type(int8_t)
eql_type(uint8_t)
eql_type(int16_t)
eql_type(uint16_t)
eql_type(int32_t)
eql_type(uint32_t)
eql_type(int64_t)
eql_type(uint64_t)
eql_type(float32_t)
eql_type(float64_t)
eql_type(cmplx64_t)
eql_type(cmplx128_t)

/* Placeholder for CA_FLOAT128 / CA_CMPLX256 slots (ca_valid[12] =
   ca_valid[15] = 0, so never invoked). */
static int
eql_retired (const char *a, const char *b, ca_size_t bytes)
{
  return 0;
}

ca_eql_func
ca_eql[CA_NTYPE] = {
  eql_data,
  eql_boolean8_t,
  eql_int8_t,
  eql_uint8_t,
  eql_int16_t,
  eql_uint16_t,
  eql_int32_t,
  eql_uint32_t,
  eql_int64_t,
  eql_uint64_t,
  eql_float32_t,
  eql_float64_t,
  eql_retired, /* float128_t: ca_valid[12] = 0 */
  eql_cmplx64_t,
  eql_cmplx128_t,
  eql_retired, /* cmplx256_t: ca_valid[15] = 0 */
  eql_VALUE,
};

/* ca_compare_common(a, b, strict) — shared body of ca_equal (==) and
 * ca_eql_strict (eql?).  Returns 1 if arrays match under the selected
 * semantics, else 0.
 *
 * Common structure: metadata pre-check (scalar / data_type / bytes /
 * ndim / elements / dim), mask attach via ca_attach_n (recurses into
 * mask), unified loop over the four masked/unmasked combinations.
 *
 * The only difference is the per-element comparator:
 *   == : ca_eql[data_type] (type-specific, so float NaN != NaN)
 *   eql?: memcmp for numeric, rb_funcall(:eql?) for CA_OBJECT
 *
 * The unmasked-unmasked branch takes a bulk memcmp or per-cell
 * shortcut to amortise per-element function pointer dispatch. */
static int
ca_compare_common (void *ap, void *bp, int strict)
{
  CArray *ca = (CArray *) ap;
  CArray *cb = (CArray *) bp;
  int flag = 1;
  int masked_a, masked_b;
  boolean8_t *ma, *mb;
  ca_size_t i;
  ca_size_t bytes;
  char *pa;
  char *pb;
  ca_eql_func eql = NULL;        /* used only when !strict */
  int is_object;

  if ( ca_is_scalar(ca) ^ ca_is_scalar(cb) ) {
    return 0;
  }
  if ( ca->data_type != cb->data_type ) {
    return 0;
  }
  if ( ca->bytes != cb->bytes ) {
    return 0;
  }
  if ( ca->ndim != cb->ndim ) {
    return 0;
  }
  if ( ca->elements != cb->elements ) {
    return 0;
  }
  for (i=0; i<ca->ndim; i++) {
    if ( ca->dim[i] != cb->dim[i] ) {
      return 0;
    }
  }

  ca_attach_n(2, ca, cb);              /* recurses into ca->mask / cb->mask */

  masked_a = ca_is_any_masked(ca);
  masked_b = ca_is_any_masked(cb);
  bytes    = ca->bytes;
  pa       = ca->ptr;
  pb       = cb->ptr;
  is_object = ( ca->data_type == CA_OBJECT );

  if ( ! strict ) {
    eql = ca_eql[ca->data_type];
  }

  /* unmasked-unmasked fast path: one bulk memcmp for numeric, per-cell
     rb_funcall for CA_OBJECT. Avoids per-element function pointer dispatch
     and enables SIMD memcmp on the common case. For strict (eql?) numeric
     comparison is bitwise (= NaN.eql?(NaN) yields true since their bit
     patterns match), so memcmp gives the right semantics. For non-strict
     (==) of numeric data_types, type-equality is byte-equality EXCEPT for
     floats where -0.0 == +0.0 (different bit pattern, same value) and
     NaN != NaN (same bit pattern, unequal value) -- so we must keep the
     per-element comparator there.

     Integer / bool / fixlen data_types are byte-exact, so memcmp matches both
     semantics. data_type >= CA_FLOAT32 (= floats / complex / object) needs
     the comparator. */
  if ( ! masked_a && ! masked_b ) {
    if ( is_object ) {
      ID id = strict ? id_eql : id_equal;
      VALUE *va = (VALUE *) pa;
      VALUE *vb = (VALUE *) pb;
      for (i=0; i<ca->elements; i++) {
        volatile VALUE x = va[i];
        volatile VALUE y = vb[i];
        if ( ! RTEST(rb_funcall(x, id, 1, y)) ) {
          flag = 0;
          break;
        }
      }
    }
    else if ( strict
              || ca->data_type <= CA_UINT64
              || ca->data_type == CA_FIXLEN ) {
      /* bytewise comparable: single memcmp */
      flag = ( memcmp(pa, pb, (size_t)(ca->elements * bytes)) == 0 ) ? 1 : 0;
    }
    else {
      /* float / complex == : per-element comparator preserves NaN/-0.0 semantics */
      for (i=0; i<ca->elements; i++) {
        if ( ! eql(pa, pb, bytes) ) {
          flag = 0;
          break;
        }
        pa += bytes; pb += bytes;
      }
    }
  }
  else {
    /* masked path: unified loop. ma/mb NULL => that side has no any-masked
       cells. Loop invariants are simple enough that branch prediction
       absorbs the per-iteration NULL test. */
    ma = masked_a ? (boolean8_t *) ca->mask->ptr : NULL;
    mb = masked_b ? (boolean8_t *) cb->mask->ptr : NULL;
    for (i=0; i<ca->elements; i++) {
      boolean8_t am = ma ? ma[i] : 0;
      boolean8_t bm = mb ? mb[i] : 0;
      if ( am != bm ) {
        flag = 0;
        break;
      }
      if ( ! am ) {
        int eq;
        if ( is_object ) {
          volatile VALUE x = *(VALUE *) pa;
          volatile VALUE y = *(VALUE *) pb;
          ID id = strict ? id_eql : id_equal;
          eq = RTEST(rb_funcall(x, id, 1, y));
        }
        else if ( strict
                  || ca->data_type <= CA_UINT64
                  || ca->data_type == CA_FIXLEN ) {
          eq = ( memcmp(pa, pb, (size_t)bytes) == 0 );
        }
        else {
          eq = eql(pa, pb, bytes);
        }
        if ( ! eq ) {
          flag = 0;
          break;
        }
      }
      pa += bytes; pb += bytes;
    }
  }

  ca_detach_n(2, ca, cb);

  return flag;
}

int
ca_equal (void *ap, void *bp)
{
  return ca_compare_common(ap, bp, 0);
}

static int
ca_eql_strict (void *ap, void *bp)
{
  return ca_compare_common(ap, bp, 1);
}

/* CArray#==(other) — elementwise equality returning true / false.
 * data_class, data_type, shape, and mask state must all match; NaN
 * compares unequal per IEEE semantics.  Non-CArray other returns
 * false. */
static VALUE
rb_ca_equal (VALUE self, VALUE other)
{
  CArray *ca, *cb;

  if ( ! rb_obj_is_carray(other) )  {    /* check kind_of?(CArray) */
    return Qfalse;
  }

  if ( rb_ca_has_data_class(self) || rb_ca_has_data_class(other) ) {
    if ( rb_ca_has_data_class(self) ^ rb_ca_has_data_class(other) ) {
      return Qfalse;
    }
    else {
      VALUE dc1 = rb_ca_data_class(self);
      VALUE dc2 = rb_ca_data_class(other);
      if ( ! RTEST(rb_funcall(dc1, id_equal, 1, dc2)) ) {
        return Qfalse;
      }
    }
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  TypedData_Get_Struct(other, CArray, &carray_data_type, cb);

  return ( ca_equal(ca, cb) ) ? Qtrue : Qfalse;
}

/* CArray#eql?(other) — Hash-invariant equality (satisfies a.eql?(b) =>
 * a.hash == b.hash).  Same structural checks as ==, but element
 * comparison is bitwise (numeric) or Object#eql? (CA_OBJECT), so
 * NaN.eql?(NaN) holds. */
static VALUE
rb_ca_eql (VALUE self, VALUE other)
{
  CArray *ca, *cb;

  if ( ! rb_obj_is_carray(other) ) {
    return Qfalse;
  }

  if ( rb_ca_has_data_class(self) || rb_ca_has_data_class(other) ) {
    if ( rb_ca_has_data_class(self) ^ rb_ca_has_data_class(other) ) {
      return Qfalse;
    }
    else {
      VALUE dc1 = rb_ca_data_class(self);
      VALUE dc2 = rb_ca_data_class(other);
      if ( ! RTEST(rb_funcall(dc1, id_eql, 1, dc2)) ) {
        return Qfalse;
      }
    }
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  TypedData_Get_Struct(other, CArray, &carray_data_type, cb);

  return ( ca_eql_strict(ca, cb) ) ? Qtrue : Qfalse;
}

/* ca_hash(ca) — cheap Hash key for CArray.  Mixes metadata (data_type,
 * ndim, bytes, elements, scalar-ness, shape, mask presence) and, for
 * unmasked arrays only, samples the leading CA_HASH_SAMPLE_BYTES of
 * data.  Masked arrays skip the data sample entirely — otherwise
 * masked positions would have to be zeroed in the sample to preserve
 * the eql?→hash invariant, and masked CArrays are rare as Hash keys.
 * The collision rate cost buys no ca->mask->ptr access and no
 * xmalloc/memcpy per call. */

#define CA_HASH_SAMPLE_BYTES 64

static st_index_t
ca_hash (CArray *ca)
{
  st_index_t h;
  int scalar_flag = ca_is_scalar(ca) ? 1 : 0;
  int masked_flag;
  ca_size_t data_len = ca_length(ca);
  ca_size_t sample = (data_len < CA_HASH_SAMPLE_BYTES) ? data_len : CA_HASH_SAMPLE_BYTES;

  h  = rb_memhash(&ca->data_type, sizeof(ca->data_type));
  h ^= rb_memhash(&ca->ndim,      sizeof(ca->ndim));
  h ^= rb_memhash(&ca->bytes,     sizeof(ca->bytes));
  h ^= rb_memhash(&ca->elements,  sizeof(ca->elements));
  h ^= rb_memhash(&scalar_flag,   sizeof(scalar_flag));
  if ( ca->ndim > 0 ) {
    h ^= rb_memhash(ca->dim, sizeof(ca_size_t) * ca->ndim);
  }

  /* ca_is_any_masked() attaches/detaches the mask internally and returns
     only a boolean, so we never touch ca->mask->ptr here. */
  masked_flag = ca_is_any_masked(ca) ? 1 : 0;
  h ^= rb_memhash(&masked_flag, sizeof(masked_flag));

  if ( ! masked_flag && sample > 0 ) {
    ca_attach(ca);
    h ^= rb_memhash(ca->ptr, sample);
    ca_detach(ca);
  }

  return h;
}

/* CArray#hash — Hash key value; wraps ca_hash into a Ruby Integer. */
VALUE
rb_ca_hash (VALUE self)
{
  CArray *ca;
  st_index_t hash;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  hash = ca_hash(ca);
  return ST2FIX(hash);
}

/* ----------------------------------------------------------------------- */

/* Mutation guard.  Rejects both a Ruby-frozen object (FrozenError) and an
 * array carrying CA_FLAG_READ_ONLY, whether set on self or inherited from a
 * read-only parent (RuntimeError).  Data-value stores are additionally gated
 * in the xfer PUT path (ca_is_readonly), but mask writes, the `x[i] = UNDEF`
 * masking path, and the direct-ptr entity hot paths in elem_store/incr/decr
 * do not pass through xfer -- mutation entry points guard here so a
 * read-only-flag-only (non-frozen) array is fully protected. */
void
rb_ca_modify (VALUE self)
{
  CArray *ca;
  rb_check_frozen(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "can not modify read-only array");
  }
}

/* CArray#freeze — freeze self and set CA_FLAG_READ_ONLY so subsequent
 * mutations raise FrozenError. */
VALUE
rb_ca_freeze (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_set_flag(ca, CA_FLAG_READ_ONLY);
  return rb_obj_freeze(self);
}

/* CArray#set_read_only_flag — set CA_FLAG_READ_ONLY so subsequent mutations
 * raise (RuntimeError), WITHOUT rb_obj_freeze.  One-way at the public surface:
 * there is no public method to clear the flag, so the read-only guarantee
 * cannot be weakened from user code.  Unlike #freeze the Ruby object stays
 * non-frozen, so views / Faces derived from it remain non-frozen and can
 * memoise.  A caller wanting a mutable array uses `.copy` (a copy does not
 * inherit the flag). */
VALUE
rb_ca_set_read_only_flag (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_set_flag(ca, CA_FLAG_READ_ONLY);
  return self;
}

/* Ensure-body arg for rb_ca_without_read_only_flag. */
struct without_read_only_state {
  CArray *ca;
  int     was_readonly;
};

static VALUE
without_read_only_body (VALUE arg)
{
  return rb_yield(Qnil);
}

static VALUE
without_read_only_ensure (VALUE arg)
{
  struct without_read_only_state *s = (struct without_read_only_state *) arg;
  if (s->was_readonly) {
    ca_set_flag(s->ca, CA_FLAG_READ_ONLY);
  }
  return Qnil;
}

/* CArray#without_read_only_flag { ... } — PRIVATE, block-only escape reserved
 * for library / class authors who understand the READONLY invariants of the
 * subsystem they are working in.  The public "One-way" guarantee stated on
 * rb_ca_set_read_only_flag above is NOT weakened by this method: it is not
 * accessible from user code by design (private + explicit `send` requirement
 * is the signal, "I know internal invariants and I am not general user code").
 *
 * READONLY is set for many different reasons across the library, and the
 * semantic behind the flag varies by class:
 *
 *   (a) the entity backs external immutable memory (wrap_memory_view over
 *       an Arrow / Parquet / mmap MAP_PRIVATE buffer) — the values buffer
 *       is truly immutable, but CArray-side metadata (mask slot) is not;
 *       a bounded lift for mask attach is safe.
 *   (b) writes are permitted only through a formal, invariant-preserving
 *       API (a future variant, e.g. classes that keep derived caches in
 *       sync on write) — lifting READONLY would enable a low-level bypass
 *       of the invariant; DO NOT lift.
 *   (c) there is no writable target at all — CAObject today, the planned
 *       CASource similarly (elements are produced by a Ruby callback / an
 *       upstream source, not stored in a buffer) — lifting READONLY is
 *       meaningless because there is nothing to write to.
 *
 * A general lift primitive would be dangerous.  The author must know which
 * of (a) / (b) / (c) applies in their subsystem before reaching for this
 * primitive: it exists so a library / class author who does know can perform
 * a bounded escape without inventing a new flag.
 *
 * Canonical use: an interop bridge attaching a validity mask onto the
 * read-only CAWrap returned by wrap_memory_view — the values buffer is
 * immutable (producer's contract) but the mask slot is CArray-side metadata
 * the bridge owns.
 *
 * Mechanics: clears CA_FLAG_READ_ONLY on self for the duration of the block;
 * rb_ensure restores the flag on normal return AND on raise.  Frozen objects
 * still raise FrozenError.  Self only: does not walk parent chains, does not
 * touch ca->mask's flag.
 *
 * Caller discipline (not enforced by the primitive): confine usage to
 * entities (CArray / CScalar / CAWrap).  On a view of a read-only parent,
 * the yielded block's mask= walks create_mask into the parent chain and
 * mutates the parent's mask allocation as a side effect, breaking the
 * view-inherits-readonly guarantee for sibling views of the same parent. */
VALUE
rb_ca_without_read_only_flag (VALUE self)
{
  CArray *ca;
  struct without_read_only_state s;
  rb_check_frozen(self);
  rb_need_block();
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  s.ca = ca;
  s.was_readonly = ca_test_flag(ca, CA_FLAG_READ_ONLY);
  if (s.was_readonly) {
    ca_unset_flag(ca, CA_FLAG_READ_ONLY);
  }
  return rb_ensure(without_read_only_body, Qnil,
                   without_read_only_ensure, (VALUE) &s);
}

void
Init_carray_test (void)
{
  id_equal = rb_intern("==");
  id_eql   = rb_intern("eql?");

  rb_define_method(rb_cCArray, "valid_index?", rb_ca_is_valid_index, -1);
  rb_define_method(rb_cCArray, "valid_addr?",  rb_ca_is_valid_addr, 1);
  rb_define_method(rb_cCArray, "same_shape?",  rb_ca_has_same_shape, 1);
  rb_define_method(rb_cCArray, "freeze",  rb_ca_freeze, 0);
  rb_define_method(rb_cCArray, "set_read_only_flag", rb_ca_set_read_only_flag, 0);
  rb_define_private_method(rb_cCArray, "without_read_only_flag",
                           rb_ca_without_read_only_flag, 0);

  rb_define_method(rb_cCArray, "==",   rb_ca_equal, 1);
  rb_define_method(rb_cCArray, "eql?", rb_ca_eql,   1);
  rb_define_method(rb_cCArray, "hash", rb_ca_hash,  0);

  /* CArray.data_class?(klass) is bound in Init_ca_obj_record. */
}
