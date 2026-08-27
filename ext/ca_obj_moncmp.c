/* ---------------------------------------------------------------------------

  CAMonCmp — lazy monadic element-wise comparison view: is_nan /
  is_inf / is_finite / is_invalid / signbit.  Output data_type =
  CA_BOOLEAN (1 byte); operand keeps its native data_type (per-type
  kernels cover integer as well, so is_nan / is_inf on integer parents
  return const-false and is_finite const-true without a cast layer).

  xfer_stride model:
    Output data_type (boolean8_t) differs from the operand data_type,
    so the in-place chain-eval trick used by CAMonOp does not apply.
    The parent is pulled into an operand-data_type scratch slab, then
    the moncmp kernel writes boolean8_t into `data`:
      1. acquire scratch (slab_n * parent_bytes) — or use the parent's
         live ptr directly via ca_moncmp_try_leaf_inplace
      2. ca_xfer_stride pulls the parent slab into scratch
      3. kernel: fn(n, m, scratch, 1, data, 1)
      4. release scratch

  Peak scratch: 1 operand-data_type slab.

  Mask propagation:
    Per-type moncmp kernels write only at non-masked positions, so
    the standard create_mask = parent.mask machinery carries mask bits
    to the caller-visible result.  No in-flight mask handling in
    xfer_stride.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_* */
#include "ca_moncmp_dispatch.h"

extern void *ca_lazy_arena_acquire (ca_size_t bytes);
extern void  ca_lazy_arena_release (void *ptr);

int8_t CA_OBJ_MONCMP;
VALUE rb_cCAMonCmp;

extern int8_t CA_OBJ_LAZY_MARKER;

/* ------------------------------------------------------------------- */
/* CAMonCmp struct                                                      */
/* ------------------------------------------------------------------- */

typedef struct CAMonCmp {
  int16_t   obj_type;
  int8_t    data_type;        /* always CA_BOOLEAN */
  int8_t    ndim;
  int32_t   flags;
  ca_size_t bytes;            /* always 1 */
  ca_size_t elements;
  ca_size_t *dim;
  char     *ptr;
  CArray   *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* CAMonCmp-specific tail */
  uint16_t  op_id;
} CAMonCmp;

static size_t
ca_moncmp_dsize (const void *ap)
{
  const CAMonCmp *ca = (const CAMonCmp *) ap;
  return sizeof(CAMonCmp) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer, uniform with the other pool-migrated views. */
static size_t
ca_moncmp_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_moncmp_pool_init (void *ap, int8_t ndim)
{
  CAMonCmp *ca = (CAMonCmp *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t camoncmp_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAMonCmp",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_moncmp_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */
/* setup / new / free                                                   */
/* ------------------------------------------------------------------- */

static int
ca_moncmp_setup (CAMonCmp *ca, CArray *parent, uint16_t op_id)
{
  ca->obj_type  = CA_OBJ_MONCMP;
  ca->data_type = CA_BOOLEAN;
  ca->flags     = CA_FLAG_READ_ONLY;
  ca->ndim      = parent->ndim;
  ca->bytes     = 1;
  ca->elements  = parent->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, parent->ndim);
  }
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->op_id     = op_id;

  memcpy(ca->dim, parent->dim, parent->ndim * sizeof(ca_size_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }
  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }
  return 0;
}

CAMonCmp *
ca_moncmp_new (CArray *parent, uint16_t op_id)
{
  CAMonCmp *ca = (CAMonCmp *) ca_array_alloc(CA_OBJ_MONCMP, parent->ndim);
  ca_moncmp_setup(ca, parent, op_id);
  return ca;
}

static void
free_ca_moncmp (void *ap)
{
  CAMonCmp *ca = (CAMonCmp *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ca->_pool ) {
      ca_array_free(ca);          /* dim lives in _pool */
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

static void ca_moncmp_func_xfer_stride (void *ap, ca_size_t *starts,
                                         ca_size_t *counts,
                                         ca_size_t *strides,
                                         void *data, int dir);

static void *
ca_moncmp_func_clone (void *ap)
{
  CAMonCmp *ca = (CAMonCmp *) ap;
  return ca_moncmp_new(ca->parent, ca->op_id);
}

static void
ca_moncmp_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAMonCmp *ca = (CAMonCmp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t counts[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  int8_t    k;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CAMonCmp is read-only (xfer_index PUT)");
  }
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    starts[k]  = idx[k];
    counts[k]  = 1;
    strides[k] = 1;
  }
  ca_moncmp_func_xfer_stride(ca, starts, counts, strides, data, CA_XFER_GET);
}

static void
ca_moncmp_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                            void *data, int dir)
{
  CAMonCmp *ca = (CAMonCmp *) ap;
  ca_size_t i;
  char *out = (char *) data;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CAMonCmp is read-only (xfer_addrs PUT)");
  }
  for ( i = 0; i < n; i++ ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addrs[i], idx);
    ca_moncmp_func_xfer_index(ca, idx, out + i, CA_XFER_GET);
  }
}

ca_size_t ca_moncmp_scratch_acquire_count = 0;
ca_size_t ca_moncmp_materialise_call_count = 0;
ca_size_t ca_moncmp_leaf_inplace_count     = 0;

/* Leaf-operand in-place read: when the parent is an entity-like
   contig source, hand parent->ptr + byte_offset directly to the
   kernel and skip the arena acquire + xfer_stride pull.  Mirrors the
   sibling helper in ca_obj_bincmp.c. */
static int
ca_moncmp_try_leaf_inplace (CArray *p,
                             ca_size_t *starts, ca_size_t *counts,
                             ca_size_t expected_inner_byte_stride,
                             char **out_ptr)
{
  ca_size_t row_strides[CA_RANK_MAX];
  ca_size_t s, byte_off;
  int8_t k;

  if ( p->ptr == NULL ) return 0;
  if ( p->bytes != expected_inner_byte_stride ) return 0;

  s = p->bytes;
  for ( k = p->ndim - 1; k >= 0; k-- ) {
    row_strides[k] = s;
    s *= p->dim[k];
  }
  byte_off = 0;
  for ( k = 0; k < p->ndim; k++ ) {
    if ( starts[k] < 0 || starts[k] + counts[k] > p->dim[k] ) return 0;
    byte_off += starts[k] * row_strides[k];
  }
  *out_ptr = p->ptr + byte_off;
  return 1;
}

static void
ca_moncmp_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                             ca_size_t *strides, void *data, int dir)
{
  CAMonCmp *mc = (CAMonCmp *) ap;
  ca_size_t slab_n;
  int8_t    k;
  void     *scratch;
  ca_size_t operand_bytes;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CAMonCmp is read-only (xfer_stride PUT)");
  }
  ca_moncmp_materialise_call_count++;

  slab_n = 1;
  for ( k = 0; k < mc->ndim; k++ ) slab_n *= counts[k];

  operand_bytes = mc->parent->bytes;

  /* === 1. pull parent (leaf-opt or scratch) === */
  int scratch_is_inplace = 0;
  {
    char *inplace = NULL;
    if ( ca_moncmp_try_leaf_inplace(mc->parent, starts, counts,
                                     operand_bytes, &inplace) ) {
      scratch = inplace;
      scratch_is_inplace = 1;
      ca_moncmp_leaf_inplace_count++;
    }
    else {
      ca_size_t scratch_strides[CA_RANK_MAX];
      ca_size_t s = operand_bytes;
      for ( k = mc->ndim - 1; k >= 0; k-- ) {
        scratch_strides[k] = s;
        s *= counts[k];
      }
      scratch = ca_lazy_arena_acquire(slab_n * operand_bytes);
      ca_moncmp_scratch_acquire_count++;
      ca_xfer_stride(mc->parent, starts, counts, scratch_strides, scratch,
                     CA_XFER_GET);
    }
  }

  /* === 2. apply moncmp kernel ===
   *
   * Kernel signature (ext/carray.h):
   *   fn(n, m, ptr1, i1, ptr2, i2)
   *   where ptr2 is boolean8_t*
   *
   * Non-trapping: m=NULL (= SIMD fast path).  Per-data_type kernel handles
   * integer is_nan etc. internally.
   */
  {
    ca_moncmp_func_t fn = ca_moncmp_kernel_lookup(mc->op_id,
                                                   mc->parent->data_type);
    if ( fn == NULL ) {
      if ( ! scratch_is_inplace ) ca_lazy_arena_release(scratch);
      rb_raise(rb_eNotImpError,
               "CAMonCmp: kernel not implemented (op_id=%u data_type=%d)",
               (unsigned) mc->op_id, (int) mc->parent->data_type);
    }
    fn(slab_n, NULL,
       (char *) scratch,    1,
       (boolean8_t *) data, 1);
  }

  if ( ! scratch_is_inplace ) ca_lazy_arena_release(scratch);
}

static void
ca_moncmp_func_xfer_all (void *ap, void *data, int dir)
{
  CAMonCmp *ca = (CAMonCmp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s = 1;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_xfer_stride(ca, starts, ca->dim, native, data, dir);
}

static void
ca_moncmp_func_allocate (void *ap)
{
  CAMonCmp *ca = (CAMonCmp *) ap;
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_moncmp_func_attach (void *ap)
{
  /* CAREFUL: self-fill through the public ca_xfer_stride dispatcher
     hits its self-memcpy fast path (data == ca->ptr becomes a no-op
     and the buffer stays as xmalloc garbage).  Call the view's own
     xfer_stride directly to force the actual gather+cast. */
  CAMonCmp *ca = (CAMonCmp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s;

  ca->ptr = xmalloc(ca_length(ca));

  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_moncmp_func_xfer_stride(ca, starts, ca->dim, native, ca->ptr, CA_XFER_GET);
}

static void
ca_moncmp_func_sync (void *ap)
{
  /* read-only */
}

static void
ca_moncmp_func_detach (void *ap)
{
  CAMonCmp *ca = (CAMonCmp *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
}

NORETURN(static void ca_moncmp_func_fill_data (void *ap, void *ptr));
static void
ca_moncmp_func_fill_data (void *ap, void *ptr)
{
  rb_raise(rb_eRuntimeError, "CAMonCmp is read-only (fill_data)");
}

static void
ca_moncmp_func_create_mask (void *ap)
{
  CAMonCmp *mc = (CAMonCmp *) ap;
  CArray *p = mc->parent;
  if ( ! ca_has_mask(p) ) return;

  mc->mask = (CArray *) carray_new(CA_BOOLEAN, mc->ndim, mc->dim, 0, NULL);
  ca_attach(p->mask);
  memcpy(mc->mask->ptr, p->mask->ptr, mc->elements);
  ca_detach(p->mask);
}

ca_operation_function_t ca_moncmp_func = {
  -1,
  CA_VIEW_ARRAY,
  free_ca_moncmp,
  ca_moncmp_func_clone,
  ca_moncmp_func_allocate,
  ca_moncmp_func_attach,
  ca_moncmp_func_sync,
  ca_moncmp_func_detach,
  ca_moncmp_func_fill_data,
  ca_moncmp_func_create_mask,
  ca_moncmp_func_xfer_index,
  ca_moncmp_func_xfer_addrs,
  NULL,
  ca_moncmp_func_xfer_stride,
  ca_moncmp_func_xfer_all,
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

static VALUE
rb_ca_moncmp_new (VALUE p_cary, uint16_t op_id)
{
  volatile VALUE obj;
  CArray *p;
  CAMonCmp *ca;
  rb_check_carray_object(p_cary);
  TypedData_Get_Struct(p_cary, CArray, &carray_data_type, p);
  ca  = ca_moncmp_new(p, op_id);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, p_cary);
  return obj;
}

VALUE
rb_ca_moncmp_build (VALUE p_cary, uint16_t op_id)
{
  volatile VALUE p_resolved = collapse_marker(p_cary);
  return rb_ca_moncmp_new(p_resolved, op_id);
}

static VALUE
rb_ca_moncmp_s_build (VALUE klass, VALUE p_cary, VALUE op_id_val)
{
  uint16_t op_id = (uint16_t) NUM2UINT(op_id_val);
  (void) klass;
  return rb_ca_moncmp_build(p_cary, op_id);
}

static VALUE
rb_ca_moncmp_op_id (VALUE self)
{
  CAMonCmp *mc;
  TypedData_Get_Struct(self, CAMonCmp, &camoncmp_data_type, mc);
  return UINT2NUM(mc->op_id);
}

static VALUE
rb_ca_moncmp_s_reset_scratch_counter (VALUE klass)
{
  (void) klass;
  ca_moncmp_scratch_acquire_count = 0;
  return Qnil;
}

static VALUE
rb_ca_moncmp_s_scratch_count (VALUE klass)
{
  (void) klass;
  return SIZE2NUM(ca_moncmp_scratch_acquire_count);
}

static VALUE
rb_ca_moncmp_s_reset_materialise_counter (VALUE klass)
{
  (void) klass;
  ca_moncmp_materialise_call_count = 0;
  return Qnil;
}

static VALUE
rb_ca_moncmp_s_materialise_count (VALUE klass)
{
  (void) klass;
  return SIZE2NUM(ca_moncmp_materialise_call_count);
}

static VALUE
rb_ca_moncmp_s_reset_leaf_inplace_counter (VALUE klass)
{
  (void) klass;
  ca_moncmp_leaf_inplace_count = 0;
  return Qnil;
}

static VALUE
rb_ca_moncmp_s_leaf_inplace_count (VALUE klass)
{
  (void) klass;
  return SIZE2NUM(ca_moncmp_leaf_inplace_count);
}

static VALUE
rb_ca_moncmp_s_allocate (VALUE klass)
{
  CAMonCmp *ca;
  return TypedData_Make_Struct(klass, CAMonCmp, &camoncmp_data_type, ca);
}

static VALUE
rb_ca_moncmp_initialize_copy (VALUE self, VALUE other)
{
  CAMonCmp *ca, *cs;
  TypedData_Get_Struct(self,  CAMonCmp, &camoncmp_data_type, ca);
  TypedData_Get_Struct(other, CAMonCmp, &camoncmp_data_type, cs);
  if ( ca_func[CA_OBJ_MONCMP].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_MONCMP, cs->parent->ndim);
  }
  ca_moncmp_setup(ca, cs->parent, cs->op_id);
  return self;
}

void
Init_ca_obj_moncmp (void)
{
  rb_cCAMonCmp = rb_define_class("CAMonCmp", rb_cCAView);

  ca_moncmp_func.struct_size = sizeof(CAMonCmp);
  ca_moncmp_func.pool_bytes  = ca_moncmp_pool_bytes;
  ca_moncmp_func.pool_init   = ca_moncmp_pool_init;

  CA_OBJ_MONCMP = ca_install_obj_type(rb_cCAMonCmp,
                                     &camoncmp_data_type,
                                     rb_cCArrayMask,
                                     &carray_mask_data_type, &ca_moncmp_func, sizeof(ca_moncmp_func));
  rb_define_const(rb_cObject, "CA_OBJ_MONCMP", INT2NUM(CA_OBJ_MONCMP));

  rb_define_const(rb_cCAMonCmp, "OP_IS_NAN",     INT2NUM(CA_MONCMP_IS_NAN));
  rb_define_const(rb_cCAMonCmp, "OP_IS_INF",     INT2NUM(CA_MONCMP_IS_INF));
  rb_define_const(rb_cCAMonCmp, "OP_IS_FINITE",  INT2NUM(CA_MONCMP_IS_FINITE));
  rb_define_const(rb_cCAMonCmp, "OP_IS_INVALID", INT2NUM(CA_MONCMP_IS_INVALID));
  rb_define_const(rb_cCAMonCmp, "OP_SIGNBIT",    INT2NUM(CA_MONCMP_SIGNBIT));

  rb_define_alloc_func(rb_cCAMonCmp, rb_ca_moncmp_s_allocate);
  rb_define_method(rb_cCAMonCmp, "initialize_copy",
                                rb_ca_moncmp_initialize_copy, 1);

  rb_define_singleton_method(rb_cCAMonCmp, "__build__",
                             rb_ca_moncmp_s_build, 2);

  rb_define_method(rb_cCAMonCmp, "__op_id__", rb_ca_moncmp_op_id, 0);

  rb_define_singleton_method(rb_cCAMonCmp, "__reset_scratch_counter__",
                             rb_ca_moncmp_s_reset_scratch_counter, 0);
  rb_define_singleton_method(rb_cCAMonCmp, "__scratch_count__",
                             rb_ca_moncmp_s_scratch_count, 0);
  rb_define_singleton_method(rb_cCAMonCmp, "__reset_materialise_counter__",
                             rb_ca_moncmp_s_reset_materialise_counter, 0);
  rb_define_singleton_method(rb_cCAMonCmp, "__materialise_count__",
                             rb_ca_moncmp_s_materialise_count, 0);
  rb_define_singleton_method(rb_cCAMonCmp, "__reset_leaf_inplace_counter__",
                             rb_ca_moncmp_s_reset_leaf_inplace_counter, 0);
  rb_define_singleton_method(rb_cCAMonCmp, "__leaf_inplace_count__",
                             rb_ca_moncmp_s_leaf_inplace_count, 0);
}
