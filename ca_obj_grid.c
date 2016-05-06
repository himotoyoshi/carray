/* ---------------------------------------------------------------------------

  ca_obj_grid.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

typedef struct {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    rank;
  int32_t   flags;
  int32_t   bytes;
  int32_t   elements;
  int32_t  *dim;
  char     *ptr;
  CArray   *mask;
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* -------------*/
  CArray  **grid;
  int8_t   *contig;
} CAGrid;

static VALUE rb_cCAGrid;

/* rdoc:
  class CAGrid < CAVirtual # :nodoc:
  end
*/

static int8_t CA_OBJ_GRID;

int
ca_grid_setup (CAGrid *ca, CArray *parent, int32_t *dim,
               CArray **grid, int8_t *contig, int share)
{
  int8_t rank, data_type;
  int32_t *dim0;
  int32_t elements, bytes;
  double  length;
  int i, j, k;

  data_type = parent->data_type;
  rank      = parent->rank;
  bytes     = parent->bytes;
  dim0      = parent->dim;

  elements = 1;
  length = bytes;
  for (i=0; i<rank; i++) {
    if ( dim[i] < 0 ) {
      rb_raise(rb_eRuntimeError, "negative size for %i-th dimension", i);
    }
    elements *= dim[i];
    length *= dim[i];
  }

  if ( length > CA_LENGTH_MAX ) {
    rb_raise(rb_eRuntimeError, "too large byte length");
  }

  ca->obj_type  = CA_OBJ_GRID;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->rank      = rank;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(int32_t, rank);

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  if ( share ) {
    ca_set_flag(ca, CA_FLAG_SHARE_INDEX);
    ca->grid   = grid;
    ca->contig = contig;
  }
  else {
    ca->grid   = ALLOC_N(CArray *, rank);
    ca->contig = ALLOC_N(int8_t, rank);
  }

  memcpy(ca->dim, dim, rank * sizeof(int32_t));

  if ( ! share ) {
    for (i=0; i<rank; i++) {
      if ( grid[i] ) {
        if ( ca_is_any_masked(grid[i]) ) {
          int32_t gsize = grid[i]->elements - ca_count_masked(grid[i]);
          boolean8_t *m;
          int32_t n;
          ca->grid[i] = carray_new(CA_INT32, 1, &gsize, 0, NULL);
          m = (boolean8_t *)grid[i]->mask->ptr;
          n = 0;
          for (j=0; j<grid[i]->elements; j++) {
            if ( ! *m ) {
              k = ((int32_t*)grid[i]->ptr)[j];
              CA_CHECK_INDEX(k, dim0[i]);
              ((int32_t*)ca->grid[i]->ptr)[n] = k;
              n++;
            }
            m++;
          }
          ca->contig[i] = 0;
        }
        else {
          ca->grid[i] = ca_template(grid[i]);
          for (j=0; j<grid[i]->elements; j++) {
            k = ((int32_t*)grid[i]->ptr)[j];
            CA_CHECK_INDEX(k, dim0[i]);
            ((int32_t*)ca->grid[i]->ptr)[j] = k;
          }
          ca->contig[i] = 0;
        }
      }
      else {
        int32_t *p;
        ca->grid[i] = carray_new(CA_INT32, 1, &dim[i], 0, NULL);
        p = (int32_t *)ca->grid[i]->ptr;
        for (j=0; j<dim[i]; j++) {
          *p++ = j;
        }
        ca->contig[i] = 1;
      }
    }
  }

  if ( ca->rank == 1 && ca_is_scalar(grid[0]) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAGrid *
ca_grid_new (CArray *parent, int32_t *dim, CArray **grid)
{
  CAGrid *ca = ALLOC(CAGrid);
  ca_grid_setup(ca, parent, dim, grid, NULL, 0);
  return ca;
}

CAGrid *
ca_grid_new_share (CArray *parent, int32_t *dim, CArray **grid, int8_t *contig)
{
  CAGrid *ca = ALLOC(CAGrid);
  ca_grid_setup(ca, parent, dim, grid, contig, 1);
  return ca;
}

static void
free_ca_grid (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  int32_t i;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ! (ca->flags & CA_FLAG_SHARE_INDEX)) {
      xfree(ca->contig);
      for (i=0; i<ca->rank; i++) {
        ca_free(ca->grid[i]);
      }
      xfree(ca->grid);
    }
    xfree(ca->dim);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

static void ca_grid_attach (CAGrid *ca);
static void ca_grid_sync (CAGrid *ca);
static void ca_grid_fill (CAGrid *ca, char *ptr);

static void *
ca_grid_func_clone (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  return ca_grid_new_share(ca->parent, ca->dim, ca->grid, ca->contig);
}

static char *
ca_grid_func_ptr_at_addr (void *ap, int32_t addr)
{
  CAGrid *ca = (CAGrid *) ap;
  if ( ! ca->ptr ) {
    int32_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addr, idx);
    return ca_ptr_at_index(ca, idx);
  }
  else {
    return ca->ptr + ca->bytes * addr;
  }
}

static char *
ca_grid_func_ptr_at_index (void *ap, int32_t *idx)
{
  CAGrid *ca = (CAGrid *) ap;
  if ( ! ca->ptr ) {
    CArray **grid = ca->grid;
    int32_t *dim0 = ca->parent->dim;
    int32_t  n, i;

    n = 0;
    for (i=0; i<ca->rank; i++) {
      n = dim0[i]*n + *(int32_t*) ca_ptr_at_addr(grid[i], idx[i]);
    }

    if ( ca->parent->ptr == NULL ) {
      return ca_ptr_at_addr(ca->parent, n);
    }
    else {
      return ca->parent->ptr + ca->bytes * n;
    }
  }
  else {
    return ca_func[CA_OBJ_ARRAY].ptr_at_index(ca, idx);
  }
}

static void
ca_grid_func_fetch_index (void *ap, int32_t *idx, void *ptr)
{
  CAGrid *ca = (CAGrid *) ap;
  CArray **grid = ca->grid;
  int32_t idx0[CA_RANK_MAX];
  int32_t i;
  for (i=0; i<ca->rank; i++) {
    ca_fetch_addr(grid[i], idx[i], &idx0[i]);
  }
  ca_fetch_index(ca->parent, idx0, ptr);
}

static void
ca_grid_func_store_index (void *ap, int32_t *idx, void *ptr)
{
  CAGrid *ca = (CAGrid *) ap;
  CArray **grid = ca->grid;
  int32_t idx0[CA_RANK_MAX];
  int32_t i;
  for (i=0; i<ca->rank; i++) {
    ca_fetch_addr(grid[i], idx[i], &idx0[i]);
  }
  ca_store_index(ca->parent, idx0, ptr);
}

static void
ca_grid_func_allocate (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_grid_func_attach (void *ap)
{
  void ca_grid_attach (CAGrid *cb);

  CAGrid *ca = (CAGrid *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_grid_attach(ca);
}

static void
ca_grid_func_sync (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_grid_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_grid_func_detach (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_grid_func_copy_data (void *ap, void *ptr)
{
  CAGrid *ca = (CAGrid *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_grid_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_grid_func_sync_data (void *ap, void *ptr)
{
  CAGrid *ca = (CAGrid *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_grid_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_grid_func_fill_data (void *ap, void *ptr)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_attach(ca->parent);
  ca_grid_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_grid_func_create_mask (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  ca->mask = (CArray *) ca_grid_new_share(ca->parent->mask,
                                          ca->dim, ca->grid, ca->contig);
}

ca_operation_function_t ca_grid_func = {
  -1, /* CA_OBJ_GRID */
  CA_VIRTUAL_ARRAY,
  free_ca_grid,
  ca_grid_func_clone,
  ca_grid_func_ptr_at_addr,
  ca_grid_func_ptr_at_index,
  NULL,
  ca_grid_func_fetch_index,
  NULL,
  ca_grid_func_store_index,
  ca_grid_func_allocate,
  ca_grid_func_attach,
  ca_grid_func_sync,
  ca_grid_func_detach,
  ca_grid_func_copy_data,
  ca_grid_func_sync_data,
  ca_grid_func_fill_data,
  ca_grid_func_create_mask,
};

/* ------------------------------------------------------------------- */

#define proc_grid_attach(type) \
  { \
    int32_t *pi = (int32_t*) ca_ptr_at_addr(grid[level], 0); \
    type *p = (type*) ca_ptr_at_index(ca, idx); \
    type *q = (type*) ca_ptr_at_index(ca->parent, idx0); \
    for (i=0; i<ca->dim[level]; i++, pi++, p++) { \
      k = *pi; \
      *p = *(q+k); \
    } \
  }

static void
ca_grid_attach_loop (CAGrid *ca, int16_t level, int32_t *idx, int32_t *idx0)
{
  CArray **grid = ca->grid;
  int32_t i, k;

  if ( level == ca->rank - 1 ) {
    idx[level] = 0;
    idx0[level] = 0;
    if ( ca->contig[level] ) {
      memcpy(ca_ptr_at_index(ca, idx), ca_ptr_at_index(ca->parent, idx0),
             ca->bytes * ca->dim[level]);
    }
    else {
      switch ( ca->bytes ) {
      case 1: proc_grid_attach(int8_t); break;
      case 2: proc_grid_attach(int16_t); break;
      case 4: proc_grid_attach(int32_t); break;
      case 8: proc_grid_attach(float64_t); break;
      default:
        {
          int32_t *pi = (int32_t*) ca_ptr_at_addr(grid[level], 0);
          char *p = ca_ptr_at_index(ca, idx);
          char *q;
          idx0[level] = 0;
          q = ca_ptr_at_index(ca->parent, idx0);
          for (i=0; i<ca->dim[level]; i++, pi++, p+=ca->bytes) {
            k = *pi;
            memcpy(p, q + ca->bytes * k, ca->bytes);
          }
        }
      }
    }
  }
  else {
    if ( ca->contig[level] ) {
      for (i=0; i<ca->dim[level]; i++) {
        idx[level]  = i;
        idx0[level] = i;
        ca_grid_attach_loop(ca, level+1, idx, idx0);
      }
    }
    else {
      int32_t *pi;
      pi = (int32_t*) ca_ptr_at_addr(grid[level], 0);
      for (i=0; i<ca->dim[level]; i++, pi++) {
        k = *pi;
        idx[level]  = i;
        idx0[level] = k;
        ca_grid_attach_loop(ca, level+1, idx, idx0);
      }
    }
  }
}

static void
ca_grid_attach (CAGrid *ca)
{
  int32_t idx[CA_RANK_MAX];
  int32_t idx0[CA_RANK_MAX];
  ca_grid_attach_loop(ca, (int16_t) 0, idx, idx0);
}

#define proc_grid_sync(type) \
  { \
    int32_t *pi = (int32_t*) ca_ptr_at_addr(grid[level], 0); \
    type *p = (type*) ca_ptr_at_index(ca, idx); \
    type *q = (type*) ca_ptr_at_index(ca->parent, idx0); \
    for (i=0; i<ca->dim[level]; i++, pi++, p++) { \
      k = *pi; \
      *(q+k) = *p; \
    } \
  }

static void
ca_grid_sync_loop (CAGrid *ca, int16_t level, int32_t *idx, int32_t *idx0)
{
  CArray **grid = ca->grid;
  int32_t i, k;

  if ( level == ca->rank - 1 ) {
    idx[level] = 0;
    idx0[level] = 0;
    if ( ca->contig[level] ) {
      memcpy(ca_ptr_at_index(ca->parent, idx0), ca_ptr_at_index(ca, idx),
             ca->bytes * ca->dim[level]);
    }
    else {
      switch ( ca->bytes ) {
      case 1: proc_grid_sync(int8_t); break;
      case 2: proc_grid_sync(int16_t); break;
      case 4: proc_grid_sync(int32_t); break;
      case 8: proc_grid_sync(float64_t); break;
      default:
        {
          int32_t *pi = (int32_t*) ca_ptr_at_addr(grid[level], 0);
          char *p = ca_ptr_at_index(ca, idx);
          char *q;
          idx0[level] = 0;
          q = ca_ptr_at_index(ca->parent, idx0);
          for (i=0; i<ca->dim[level]; i++, pi++, p+=ca->bytes) {
            k = *pi;
            memcpy(q + ca->bytes * k, p, ca->bytes);
          }
        }
      }
    }
  }
  else {
    if ( ca->contig[level] ) {
      for (i=0; i<ca->dim[level]; i++) {
        idx[level] = i;
        idx0[level] = i;
        ca_grid_sync_loop(ca, level+1, idx, idx0);
      }
    }
    else {
      for (i=0; i<ca->dim[level]; i++) {
        k = *(int32_t*) ca_ptr_at_addr(grid[level], i);
        idx[level]  = i;
        idx0[level] = k;
        ca_grid_sync_loop(ca, level+1, idx, idx0);
      }
    }
  }
}

static void
ca_grid_sync (CAGrid *ca)
{
  int32_t idx[CA_RANK_MAX];
  int32_t idx0[CA_RANK_MAX];
  ca_grid_sync_loop(ca, (int16_t) 0, idx, idx0);
}

#define proc_grid_fill(type) \
  { \
    int32_t *pi = (int32_t*) ca_ptr_at_addr(grid[level], 0); \
    type fval = *(type*)ptr; \
    type *q = (type*) ca_ptr_at_index(ca->parent, idx0); \
    for (i=0; i<ca->dim[level]; i++, pi++) { \
      k = *pi; \
      *(q+k) = fval; \
    } \
  }

static void
ca_grid_fill_loop (CAGrid *ca, char *ptr,
                  int16_t level, int32_t *idx0)
{
  CArray **grid = ca->grid;
  int32_t i, k;
  if ( level == ca->rank - 1 ) {
    idx0[level] = 0;
    if ( ca->contig[level] ) {
      char *p = ca_ptr_at_index(ca->parent, idx0);
      for (i=0; i<ca->dim[level]; i++) {
        memcpy(p, ptr, ca->bytes);
        p += ca->bytes;
      }
    }
    else {
      switch ( ca->bytes ) {
      case 1: proc_grid_fill(int8_t); break;
      case 2: proc_grid_fill(int16_t); break;
      case 4: proc_grid_fill(int32_t); break;
      case 8: proc_grid_fill(float64_t); break;
      default:
        {
          int32_t *pi = (int32_t*) ca_ptr_at_addr(grid[level], 0);
          char *q;
          idx0[level] = 0;
          q = ca_ptr_at_index(ca->parent, idx0);
          for (i=0; i<ca->dim[level]; i++, pi++) {
            k = *pi;
            memcpy(q + ca->bytes * k, ptr, ca->bytes);
          }
        }
      }
    }
  }
  else {
    if ( ca->contig[level] ) {
      for (i=0; i<ca->dim[level]; i++) {
        idx0[level] = i;
        ca_grid_fill_loop(ca, ptr, level+1, idx0);
      }
    }
    else {
      for (i=0; i<ca->dim[level]; i++) {
        k = *(int32_t*) ca_ptr_at_addr(grid[level], i);
        idx0[level] = k;
        ca_grid_fill_loop(ca, ptr, level+1, idx0);
      }
    }
  }
}

static void
ca_grid_fill (CAGrid *ca, char *ptr)
{
  int32_t idx0[CA_RANK_MAX];
  ca_grid_fill_loop(ca, ptr, (int16_t) 0, idx0);
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_grid_new (VALUE cary, int32_t *dim, CArray **grid)
{
  volatile VALUE obj;
  CArray *parent;
  CAGrid *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_grid_new(parent, dim, grid);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

/* rdoc:
  class CArray
    def grid
    end
  end
*/

VALUE
rb_ca_grid (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ridx, rval;
  volatile VALUE list = rb_ary_new();
  CArray *ca;
  CArray *ci[CA_RANK_MAX];
  int32_t dim[CA_RANK_MAX];
  CArray *grid[CA_RANK_MAX];
  int32_t i;

  Data_Get_Struct(self, CArray, ca);

  ridx = rb_ary_new4(argc, argv);

  if ( RARRAY_LEN(ridx) > ca->rank ) {
    rb_raise(rb_eArgError, "# of arguments doesn't equal to the rank");
  }
  else if ( RARRAY_LEN(ridx) < ca->rank ) {
    volatile VALUE ref;
    CArray *cv;
    int32_t rdim[CA_RANK_MAX];
    int32_t rrank = RARRAY_LEN(ridx);
    int32_t j = 0, k;
    for (i=0; i<rrank; i++) {
      rval = rb_ary_entry(ridx, i);
      if ( rb_obj_is_carray(rval) ) {
        Data_Get_Struct(rval, CArray, cv);
        rdim[i] = 1;
        for (k=0; k<cv->rank; k++) {
          rdim[i] *= ca->dim[j];
          j += 1;
        }
      }
      else {
        rdim[i] = ca->dim[j];
        j += 1;
      }
    }
    if ( j != ca->rank ) {
      rb_raise(rb_eArgError, "invalid total rank of args");
    }
    ref = rb_ca_refer_new(self, ca->data_type, rrank, rdim, ca->bytes, 0);
    return rb_ca_grid(argc, argv, ref);
  }

  for (i=0; i<RARRAY_LEN(ridx); i++) {
    rval = rb_ary_entry(ridx, i);
    if ( NIL_P(rval) ) {
      ci[i]   = NULL;
      dim[i]  = ca->dim[i];
      grid[i] = NULL;
    }
    else {
      if ( rb_obj_is_carray(rval) ) {
        if ( rb_ca_is_boolean_type(rval) ) {
          rval = rb_ca_where(rval);
        }
      }
      else if ( rb_obj_is_kind_of(rval, rb_cRange) ) {
        rval = rb_funcall(rb_mKernel, rb_intern("CA_INT32"), 1, rval);
      }
      else if ( TYPE(rval) == T_ARRAY ) {
        rb_raise(rb_eRuntimeError, "not implemented for this index");
      }
      ci[i] = ca_wrap_readonly(rval, CA_INT32);
      rb_ary_push(list, rval);
      ca_attach(ci[i]);

      if ( ca_is_any_masked(ci[i]) ) {
        dim[i] = ci[i]->elements - ca_count_masked(ci[i]);
      }
      else {
        dim[i]  = ci[i]->elements;
      }
      grid[i] = ci[i];
    }
  }

  obj = rb_ca_grid_new(self, dim, grid);

  for (i=0; i<RARRAY_LEN(ridx); i++) {
    if ( ci[i] ) {
      ca_detach(ci[i]);
    }
  }

  return obj;
}

static VALUE
rb_ca_grid_s_allocate (VALUE klass)
{
  CAGrid *ca;
  return Data_Make_Struct(klass, CAGrid, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_grid_initialize_copy (VALUE self, VALUE other)
{
  CAGrid *ca, *cs;

  Data_Get_Struct(self,  CAGrid, ca);
  Data_Get_Struct(other, CAGrid, cs);

  /* share grid info */
  ca_grid_setup(ca, cs->parent, cs->dim, cs->grid, cs->contig, 1);

  return self;
}



void
Init_ca_obj_grid ()
{
  rb_cCAGrid = rb_define_class("CAGrid", rb_cCAVirtual);

  CA_OBJ_GRID = ca_install_obj_type(rb_cCAGrid, ca_grid_func);
  rb_define_const(rb_cObject, "CA_OBJ_GRID", INT2NUM(CA_OBJ_GRID));

  rb_define_method(rb_cCArray, "grid", rb_ca_grid, -1);

  rb_define_alloc_func(rb_cCAGrid, rb_ca_grid_s_allocate);
  rb_define_method(rb_cCAGrid, "initialize_copy",
                                      rb_ca_grid_initialize_copy, 1);
}

