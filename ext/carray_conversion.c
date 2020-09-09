/* ---------------------------------------------------------------------------

  carray_conversion.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

#if RUBY_VERSION_CODE >= 190
#include "ruby/io.h"
#else
#include "rubyio.h"
#endif

static void
rb_ca_to_a_loop (VALUE self, int32_t level, ca_size_t *idx, VALUE ary)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t i;

  Data_Get_Struct(self, CArray, ca);

  if ( level == ca->ndim - 1 ) {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ary, i, rb_ca_fetch_index(self, idx));
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      obj = rb_ary_new2(ca->dim[level+1]);
      rb_ca_to_a_loop(self, level+1, idx, obj);
      rb_ary_store(ary, i, obj);
    }
  }
}

/* 
@overload to_a

(Conversion)
Converts the array to Ruby's array. For higher dimension, 
the array is nested ndim-1 times.
*/

VALUE
rb_ca_to_a (VALUE self)
{
  volatile VALUE ary;
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  Data_Get_Struct(self, CArray, ca);
  ary = rb_ary_new2(ca->dim[0]);
  ca_attach(ca);
  rb_ca_to_a_loop(self, 0, idx, ary);
  ca_detach(ca);
  return ary;
}

/* @overload convert (data_type=nil, dim=nil) { |elem| ... }

(Conversion) 
Returns new array which elements are caluculated 
in the iteration block. The output array is internally created 
using `CArray#template` to which the arguments is passed.
*/

static VALUE
rb_ca_convert (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t i;

  obj = rb_apply(self, rb_intern("template"), rb_ary_new4(argc, argv));

  Data_Get_Struct(self, CArray, ca);
  ca_attach(ca);
  if ( ca_has_mask(ca) ) {
    for (i=0; i<ca->elements; i++) {
      if ( ! ca->mask->ptr[i] ) {
	rb_ca_store_addr(obj, i, rb_yield(rb_ca_fetch_addr(self, i)));
      }
      else {
	rb_ca_store_addr(obj, i, CA_UNDEF);
      }
    }
  }
  else {
    for (i=0; i<ca->elements; i++) {
      rb_ca_store_addr(obj, i, rb_yield(rb_ca_fetch_addr(self, i)));
    }
  }
  ca_detach(ca);

  return obj;
}

/* @overload dump_binary

(IO) 
Dumps the value array to the given IO stream
*/

static VALUE
rb_ca_dump_binary (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE io;
  CArray *ca;

  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_object_type(ca) ) {
    rb_raise(rb_eCADataTypeError, "don't dump object array");
  }

  if ( argc == 0 ) {
    io = rb_str_new(NULL, 0);
  }
  else if ( argc == 1 ) {
    io = argv[0];
  }
  else {
    rb_raise(rb_eArgError, "invalid # of arguments (%i for 1)", argc);
  }

  switch ( TYPE(io) ) {
  case T_STRING:
    if ( ca_length(ca) != RSTRING_LEN(io) ) {
      rb_str_resize(io, ca_length(ca));
    }
    ca_copy_data(ca, StringValuePtr(io));
    StringValuePtr(io)[ca_length(ca)] = '\0';
    OBJ_TAINT(io);
    break;
#if RUBY_VERSION_CODE >= 190
  case T_FILE: {
    volatile VALUE str;
    rb_io_t *iop;
    GetOpenFile(io, iop);
    rb_io_check_writable(iop);
    ca_attach(ca);
    str = rb_str_new(ca->ptr, ca->bytes*ca->elements);
    rb_io_write(io, str);
    ca_detach(ca);
    break;
  }
#else
  case T_FILE: {
    OpenFile *iop;
    size_t total;
    GetOpenFile(io, iop);
    rb_io_check_writable(iop);
    ca_attach(ca);
    total = fwrite(ca->ptr, ca->bytes, ca->elements, iop->f);
    ca_detach(ca);
    if ( total < ca->elements ) {
      rb_raise(rb_eIOError, "I/O write error in CArray#dump_binary");
    }
    break;
  }
#endif
  default:
    if ( rb_respond_to(io, rb_intern("write") ) ) {
      VALUE buf = rb_str_new(NULL, ca_length(ca));
      ca_copy_data(ca, StringValuePtr(buf));
      OBJ_INFECT(buf, self);
      rb_funcall(io, rb_intern("write"), 1, buf);
    }
    else {
      rb_raise(rb_eRuntimeError, "IO like object should have 'write' method");
    }
  }

  return io;
}

/* @overload to_s

(Conversion) 
Dumps the value array to a string.
*/

static VALUE
rb_ca_to_s (VALUE self)
{
  return rb_ca_dump_binary(0, NULL, self);
}

/* @overload load_binary (io)

(IO) 
Loads the value array from the given IO stream
*/

static VALUE
rb_ca_load_binary (VALUE self, VALUE io)
{
  CArray *ca;

  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_object_type(ca) ) {
    rb_raise(rb_eCADataTypeError, "don't load object array");
  }

  ca_allocate(ca);

  switch ( TYPE(io) ) {
  case T_STRING:
    if ( ca_length(ca) > RSTRING_LEN(io) ) {
      rb_raise(rb_eRuntimeError,
               "data size mismatch (%lld for %lld)",
               (ca_size_t) RSTRING_LEN(io), (ca_size_t) ca_length(ca));
    }
    memcpy(ca->ptr, StringValuePtr(io), ca_length(ca));
    OBJ_INFECT(self, io);
    break;
  default:
    if ( rb_respond_to(io, rb_intern("read") ) ) {
      VALUE buf = rb_funcall(io, rb_intern("read"), 1, SIZE2NUM(ca_length(ca)));
      memcpy(ca->ptr, StringValuePtr(buf), ca_length(ca));
      OBJ_INFECT(self, io);
    }
    else {
      rb_raise(rb_eRuntimeError, "IO like object should have 'read' method");
    }
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

void *
ca_to_cptr (void *ap)
{
  CArray *ca = (CArray *) ap;
  void **ptr, **p, **r;
  char *q;
  ca_size_t offset[CA_RANK_MAX];
  ca_size_t count[CA_RANK_MAX];
  ca_size_t ptr_num;
  ca_size_t i, j;
  
  if ( ! ca_is_attached(ca) ) {
    rb_raise(rb_eRuntimeError, "[BUG] ca_to_cptr called for detached array");
  }
  
  if ( ca->ndim == 1 ) {
    rb_raise(rb_eRuntimeError, "[BUG] ca_to_cptr called for ndim-1 array");
  }

  offset[0] = 0;  
  count[0]  = ca->dim[0];
  ptr_num   = count[0];
  for (i=1; i<ca->ndim-1; i++) {
    offset[i] = ptr_num;
    count[i]  = count[i-1] * ca->dim[i];
    ptr_num  += count[i];
  }

  ptr = malloc(sizeof(void*)*ptr_num);

  i = ca->ndim-2;
  p = ptr + offset[i];
  q = (char *)ca->ptr;
  for (j=0; j<count[i]; j++) {
    *p = (void*)q;
    p++; q += ca->dim[ca->ndim-1] * ca->bytes;
  }

  for (i=ca->ndim-3; i>=0; i--) {
    p = ptr + offset[i];
    r = ptr + offset[i+1];
    for (j=0; j<count[i]; j++) {
      *p = (void*)r;
      p++; r+=ca->dim[i+1]; 
    }
  }
  
  return ptr;
}


/* @overload str_format (*fmts)

(Conversion) 
Creates object type array consist of string using the "::format" method.
The Multiple format strings are given, they are applied cyclic in turn.
*/


static VALUE
rb_ca_format (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, elem, val;
  CArray *ca;
  ca_size_t i, j;
  ID id_format = rb_intern("format");

  Data_Get_Struct(self, CArray, ca);

  obj = rb_ca_template_with_type(self, INT2NUM(CA_OBJECT), INT2NUM(0));

  ca_attach(ca);
  if ( ca_has_mask(ca) ) {
    j = 0;
    for (i=0; i<ca->elements; i++) {
      val = CA_UNDEF;
      if ( ! ca->mask->ptr[i] ) {
        elem = rb_ca_fetch_addr(self, i);
        val = rb_funcall(elem, id_format, 2, argv[j], elem);
      }
      rb_ca_store_addr(obj, i, val);
      j++;
      j = j % argc; /* cyclic referencing of argv */
    }
  }
  else {
    j = 0;
    for (i=0; i<ca->elements; i++) {
      elem = rb_ca_fetch_addr(self, i);
      val = rb_funcall(elem, id_format, 2, argv[j], elem);
      rb_ca_store_addr(obj, i, val);
      j++;
      j = j % argc; /* cyclic referencing of argv */
    }
  }
  ca_detach(ca);

  return obj;
}


#include <time.h>

#ifdef HAVE_STRPTIME

/* @overload str_strptime (fmt)

(Conversion) 
Creates object type array consist of Time objects 
which are created by 'Time.strptime' applied to the elements of the object.
This method assumes all the elements of the objetct to be String.
*/

static VALUE
rb_ca_strptime (VALUE self, VALUE rfmt)
{
  volatile VALUE obj, elem, val;
  CArray *ca;
  char *fmt;
  struct tm tmv;
  ca_size_t i;
  
  ca = ca_wrap_readonly(self, CA_OBJECT);

  if ( ! ca_is_object_type(ca) ) {
    rb_raise(rb_eRuntimeError, "strptime can be applied only to object type.");
  }

  Check_Type(rfmt, T_STRING);
  fmt = (char *) StringValuePtr(rfmt);

  obj = rb_ca_template(self);

  ca_attach(ca);
  if ( ca_has_mask(ca) ) {
    for (i=0; i<ca->elements; i++) {
      val = CA_UNDEF;
      if ( ! ca->mask->ptr[i] ) {
        elem = rb_ca_fetch_addr(self, i);
        if ( TYPE(elem) == T_STRING ) {
          memset(&tmv, 0, sizeof(struct tm));
          if ( strptime(StringValuePtr(elem), fmt, &tmv) ) {
            val = rb_time_new(mktime(&tmv), 0);
          }  
        }
      }
      rb_ca_store_addr(obj, i, val);      
    }
  }
  else {
    for (i=0; i<ca->elements; i++) {
      val = CA_UNDEF;
      elem = rb_ca_fetch_addr(self, i);
      if ( TYPE(elem) == T_STRING ) {
        memset(&tmv, 0, sizeof(struct tm));
        if ( strptime(StringValuePtr(elem), fmt, &tmv) ) {
          val = rb_time_new(mktime(&tmv), 0);
        }  
      }
      rb_ca_store_addr(obj, i, val);      
    }
  }
  ca_detach(ca);

  return obj;
}

#endif

/* @overload time_strftime (fmt)

(Conversion) 
Creates object type array consist of strings
which are created by 'Time#strftime' applied to the elements of the object.
This method assumes all the elements of the objetct to be Time or DateTime.
*/

static VALUE
rb_ca_strftime (VALUE self, VALUE rfmt)
{
  volatile VALUE obj, elem, val;
  CArray *ca;
  ca_size_t i;
  ID id_strftime = rb_intern("strftime");
  
  ca = ca_wrap_readonly(self, CA_OBJECT);

  if ( ! ca_is_object_type(ca) ) {
    rb_raise(rb_eRuntimeError, "strptime can be applied only to object type.");
  }

  obj = rb_ca_template(self);

  ca_attach(ca);
  if ( ca_has_mask(ca) ) {
    for (i=0; i<ca->elements; i++) {
      val = CA_UNDEF;
      if ( ! ca->mask->ptr[i] ) {
        elem = rb_ca_fetch_addr(self, i);
        val = rb_funcall(elem, id_strftime, 1, rfmt);
      }
      rb_ca_store_addr(obj, i, val);      
    }
  }
  else {
    for (i=0; i<ca->elements; i++) {
      elem = rb_ca_fetch_addr(self, i);
      val = rb_funcall(elem, id_strftime, 1, rfmt);
      rb_ca_store_addr(obj, i, val);      
    }
  }
  ca_detach(ca);

  return obj;
}

/* @private

*/

static VALUE 
rb_test_ca_to_cptr (VALUE self)
{
  CArray *ca;
  double ****a;
  int i, j, k, l;
  
  Data_Get_Struct(self, CArray, ca);
  
  ca_attach(ca);

  a = ca_to_cptr(ca);
  for (i=0; i<ca->dim[0]; i++) {
    for (j=0; j<ca->dim[1]; j++) {
      for (k=0; k<ca->dim[2]; k++) {
        for (l=0; l<ca->dim[3]; l++) {
          printf("(%i, %i, %i, %i) -> %g\n", i, j, k, l, a[i][j][k][l]);
        }
      }
    } 
  }
  free(a);

  ca_detach(ca);
  
  return Qnil;
}

void
Init_carray_conversion ()
{
  rb_define_method(rb_cCArray, "to_a", rb_ca_to_a, 0);
  rb_define_method(rb_cCArray, "convert", rb_ca_convert, -1);

  rb_define_method(rb_cCArray, "dump_binary", rb_ca_dump_binary, -1);
  rb_define_method(rb_cCArray, "to_s", rb_ca_to_s, 0);
  rb_define_method(rb_cCArray, "load_binary", rb_ca_load_binary, 1);

  /* DO NOT define CArray#to_ary, it makes trouble with various situations */
  /* rb_define_method(rb_cCArray, "to_ary", rb_ca_to_a, 0); */ 

  rb_define_method(rb_cCArray, "str_format", rb_ca_format, -1); 

#ifdef HAVE_STRPTIME
  rb_define_method(rb_cCArray, "str_strptime", rb_ca_strptime, 1);
#endif
  
  rb_define_method(rb_cCArray, "time_strftime", rb_ca_strftime, 1);

  rb_define_method(rb_cCArray, "test_ca_to_cptr", rb_test_ca_to_cptr, 0);

}
