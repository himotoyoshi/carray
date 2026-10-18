/* ---------------------------------------------------------------------------

  CArray#round(ndigits) and #round!(ndigits): each element rounded as Ruby's
  Float#round(ndigits) and Integer#round(ndigits) round it, half away from
  zero.  The argument-free forms are the generated monop kernels; this file
  takes over the method and hands them the calls without an argument.

---------------------------------------------------------------------------- */

#include <math.h>
#include <float.h>

#include "carray.h"
#include "carray_internal.h"
#include "ca_obj_face.h"

VALUE rb_ca_round (VALUE self);        /* generated: round without digits */
VALUE rb_ca_round_bang (VALUE self);

static ID id_round;

/* The rounding of Float#round for ndigits > 0 (numeric.c, round_half_up
   with its check for a product that came out one short). */
static double
ca_round_half_up (double x, double s)
{
  double f, xs = x * s;

  f = round(xs);
  if ( x > 0 ) {
    if ( (double)((f + 0.5) / s) <= x ) f += 1;
    x = f;
  }
  else {
    if ( (double)((f - 0.5) / s) >= x ) f -= 1;
    x = f;
  }
  return x;
}

/* numeric.c: float_round_overflow / float_round_underflow.  When the first
   holds, number * 10**ndigits is already an integer and the number is its
   own answer; when the second holds, the answer is 0. */
static int
ca_round_overflow (long ndigits, int binexp)
{
  enum { float_dig = DBL_DIG + 2 };
  return ndigits >= float_dig - (binexp > 0 ? binexp / 4 : binexp / 3 - 1);
}

static int
ca_round_underflow (long ndigits, int binexp)
{
  return ndigits < - (binexp > 0 ? binexp / 3 + 1 : binexp / 4);
}

/* An integer |x| rounded to a multiple of 10**k (k >= 1), half away from
   zero, as Integer#round(-k).  Returns 0 when the answer does not fit in
   64 bits, and sets *overflow. */
static uint64_t
ca_round_uint64 (uint64_t ax, long k, int *overflow)
{
  uint64_t y = 1, q, rem, r;
  long i;

  *overflow = 0;
  if ( k > 19 ) {          /* 10**20 / 2 exceeds every 64-bit value */
    return 0;
  }
  for (i = 0; i < k; i++) {
    y *= 10;
  }
  q   = ax / y;
  rem = ax % y;
  r   = q * y;
  if ( rem >= y - y / 2 ) {       /* rem * 2 >= y, without overflow */
    if ( r > UINT64_MAX - y ) {
      *overflow = 1;
      return 0;
    }
    r += y;
  }
  return r;
}

/* x rounded as Float#round(ndigits) rounds it, for ndigits != 0.  NaN and
   the infinities are their own answer (Float#round raises for them when
   ndigits <= 0; an array of floats keeps them as values). */
static double
ca_round_double (double x, long ndigits)
{
  int binexp;

  if ( x == 0.0 || ! isfinite(x) ) {
    return x;
  }
  if ( ndigits > 0 ) {
    frexp(x, &binexp);
    if ( ca_round_overflow(ndigits, binexp) ) {
      return x;
    }
    if ( ca_round_underflow(ndigits, binexp) ) {
      return 0.0;
    }
    if ( ndigits > 14 ) {
      /* pow(10, ndigits) may not be exact; Ruby rounds through a Rational. */
      return NUM2DBL(rb_funcall(DBL2NUM(x), id_round, 1, LONG2NUM(ndigits)));
    }
    {
      double f = pow(10, (double) ndigits);
      return ca_round_half_up(x, f) / f;
    }
  }
  else {
    /* Ruby truncates to an Integer, then rounds the Integer. */
    double t = trunc(x);
    if ( fabs(t) < 18446744073709551616.0 ) {          /* 2**64 */
      int overflow;
      uint64_t r = ca_round_uint64((uint64_t) fabs(t), -ndigits, &overflow);
      if ( ! overflow ) {
        return ( t < 0 ) ? -(double) r : (double) r;
      }
    }
    return NUM2DBL(rb_funcall(DBL2NUM(x), id_round, 1, LONG2NUM(ndigits)));
  }
}

#define ROUND_INT_LOOP(type, lo, hi, is_signed)                               \
  {                                                                           \
    type *p = (type *) ca->ptr;                                               \
    for (i = 0; i < ca->elements; i++) {                                      \
      int neg, overflow;                                                      \
      uint64_t ax, r;                                                         \
      if ( m && m[i] ) continue;                                              \
      neg = ( is_signed ) && ( (int64_t) p[i] < 0 );                          \
      ax  = neg ? (uint64_t) 0 - (uint64_t)(int64_t) p[i] : (uint64_t) p[i];  \
      r   = ca_round_uint64(ax, -ndigits, &overflow);                         \
      if ( overflow || ( neg ? r > (uint64_t) 0 - (uint64_t)(int64_t)(lo)     \
                             : r > (uint64_t)(hi) ) ) {                       \
        rb_raise(rb_eRangeError,                                              \
                 "round: a value rounded to %ld digits does not fit "         \
                 "data_type %s", ndigits, ca_type_name[ca->data_type]);       \
      }                                                                       \
      p[i] = neg ? (type)((uint64_t) 0 - r) : (type) r;                       \
    }                                                                         \
  }

/* Rounds the cells of the entity `ca` in place; masked cells are left. */
static void
ca_round_entity (CArray *ca, long ndigits)
{
  boolean8_t *m = NULL;
  ca_size_t i;

  if ( ca->mask ) {
    m = (boolean8_t *) ca->mask->ptr;
  }

  switch ( ca->data_type ) {
  case CA_INT8:   ROUND_INT_LOOP(int8_t,   INT8_MIN,  INT8_MAX,  1); break;
  case CA_UINT8:  ROUND_INT_LOOP(uint8_t,  0,         UINT8_MAX, 0); break;
  case CA_INT16:  ROUND_INT_LOOP(int16_t,  INT16_MIN, INT16_MAX, 1); break;
  case CA_UINT16: ROUND_INT_LOOP(uint16_t, 0,         UINT16_MAX, 0); break;
  case CA_INT32:  ROUND_INT_LOOP(int32_t,  INT32_MIN, INT32_MAX, 1); break;
  case CA_UINT32: ROUND_INT_LOOP(uint32_t, 0,         UINT32_MAX, 0); break;
  case CA_INT64:  ROUND_INT_LOOP(int64_t,  INT64_MIN, INT64_MAX, 1); break;
  case CA_UINT64: ROUND_INT_LOOP(uint64_t, 0,         UINT64_MAX, 0); break;
  case CA_FLOAT32: {
    float32_t *p = (float32_t *) ca->ptr;
    for (i = 0; i < ca->elements; i++) {
      if ( m && m[i] ) continue;
      p[i] = (float32_t) ca_round_double((double) p[i], ndigits);
    }
    break;
  }
  case CA_FLOAT64: {
    float64_t *p = (float64_t *) ca->ptr;
    for (i = 0; i < ca->elements; i++) {
      if ( m && m[i] ) continue;
      p[i] = ca_round_double(p[i], ndigits);
    }
    break;
  }
  case CA_OBJECT: {
    VALUE *p = (VALUE *) ca->ptr;
    volatile VALUE nd = LONG2NUM(ndigits);
    for (i = 0; i < ca->elements; i++) {
      if ( m && m[i] ) continue;
      p[i] = rb_funcall(p[i], id_round, 1, nd);
    }
    break;
  }
  default:
    rb_raise(rb_eCADataTypeError, "round: not defined for data_type %s",
             ca_type_name[ca->data_type]);
  }
}

/* The array to round: a boolean is rounded as its 0/1 int64 values, as
   round without digits does. */
static VALUE
ca_round_source (VALUE self, VALUE vdigits, long *ndigits)
{
  CArray *ca;
  *ndigits = ca_integer_arg(vdigits, "ndigits", "round");
  ca_face_refuse_numeric(self, "round", rb_eCADataTypeError);
  GetCArray(self, ca);
  if ( ca->data_type == CA_BOOLEAN ) {
    self = rb_ca_wrap_readonly(self, INT2NUM(CA_INT64));
  }
  return self;
}

/* A copy of `src` rounded to `ndigits`.  Rounding to 0 digits is what round
   without digits does (except for objects, which are asked with the digits);
   an integer has no digits below 10**0 to round. */
static VALUE
ca_round_copy (VALUE src, long ndigits)
{
  volatile VALUE out;
  CArray *ca, *co;
  GetCArray(src, ca);
  if ( ndigits == 0 && ca->data_type != CA_OBJECT ) {
    return rb_ca_round(src);
  }
  out = rb_ca_copy(src);
  GetCArray(out, co);
  if ( ndigits > 0 && ca_is_integer_type(co) ) {
    return out;
  }
  ca_round_entity(co, ndigits);
  return out;
}

static VALUE
rb_ca_round_digits (int argc, VALUE *argv, VALUE self)
{
  long ndigits;
  rb_check_arity(argc, 0, 1);
  if ( argc == 0 ) {
    return rb_ca_round(self);
  }
  self = ca_round_source(self, argv[0], &ndigits);
  return ca_round_copy(self, ndigits);
}

static VALUE
rb_ca_round_digits_bang (int argc, VALUE *argv, VALUE self)
{
  long ndigits;
  volatile VALUE src, out;
  rb_check_arity(argc, 0, 1);
  if ( argc == 0 ) {
    return rb_ca_round_bang(self);
  }
  rb_ca_modify(self);
  src = ca_round_source(self, argv[0], &ndigits);
  if ( src != self ) {
    rb_raise(rb_eCADataTypeError,
             "round!: a boolean array can not hold the rounded int64 values");
  }
  out = ca_round_copy(self, ndigits);
  rb_ca_store_all(self, out);
  return self;
}

void
Init_carray_round (void)
{
  id_round = rb_intern("round");
  rb_define_method(rb_cCArray, "round",  rb_ca_round_digits, -1);
  rb_define_method(rb_cCArray, "round!", rb_ca_round_digits_bang, -1);
}
