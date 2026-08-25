/* ---------------------------------------------------------------------------

  CABlock: a CAStride view that exposes a rectangular sub-array of the
  parent with per-axis start / step / count.  Layout is the CAStride
  prefix (dim, strides) plus a CABlock-specific tail (start, step,
  count, size0) that captures the unstrided "what we slice from"
  geometry — needed so iterators can mutate start[] in place and so
  create_mask can reconstruct an aligned mask block.

  Storage owns 6 * ndim ca_size_t cells (dim + strides + start + step
  + count + size0), allocated either through the pool framework
  (single buffer via _pool) or, when the pool is not wired, through
  six ALLOC_N calls in ca_block_setup.  Both layouts give the same
  byte total; the pool path is preferred and the ALLOC_N fallback
  remains until all callsites are migrated.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */

extern ca_operation_function_t ca_stride_func;

VALUE rb_cCABlock;
VALUE rb_cCABlockMask;

static ca_operation_function_t ca_block_func;   /* filled at Init time */

static size_t
ca_block_dsize (const void *ap)
{
  const CABlock *ca = (const CABlock *) ap;
  return sizeof(CABlock) + 6 * ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks for CABlock.  Overrides the CAStride base
   hooks: where CAStride owns 2*ndim cells (dim + strides), CABlock
   owns 6*ndim (dim + strides + start + step + count + size0).
   CAREFUL: the first 2*ndim slots must stay layout-compatible with
   ca_stride_pool_init so the base ca_stride_setup pool branch finds
   dim / strides at the same offsets.  See
   devel/PROPOSAL_CARRAY_POOL_STANDARDIZATION.md. */
static size_t
ca_block_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return 6 * (size_t) n * sizeof(ca_size_t);
}

static void
ca_block_pool_init (void *ap, int8_t ndim)
{
  CABlock   *ca   = (CABlock *) ap;
  ca_size_t  n    = (ndim > 0) ? ndim : 1;
  ca_size_t *base = (ca_size_t *) ca->_pool;
  /* CAStride prefix (dim, strides) at offsets 0, n -- the offsets must
     match ca_stride_pool_init exactly. */
  ca->dim     = base + 0 * n;
  ca->strides = base + 1 * n;
  /* CABlock tail (start, step, count, size0). */
  ca->start   = base + 2 * n;
  ca->step    = base + 3 * n;
  ca->count   = base + 4 * n;
  ca->size0   = base + 5 * n;
}

const rb_data_type_t cablock_data_type = {
    .parent = &castride_data_type,
    .wrap_struct_name = "CABlock",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_block_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t cablock_mask_data_type = {
    .parent = &cablock_data_type,
    .wrap_struct_name = "CABlockMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_block_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */

/* Recompute base_offset from offset / start[] / size0[] / bytes.
   Public because the per-cell iterators (CABlockIterator in
   ext/ca_iter_block.c) mutate start[] in place between yields and
   need to keep the CAStride prefix consistent with the new origin. */
void
ca_block_sync_base_offset (CABlock *cb)
{
  ca_size_t n = cb->offset;
  ca_size_t suffix = 1;
  int8_t k;
  for (k = cb->ndim - 1; k >= 0; k--) {
    n += cb->start[k] * suffix;
    suffix *= cb->size0[k];
  }
  cb->base_offset = n * cb->bytes;
}

int
ca_block_setup (CABlock *ca, CArray *parent, int8_t ndim, ca_size_t *dim,
                ca_size_t *start, ca_size_t *step, ca_size_t *count,
                ca_size_t offset)
{
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t base_offset_elements;
  ca_size_t suffix;
  int8_t i;

  for (i = 0; i < ndim; i++) {
    if (count[i] < 0) {
      rb_raise(rb_eIndexError,
               "invalid size for %i-th dimension (negative)", i);
    }
  }

  /* strides[k] = step[k] * Pi_{j>k} size0[j] * parent->bytes */
  suffix = parent->bytes;
  for (i = ndim - 1; i >= 0; i--) {
    strides[i] = step[i] * suffix;
    suffix *= dim[i];   /* dim is parent->dim here (= the block's size0) */
  }

  /* base_offset (in parent elements) = offset + Sigma start[k] * Pi_{j>k} dim[j] */
  base_offset_elements = offset;
  {
    ca_size_t s = 1;
    for (i = ndim - 1; i >= 0; i--) {
      base_offset_elements += start[i] * s;
      s *= dim[i];
    }
  }

  /* CAREFUL: the CABlock tail (offset / start / step / count / size0)
     must be filled BEFORE ca_stride_setup.  ca_stride_setup may auto-
     dispatch ca_create_mask when the parent has a mask, and
     ca_block_func_create_mask reads those tail fields.

     Pool path: start/step/count/size0 already point into _pool (wired
     by ca_block_pool_init); only memcpy the values.  Non-pool path:
     ALLOC_N each first, then memcpy. */
  ca->offset = offset;
  if ( ! ca->_pool ) {
    ca->start  = ALLOC_N(ca_size_t, ndim);
    ca->step   = ALLOC_N(ca_size_t, ndim);
    ca->count  = ALLOC_N(ca_size_t, ndim);
    ca->size0  = ALLOC_N(ca_size_t, ndim);
  }
  memcpy(ca->start, start, ndim * sizeof(ca_size_t));
  memcpy(ca->step,  step,  ndim * sizeof(ca_size_t));
  memcpy(ca->count, count, ndim * sizeof(ca_size_t));
  memcpy(ca->size0, dim,   ndim * sizeof(ca_size_t));

  ca_stride_setup((CAStride *) ca, CA_OBJ_BLOCK, parent,
                  parent->data_type, parent->bytes,
                  ndim, count, strides,
                  base_offset_elements * parent->bytes);

  return 0;
}

CABlock *
ca_block_new (CArray *parent, int8_t ndim, ca_size_t *dim,
              ca_size_t *start, ca_size_t *step, ca_size_t *count,
              ca_size_t offset)
{
  CABlock *ca = (CABlock *) ca_array_alloc(CA_OBJ_BLOCK, ndim);
  ca_block_setup(ca, parent, ndim, dim, start, step, count, offset);
  return ca;
}

/* CABlock-specific free_object: cleans up the mask, then frees all
   six per-axis arrays.  Pool path consolidates them into one
   ca_array_free; non-pool path xfrees each individually.  Wired into
   ca_block_func at Init_ca_obj_block. */
static void
free_ca_block (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  if (ca == NULL) return;
  ca_free(ca->mask);
  if (ca->_pool) {
    ca_array_free(ca);
  } else {
    xfree(ca->start);
    xfree(ca->step);
    xfree(ca->count);
    xfree(ca->size0);
    xfree(ca->strides);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
ca_block_func_clone (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  return ca_block_new(ca->parent, ca->ndim, ca->size0,
                      ca->start, ca->step, ca->count, ca->offset);
}

static void
ca_block_func_create_mask (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  ca_create_mask(ca->parent);
  ca->mask =
    (CArray *) ca_block_new(ca->parent->mask,
                            ca->ndim, ca->size0,
                            ca->start, ca->step, ca->count, ca->offset);
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_block_new (VALUE cary, int8_t ndim, ca_size_t *dim,
                 ca_size_t *start, ca_size_t *step, ca_size_t *count,
                 ca_size_t offset)
{
  volatile VALUE obj;
  CArray *parent;
  CABlock *ca;

  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);

  ca = ca_block_new(parent, ndim, dim, start, step, count, offset);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);

  return obj;
}

static VALUE
rb_cb_s_allocate (VALUE klass)
{
  CABlock *ca;
  return TypedData_Make_Struct(klass, CABlock, &cablock_data_type, ca);
}

static VALUE
rb_cb_initialize_copy (VALUE self, VALUE other)
{
  CABlock *ca, *cs;
  TypedData_Get_Struct(self,  CABlock, &cablock_data_type, ca);
  TypedData_Get_Struct(other, CABlock, &cablock_data_type, cs);
  /* `self` was created by rb_cb_s_allocate (TypedData_Make_Struct) with
     ca->_pool == NULL.  Wire up the pool before ca_block_setup so the
     tail-and-prefix branches in ca_block_setup / ca_stride_setup both
     skip ALLOC_N. */
  if ( ca_func[CA_OBJ_BLOCK].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_BLOCK, cs->ndim);
  }
  ca_block_setup(ca, cs->parent, cs->ndim, cs->size0,
                 cs->start, cs->step, cs->count, cs->offset);
  rb_ca_set_parent(self, rb_ca_parent(other));
  return self;
}

/* Per-axis accessor macro: defines a method that returns the named
   CABlock tail array (size0 / start / step / count) as a Ruby Array.
   `offset` is a single Integer and uses its own accessor below. */
#define rb_cb_get_attr_ary(name)                    \
rb_cb_ ## name (VALUE self)                         \
{                                                   \
    volatile VALUE ary;                             \
    CABlock *cb;                                    \
    int8_t i;                                       \
    TypedData_Get_Struct(self, CABlock, &cablock_data_type, cb); \
    ary = rb_ary_new2(cb->ndim);                    \
    for (i=0; i<cb->ndim; i++) {                    \
      rb_ary_store(ary, i, LONG2NUM(cb->name[i]));  \
    }                                               \
    return ary;                                     \
}

static VALUE rb_cb_get_attr_ary(size0)
static VALUE rb_cb_get_attr_ary(start)
static VALUE rb_cb_get_attr_ary(step)
static VALUE rb_cb_get_attr_ary(count)

static VALUE
rb_cb_offset (VALUE self)
{
  CABlock *cb;
  TypedData_Get_Struct(self, CABlock, &cablock_data_type, cb);
  return SIZE2NUM(cb->offset);
}

/* CABlock#idx2addr0(*idx) -- map a per-axis view index tuple to the
   corresponding flat address into the parent (= "addr0").
   Equivalent to following the start[] + step[] geometry; used to
   project a view-local coordinate back onto the underlying buffer. */
static VALUE
rb_cb_idx2addr0 (int argc, VALUE *argv, VALUE self)
{
  CABlock *cb;
  ca_size_t addr;
  int8_t i;
  ca_size_t idxi;

  TypedData_Get_Struct(self, CABlock, &cablock_data_type, cb);

  if (argc != cb->ndim) {
    rb_raise(rb_eArgError,
             "invalid # of arguments (should be <%i>)", cb->ndim);
  }

  addr = 0;
  for (i=0; i<cb->ndim; i++) {
    idxi = NUM2SIZE(argv[i]);
    CA_CHECK_INDEX(idxi, cb->dim[i]);
    addr = cb->size0[i] * addr + cb->start[i] + idxi * cb->step[i];
  }

  return SIZE2NUM(addr + cb->offset);
}

/* CABlock#addr2addr0(addr) -- flat-address variant of idx2addr0: take
   a view-local flat address, unravel it via ca_addr2index, and walk
   start[]/step[] to the corresponding parent flat address. */
static VALUE
rb_cb_addr2addr0 (VALUE self, VALUE raddr)
{
  CABlock *cb;
  ca_size_t addr = NUM2SIZE(raddr);
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;

  TypedData_Get_Struct(self, CABlock, &cablock_data_type, cb);

  ca_addr2index((CArray *) cb, addr, idx);

  addr = 0;
  for (i=0; i<cb->ndim; i++) {
    addr *= cb->size0[i];
    addr += cb->start[i] + idx[i] * cb->step[i];
  }

  return SIZE2NUM(addr + cb->offset);
}

void
Init_ca_obj_block (void)
{
  /* rb_cCABlock and CA_OBJ_BLOCK are defined in ruby_carray.c /
     carray_core.c; here we override the baseline ca_stride_func entry
     with CABlock-specific free_object / clone / create_mask, plus the
     pool hooks (6*ndim, sizeof(CABlock)) so ca_array_alloc reserves
     room for the tail fields too. */
  ca_block_func = ca_stride_func;
  ca_block_func.free_object = free_ca_block;
  ca_block_func.clone       = ca_block_func_clone;
  ca_block_func.create_mask = ca_block_func_create_mask;
  ca_block_func.struct_size = sizeof(CABlock);
  ca_block_func.pool_bytes  = ca_block_pool_bytes;
  ca_block_func.pool_init   = ca_block_pool_init;
  ca_func[CA_OBJ_BLOCK] = ca_block_func;

  rb_define_const(rb_cObject, "CA_OBJ_BLOCK", INT2NUM(CA_OBJ_BLOCK));

  rb_define_alloc_func(rb_cCABlock, rb_cb_s_allocate);
  rb_define_method(rb_cCABlock, "initialize_copy", rb_cb_initialize_copy, 1);

  rb_define_method(rb_cCABlock, "size0",  rb_cb_size0, 0);
  rb_define_method(rb_cCABlock, "start",  rb_cb_start, 0);
  rb_define_method(rb_cCABlock, "step",   rb_cb_step, 0);
  rb_define_method(rb_cCABlock, "count",  rb_cb_count, 0);
  rb_define_method(rb_cCABlock, "offset", rb_cb_offset, 0);

  rb_define_method(rb_cCABlock, "idx2addr0",   rb_cb_idx2addr0, -1);
  rb_define_method(rb_cCABlock, "index2addr0", rb_cb_idx2addr0, -1);
  rb_define_method(rb_cCABlock, "addr2addr0",  rb_cb_addr2addr0, 1);
}
