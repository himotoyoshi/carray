/* ---------------------------------------------------------------------------

  The indexer: CArray#[] and #[]= plus their helpers (fill, addr2index,
  index2addr, normalize_index, scan_index).  Classifies an index spec via
  rb_ca_scan_index (forwarded to ext/carray_index_classifier.c) and
  dispatches each CA_REG_* case to the matching view constructor
  (CABlock / CASelect / CAGrid / CARemap / CASlabIterator / ...).

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */
#include "ca_obj_face.h"
#include "carray_index_classifier.h"  /* rb_ca_scan_index_v2 forward decl */

static ID id_begin, id_end, id_excl_end;
#define RANGE_BEG(r)  (rb_funcall(r, id_begin, 0))
#define RANGE_END(r)  (rb_funcall(r, id_end, 0))
#define RANGE_EXCL(r) (rb_funcall(r, id_excl_end, 0))

static ID id_to_ca;
static VALUE sym_star, sym_perc, sym_under, sym_gt, sym_tilde;
static VALUE S_CAInfo;

VALUE
rb_ca_store_index (VALUE self, ca_size_t *idx, VALUE rval)
{
  CArray *ca;
  boolean8_t zero = 0, one = 1;

  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_empty(ca) ) {
    return rval;
  }

  if ( rval == CA_UNDEF ) { /* set mask of the element at the index 'idx' */
    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    ca_store_index(ca->mask, idx, &one);
  }
  else {                   /* unset mask and set value of the element at the index 'idx' */

    /* unset mask */
    ca_update_mask(ca);
    if ( ca->mask ) {
      ca_store_index(ca->mask, idx, &zero);
    }

    /* store value */
    if ( ca->bytes <= 64) {
      char v[64];
      rb_ca_obj2ptr(self, rval, v);
      ca_store_index(ca, idx, v);
    }
    else {
      char *v = xmalloc(ca->bytes);
      rb_ca_obj2ptr(self, rval, v);
      ca_store_index(ca, idx, v);
      xfree(v);
    }
  }

  return rval;
}

VALUE
rb_ca_fetch_index (VALUE self, ca_size_t *idx)
{
  volatile VALUE out;
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_empty(ca) ) {
    return Qnil;
  }

  /* fetch value from the element */
  if ( ca->bytes <= 64) {
    char v[64];
    ca_fetch_index(ca, idx, v);
    out = rb_ca_ptr2obj(self, v);
  }
  else {
    char *v = xmalloc(ca->bytes);
    ca_fetch_index(ca, idx, v);
    out = rb_ca_ptr2obj(self, v);
    xfree(v);
  }

  /* check if the element is masked */
  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t mval;
    ca_fetch_index(ca->mask, idx, &mval);
    if ( mval ) {
      return CA_UNDEF; /* the element is masked */
    }
  }

  /* Face scalar decode (invoked if the subclass defines storage_to_scalar(raw)) */
  CA_FACE_STORAGE_TO_SCALAR_IF_FACE(out, self, ca);

  /* Boolean scalar access yields true/false, not Integer 0/1.  Bulk paths
     (to_a / cast / serialize via rb_ca_ptr2obj) keep 0/1.  Gate on the raw
     INT2FIX(0/1) so a boolean-storage Face that decoded to its own object is
     left untouched; note INT2FIX(0) is truthy in Ruby, so map by value, not
     by RTEST. */
  if ( ca->data_type == CA_BOOLEAN &&
       ( out == INT2FIX(0) || out == INT2FIX(1) ) ) {
    out = ( out == INT2FIX(1) ) ? Qtrue : Qfalse;
  }

  return out;
}

VALUE
rb_ca_store_addr (VALUE self, ca_size_t addr, VALUE rval)
{
  CArray *ca;
  boolean8_t zero = 0, one = 1;

  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_empty(ca) ) {
    return rval;
  }

  if ( rval == CA_UNDEF ) { /* set mask at the element */
    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    ca_store_addr(ca->mask, addr, &one);
  }
  else {                   /* set value at the element */
    ca_update_mask(ca);
    if ( ca->mask ) {
      ca_store_addr(ca->mask, addr, &zero); /* unset mask */
    }

    /* store value */
    if ( ca->bytes <= 64) {
      char v[64];
      rb_ca_obj2ptr(self, rval, v);
      ca_store_addr(ca, addr, v);
    }
    else {
      char *v = xmalloc(ca->bytes);
      rb_ca_obj2ptr(self, rval, v);
      ca_store_addr(ca, addr, v);
      xfree(v);
    }
  }

  return rval;
}

VALUE
rb_ca_fetch_addr (VALUE self, ca_size_t addr)
{
  volatile VALUE out;
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_empty(ca) ) {
    return Qnil;
  }

  /* fetch value from the element */
  if ( ca->bytes <= 64) {
    char v[64];
    ca_fetch_addr(ca, addr, v);
    out = rb_ca_ptr2obj(self, v);
  }
  else {
    char *v = xmalloc(ca->bytes);
    ca_fetch_addr(ca, addr, v);
    out = rb_ca_ptr2obj(self, v);
    xfree(v);
  }

  /* check if the element is masked */
  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t mval;
    ca_fetch_addr(ca->mask, addr, &mval);
    if ( mval ) {
      return CA_UNDEF; /* the element is masked */
    }
  }

  /* Face scalar decode */
  CA_FACE_STORAGE_TO_SCALAR_IF_FACE(out, self, ca);

  /* Boolean scalar access yields true/false (see rb_ca_fetch_index). */
  if ( ca->data_type == CA_BOOLEAN &&
       ( out == INT2FIX(0) || out == INT2FIX(1) ) ) {
    out = ( out == INT2FIX(1) ) ? Qtrue : Qfalse;
  }

  return out;
}

VALUE
rb_ca_fill (VALUE self, VALUE rval)
{
  CArray *ca;

  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_empty(ca) ) {
    return self;                /* empty = no-op fill; return self for chaining */
  }

  if ( rval == CA_UNDEF ) {
    boolean8_t one = 1;
    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    ca_fill(ca->mask, &one);
  }
  else {
    char *fval = xmalloc(ca->bytes);
    boolean8_t zero = 0;
    rb_ca_obj2ptr(self, rval, fval);
    if ( ca_has_mask(ca) ) {
      ca_fill(ca->mask, &zero);
    }
    ca_fill(ca, fval);
    xfree(fval);
  }

  return self;
}

VALUE
rb_ca_fill_copy (VALUE self, VALUE rval)
{
  volatile VALUE out = rb_ca_template(self);
  return rb_ca_fill(out, rval);
}

/* -------------------------------------------------------------------- */

static void
ary_guess_shape (VALUE ary, int level, int *max_level, ca_size_t *dim)
{
  volatile VALUE ary0;
  if ( level > CA_RANK_MAX ) {
    rb_raise(rb_eRuntimeError, "too deep level array for conversion to carray");
  }

  if ( TYPE(ary) == T_ARRAY ) {
    if ( RARRAY_LEN(ary) == 0 && level == 0 ) {
      *max_level = level;
      dim[level] = 0;
    }
    else if ( RARRAY_LEN(ary) > 0 ) {
      *max_level = level;
      dim[level] = RARRAY_LEN(ary);
      ary0 = rb_ary_entry(ary, 0);
      if ( TYPE(ary0) == T_ARRAY ) {
        ca_size_t dim0 = RARRAY_LEN(ary0);
        ca_size_t i;
        int flag = 0;
        for (i=0; i<dim[level]; i++) {
          VALUE x = rb_ary_entry(ary, i);
          flag = flag || ( TYPE(x) != T_ARRAY ) || ( dim0 != RARRAY_LEN(x) );
        }
        if ( ! flag ) {
          ary_guess_shape(ary0, level+1, max_level, dim);
        }
      }
    }
  }
}

static VALUE
rb_ca_s_guess_array_shape (VALUE self, VALUE ary)
{
  volatile VALUE out;
  ca_size_t dim[CA_RANK_MAX];
  int max_level = -1;
  int i;
  ary_guess_shape(ary, 0, &max_level, dim);
  out = rb_ary_new2(max_level);
  for (i=0; i<max_level+1; i++) {
    rb_ary_store(out, i, SIZE2NUM(dim[i]));
  }
  return out;
}

static void
ary_flatten_upto_level (VALUE ary, int max_level, int level,
                        VALUE out, int *len)
{
  int32_t i;

  if ( TYPE(ary) != T_ARRAY ) {
    rb_raise(rb_eRuntimeError, "invalid shape array for conversion to carray");
  }

  if ( level == max_level ) {
    *len += RARRAY_LEN(ary);
    for (i=0; i<RARRAY_LEN(ary); i++) {
      rb_ary_push(out, rb_ary_entry(ary, i));
    }
  }
  else {
    for (i=0; i<RARRAY_LEN(ary); i++) {
      VALUE x = rb_ary_entry(ary, i);
      ary_flatten_upto_level(x, max_level, level+1, out, len);
    }
  }
}

static VALUE
rb_ary_flatten_for_elements (VALUE ary, ca_size_t elements, void *ap)
{
  CArray *ca = (CArray *) ap;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t total;
  int max_level = -1, level = -1;
  int same_shape, is_object = ( ca_is_object_type(ca) );
  int i;

  ary_guess_shape(ary, 0, &max_level, dim);

  if ( max_level == -1 ) {
    return Qnil;
  }

  if ( ! ca_is_object_type(ca) ) {
    total = 1;
    for (i=0; i<max_level+1; i++) {
      total *= dim[i];
      level = i;
      if ( is_object && total == elements ) {
        break;
      }
    }

    if ( total != ca->elements ) {
      rb_raise(rb_eRuntimeError, "invalid shape array for conversion to carray");
    }
    else {
      volatile VALUE out = rb_ary_new2(0);
      int len = 0;
      ary_flatten_upto_level(ary, max_level, 0, out, &len);
      if ( len != elements ) {
        return Qnil;
      }
      else {
        return out;
      }
    }
  }
  else {
    same_shape = 1;
    if ( max_level+1 < ca->ndim ) {
      same_shape = 0;
    }
    else {
      for (i=0; i<ca->ndim; i++) {
        if ( ca->dim[i] != dim[i] ) {
          same_shape = 0;
          break;
        }
      }
    }

    if ( same_shape ) {
      volatile VALUE out = rb_ary_new2(0);
      int len = 0;
      ary_flatten_upto_level(ary, ca->ndim-1, 0, out, &len);

      if ( len != elements ) {
        return Qnil;
      }
      else {
        return out;
      }
    }
    else {
      total = 1;
      for (i=0; i<max_level+1; i++) {
        total *= dim[i];
        level = i;
        if ( is_object && total == elements ) {
          break;
        }
      }

      if ( level >= 0 ) {
        volatile VALUE out = rb_ary_new2(0);
        int len = 0;
        ary_flatten_upto_level(ary, level, 0, out, &len);
        if ( len != elements ) {
          return Qnil;
        }
        else {
          return out;
        }
      }
      else {
        return Qnil;
      }
    }
  }
}

#define CA_CHECK_INDEX_AT(index, dim, i)                                \
  if ( index < 0 ) {                                                    \
    index += (dim);                                                     \
  }                                                                     \
  if ( index < 0 || index >= (dim) ) {                                  \
    rb_raise(rb_eIndexError,                                            \
             "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",        \
             i, (ca_size_t) index, (ca_size_t) (dim-1));                                          \
  }

void
rb_ca_scan_index (int ca_ndim, ca_size_t *ca_dim, ca_size_t ca_elements,
                  long argc, VALUE *argv, CAIndexInfo *info)
{
  /* Forwards to the v2 classifier in ext/carray_index_classifier.c. */
  rb_ca_scan_index_v2(ca_ndim, ca_dim, ca_elements, argc, argv, info);
}

/* ----------------------------------------------------------------------- */

static VALUE
rb_ca_ref_address (VALUE self, CAIndexInfo *info)
{
  ca_size_t addr;
  addr = info->index[0].scalar;
  return rb_ca_fetch_addr(self, addr);
}

static VALUE
rb_ca_store_address (VALUE self, CAIndexInfo *info, volatile VALUE rval)
{
  ca_size_t addr;
  addr = info->index[0].scalar;
  if ( rb_obj_is_cscalar(rval) ) {
    rval = rb_ca_fetch_addr(rval, 0);
  }
  rb_ca_store_addr(self, addr, rval);
  return rval;
}

static VALUE
rb_ca_ref_point (VALUE self, CAIndexInfo *info)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  for (i=0; i<ca->ndim; i++) {
    idx[i] = info->index[i].scalar;
  }
  return rb_ca_fetch_index(self, idx);
}

static VALUE
rb_ca_store_point (VALUE self, CAIndexInfo *info, volatile VALUE val)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  for (i=0; i<ca->ndim; i++) {
    idx[i] = info->index[i].scalar;
  }
  if ( rb_obj_is_cscalar(val) ) {
    val = rb_ca_fetch_addr(val, 0);
  }
  rb_ca_store_index(self, idx, val);
  return val;
}

static VALUE
rb_ca_ref_all (VALUE self, CAIndexInfo *info)
{
  return rb_funcall(self, rb_intern("refer"), 0);
}

VALUE
rb_ca_store_all (VALUE self, VALUE rval)
{
  CArray *ca;

  rb_ca_modify(self);

  if ( self == rval || rb_ca_is_empty(self) ) {
    return rval;
  }
  
  if ( rb_obj_is_cscalar(rval) ) {
    rval = rb_ca_fetch_addr(rval, 0);
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

 retry:

  if ( rb_obj_is_carray(rval) ) {
    CArray *cv;
    TypedData_Get_Struct(rval, CArray, &carray_data_type, cv);

    if ( cv->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
      rval = ca_ubrep_bind_with(rval, self);
      TypedData_Get_Struct(rval, CArray, &carray_data_type, cv);
    }

    /* The destination owns the shape; see ca_broadcast_to_destination. */
    ca_broadcast_to_destination(self, &rval);
    TypedData_Get_Struct(rval, CArray, &carray_data_type, cv);

    /* Source delivery via ca_xfer_all into a local scratch instead of
       ca_attach(cv).  This routes through ca_*_func_xfer_all's per-region
       partial-materialise path, avoiding a ca_attach(root) silent
       transitive attach.  When cv composes through a view root (CAFake /
       CAByteSwap / CAGrid / etc.), attaching the root would materialise
       the whole root (size = root->elements * root->bytes), producing a
       catastrophic slowdown for size-gap cases like
       big_virtual[100..200] = big_virtual[100..200].flip(0).  The scratch
       here is sized for cv only (cv->elements * cv->bytes), so the cost
       scales with the view, not the root.  (The dst-side ca_sync_data is
       already an xfer_all PUT.) */
    {
      volatile VALUE scratch_holder;
      ca_size_t      cv_bytes = cv->bytes * cv->elements;
      char          *scratch  = ALLOCV_N(char, scratch_holder, cv_bytes);
      ca_xfer_all(cv, scratch, CA_XFER_GET);

      if ( ca->data_type != cv->data_type ) {
        ca_allocate(ca);
        ca_copy_mask_overwrite(ca, ca->elements, 1, cv);
        if ( ca->mask ) {
          ca_cast_block_with_mask(ca->elements, cv, scratch, ca, ca->ptr,
                                  (boolean8_t*)ca->mask->ptr);
        }
        else {
          ca_cast_block(ca->elements, cv, scratch, ca, ca->ptr);
        }
        ca_sync(ca);
        ca_detach(ca);
      }
      else {
        ca_copy_mask_overwrite(ca, ca->elements, 1, cv);
        ca_sync_data(ca, scratch);
      }

      ALLOCV_END(scratch_holder);
    }
  }
  else if ( TYPE(rval) == T_ARRAY ) {
    volatile VALUE list =
                 rb_ary_flatten_for_elements(rval, ca->elements, ca);
    ca_size_t i;
    if ( NIL_P(list) ) {
      rb_raise(rb_eRuntimeError,
               "failed to guess data size of given array");
    }
    else {
      int has_mask = 0;
      CArray ico;
      /* ca_cast_block reads ca_is_face(ca1), so flags must be 0-initialised. */
      memset(&ico, 0, sizeof(CArray));
      ico.data_type = CA_OBJECT;
      ico.bytes     = ca_sizeof[CA_OBJECT];
      for (i=0; i<ca->elements; i++) {
        if ( rb_ary_entry(list,i) == CA_UNDEF ) {
          has_mask = 1;
          ca_create_mask(ca);
          break;
        }
      }
      /* Use ca_allocate() instead of ca_attach() here because rb_ca_store_all()
         overwrites ALL elements of the array from a Ruby Array. There is no need
         to copy parent data (which ca_attach would do), since every element will
         be replaced. Mask handling is also safe: ca_create_mask() above and
         ca_copy_mask_overwrite() handle mask allocation and propagation internally,
         so ca_allocate()'s simpler path (no parent data copy) is sufficient. */
      ca_allocate(ca);
      {
        /* Face has surface != storage; the cast runs in the storage
           data_type.  Passing ca directly makes the cast table see FIXLEN
           and report non-implemented, so pass a shadow CArray (storage
           data_type, ptr aliased to ca). */
        CArray shadow;
        CArray *cast_target = ca;
        memset(&shadow, 0, sizeof(CArray));
        if ( ca_is_face(ca) ) {
          CArray *root = ca;
          while (root && ca_is_face(root)) root = ((CAView *) root)->parent;
          if (root) {
            shadow.data_type = root->data_type;
            shadow.bytes     = ca->bytes;
            shadow.elements  = ca->elements;
            shadow.ptr       = ca->ptr;
            cast_target = &shadow;
          }
        }
        if ( has_mask ) {
          boolean8_t *m;
          m = (boolean8_t *)ca->mask->ptr;
          for (i=0; i<ca->elements; i++) {
            if ( rb_ary_entry(list,i) == CA_UNDEF ) {
              *m = 1;
            }
            else {
              *m = 0;
            }
            m++;
          }
          ca_cast_block_with_mask(ca->elements, &ico, (VALUE *)RARRAY_CONST_PTR(list),
                                  cast_target, ca->ptr,
                                  (boolean8_t*)ca->mask->ptr);
        }
        else {
          ca_cast_block(ca->elements, &ico, (VALUE *)RARRAY_CONST_PTR(list), cast_target, ca->ptr);
        }
      }
      ca_sync(ca);
      ca_detach(ca);
    }
  }
  else if ( rb_respond_to(rval, id_to_ca) ) {
    rval = rb_funcall(rval, id_to_ca, 0);
    goto retry;
  }
  else {
    rb_ca_fill(self, rval);
  }

  return rval;
}

static void
rb_ca_index_restruct_block (int16_t *ndimp, ca_size_t *shrink, ca_size_t *dim,
                            ca_size_t *start, ca_size_t *step, ca_size_t *count,
                            ca_size_t *offsetp)
{
  ca_size_t dim0[CA_RANK_MAX];
  ca_size_t start0[CA_RANK_MAX];
  ca_size_t step0[CA_RANK_MAX];
  ca_size_t count0[CA_RANK_MAX];
  ca_size_t idx[CA_RANK_MAX];
  int16_t ndim0, ndim;
  ca_size_t offset0, offset, length;
  ca_size_t k, n;
  ca_size_t i, j, m;

  ndim0   = *ndimp;
  offset0 = *offsetp;

  /* store original start, step, count to start0, step0, count0 */
  memcpy(dim0,   dim,   sizeof(ca_size_t) * ndim0);
  memcpy(start0, start, sizeof(ca_size_t) * ndim0);
  memcpy(step0,  step,  sizeof(ca_size_t) * ndim0);
  memcpy(count0, count, sizeof(ca_size_t) * ndim0);

  /* classify and calc ndim */
  n = -1;
  for (i=0; i<ndim0; i++) {
    if ( ! shrink[i] ) {
      n += 1;
    }
    idx[i] = n;
  }
  ndim = n + 1;

  *ndimp = ndim;

  /* calc offset */

  offset = 0;

  if ( idx[0] == -1 ) {
    j = 0;
    while ( idx[++j] ) {
      ;
    }

    offset = start0[0];
    for (i=1; i<j; i++) {
      offset = offset * dim0[i] + start0[i];
    }

    length = 1;
    for (i=j; i<ndim0; i++) {
      length *= dim0[i];
    }

    offset *= length;
  }

  *offsetp = offset0 + offset;

  /* calc dim, start, step, count */

  for (i=0; i<ndim0; i++) {
    n = idx[i];
    if ( n == -1) {
      continue;
    }

    for (j=i+1, m=i; j<ndim0 && (idx[j] == n); j++) {
      ;
    }

    dim[n] = 1;
    for (k=m; k<j; k++) {
      dim[n] *= dim0[k];
    }

    start[n] = start0[m];
    step[n]  = step0[m];
    count[n] = count0[m];
    for (k=m+1; k<j; k++) {
      start[n] = start[n] * dim0[k] + start0[k];
      step[n]  = step[n]  * dim0[k];
      count[n] = count[n] * count0[k];
    }

    i = j - 1;
  }

}

VALUE
rb_ca_ref_block (VALUE self, CAIndexInfo *info)
{
  volatile VALUE refer;
  CArray *ca;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t start[CA_RANK_MAX];
  ca_size_t step[CA_RANK_MAX];
  ca_size_t count[CA_RANK_MAX];
  ca_size_t shrink[CA_RANK_MAX];
  int16_t ndim = 0;
  ca_size_t offset = 0;
  ca_size_t flag = 0;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  ndim = info->ndim;

  for (i=0; i<info->ndim; i++) {
    dim[i] = ca->dim[i];
  }

  for (i=0; i<info->ndim; i++) {
    switch ( info->index_type[i] ) {
    case CA_IDX_SCALAR:
      start[i]  = info->index[i].scalar;
      step[i]   = 1;
      count[i]  = 1;
      shrink[i] = 1;
      break;
    case CA_IDX_ALL:
      start[i]  = 0;
      step[i]   = 1;
      count[i]  = ca->dim[i];
      shrink[i] = 0;
      break;
    case CA_IDX_BLOCK:
      start[i]  = info->index[i].block.start;
      step[i]   = info->index[i].block.step;
      count[i]  = info->index[i].block.count;
      shrink[i] = 0;
      break;
    }
  }

  for (i=0; i<ndim; i++) {
    if ( shrink[i] ) {
      flag = 1;
      break;
    }
  }

  refer = self;
  ndim  = ca->ndim;

  offset = 0;

  if ( flag ) {
    rb_ca_index_restruct_block(&ndim, shrink,
                              dim, start, step, count, &offset);
  }

  {
    volatile VALUE blk;
    blk = rb_ca_block_new(refer, ndim, dim, start, step, count, offset);
    /* The block inherits the Face source's FIXLEN surface; rewrite its
       data_type to the storage data_type (chain bottom) so the write path
       casts in the storage type. */
    if ( ca_is_face(ca) ) {
      CArray *blk_ca, *root = ca;
      TypedData_Get_Struct(blk, CArray, &carray_data_type, blk_ca);
      while (root && ca_is_face(root)) root = ((CAView *) root)->parent;
      if (root && root->data_type != blk_ca->data_type) {
        blk_ca->data_type = root->data_type;
      }
    }
    return blk;
  }
}

static VALUE
rb_ca_refer_new_flatten (VALUE self)
{
  CArray *ca;
  ca_size_t dim0;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  dim0 = ca->elements;
  return rb_ca_refer_new(self, ca->data_type, 1, &dim0, ca->bytes, 0);
}

/* CARemap routing: when self and mapper have identical shape AND
   mapper's data_type is CA_SIZE, take the same-shape per-element gather
   fast path.  Defined in ca_obj_remap.c. */
extern VALUE rb_ca_remap_new (VALUE cary, VALUE rmapper);

/* a[mapper] is semantically equivalent to
   a.flatten[mapper.flatten].reshape(*mapper.dim).

   Two routes:
     (a) Same-shape + CA_SIZE mapper -> CARemap view (fast path, avoids
         building the flatten/gather/reshape chain).
     (b) Otherwise -> normalize chain (a.flatten[mapper.flatten]
         .reshape).  A 1-D mapper is already routed to CAGrid upstream.

   Both routes raise on a masked mapper. */
static VALUE
rb_ca_fancy_index_chain (VALUE self, VALUE rmapper)
{
  CArray *ca, *cm;
  volatile VALUE flat_self, flat_mapper, gridded, result;
  VALUE grid_argv[1];
  int i;

  TypedData_Get_Struct(self,    CArray, &carray_data_type, ca);
  TypedData_Get_Struct(rmapper, CArray, &carray_data_type, cm);

  if ( ca_is_any_masked(cm) ) {
    rb_raise(rb_eArgError, "mapper in ca[mapper] should not be masked");
  }

  /* (a) same-shape fast path: ndim + per-axis dim + CA_SIZE data_type. */
  if ( cm->data_type == CA_SIZE
    && cm->ndim == ca->ndim
    && memcmp(cm->dim, ca->dim, ca->ndim * sizeof(ca_size_t)) == 0 ) {
    return rb_ca_remap_new(self, rmapper);
  }

  /* (b) Normalize chain fallback. */
  flat_self    = rb_ca_refer_new_flatten(self);
  flat_mapper  = (cm->ndim == 1) ? rmapper : rb_ca_flatten(rmapper);
  grid_argv[0] = flat_mapper;
  gridded      = rb_ca_grid(1, grid_argv, flat_self);

  if ( cm->ndim == 1 ) {
    result = gridded;
  }
  else {
    VALUE *dim_argv = ALLOCA_N(VALUE, cm->ndim);
    for (i = 0; i < cm->ndim; i++) {
      dim_argv[i] = SIZE2NUM(cm->dim[i]);
    }
    result = rb_ca_reshape(cm->ndim, dim_argv, gridded);
  }
  return result;
}

/* The CAMapping class is gone; rb_ca_mapping_new and rb_ca_mapping build
   the normalize chain via rb_ca_fancy_index_chain.  The public C API
   signatures are preserved so external ext gems keep linking; the runtime
   class of the returned VALUE is CARefer (chain outermost), not CAMapping. */

VALUE
rb_ca_mapping_new (VALUE cary, CArray *mapper)
{
  CArray *m_copy = ca_copy(mapper);
  volatile VALUE rmapper = ca_wrap_struct(m_copy);
  return rb_ca_fancy_index_chain(cary, rmapper);
}

VALUE
rb_ca_mapping (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rmapper;
  rb_scan_args(argc, argv, "1", (VALUE *) &rmapper);
  rb_check_carray_object(rmapper);
  return rb_ca_fancy_index_chain(self, rmapper);
}

/* ------------------------------------------------------------------- */
/* newaxis (:_) sugar.  `:_` inserts a size-1 axis at its position.
   Strategy: strip `:_`, fetch the remaining per-axis indices into a base
   view, then reshape the base inserting size-1 axes.  reshape inherits
   the optimal view class (CAStride for stride bases, CARefer for fancy
   bases). */

static int
ca_argv_has_newaxis (int argc, VALUE *argv)
{
  int i;
  for (i = 0; i < argc; i++) {
    if ( argv[i] == sym_under ) return 1;
  }
  return 0;
}

static int
ca_argv_has_slab_sigil (int argc, VALUE *argv)
{
  int i;
  for (i = 0; i < argc; i++) {
    if ( argv[i] == sym_gt ) return 1;
  }
  return 0;
}

static VALUE rb_ca_fetch_newaxis (int argc, VALUE *argv, VALUE self,
                                  CArray *ca);
static VALUE rb_ca_slab_iter_new (VALUE self, CAIndexInfo *info);
static VALUE rb_ca_fetch_slab_sigil (int argc, VALUE *argv, VALUE self);

/* axis-group apply (ext/ca_group_iter.c): type gate that routes a
   CACategorical/AxisGroup index to the group path. */
int   ca_argv_has_group (int argc, VALUE *argv);
VALUE rb_ca_fetch_group (int argc, VALUE *argv, VALUE self);

static VALUE
rb_ca_fetch_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj = Qnil;
  CArray *ca;
  CAIndexInfo info;

 retry:

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* newaxis (:_) interception (cheap pointer scan; zero overhead beyond
     the loop when no :_ is present). */
  if ( ca_argv_has_newaxis(argc, argv) ) {
    return rb_ca_fetch_newaxis(argc, argv, self, ca);
  }

  /* slab sigil (:>) interception.  Pre-strip :> -> nil and Integer ->
     length-1 Range so mask / fancy outer slots route through the regular
     dispatch (CA_REG_SELECT / CA_REG_GRID / CA_REG_MAPPING) before being
     wrapped in CASlabIterator. */
  if ( ca_argv_has_slab_sigil(argc, argv) ) {
    return rb_ca_fetch_slab_sigil(argc, argv, self);
  }

  /* Axis-group type gate: a CACategorical/AxisGroup index routes to the
     group apply path (CAGroupIterator); plain int-array indices fall
     through to the regular selection dispatch below.  The scan short-circuits
     when the surface classes have not been loaded, so a normal index pays
     nothing. */
  if ( ca_argv_has_group(argc, argv) ) {
    return rb_ca_fetch_group(argc, argv, self);
  }

  info.range_check = 1;
  rb_ca_scan_index(ca->ndim, ca->dim, ca->elements, argc, argv, &info);

  switch ( info.type ) {
  case CA_REG_ADDRESS_COMPLEX:
    /* Re-enter against a flattened view of self.  rb_ca_refer_new_flatten
       is an internal builder and hands back a bare refer, so a marker
       receiver would be dropped here and the result would never be lifted
       at the tail.  Put it back on before the re-entry.  (A Face survives
       on its own -- the internal builder still lifts those.) */
    self = rb_ca_refer_new_flatten(self);
    if ( ca_is_lazy_marker(ca) ) {
      extern VALUE rb_ca_lazy_marker_new (VALUE cary);
      self = rb_ca_lazy_marker_new(self);
    }
    goto retry;
  case CA_REG_ADDRESS:
    obj = rb_ca_ref_address(self, &info);
    break;
  case CA_REG_FLATTEN:
    obj = rb_ca_refer_new_flatten(self);
    break;
  case CA_REG_POINT:
    obj = rb_ca_ref_point(self, &info);
    break;
  case CA_REG_ALL:
    obj = rb_ca_ref_all(self, &info);
    break;
  case CA_REG_BLOCK:
    obj = rb_ca_ref_block(self, &info);
    break;
  case CA_REG_SELECT:
    obj = rb_ca_select_new(self, argv[0]);
    break;
  case CA_REG_ITERATOR:
    obj = rb_ca_slab_iter_new(self, &info);
    break;
  case CA_REG_REPEAT:
    obj = rb_ca_repeat(argc, argv, self);
    break;
  case CA_REG_UNBOUND_REPEAT:
    obj = rb_funcall2(self, rb_intern("unbound_repeat"), (int) argc, argv);
    break;
  case CA_REG_MAPPING:
    obj = rb_ca_fancy_index_chain(self, argv[0]);
    break;
  case CA_REG_GRID:
    obj = rb_ca_grid(argc, argv, self);
    break;
  case CA_REG_METHOD_CALL: {
    volatile VALUE idx;
    idx = rb_funcall2(self, SYM2ID(info.symbol), argc-1, argv+1);
    obj = rb_ca_fetch(self, idx);
    break;
  }
  case CA_REG_MEMBER: {
    volatile VALUE data_class = rb_ca_data_class(self);
    if ( ! NIL_P(data_class) ) {
      /* Field projection strips Face and returns a CAField on the parent
         (= a different data_type).  Do not re-wrap with Face (CARecord
         wraps structs only; a field view like float64 is not a CARecord).
         Early-return to bypass the trailing ca_face_lift. */
      return rb_ca_face_field(self, info.symbol);
    }
    else {
      rb_raise(rb_eIndexError,
               "can't refer member of carray doesn't have data_class");
    }
    break;
  }
  case CA_REG_ATTRIBUTE: {
    obj = rb_funcall(self, rb_intern("attribute"), 0);
    obj = rb_hash_aref(obj, info.symbol);
    break;
  }
  default:
    rb_raise(rb_eIndexError, "invalid index specified");
  }

  /* Wrapper lift at the read touch point: if `self` is a Face or a
     CALazyMarker, re-wrap the view result so the wrapper stays on top.
     Guarded to CArray results, which drops the scalar / CASlabIterator /
     CAGroupIterator / Hash cases the switch above can produce.  The
     already-a-Face case (some builders lift their own result) is handled
     inside ca_wrapper_lift.

     Every CA_REG_* branch converges here, so this one line covers all of
     them -- but not every index form: `a[:*, nil]` builds a CAUnboundRepeat,
     whose shape stays open until an operand binds it, and a marker copies
     shape at construction.  ca_wrapper_lift refuses that one, in one place,
     because `unbound_repeat` reaches it by a second route. */
  CA_WRAPPER_LIFT(obj, self, ca);

  return obj;
}

/* newaxis (:_) implementation (reshape).  See the forward decl + the
   interception hook in rb_ca_fetch_method.  Pre-condition: argv contains
   at least one sym_under. */
static VALUE
rb_ca_fetch_newaxis (int argc, VALUE *argv, VALUE self, CArray *ca)
{
  int i;
  int nclean = 0;
  VALUE clean[CA_RANK_MAX];
  volatile VALUE base;
  ca_size_t final_dims[CA_RANK_MAX];
  int nfinal = 0;
  int base_cursor;
  CArray *cb;
  VALUE dim_argv[CA_RANK_MAX];

  /* Build clean argv (strip :_); reject disjoint sigils + rubber dim. */
  for (i = 0; i < argc; i++) {
    VALUE a = argv[i];
    if ( a == sym_under ) continue;
    if ( a == sym_gt || a == sym_star || a == sym_perc
         || a == Qfalse || a == sym_tilde ) {
      rb_raise(rb_eIndexError,
               "newaxis (:_) cannot be combined with :>, :*, :%%, "
               "or rubber dim (false / :~)");
    }
    if ( nclean >= CA_RANK_MAX ) {
      rb_raise(rb_eIndexError, "too many indices");
    }
    clean[nclean++] = a;
  }

  /* newaxis requires full per-axis indexing (CArray uses flat addressing
     for partial indices, which is incoherent with axis-position newaxis). */
  if ( nclean != ca->ndim ) {
    rb_raise(rb_eIndexError,
             "newaxis (:_) requires full per-axis indexing "
             "(got %d non-:_ indices for ndim %d)",
             nclean, (int) ca->ndim);
  }

  base = rb_ca_fetch_method(nclean, clean, self);

  /* Degenerate: all real axes scalar -> base is a scalar element, not a
     CArray.  Out of scope (rare + degenerate); user indexes the element
     and reshapes explicitly.  IndexError keeps it catchable + consistent
     with the other newaxis rejects. */
  if ( ! rb_obj_is_kind_of(base, rb_cCArray) ) {
    rb_raise(rb_eIndexError,
             "newaxis (:_) needs at least one non-scalar axis "
             "(all-scalar indexing yields a single element)");
  }

  TypedData_Get_Struct(base, CArray, &carray_data_type, cb);

  /* Reconstruct final shape: walk original argv.  :_ -> size-1, scalar
     (Integer) -> dropped (skip), else -> base.dim[cursor]. */
  base_cursor = 0;
  for (i = 0; i < argc; i++) {
    VALUE a = argv[i];
    if ( a == sym_under ) {
      final_dims[nfinal++] = 1;
    }
    else if ( FIXNUM_P(a) || RB_TYPE_P(a, T_BIGNUM) ) {
      /* scalar index -> axis dropped in base; contributes no output axis */
    }
    else {
      if ( base_cursor >= cb->ndim ) {
        rb_raise(rb_eIndexError, "newaxis: base axis count mismatch");
      }
      final_dims[nfinal++] = cb->dim[base_cursor++];
    }
  }
  if ( base_cursor != cb->ndim ) {
    rb_raise(rb_eIndexError, "newaxis: base axis count mismatch");
  }

  for (i = 0; i < nfinal; i++) {
    dim_argv[i] = SIZE2NUM(final_dims[i]);
  }
  return rb_ca_reshape(nfinal, dim_argv, base);
}

/* Build a CASlabIterator from a classified ITERATOR index.  The
   `:>` axes (CA_IDX_SYMBOL) become the slab axes; they are converted to
   CA_IDX_ALL so rb_ca_ref_block yields the sliced base view keeping all
   axes (scalars are already length-1 BLOCKs via the finalize_reg post-
   pass).  CASlabIterator delegates to each_slab / map_slab / reduce_slab. */
static VALUE
rb_ca_slab_iter_new (VALUE self, CAIndexInfo *info)
{
  volatile VALUE slab_axes = rb_ary_new();
  volatile VALUE base;
  volatile VALUE klass;
  int i;

  for (i = 0; i < info->ndim; i++) {
    if ( info->index_type[i] == CA_IDX_SYMBOL ) {
      rb_ary_push(slab_axes, INT2NUM(i));
      info->index_type[i] = CA_IDX_ALL;   /* :> axis -> full range */
    }
  }

  base  = rb_ca_ref_block(self, info);
  klass = rb_const_get(rb_cObject, rb_intern("CASlabIterator"));
  return rb_funcall(klass, rb_intern("new"), 2, base, slab_axes);
}

/* Slab sigil dispatcher that supports any outer-slot index type
   (Integer / Range / nil / boolean mask / CArray / Symbol-method etc.).
   Strategy: expand rubber dim (false / :~) if present so :> positions
   align with the post-expansion ndim, replace :> with nil (full axis),
   promote Integer to length-1 Range so the base view preserves ndim,
   recurse through the regular indexer dispatch to build the base
   reference (CABlock / CASelectAxis / CAGrid / CAMapping / ...), then
   wrap in CASlabIterator with the recorded slab_axes positions. */
static VALUE
rb_ca_fetch_slab_sigil (int argc, VALUE *argv, VALUE self)
{
  VALUE expanded[CA_RANK_MAX];
  VALUE clean[CA_RANK_MAX];
  volatile VALUE slab_axes = rb_ary_new();
  volatile VALUE base;
  volatile VALUE klass;
  CArray *ca;
  int i, j;
  int eargc;
  VALUE *eargv;
  int rubber_pos = -1;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Rubber-dim expansion (mirrors ca_classifier_expand_rubber_dim).
     Only the first rubber marker is honoured; later ones are left for
     the regular classifier to reject downstream. */
  for (i = 0; i < argc; i++) {
    if ( argv[i] == Qfalse || argv[i] == sym_tilde ) {
      rubber_pos = i;
      break;
    }
  }
  if ( rubber_pos < 0 ) {
    eargc = argc;
    eargv = argv;
  }
  else {
    int rndim;
    if ( argc > ca->ndim + 1 ) {
      rb_raise(rb_eIndexError,
               "index specification exceeds the ndim of carray (%i)",
               ca->ndim);
    }
    rndim = ca->ndim - argc + 1;
    if ( rndim < 0 ) rndim = 0;
    j = 0;
    for (i = 0; i < argc; i++) {
      if ( i == rubber_pos ) {
        int k;
        for (k = 0; k < rndim; k++) expanded[j++] = Qnil;
      }
      else {
        expanded[j++] = argv[i];
      }
    }
    eargc = j;
    eargv = expanded;
  }

  if ( eargc > CA_RANK_MAX ) {
    rb_raise(rb_eIndexError, "too many indices");
  }

  for (i = 0; i < eargc; i++) {
    VALUE a = eargv[i];
    if ( a == sym_gt ) {
      rb_ary_push(slab_axes, INT2NUM(i));
      clean[i] = Qnil;
    }
    else if ( FIXNUM_P(a) || RB_TYPE_P(a, T_BIGNUM) ) {
      /* Promote Integer to length-1 Range so the recursed view keeps
         the axis (matches the existing :> dispatcher semantics where
         scalars become length-1 BLOCKs via finalize_reg). */
      clean[i] = rb_range_new(a, a, 0);
    }
    else {
      clean[i] = a;
    }
  }

  base = rb_ca_fetch_method(eargc, clean, self);
  if ( ! rb_obj_is_kind_of(base, rb_cCArray) ) {
    rb_raise(rb_eIndexError,
             "slab sigil (:>) requires the base view to be a CArray");
  }
  klass = rb_const_get(rb_cObject, rb_intern("CASlabIterator"));
  return rb_funcall(klass, rb_intern("new"), 2, base, slab_axes);
}

static VALUE
rb_cs_fetch_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj = Qnil;
  CArray *ca;
  CAIndexInfo info;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  info.range_check = 0;
  rb_ca_scan_index(ca->ndim, ca->dim, ca->elements, argc, argv, &info);

  switch ( info.type ) {
  case CA_REG_ADDRESS_COMPLEX:
    obj = rb_ca_fetch_addr(self, 0);
    break;
  case CA_REG_ADDRESS:
    obj = rb_ca_fetch_addr(self, 0);
    break;
  case CA_REG_FLATTEN:
    obj = self; /* rb_funcall(self, rb_intern("refer"), 0); */
    break;
  case CA_REG_POINT:
    obj = rb_ca_fetch_addr(self, 0);
    break;
  case CA_REG_ALL:
    obj = self; /* rb_funcall(self, rb_intern("refer"), 0); */
    break;
  case CA_REG_BLOCK:
    obj = self; /* rb_funcall(self, rb_intern("refer"), 0); */
    break;
  case CA_REG_SELECT:
    obj = rb_ca_select_new(self, argv[0]);
    break;
  case CA_REG_ITERATOR:
    obj = rb_ca_slab_iter_new(self, &info);
    break;
  case CA_REG_REPEAT:
    obj = rb_ca_repeat(argc, argv, self);
    break;
  case CA_REG_UNBOUND_REPEAT:
    obj = rb_funcall2(self, rb_intern("unbound_repeat"), (int) argc, argv);
    break;
  case CA_REG_MAPPING:
    obj = rb_ca_fancy_index_chain(self, argv[0]);
    break;
  case CA_REG_GRID:
    obj = rb_ca_grid(argc, argv, self);
    break;
  case CA_REG_METHOD_CALL: {
    volatile VALUE idx;
    idx = rb_funcall2(self, SYM2ID(info.symbol), argc-1, argv+1);
    obj = rb_ca_fetch(self, idx);
    break;
  }
  case CA_REG_MEMBER: {
    volatile VALUE data_class = rb_ca_data_class(self);
    if ( ! NIL_P(data_class) ) {
      obj = rb_ca_face_field(self, info.symbol);
      break;
    }
    else {
      rb_raise(rb_eIndexError, 
               "can't refer member of carray doesn't have data_class");
    }
    break;
  }
  case CA_REG_ATTRIBUTE: {
    obj = rb_funcall(self, rb_intern("attribute"), 0);
    obj = rb_hash_aref(obj, info.symbol);
    break;
  }
  default:
    rb_raise(rb_eIndexError, "invalid index specified");
  }

  return obj;
}

/* Recursively convert a store rvalue's surface value objects into
   storage-domain values for a Face `self`, applied at the Ruby `[]=` entry
   before any store-side view (block / newaxis / grid / ...) is built.  The
   store-side view is stripped to the storage data_type, so the Face is only
   visible here at the top of the dispatch; converting now lets every view
   path store a Face surface scalar correctly.

   - a Face CArray rvalue is reconciled to self's storage via to_comparable
     (unit-safe: cross-group / non-exact raises), so a same-Face bulk store
     (t[0..1] = t[1..2]) becomes a storage int64 xfer.  A non-Face CArray
     (e.g. datetime[0..1] = plain_int64_array) passes through unchanged --
     the documented raw-storage escape -- but it has to be raw *storage*: an
     integer-storage Face takes integer cells only.  The scalar path already
     refuses a bare Float there (to_comparable does not recognise it) instead
     of letting the storage cast truncate it, and the bulk path must not be
     the looser door.
   - an Array is mapped structure-preserving (leaves converted),
   - a scalar goes through the write hook (ca_face_scalar_to_storage), which
     leaves a bare Integer / String unchanged.

   Idempotent: an already-converted Integer passes through, so re-running on
   a `goto retry` iteration is harmless. */
static VALUE
ca_face_convert_store_rval (VALUE self, CArray *ca, VALUE val)
{
  if ( rb_obj_is_carray(val) ) {
    CArray *cval;
    GetCArray(val, cval);
    /* Face RHS: reconcile to self's unit and descend to storage.  Mirror of
       the scalar path (ca_face_scalar_to_storage) for a bulk CArray source.
       Guarded on self having to_comparable so a Face without a reconcile
       algebra (e.g. a fixlen-storage Face, whose same-storage store already
       takes the storage xfer branch) is left to the existing store path. */
    if ( ca_is_face(cval) && rb_respond_to(self, rb_intern("to_comparable")) ) {
      volatile VALUE reconciled = rb_funcall(self, rb_intern("to_comparable"),
                                             1, val);
      return rb_funcall(reconciled, rb_intern("parent"), 0);
    }
    /* Bare storage escape, integer storage: integer cells only (see above). */
    {
      CArray *storage = ca_strip_face(ca);
      if ( storage && ca_is_integer_type(storage) && ! ca_is_integer_type(cval) ) {
        rb_raise(rb_eTypeError,
                 "%s cannot store a bare %s array as raw storage "
                 "(use ca.parent to write the %s storage directly)",
                 rb_obj_classname(self), ca_type_name[cval->data_type],
                 ca_type_name[storage->data_type]);
      }
    }
    return val;
  }
  if ( TYPE(val) == T_ARRAY ) {
    long i, n = RARRAY_LEN(val);
    volatile VALUE out = rb_ary_new2(n);
    for (i = 0; i < n; i++) {
      rb_ary_push(out, ca_face_convert_store_rval(self, ca, rb_ary_entry(val, i)));
    }
    return out;
  }
  return ca_face_scalar_to_storage(self, ca, val);
}

static VALUE
rb_ca_store_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj = Qnil, rval;
  CArray *ca;
  CAIndexInfo info;

  rb_ca_modify(self);

  obj = rval = argv[argc-1];
  argc -= 1;

 retry:

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Face store: bring a surface value object (Scalar / Time / DateTime) into
     the storage domain while self is still the Face.  Store-side views strip
     the Face to storage, so this is the only point that sees it. */
  if ( ca_is_face(ca) ) {
    rval = ca_face_convert_store_rval(self, ca, rval);
  }

  /* newaxis (:_) interception on store.  Build the newaxis view (a
     writable reshape aliasing self), then assign rval into the whole view
     (writes propagate to self). */
  if ( ca_argv_has_newaxis(argc, argv) ) {
    volatile VALUE view = rb_ca_fetch_newaxis(argc, argv, self, ca);
    rb_ca_store_all(view, rval);
    return rval;
  }

  /* slab sigil on store is rejected regardless of outer-slot type.  Catch
     :> before scan_index so mask/fancy outer slots get the same "not
     supported" message instead of a misleading TypeError. */
  if ( ca_argv_has_slab_sigil(argc, argv) ) {
    rb_raise(rb_eIndexError,
             "assignment through a slab iterator (:>) is not supported "
             "(use a block index, e.g. ca[range, nil] = val, or each_slab)");
  }

  info.range_check = 1;
  rb_ca_scan_index(ca->ndim, ca->dim, ca->elements, argc, argv, &info);

  switch ( info.type ) {
  case CA_REG_ADDRESS_COMPLEX:
    self = rb_ca_refer_new_flatten(self);
    goto retry;
  case CA_REG_ADDRESS:
    obj = rb_ca_store_address(self, &info, rval);
    break;
  case CA_REG_FLATTEN:
    self = rb_ca_refer_new_flatten(self);
    obj = rb_ca_store_all(self, rval);
    break;
  case CA_REG_POINT:
    obj = rb_ca_store_point(self, &info, rval);
    break;
  case CA_REG_ALL:
    obj = rb_ca_store_all(self, rval);
    break;
  case CA_REG_BLOCK: {
    volatile VALUE block;
    block = rb_ca_ref_block(self, &info);
    obj   = rb_ca_store_all(block, rval); 
    break;
  }
  case CA_REG_SELECT: {
    obj = rb_ca_select_new(self, argv[0]);
    obj = rb_ca_store_all(obj, rval);
    break;
  }
  case CA_REG_ITERATOR: {
    /* assignment through a slab iterator (:>) is not supported.
       Use a block index (ca[range, nil] = val) or each_slab/map_slab. */
    rb_raise(rb_eIndexError,
             "assignment through a slab iterator (:>) is not supported "
             "(use a block index, e.g. ca[range, nil] = val, or each_slab)");
    break;
  }
  case CA_REG_REPEAT: {
    obj = rb_ca_repeat(argc, argv, self);
    obj = rb_ca_store_all(obj, rval);
    break;
  }
  case CA_REG_UNBOUND_REPEAT:
    obj = rb_funcall2(self, rb_intern("unbound_repeat"), (int) argc, argv);
    obj = rb_ca_store_all(obj, rval);
    break;
  case CA_REG_MAPPING: {
    obj = rb_ca_fancy_index_chain(self, argv[0]);
    obj = rb_ca_store_all(obj, rval);
    break;
  }
  case CA_REG_GRID: {
    obj = rb_ca_grid(argc, argv, self);
    obj = rb_ca_store_all(obj, rval);
    break;
  }
  case CA_REG_METHOD_CALL: {
    volatile VALUE idx;
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    ca_attach(ca);
    idx = rb_funcall2(self, SYM2ID(info.symbol), (int)(argc-1), argv+1);
    obj = rb_ca_store(self, idx, rval);
    ca_detach(ca);
    break;
  }
  case CA_REG_MEMBER: {
    volatile VALUE data_class = rb_ca_data_class(self);
    if ( ! NIL_P(data_class) ) {
      obj = rb_ca_face_field(self, info.symbol);
      obj = rb_ca_store_all(obj, rval);
    }
    else {
      rb_raise(rb_eIndexError, 
               "can't store member of carray doesn't have data_class");
    }
    break;
  }
  case CA_REG_ATTRIBUTE: {
    obj = rb_funcall(self, rb_intern("attribute"), 0);
    obj = rb_hash_aset(obj, info.symbol, rval);
    break;
  }
  }

  return obj;
}

VALUE
rb_ca_fetch (VALUE self, VALUE index)
{
  switch ( TYPE(index) ) {
  case T_ARRAY:
    return rb_ca_fetch_method((int) RARRAY_LEN(index), (VALUE *)RARRAY_CONST_PTR(index), self);
  default:
    return rb_ca_fetch_method(1, &index, self);
  }
}

VALUE
rb_ca_fetch2 (VALUE self, int n, VALUE *rindex)
{
  return rb_ca_fetch_method(n, rindex, self);
}

VALUE
rb_ca_store (VALUE self, VALUE index, VALUE rval)
{
  switch ( TYPE(index) ) {
  case T_ARRAY:
    index = rb_obj_clone(index);
    rb_ary_push(index, rval);
    return rb_ca_store_method((int)RARRAY_LEN(index), (VALUE *)RARRAY_CONST_PTR(index), self);
  default: {
    VALUE rindex[2] = { index, rval };
    return rb_ca_store_method(2, rindex, self);
  }
  }
}

VALUE
rb_ca_store2 (VALUE self, int n, VALUE *rindex, VALUE rval)
{
  volatile VALUE index = rb_ary_new4(n, rindex);
  rb_ary_push(index, rval);
  return rb_ca_store_method((int)RARRAY_LEN(index), (VALUE *)RARRAY_CONST_PTR(index), self);
}

static VALUE
rb_ca_s_scan_index (VALUE self, VALUE rdim, VALUE ridx)
{
  volatile VALUE rtype, rindex;
  CAIndexInfo info;
  int     ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t elements;
  int i;

  Check_Type(rdim, T_ARRAY);
  Check_Type(ridx, T_ARRAY);

  elements = 1;
  ndim = (int) RARRAY_LEN(rdim);
  for (i=0; i<ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
    elements *= dim[i];
  }

  CA_CHECK_RANK(ndim);
  CA_CHECK_DIM(ndim, dim);

  info.range_check = 1;
  rb_ca_scan_index(ndim, dim, elements,
                   RARRAY_LEN(ridx), (VALUE *)RARRAY_CONST_PTR(ridx), &info);

  rtype  = INT2NUM(info.type);
  rindex = rb_ary_new2(info.ndim);

  switch ( info.type ) {
  case CA_REG_NONE:
  case CA_REG_ALL:
    break;
  case CA_REG_ADDRESS:
    rb_ary_store(rindex, 0, SIZE2NUM(info.index[0].scalar));
    break;
  case CA_REG_FLATTEN:
    break;
  case CA_REG_ADDRESS_COMPLEX: {
    volatile VALUE rinfo;
    ca_size_t elements = 1;
    for (i=0; i<ndim; i++) {
      elements *= dim[i];
    }
    rinfo = rb_ca_s_scan_index(self, rb_ary_new3(1, SIZE2NUM(elements)), ridx);
    rtype = INT2NUM(CA_REG_ADDRESS_COMPLEX);
    rindex = rb_struct_aref(rinfo, rb_str_new2("index"));
    break;
  }
  case CA_REG_POINT:
    for (i=0; i<ndim; i++) {
      rb_ary_store(rindex, i, SIZE2NUM(info.index[i].scalar));
    }
    break;
  case CA_REG_SELECT:
    break;
  case CA_REG_BLOCK:
  case CA_REG_ITERATOR:
    for (i=0; i<ndim; i++) {
      switch ( info.index_type[i] ) {
      case CA_IDX_SCALAR:
        rb_ary_store(rindex, i, SIZE2NUM(info.index[i].scalar));
        break;
      case CA_IDX_ALL:
        rb_ary_store(rindex, i,
                     rb_ary_new3(3,
                                 INT2NUM(0),
                                 rb_ary_entry(rdim, i),
                                 INT2NUM(1)));
        break;
      case CA_IDX_BLOCK:
        rb_ary_store(rindex, i,
                     rb_ary_new3(3,
                                 SIZE2NUM(info.index[i].block.start),
                                 SIZE2NUM(info.index[i].block.count),
                                 SIZE2NUM(info.index[i].block.step)));
        break;
      case CA_IDX_SYMBOL:
        rb_ary_store(rindex, i,
                     rb_ary_new3(2,
                                 ID2SYM(info.index[i].symbol.id),
                                 info.index[i].symbol.spec));
        break;
      default:
        rb_raise(rb_eRuntimeError, "unknown index spec");
      }
    }
    break;
  case CA_REG_REPEAT:
  case CA_REG_GRID:
  case CA_REG_MAPPING:
  case CA_REG_METHOD_CALL:
  case CA_REG_UNBOUND_REPEAT:
  case CA_REG_MEMBER:  
  case CA_REG_ATTRIBUTE:  
    break;
  default:
    rb_raise(rb_eArgError, "unknown index specification");
  }

  return rb_struct_new(S_CAInfo, rtype, rindex);
}

static VALUE
rb_ca_normalize_index (VALUE self, VALUE ridx)
{
  volatile VALUE rindex;
  CArray *ca;
  CAIndexInfo info;
  int i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  Check_Type(ridx, T_ARRAY);

  info.range_check = 1;
  rb_ca_scan_index(ca->ndim, ca->dim, ca->elements,
                   RARRAY_LEN(ridx), (VALUE *)RARRAY_CONST_PTR(ridx), &info);

  switch ( info.type ) {
  case CA_REG_ALL:
  case CA_REG_SELECT:
  case CA_REG_ADDRESS:
    rindex = rb_ary_new2(info.ndim);
    rb_ary_store(rindex, 0, SIZE2NUM(info.index[0].scalar));
    return rindex;
  case CA_REG_POINT:
    rindex = rb_ary_new2(info.ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(rindex, i, SIZE2NUM(info.index[i].scalar));
    }
    return rindex;
  case CA_REG_BLOCK:
  case CA_REG_ITERATOR:
    rindex = rb_ary_new2(info.ndim);
    for (i=0; i<ca->ndim; i++) {
      switch ( info.index_type[i] ) {
      case CA_IDX_SCALAR:
        rb_ary_store(rindex, i, SIZE2NUM(info.index[i].scalar));
        break;
      case CA_IDX_ALL:
        rb_ary_store(rindex, i, Qnil);
        break;
      case CA_IDX_BLOCK:
        rb_ary_store(rindex, i,
                     rb_ary_new3(3,
                                 SIZE2NUM(info.index[i].block.start),
                                 SIZE2NUM(info.index[i].block.count),
                                 SIZE2NUM(info.index[i].block.step)));
        break;
      case CA_IDX_SYMBOL:
        rb_ary_store(rindex, i, ID2SYM(info.index[i].symbol.id));
        break;
      default:
        rb_raise(rb_eRuntimeError, "unknown index spec");
      }
    }
    return rindex;
  case CA_REG_ADDRESS_COMPLEX:
  case CA_REG_FLATTEN:
    self = rb_ca_refer_new_flatten(self);
    return rb_ca_normalize_index(self, ridx);
  default:
    rb_raise(rb_eArgError, "unknown index specification");
  }
  rb_raise(rb_eArgError, "fail to normalize index");
}

/* ------------------------------------------------------------------- */

/* ------------------------------------------------------------------- */
/* addr <-> index conversion primitives.
 *
 * Two dispatch axes:
 *   (a) instance form (uses self.shape) vs class form (`shape:` kwarg)
 *   (b) scalar input vs CArray input (per method)
 *
 * The four Ruby entry points (rb_ca_{addr2index,index2addr},
 * rb_ca_s_{addr2index,index2addr}) all funnel into the two _do helpers
 * below, which take an already-resolved (ndim, dim[], elements) triple.
 */

static void
parse_shape_kwarg (VALUE rshape, int *out_ndim, ca_size_t *dim,
                   ca_size_t *out_elements)
{
  int i, ndim;
  ca_size_t elements = 1;

  Check_Type(rshape, T_ARRAY);
  ndim = (int) RARRAY_LEN(rshape);
  if ( ndim < 1 || ndim > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "invalid shape ndim %d (must be 1..%d)",
             ndim, CA_RANK_MAX);
  }
  for (i = 0; i < ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rshape, i));
    if ( dim[i] < 0 ) {
      rb_raise(rb_eArgError, "negative dim %" PRId64 " at axis %d",
               (ca_size_t) dim[i], i);
    }
    elements *= dim[i];
  }
  *out_ndim = ndim;
  *out_elements = elements;
}

static VALUE
addr2index_do (int ndim, ca_size_t *dim, ca_size_t elements, VALUE raddr)
{
  volatile VALUE out;
  int i;

  /* Scalar path (Integer input): returns Ruby Array of N Integers.
   * Preserves legacy shape for callers like `i, j = ca.addr2index(k)`. */
  if ( rb_obj_is_kind_of(raddr, rb_cInteger) ) {
    ca_size_t addr = NUM2SIZE(raddr);
    if ( addr < 0 || addr >= elements ) {
      rb_raise(rb_eArgError,
               "address %" PRId64 " is out of range (0..%" PRId64 ")",
               (ca_size_t) addr, (ca_size_t) (elements - 1));
    }
    out = rb_ary_new2(ndim);
    for (i = ndim - 1; i >= 0; i--) {
      rb_ary_store(out, i, SIZE2NUM(addr % dim[i]));
      addr /= dim[i];
    }
    return out;
  }

  /* Vector path (CArray input): returns Ruby Array of N CArrays,
   * each with the same shape as the input; mask propagated. */
  {
    CArray *cin, *co[CA_RANK_MAX];
    ca_size_t *p_out[CA_RANK_MAX];
    boolean8_t *m;
    ca_size_t j, n;
    volatile VALUE objs[CA_RANK_MAX];

    cin = ca_wrap_readonly(raddr, CA_SIZE);
    ca_attach(cin);

    out = rb_ary_new2(ndim);
    for (i = 0; i < ndim; i++) {
      objs[i] = rb_carray_new(CA_SIZE, cin->ndim, cin->dim, 0, NULL);
      TypedData_Get_Struct(objs[i], CArray, &carray_data_type, co[i]);
      p_out[i] = (ca_size_t *) co[i]->ptr;
      rb_ary_store(out, i, objs[i]);
    }

    m = cin->mask ? (boolean8_t *) cin->mask->ptr : NULL;
    if ( m ) {
      for (i = 0; i < ndim; i++) {
        ca_create_mask(co[i]);
        memcpy(co[i]->mask->ptr, m, cin->elements);
      }
    }

    n = cin->elements;
    {
      ca_size_t *src = (ca_size_t *) cin->ptr;
      ca_size_t addr;
      int k;
      for (j = 0; j < n; j++) {
        if ( m && m[j] ) {
          for (k = 0; k < ndim; k++) { p_out[k][j] = 0; }
          continue;
        }
        addr = src[j];
        if ( addr < 0 || addr >= elements ) {
          ca_detach(cin);
          rb_raise(rb_eArgError,
                   "address %" PRId64 " is out of range (0..%" PRId64 ")",
                   (ca_size_t) addr, (ca_size_t) (elements - 1));
        }
        for (k = ndim - 1; k >= 0; k--) {
          p_out[k][j] = addr % dim[k];
          addr /= dim[k];
        }
      }
    }

    ca_detach(cin);
    return out;
  }
}

static VALUE
index2addr_do (int ndim, ca_size_t *dim, int argc, VALUE *argv)
{
  volatile VALUE obj;
  CArray *co, *cidx[CA_RANK_MAX];
  ca_size_t *q, *p[CA_RANK_MAX], s[CA_RANK_MAX];
  ca_size_t addr, k, n;
  boolean8_t *m;
  int i, all_number = 1;
  int out_ndim = 1;
  ca_size_t out_dim[CA_RANK_MAX];
  ca_size_t out_elements = 1;
  int shape_from = -1;

  if ( argc != ndim ) {
    rb_raise(rb_eArgError,
             "wrong number of indices (%d for %d)", argc, ndim);
  }

  for (i = 0; i < ndim; i++) {
    if ( ! rb_obj_is_kind_of(argv[i], rb_cInteger) ) {
      all_number = 0;
      break;
    }
  }

  /* All-scalar path: returns single Integer (unchanged). */
  if ( all_number ) {
    addr = 0;
    for (i = 0; i < ndim; i++) {
      k = NUM2SIZE(argv[i]);
      CA_CHECK_INDEX(k, dim[i]);
      addr = dim[i] * addr + k;
    }
    return SIZE2NUM(addr);
  }

  /* Vector path: wrap each arg as CA_SIZE view.  Output shape follows
   * the first non-scalar CArray input; other non-scalar inputs must
   * match that shape. */
  for (i = 0; i < ndim; i++) {
    cidx[i] = ca_wrap_readonly(argv[i], CA_SIZE);
    if ( ! ca_is_scalar(cidx[i]) ) {
      if ( shape_from < 0 ) {
        shape_from = i;
        out_ndim = cidx[i]->ndim;
        memcpy(out_dim, cidx[i]->dim, sizeof(ca_size_t) * out_ndim);
        out_elements = cidx[i]->elements;
      }
      else {
        int j;
        if ( cidx[i]->ndim != out_ndim
             || cidx[i]->elements != out_elements ) {
          rb_raise(rb_eArgError,
                   "shape mismatch: axis %d has shape ndim=%d elements=%"
                   PRId64 ", expected ndim=%d elements=%" PRId64,
                   i, cidx[i]->ndim, (ca_size_t) cidx[i]->elements,
                   out_ndim, (ca_size_t) out_elements);
        }
        for (j = 0; j < out_ndim; j++) {
          if ( cidx[i]->dim[j] != out_dim[j] ) {
            rb_raise(rb_eArgError,
                     "shape mismatch at axis %d dim %d", i, j);
          }
        }
      }
    }
  }

  for (i = 0; i < ndim; i++) {
    ca_attach(cidx[i]);
    ca_set_iterator(1, cidx[i], &p[i], &s[i]);
  }

  obj = rb_carray_new(CA_SIZE, out_ndim, out_dim, 0, NULL);
  TypedData_Get_Struct(obj, CArray, &carray_data_type, co);

  q = (ca_size_t *) co->ptr;

  ca_copy_mask_overwrite_n(co, out_elements, ndim, cidx);
  m = ( co->mask ) ? (boolean8_t *) co->mask->ptr : NULL;

  if ( m ) {
    n = out_elements;
    while ( n-- ) {
      if ( ! *m ) {
        addr = 0;
        for (i = 0; i < ndim; i++) {
          k = *(p[i]);
          p[i] += s[i];
          CA_CHECK_INDEX(k, dim[i]);
          addr = dim[i] * addr + k;
        }
        *q = addr;
      }
      else {
        for (i = 0; i < ndim; i++) { p[i] += s[i]; }
      }
      m++; q++;
    }
  }
  else {
    n = out_elements;
    while ( n-- ) {
      addr = 0;
      for (i = 0; i < ndim; i++) {
        k = *(p[i]);
        p[i] += s[i];
        CA_CHECK_INDEX(k, dim[i]);
        addr = dim[i] * addr + k;
      }
      *q = addr;
      q++;
    }
  }

  for (i = 0; i < ndim; i++) { ca_detach(cidx[i]); }

  return obj;
}

VALUE
rb_ca_addr2index (VALUE self, VALUE raddr)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return addr2index_do(ca->ndim, ca->dim, ca->elements, raddr);
}

VALUE
rb_ca_index2addr (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return index2addr_do(ca->ndim, ca->dim, argc, argv);
}

/* CArray.addr2index(addr, shape: [...]) */
static VALUE
rb_ca_s_addr2index (int argc, VALUE *argv, VALUE klass)
{
  VALUE raddr, opts;
  ID kw_ids[1];
  VALUE kw_vals[1];
  int ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t elements;

  kw_ids[0] = rb_intern("shape");
  rb_scan_args(argc, argv, "1:", &raddr, &opts);
  if ( NIL_P(opts) ) {
    rb_raise(rb_eArgError, "missing keyword: shape");
  }
  rb_get_kwargs(opts, kw_ids, 1, 0, kw_vals);
  parse_shape_kwarg(kw_vals[0], &ndim, dim, &elements);
  return addr2index_do(ndim, dim, elements, raddr);
}

/* CArray.index2addr(*index, shape: [...]) */
static VALUE
rb_ca_s_index2addr (int argc, VALUE *argv, VALUE klass)
{
  VALUE rest, opts;
  ID kw_ids[1];
  VALUE kw_vals[1];
  int ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t elements;

  kw_ids[0] = rb_intern("shape");
  rb_scan_args(argc, argv, "*:", &rest, &opts);
  if ( NIL_P(opts) ) {
    rb_raise(rb_eArgError, "missing keyword: shape");
  }
  rb_get_kwargs(opts, kw_ids, 1, 0, kw_vals);
  parse_shape_kwarg(kw_vals[0], &ndim, dim, &elements);
  return index2addr_do(ndim, dim, (int) RARRAY_LEN(rest), RARRAY_PTR(rest));
}


void
Init_carray_access (void)
{

  id_begin    = rb_intern("begin");
  id_end      = rb_intern("end");
  id_excl_end = rb_intern("exclude_end?");

  id_to_ca = rb_intern("to_ca");
  sym_star  = ID2SYM(rb_intern("*"));
  sym_perc  = ID2SYM(rb_intern("%"));
  sym_under = ID2SYM(rb_intern("_"));
  sym_gt    = ID2SYM(rb_intern(">"));
  sym_tilde = ID2SYM(rb_intern("~"));

  rb_define_method(rb_cCArray, "[]", rb_ca_fetch_method, -1);
  rb_define_method(rb_cCArray, "[]=", rb_ca_store_method, -1);

  rb_define_method(rb_cCScalar, "[]", rb_cs_fetch_method, -1);

  rb_define_method(rb_cCArray, "fill", rb_ca_fill, 1);
  rb_define_method(rb_cCArray, "fill_copy", rb_ca_fill_copy, 1);

  S_CAInfo = rb_struct_define("CAIndexInfo", "type", "index", NULL);

  rb_define_singleton_method(rb_cCArray, "guess_array_shape",
                                          rb_ca_s_guess_array_shape, 1);
  rb_define_singleton_method(rb_cCArray, "scan_index", rb_ca_s_scan_index, 2);
  rb_define_method(rb_cCArray, "normalize_index", rb_ca_normalize_index, 1);

  rb_define_method(rb_cCArray, "index2addr", rb_ca_index2addr, -1);
  rb_define_method(rb_cCArray, "addr2index", rb_ca_addr2index, 1);

  rb_define_singleton_method(rb_cCArray, "addr2index", rb_ca_s_addr2index, -1);
  rb_define_singleton_method(rb_cCArray, "index2addr", rb_ca_s_index2addr, -1);

  rb_define_const(rb_cObject, "CA_REG_NONE",     INT2NUM(CA_REG_NONE));
  rb_define_const(rb_cObject, "CA_REG_ALL",      INT2NUM(CA_REG_ALL));
  rb_define_const(rb_cObject, "CA_REG_ADDRESS",  INT2NUM(CA_REG_ADDRESS));
  rb_define_const(rb_cObject, "CA_REG_FLATTEN",  INT2NUM(CA_REG_FLATTEN));
  rb_define_const(rb_cObject, "CA_REG_ADDRESS_COMPLEX",
                                                 INT2NUM(CA_REG_ADDRESS_COMPLEX));
  rb_define_const(rb_cObject, "CA_REG_POINT",    INT2NUM(CA_REG_POINT));
  rb_define_const(rb_cObject, "CA_REG_BLOCK",    INT2NUM(CA_REG_BLOCK));
  rb_define_const(rb_cObject, "CA_REG_SELECT",   INT2NUM(CA_REG_SELECT));
  rb_define_const(rb_cObject, "CA_REG_ITERATOR", INT2NUM(CA_REG_ITERATOR));
  rb_define_const(rb_cObject, "CA_REG_REPEAT",   INT2NUM(CA_REG_REPEAT));
  rb_define_const(rb_cObject, "CA_REG_GRID",     INT2NUM(CA_REG_GRID));
  rb_define_const(rb_cObject, "CA_REG_MAPPING",  INT2NUM(CA_REG_MAPPING));
  rb_define_const(rb_cObject, "CA_REG_METHOD_CALL",
                                                 INT2NUM(CA_REG_METHOD_CALL));
  rb_define_const(rb_cObject, "CA_REG_UNBOUND_REPEAT",
                                                 INT2NUM(CA_REG_UNBOUND_REPEAT));
  rb_define_const(rb_cObject, "CA_REG_MEMBER",   INT2NUM(CA_REG_MEMBER));
  rb_define_const(rb_cObject, "CA_REG_ATTRIBUTE",   INT2NUM(CA_REG_ATTRIBUTE));

}

