/* ---------------------------------------------------------------------------

  Lazy triadic element-wise arithmetic view: holds (op1, op2, op3,
  op_id) and materialises the promoted result on attach.  Carries
  CA_FLAG_READ_ONLY; there is no bang path and `[]=` raises.

  Sibling of ca_obj_binop.c (binary arithmetic) — same 3.0 lazy
  substrate.  Dispatched by ca_triop_kernel_lookup_vvv from
  ca_triop_dispatch.h.  Casts to the common data_type are inserted
  as CAMonOp nodes on all 3 operands by the public builder before the
  CATriOp is constructed.

  xfer_stride model (mirrors CABinOp):
    1. Pull op1 into `data` (the output buffer).  op1 and output share
       data_type (cast-before invariant), so this is safe as an
       in-place gather.
    2. Pull op2 into an arena scratch (per-node).
    3. Pull op3 into another arena scratch (per-node).
    4. Call the eager 1-D kernel with src1 == dst == data (in-place
       op1), src2 == scratch2, src3 == scratch3.

  Mask handling: none of the currently-defined triops (fma / fms /
  clip) trap on integer zero divisor, so m=NULL always at the
  kernel walk (SIMD fast path).  Output mask is a blind OR of
  operand masks (create_mask time).

  Cross-ndim promotion: intentional design rejection, mirroring
  CABinOp.  Callers must reshape explicitly.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_* */
#include "ca_triop_dispatch.h"
#include "ca_monop_dispatch.h"  /* CA_MONOP_CAST_BASE */

extern VALUE ca_broadcast_view (VALUE src, int8_t ndim,
                                ca_size_t *target_dim);

int8_t CA_OBJ_TRIOP;
VALUE rb_cCATriOp;

extern int8_t CA_OBJ_LAZY_MARKER;
extern VALUE ca_lazy_wrap_scalar (VALUE other, CArray *self_ca);

/* ------------------------------------------------------------------- */
/* CATriOp struct                                                       */
/* ------------------------------------------------------------------- */

typedef struct CATriOp {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;
  int32_t   flags;
  ca_size_t bytes;
  ca_size_t elements;
  ca_size_t *dim;
  char     *ptr;
  CArray   *mask;
  char     *_pool;
  CArray   *parent;       /* = op1 */
  uint32_t  attach;
  uint8_t   nosync;
  /* ---- CAMultiParent conformance (CA_FLAG_MULTI_PARENTS): n_parents and
         parents[] sit immediately after the CAView header, as carray.h's
         layout convention requires, so ca_has_mask can fold over both
         operands and build the mask on demand instead of at setup. ---- */
  int32_t   n_parents;        /* always 3 */
  CArray  **parents;          /* = &operands[0]; no separate allocation */
  /* CATriOp-specific tail */
  CArray   *op2;
  CArray   *op3;
  uint16_t  op_id;
  uint8_t   op2_is_scalar;
  uint8_t   op3_is_scalar;
  CArray   *operands[3];      /* {op1, op2, op3}; what parents points at */
} CATriOp;

static size_t
ca_triop_dsize (const void *ap)
{
  const CATriOp *ca = (const CATriOp *) ap;
  return sizeof(CATriOp) + ca->ndim * sizeof(ca_size_t);
}

static size_t
ca_triop_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_triop_pool_init (void *ap, int8_t ndim)
{
  CATriOp *ca = (CATriOp *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
  (void) ndim;
}

const rb_data_type_t catriop_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CATriOp",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_triop_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */
/* setup / new / free                                                   */
/* ------------------------------------------------------------------- */

static int
ca_triop_setup (CATriOp *ca, CArray *op1, CArray *op2, CArray *op3,
                uint16_t op_id)
{
  int8_t out_dt = ca_lazy_promote_triop(op_id, op1->data_type,
                                        op2->data_type, op3->data_type);
  ca_size_t out_bytes = ca_sizeof[out_dt];

  ca->obj_type  = CA_OBJ_TRIOP;
  ca->data_type = out_dt;
  ca->flags     = CA_FLAG_READ_ONLY | CA_FLAG_MULTI_PARENTS;
  ca->ndim      = op1->ndim;
  ca->bytes     = out_bytes;
  ca->elements  = op1->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, op1->ndim);
  }
  ca->parent    = op1;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->op2       = op2;
  ca->op3       = op3;
  ca->op_id     = op_id;
  ca->op2_is_scalar = ( op2->elements == 1 && op1->elements > 1 ) ? 1 : 0;
  ca->op3_is_scalar = ( op3->elements == 1 && op1->elements > 1 ) ? 1 : 0;
  ca->operands[0] = op1;
  ca->operands[1] = op2;
  ca->operands[2] = op3;
  ca->parents     = ca->operands;
  ca->n_parents   = 3;

  memcpy(ca->dim, op1->dim, op1->ndim * sizeof(ca_size_t));

  /* The mask is NOT built here.  ca_has_mask folds over parents[] for a
     multi-parent view and creates it on demand, so an expression whose mask
     nobody reads never allocates one. */

  if ( ca_is_scalar(op1) && ca_is_scalar(op2) && ca_is_scalar(op3) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CATriOp *
ca_triop_new (CArray *op1, CArray *op2, CArray *op3, uint16_t op_id)
{
  CATriOp *ca = (CATriOp *) ca_array_alloc(CA_OBJ_TRIOP, op1->ndim);
  ca_triop_setup(ca, op1, op2, op3, op_id);
  return ca;
}

static void
free_ca_triop (void *ap)
{
  CATriOp *ca = (CATriOp *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ca->_pool ) {
      ca_array_free(ca);
    }
    else {
      xfree(ca->dim);
      xfree(ca);
    }
  }
}

/* ------------------------------------------------------------------- */
/* operation function table                                             */
/* ------------------------------------------------------------------- */

static void ca_triop_func_xfer_stride (void *ap, ca_size_t *starts,
                                       ca_size_t *counts, ca_size_t *strides,
                                       void *data, int dir);

static void *
ca_triop_func_clone (void *ap)
{
  CATriOp *ca = (CATriOp *) ap;
  return ca_triop_new(ca->parent, ca->op2, ca->op3, ca->op_id);
}

static void
ca_triop_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CATriOp *ca = (CATriOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t counts[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CATriOp is read-only (xfer_index PUT)");
  }

  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    starts[k]  = idx[k];
    counts[k]  = 1;
    strides[k] = s;
  }
  ca_triop_func_xfer_stride(ca, starts, counts, strides, data, CA_XFER_GET);
}

static void
ca_triop_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                          void *data, int dir)
{
  CATriOp *ca = (CATriOp *) ap;
  ca_size_t i;
  char *out = (char *) data;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CATriOp is read-only (xfer_addrs PUT)");
  }

  for ( i = 0; i < n; i++ ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addrs[i], idx);
    ca_triop_func_xfer_index(ca, idx, out + i * ca->bytes, CA_XFER_GET);
  }
}

/* Test / observability counters (mirror CABinOp's counters).           */
ca_size_t ca_triop_scratch_acquire_count = 0;
ca_size_t ca_triop_materialise_call_count = 0;

/* Pull one operand into a scratch (or one cell if it is a scalar to
   be broadcast at step=0).  Returns the scratch pointer; updates
   *step_out to 0 (scalar) or 1 (same-shape).                          */
static void *
pull_operand (CArray *op, int is_scalar, ca_size_t *starts,
              ca_size_t *counts, ca_size_t slab_n, int8_t ndim,
              ca_size_t *step_out)
{
  void *scratch;
  ca_size_t bytes = op->bytes;
  int8_t k;

  if ( is_scalar ) {
    ca_size_t one_starts[CA_RANK_MAX] = {0};
    ca_size_t one_counts[CA_RANK_MAX];
    ca_size_t one_strides[CA_RANK_MAX];
    for ( k = 0; k < op->ndim; k++ ) {
      one_counts[k]  = 1;
      one_strides[k] = bytes;
    }
    scratch = ca_lazy_arena_acquire(bytes);
    ca_triop_scratch_acquire_count++;
    ca_xfer_stride(op, one_starts, one_counts, one_strides, scratch,
                   CA_XFER_GET);
    *step_out = 0;
  }
  else {
    ca_size_t op_strides[CA_RANK_MAX];
    ca_size_t s = bytes;
    for ( k = ndim - 1; k >= 0; k-- ) {
      op_strides[k] = s;
      s *= counts[k];
    }
    scratch = ca_lazy_arena_acquire(slab_n * bytes);
    ca_triop_scratch_acquire_count++;
    ca_xfer_stride(op, starts, counts, op_strides, scratch, CA_XFER_GET);
    *step_out = 1;
  }
  return scratch;
}

static void
ca_triop_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                           ca_size_t *strides, void *data, int dir)
{
  CATriOp *to = (CATriOp *) ap;
  ca_size_t slab_n;
  int8_t    k;
  void     *scratch2, *scratch3;
  ca_size_t op2_step, op3_step;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CATriOp is read-only (xfer_stride PUT)");
  }
  ca_triop_materialise_call_count++;

  slab_n = 1;
  for ( k = 0; k < to->ndim; k++ ) slab_n *= counts[k];

  /* Step 1: pull op1 into the output buffer. */
  ca_xfer_stride(to->parent, starts, counts, strides, data, CA_XFER_GET);

  /* Step 2: pull op2 into an arena scratch. */
  scratch2 = pull_operand(to->op2, to->op2_is_scalar, starts, counts,
                          slab_n, to->ndim, &op2_step);

  /* Step 3: pull op3 into another arena scratch. */
  scratch3 = pull_operand(to->op3, to->op3_is_scalar, starts, counts,
                          slab_n, to->ndim, &op3_step);

  /* Step 4: apply the kernel.  ptr1 == ptr4 (in-place op1); no
     currently-defined triop traps, so m=NULL. */
  {
    ca_triop_func_t fn = ca_triop_kernel_lookup_vvv(to->op_id, to->data_type);
    if ( fn == NULL ) {
      ca_lazy_arena_release(scratch3);
      ca_lazy_arena_release(scratch2);
      rb_raise(rb_eNotImpError,
               "CATriOp: kernel not implemented (op_id=%u data_type=%d)",
               (unsigned) to->op_id, (int) to->data_type);
    }
    fn(slab_n, NULL,
       (char *)data,     1,              /* src1 == dst (op1, in-place) */
       (char *)scratch2, op2_step,       /* src2 (op2) */
       (char *)scratch3, op3_step,       /* src3 (op3) */
       (char *)data,     1);             /* dst */
  }

  ca_lazy_arena_release(scratch3);
  ca_lazy_arena_release(scratch2);
}

static void
ca_triop_func_xfer_all (void *ap, void *data, int dir)
{
  CATriOp *ca = (CATriOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_xfer_stride(ca, starts, ca->dim, native, data, dir);
}

static void
ca_triop_func_allocate (void *ap)
{
  CATriOp *ca = (CATriOp *) ap;
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_triop_func_attach (void *ap)
{
  /* CAREFUL: call the view-specific xfer_stride directly (same as
     CABinOp).  The public dispatcher's self-memcpy fast path would
     leave the freshly-allocated buffer holding garbage. */
  CATriOp *ca = (CATriOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s;

  ca->ptr = xmalloc(ca_length(ca));

  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_triop_func_xfer_stride(ca, starts, ca->dim, native, ca->ptr, CA_XFER_GET);
}

static void
ca_triop_func_sync (void *ap)
{
  (void) ap;  /* read-only */
}

static void
ca_triop_func_detach (void *ap)
{
  CATriOp *ca = (CATriOp *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
}

NORETURN(static void ca_triop_func_fill_data (void *ap, void *ptr));
static void
ca_triop_func_fill_data (void *ap, void *ptr)
{
  (void) ap; (void) ptr;
  rb_raise(rb_eRuntimeError, "CATriOp is read-only (fill_data)");
}

/* Build out.mask.  Blind OR of the three operand masks — none of the
   currently-defined triops carry a Kleene 3-valued fixup. */
static void
ca_triop_func_create_mask (void *ap)
{
  CATriOp *to = (CATriOp *) ap;
  CArray *op1 = to->parent;
  CArray *op2 = to->op2;
  CArray *op3 = to->op3;
  boolean8_t *dst, *m1, *m2, *m3;
  ca_size_t i, n;
  int has1, has2, has3;

  has1 = ca_has_mask(op1);
  has2 = ca_has_mask(op2);
  has3 = ca_has_mask(op3);
  if ( ! has1 && ! has2 && ! has3 ) return;

  /* Exactly one masked operand: the answer is that operand's mask, cell
     for cell.  Share it rather than allocating a copy per node. */
  if ( has1 + has2 + has3 == 1 ) {
    CArray *src = has1 ? op1 : ( has2 ? op2 : op3 );
    if ( src->elements == to->elements ) {
      to->mask = (CArray *) ca_refer_new(src->mask, CA_BOOLEAN,
                                         to->ndim, to->dim, 0, 0);
      return;
    }
  }

  to->mask = (CArray *) carray_new(CA_BOOLEAN, to->ndim, to->dim, 0, NULL);
  dst = (boolean8_t *) to->mask->ptr;
  n = to->elements;

  /* The masks are what is read here; attaching the operand instead
     materialises the whole subexpression under it. */
  if ( has1 ) ca_attach(op1->mask);
  if ( has2 ) ca_attach(op2->mask);
  if ( has3 ) ca_attach(op3->mask);

  m1 = has1 ? (boolean8_t *) op1->mask->ptr : NULL;
  m2 = has2 ? (boolean8_t *) op2->mask->ptr : NULL;
  m3 = has3 ? (boolean8_t *) op3->mask->ptr : NULL;

  for ( i = 0; i < n; i++ ) {
    ca_size_t i2 = to->op2_is_scalar ? 0 : i;
    ca_size_t i3 = to->op3_is_scalar ? 0 : i;
    boolean8_t a = m1 ? m1[i]  : 0;
    boolean8_t b = m2 ? m2[i2] : 0;
    boolean8_t c = m3 ? m3[i3] : 0;
    dst[i] = (boolean8_t) ( a | b | c );
  }

  if ( has3 ) ca_detach(op3->mask);
  if ( has2 ) ca_detach(op2->mask);
  if ( has1 ) ca_detach(op1->mask);
}

ca_operation_function_t ca_triop_func = {
  -1, /* CA_OBJ_TRIOP, set at install time */
  CA_VIEW_ARRAY,
  free_ca_triop,
  ca_triop_func_clone,
  ca_triop_func_allocate,
  ca_triop_func_attach,
  ca_triop_func_sync,
  ca_triop_func_detach,
  ca_triop_func_fill_data,
  ca_triop_func_create_mask,
  ca_triop_func_xfer_index,
  ca_triop_func_xfer_addrs,
  NULL,                       /* fold_stride: never fold — op boundary */
  ca_triop_func_xfer_stride,
  ca_triop_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Public builder                                                       */
/* ------------------------------------------------------------------- */

static VALUE
collapse_marker (VALUE cary)
{
  CArray *ca;
  if ( ! rb_obj_is_carray(cary) ) return cary;
  TypedData_Get_Struct(cary, CArray, &carray_data_type, ca);
  if ( ca->obj_type == CA_OBJ_LAZY_MARKER ) {
    return rb_ca_parent(cary);
  }
  return cary;
}

/* Low-level constructor.  Does NOT insert cast nodes; the caller must
   have promoted all three operands to the common data_type. */
static VALUE
rb_ca_triop_new (VALUE cary1, VALUE cary2, VALUE cary3, uint16_t op_id)
{
  volatile VALUE obj;
  CArray *op1, *op2, *op3;
  CATriOp *ca;
  rb_check_carray_object(cary1);
  rb_check_carray_object(cary2);
  rb_check_carray_object(cary3);
  TypedData_Get_Struct(cary1, CArray, &carray_data_type, op1);
  TypedData_Get_Struct(cary2, CArray, &carray_data_type, op2);
  TypedData_Get_Struct(cary3, CArray, &carray_data_type, op3);
  ca  = ca_triop_new(op1, op2, op3, op_id);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary1);
  /* Pin op2 / op3 via ivars so GC keeps them alive.  parent slot
     already pins op1. */
  rb_ivar_set(obj, rb_intern("__triop_op2__"), cary2);
  rb_ivar_set(obj, rb_intern("__triop_op3__"), cary3);
  return obj;
}

/* Insert a cast node if operand's data_type differs from target. */
static VALUE
insert_cast (VALUE cary, int8_t target_dt, CArray **ca_out)
{
  CArray *ca;
  TypedData_Get_Struct(cary, CArray, &carray_data_type, ca);
  if ( ca->data_type != target_dt ) {
    VALUE cast_op = INT2NUM(CA_MONOP_CAST_BASE + target_dt);
    cary = rb_funcall(rb_const_get(rb_cObject, rb_intern("CAMonOp")),
                      rb_intern("__build__"), 2, cary, cast_op);
    TypedData_Get_Struct(cary, CArray, &carray_data_type, ca);
  }
  *ca_out = ca;
  return cary;
}

/* Public builder: build a CATriOp tree node for op_id over
   (cary1, cary2, cary3).  Inserts cast nodes when any operand's
   data_type differs from the common data_type, then resolves
   same-ndim size-1 broadcast pairwise against op1 (the walk anchor).

   Broadcast: each of op2 / op3 is aligned against op1 via
   ca_broadcast_pair.  After alignment, each must have either the
   same elements as op1 or be a 1-element CScalar (walked with
   element_step = 0 by the kernel).  If op1 itself is a 1-element
   CScalar and any of op2 / op3 is an array, op1 is lifted via
   ca_repeat_new + ca_broadcast_view (same trick as CABinOp).

   Cross-ndim promotion is rejected, mirroring CABinOp. */
VALUE
rb_ca_triop_build (VALUE cary1, VALUE cary2, VALUE cary3, uint16_t op_id)
{
  CArray *op1, *op2, *op3;
  int8_t  dt1, dt2, dt3;
  volatile VALUE r1, r2, r3;

  r1 = collapse_marker(cary1);
  r2 = collapse_marker(cary2);
  r3 = collapse_marker(cary3);

  /* Promote non-CArray Ruby values (e.g. clip's Numeric bounds) to
     CScalars carrying an existing operand's data_type. */
  if ( ! rb_obj_is_carray(r1) || ! rb_obj_is_carray(r2) || ! rb_obj_is_carray(r3) ) {
    /* Find an anchor CArray for scalar promotion. */
    CArray *anchor = NULL;
    if ( rb_obj_is_carray(r1) ) TypedData_Get_Struct(r1, CArray, &carray_data_type, anchor);
    else if ( rb_obj_is_carray(r2) ) TypedData_Get_Struct(r2, CArray, &carray_data_type, anchor);
    else if ( rb_obj_is_carray(r3) ) TypedData_Get_Struct(r3, CArray, &carray_data_type, anchor);
    if ( anchor == NULL ) {
      rb_raise(rb_eArgError,
               "CATriOp: at least one operand must be a CArray");
    }
    if ( ! rb_obj_is_carray(r1) ) r1 = ca_lazy_wrap_scalar(r1, anchor);
    if ( ! rb_obj_is_carray(r2) ) r2 = ca_lazy_wrap_scalar(r2, anchor);
    if ( ! rb_obj_is_carray(r3) ) r3 = ca_lazy_wrap_scalar(r3, anchor);
  }

  TypedData_Get_Struct(r1, CArray, &carray_data_type, op1);
  TypedData_Get_Struct(r2, CArray, &carray_data_type, op2);
  TypedData_Get_Struct(r3, CArray, &carray_data_type, op3);

  /* Step 1: cast to common data_type. */
  ca_triop_kernel_input_data_types(op_id,
                                   op1->data_type, op2->data_type, op3->data_type,
                                   &dt1, &dt2, &dt3);
  r1 = insert_cast(r1, dt1, &op1);
  r2 = insert_cast(r2, dt2, &op2);
  r3 = insert_cast(r3, dt3, &op3);

  /* Step 2: pairwise broadcast against op1 (the walk anchor).  If op1
     is a scalar and any of op2 / op3 is an array, lift op1 up to the
     array shape first. */
  {
    CArray *anchor = NULL;
    volatile VALUE r_anchor = Qnil;
    int8_t anchor_ndim;
    /* Pick the largest-ndim non-scalar operand as anchor. */
    if ( op1->elements > 1 ) { anchor = op1; r_anchor = r1; }
    else if ( op2->elements > 1 ) { anchor = op2; r_anchor = r2; }
    else if ( op3->elements > 1 ) { anchor = op3; r_anchor = r3; }
    if ( anchor && anchor != op1 ) {
      /* op1 is a CScalar but the walk shape is determined by another
         operand.  Lift op1 up to anchor's shape via
         ca_repeat_new + ca_broadcast_view (same trick as CABinOp's
         non-commutative left-scalar path). */
      anchor_ndim = anchor->ndim;
      if ( anchor_ndim > op1->ndim ) {
        ca_size_t count[CA_RANK_MAX];
        int8_t k;
        for ( k = 0; k < anchor_ndim - 1; k++ ) count[k] = 1;
        count[anchor_ndim - 1] = 0;
        r1 = rb_ca_repeat_new(r1, anchor_ndim, count);
        TypedData_Get_Struct(r1, CArray, &carray_data_type, op1);
      }
      r1 = ca_broadcast_view(r1, anchor_ndim, anchor->dim);
      TypedData_Get_Struct(r1, CArray, &carray_data_type, op1);
      (void) r_anchor;
    }
  }

  /* Now align op2 / op3 against op1 for size-1 broadcast. */
  ca_broadcast_pair(&r1, &r2);
  TypedData_Get_Struct(r1, CArray, &carray_data_type, op1);
  TypedData_Get_Struct(r2, CArray, &carray_data_type, op2);
  ca_broadcast_pair(&r1, &r3);
  TypedData_Get_Struct(r1, CArray, &carray_data_type, op1);
  TypedData_Get_Struct(r3, CArray, &carray_data_type, op3);

  /* Step 3: each of op2 / op3 must match op1's element count OR be a
     1-element CScalar (kernel walks with element_step = 0 in that case).
     Unreachable from Ruby; see the note in ca_obj_binop.c. */
  if ( op2->elements != op1->elements && op2->elements != 1 ) {
    rb_raise(rb_eArgError,
             "CATriOp: element count mismatch on op2 (%lld vs %lld)",
             (long long) op2->elements, (long long) op1->elements);
  }
  if ( op3->elements != op1->elements && op3->elements != 1 ) {
    rb_raise(rb_eArgError,
             "CATriOp: element count mismatch on op3 (%lld vs %lld)",
             (long long) op3->elements, (long long) op1->elements);
  }

  return rb_ca_triop_new(r1, r2, r3, op_id);
}

static VALUE
rb_ca_triop_s_build (VALUE klass, VALUE cary1, VALUE cary2, VALUE cary3,
                     VALUE op_id_val)
{
  uint16_t op_id = (uint16_t) NUM2UINT(op_id_val);
  (void) klass;
  return rb_ca_triop_build(cary1, cary2, cary3, op_id);
}

static VALUE
rb_ca_triop_op_id (VALUE self)
{
  CATriOp *to;
  TypedData_Get_Struct(self, CATriOp, &catriop_data_type, to);
  return UINT2NUM(to->op_id);
}

static VALUE
rb_ca_triop_op2 (VALUE self)
{
  return rb_ivar_get(self, rb_intern("__triop_op2__"));
}

static VALUE
rb_ca_triop_op3 (VALUE self)
{
  return rb_ivar_get(self, rb_intern("__triop_op3__"));
}

/* Test instrumentation. */
static VALUE
rb_ca_triop_s_reset_scratch_counter (VALUE klass)
{
  (void) klass;
  ca_triop_scratch_acquire_count = 0;
  return Qnil;
}

static VALUE
rb_ca_triop_s_scratch_count (VALUE klass)
{
  (void) klass;
  return SIZE2NUM(ca_triop_scratch_acquire_count);
}

static VALUE
rb_ca_triop_s_reset_materialise_counter (VALUE klass)
{
  (void) klass;
  ca_triop_materialise_call_count = 0;
  return Qnil;
}

static VALUE
rb_ca_triop_s_materialise_count (VALUE klass)
{
  (void) klass;
  return SIZE2NUM(ca_triop_materialise_call_count);
}

static VALUE
rb_ca_triop_s_allocate (VALUE klass)
{
  CATriOp *ca;
  return TypedData_Make_Struct(klass, CATriOp, &catriop_data_type, ca);
}

static VALUE
rb_ca_triop_initialize_copy (VALUE self, VALUE other)
{
  CATriOp *ca, *cs;
  TypedData_Get_Struct(self,  CATriOp, &catriop_data_type, ca);
  TypedData_Get_Struct(other, CATriOp, &catriop_data_type, cs);
  if ( ca_func[CA_OBJ_TRIOP].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_TRIOP, cs->parent->ndim);
  }
  ca_triop_setup(ca, cs->parent, cs->op2, cs->op3, cs->op_id);
  return self;
}

void
Init_ca_obj_triop (void)
{
  rb_cCATriOp = rb_define_class("CATriOp", rb_cCAView);

  ca_triop_func.struct_size = sizeof(CATriOp);
  ca_triop_func.pool_bytes  = ca_triop_pool_bytes;
  ca_triop_func.pool_init   = ca_triop_pool_init;

  CA_OBJ_TRIOP = ca_install_obj_type(rb_cCATriOp,
                                     &catriop_data_type,
                                     rb_cCArrayMask,
                                     &carray_mask_data_type, &ca_triop_func, sizeof(ca_triop_func));
  rb_define_const(rb_cObject, "CA_OBJ_TRIOP", INT2NUM(CA_OBJ_TRIOP));

  /* op_id constants shared with lib/carray/lazy.rb. */
  rb_define_const(rb_cCATriOp, "OP_FMA",  INT2NUM(CA_TRIOP_FMA));
  rb_define_const(rb_cCATriOp, "OP_FMS",  INT2NUM(CA_TRIOP_FMS));
  rb_define_const(rb_cCATriOp, "OP_CLIP", INT2NUM(CA_TRIOP_CLIP));

  rb_define_alloc_func(rb_cCATriOp, rb_ca_triop_s_allocate);
  rb_define_method(rb_cCATriOp, "initialize_copy",
                                rb_ca_triop_initialize_copy, 1);

  rb_define_singleton_method(rb_cCATriOp, "__build__",
                             rb_ca_triop_s_build, 4);

  rb_define_method(rb_cCATriOp, "__op_id__",
                                rb_ca_triop_op_id, 0);
  rb_define_method(rb_cCATriOp, "__triop_op2__",
                                rb_ca_triop_op2, 0);
  rb_define_method(rb_cCATriOp, "__triop_op3__",
                                rb_ca_triop_op3, 0);

  /* Test instrumentation. */
  rb_define_singleton_method(rb_cCATriOp, "__reset_scratch_counter__",
                             rb_ca_triop_s_reset_scratch_counter, 0);
  rb_define_singleton_method(rb_cCATriOp, "__scratch_count__",
                             rb_ca_triop_s_scratch_count, 0);
  rb_define_singleton_method(rb_cCATriOp, "__reset_materialise_counter__",
                             rb_ca_triop_s_reset_materialise_counter, 0);
  rb_define_singleton_method(rb_cCATriOp, "__materialise_count__",
                             rb_ca_triop_s_materialise_count, 0);
}
