/* ---------------------------------------------------------------------------

  ca_obj_shift.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

/* rdoc:
  class CAShift < CAVirtual # :nodoc:
  end
*/

static VALUE rb_cCAShift;

typedef struct {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    rank;
  int32_t   flags;
  ca_size_t   bytes;
  ca_size_t   elements;
  ca_size_t  *dim;
  char     *ptr;
  CArray   *mask;
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* -------------*/
  ca_size_t  *shift;
  char     *fill;
  int8_t   *roll;
  int       fill_mask;
} CAShift;

static int8_t CA_OBJ_SHIFT;

/* ------------------------------------------------------------------- */

int
ca_shift_setup (CAShift *ca, CArray *parent,
               ca_size_t *shift, char *fill, int8_t *roll)
{
  int8_t data_type, rank;
  ca_size_t elements, bytes;

  data_type = parent->data_type;
  bytes     = parent->bytes;
  rank      = parent->rank;
  elements  = parent->elements;


  ca->obj_type  = CA_OBJ_SHIFT;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->rank      = rank;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(ca_size_t, rank);

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->shift     = ALLOC_N(ca_size_t, rank);
  ca->fill      = ALLOC_N(char, ca->bytes);
  ca->roll      = ALLOC_N(int8_t, rank);

  memcpy(ca->dim, parent->dim, rank * sizeof(ca_size_t));
  memcpy(ca->shift, shift, rank * sizeof(ca_size_t));
  memcpy(ca->roll, roll, rank * sizeof(int8_t));

  if ( fill ) {
    ca->fill_mask = 0;
    memcpy(ca->fill, fill, ca->bytes);
  }
  else {
    ca->fill_mask = 1;
    memset(ca->fill, 0, ca->bytes);
  }

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CAShift *
ca_shift_new (CArray *parent, ca_size_t *shift, char *fill, int8_t *roll)
{
  CAShift *ca = ALLOC(CAShift);
  ca_shift_setup(ca, parent, shift, fill, roll);
  return ca;
}

static void
free_ca_shift (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  if ( ca != NULL ) {
    xfree(ca->fill);
    xfree(ca->shift);
    xfree(ca->roll);
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void ca_shift_attach (CAShift *ca);
static void ca_shift_sync (CAShift *ca);
static void ca_shift_fill (CAShift *ca, char *ptr);

static ca_size_t
ca_shift_normalized_roll_shift (CAShift *ca, ca_size_t i)
{
  ca_size_t dim   = ca->dim[i];
  ca_size_t shift = ca->shift[i];
  if ( shift >= 0 ) {
    return shift % dim;
  }
  else {
    return -((-shift) % dim);
  }
}

static ca_size_t
ca_shift_rolled_index (CAShift *ca, ca_size_t i, ca_size_t k)
{
  ca_size_t dim = ca->dim[i];
  ca_size_t shift = ca->shift[i];
  ca_size_t idx = k - shift;
  if ( idx >= 0 ) {
    return idx % dim;
  }
  else {
    idx = (-idx) % dim;
    return ( ! idx ) ? 0 : dim - idx;
  }
}

static ca_size_t
ca_shift_shifted_index (CAShift *ca, ca_size_t i, ca_size_t k)
{
  ca_size_t dim   = ca->dim[i];
  ca_size_t shift = ca->shift[i];
  ca_size_t idx   = k - shift;
  if ( idx < 0 || idx >= dim ) {
    return -1;
  }
  else {
    return idx;
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_shift_func_clone (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  return ca_shift_new(ca->parent, ca->shift, ca->fill, ca->roll);
}

static char *
ca_shift_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CAShift *ca = (CAShift *) ap;
  if ( ! ca->ptr ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addr, idx);
    return ca_ptr_at_index(ca, idx);
  }
  else {
    return ca->ptr + ca->bytes * addr;
  }
}

static char *
ca_shift_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CAShift *ca = (CAShift *) ap;
  if ( ! ca->ptr ) {
    ca_size_t *dim    = ca->dim;
    int8_t *roll = ca->roll;
    int8_t i;
    ca_size_t k, n;
    n = 0;
    for (i=0; i<ca->rank; i++) {
      k = idx[i];
      if ( roll[i] ) {
        k = ca_shift_rolled_index(ca, i, k);
      }
      else {
        k = ca_shift_shifted_index(ca, i, k);
      }

      if ( k < 0 ) {
        return ca->fill;
      }
      n = dim[i] * n + k;
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
ca_shift_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAShift *ca = (CAShift *) ap;
  ca_size_t *dim    = ca->dim;
  int8_t *roll = ca->roll;
  int8_t  i;
  ca_size_t k, n;
  n = 0;
  for (i=0; i<ca->rank; i++) {
    k = idx[i];
    if ( roll[i] ) {
      k = ca_shift_rolled_index(ca, i, k);
    }
    else {
      k = ca_shift_shifted_index(ca, i, k);
    }

    if ( k < 0 ) {
      memcpy(ptr, ca->fill, ca->bytes);
      return;
    }
    n = dim[i] * n + k;
  }
  ca_fetch_addr(ca->parent, n, ptr);
}

static void
ca_shift_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAShift *ca = (CAShift *) ap;
  ca_size_t *dim    = ca->dim;
  int8_t *roll = ca->roll;
  int8_t i;
  ca_size_t k, n;
  n = 0;
  for (i=0; i<ca->rank; i++) {
    k = idx[i];
    if ( roll[i] ) {
      k = ca_shift_rolled_index(ca, i, k);
    }
    else {
      k = ca_shift_shifted_index(ca, i, k);
    }

    if ( k < 0 ) {
      return;
    }
    n = dim[i] * n + k;
  }
  ca_store_addr(ca->parent, n, ptr);
}

static void
ca_shift_func_allocate (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_shift_func_attach (void *ap)
{
  void ca_shift_attach (CAShift *cb);

  CAShift *ca = (CAShift *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_shift_attach(ca);
}

static void
ca_shift_func_sync (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  ca_shift_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_shift_func_detach (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_shift_func_copy_data (void *ap, void *ptr)
{
  CAShift *ca = (CAShift *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_shift_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_shift_func_sync_data (void *ap, void *ptr)
{
  CAShift *ca = (CAShift *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_shift_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_shift_func_fill_data (void *ap, void *ptr)
{
  CAShift *ca = (CAShift *) ap;
  ca_attach(ca->parent);
  ca_shift_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_shift_func_create_mask (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  boolean8_t one = 1;
  boolean8_t zero = 0;

  ca_update_mask(ca->parent);

  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  if ( ca->fill_mask ) {
    ca->mask = (CArray *) ca_shift_new(ca->parent->mask,
                                     ca->shift, (char *) &one, ca->roll);
  }
  else {
    ca->mask = (CArray *) ca_shift_new(ca->parent->mask,
                                     ca->shift, (char *) &zero, ca->roll);
  }
}

ca_operation_function_t ca_shift_func = {
  -1, /* CA_OBJ_SHIFT */
  CA_VIRTUAL_ARRAY,
  free_ca_shift,
  ca_shift_func_clone,
  ca_shift_func_ptr_at_addr,
  ca_shift_func_ptr_at_index,
  NULL,
  ca_shift_func_fetch_index,
  NULL,
  ca_shift_func_store_index,
  ca_shift_func_allocate,
  ca_shift_func_attach,
  ca_shift_func_sync,
  ca_shift_func_detach,
  ca_shift_func_copy_data,
  ca_shift_func_sync_data,
  ca_shift_func_fill_data,
  ca_shift_func_create_mask,
};

/* ------------------------------------------------------------------- */

static void
ca_shift_attach_loop (CAShift *ca, int16_t level, ca_size_t *idx, ca_size_t *idx0,
                                                                  int32_t fill)
{
  ca_size_t dim   = ca->dim[level];
  ca_size_t shift = ca->shift[level];
  int8_t roll = ca->roll[level];
  ca_size_t i;

  if ( level == ca->rank - 1 ) {
    if ( fill ) {
      for (i=0; i<ca->dim[level]; i++) {
        idx[level] = i;
        memcpy(ca_ptr_at_index(ca, idx), ca->fill, ca->bytes);
      }
    }
    else if ( ! shift ) {
      idx[level] = 0;
      idx0[level] = 0;
      memcpy(ca_ptr_at_index(ca, idx), ca_ptr_at_index(ca->parent, idx0), dim * ca->bytes);
    }
    else if ( roll ) {
      shift = ca_shift_normalized_roll_shift(ca, level);
      if ( shift > 0 ) {
        idx[level] = 0;
        idx0[level] = dim-shift;
        memcpy(ca_ptr_at_index(ca,idx), ca_ptr_at_index(ca->parent,idx0), shift*ca->bytes);
        idx[level] = shift;
        idx0[level] = 0;
        memcpy(ca_ptr_at_index(ca,idx), ca_ptr_at_index(ca->parent,idx0), (dim-shift)*ca->bytes);
      }
      else {
        idx[level]  = 0;
        idx0[level] = -shift;
        memcpy(ca_ptr_at_index(ca,idx), ca_ptr_at_index(ca->parent,idx0), (dim+shift)*ca->bytes);
        idx[level] = dim + shift;
        idx0[level] = 0;
        memcpy(ca_ptr_at_index(ca,idx), ca_ptr_at_index(ca->parent,idx0), (-shift)*ca->bytes);
      }
    }
    else {
      if ( shift > 0 ) {
        shift = ( shift >= dim ) ? dim : shift;

        for (i=0; i<shift; i++) {
          idx[level] = i;
          memcpy(ca_ptr_at_index(ca, idx), ca->fill, ca->bytes);
        }

        if ( shift < dim ) {
          idx[level] = shift;
          idx0[level] = 0;
          memcpy(ca_ptr_at_index(ca,idx), ca_ptr_at_index(ca->parent,idx0),(dim-shift)*ca->bytes);
        }
      }
      else {
        shift = ( -shift >= dim ) ? -dim : shift;

        if ( -shift < dim ) {
          idx[level]  = 0;
          idx0[level] = -shift;
          memcpy(ca_ptr_at_index(ca,idx), ca_ptr_at_index(ca->parent,idx0),(dim+shift)*ca->bytes);
        }

        for (i=0; i<-shift; i++) {
          idx[level] = dim+shift+i;
          memcpy(ca_ptr_at_index(ca, idx), ca->fill, ca->bytes);
        }
      }
    }
  }
  else {
    if ( fill ) {
      for (i=0; i<dim; i++) {
        idx[level]  = i;
        ca_shift_attach_loop(ca, level+1, idx, idx0, 1); /* fill */
      }
    }
    else if ( ! shift ) {
      for (i=0; i<dim; i++) {
        idx[level]  = i;
        idx0[level] = i;
        ca_shift_attach_loop(ca, level+1, idx, idx0, 0);
      }
    }
    else if ( roll ) {
      shift = ca_shift_normalized_roll_shift(ca, level);

      if ( shift > 0 ) {
        for (i=0; i<shift; i++) {
          idx[level] = i;
          idx0[level] = dim-shift+i;
          ca_shift_attach_loop(ca, level+1, idx, idx0, 0);
        }

        for (i=0; i<dim-shift; i++) {
          idx[level] = shift+i;
          idx0[level] = i;
          ca_shift_attach_loop(ca, level+1, idx, idx0, 0);
        }
      }
      else {
        for (i=0; i<dim+shift; i++) {
          idx[level]  = i;
          idx0[level] = -shift+i;
          ca_shift_attach_loop(ca, level+1, idx, idx0, 0);
        }

        for (i=0; i<-shift; i++) {
          idx[level] = dim + shift + i;
          idx0[level] = i;
          ca_shift_attach_loop(ca, level+1, idx, idx0, 0);
        }
      }
    }
    else {
      if ( shift > 0 ) {
        shift = ( shift >= dim ) ? dim : shift;

        for (i=0; i<shift; i++) {
          idx[level] = i;
          ca_shift_attach_loop(ca, level+1, idx, idx0, 1); /* fill */
        }

        if ( shift < dim ) {
          for (i=0; i<dim-shift; i++) {
            idx[level] = shift+i;
            idx0[level] = i;
            ca_shift_attach_loop(ca, level+1, idx, idx0, 0);
          }
        }
      }
      else {
        shift = ( -shift >= dim ) ? -dim : shift;

        if ( -shift < dim ) {
          for (i=0; i<dim+shift; i++) {
            idx[level]  = i;
            idx0[level] = -shift+i;
            ca_shift_attach_loop(ca, level+1, idx, idx0, 0);
          }
        }

        for (i=0; i<-shift; i++) {
          idx[level] = dim+shift+i;
          ca_shift_attach_loop(ca, level+1, idx, idx0, 1); /* fill */
        }
      }
    }
  }
}

static void
ca_shift_attach (CAShift *ca)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_shift_attach_loop(ca, (int16_t) 0, idx, idx0, 0);
}

static void
ca_shift_sync_loop (CAShift *ca, int16_t level, ca_size_t *idx, ca_size_t *idx0)
{
  ca_size_t dim   = ca->dim[level];
  ca_size_t shift = ca->shift[level];
  int8_t roll = ca->roll[level];
  ca_size_t i;

  if ( level == ca->rank - 1 ) {
    if ( ! shift ) {
      idx[level] = 0;
      idx0[level] = 0;
      memcpy(ca_ptr_at_index(ca->parent, idx0), ca_ptr_at_index(ca, idx), dim * ca->bytes);
    }
    else if ( roll ) {
      shift = ca_shift_normalized_roll_shift(ca, level);

      if ( shift > 0 ) {
        idx[level] = 0;
        idx0[level] = dim-shift;
        memcpy(ca_ptr_at_index(ca->parent,idx0), ca_ptr_at_index(ca,idx), shift*ca->bytes);
        idx[level] = shift;
        idx0[level] = 0;
        memcpy(ca_ptr_at_index(ca->parent,idx0), ca_ptr_at_index(ca,idx), (dim-shift)*ca->bytes);
      }
      else {
        idx[level]  = 0;
        idx0[level] = -shift;
        memcpy(ca_ptr_at_index(ca->parent,idx0), ca_ptr_at_index(ca,idx), (dim+shift)*ca->bytes);
        idx[level] = dim + shift;
        idx0[level] = 0;
        memcpy(ca_ptr_at_index(ca->parent,idx0), ca_ptr_at_index(ca,idx), (-shift)*ca->bytes);
      }
    }
    else {
      if ( shift > 0 ) {
        shift = ( shift >= dim ) ? dim : shift;

        for (i=0; i<shift; i++) {
          ; /* do nothing */
        }

        if ( shift < dim ) {
          idx[level] = shift;
          idx0[level] = 0;
          memcpy(ca_ptr_at_index(ca->parent,idx0), ca_ptr_at_index(ca,idx),(dim-shift)*ca->bytes);
        }
      }
      else {
        shift = ( -shift >= dim ) ? -dim : shift;

        if ( -shift < dim ) {
          idx[level]  = 0;
          idx0[level] = -shift;
          memcpy(ca_ptr_at_index(ca->parent,idx0), ca_ptr_at_index(ca,idx),(dim+shift)*ca->bytes);
        }

        for (i=0; i<-shift; i++) {
          ; /* do nothing */
        }
      }
    }
  }
  else {
    if ( ! shift ) {
      for (i=0; i<dim; i++) {
        idx[level]  = i;
        idx0[level] = i;
        ca_shift_sync_loop(ca, level+1, idx, idx0);
      }
    }
    else if ( roll ) {
      shift = ca_shift_normalized_roll_shift(ca, level);
      if ( shift > 0 ) {
        for (i=0; i<shift; i++) {
          idx[level] = i;
          idx0[level] = dim-shift+i;
          ca_shift_sync_loop(ca, level+1, idx, idx0);
        }

        for (i=0; i<dim-shift; i++) {
          idx[level] = shift+i;
          idx0[level] = i;
          ca_shift_sync_loop(ca, level+1, idx, idx0);
        }
      }
      else {
        for (i=0; i<dim+shift; i++) {
          idx[level]  = i;
          idx0[level] = -shift+i;
          ca_shift_sync_loop(ca, level+1, idx, idx0);
        }

        for (i=0; i<-shift; i++) {
          idx[level] = dim + shift + i;
          idx0[level] = i;
          ca_shift_sync_loop(ca, level+1, idx, idx0);
        }
      }
    }
    else {
      if ( shift > 0 ) {
        shift = ( shift >= dim ) ? dim : shift;

        for (i=0; i<shift; i++) {
          ; /* do nothing */
        }

        if ( shift < dim ) {
          for (i=0; i<dim-shift; i++) {
            idx[level] = shift+i;
            idx0[level] = i;
            ca_shift_sync_loop(ca, level+1, idx, idx0);
          }
        }
      }
      else {
        shift = ( -shift >= dim ) ? -dim : shift;

        if ( -shift < dim ) {
          for (i=0; i<dim+shift; i++) {
            idx[level]  = i;
            idx0[level] = -shift+i;
            ca_shift_sync_loop(ca, level+1, idx, idx0);
          }
        }

        for (i=0; i<-shift; i++) {
          ; /* do nothing */
        }
      }
    }
  }
}

static void
ca_shift_sync (CAShift *ca)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_shift_sync_loop(ca, (int16_t) 0, idx, idx0);
}

static void
ca_shift_fill_loop (CAShift *ca, char *ptr,
                  int16_t level, ca_size_t *idx0)
{
  ca_size_t dim   = ca->dim[level];
  ca_size_t shift = ca->shift[level];
  int8_t roll = ca->roll[level];
  ca_size_t i;

  if ( level == ca->rank - 1 ) {
    if ( ( ! shift ) || roll ) {
      for (i=0; i<dim; i++) {
        idx0[level] = i;
        memcpy(ca_ptr_at_index(ca->parent, idx0), ptr, ca->bytes);
      }
    }
    else {
      if ( shift > 0 ) {
        shift = ( shift >= dim ) ? dim : shift;

        for (i=0; i<shift; i++) {
          ; /* do nothing */
        }

        if ( shift < dim ) {
          for (i=0; i<dim-shift; i++) {
            idx0[level] = i;
            memcpy(ca_ptr_at_index(ca->parent, idx0), ptr, ca->bytes);
          }
        }
      }
      else {
        shift = ( -shift >= dim ) ? -dim : shift;

        if ( -shift < dim ) {
          for (i=0; i<dim+shift; i++) {
            idx0[level] = -shift+i;
            memcpy(ca_ptr_at_index(ca->parent, idx0), ptr, ca->bytes);
          }
        }

        for (i=0; i<-shift; i++) {
          ; /* do nothing */
        }
      }
    }
  }
  else {
    if ( ( ! shift ) || roll ) {
      for (i=0; i<dim; i++) {
        idx0[level] = i;
        ca_shift_fill_loop(ca, ptr, level+1, idx0);
      }
    }
    else {
      if ( shift > 0 ) {
        shift = ( shift >= dim ) ? dim : shift;

        for (i=0; i<shift; i++) {
          ; /* do nothing */
        }

        if ( shift < dim ) {
          for (i=0; i<dim-shift; i++) {
            idx0[level] = i;
            ca_shift_fill_loop(ca, ptr, level+1, idx0);
          }
        }
      }
      else {
        shift = ( -shift >= dim ) ? -dim : shift;

        if ( -shift < dim ) {
          for (i=0; i<dim+shift; i++) {
            idx0[level] = -shift+i;
            ca_shift_fill_loop(ca, ptr, level+1, idx0);
          }
        }

        for (i=0; i<-shift; i++) {
          ; /* do nothing */
        }
      }
    }
  }
}

static void
ca_shift_fill (CAShift *ca, char *ptr)
{
  ca_size_t idx0[CA_RANK_MAX];
  ca_shift_fill_loop(ca, ptr, (int16_t) 0, idx0);
}

/* ------------------------------------------------------------------- */

/*
static VALUE
rb_ca_shift_set_fill_value (VALUE self, VALUE rfval)
{
  CAShift *ca;
  CArray *cs;

  Data_Get_Struct(self, CAShift, ca);

  if ( NIL_P(rfval) ) {
    memset(ca->fill, 0, ca->bytes);
  }
  else {
    cs = ca_wrap_readonly(rfval, ca->data_type);
    memcpy(ca->fill, cs->ptr, ca->bytes);
  }

  return rfval;
}
*/

VALUE
rb_ca_shift_new (VALUE cary, ca_size_t *shift, char *fill, int8_t *roll)
{
  volatile VALUE obj;
  CArray *parent;
  CAShift *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_shift_new(parent, shift, fill, roll);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

/* rdoc:
  class CArray
    def shifted
    end
  end
*/

VALUE
rb_ca_shift (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ropt, rfval = CA_NIL, rroll = Qnil, rcs;
  CArray *ca;
  CScalar *cs;
  ca_size_t shift[CA_RANK_MAX];
  int8_t roll[CA_RANK_MAX];
  char *fill = NULL;
  int8_t i;

  Data_Get_Struct(self, CArray, ca);

  ropt = rb_pop_options(&argc, &argv);
  rb_scan_options(ropt, "roll,fill_value", &rroll, &rfval);

  if ( argc != ca->rank ) {
    rb_raise(rb_eArgError, "# of arguments mismatch with rank");
  }

  for (i=0; i<ca->rank; i++) {
    shift[i] = NUM2SIZE(argv[i]);
  }

  if ( rfval == CA_NIL ) {
    if ( rb_block_given_p() ) {
      rfval = rb_yield(self);
    }
  }
  else {
    /* rb_warn(":fill_value option for CArray#shifted will be obsoleted."); */
  }

  if ( rfval == CA_NIL ) {
    rcs = rb_cscalar_new(ca->data_type, ca->bytes, NULL);
    Data_Get_Struct(rcs, CScalar, cs);
    fill = cs->ptr;
    if ( ca_is_object_type(ca) ) {
      *(VALUE *)fill = INT2NUM(0);
    }
    else {
      memset(fill, 0, cs->bytes);
    }    
  }
  else if ( rfval == CA_UNDEF ) {
    fill = NULL;
  }
  else {
    rcs = rb_cscalar_new_with_value(ca->data_type, ca->bytes, rfval);
    Data_Get_Struct(rcs, CScalar, cs);
    fill = cs->ptr;
  }

  if ( NIL_P(rroll) ) {
    for (i=0; i<ca->rank; i++) {
      roll[i] = 0;
    }
  }
  else {
    Check_Type(rroll, T_ARRAY);

    if ( RARRAY_LEN(rroll) != ca->rank ) {
      rb_raise(rb_eArgError, "# of arguments mismatch with rank");
    }

    for (i=0; i<ca->rank; i++) {
      roll[i] = NUM2INT(rb_ary_entry(rroll, i));
    }
  }

  obj = rb_ca_shift_new(self, shift, fill, roll);

  if ( rfval == CA_UNDEF ) {
    CArray *co;
    Data_Get_Struct(obj, CArray, co);
    ca_create_mask(co);
  }

  return obj;
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_shift_s_allocate (VALUE klass)
{
  CAShift *ca;
  return Data_Make_Struct(klass, CAShift, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_shift_initialize_copy (VALUE self, VALUE other)
{
  CAShift *ca, *cs;

  Data_Get_Struct(self,  CAShift, ca);
  Data_Get_Struct(other, CAShift, cs);

  ca_shift_setup(ca, cs->parent, cs->shift, cs->fill, cs->roll);

  return self;
}

void
Init_ca_obj_shift ()
{
  rb_cCAShift = rb_define_class("CAShift", rb_cCAVirtual);

  CA_OBJ_SHIFT = ca_install_obj_type(rb_cCAShift, ca_shift_func);
  rb_define_const(rb_cObject, "CA_OBJ_SHIFT", INT2NUM(CA_OBJ_SHIFT));

  rb_define_method(rb_cCArray, "shifted", rb_ca_shift, -1);

  rb_define_alloc_func(rb_cCAShift, rb_ca_shift_s_allocate);
  rb_define_method(rb_cCAShift, "initialize_copy",
                                      rb_ca_shift_initialize_copy, 1);
}

