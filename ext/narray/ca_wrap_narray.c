/* ---------------------------------------------------------------------------

  carray/ca_wrap_narray.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"

#include "narray_config.h"
#ifndef HAVE_U_INT8_T
#define HAVE_U_INT8_T
#endif
#ifndef HAVE_INT16_T
#define HAVE_INT16_T
#endif
#ifndef HAVE_INT16_T
#define HAVE_INT32_T
#endif
#ifndef HAVE_U_INT32_T
#define HAVE_U_INT32_T
#endif
#include "narray.h"

#include <math.h>

extern VALUE cNMatrix, cNVector, cNMatrixLU;

static char EMPTY_ARRAY_PTR;

/* -------------------------------------------------------------------- */

static int8_t
na_typecode_to_ca_data_type (int typecode)
{
  int8_t data_type;
  
  switch ( typecode ) {
  case NA_BYTE:
    data_type = CA_UINT8; break;
  case NA_SINT:
    data_type = CA_INT16; break;
  case NA_LINT:
    data_type = CA_INT32; break;
  case NA_SFLOAT:
    data_type = CA_FLOAT32; break;
  case NA_DFLOAT:
    data_type = CA_FLOAT64; break;
#ifdef HAVE_COMPLEX_H
  case NA_SCOMPLEX:
    data_type = CA_CMPLX64; break;
  case NA_DCOMPLEX:
    data_type = CA_CMPLX128; break;
#endif
  case NA_ROBJ:
    data_type = CA_OBJECT; break;
  default:
    rb_raise(rb_eCADataTypeError, 
             "unknown NArray typecode <%i>", typecode);
  }
  return data_type;
}

static int
ca_data_type_to_na_typecode(int8_t data_type)
{
  int typecode;

  switch ( data_type ) {
  case CA_BOOLEAN:
  case CA_UINT8:
    typecode = NA_BYTE; break;
  case CA_INT16:
    typecode = NA_SINT; break;
  case CA_INT32:
    typecode = NA_LINT; break;
  case CA_FLOAT32:
    typecode = NA_SFLOAT; break;
  case CA_FLOAT64:
    typecode = NA_DFLOAT; break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:
    typecode = NA_SCOMPLEX; break;
  case CA_CMPLX128:
    typecode = NA_DCOMPLEX; break;
#endif
  case CA_OBJECT:
    typecode = NA_ROBJ; break;
  default:
    rb_raise(rb_eRuntimeError, 
             "no corresponding NArray typecode for CArray data type <%s>",
             ca_type_name[data_type]);
  }

  return typecode;
}

/* -------------------------------------------------------------------- */

static void
cary_na_ref_free (struct NARRAY *ary)
{
  xfree(ary->shape);
  xfree(ary);
}

static void
cary_na_ref_mark (struct NARRAY *ary)
{
  rb_gc_mark( ary->ref );
}

/* -------------------------------------------------------------------- */

static VALUE
rb_cary_na_ref_new_i (int argc, VALUE *argv, VALUE self, VALUE klass)
{
  CArray *orig;
  struct NARRAY *ary;
  int i;

  Data_Get_Struct(self, CArray, orig);

  if ( ! ca_is_attached(orig) ) {
    rb_raise(rb_eRuntimeError,
             "cannot create NArray reference for not attached CArray");
  }

  ary = ALLOC(struct NARRAY);
  if ( !ary ) {
    rb_raise(rb_eRuntimeError, "cannot allocate NArray");
  }

  if ( orig->elements == 0 ) {
    ary->rank = 0;
    ary->shape = NULL;
    ary->total = 0;
    ary->ptr   = NULL;
  }
  else if ( argc == 0 ) {
    ary->rank = orig->rank;
    ary->shape = ALLOC_N(int, ary->rank);
    for (i=0; i<ary->rank; i++) {
      ary->shape[i] = orig->dim[ary->rank-1-i];
    }
    ary->total = orig->elements;
    ary->ptr   = orig->ptr;
  }
  else {
    int32_t elements = 1;
    ary->rank = argc;
    ary->shape = ALLOC_N(int, ary->rank);
    for (i=0; i<ary->rank; i++) {
      ary->shape[i] = NUM2INT(argv[i]);
      elements *= ary->shape[i];
    }
    ary->total = elements;
    ary->ptr   = orig->ptr;
    if ( elements != orig->elements ) {
      free(ary->shape);
      rb_raise(rb_eRuntimeError, "elements mismatch");
    }
  }

  ary->type = ca_data_type_to_na_typecode(orig->data_type);
  ary->ref  = self;

  return Data_Wrap_Struct(klass, cary_na_ref_mark, cary_na_ref_free, ary);
}

/* rdoc:
  class CArray
    def na
    end
    def nv
    end
    def nm
    end
  end
*/

static VALUE
rb_cary_na_ref_new (int argc, VALUE *argv, VALUE self)
{
  return rb_cary_na_ref_new_i(argc, argv, self, cNArray);
}

static VALUE
rb_cary_nv_ref_new (int argc, VALUE *argv, VALUE self)
{
  return rb_cary_na_ref_new_i(argc, argv, self, cNVector);
}

static VALUE
rb_cary_nm_ref_new (int argc, VALUE *argv, VALUE self)
{
  return rb_cary_na_ref_new_i(argc, argv, self, cNMatrix);
}

/* -------------------------------------------------------------------- */

static VALUE
rb_cary_to_na_bang_i (VALUE self, VALUE klass)
{
  volatile VALUE obj, fary;
  CArray *ca;
  struct NARRAY *na;
  int type;

  Data_Get_Struct(self, CArray, ca);

  type = ca_data_type_to_na_typecode(ca->data_type);

  if ( ca->elements == 0 ) {
    obj = na_make_empty(type, klass);
  }
  else {
    obj = na_make_object(type, ca->rank, (int *) ca->dim, klass);
    GetNArray(obj, na);

    fary = rb_ca_farray(self);
    Data_Get_Struct(fary, CArray, ca);

    ca_copy_data(ca, na->ptr);
  }

  return obj;
}

/* rdoc:
  class CArray
    def to_na!
    end
    def to_nv!
    end
    def to_nm!
    end
  end
*/

static VALUE
rb_cary_to_na_bang (VALUE self)
{
  return rb_cary_to_na_bang_i(self, cNArray);
}

static VALUE
rb_cary_to_nv_bang (VALUE self)
{
  return rb_cary_to_na_bang_i(self, cNVector);
}

static VALUE
rb_cary_to_nm_bang (VALUE self)
{
  return rb_cary_to_na_bang_i(self, cNMatrix);
}

/* -------------------------------------------------------------------- */

static VALUE
rb_cary_to_na_i (VALUE self, VALUE klass)
{
  volatile VALUE obj;
  CArray *ca;
  struct NARRAY *na;
  int type;
  int i;

  Data_Get_Struct(self, CArray, ca);

  type = ca_data_type_to_na_typecode(ca->data_type);

  if ( ca->elements == 0 ) {
    obj = na_make_empty(type, klass);
  }
  else {
    obj = na_make_object(type, ca->rank, (int *) ca->dim, klass);
    GetNArray(obj, na);

    for (i=0; i<ca->rank; i++) {
      na->shape[i] = ca->dim[ca->rank-i-1];
    }

    ca_copy_data(ca, na->ptr);
  }

  return obj;
}

/* rdoc:
  class CArray
    def to_na
    end
    def to_nv
    end
    def to_nm
    end
  end
*/

static VALUE
rb_cary_to_na (VALUE self, VALUE klass)
{
  return rb_cary_to_na_i(self, cNArray);
}

static VALUE
rb_cary_to_nv (VALUE self, VALUE klass)
{
  return rb_cary_to_na_i(self, cNVector);
}

static VALUE
rb_cary_to_nm (VALUE self, VALUE klass)
{
  return rb_cary_to_na_i(self, cNMatrix);
}

/* -------------------------------------------------------------------- */

/* rdoc:
  class NArray
    def ca
    end
  end
*/

static VALUE
rb_na_ca_ref_new (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  struct NARRAY *na;
  int32_t dim[CA_RANK_MAX];
  int8_t data_type;
  int i;

  GetNArray(self, na);

  data_type = na_typecode_to_ca_data_type(na->type);

  if ( na->total == 0 ) {
    int32_t zero = 0;
    obj = rb_carray_wrap_ptr(data_type, 1, &zero, 0, NULL,
                             &EMPTY_ARRAY_PTR, self); /* avoid ca->ptr == NULL */
  }
  else {
    if ( argc == 0 ) {
      CA_CHECK_RANK(na->rank);
      for (i=0; i<na->rank; i++) {
        dim[i] = na->shape[na->rank-i-1];
      }
      obj = rb_carray_wrap_ptr(data_type,
                               na->rank, dim, 0, NULL, na->ptr, self);
    }
    else {
      CA_CHECK_RANK(argc);
      for (i=0; i<argc; i++) {
        dim[i] = NUM2INT(argv[i]);
      }
      obj = rb_carray_wrap_ptr(data_type, argc, dim, 0, NULL, na->ptr, self);
    }
  }

  return obj;
}

/* -------------------------------------------------------------------- */

/* rdoc:
  class NArray
    def to_ca
    end
  end
*/


static VALUE
rb_na_to_ca (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  struct NARRAY *na;
  int32_t dim[CA_RANK_MAX];
  int32_t data_type;
  int32_t i;

  GetNArray(self, na);

  data_type = na_typecode_to_ca_data_type(na->type);

  if ( na->total == 0 ) {
    int32_t zero = 0;
    obj = rb_carray_new(data_type, 1, &zero, 0, NULL);
  }
  else {
    CA_CHECK_RANK(na->rank);

    for (i=0; i<na->rank; i++) {
      dim[i] = na->shape[na->rank-i-1];
    }

    obj = rb_carray_new(data_type, na->rank, dim, 0, NULL);
    Data_Get_Struct(obj, CArray, ca);

    ca_sync_data(ca, na->ptr);
  }

  return obj;
}

/* -------------------------------------------------------------------- */

/* rdoc:
  class NArray
    def to_ca!
    end
  end
*/

static VALUE
rb_na_to_ca_bang (VALUE self)
{
  volatile VALUE obj, fary;
  CArray *ca;
  struct NARRAY *na;
  int32_t dim[CA_RANK_MAX];
  int32_t data_type;
  int32_t i;

  GetNArray(self, na);

  data_type = na_typecode_to_ca_data_type(na->type);

  if ( na->total == 0 ) {
    int32_t zero = 0;
    obj = rb_carray_new(data_type, 1, &zero, 0, NULL);
  }
  else {
    CA_CHECK_RANK(na->rank);

    for (i=0; i<na->rank; i++) {
      dim[i] = na->shape[na->rank-i-1];
    }

    obj = rb_carray_new(data_type, na->rank, na->shape, 0, NULL);
    fary = rb_ca_farray(obj);
    Data_Get_Struct(fary, CArray, ca);

    ca_sync_data(ca, na->ptr);
  }

  return obj;
}

/* -------------------------------------------------------------------- */

void
Init_ca_wrap_narray ()
{
  /* rb_require("narray"); */ /* "narray" should be loaded in config.rb */

  rb_define_const(rb_cCArray, "HAVE_NARRAY", Qtrue);

  /* CArray -> NArray */
  rb_define_method(rb_cCArray, "na",     rb_cary_na_ref_new, -1);
  rb_define_method(rb_cCArray, "to_na",  rb_cary_to_na, 0);
  rb_define_method(rb_cCArray, "to_na!", rb_cary_to_na_bang, 0);

  /* CArray -> NVector */
  rb_define_method(rb_cCArray, "nv",     rb_cary_nv_ref_new, -1);
  rb_define_method(rb_cCArray, "to_nv",  rb_cary_to_nv, 0);
  rb_define_method(rb_cCArray, "to_nv!", rb_cary_to_nv_bang, 0);

  /* CArray -> NMatrix */
  rb_define_method(rb_cCArray, "nm",     rb_cary_nm_ref_new, -1);
  rb_define_method(rb_cCArray, "to_nm",  rb_cary_to_nm, 0);
  rb_define_method(rb_cCArray, "to_nm!", rb_cary_to_nm_bang, 0);

  /* NArray -> CArray */
  rb_define_method(cNArray,    "ca",     rb_na_ca_ref_new, -1);
  rb_define_method(cNArray,    "to_ca",  rb_na_to_ca, 0);
  rb_define_method(cNArray,    "to_ca!", rb_na_to_ca_bang, 0);
}

