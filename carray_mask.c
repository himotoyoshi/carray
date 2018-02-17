/* ---------------------------------------------------------------------------

  carray_mask.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include <stdarg.h>
#include "ruby.h"
#include "carray.h"

boolean8_t *
ca_mask_ptr (void *ap)
{
  CArray *ca = (CArray*) ap;
  ca_update_mask(ca);
  return ( ca->mask ) ? (boolean8_t *) ca->mask->ptr : NULL;
}

int
ca_has_mask (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ca->mask ) {                /* mask array already created */
    return 1;
  }
  else if ( ca_is_value_array(ca) ) {
    return 0;                     /* array itself is returned by CArray#value */
  }
  else if ( ca_is_entity(ca) ) {   /* entity array */
    return ( ca->mask != NULL ) ? 1 : 0;
  }
  else if ( ca_is_caobject(ca) ) { /* CAObject */
    CAObject *co = (CAObject *) ca;
    if ( rb_obj_respond_to(co->self, rb_intern("mask_created?"), Qtrue) ) {
      return RTEST(rb_funcall(co->self, rb_intern("mask_created?"), 0));
    }
    return ( ca->mask != NULL ) ? 1 : 0;
  }
  else {
    CAVirtual *cr = (CAVirtual *) ca; /* virtual array, check parent array */
    if ( ca_has_mask(cr->parent) ) {
      ca_create_mask(ca);
      return 1;
    }
    else {
      return 0;
    }
  }
}

int
ca_is_any_masked (void *ap)
{
  CArray *ca = (CArray *) ap;
  boolean8_t *m;
  ca_size_t i;
  int flag = 0;

  ca_update_mask(ca);
  if ( ca->mask ) {
    ca_attach(ca->mask);
    m = (boolean8_t *) ca->mask->ptr;
    for (i=0; i<ca->elements; i++) {
      if ( *m++ ) {
        flag = 1;
        break;
      }
    }
    ca_detach(ca->mask);
  }

  return flag;
}

int
ca_is_all_masked (void *ap)
{
  CArray *ca = (CArray *) ap;
  boolean8_t *m;
  ca_size_t i;
  int flag;

  ca_update_mask(ca);
  if ( ca->mask ) {
    flag = 1;
    ca_attach(ca->mask);
    m = (boolean8_t *) ca->mask->ptr;
    for (i=0; i<ca->elements; i++) {
      if ( ! *m++ ) {
        flag = 0;
        break;
      }
    }
    ca_detach(ca->mask);
    return flag;
  } else {
    return 0;
  }
}

void
ca_update_mask (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ( ! ca->mask ) && ca_has_mask(ca) ) {
    ca_create_mask(ca);
  }
}

void
ca_create_mask (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ca_is_value_array(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not create mask array for the value array");
  }

  if ( ca_is_mask_array(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not create mask array for the mask array");
  }

  if ( ! ca->mask ) {
    ca_func[ca->obj_type].create_mask(ca);
    ca_set_flag(ca->mask, CA_FLAG_MASK_ARRAY);
    if ( ca_is_virtual(ca) ) {
      if ( CAVIRTUAL(ca)->attach ) {
        ca_attach(ca->mask);
        if ( ca_is_virtual(ca->mask) ) {
          CAVIRTUAL(ca->mask)->attach = CAVIRTUAL(ca)->attach;
        }
      }
    }
  }
}

void
ca_clear_mask (void *ap)
{
  CArray *ca = (CArray *) ap;

  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }
}

void
ca_setup_mask (void *ap, CArray *mask)
{
  CArray *ca = (CArray *) ap;

  ca_update_mask(ca);

  if ( mask ) {
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    ca_attach(mask);
    ca_sync_data(ca->mask, mask->ptr);
    ca_detach(mask);
  }
  else if ( ca->mask ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }
}

/*
  ca_copy_mask_overlay_n (void *ap, ca_size_t elements, int n, CArray **slist)

  + slist[i] can be NULL (simply skipped)

 */

void
ca_copy_mask_overlay_n (void *ap, ca_size_t elements, int n, CArray **slist)
{
  CArray *ca = (CArray *) ap;
  CArray *cs;
  boolean8_t *ma, *ms;
  int i, some_has_mask = 0;
  ca_size_t j;

  for (i=0; i<n; i++) {
    if ( slist[i] && ca_has_mask(slist[i]) ) {
      some_has_mask = 1;
      break;
    }
  }

  if ( some_has_mask ) {

    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }

    if ( elements > ca->elements ) {
      elements = ca->elements;
    }

    ca_attach(ca->mask);
    for (i=0; i<n; i++) {
      cs = slist[i];
      if ( ! cs ) {
        continue;
      }
      ca_update_mask(cs);
      if ( ! cs->mask ) {
        continue;
      }
      ca_attach(cs->mask);
      ma = (boolean8_t *) ca->mask->ptr;
      ms = (boolean8_t *) cs->mask->ptr;
      if ( ca_is_scalar(cs) ) {
        if ( *ms ) {
          for (j=0; j<elements; j++) {
            *ma = 1;
            ma++;
          }
        }
      }
      else {
        for (j=0; j<elements; j++) {
          if ( *ms ) {
            *ma = 1;
          }
          ma++; ms++;
        }
      }
      ca_detach(cs->mask);
    }
    ca_sync(ca->mask);
    ca_detach(ca->mask);
  }
}

void
ca_copy_mask_overlay (void *ap, ca_size_t elements, int n, ...)
{
  CArray *ca = (CArray *) ap;
  CArray **slist;
  va_list args;
  int i;

  slist = malloc_with_check(sizeof(CArray *)*n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray *);
  }
  va_end(args);

  ca_copy_mask_overlay_n(ca, elements, n, slist);

  free(slist);
}

void
ca_copy_mask_overwrite_n (void *ap, ca_size_t elements, int n, CArray **slist)
{
  CArray *ca = (CArray *) ap;

  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }

  ca_copy_mask_overlay_n(ca, elements, n, slist);
}

void
ca_copy_mask_overwrite (void *ap, ca_size_t elements, int n, ...)
{
  CArray *ca = (CArray *) ap;
  CArray **slist;
  va_list args;
  int i;

  slist = malloc_with_check(sizeof(CArray*)*n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray*);
  }
  va_end(args);

  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }

  ca_copy_mask_overlay_n(ca, elements, n, slist);

  free(slist);
}

void
ca_copy_mask (void *ap, void *ao)
{
  CArray *ca = (CArray *) ap;
  CArray *co = (CArray *) ao;
  ca_check_same_elements(ca, co);
  ca_copy_mask_overlay(ca, ca->elements, 1, co);
}

ca_size_t
ca_count_masked (void *ap)
{
  CArray *ca = (CArray *) ap;
  boolean8_t *m;
  ca_size_t i, count = 0;

  ca_update_mask(ca);

  if ( ca->mask ) {
    ca_attach(ca->mask);
    m = (boolean8_t *) ca->mask->ptr;
    for (i=0; i<ca->elements; i++) {
      if ( *m++ ) {
        count++;
      }
    }
    ca_detach(ca->mask);
  }

  return count;
}

ca_size_t
ca_count_not_masked (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ca->elements - ca_count_masked(ca);
}

#define proc_fill_bang(type)                    \
  {                                             \
    ca_size_t i;                                  \
    type *p = (type *)ca->ptr;                  \
    type  v = *(type *)fill_value;              \
    boolean8_t *m = (boolean8_t *) ca->mask->ptr; \
    for (i=0; i<ca->elements; i++) {            \
      if ( *m ) {                               \
        *p = v;                                 \
        *m = 0;                                 \
      }                                         \
      m++; p++;                                 \
    }                                           \
  }

#define proc_fill_bang_fixlen()                 \
  {                                             \
    ca_size_t i;                                  \
    char *p = ca->ptr;                          \
    boolean8_t *m = (boolean8_t *) ca->mask->ptr; \
    for (i=0; i<ca->elements; i++) {            \
      if ( *m ) {                               \
        memcpy(p, fill_value, ca->bytes);       \
        *m = 0;                                 \
      }                                         \
      m++; p+=ca->bytes;                        \
    }                                           \
  }

void
ca_unmask (void *ap, char *fill_value)
{
  CArray *ca = (CArray *) ap;

  ca_update_mask(ca);
  if ( ca->mask ) {
    if ( ! fill_value ) {
      boolean8_t zero = 0;
      ca_fill(ca->mask, &zero);
    }
    else {
      ca_attach(ca);

      switch ( ca->data_type ) {
      case CA_FIXLEN: proc_fill_bang_fixlen();  break;
      case CA_BOOLEAN:
      case CA_INT8:
      case CA_UINT8:    proc_fill_bang(int8_t);  break;
      case CA_INT16:
      case CA_UINT16:   proc_fill_bang(int16_t); break;
      case CA_INT32:
      case CA_UINT32:
      case CA_FLOAT32:  proc_fill_bang(int32_t); break;
      case CA_INT64:
      case CA_UINT64:
      case CA_FLOAT64:  proc_fill_bang(float64_t);  break;
      case CA_FLOAT128: proc_fill_bang(float128_t);  break;
#ifdef HAVE_COMPLEX_H
      case CA_CMPLX64:  proc_fill_bang(cmplx64_t);  break;
      case CA_CMPLX128: proc_fill_bang(cmplx128_t);  break;
      case CA_CMPLX256: proc_fill_bang(cmplx256_t);  break;
#endif
      case CA_OBJECT:   proc_fill_bang(VALUE);  break;
      default: rb_bug("array has an unknown data type");
      }

      ca_sync(ca);
      ca_detach(ca);
    }
  }
}

CArray *
ca_unmask_copy (void *ap, char *fill_value)
{
  CArray *ca = (CArray *) ap;
  CArray *co;
  char *p, *q;
  boolean8_t *m;
  ca_size_t i;

  co = ca_template(ca);
  ca_copy_data(ca, co->ptr);

  if ( fill_value && ca_has_mask(ca) ) {
    ca_attach(ca);
    p = ca->ptr;
    q = co->ptr;
    m = (boolean8_t *) ca->mask->ptr;
    for (i=0; i<ca->elements; i++) {
      if ( *m ) {
        memcpy(q, fill_value, ca->bytes);
      }
      m++; p+=ca->bytes; q+=co->bytes;
    }
    ca_detach(ca);
  }

  return co;
}

void
ca_invert_mask (void *ap)
{
  CArray *ca = (CArray *) ap;
  boolean8_t *m;
  ca_size_t i;

  ca_update_mask(ca);

  if ( ! ca->mask ) {
    ca_create_mask(ca);
  }

  ca_attach(ca->mask);
  m = (boolean8_t *) ca->mask->ptr;
  for (i=0; i<ca->elements; i++) {
    *m ^= 1;
    m++;
  }
  ca_detach(ca->mask);

  return;
}

boolean8_t *
ca_allocate_mask_iterator_n (int n, CArray **slist)
{
  boolean8_t *m, *mp, *ms;
  CArray *cs;
  ca_size_t j, elements = -1;
  int i, some_has_mask = 0;

  for (i=0; i<n; i++) {
    if ( slist[i] ) {
      if ( ca_has_mask(slist[i]) ) {
        some_has_mask = 1;
      }

      if ( elements >= 0 ) {
        if ( elements != slist[i]->elements ) {
          if ( elements == 1 ) {
            elements = slist[i]->elements;
          }
          else if ( ! ca_is_scalar(slist[i]) ) {
            rb_raise(rb_eRuntimeError,
                     "# of elements is different among the given arrays");
          }
        }
      }
      else {
        elements = slist[i]->elements;
      }
    }
  }

  m = malloc(sizeof(boolean8_t)*elements);
  memset(m, 0, elements);

  if ( ! some_has_mask ) {
    return m;
  }

  for (i=0; i<n; i++) {
    cs = slist[i];
    if ( ! cs ) {
      continue;
    }
    ca_update_mask(cs);
    if ( ! cs->mask ) {
      continue;
    }
    ca_attach(cs->mask);
    ms = (boolean8_t *) cs->mask->ptr;
    mp = m;
    if ( ca_is_scalar(cs) ) {
      if ( *ms ) {
        for (j=0; j<elements; j++) {
          *mp = 1;
          mp++;
        }
      }
    }
    else {
      for (j=0; j<elements; j++) {
        *mp = ( *mp || *ms );
        mp++; ms++;
      }
    }
    ca_detach(cs->mask);
  }
  return m;
}

boolean8_t *
ca_allocate_mask_iterator (int n, ...)
{
  boolean8_t *m;
  CArray **slist;
  va_list args;
  int i;

  slist = malloc_with_check(sizeof(CArray *)*n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray *);
  }
  va_end(args);

  m = ca_allocate_mask_iterator_n(n, slist);

  free(slist);

  return m;
}

/* ------------------------------------------------------------------- */

/* rdoc:
  class CArray 
    # Returns true if self has the mask array.
    def has_mask?() 
    end 
  end
*/

VALUE
rb_ca_has_mask (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_has_mask(ca) ) ? Qtrue : Qfalse;
}

/* rdoc:
  class CArray
    # Returns true if self has at least one masked element.
    def any_masked?
    end
  end
*/

VALUE
rb_ca_is_any_masked (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_any_masked(ca) ) ? Qtrue : Qfalse;
}

/* rdoc:
  class CArray
    # Returns true if all elements of self are masked.
    def all_masked?
    end
  end
*/

VALUE
rb_ca_is_all_masked (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_all_masked(ca) ) ? Qtrue : Qfalse;
}

/* rdoc:
  class CArray
    private
    def create_mask
    end
  end
*/

static VALUE
rb_ca_create_mask (VALUE self)
{
  CArray *ca;
  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);
  ca_create_mask(ca);
  return Qnil;
}

/* rdoc:
  class CArray
    private
    def update_mask
    end
  end
*/

/*
static VALUE
rb_ca_update_mask (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  ca_update_mask(ca);
  return Qnil;
}
*/

/* rdoc:
  class CArray
    # Returns new array which refers the data of <code>self</code>.
    # The data of masked elements of <code>self</code> can be accessed
    # via the returned array. The value array can't be set mask.
    def value ()
    end
  end
*/

VALUE
rb_ca_value_array (VALUE self)
{
  VALUE obj;
  CArray *ca, *co;

  Data_Get_Struct(self, CArray, ca);

  obj = rb_ca_refer_new(self, ca->data_type, ca->rank, ca->dim, ca->bytes, 0);
  Data_Get_Struct(obj, CArray, co);

  ca_set_flag(co, CA_FLAG_VALUE_ARRAY);

  return obj;
}

/* rdoc:
  class CArray
    # Returns new array which refers the mask state of <code>self</code>.
    # The mask array can't be set mask.
    def mask ()
    end
  end
*/

VALUE
rb_ca_mask_array (VALUE self)
{
  VALUE obj;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);

  ca_update_mask(ca);
  if ( ca->mask ) {
    obj = Data_Wrap_Struct(ca_class[ca->mask->obj_type],
            ca_mark, ca_free_nop, ca->mask);
    rb_ivar_set(obj, rb_intern("masked_array"), self);
    if ( OBJ_FROZEN(self) ) {
      rb_ca_freeze(obj);
    }
    return obj;
  }
  else {
    return INT2NUM(0);
  }
}

/* rdoc:
  class CArray
    # Asigns <code>new_mask</code> to the mask array of <code>self</code>.
    # If <code>self</code> doesn't have a mask array, it will be created
    # before asignment.
    def mask= (new_mask)
    end
  end
*/    

VALUE
rb_ca_set_mask (VALUE self, VALUE rval)
{
  volatile VALUE rmask = rval;
  CArray *ca, *cv;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_value_array(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not create mask for the value array");
  }

  if ( ca_is_mask_array(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not create mask for the mask array");
  }

  ca_update_mask(ca);
  if ( ! ca->mask ) {
    ca_create_mask(ca);
  }

  if ( rb_obj_is_carray(rmask) ) {
    Data_Get_Struct(rmask, CArray, cv);
    if ( ! ca_is_boolean_type(cv) ) {
      cv = ca_wrap_readonly(rval, CA_BOOLEAN);
    }
    ca_setup_mask(ca, cv);
    ca_copy_mask_overlay(ca, ca->elements, 1, cv);
    return rval;
  }
  else {
    return rb_ca_store_all(rb_ca_mask_array(self), rmask);
  }
}

/* rdoc:
  class CArray
    # Returns new boolean type array of same shape with <code>self</code>.
    # The returned array has 1 for the masked elements and
    # 0 for not-masked elements.
    def is_masked ()
    end
  end
*/

VALUE
rb_ca_is_masked (VALUE self)
{
  volatile VALUE mask;
  CArray *ca, *cm, *co;
  boolean8_t zero = 0;
  boolean8_t *m, *p;
  ca_size_t i;

  Data_Get_Struct(self, CArray, ca);

  co = carray_new(CA_BOOLEAN, ca->rank, ca->dim, ca->bytes, NULL);

  ca_update_mask(ca);
  if ( ! ca->mask ) {
    ca_fill(co, &zero);
  }
  else {
    mask = rb_ca_mask_array(self);
    Data_Get_Struct(mask, CArray, cm);
    ca_attach(cm);
    m = (boolean8_t *) cm->ptr;
    p = (boolean8_t *) co->ptr;
    for (i=0; i<ca->elements; i++) {
      *p = ( *m ) ? 1 : 0;
      m++; p++;
    }
    ca_detach(cm);
  }

  return ca_wrap_struct(co);
}

/* rdoc:
  class CArray
    # Returns new boolean type array of same shape with <code>self</code>.
    # The returned array has 0 for the masked elements and
    # 1 for not-masked elements.
    def is_not_masked ()
    end
  end
*/

VALUE
rb_ca_is_not_masked (VALUE self)
{
  volatile VALUE mask;
  CArray *ca, *cm, *co;
  boolean8_t one = 1;
  boolean8_t *m, *p;
  ca_size_t i;

  Data_Get_Struct(self, CArray, ca);

  co = carray_new(CA_BOOLEAN, ca->rank, ca->dim, ca->bytes, NULL);

  ca_update_mask(ca);
  if ( ! ca->mask ) {
    ca_fill(co, &one);
  }
  else {
    mask = rb_ca_mask_array(self);
    Data_Get_Struct(mask, CArray, cm);
    ca_attach(cm);
    m = (boolean8_t *) cm->ptr;
    p = (boolean8_t *) co->ptr;
    for (i=0; i<ca->elements; i++) {
      *p = ( *m ) ? 0 : 1;
      m++; p++;
    }
    ca_detach(cm);
  }

  return ca_wrap_struct(co);
}

/* rdoc:
  class CArray
    # Returns the number of masked elements.
    def count_masked ()
    end
  end
*/

VALUE
rb_ca_count_masked (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return SIZE2NUM(ca_count_masked(ca));
}

/* rdoc:
  class CArray
    # Returns the number of not-masked elements.
    def count_not_masked ()
    end
  end
*/

VALUE
rb_ca_count_not_masked (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return SIZE2NUM(ca_count_not_masked(ca));
}

static VALUE
rb_ca_unmask_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rfval = CA_NIL, rcs;
  CArray *ca;
  CScalar *cv;
  char *fval = NULL;

  rb_ca_modify(self);

  if ( argc >= 1 ) {
    rfval = argv[0];
  }

  Data_Get_Struct(self, CArray, ca);

  if ( rfval != CA_NIL ) {
    rcs = rb_cscalar_new_with_value(ca->data_type, ca->bytes, rfval);
    Data_Get_Struct(rcs, CScalar, cv);
    fval = cv->ptr;
  }

  ca_unmask(ca, fval);

  return self;
}

/* api: rb_ca_unmask */

VALUE
rb_ca_unmask (VALUE self)
{
  return rb_ca_unmask_method(0, NULL, self);
}

/* api: rb_ca_mask_fill */

VALUE
rb_ca_mask_fill (VALUE self, VALUE fval)
{
  return rb_ca_unmask_method(1, &fval, self);
}

/* rdoc:
  class CArray  
    # Returns new unmasked array.
    # If the optional argument <code>fill_value</code> is given,
    # the masked elements are filled by <code>fill_value</code>.
    # The returned array doesn't have the mask array.
    def unmask_copy (fill_value=nil)
    end
  end
*/

static VALUE
rb_ca_unmask_copy_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rfval = CA_NIL, rcs;
  CArray *ca, *co;
  CScalar *cv;
  char *fval = NULL;

  if ( argc >= 1 ) {
    rfval = argv[0];
  }

  Data_Get_Struct(self, CArray, ca);

  if ( rfval != CA_NIL ) {
    rcs = rb_cscalar_new_with_value(ca->data_type, ca->bytes, rfval);
    Data_Get_Struct(rcs, CScalar, cv);
    fval = cv->ptr;
  }

  co = ca_unmask_copy(ca, fval);
  obj = ca_wrap_struct(co);
  rb_ca_data_type_inherit(obj, self);
  return obj;
}

/* api: rb_ca_unmask_copy */

VALUE
rb_ca_unmask_copy (VALUE self)
{
  return rb_ca_unmask_copy_method(0, NULL, self);
}

/* api: rb_ca_mask_fill_copy */

VALUE
rb_ca_mask_fill_copy (VALUE self, VALUE fval)
{
  return rb_ca_unmask_copy_method(1, &fval, self);
}

/* CArray#invert_mask */

VALUE
rb_ca_invert_mask (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  ca_invert_mask(ca);
  return self;
}

/* rdoc:
  class CArray
    # Sets the mask array of <code>self</code> by the logical sum of
    # the mask states of <code>self</code> and arrays given in arguments.
    def inherit_mask (*argv)
    end
  end
*/

static VALUE
rb_ca_inherit_mask_method (int argc, VALUE *argv, VALUE self)
{
  CArray **slist;
  CArray *ca, *cs;
  int i;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  slist = malloc_with_check(sizeof(CArray *)*argc);
  for (i=0; i<argc; i++) {
    if ( rb_obj_is_carray(argv[i]) ) {
      Data_Get_Struct(argv[i], CArray, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  ca_copy_mask_overlay_n(ca, ca->elements, argc, slist);

  free(slist);

  return self;
}

/* api: rb_ca_inherit_mask_n */

VALUE
rb_ca_inherit_mask_n (VALUE self, int n, VALUE *rothers)
{
  return rb_ca_inherit_mask_method(n, rothers, self);
}

/* api: rb_ca_inherit_mask */

VALUE
rb_ca_inherit_mask (VALUE self, int n, ...)
{
  VALUE other;
  CArray **slist;
  CArray *ca, *cs;
  int i;
  va_list rothers;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  va_start(rothers, n);
  slist = malloc_with_check(sizeof(CArray *)*n);
  for (i=0; i<n; i++) {
    other = va_arg(rothers, VALUE);
    if ( rb_obj_is_carray(other) ) {
      Data_Get_Struct(other, CArray, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  va_end(rothers);

  ca_copy_mask_overlay_n(ca, ca->elements, n, slist);

  free(slist);

  return self;
}

/* rdoc: 
  class CArray
    # Sets the mask array of <code>self</code> by the logical sum of
    # the mask states of arrays given in arguments.
    def inherit_mask_replace (*argv)
    end
  end
*/

static VALUE
rb_ca_inherit_mask_replace_method (int argc, VALUE *argv, VALUE self)
{
  CArray **slist;
  CArray *ca, *cs;
  int i;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  slist = malloc_with_check(sizeof(CArray *)*argc);
  for (i=0; i<argc; i++) {
    if ( rb_obj_is_carray(argv[i]) ) {
      Data_Get_Struct(argv[i], CArray, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  ca_copy_mask_overwrite_n(ca, ca->elements, argc, slist);

  free(slist);

  return self;
}

/* api: rb_ca_inherit_mask_replace_n */

VALUE
rb_ca_inherit_mask_replace_n (VALUE self, int n, VALUE *rothers)
{
  return rb_ca_inherit_mask_replace_method(n, rothers, self);
}

/* api: rb_ca_inherit_mask_replace */

VALUE
rb_ca_inherit_mask_replace (VALUE self, int n, ...)
{
  VALUE other;
  CArray **slist;
  CArray *ca, *cs;
  int i;
  va_list rothers;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  va_start(rothers, n);
  slist = malloc_with_check(sizeof(CArray *)*n);
  for (i=0; i<n; i++) {
    other = va_arg(rothers, VALUE);
    if ( rb_obj_is_carray(other) ) {
      Data_Get_Struct(other, CArray, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  va_end(rothers);

  ca_copy_mask_overwrite_n(ca, ca->elements, n, slist);

  free(slist);

  return self;
}

void
Init_carray_mask ()
{
  rb_define_private_method(rb_cCArray, "__create_mask__", rb_ca_create_mask, 0);
  /*
  rb_define_private_method(rb_cCArray, "__update_mask__", rb_ca_update_mask, 0);
  */

  rb_define_method(rb_cCArray, "has_mask?",     rb_ca_has_mask, 0);
  rb_define_method(rb_cCArray, "any_masked?",   rb_ca_is_any_masked, 0);
  rb_define_method(rb_cCArray, "all_masked?",   rb_ca_is_all_masked, 0);

  rb_define_method(rb_cCArray, "value",         rb_ca_value_array, 0);
  rb_define_method(rb_cCArray, "mask",          rb_ca_mask_array, 0);
  rb_define_method(rb_cCArray, "mask=",         rb_ca_set_mask, 1);
  rb_define_method(rb_cCArray, "is_masked",     rb_ca_is_masked, 0);
  rb_define_method(rb_cCArray, "is_not_masked", rb_ca_is_not_masked, 0);
  rb_define_method(rb_cCArray, "unmask",        rb_ca_unmask_method, -1);
  rb_define_method(rb_cCArray, "unmask_copy",   rb_ca_unmask_copy_method, -1);
  rb_define_method(rb_cCArray, "invert_mask",  rb_ca_invert_mask, 0);

  rb_define_method(rb_cCArray, "inherit_mask",  rb_ca_inherit_mask_method, -1);
  rb_define_method(rb_cCArray, "inherit_mask_replace", 
                                       rb_ca_inherit_mask_replace_method, -1);

/*  These methods go to lib/carray/base.rb. */
/*  rb_define_method(rb_cCArray, "count_masked",  rb_ca_count_masked, 0); */
/*  rb_define_method(rb_cCArray, "count_not_masked", rb_ca_count_not_masked, 0); */

}

