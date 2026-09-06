/* ---------------------------------------------------------------------------

  CARefer view: strided reinterpretation of the parent (`#refer`)
  plus the two shape-only rewrites `#reshape` and `#flatten`.
  Byte-level reinterpret (a different `data_type` / `bytes`) that
  CAStride cannot express is what makes CARefer distinct — plain
  same-shape reshape usually rewrites to CAStride directly through
  ca_reshape_try_strides.

  Sibling of ca_obj_stride.c (CARefer's operation table is
  ca_stride_func with `free_object` / `clone` / `create_mask`
  overridden for the byte-reinterpret mask paths).

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */
#include "ca_obj_face.h"  /* CA_FACE_LIFT_IF_FACE for CARecord parent */

extern ca_operation_function_t ca_stride_func;

VALUE rb_cCARefer;
VALUE rb_cCAReferMask;

/* CARefer ops: ca_stride_func + custom free + custom create_mask.
   Filled in at Init time so the function pointers are valid before
   carray_core's baseline registration is overridden. */
static ca_operation_function_t ca_refer_func;

static size_t
ca_refer_dsize (const void *ap)
{
  const CARefer *ca = (const CARefer *) ap;
  return sizeof(CARefer) + 2 * ca->ndim * sizeof(ca_size_t);
}

/* TypedData parent chain: carefer -> castride -> caview -> carray.
   Inheriting from castride_data_type lets CAStride accessor methods
   (#strides, #byte_offset) accept CARefer instances. */
const rb_data_type_t carefer_data_type = {
    .parent = &castride_data_type,
    .wrap_struct_name = "CARefer",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_refer_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t carefer_mask_data_type = {
    .parent = &carefer_data_type,
    .wrap_struct_name = "CAReferMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_refer_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */

int
ca_refer_setup (CARefer *ca, CArray *parent,
                int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                ca_size_t offset)
{
  ca_size_t elements, strides[CA_RANK_MAX];
  ca_size_t parent_bytes = parent->bytes;
  ca_size_t base_offset;
  ca_size_t s;
  int8_t i;

  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_RANK(ndim);
  CA_CHECK_DIM(ndim, dim);
  CA_CHECK_BYTES(data_type, bytes);

  if (ca_is_object_type(parent) && data_type != CA_OBJECT) {
    rb_raise(rb_eRuntimeError,
             "object array can't be referred by other data type");
  }
  if (parent->elements && bytes > parent_bytes * parent->elements) {
    rb_raise(rb_eRuntimeError, "bytes exceeds the data size of referent");
  }
  if (bytes < parent_bytes && parent_bytes % bytes != 0) {
    rb_raise(rb_eRuntimeError,
             "bytes of reference array must be a multiple of that of referent");
  }
  if (bytes > parent_bytes && bytes % parent_bytes != 0) {
    rb_raise(rb_eRuntimeError,
             "bytes of reference array must be a multiple of that of referent");
  }
  if (offset < 0) {
    rb_raise(rb_eRuntimeError, "negative offset is not permitted for CARefer");
  }
  elements = 1;
  for (i = 0; i < ndim; i++) elements *= dim[i];
  if ((bytes * elements + parent_bytes * offset) >
      (parent_bytes * parent->elements)) {
    rb_raise(rb_eRuntimeError,
             "data size of reference array must not exceed that of referent");
  }

  /* strides: row-major contiguous over the view's own dim, in view bytes */
  s = bytes;
  for (i = ndim - 1; i >= 0; i--) {
    strides[i] = s;
    s *= dim[i];
  }
  /* base_offset is in bytes: `offset` is in parent-element units. */
  base_offset = offset * parent_bytes;

  /* CAREFUL: initialise mask0 before ca_stride_setup — the setup
     may dispatch to ca_refer_func_create_mask, which writes to
     mask0.  Leaving it uninitialised risks freeing a garbage
     pointer during error unwind. */
  ca->mask0 = NULL;

  ca_stride_setup((CAStride *) ca, CA_OBJ_REFER, parent,
                  data_type, bytes, ndim, dim, strides, base_offset);

  if (ca_is_scalar(parent)) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }
  return 0;
}

CARefer *
ca_refer_new (CArray *parent,
              int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
              ca_size_t offset)
{
  CARefer *ca = (CARefer *) ca_array_alloc(CA_OBJ_REFER, ndim);
  ca_refer_setup(ca, parent, data_type, ndim, dim, bytes, offset);
  return ca;
}

static void
free_ca_refer (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  if (ca == NULL) return;
  /* Free the byte-reinterpret intermediate mask, if any. */
  ca_free(ca->mask0);
  /* The rest mirrors free_ca_stride. */
  ca_free(ca->mask);
  if (ca->_pool) {
    ca_array_free(ca);
  } else {
    xfree(ca->strides);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
ca_refer_func_clone (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  return ca_refer_new(ca->parent, ca->data_type, ca->ndim, ca->dim,
                      ca->bytes, ca->base_offset / ca->parent->bytes);
}

static void
ca_refer_func_create_mask (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  ca_size_t parent_bytes = ca->parent->bytes;
  ca_size_t parent_offset;

  ca_update_mask(ca->parent);
  if (! ca->parent->mask) {
    ca_create_mask(ca->parent);
  }

  parent_offset = ca->base_offset / parent_bytes;

  if (ca->bytes == parent_bytes) {
    /* Same-width reinterpret / reshape.  Mask is a CARefer over
       the parent's mask with the same logical shape and offset. */
    ca->mask =
      (CArray *) ca_refer_new(ca->parent->mask,
                              CA_BOOLEAN, ca->ndim, ca->dim, 0, parent_offset);
  }
  else if (ca->bytes < parent_bytes) {
    /* Divided reinterpret: one parent element splits into
       ratio = parent_bytes / bytes view elements.  Build a
       CARepeat that broadcasts each parent mask bit across the
       ratio sub-positions, then refer-reshape it to the view's
       actual shape. */
    ca_size_t ratio = parent_bytes / ca->bytes;
    ca_size_t count[CA_RANK_MAX];
    int8_t i;
    for (i = 0; i < ca->parent->ndim; i++) count[i] = 0;
    count[ca->parent->ndim] = ratio;
    ca->mask0 =
      (CArray *) ca_repeat_new(ca->parent->mask, ca->parent->ndim + 1, count);
    ca_unset_flag(ca->mask0, CA_FLAG_READ_ONLY);
    ca->mask =
      (CArray *) ca_refer_new(ca->mask0,
                              CA_BOOLEAN, ca->ndim, ca->dim, 0, parent_offset);
  }
  else {
    /* Spanned reinterpret: ratio = bytes / parent_bytes parent
       elements fold into one view element.  Build a CAReduce that
       OR-reduces the ratio adjacent parent mask bits into one
       mask bit, then refer-reshape to the view's shape. */
    ca_size_t ratio = ca->bytes / parent_bytes;
    ca->mask0 =
      (CArray *) ca_reduce_new(ca->parent->mask, ratio, parent_offset);
    ca->mask =
      (CArray *) ca_refer_new(ca->mask0,
                              CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
  }
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_refer_s_allocate (VALUE klass)
{
  CARefer *ca;
  return TypedData_Make_Struct(klass, CARefer, &carefer_data_type, ca);
}

static VALUE
rb_ca_refer_initialize_copy (VALUE self, VALUE other)
{
  CARefer *ca, *cs;
  TypedData_Get_Struct(self,  CARefer, &carefer_data_type, ca);
  TypedData_Get_Struct(other, CARefer, &carefer_data_type, cs);
  if ( ca_func[CA_OBJ_REFER].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_REFER, cs->ndim);
  }
  /* CAREFUL: rebuild through ca_refer_setup's (data_type, ndim,
     dim, bytes, offset) form.  The CAStride (strides, base_offset)
     form would lose the parent-element offset semantics on
     unusual mod-bytes alignments. */
  ca_refer_setup(ca, cs->parent, cs->data_type, cs->ndim, cs->dim,
                 cs->bytes, cs->base_offset / cs->parent->bytes);
  return self;
}

/* Reshape-stride rewrite.
 *
 * Try to express `parent` reshaped to `new_dim` as a CAStride over
 * the deepest non-CAStride ancestor (returned in *out_root) with
 * explicit strides + base_offset in that root's byte coord.  Used
 * by rb_ca_reshape and rb_ca_flatten before falling back to
 * ca_refer_new.
 *
 * Pre-conditions (contract from the callers):
 *   - product of new_dim == parent->elements
 *   - bytes (== parent->bytes) and data_type (== parent->data_type)
 *     unchanged, offset == 0 implicit
 *
 * Returns 1 on success with *out_root, out_strides[0..new_ndim-1]
 * and *out_base filled.  The caller then constructs
 *   ca_stride_new(CA_OBJ_STRIDE, *out_root, ..., out_strides, *out_base);
 * the CAStride's parent is *out_root (not the immediate caller
 * parent), which lets compose-fold treat the whole reshape as a
 * single-step gather from the entity.
 *
 * Returns 0 on failure: the caller must fall back to ca_refer_new.
 *
 * Algorithm:
 *   1. Resolve parent into (root, root_strides, root_base) via
 *      ca_stride_compose_to_root for the CAStride family, or
 *      row-major derivation for a plain CArray entity.  Other
 *      obj_types fail immediately.
 *   2. Match ranges of parent axes to new axes so element products
 *      agree.  Inside each matched range, root_strides must be
 *      inter-axis contiguous. */
static int
ca_reshape_try_strides (CArray *parent,
                        const ca_size_t *new_dim,
                        int8_t new_ndim,
                        CArray **out_root,
                        ca_size_t *out_strides,
                        ca_size_t *out_base)
{
  ca_size_t pstrides_buf[CA_RANK_MAX];
  ca_size_t pstrides_composed[CA_RANK_MAX];
  const ca_size_t *pstrides;
  ca_size_t pbase;
  ca_size_t bytes = parent->bytes;
  int8_t pndim = parent->ndim;
  int8_t k;
  CArray *root;

  /* Resolve parent into (root, pstrides, pbase) in root's byte coord. */
  if (ca_func[parent->obj_type].attach == ca_stride_func.attach) {
    /* CAStride family: fold the parent's own view through its
       ancestor chain, producing strides + base in the deepest
       non-CAStride ancestor's coord. */
    ca_stride_compose_to_root((CAStride *) parent,
                              &root, pstrides_composed, &pbase);
    pstrides = pstrides_composed;
  } else if (parent->obj_type == CA_OBJ_ARRAY
          || parent->obj_type == CA_OBJ_ARRAY_WRAP
          || parent->obj_type == CA_OBJ_SCALAR) {
    /* Plain CArray entity: row-major contig, base 0. */
    ca_size_t s = bytes;
    for (k = pndim - 1; k >= 0; k--) {
      pstrides_buf[k] = s;
      s *= parent->dim[k];
    }
    pstrides = pstrides_buf;
    pbase    = 0;
    root     = parent;
    (void) pstrides_composed;
  } else {
    /* CASelect / CAReduce / CAGrid / CAObject / CAField etc. — no usable
       strides representation for reshape rewrite. */
    return 0;
  }

  *out_root = root;

  /* Zero-element corner case: nothing to gather; trivial reshape. */
  if (parent->elements == 0) {
    for (k = 0; k < new_ndim; k++) out_strides[k] = 0;
    *out_base = pbase;
    return 1;
  }

  /* Scalar reshape (new_ndim == 0) only valid if elements == 1 — but
     CArray's reshape rejects argc==0 earlier; defensive return for safety. */
  if (new_ndim == 0) {
    *out_base = pbase;
    return parent->elements == 1 ? 1 : 0;
  }

  /* Match ranges outer-to-inner.  Skip dim==1 axes on either side
     (they contribute no displacement; we'll assign stride 0 to dim==1
     new axes after matching). */
  int8_t oi = 0, ni = 0;

  while (oi < pndim && ni < new_ndim) {
    /* Skip leading dim==1 new axes (no parent axis consumed) */
    if (new_dim[ni] == 1) {
      out_strides[ni] = 0;
      ni++;
      continue;
    }
    /* Skip leading dim==1 parent axes (no contribution) */
    if (parent->dim[oi] == 1) {
      oi++;
      continue;
    }

    int8_t oj = oi + 1;
    int8_t nj = ni + 1;
    ca_size_t old_prod = parent->dim[oi];
    ca_size_t new_prod = new_dim[ni];

    while (old_prod != new_prod) {
      if (old_prod < new_prod) {
        /* Need to extend old range; require inter-axis contig */
        if (oj >= pndim) return 0;
        if (parent->dim[oj] == 0) return 0;   /* shouldn't happen */
        if (pstrides[oj - 1] != pstrides[oj] * parent->dim[oj]) return 0;
        old_prod *= parent->dim[oj];
        oj++;
      } else {
        if (nj >= new_ndim) return 0;
        if (new_dim[nj] == 0) return 0;
        new_prod *= new_dim[nj];
        nj++;
      }
    }

    /* Range matched: assign strides to new axes [ni..nj).
       Innermost gets parent's innermost stride in the matched old range.
       Outer new axes scale by following new_dim. */
    out_strides[nj - 1] = pstrides[oj - 1];
    for (k = nj - 2; k >= ni; k--) {
      out_strides[k] = out_strides[k + 1] * new_dim[k + 1];
    }

    oi = oj;
    ni = nj;
  }

  /* Trailing dim==1 axes in either side */
  while (ni < new_ndim) {
    if (new_dim[ni] != 1) return 0;
    out_strides[ni] = 0;
    ni++;
  }
  while (oi < pndim) {
    if (parent->dim[oi] != 1) return 0;
    oi++;
  }

  *out_base = pbase;
  return 1;
}

static VALUE
rb_ca_refer (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj = Qnil;
  CArray *ca;
  CARefer *cr;
  int8_t  data_type;
  int8_t  ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t bytes, offset = 0;
  int8_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if (argc == 0) {
    data_type = ca->data_type;
    bytes     = ca->bytes;
    ndim      = ca->ndim;
    for (i = 0; i < ndim; i++) dim[i] = ca->dim[i];
    cr = ca_refer_new((CArray *) ca, data_type, ndim, dim, bytes, offset);
    obj = ca_wrap_struct(cr);
    rb_ca_set_parent(obj, self);
  }
  else {
    volatile VALUE rtype, rdim, ropt, rbytes = Qnil, roffset = Qnil;
    ropt = rb_pop_options(&argc, &argv);
    rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &rdim);
    rb_scan_options(ropt, "bytes,offset", &rbytes, &roffset);
    if (NIL_P(rbytes)) rbytes = rb_ca_bytes(self);
    rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
    if (NIL_P(rdim)) {
      if (ca->bytes != bytes) {
        rb_raise(rb_eRuntimeError,
                 "specify dimension shape for different byte size");
      } else {
        rdim = rb_ca_dim(self);
      }
    }
    Check_Type(rdim, T_ARRAY);
    ndim = RARRAY_LEN(rdim);
    for (i = 0; i < ndim; i++) dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
    if (! NIL_P(roffset)) offset = NUM2SIZE(roffset);
    cr = ca_refer_new((CArray *) ca, data_type, ndim, dim, bytes, offset);
    obj = ca_wrap_struct(cr);
    rb_ca_set_parent(obj, self);
    /* When rtype is a data_class, wrap the result in CARecord so
       the data_class is carried even if self is not itself a Face. */
    if ( rb_obj_is_data_class(rtype) ) {
      obj = rb_funcall(rb_const_get(rb_cObject, rb_intern("CARecord")),
                       rb_intern("wrap"), 2, obj, rtype);
      return obj;
    }
  }
  CA_WRAPPER_LIFT(obj, self, ca);
  return obj;
}

VALUE
rb_ca_refer_new (VALUE self,
                 int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                 ca_size_t offset)
{
  volatile VALUE list, rdim, ropt;
  int8_t i;

  rdim = rb_ary_new2(ndim);
  for (i = 0; i < ndim; i++) {
    rb_ary_store(rdim, i, SIZE2NUM(dim[i]));
  }

  list = rb_ary_new2(3);
  if (data_type == CA_FIXLEN && rb_ca_has_data_class(self)) {
    rb_ary_store(list, 0, rb_ca_data_class(self));
  } else {
    rb_ary_store(list, 0, INT2NUM(data_type));
  }
  rb_ary_store(list, 1, rdim);
  ropt = rb_hash_new();
  rb_set_options(ropt, "bytes,offset", SIZE2NUM(bytes), SIZE2NUM(offset));
  rb_ary_store(list, 2, ropt);

  {
    volatile VALUE obj = rb_ca_refer(3, (VALUE *) RARRAY_CONST_PTR(list), self);
    CArray *co;

    /* CAREFUL: this is the internal builder -- some fifteen call sites want
       the refer itself, not a wrapper on top of it.  The public `refer` it
       delegates to lifts a CALazyMarker, so strip that here.

       Two things go wrong otherwise.  rb_ca_value_array strips the mask off
       what it gets back and marks the level it is handed; with a marker in
       the way the refer underneath keeps its mask and never gets
       CA_FLAG_VALUE_ARRAY, so the values read back as UNDEF.  And builders
       that stack further views on the result -- fancy indexing goes refer,
       grid, refer -- end up with a marker buried in the middle of the
       chain, which is the redundant-middle-wrapper that CAFace.md section
       8.3 exists to prevent.

       Faces stay lifted: rb_ca_value_array depends on that and says so
       where it marks the storage level. */
    TypedData_Get_Struct(obj, CArray, &carray_data_type, co);
    if ( ca_is_lazy_marker(co) ) {
      obj = rb_ca_parent(obj);
    }
    return obj;
  }
}

/* CArray#reshape(*newdim) — returns a view of self with the new
   shape (a CAStride when ca_reshape_try_strides succeeds, otherwise
   a CARefer).  Each element of `newdim` is either:
     - Integer : the new size for that axis
     - nil     : copy from the source.  Axes left of the auto-infer
                 placeholder use ca->dim[i] in position order; axes
                 to its right use ca->dim[ca->ndim - (argc - i)] so
                 trailing nils mirror trailing source axes.
     - -1 / `:~` : one axis inferred from elements / (product of the
                 others).  At most one placeholder is allowed.

   Also exported (declared in carray.h) so downstream C extensions
   can build a reshape view directly:

     VALUE args[] = {INT2NUM(3), INT2NUM(2)};
     VALUE view = rb_ca_reshape(2, args, ca);

   For typed-dim usage (bypassing the placeholder vocabulary) call
   rb_ca_refer_new(self, ca->data_type, ndim, dim, ca->bytes, 0). */
VALUE
rb_ca_reshape (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  CARefer *cr;
  ca_size_t new_dim[CA_RANK_MAX];
  ca_size_t prod = 1;
  int placeholder_idx = -1;     /* axis with `-1` or `:~` infer placeholder */
  int i;
  volatile VALUE obj;
  VALUE sym_tilde = ID2SYM(rb_intern("~"));   /* :~ = infer-placeholder alias for -1 */

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if (argc < 0 || argc > CA_RANK_MAX) {
    rb_raise(rb_eArgError, "reshape: invalid number of dims (%d)", argc);
  }

  /* Locate the (at most one) auto-infer placeholder.  `-1` is the
     conventional spelling; `:~` is the unified auto-fill sigil
     (same meaning). */
  for (i = 0; i < argc; i++) {
    if ( (FIXNUM_P(argv[i]) && FIX2LONG(argv[i]) == -1)
         || argv[i] == sym_tilde ) {
      if (placeholder_idx >= 0) {
        rb_raise(rb_eRuntimeError,
                 "reshape: only one auto-infer placeholder (-1 / :~) allowed");
      }
      placeholder_idx = i;
    }
  }

  /* Resolve every non-placeholder axis. */
  for (i = 0; i < argc; i++) {
    if (i == placeholder_idx) continue;
    if (NIL_P(argv[i])) {
      /* Two-sweep nil resolution:
         - With a placeholder: forward-map before it, mirror from
           the end after.
         - Without a placeholder: forward-map while in range,
           otherwise mirror from the end so trailing nils pick up
           the tail source axes (e.g. b.ndim=1, b.reshape(1, nil)
           -> (1, 3)). */
      int src;
      if (placeholder_idx >= 0) {
        src = (i < placeholder_idx) ? i : ca->ndim - (argc - i);
      } else {
        src = (i < ca->ndim) ? i : ca->ndim - (argc - i);
      }
      if (src < 0 || src >= ca->ndim) {
        rb_raise(rb_eRuntimeError,
                 "reshape: nil at axis %d has no source dim", i);
      }
      new_dim[i] = ca->dim[src];
    }
    else {
      new_dim[i] = NUM2SIZE(argv[i]);
    }
    prod *= new_dim[i];
  }

  /* Resolve placeholder dim from the leftover total. */
  if (placeholder_idx >= 0) {
    if (prod == 0 || ca->elements % prod != 0) {
      rb_raise(rb_eRuntimeError,
               "reshape: cannot infer dim for `-1` placeholder");
    }
    new_dim[placeholder_idx] = ca->elements / prod;
  }
  else {
    /* CAREFUL: strict element conservation.  Without a placeholder
       the resolved product must equal the source element count.
       A smaller shape would silently truncate data (a CARefer over
       a subset), and on non-contiguous parents the compose-fold
       path corrupts data outright — hence the raise. */
    if (prod != ca->elements) {
      rb_raise(rb_eRuntimeError,
               "reshape: cannot reshape array of %lld elements into a shape "
               "of %lld elements (use -1 / :~ to infer a dim)",
               (long long) ca->elements, (long long) prod);
    }
  }

  /* Try the stride rewrite first.  On success, construct a
     CAStride directly over the deepest non-CAStride ancestor
     (out_root) with composed strides + base in that root's byte
     coord.  The Ruby-level parent ref is still `self`, so the
     immediate parent stays alive through GC.  On failure, fall
     through to the CARefer path. */
  {
    CArray *out_root;
    ca_size_t out_strides[CA_RANK_MAX];
    ca_size_t out_base;
    if (ca_reshape_try_strides(ca, new_dim, (int8_t) argc,
                               &out_root, out_strides, &out_base)) {
      CAStride *cs = ca_stride_new(CA_OBJ_STRIDE, out_root,
                                   ca->data_type, ca->bytes,
                                   (int8_t) argc, new_dim,
                                   out_strides, out_base);
      obj = ca_wrap_struct(cs);
      rb_ca_set_parent(obj, self);
      CA_WRAPPER_LIFT(obj, self, ca);
      return obj;
    }
  }

  cr = ca_refer_new(ca, ca->data_type, (int8_t) argc,
                    new_dim, ca->bytes, 0);
  obj = ca_wrap_struct(cr);
  rb_ca_set_parent(obj, self);
  CA_WRAPPER_LIFT(obj, self, ca);
  return obj;
}

/* CArray#flatten — a 1-D view of all elements in row-major order
   (a CAStride when ca_reshape_try_strides succeeds, otherwise a
   CARefer).  Also exported (declared in carray.h). */
VALUE
rb_ca_flatten (VALUE self)
{
  CArray *ca;
  CARefer *cr;
  ca_size_t dim[1];
  volatile VALUE obj;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  dim[0] = ca->elements;

  {
    CArray *out_root;
    ca_size_t out_strides[1];
    ca_size_t out_base;
    if (ca_reshape_try_strides(ca, dim, 1, &out_root, out_strides, &out_base)) {
      CAStride *cs = ca_stride_new(CA_OBJ_STRIDE, out_root,
                                   ca->data_type, ca->bytes,
                                   1, dim, out_strides, out_base);
      obj = ca_wrap_struct(cs);
      rb_ca_set_parent(obj, self);
      CA_WRAPPER_LIFT(obj, self, ca);
      return obj;
    }
  }

  cr = ca_refer_new(ca, ca->data_type, 1, dim, ca->bytes, 0);
  obj = ca_wrap_struct(cr);
  rb_ca_set_parent(obj, self);
  CA_WRAPPER_LIFT(obj, self, ca);
  return obj;
}

/* The bare size-1 insertion primitive, in the SOURCE frame: each position
   names the existing axis the new axis goes *before* (ndim = append at the
   end; negatives count from the end gap).  A position given more than once
   stacks several length-1 axes before that source axis.  Positions do not
   shift as other axes are inserted.

     a = CArray.int32(2, 3)            # shape [2, 3]
     insert before axis 0             -> [1, 2, 3]
     insert before axis 2 (= -1, end) -> [2, 3, 1]
     before axis 0 and the end        -> [1, 2, 3, 1]
     before axis 0 twice              -> [1, 1, 2, 3]

   Returns a CARefer view (zero-copy alias to +self+'s data, via reshape).
   Bound to the internal name __insert_axis_size1__; the user-facing
   insert_axis (with the repeat: keyword) is the Ruby method in
   lib/carray/basics.rb, which builds on this primitive.

   Non-static so external CIFY consumers (= carray_order.c,
   carray_median_percentile.c) can call directly; they pass a single axis,
   for which the source and output frames coincide. */
VALUE
rb_ca_insert_axis (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  VALUE   new_argv[CA_RANK_MAX];
  int     gap_count[CA_RANK_MAX + 1];
  int     ndim, new_ndim, ngap;
  int     i, c, k;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  ndim     = (int) ca->ndim;
  new_ndim = ndim + argc;
  if (new_ndim > CA_RANK_MAX) {
    rb_raise(rb_eArgError,
             "insert_axis: resulting ndim %d exceeds CA_RANK_MAX %d",
             new_ndim, CA_RANK_MAX);
  }

  ngap = ndim + 1;   /* gaps live in [0, ndim] (ndim = the end gap) */

  /* Tally how many new axes go before each source axis (gap).  Negative
     positions count from the end gap; duplicates are allowed (stacking). */
  for (i = 0; i <= ndim; i++) {
    gap_count[i] = 0;
  }
  for (i = 0; i < argc; i++) {
    int raw = NUM2INT(argv[i]);
    int g   = (raw < 0) ? raw + ngap : raw;
    if (g < 0 || g >= ngap) {
      rb_raise(rb_eArgError,
               "insert_axis: axis %d out of range for ndim %d", raw, ndim);
    }
    gap_count[g]++;
  }

  /* Build the output dim list: before each source axis emit its tally of
     length-1 axes, then the source dim; finally the end-gap tally. */
  k = 0;
  for (i = 0; i < ndim; i++) {
    for (c = 0; c < gap_count[i]; c++) {
      new_argv[k++] = INT2NUM(1);
    }
    new_argv[k++] = SIZE2NUM(ca->dim[i]);
  }
  for (c = 0; c < gap_count[ndim]; c++) {
    new_argv[k++] = INT2NUM(1);
  }

  return rb_ca_reshape(new_ndim, new_argv, self);
}

void
Init_ca_obj_refer (void)
{
  /* rb_cCARefer, CA_OBJ_REFER are defined in ruby_carray.c /
     carray_core.c.  Build the custom op table and override the
     baseline registration installed by Init_carray_core. */
  ca_refer_func = ca_stride_func;
  ca_refer_func.free_object = free_ca_refer;
  ca_refer_func.clone       = ca_refer_func_clone;
  ca_refer_func.create_mask = ca_refer_func_create_mask;
  /* CARefer's struct is larger than CAStride (adds mask0); inherit
     CAStride's pool_bytes / pool_init (dim + strides) but override
     struct_size so ca_array_alloc reserves the right amount. */
  ca_refer_func.struct_size = sizeof(CARefer);
  ca_func[CA_OBJ_REFER] = ca_refer_func;

  rb_define_const(rb_cObject, "CA_OBJ_REFER", INT2NUM(CA_OBJ_REFER));

  rb_define_method(rb_cCArray, "refer", rb_ca_refer, -1);
  rb_define_method(rb_cCArray, "reshape", rb_ca_reshape, -1);
  rb_define_method(rb_cCArray, "flatten", rb_ca_flatten, 0);
  /* The bare size-1 primitive.  The user-facing `insert_axis` (with its
     `repeat:` keyword) is the Ruby method in lib/carray/basics.rb, which
     owns the name and calls this primitive. */
  rb_define_method(rb_cCArray, "__insert_axis_size1__", rb_ca_insert_axis, -1);
  rb_define_alloc_func(rb_cCARefer, rb_ca_refer_s_allocate);
  rb_define_method(rb_cCARefer, "initialize_copy",
                                       rb_ca_refer_initialize_copy, 1);
}
