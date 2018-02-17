/* ---------------------------------------------------------------------------

  carray_generate.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"

/* ----------------------------------------------------------------- */

/* rdoc:
  class CArray
    # Sets true at the given index for the boolean array and returns self.
    # It accept the arguments same as for CArray#[].
    def set (*argv)
    end
    # Sets false at the given index for the boolean array and returns self.
    # It accept the arguments same as for CArray#[].
    def unset (*argv)
    end
  end
*/

static VALUE
rb_ca_boolean_set (int argc, VALUE *argv, VALUE self)
{
  VALUE one = INT2NUM(1);
  rb_ca_modify(self);
  if ( ! rb_ca_is_boolean_type(self) ) {
    rb_raise(rb_eCADataTypeError, "reciever should be a boolean array");
  }
  rb_ca_store2(self, argc, argv, one);
  return self;
}

static VALUE
rb_ca_boolean_unset (int argc, VALUE *argv, VALUE self)
{
  VALUE zero = INT2NUM(0);
  rb_ca_modify(self);
  if ( ! rb_ca_is_boolean_type(self) ) {
    rb_raise(rb_eCADataTypeError, "reciever should be a boolean array");
  }
  rb_ca_store2(self, argc, argv, zero);
  return self;
}

/* ----------------------------------------------------------------- */

/* rdoc:
  class CArray
    # Returns the 1d index array for non-zero elements of self
    def where
    end
  end
*/

VALUE
rb_ca_where (VALUE self)
{
  volatile VALUE bool, obj;
  CArray *ca, *co;
  boolean8_t *p, *m;
  ca_size_t *q;
  ca_size_t i, count;

  bool = ( ! rb_ca_is_boolean_type(self) ) ? rb_ca_to_boolean(self) : self;

  Data_Get_Struct(bool, CArray, ca);

  ca_attach(ca);

  /* calculate elements of output array */
  p = (boolean8_t *) ca->ptr;
  m = ca_mask_ptr(ca);
  count = 0;
  if ( m ) {
    for (i=0; i<ca->elements; i++) {
      if ( ( ! *m ) && ( *p ) ) { count++; }    /* not-masked && true */
      m++; p++;
    }
  }
  else {
    for (i=0; i<ca->elements; i++) {
      if ( *p ) { count++; }                    /* true */ 
      p++;
    }
  }

  /* create output array */
  obj = rb_carray_new(CA_SIZE, 1, &count, 0, NULL);
  Data_Get_Struct(obj, CArray, co);

  /* store address which elements is true to output array */
  p = (boolean8_t *) ca->ptr;
  q = (ca_size_t *) co->ptr;
  m = ca_mask_ptr(ca);
  if ( m )  {
    for (i=0; i<ca->elements; i++) {  /* not-masked && true */
      if ( ( ! *m ) && ( *p ) ) { *q = i; q++; }
      m++; p++; 
    }
  }
  else {                              /* true */
    for (i=0; i<ca->elements; i++) {
      if ( *p ) { *q = i; q++; }
      p++;
    }
  }

  ca_detach(ca);

  return obj;
}

/* ----------------------------------------------------------------- */

#define proc_seq_bang(type, from, to)       \
  {                                         \
    type *p = (type *)ca->ptr;              \
    ca_size_t i;                              \
    if ( NIL_P(roffset) && NIL_P(rstep) ) { \
      for (i=0; i<ca->elements; i++) {    \
        *p++ = (type) to(i);                     \
      }                                   \
    }                                     \
    else if ( rb_obj_is_kind_of(rstep, rb_cFloat) ||              \
              rb_obj_is_kind_of(roffset, rb_cFloat) ) {            \
      type offset = (NIL_P(roffset)) ? (type) 0 : (type) from(roffset);  \
      double step = (NIL_P(rstep)) ? 1 : NUM2DBL(rstep);          \
      for (i=0; i<ca->elements; i++) {    \
        *p++ = (type) to(step*i+offset);         \
      }                                   \
    }                                     \
    else {                                \
      type offset = (NIL_P(roffset)) ? (type) 0 : (type) from(roffset); \
      type step   = (NIL_P(rstep)) ? (type) 1 : (type) from(rstep);     \
      for (i=0; i<ca->elements; i++) {    \
        *p++ = (type) to(step*i+offset);         \
      }                                   \
    }                                     \
  }

#define proc_seq_bang_with_block(type, from, to)       \
  {                                                    \
    type *p = (type *)ca->ptr;                         \
    ca_size_t i;                                         \
    if ( NIL_P(roffset) && NIL_P(rstep) ) {            \
      for (i=0; i<ca->elements; i++) {                 \
        *p++ = (type) from(rb_yield(SIZE2NUM(i)));             \
      }                                                \
    }                                                             \
    else if ( rb_obj_is_kind_of(rstep, rb_cFloat) ||              \
              rb_obj_is_kind_of(roffset, rb_cFloat)) {            \
      type offset = (NIL_P(roffset)) ? (type) 0 : (type) from(roffset);  \
      double step = (NIL_P(rstep)) ? 1 : NUM2DBL(rstep);          \
      for (i=0; i<ca->elements; i++) {                            \
        *p++ = (type) from(rb_yield(rb_float_new(step*i+offset)));       \
      }                                                           \
    }                                                             \
    else {                                                        \
      type offset = (NIL_P(roffset)) ? (type) 0 : (type) from(roffset);  \
      type step   = (NIL_P(rstep)) ? (type) 1 : (type) from(rstep);      \
      for (i=0; i<ca->elements; i++) {                            \
        *p++ = (type) from(rb_yield(SIZE2NUM(step*i+offset)));            \
      }                                                           \
    }                                                             \
  }

static VALUE
rb_ca_seq_bang_object (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE roffset, rstep, rval, rmethod = Qnil;
  CArray *ca;
  VALUE *p;
  ca_size_t i;

  Data_Get_Struct(self, CArray, ca);

  rb_scan_args((argc>2) ? 2 : argc, argv, "02", (VALUE *) &roffset, (VALUE *) &rstep);

  if ( TYPE(rstep) == T_SYMBOL ) {                /* e.g. a.seq("a", :succ) */
    rmethod = rstep;
    rstep = Qnil;
  }

  ca_allocate(ca);

  if ( ca_has_mask(ca) ) {
    ca_clear_mask(ca);                            /* clear all mask */
  }

  p = (VALUE *)ca->ptr;
  if ( rb_obj_is_kind_of(roffset, rb_cFloat) ||
       rb_obj_is_kind_of(rstep, rb_cFloat) ) {  /* a.seq(0.0, 1.0) */
    double offset = ( NIL_P(roffset) ) ? 0 : NUM2DBL(roffset);
    double step = ( NIL_P(rstep) ) ? 1 : NUM2DBL(rstep);
    for (i=0; i<ca->elements; i++) {
      *p++ = rb_float_new(step*i+offset);
    }
  }
  else if ( NIL_P(roffset) ) {
    if ( ! NIL_P(rstep) ) {                     /* a.seq(nil, 1) */
      rb_raise(rb_eArgError,
               "nil is invalid as offset for seq([offset[,step])");
    }
    for (i=0; i<ca->elements; i++) {            /* a.seq() */
      *p++ = INT2NUM(i);
    }
  }
  else if ( ! NIL_P(rmethod) ) {                /* a.seq(obj, :method) */
    ID id_method = SYM2ID(rmethod);
    *p++ = rval = roffset;
    for (i=1; i<ca->elements; i++) {
      *p++ = rval = rb_funcall2(rval, id_method, argc-2, argv+2);
    }
  }
  else {                                        /* a.seq(obj, step) */
    ID id_plus = rb_intern("+");
    rstep   = ( NIL_P(rstep) ) ? INT2NUM(1) : rstep;
    *p++ = rval = roffset;
    for (i=1; i<ca->elements; i++) {
      *p++ = rval = rb_funcall(rval, id_plus, 1, rstep);
    }
  }

  if ( rb_block_given_p() ) {
    p = (VALUE *)ca->ptr;
    for(i=0; i<ca->elements; i++) {
      *p = rb_yield(*p);
      p++;
    }
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

/* rdoc:
  class CArray
    # call-seq:
    #   seq (init_val=0, step=1)
    #   seq (init_val=0, step=1) {|x| ... }
    #   seq (init_val=0, step=A_symbol)            ### for object array
    #   seq (init_val=0, step=A_symbol) {|x| ...}  ### for object array
    #
    # Generates sequential data with initial value `init_val` 
    # and step value `step`. For object array, if the second argument
    # is Symbol object, it will be interpreted as stepping method and 
    # it is called for the last element in each step.
    #
    def seq (init_val=0, step=1)
    end
    # 
    def seq! (init_val=0, step=1)
    end
  end
*/

static VALUE
rb_ca_seq_bang_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE roffset, rstep;
  CArray *ca;

  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);

  /* delegate to rb_ca_seq_bang_object if data_type is object */
  if ( ca_is_object_type(ca) ) {
    return rb_ca_seq_bang_object(argc, argv, self);
  }

  rb_scan_args(argc, argv, "02", (VALUE *) &roffset, (VALUE *) &rstep);

  ca_allocate(ca);

  if ( ca_has_mask(ca) ) {
    ca_clear_mask(ca);              /* clear all mask */
  }

  if ( rb_block_given_p() ) {       /* with block */
    switch ( ca->data_type ) {
    case CA_INT8:     proc_seq_bang_with_block(int8_t,     NUM2LONG, );   break;
    case CA_UINT8:    proc_seq_bang_with_block(uint8_t,   NUM2ULONG, );  break;
    case CA_INT16:    proc_seq_bang_with_block(int16_t,    NUM2LONG, ) ;  break;
    case CA_UINT16:   proc_seq_bang_with_block(uint16_t,  NUM2ULONG, );  break;
    case CA_INT32:    proc_seq_bang_with_block(int32_t,    NUM2LONG, );   break;
    case CA_UINT32:   proc_seq_bang_with_block(uint32_t,  NUM2ULONG, );  break;
    case CA_INT64:    proc_seq_bang_with_block(int64_t,    NUM2LL, );     break;
    case CA_UINT64:   proc_seq_bang_with_block(uint64_t,  rb_num2ull, ); break;
    case CA_FLOAT32:  proc_seq_bang_with_block(float32_t,  NUM2DBL, );    break;
    case CA_FLOAT64:  proc_seq_bang_with_block(float64_t,  NUM2DBL, );    break;
    case CA_FLOAT128: proc_seq_bang_with_block(float128_t, NUM2DBL, );    break;
#ifdef HAVE_COMPLEX_H
    case CA_CMPLX64:  proc_seq_bang_with_block(cmplx64_t, (cmplx64_t) NUM2CC,); break;
    case CA_CMPLX128: proc_seq_bang_with_block(cmplx128_t, NUM2CC, );     break;
    case CA_CMPLX256: proc_seq_bang_with_block(cmplx256_t, (cmplx256_t) NUM2CC, ); break;
#endif
    default: rb_raise(rb_eCADataTypeError,
                      "invalid data type of receiver");
    }
  }
  else {                            /* without block */
    switch ( ca->data_type ) {
    case CA_INT8:     proc_seq_bang(int8_t,     NUM2LONG, );   break;
    case CA_UINT8:    proc_seq_bang(uint8_t,   NUM2ULONG, );  break;
    case CA_INT16:    proc_seq_bang(int16_t,    NUM2LONG, ) ;  break;
    case CA_UINT16:   proc_seq_bang(uint16_t,  NUM2ULONG, );  break;
    case CA_INT32:    proc_seq_bang(int32_t,    NUM2LONG, );   break;
    case CA_UINT32:   proc_seq_bang(uint32_t,  NUM2ULONG, );  break;
    case CA_INT64:    proc_seq_bang(int64_t,    NUM2LL, );     break;
    case CA_UINT64:   proc_seq_bang(uint64_t,  rb_num2ull, ); break;
    case CA_FLOAT32:  proc_seq_bang(float32_t,  NUM2DBL, );    break;
    case CA_FLOAT64:  proc_seq_bang(float64_t,  NUM2DBL, );    break;
    case CA_FLOAT128: proc_seq_bang(float128_t, NUM2DBL, );    break;
#ifdef HAVE_COMPLEX_H
    case CA_CMPLX64:  proc_seq_bang(cmplx64_t, (cmplx64_t) NUM2CC, );   break;
    case CA_CMPLX128: proc_seq_bang(cmplx128_t, NUM2CC, );              break;
    case CA_CMPLX256: proc_seq_bang(cmplx256_t, (cmplx256_t) NUM2CC, ); break;
#endif
    default: rb_raise(rb_eCADataTypeError,
                      "invalid data type of reciever");
    }
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

static VALUE
rb_ca_seq_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out = rb_ca_template(self);
  return rb_ca_seq_bang_method(argc, argv, out);
}

VALUE
rb_ca_seq_bang (VALUE self, VALUE offset, VALUE step)
{
  VALUE args[2] = { offset, step };
  return rb_ca_seq_bang_method(2, args, self);
}

VALUE
rb_ca_seq_bang2 (VALUE self, int n, VALUE *args)
{
  return rb_ca_seq_bang_method(n, args, self);
}

VALUE
rb_ca_seq (VALUE self, VALUE offset, VALUE step)
{
  VALUE args[2] = { offset, step };
  return rb_ca_seq_method(2, args, self);
}

VALUE
rb_ca_seq2 (VALUE self, int n, VALUE *args)
{
  return rb_ca_seq_method(n, args, self);
}

/* ----------------------------------------------------------------- */


void
ca_swap_bytes (char *ptr, ca_size_t bytes, ca_size_t elements)
{
  char *p;
  char val;
  ca_size_t i;

#define SWAP_BYTE(a, b) (val = (a), (a) = (b), (b) = val)

  switch ( bytes ) {
  case 1:
    break;
  case 2:
    #ifdef _OPENMP
    #pragma omp parallel for private(p)
    #endif
    for (i=0; i<elements; i++) {
      p = ptr + 2*i;
      SWAP_BYTE(p[0], p[1]);
    }
    break;
  case 4:
    #ifdef _OPENMP
    #pragma omp parallel for private(p)
    #endif
    for (i=0; i<elements; i++) {
      p = ptr + 4*i;
      SWAP_BYTE(p[0], p[3]);
      SWAP_BYTE(p[1], p[2]);
    }
    break;
  case 8:
    #ifdef _OPENMP
    #pragma omp parallel for private(p)
    #endif
    for (i=0; i<elements; i++) {
      p = ptr + 8*i;
      SWAP_BYTE(p[0], p[7]);
      SWAP_BYTE(p[1], p[6]);
      SWAP_BYTE(p[2], p[5]);
      SWAP_BYTE(p[3], p[4]);
    }
    break;
  case 16:
    #ifdef _OPENMP
    #pragma omp parallel for private(p)
    #endif
    for (i=0; i<elements; i++) {
      p = ptr + 16*i;
      SWAP_BYTE(p[0], p[15]);
      SWAP_BYTE(p[1], p[14]);
      SWAP_BYTE(p[2], p[13]);
      SWAP_BYTE(p[3], p[12]);
      SWAP_BYTE(p[4], p[11]);
      SWAP_BYTE(p[5], p[10]);
      SWAP_BYTE(p[6], p[9]);
      SWAP_BYTE(p[7], p[8]);
    }
    break;
  default: {
    char *p1, *p2;
    #ifdef _OPENMP
    #pragma omp parallel for private(p,p1,p2)
    #endif
    for (i=0; i<elements; i++) {
      p = ptr + i*bytes;
      p1 = p;
      p2 = p+bytes-1;
      while (p1<p2) {
        SWAP_BYTE(*p1, *p2);
        p1++; p2--;
      }
    }
    break;
  }
  }

#undef SWAP_BYTE

}

/* rdoc:
  class CArray
    # Swaps the byte order of each element.
    def swap_bytes
    end
    # 
    def swap_bytes!
    end
  end
*/

VALUE
rb_ca_swap_bytes_bang (VALUE self)
{
  CArray *ca;
  int i;

  rb_ca_modify(self);

  if ( rb_ca_is_object_type(self) ) {
    rb_raise(rb_eCADataTypeError, "object array can't swap bytes");
  }

  if ( rb_ca_is_fixlen_type(self) ) {
    if ( rb_ca_has_data_class(self) ) {
      volatile VALUE members = rb_ca_fields(self);
      Check_Type(members, T_ARRAY);
      for (i=0; i<RARRAY_LEN(members); i++) {
        volatile VALUE obj = rb_ary_entry(members, i);
        rb_ca_swap_bytes_bang(obj);
      }
    }
    else {
      Data_Get_Struct(self, CArray, ca);
      ca_attach(ca);
      ca_swap_bytes(ca->ptr, ca->bytes, ca->elements);
      ca_sync(ca);
      ca_detach(ca);
    }
    return self;
  }

  Data_Get_Struct(self, CArray, ca);

  switch ( ca->data_type ) {
  case CA_INT16:
  case CA_UINT16:
    ca_attach(ca);
    ca_swap_bytes(ca->ptr, 2, ca->elements);
    ca_sync(ca);
    ca_detach(ca);
    break;
  case CA_INT32:
  case CA_UINT32:
  case CA_FLOAT32:
    ca_attach(ca);
    ca_swap_bytes(ca->ptr, 4, ca->elements);
    ca_sync(ca);
    ca_detach(ca);
    break;
  case CA_INT64:
  case CA_UINT64:
  case CA_FLOAT64:
    ca_attach(ca);
    ca_swap_bytes(ca->ptr, 8, ca->elements);
    ca_sync(ca);
    ca_detach(ca);
    break;
  case CA_FLOAT128:
    ca_attach(ca);
    ca_swap_bytes(ca->ptr, 16, ca->elements);
    ca_sync(ca);
    ca_detach(ca);
    break;
  case CA_CMPLX64:
    ca_attach(ca);
    ca_swap_bytes(ca->ptr, 4, 2 * ca->elements);
    ca_sync(ca);
    ca_detach(ca);
    break;
  case CA_CMPLX128:
    ca_attach(ca);
    ca_swap_bytes(ca->ptr, 8, 2 * ca->elements);
    ca_sync(ca);
    ca_detach(ca);
    break;
  case CA_CMPLX256:
    ca_attach(ca);
    ca_swap_bytes(ca->ptr, 16, 2 * ca->elements);
    ca_sync(ca);
    ca_detach(ca);
    break;
  }

  return self;
}

VALUE
rb_ca_swap_bytes (VALUE self)
{
  volatile VALUE out = rb_ca_copy(self);
  return rb_ca_swap_bytes_bang(out);
}

/* ----------------------------------------------------------------- */

#define proc_trim_bang(type, from)                                 \
  {                                                                \
    type *ptr = (type *) ca->ptr;                                  \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type min  = (type) from(rmin);                                 \
    type max  = (type) from(rmax);                                 \
    ca_size_t i;                                                     \
    if ( m && rfval == CA_UNDEF) {                                 \
      for (i=ca->elements; i; i--, ptr++, m++) {                   \
        if ( ! *m ) {                                              \
          if ( *ptr < min || *ptr >= max )                         \
            *m = 1;                                                \
        }                                                          \
      }                                                            \
    }                                                              \
    else {                                                         \
      int  has_fill = ! ( NIL_P(rfval) );                          \
      type fill = (has_fill) ? (type) from(rfval) : (type) 0;             \
      if ( m ) {                                                   \
        for (i=ca->elements; i; i--, ptr++) {                      \
          if ( ! *m++ ) {                                          \
            if ( *ptr >= max )                                     \
              *ptr = (has_fill) ? fill : max;                      \
            else if ( *ptr < min )                                 \
              *ptr = (has_fill) ? fill : min;                      \
          }                                                        \
        }                                                          \
      }                                                            \
      else {                                                       \
        for (i=ca->elements; i; i--, ptr++) {                      \
          if ( *ptr >= max )                                       \
            *ptr = (has_fill) ? fill : max;                        \
          else if ( *ptr < min )                                   \
            *ptr = (has_fill) ? fill : min;                        \
        }                                                          \
      }                                                            \
    }                                                              \
  }

/* rdoc:
  class CArray
    # trims the data into the range between min and max. If `fill_value`
    # is given, the element out of the range between min and max is filled
    # by `fill_value`
    def trim (min, max, fill_value=nil)
    end
    #
    def trim! (min, max, fill_value=nil)
    end
  end
*/

static VALUE
rb_ca_trim_bang (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rmin, rmax, rfval;
  CArray *ca;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  rb_scan_args(argc, argv, "21", (VALUE *) &rmin, (VALUE *) &rmax, (VALUE *) &rfval);

  if ( rfval == CA_UNDEF ) {
    ca_create_mask(ca);
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_INT8:     proc_trim_bang(int8_t,    NUM2INT);  break;
  case CA_UINT8:    proc_trim_bang(uint8_t,   NUM2UINT); break;
  case CA_INT16:    proc_trim_bang(int16_t,    NUM2INT);  break;
  case CA_UINT16:   proc_trim_bang(uint16_t,  NUM2INT);  break;
  case CA_INT32:    proc_trim_bang(int32_t,    NUM2LONG);  break;
  case CA_UINT32:   proc_trim_bang(uint32_t,  NUM2LONG);  break;
  case CA_INT64:    proc_trim_bang(int64_t,    NUM2LONG);  break;
  case CA_UINT64:   proc_trim_bang(uint64_t,  NUM2LONG);  break;
  case CA_FLOAT32:  proc_trim_bang(float32_t,  NUM2DBL);   break;
  case CA_FLOAT64:  proc_trim_bang(float64_t,  NUM2DBL);   break;
  case CA_FLOAT128: proc_trim_bang(float128_t, NUM2DBL);   break;
  default:
    rb_raise(rb_eCADataTypeError,
             "can not trim for non-numeric or complex data type");
  }

  ca_detach(ca);

  return self;
}

static VALUE
rb_ca_trim (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out = rb_ca_copy(self);
  return rb_ca_trim_bang(argc, argv, out);
}


void
Init_carray_generate ()
{
  rb_define_method(rb_cCArray, "set",   rb_ca_boolean_set, -1);
  rb_define_method(rb_cCArray, "unset", rb_ca_boolean_unset, -1);

  rb_define_method(rb_cCArray, "where", rb_ca_where, 0);
  rb_define_method(rb_cCArray, "seq!", rb_ca_seq_bang_method, -1);
  rb_define_method(rb_cCArray, "seq", rb_ca_seq_method, -1);
  rb_define_method(rb_cCArray, "swap_bytes!", rb_ca_swap_bytes_bang, 0);
  rb_define_method(rb_cCArray, "swap_bytes", rb_ca_swap_bytes, 0);
  rb_define_method(rb_cCArray, "trim!", rb_ca_trim_bang, -1);
  rb_define_method(rb_cCArray, "trim", rb_ca_trim, -1);
}



