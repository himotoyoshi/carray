# -*- Mode: C; tab-width: 2; -*-
# ----------------------------------------------------------------------------
#
#  carray_stat_proc.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

def macro_expand (text, values)
  text = text.clone
  values.each do |key, val|
    text.gsub!("<"+key+">", val)
  end
  return text
end

TYPEINFO = {
  'boolean8_t' => {
                'type' => "boolean8_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2LONG',
                'type2obj' => 'LONG2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",
              },
  'int8_t' => {
                'type' => "int8_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2LONG',
                'type2obj' => 'LONG2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'uint8_t' => {
                'type' => "uint8_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2ULONG',
                'type2obj' => 'ULONG2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'int16_t' => {
                'type' => "int16_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2LONG',
                'type2obj' => 'LONG2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'uint16_t' => {
                'type' => "uint16_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2ULONG',
                'type2obj' => 'ULONG2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'int32_t' => {
                'type' => "int32_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2LONG',
                'type2obj' => 'LONG2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'uint32_t' => {
                'type' => "uint32_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2ULONG',
                'type2obj' => 'ULONG2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'int64_t' => {
                'type' => "int64_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2LL',
                'type2obj' => 'LL2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'uint64_t' => {
                'type' => "uint64_t",
                'zero' => '0',
                'dat2type' => '',
                'obj2type' => 'NUM2ULL',
                'type2obj' => 'ULL2NUM',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'float32_t' => {
                'type' => "float32_t",
                'zero' => '0.0',
                'dat2type' => '',
                'obj2type' => 'NUM2DBL',
                'type2obj' => 'rb_float_new',
                'type2dbl' => '(float64_t)',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'float64_t' => {
                'type' => "float64_t",
                'zero' => '0.0',
                'dat2type' => '',
                'obj2type' => 'NUM2DBL',
                'type2obj' => 'rb_float_new',
                'type2dbl' => '',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'float128_t' => {
                'type' => "float128_t",
                'zero' => '0.0',
                'dat2type' => '',
                'obj2type' => 'NUM2DBL',
                'type2obj' => 'rb_float_new',
                'type2dbl' => '',
                'int2type' => '',
                'atype' => 'double',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_float_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'cmplx64_t' => {
                'type' => "cmplx64_t",
                'zero' => '0.0',
                'dat2type' => '',
                'obj2type' => 'NUM2CC',
                'type2obj' => 'rb_ccomplex_new',
                'type2dbl' => '',
                'int2type' => '',
                'atype' => 'cmplx128_t',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_ccomplex_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'cmplx128_t' => {
                'type' => "cmplx128_t",
                'zero' => '0.0',
                'dat2type' => '',
                'obj2type' => 'NUM2CC',
                'type2obj' => 'rb_ccomplex_new',
                'type2dbl' => '',
                'int2type' => '',
                'atype' => 'cmplx128_t',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_ccomplex_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'cmplx256_t' => {
                'type' => "cmplx256_t",
                'zero' => '0.0',
                'dat2type' => '',
                'obj2type' => 'NUM2CC',
                'type2obj' => 'rb_ccomplex_new',
                'type2dbl' => '',
                'int2type' => '',
                'atype' => 'cmplx128_t',
                'azero' => '0.0',
                'aone' => '1.0',
                'atype2obj' => 'rb_ccomplex_new',
                'eql' => "GEQ",
                'op_type' => "c",                
              },
  'VALUE' => {
                'type' => "VALUE",
                'zero' => 'INT2FIX(0)',
                'dat2type' => '',
                'obj2type' => '',
                'type2obj' => '',
                'type2dbl' => 'NUM2DBL',
                'int2type' => 'INT2NUM',
                'atype' => 'VALUE',
                'azero' => 'rb_float_new(0.0)',
                'aone' => 'rb_float_new(1.0)',
                'atype2obj' => '',
                'eql' => "OEQ",
                'op_type' => "VALUE",                
              },

}

# --------------------------------------------------------------------------
#
# HEADER
#
# --------------------------------------------------------------------------

header = <<HERE_END
/* ---------------------------------------------------------------------------

  carray_stat_proc.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  This file is automatically generated from carray_stat_proc.rb

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include <math.h>
#include "ruby.h"
#include "carray.h"

typedef struct {
  int32_t    offset;
  int32_t    count;
  int32_t    step;
  int32_t   *addr;
} CAStatIterator;

typedef void (*ca_stat_proc_t)();

#define iterator_rewind(it)                   \
  { \
    if ( (it)->step ) { \
      (it)->count = 0; \
      (it)->offset = (it)->addr[((it)->count)++]; \
    } \
    else { \
      (it)->offset = 0; \
    } \
  }

#define iterator_succ(it)                     \
  { \
    if ( (it)->step ) { \
      (it)->offset = (it)->addr[((it)->count)++]; \
    } \
    else { \
      ((it)->offset)++; \
    } \
  }

static ID id_lt, id_gt, id_plus, id_minus, id_star, id_quo;

#define GEQ(x,y)        ( (x) == (y) )
#define OEQ(x,y)        rb_equal((x),(y))

#define lt_c(x, y)      ( (x) < (y) )
#define lt_VALUE(x, y)  rb_funcall((x), id_lt, 1, (y))

#define gt_c(x, y)      ( (x) > (y) )
#define gt_VALUE(x, y)  rb_funcall((x), id_gt, 1, (y))

#define add_c(x, y)     ( (x) + (y) )
#define add_VALUE(x, y) rb_funcall((x), id_plus, 1, (y))

#define sub_c(x, y)     ( (x) - (y) )
#define sub_VALUE(x, y) rb_funcall((x), id_minus, 1, (y))

#define mul_c(x, y)     ( (x) * (y) )
#define mul_VALUE(x, y) rb_funcall((x), id_star, 1, (y))

#define div_c(x, y)     ( (x) / (y) )
#define div_VALUE(x, y) rb_funcall((x), id_quo, 1, (y))

#define sqrt_c(x)       sqrt(x)
#define sqrt_VALUE(x)   rb_funcall((x), rb_intern("sqrt"), 0)

HERE_END

puts header


# --------------------------------------------------------------------------
#
# STAT Part 1
#
# --------------------------------------------------------------------------


text = <<'HERE_END'

/* ============================= */
/* ca_proc_prod                  */
/* ============================= */

static void
ca_proc_prod_<type> (int32_t elements, int32_t min_count,
                     boolean8_t *m, void *ptr, CAStatIterator *it,
                     int return_object, VALUE *retobj,
                     boolean8_t *retmask, <atype> *retval)
{
  volatile <atype> prod = <aone>;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        prod = mul_<op_type>(prod, (<atype>)<dat2type>(*(p + *a)));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      prod = mul_<op_type>(prod, (<atype>)<dat2type>(*(p + *a)));
      iterator_succ(it);
    }
  }
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <atype2obj>(prod);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = prod;
  }
}

/* ============================= */
/* ca_proc_count                 */
/* ============================= */

static void
ca_proc_count_<type> (int32_t elements, int32_t min_count,
                      boolean8_t *m, void *ptr, CAStatIterator *it,
                      int return_object, VALUE *retobj,
                      boolean8_t *retmask, int32_t *retval)
{
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      iterator_succ(it);
    }
  }
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : LONG2NUM(elements - count);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = elements - count;
  }
}

static void
ca_proc_sum_<type> (int32_t elements, int32_t min_count,
                    boolean8_t *m, void *ptr, CAStatIterator *it,
                    int return_object, VALUE *retobj,
                    boolean8_t *retmask, float64_t *retval)
{
  volatile <atype> sum = <azero>;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *)it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      iterator_succ(it);
    }
  }
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <atype2obj>(sum);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = <type2dbl>(sum);
  }
}


/* ============================= */
/* ca_proc_mean                  */
/* ============================= */

static void
ca_proc_mean_<type> (int32_t elements, int32_t min_count,
                     boolean8_t *m, void *ptr, CAStatIterator *it,
                     int return_object, VALUE *retobj,
                     boolean8_t *retmask, float64_t *retval)
{
  volatile <atype> sum = <azero>, ave;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      iterator_succ(it);
    }
  }
  ave = div_<op_type>(sum, (<atype>)<int2type>(elements-count));
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <atype2obj>(ave);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval = <type2dbl>(ave);
  }
}

/* ============================= */
/* ca_proc_variancep             */
/* ============================= */

static void
ca_proc_variancep_<type> (int32_t elements, int32_t min_count,
                     boolean8_t *m, void *ptr, CAStatIterator *it,
                     int return_object, VALUE *retobj,
                     boolean8_t *retmask, float64_t *retval)
{
  volatile <atype> sum = <azero>, sum2 = <azero>, ave, var, diff;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      iterator_succ(it);
    }
  }
  ave = div_<op_type>(sum, (<atype>)<int2type>(elements-count));

  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        ;
      }
      else {
        diff = sub_<op_type>((<atype>)<dat2type>(*(p + *a)), ave);
        sum2 = add_<op_type>(sum2, mul_<op_type>(diff,diff));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      diff = sub_<op_type>((<atype>)<dat2type>(*(p + *a)), ave);
      sum2 = add_<op_type>(sum2, mul_<op_type>(diff,diff));
      iterator_succ(it);
    }
  }

  var = div_<op_type>(sum2, (<atype>)<int2type>(elements-count));
  
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <atype2obj>(var);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval = <type2dbl>(var);
  }
}

/* ============================= */
/* ca_proc_stddevp             */
/* ============================= */

static void
ca_proc_stddevp_<type> (int32_t elements, int32_t min_count,
                     boolean8_t *m, void *ptr, CAStatIterator *it,
                     int return_object, VALUE *retobj,
                     boolean8_t *retmask, float64_t *retval)
{
  volatile <atype> sum = <azero>, sum2 = <azero>, ave, var, diff;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      iterator_succ(it);
    }
  }
  ave = div_<op_type>(sum, (<atype>)<int2type>(elements-count));

  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        ;
      }
      else {
        diff = sub_<op_type>((<atype>)<dat2type>(*(p + *a)), ave);
        sum2 = add_<op_type>(sum2, mul_<op_type>(diff,diff));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      diff = sub_<op_type>((<atype>)<dat2type>(*(p + *a)), ave);
      sum2 = add_<op_type>(sum2, mul_<op_type>(diff,diff));
      iterator_succ(it);
    }
  }

  var = div_<op_type>(sum2, (<atype>)<int2type>(elements-count));
  
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <atype2obj>(sqrt_<op_type>(var));
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval = <type2dbl>(sqrt_<op_type>(var));
  }
}

/* ============================= */
/* ca_proc_variance              */
/* ============================= */

static void
ca_proc_variance_<type> (int32_t elements, int32_t min_count,
                     boolean8_t *m, void *ptr, CAStatIterator *it,
                     int return_object, VALUE *retobj,
                     boolean8_t *retmask, float64_t *retval)
{
  volatile <atype> sum = <azero>, sum2 = <azero>, ave, var, diff;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      iterator_succ(it);
    }
  }
  ave = div_<op_type>(sum, (<atype>)<int2type>(elements-count));

  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        ;
      }
      else {
        diff = sub_<op_type>((<atype>)<dat2type>(*(p + *a)), ave);
        sum2 = add_<op_type>(sum2, mul_<op_type>(diff,diff));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      diff = sub_<op_type>((<atype>)<dat2type>(*(p + *a)), ave);
      sum2 = add_<op_type>(sum2, mul_<op_type>(diff,diff));
      iterator_succ(it);
    }
  }

  var = div_<op_type>(sum2, (<atype>)<int2type>(elements-count-1));

  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <atype2obj>(var);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval = <type2dbl>(var);
  }
}

/* ============================= */
/* ca_proc_stddev                */
/* ============================= */

static void
ca_proc_stddev_<type> (int32_t elements, int32_t min_count,
                     boolean8_t *m, void *ptr, CAStatIterator *it,
                     int return_object, VALUE *retobj,
                     boolean8_t *retmask, <atype> *retval)
{
  volatile <atype> sum = <azero>, sum2 = <azero>, ave, var, diff;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      iterator_succ(it);
    }
  }
  ave = div_<op_type>(sum, (<atype>)<int2type>(elements-count));

  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        ;
      }
      else {
        diff = sub_<op_type>((<atype>)<dat2type>(*(p + *a)), ave);
        sum2 = add_<op_type>(sum2, mul_<op_type>(diff,diff));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      diff = sub_<op_type>((<atype>)<dat2type>(*(p + *a)), ave);
      sum2 = add_<op_type>(sum2, mul_<op_type>(diff,diff));
      iterator_succ(it);
    }
  }

  var = div_<op_type>(sum2, (<atype>)<int2type>(elements-count-1));
  
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <atype2obj>(sqrt_<op_type>(var));
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = sqrt_<op_type>(var);
  }
}

/* ============================= */
/* ca_proc_min                   */
/* ============================= */

static void
ca_proc_min_<type> (int32_t elements, int32_t min_count,
                    boolean8_t *m, void *ptr, CAStatIterator *it,
                    int return_object, VALUE *retobj,
                    boolean8_t *retmask, <type> *retval)
{
  <type> min = <zero>;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t addr;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    addr = -1;
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        min = *(p + *a);
        addr = i;
        break;
      }
      iterator_succ(it);
    }
    iterator_succ(it);
    if ( addr >= 0 ) {
      for (i=addr+1; i<elements; i++) {
        if ( *(m + *a) ) {
          count++;
        }
        else {
          if ( lt_<op_type>(*(p + *a), min) ) {
            min = *(p + *a);
            addr = i;
          }
        }
        iterator_succ(it);
      }
    }
  }
  else {
    min = *(p + *a);
    addr = 0;
    for (i=addr; i<elements; i++) {
      if ( lt_<op_type>(*(p + *a), min) ) {
        min = *(p + *a);
        addr = i;
      }
      iterator_succ(it);
    }
  }
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <type2obj>(min);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = min;
  }
}

/* ============================= */
/* ca_proc_min_addr              */
/* ============================= */

static void
ca_proc_min_addr_<type> (int32_t elements, int32_t min_count,
                         boolean8_t *m, void *ptr, CAStatIterator *it,
                         int return_object, VALUE *retobj,
                         boolean8_t *retmask, int32_t *retval)
{
  <type> min = <zero>;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t addr;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    addr = -1;
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        min = *(p + *a);
        addr = i;
        break;
      }
      iterator_succ(it);
    }
    iterator_succ(it);
    if ( addr >= 0 ) {
      for (i=addr+1; i<elements; i++) {
        if ( *(m + *a) ) {
          count++;
        }
        else {
          if ( lt_<op_type>(*(p + *a), min) ) {
            min = *(p + *a);
            addr = i;
          }
        }
        iterator_succ(it);
      }
    }
  }
  else {
    min = *(p + *a);
    addr = 0;
    for (i=addr; i<elements; i++) {
      if ( lt_<op_type>(*(p + *a), min) ) {
        min = *(p + *a);
        addr = i;
      }
      iterator_succ(it);
    }
  }
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF
                                    : ( addr < 0 ) ? Qnil : LONG2NUM(addr);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = addr;
  }
}

/* ============================= */
/* ca_proc_max                   */
/* ============================= */

static void
ca_proc_max_<type> (int32_t elements, int32_t min_count,
                    boolean8_t *m, void *ptr, CAStatIterator *it,
                    int return_object, VALUE *retobj,
                    boolean8_t *retmask, <type> *retval)
{
  <type> max = 0;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t addr;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    addr = -1;
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        max = *(p + *a);
        addr = i;
        break;
      }
      iterator_succ(it);
    }
    iterator_succ(it);
    if ( addr >= 0 ) {
      for (i=addr+1; i<elements; i++) {
        if ( *(m + *a) ) {
          count++;
        }
        else {
          if ( gt_<op_type>(*(p + *a), max) ) {
            max = *(p + *a);
            addr = i;
          }
        }
        iterator_succ(it);
      }
    }
  }
  else {
    max = *(p + *a);
    addr = 0;
    for (i=addr; i<elements; i++) {
      if ( gt_<op_type>(*(p + *a), max) ) {
        max = *(p + *a);
        addr = i;
      }
      iterator_succ(it);
    }
  }
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <type2obj>(max);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = max;
  }
}

/* ============================= */
/* ca_proc_max_addr              */
/* ============================= */

static void
ca_proc_max_addr_<type> (int32_t elements, int32_t min_count,
                         boolean8_t *m, void *ptr, CAStatIterator *it,
                         int return_object, VALUE *retobj,
                         boolean8_t *retmask, int32_t *retval)
{
  <type> max = 0;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t addr;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    addr = -1;
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        max = *(p + *a);
        addr = i;
        break;
      }
      iterator_succ(it);
    }
    iterator_succ(it);
    if ( addr >= 0 ) {
      for (i=addr+1; i<elements; i++) {
        if ( *(m + *a) ) {
          count++;
        }
        else {
          if ( gt_<op_type>(*(p + *a), max) ) {
            max = *(p + *a);
            addr = i;
          }
        }
        iterator_succ(it);
      }
    }
  }
  else {
    max = *(p + *a);
    addr = 0;
    for (i=addr; i<elements; i++) {
      if ( gt_<op_type>(*(p + *a), max) ) {
        max = *(p + *a);
        addr = i;
      }
      iterator_succ(it);
    }
  }
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF
                                    : ( addr < 0 ) ? Qnil : LONG2NUM(addr);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = addr;
  }
}


/* ============================= */
/* ca_proc_cumcount              */
/* ============================= */

static void
ca_proc_cumcount_<type> (int32_t elements, int32_t min_count,
                         boolean8_t *m, void *ptr, CAStatIterator *it,
                         boolean8_t *retmask, int32_t *retval)
{
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      if ( retmask ) {
        if ( count > min_count ) {
          *retmask = 1;
        }
        else {
          *retmask = 0;
        }
      }
      *retval  = i + 1 - count;
      retmask++; retval++;
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      *retval = i+1;
      retval++;
    }
  }
}


/* ============================= */
/* ca_proc_cumsum                */
/* ============================= */

static void
ca_proc_cumsum_<type> (int32_t elements, int32_t min_count,
                       boolean8_t *m, void *ptr, CAStatIterator *it,
                       boolean8_t *retmask, float64_t *retval)
{
  volatile <atype> sum = <azero>;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      }
      if ( retmask ) {
        if ( count > min_count ) {
          *retmask = 1;
        }
        else {
          *retmask = 0;
        }
      }
      *retval = <type2dbl>(sum);
      retmask++; retval++;
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      sum = add_<op_type>(sum, (<atype>)<dat2type>(*(p + *a)));
      *retval = <type2dbl>(sum);
      retval++;
      iterator_succ(it);
    }
  }
}

HERE_END

puts macro_expand(text, TYPEINFO['boolean8_t'])
puts macro_expand(text, TYPEINFO['int8_t'])
puts macro_expand(text, TYPEINFO['uint8_t'])
puts macro_expand(text, TYPEINFO['int16_t'])
puts macro_expand(text, TYPEINFO['uint16_t'])
puts macro_expand(text, TYPEINFO['int32_t'])
puts macro_expand(text, TYPEINFO['uint32_t'])
puts macro_expand(text, TYPEINFO['int64_t'])
puts macro_expand(text, TYPEINFO['uint64_t'])
puts macro_expand(text, TYPEINFO['float32_t'])
puts macro_expand(text, TYPEINFO['float64_t'])
puts macro_expand(text, TYPEINFO['float128_t'])
# puts macro_expand(text, TYPEINFO['cmplx64_t']) 
# puts macro_expand(text, TYPEINFO['cmplx128_t'])
# puts macro_expand(text, TYPEINFO['cmplx256_t'])
puts macro_expand(text, TYPEINFO['VALUE'])

text = <<'HERE_END'
static ca_stat_proc_t
ca_proc_<name>[CA_NTYPE] = {
  NULL,
  ca_proc_<name>_boolean8_t,
  ca_proc_<name>_int8_t,
  ca_proc_<name>_uint8_t,
  ca_proc_<name>_int16_t,
  ca_proc_<name>_uint16_t,
  ca_proc_<name>_int32_t,
  ca_proc_<name>_uint32_t,
  ca_proc_<name>_int64_t,
  ca_proc_<name>_uint64_t,
  ca_proc_<name>_float32_t,
  ca_proc_<name>_float64_t,
  ca_proc_<name>_float128_t,
  NULL, /* ca_proc_<name>_cmplx64_t,  */
  NULL, /* ca_proc_<name>_cmplx128_t,    */
  NULL, /* ca_proc_<name>_cmplx256_t,      */
  ca_proc_<name>_VALUE, 
};

HERE_END

puts macro_expand(text, "name" => "count")
puts macro_expand(text, "name" => "sum")
puts macro_expand(text, "name" => "mean")
puts macro_expand(text, "name" => "variancep")
puts macro_expand(text, "name" => "stddevp")
puts macro_expand(text, "name" => "variance")
puts macro_expand(text, "name" => "stddev")
puts macro_expand(text, "name" => "prod")
puts macro_expand(text, "name" => "min")
puts macro_expand(text, "name" => "min_addr")
puts macro_expand(text, "name" => "max")
puts macro_expand(text, "name" => "max_addr")

puts macro_expand(text, "name" => "cumcount")
puts macro_expand(text, "name" => "cumsum")

# --------------------------------------------------------------------------
#
# STAT Part 2
#
# --------------------------------------------------------------------------

text = <<'HERE_END'

/* ============================= */
/* ca_proc_accum                 */
/* ============================= */

static void
ca_proc_accum_<type> (int32_t elements, int32_t min_count,
                      boolean8_t *m, void *ptr, CAStatIterator *it,
                      int return_object, VALUE *retobj,
                      boolean8_t *retmask, <type> *retval)
{
  <type> sum = <zero>;
  <type> *p = (<type> *) ptr;
  int32_t *a = (int32_t *) it;
  int32_t count = 0;
  int32_t i;
  iterator_rewind(it);
  if ( m ) {
    for (i=0; i<elements; i++) {
      if ( *(m + *a) ) {
        count++;
      }
      else {
        sum = add_<op_type>(sum, (<type>)<dat2type>(*(p + *a)));
      }
      iterator_succ(it);
    }
  }
  else {
    for (i=0; i<elements; i++) {
      sum = add_<op_type>(sum, (<type>)<dat2type>(*(p + *a)));
      iterator_succ(it);
    }
  }
  if ( return_object ) {
    *retobj = ( count > min_count ) ? CA_UNDEF : <type2obj>(sum);
  }
  else {
    if ( retmask ) {
      *retmask = ( count > min_count ) ? 1 : 0;
    }
    *retval  = sum;
  }
}

HERE_END

puts macro_expand(text, TYPEINFO['boolean8_t'])
puts macro_expand(text, TYPEINFO['int8_t'])
puts macro_expand(text, TYPEINFO['uint8_t'])
puts macro_expand(text, TYPEINFO['int16_t'])
puts macro_expand(text, TYPEINFO['uint16_t'])
puts macro_expand(text, TYPEINFO['int32_t'])
puts macro_expand(text, TYPEINFO['uint32_t'])
puts macro_expand(text, TYPEINFO['int64_t'])
puts macro_expand(text, TYPEINFO['uint64_t'])
puts macro_expand(text, TYPEINFO['float32_t'])
puts macro_expand(text, TYPEINFO['float64_t'])
puts macro_expand(text, TYPEINFO['float128_t'])
puts macro_expand(text, TYPEINFO['cmplx64_t'])
puts macro_expand(text, TYPEINFO['cmplx128_t'])
puts macro_expand(text, TYPEINFO['cmplx256_t'])
puts macro_expand(text, TYPEINFO['VALUE'])

text = <<'HERE_END'
static ca_stat_proc_t
ca_proc_<name>[CA_NTYPE] = {
  NULL,
  ca_proc_<name>_boolean8_t,
  ca_proc_<name>_int8_t,
  ca_proc_<name>_uint8_t,
  ca_proc_<name>_int16_t,
  ca_proc_<name>_uint16_t,
  ca_proc_<name>_int32_t,
  ca_proc_<name>_uint32_t,
  ca_proc_<name>_int64_t,
  ca_proc_<name>_uint64_t,
  ca_proc_<name>_float32_t,
  ca_proc_<name>_float64_t,
  ca_proc_<name>_float128_t,
  ca_proc_<name>_cmplx64_t,
  ca_proc_<name>_cmplx128_t,
  ca_proc_<name>_cmplx256_t,
  ca_proc_<name>_VALUE, 
};

HERE_END

puts macro_expand(text, "name" => "accum")

# --------------------------------------------------------------------------
#
# METHOD DEFINITIONS (after __END__)
#
# --------------------------------------------------------------------------

puts DATA.read

__END__

static VALUE
rb_ca_stat_1d (VALUE self, VALUE rmc, VALUE vfval,
               ca_stat_proc_t *ca_proc)
{
  volatile VALUE out;
  CArray *ca;
  CAStatIterator it;
  boolean8_t *m;
  int32_t mc;

  Data_Get_Struct(self, CArray, ca);

  if ( ! ca_proc[ca->data_type] ) {
    rb_raise(rb_eCADataTypeError,
             "this method is not implemented for data_type %s",
             ca_type_name[ca->data_type]);
  }

  if ( ca->elements == 0 ) {
    out = CA_UNDEF;
  }
  else {
    ca_attach(ca);
    m = ( ca->mask ) ? (boolean8_t *)ca->mask->ptr : NULL;
    mc = ( ( ! ca_has_mask(ca) ) || NIL_P(rmc)) ? ca->elements - 1 : NUM2LONG(rmc);
    if ( mc < 0 ) {
      mc += ca->elements;
    }
    it.step = 0;
    ca_proc[ca->data_type](ca->elements, mc, m, ca->ptr, &it, 1, &out, NULL, NULL);
    ca_detach(ca);
  }

  if ( out == CA_UNDEF && ( vfval != CA_NIL ) ) {
    out = vfval;
  }

  return out;
}

static void
ca_stat_nd_contig_loop (CArray *ca, CArray *co, int32_t mc,
                        ca_stat_proc_t *ca_proc,
                        int level, int32_t *idx, char **op, boolean8_t **om)
{
  void *p;
  boolean8_t *m;
  int32_t i, n;
  if ( level == co->rank ) {
    CAStatIterator it;
    n = ca->elements/co->elements;
    idx[level] = 0;
    p = ca_ptr_at_index(ca, idx);
    m = ( ca->mask && ca->mask->ptr ) ?
                          (boolean8_t *)ca_ptr_at_index(ca->mask, idx) : NULL;
		it.step = 0;
    ca_proc[ca->data_type](n, mc, m, p, &it, 0, NULL, *om, *op);
    if ( *om ) {
      *om += 1;
    }
    *op += co->bytes;
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      ca_stat_nd_contig_loop(ca, co, mc, ca_proc, level+1, idx, op, om);
    }
  }
}

static VALUE
rb_ca_stat_nd_contig (VALUE self, VALUE vaxis, VALUE rmc, VALUE vfval,
                      int8_t data_type, ca_stat_proc_t *ca_proc)
{
  volatile VALUE out;
  CArray *ca, *co;
  int32_t mc, ndim;

  Data_Get_Struct(self, CArray, ca);

  if ( ! ca_proc[ca->data_type] ) {
    rb_raise(rb_eCADataTypeError,
             "this method is not implemented for data_type %s",
             ca_type_name[ca->data_type]);
  }

  ndim = ca->rank - RARRAY_LEN(vaxis);
  if ( ndim <= 0 || ndim > ca->rank ) {
    rb_raise(rb_eRuntimeError, "invalid dimension specified");
  }

  out = rb_carray_new(data_type, ndim, ca->dim, 0, NULL);
  Data_Get_Struct(out, CArray, co);

	if ( ca_has_mask(ca) ) {
		ca_create_mask(co);
	}

  if ( NIL_P(rmc) ) {
    mc = ca->elements/co->elements - 1;
  }
  else {
    mc = NUM2LONG(rmc);
  }

  if ( mc < 0 ) {
    mc += ca->elements;
  }

  {
    int32_t idx[CA_RANK_MAX];
    char *op;
    boolean8_t *om;
    int32_t i;
    for (i=0; i<ca->rank; i++) {
      idx[i] = 0;
    }
    ca_attach_n(2, ca, co);
    op = co->ptr;
    om = ( co->mask && co->mask->ptr ) ? (boolean8_t *)co->mask->ptr : NULL;
    ca_stat_nd_contig_loop(ca, co, mc, ca_proc, 0, idx, &op, &om);
    ca_sync(co);
    ca_detach_n(2, ca, co);
  }

  if ( ca_has_mask(co) && ( vfval != CA_NIL ) ) {
    out = rb_ca_mask_fill_copy(out, vfval);
  }

  return out;
}

static void
ca_stat_get_offset_loop (CArray *ca, int32_t *dm,
                        int level, int32_t *idx,
                        int level1, int32_t *idx1,
                        CArray *offset)
{
  int32_t i;
  if ( level == ca->rank - 1 ) {
    if ( dm[level] == 0 ) {
      idx[level] = 0;
      *(int32_t *)ca_ptr_at_index(offset, idx1) = ca_index2addr(ca, idx);
    }
    else {
      for (i=0; i<ca->dim[level]; i++) {
        idx[level] = i;
        idx1[level1] = i;
        *(int32_t *)ca_ptr_at_index(offset, idx1) = ca_index2addr(ca, idx);
      }
    }
  }
  else {
    if ( dm[level] == 0 ) {
      idx[level] = 0;
      ca_stat_get_offset_loop(ca, dm, level+1, idx, level1, idx1, offset);
    }
    else {
      for (i=0; i<ca->dim[level]; i++) {
        idx[level] = i;
        idx1[level1] = i;
        ca_stat_get_offset_loop(ca, dm, level+1, idx, level1+1, idx1, offset);
      }
    }
  }
}

static VALUE
rb_ca_stat_nd_discrete (VALUE self, VALUE vaxis, VALUE rmc, VALUE vfval,
                        int8_t data_type, ca_stat_proc_t *ca_proc)
{
  volatile VALUE out;
  int32_t idx[CA_RANK_MAX];
  int32_t idx1[CA_RANK_MAX];
  int32_t out_dim[CA_RANK_MAX];
  int32_t loop_dim[CA_RANK_MAX];
  int32_t dm[CA_RANK_MAX], dn[CA_RANK_MAX];
  CArray *ca, *co, *first, *offset;
  int32_t out_rank, loop_rank;
  int32_t mc;
  int32_t i, k;

  Data_Get_Struct(self, CArray, ca);

  for (i=0; i<ca->rank; i++) {
    dm[i] = 0;
    dn[i] = 1;
  }

  for (i=0; i<RARRAY_LEN(vaxis); i++) {
    k = NUM2INT(rb_ary_entry(vaxis, i));
    dm[k] = 1;
    dn[k] = 0;
  }

  out_rank  = 0;
  loop_rank = 0;
  for (i=0; i<ca->rank; i++) {
    if ( dm[i] ) {
      loop_dim[loop_rank] = ca->dim[i];
      loop_rank += 1;
    }
    else {
      out_dim[out_rank] = ca->dim[i];
      out_rank += 1;
    }
  }

  out    = rb_carray_new(data_type, out_rank, out_dim, 0, NULL);
  Data_Get_Struct(out, CArray, co);
  
  first  = carray_new(CA_INT32, out_rank, out_dim, 0, NULL);
  first->ptr = realloc(first->ptr, first->bytes*(first->elements+1));

  offset = carray_new(CA_INT32, loop_rank, loop_dim, 0, NULL);
  offset->ptr = realloc(offset->ptr, offset->bytes*(offset->elements+1));

  ca_stat_get_offset_loop(ca, dn, 0, idx, 0, idx1, first);
  ca_stat_get_offset_loop(ca, dm, 0, idx, 0, idx1, offset);

	if ( ca_has_mask(ca) ) {
		ca_create_mask(co);
	}

  if ( NIL_P(rmc) ) {
    mc = offset->elements - 1;
  }
  else {
    mc = NUM2LONG(rmc);
  }

  if ( mc < 0 ) {
    mc += offset->elements;
  }

  ca_attach_n(2, ca, co);

  {
    CAStatIterator it, jt;
    int32_t *a = (int32_t *) (&it);
    boolean8_t *m0, *m, *om;
    char *p, *op;

    it.step = 1;
    it.addr = (int32_t *)first->ptr;
    jt.step = 1;
    jt.addr = (int32_t *)offset->ptr;

    m0 = ( ca->mask && ca->mask->ptr ) ? (boolean8_t *)ca->mask->ptr : NULL;
    om = ( co->mask && co->mask->ptr ) ? (boolean8_t *)co->mask->ptr : NULL;
    op = co->ptr;

    iterator_rewind(&it);
    for (i=0; i<co->elements; i++) {
      m = ( m0 ) ? m0 + (*a) : NULL;
      p = ca->ptr + (*a) * ca->bytes;
      ca_proc[ca->data_type](offset->elements, mc, m, p, &jt, 0, NULL, om, op);
      if ( om ) {
        om += 1;
      }
      op += co->bytes;
      iterator_succ(&it);
    }
  }

  ca_sync(co);
  ca_detach_n(2, ca, co);

  if ( ca_has_mask(co) && ( vfval != CA_NIL ) ) {
    out = rb_ca_mask_fill_copy(out, vfval);
  }

  ca_free(first);
  ca_free(offset);

  return out;
}

static VALUE
rb_ca_stat_general (int argc, VALUE *argv, VALUE self,
                    int8_t data_type, ca_stat_proc_t *ca_proc)
{
  volatile VALUE ropt, rmc = Qnil, rmask_limit = Qnil, rmin_count = Qnil, 
                 vfval = CA_NIL, vaxis;
  CArray *ca;

  Data_Get_Struct(self, CArray, ca);

  ropt = rb_pop_options(&argc, &argv);
  rb_scan_options(ropt,
                  "mask_limit,fill_value,min_count",
                  &rmask_limit, &vfval, &rmin_count);

  if ( ( ! NIL_P(rmask_limit) ) && ( ! NIL_P(rmin_count) ) ) {
    rb_raise(rb_eArgError,
             "don't specify mask_limit and min_count simaltaniously");
  }
  else if ( ! NIL_P(rmin_count) ) {
    int min_count = NUM2LONG(rmin_count);
    if ( min_count == 0 ) {
      rmc = Qnil;
    }
    else {
      rmc = LONG2NUM(-min_count);
    }
  }
  else if ( ! NIL_P(rmask_limit) ) {
    int mask_limit = NUM2LONG(rmask_limit);
    if ( mask_limit == 0 ) {
      rmc = Qnil;
    }
    else {
      rmc = LONG2NUM(mask_limit-1);
    }
  }
  else {
    rmc = Qnil;
  }

  if ( argc > 0 ) {
    vaxis = rb_ary_new4(argc, argv);
  }
  else {
    vaxis = Qnil;
  }

  if ( NIL_P(vaxis) ) {
    return rb_ca_stat_1d(self, rmc, vfval, ca_proc);
  }
  else {
    int is_contig = 1;
    int i, k;

    vaxis = rb_funcall(vaxis, rb_intern("sort"), 0);
    vaxis = rb_funcall(vaxis, rb_intern("uniq"), 0);

    for (i=0; i<RARRAY_LEN(vaxis); i++) {
      k = NUM2INT(rb_ary_entry(vaxis, RARRAY_LEN(vaxis)-1-i));
      CA_CHECK_INDEX(k, ca->rank);
      if ( k != ca->rank-1-i ) {
        is_contig = 0;
      }
    }

    if ( is_contig ) {
      if ( RARRAY_LEN(vaxis) == ca->rank ) {
        return rb_ca_stat_1d(self, rmc, vfval, ca_proc);
      }
      else {
        return rb_ca_stat_nd_contig(self, vaxis, rmc, vfval,
                                    data_type, ca_proc);
      }
    }
    else {
      return rb_ca_stat_nd_discrete(self, vaxis, rmc, vfval,
                                    data_type, ca_proc);
    }
  }
}


static VALUE
rb_ca_prod (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_FLOAT64, ca_proc_prod);
}

static VALUE
rb_ca_count (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_INT32, ca_proc_count);
}

static VALUE
rb_ca_sum (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_FLOAT64, ca_proc_sum);
}

static VALUE
rb_ca_mean (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_FLOAT64, ca_proc_mean);
}

static VALUE
rb_ca_variancep (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_FLOAT64, ca_proc_variancep);
}

static VALUE
rb_ca_stddevp (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_FLOAT64, ca_proc_stddevp);
}

static VALUE
rb_ca_variance (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_FLOAT64, ca_proc_variance);
}

static VALUE
rb_ca_stddev (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_FLOAT64, ca_proc_stddev);
}

static VALUE
rb_ca_min (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return rb_ca_stat_general(argc, argv, self, ca->data_type, ca_proc_min);
}

static VALUE
rb_ca_min_addr (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_INT32, ca_proc_min_addr);
}

static VALUE
rb_ca_max (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return rb_ca_stat_general(argc, argv, self, ca->data_type, ca_proc_max);
}

static VALUE
rb_ca_max_addr (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_general(argc, argv, self, CA_INT32, ca_proc_max_addr);
}

static VALUE
rb_ca_accum (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return rb_ca_stat_general(argc, argv, self, ca->data_type, ca_proc_accum);
}

static VALUE
rb_ca_stat_type2 (int argc, VALUE *argv, VALUE self,
                  int8_t data_type, ca_stat_proc_t *ca_proc)
{
  VALUE out, rmc, rfval;
  CArray *ca, *co;
  int32_t mc;

  rb_scan_args(argc, argv, "02", &rmc, &rfval);

  Data_Get_Struct(self, CArray, ca);

  if ( ! ca_proc[ca->data_type] ) {
    rb_raise(rb_eCADataTypeError,
             "this method is not implemented for data_type %s",
             ca_type_name[ca->data_type]);
  }

  out = rb_carray_new(data_type, 1, &ca->elements, 0, NULL);
  Data_Get_Struct(out, CArray, co);

  if ( ca->elements == 0 ) {
    ;
  }
  else {
    CAStatIterator it;
    boolean8_t *m = NULL;
    boolean8_t *om = NULL;
    ca_attach(ca);
    if ( ca->mask ) {
      m = (boolean8_t *)ca->mask->ptr;
    }
    mc = ( (! ca->mask) || NIL_P(rmc) ) ? ca->elements - 1 : NUM2LONG(rmc);
    if ( mc < 0 ) {
      mc += ca->elements;
    }
    if ( m ) {
      ca_create_mask(co);
      om = (boolean8_t *) co->mask->ptr;
    }
    it.step = 0;
    ca_proc[ca->data_type](ca->elements, mc, m, ca->ptr, &it,
                           om, co->ptr);
    ca_detach(ca);
  }

  if ( ca_has_mask(co) && ( ! NIL_P(rfval) ) ) {
    out = rb_ca_mask_fill_copy(out, rfval);
  }

  return out;
}

static void
ca_dimstat_type2_loop (CArray *ca, CArray *co, int32_t mc,
                       ca_stat_proc_t *ca_proc,
                       int level, int32_t *idx, char **op, boolean8_t **om)
{
  void *p;
  boolean8_t *m;
  int32_t i, n;
  if ( level == co->rank ) {
    CAStatIterator it;
    n = ca->elements/co->elements;
    idx[level] = 0;
    p = ca_ptr_at_index(ca, idx);
    m = ( ca->mask && ca->mask->ptr ) ?
                                (boolean8_t *)ca_ptr_at_index(ca->mask, idx) : NULL;
    it.step = 0;
    ca_proc[ca->data_type](n, mc, m, p, &it, 0, NULL, *om, *op);
    printf("world\n");
    if ( *om ) {
      *om += n;
    }
    *op += n*co->bytes;
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      ca_dimstat_type2_loop(ca, co, mc, ca_proc, level+1, idx, op, om);
    }
  }
}

static void
ca_dimstat_type2 (CArray *ca, CArray *co, int32_t mc, ca_stat_proc_t *ca_proc)
{
  int32_t idx[CA_RANK_MAX];
  char *op;
  boolean8_t *om;
  int32_t i;
  for (i=0; i<ca->rank; i++) {
    idx[i] = 0;
  }
  ca_attach_n(2, ca, co);
  op = co->ptr;
  om = ( co->mask && co->mask->ptr ) ? (boolean8_t *)co->mask->ptr : NULL;
  ca_dimstat_type2_loop(ca, co, mc, ca_proc, 0, idx, &op, &om);
  ca_sync(co);
  ca_detach_n(2, ca, co);
}

static VALUE
rb_ca_dimstat_type2 (int argc, VALUE *argv, VALUE self,
                    int8_t data_type, ca_stat_proc_t *ca_proc)
{
  volatile VALUE rndim, rmc, rfval;
  volatile VALUE out;
  CArray *ca, *co;
  int32_t odim[CA_RANK_MAX], n;
  int32_t mc, ndim;
  int32_t i;

  rb_scan_args(argc, argv, "12", &rndim, &rmc, &rfval);

  Data_Get_Struct(self, CArray, ca);

  if ( ! ca_proc[ca->data_type] ) {
    rb_raise(rb_eCADataTypeError,
             "this method is not implemented for data_type %s",
             ca_type_name[ca->data_type]);
  }

  ndim = NUM2INT(rndim);
  if ( ndim <= 0 || ndim > ca->rank ) {
    rb_raise(rb_eRuntimeError, "invalid dimension specified");
  }

  n = 1;
  for (i=0; i<ndim; i++) {
    odim[i] = ca->dim[i];
    n *= odim[i];
  }
  odim[ndim] = ca->elements/n;

  out = rb_carray_new(data_type, ndim+1, odim, 0, NULL);
  Data_Get_Struct(out, CArray, co);

	if ( ca_has_mask(ca) ) {
		ca_create_mask(co);
	}

  if ( NIL_P(rmc) ) {
    mc = ca->elements/co->elements - 1;
  }
  else {
    mc = NUM2LONG(rmc);
  }

  if ( mc < 0 ) {
    mc += ca->elements;
  }

  ca_dimstat_type2(ca, co, mc, ca_proc);

  if ( ca_has_mask(co) && ( ! NIL_P(rfval) ) ) {
    out = rb_ca_mask_fill_copy(out, rfval);
  }

  return out;
}

static VALUE
rb_ca_cumcount (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_type2(argc, argv, self, CA_INT32, ca_proc_cumcount);
}

static VALUE
rb_ca_dimcumcount (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_dimstat_type2(argc, argv, self, CA_INT32, ca_proc_cumcount);
}

static VALUE
rb_ca_cumsum (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_stat_type2(argc, argv, self, CA_FLOAT64, ca_proc_cumsum);
}

static VALUE
rb_ca_dimcumsum (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_dimstat_type2(argc, argv, self, CA_FLOAT64, ca_proc_cumsum);
}

void
Init_carray_stat_proc ()
{
  id_lt    = rb_intern("<");
  id_gt    = rb_intern(">");  
  id_plus  = rb_intern("+");
  id_minus = rb_intern("-"); 
  id_star  = rb_intern("*"); 
  id_quo   = rb_intern("quo");   

  rb_define_method(rb_cCArray, "prod",    rb_ca_prod, -1);
  rb_define_method(rb_cCArray, "count_valid", rb_ca_count, -1);
  rb_define_method(rb_cCArray, "sum",     rb_ca_sum, -1);
  rb_define_method(rb_cCArray, "mean",    rb_ca_mean, -1);
  rb_define_method(rb_cCArray, "variancep", rb_ca_variancep, -1);
  rb_define_method(rb_cCArray, "stddevp", rb_ca_stddevp, -1);
  rb_define_method(rb_cCArray, "variance",  rb_ca_variance, -1);
  rb_define_method(rb_cCArray, "stddev",  rb_ca_stddev, -1);
  rb_define_method(rb_cCArray, "min",     rb_ca_min, -1);
  rb_define_method(rb_cCArray, "max",     rb_ca_max, -1);
  rb_define_method(rb_cCArray, "min_addr", rb_ca_min_addr, -1);
  rb_define_method(rb_cCArray, "max_addr", rb_ca_max_addr, -1);

  rb_define_method(rb_cCArray, "accumulate",  rb_ca_accum, -1);

  rb_define_method(rb_cCArray, "cumcount",    rb_ca_cumcount, -1);
  rb_define_method(rb_cCArray, "dimcumcount", rb_ca_dimcumcount, -1);
  rb_define_method(rb_cCArray, "cumsum",    rb_ca_cumsum, -1);
  rb_define_method(rb_cCArray, "dimcumsum", rb_ca_dimcumsum, -1);
}



