/* ---------------------------------------------------------------------------

  Cast surface (3 layers):

    <type>        `a.int32` etc., and the general `a.to_type(:int32)`.
                  Returns a fresh entity CArray of the target
                  data_type.  Independent storage from `self`.  (The
                  C functions are named rb_ca_to_<type>, but the
                  methods they register carry no `to_` prefix.)

    as_<type>     `a.as_int32` etc.  Returns a writable CAMonOp view
                  that reinterprets `self` cell-by-cell at the target
                  data_type.  No new storage.

    CA_<TYPE>(data)
                  `CA_INT32(data)`, `CA_FLOAT64(data)`, ...,
                  `CA_OBJECT(data)`, `CA_FIXLEN(...)` — global
                  polymorphic cast functions (registered at file
                  bottom via rb_define_global_function).  Coerce
                  `data` (Numeric / Array / CArray / Range /
                  String / nil / object responding to `to_ca` /
                  `to_a`) into a CArray of the target data_type,
                  dispatching on `data`'s Ruby class.  Type-name
                  aliases (CA_BYTE / CA_INT / CA_FLOAT / CA_SIZE /
                  ...) reuse the canonical entry.

  Sibling of ext/carray_data_type.c (type-tag class shells +
  data_type id <-> class mapping); the CA_<TYPE>(data) functions
  here pair with the typed classes registered there.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ruby/memory_view.h"
#include "ca_monop_dispatch.h"   /* CA_MONOP_CAST_BASE for as_type routing */
#include "ca_obj_face.h"         /* ca_strip_face for write path lift */
#include "carray_internal.h"      /* rb_ca_inherit_attr */
#include "ruby/util.h"            /* ruby_strtod */
#include <math.h>

/* ------------------------------------------------------------------------
   Reading numbers from strings

   A String stored into, or converted to, an integer or float array is data,
   not a Ruby literal, so it is read as a decimal number rather than through
   Integer() / Float():

     number    [+-]? ( digit+ ( '.' digit* )? | '.' digit+ )
                     ( [eE] [+-]? digit+ )?
     float     number | nan | inf | infinity     (any case, optional sign)

   Surrounding ASCII whitespace is ignored.  "010" is ten, never octal, and
   "0x1F" / "1_000" / "0b11" are not numbers.  An integer target takes a
   number whose value is exactly an integer ("1.0", "1e3", "2.50e1"), decided
   from the digits rather than through a double, so a long integer is not
   rounded; "1.5" is not an integer.

   to_type makes a string that does not read, or an integer the target type
   cannot hold, UNDEF; a store raises (ArgumentError / RangeError).
   ------------------------------------------------------------------------ */

static int ca_str_nonfinite (const char *str, double *out);

#include "ca_pow5_table.h"

/* Decimal to binary64, correctly rounded, without the C library.

   A validated token is read as w * 10^q with w the first 19 significant
   digits.  Clinger's fast path answers when w and 10^q are both exact
   doubles (one rounding).  Otherwise the Eisel-Lemire method multiplies w
   by a 128-bit approximation of 5^q (ca_pow5_table.h) and reads the
   significand from the top of the product, declining in the rare cases
   where the product cannot settle the rounding.  A declined token, and one
   with more than 19 significant digits, goes to ruby_strtod. */

static const double ca_exact_pow10[23] = {
  1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
  1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
};

#if defined(__SIZEOF_INT128__)
static int
ca_decimal_to_double_eisel_lemire (int64_t q, uint64_t w, uint64_t *bits)
{
  const uint64_t *t;
  unsigned __int128 p;
  uint64_t hi, lo, m;
  int lz, upper;
  int64_t e2;

  if ( q < CA_POW5_Q_MIN ) {
    *bits = 0;
    return 1;
  }
  if ( q > CA_POW5_Q_MAX ) {
    *bits = 0x7FFULL << 52;
    return 1;
  }
  lz = __builtin_clzll(w);
  w <<= lz;
  t = ca_pow5_table + 2 * ( q - CA_POW5_Q_MIN );
  p = (unsigned __int128) w * t[0];
  hi = (uint64_t) ( p >> 64 );
  lo = (uint64_t) p;
  if ( ( hi & 0x1FF ) == 0x1FF ) {
    /* The bits below the significand are all ones: the low half of the
       table entry can carry into them. */
    uint64_t hi2 = (uint64_t) ( ( (unsigned __int128) w * t[1] ) >> 64 );
    lo += hi2;
    if ( lo < hi2 ) {
      hi++;
    }
    if ( ( hi & 0x1FF ) == 0x1FF && lo == UINT64_MAX && ( q < -27 || q > 55 ) ) {
      return 0;
    }
  }
  upper = (int) ( hi >> 63 );
  m = hi >> ( upper + 9 );
  /* floor(q * log2(10)) + 63, then the bias.  217706 / 2^16 is log2(10)
     closely enough for every q in the table; the floor is taken by hand,
     since >> on a negative number is the compiler's choice. */
  {
    int64_t t = 217706 * q;
    int64_t log2_10_q = ( t >= 0 ) ? t / 65536 : - ( ( - t + 65535 ) / 65536 );
    e2 = log2_10_q + 63 + upper - lz + 1023;
  }
  if ( e2 <= 0 ) {                                   /* subnormal */
    if ( -e2 + 1 >= 64 ) {
      *bits = 0;
      return 1;
    }
    m >>= -e2 + 1;
    m += m & 1;
    m >>= 1;
    e2 = ( m < ( 1ULL << 52 ) ) ? 0 : 1;
    *bits = ( (uint64_t) e2 << 52 ) | ( m & ( ( 1ULL << 52 ) - 1 ) );
    return 1;
  }
  if ( lo <= 1 && q >= -4 && q <= 23 && ( m & 3 ) == 1
       && ( m << ( upper + 9 ) ) == hi ) {
    m &= ~1ULL;                                      /* exactly halfway: to even */
  }
  m += m & 1;
  m >>= 1;
  if ( m >= ( 2ULL << 52 ) ) {
    m = 1ULL << 52;
    e2++;
  }
  m &= ~( 1ULL << 52 );
  if ( e2 >= 0x7FF ) {
    *bits = 0x7FFULL << 52;
    return 1;
  }
  *bits = ( (uint64_t) e2 << 52 ) | m;
  return 1;
}
#endif

/* 1 with the value at out, 0 to hand the token to ruby_strtod. */
static int
ca_decimal_token_to_double_without_strtod (const char *s, long n, double *out)
{
  long i = 0;
  int negative = 0, nd = 0, truncated = 0;
  uint64_t w = 0;
  int64_t q = 0, e = 0;

  if ( s[i] == '+' || s[i] == '-' ) {
    negative = ( s[i] == '-' );
    i++;
  }
  for (; i < n && s[i] >= '0' && s[i] <= '9'; i++) {
    unsigned d = (unsigned) ( s[i] - '0' );
    if ( w == 0 && d == 0 ) continue;
    if ( nd < 19 ) { w = w * 10 + d; nd++; }
    else { q++; truncated |= ( d != 0 ); }
  }
  if ( i < n && s[i] == '.' ) {
    for (i++; i < n && s[i] >= '0' && s[i] <= '9'; i++) {
      unsigned d = (unsigned) ( s[i] - '0' );
      if ( w == 0 && d == 0 ) { q--; continue; }
      if ( nd < 19 ) { w = w * 10 + d; nd++; q--; }
      else { truncated |= ( d != 0 ); }
    }
  }
  if ( i < n && ( s[i] == 'e' || s[i] == 'E' ) ) {
    int eneg = 0;
    i++;
    if ( s[i] == '+' || s[i] == '-' ) {
      eneg = ( s[i] == '-' );
      i++;
    }
    for (; i < n; i++) {
      if ( e < 100000 ) {
        e = e * 10 + ( s[i] - '0' );
      }
    }
    q += eneg ? -e : e;
  }
  if ( truncated ) {
    return 0;
  }
  if ( w == 0 ) {
    *out = negative ? -0.0 : 0.0;
    return 1;
  }
  if ( w <= ( 1ULL << 53 ) && q >= -22 && q <= 22 ) {
    double d = (double) w;
    d = ( q >= 0 ) ? d * ca_exact_pow10[q] : d / ca_exact_pow10[-q];
    *out = negative ? -d : d;
    return 1;
  }
#if defined(__SIZEOF_INT128__)
  {
    uint64_t bits;
    double d;
    if ( ! ca_decimal_to_double_eisel_lemire(q, w, &bits) ) {
      return 0;
    }
    memcpy(&d, &bits, sizeof(d));
    *out = negative ? -d : d;
    return 1;
  }
#else
  return 0;
#endif
}

static double
ca_decimal_token_to_double (const char *s, long n, const char *buf)
{
  double d;
  if ( ca_decimal_token_to_double_without_strtod(s, n, &d) ) {
    return d;
  }
  return ruby_strtod(buf, NULL);
}

enum {
  CA_DECIMAL_OK = 0,
  CA_DECIMAL_BLANK,
  CA_DECIMAL_UNREADABLE,
  CA_DECIMAL_OUT_OF_RANGE
};

static int
ca_decimal_is_space (char c)
{
  return c == ' ' || c == '\t' || c == '\n' || c == '\r'
         || c == '\v' || c == '\f';
}

static void
ca_decimal_trim (const char **str, long *len)
{
  const char *s = *str;
  long n = *len;
  while ( n > 0 && ca_decimal_is_space(s[0]) ) {
    s++;
    n--;
  }
  while ( n > 0 && ca_decimal_is_space(s[n-1]) ) {
    n--;
  }
  *str = s;
  *len = n;
}

/* A decimal number whose value is exactly an integer, into a sign and a
   magnitude.  The digits are read with the decimal point moved by the
   exponent: those left of it form the magnitude, those right of it must all
   be zero.  Returns CA_DECIMAL_OK, CA_DECIMAL_UNREADABLE, or
   CA_DECIMAL_OUT_OF_RANGE for a magnitude beyond uint64. */
static int
ca_decimal_integer (const char *s, long n, int *negative, uint64_t *magnitude)
{
  long i = 0, int_start, int_end, frac_start, frac_end;
  long nint, total, point, exponent = 0, k;
  int exponent_negative = 0;
  uint64_t v = 0;
  *negative = 0;
  if ( i < n && ( s[i] == '+' || s[i] == '-' ) ) {
    *negative = ( s[i] == '-' );
    i++;
  }
  int_start = i;
  while ( i < n && s[i] >= '0' && s[i] <= '9' ) {
    i++;
  }
  int_end = frac_start = frac_end = i;
  if ( i < n && s[i] == '.' ) {
    i++;
    frac_start = i;
    while ( i < n && s[i] >= '0' && s[i] <= '9' ) {
      i++;
    }
    frac_end = i;
  }
  nint  = int_end - int_start;
  total = nint + ( frac_end - frac_start );
  if ( total == 0 ) {
    return CA_DECIMAL_UNREADABLE;
  }
  if ( i < n && ( s[i] == 'e' || s[i] == 'E' ) ) {
    long exponent_digits = 0;
    i++;
    if ( i < n && ( s[i] == '+' || s[i] == '-' ) ) {
      exponent_negative = ( s[i] == '-' );
      i++;
    }
    while ( i < n && s[i] >= '0' && s[i] <= '9' ) {
      if ( exponent < 1000000 ) {            /* saturate; far past any fit */
        exponent = exponent * 10 + ( s[i] - '0' );
      }
      i++;
      exponent_digits++;
    }
    if ( exponent_digits == 0 ) {
      return CA_DECIMAL_UNREADABLE;
    }
    if ( exponent_negative ) {
      exponent = - exponent;
    }
  }
  if ( i != n ) {
    return CA_DECIMAL_UNREADABLE;
  }
  point = nint + exponent;
  for (k = 0; k < total; k++) {
    char c = ( k < nint ) ? s[int_start + k] : s[frac_start + k - nint];
    unsigned d = (unsigned) ( c - '0' );
    if ( k >= point ) {
      if ( d != 0 ) {
        return CA_DECIMAL_UNREADABLE;       /* a fractional part */
      }
      continue;
    }
    if ( v > ( UINT64_MAX - d ) / 10 ) {
      return CA_DECIMAL_OUT_OF_RANGE;
    }
    v = v * 10 + d;
  }
  for (k = total; k < point && v != 0; k++) {
    if ( v > UINT64_MAX / 10 ) {
      return CA_DECIMAL_OUT_OF_RANGE;
    }
    v *= 10;
  }
  *magnitude = v;
  return CA_DECIMAL_OK;
}

/* Whether s could be nan / inf / infinity: a letter after an optional sign. */
static int
ca_decimal_may_be_word (const char *s, long n)
{
  long i = ( s[0] == '+' || s[0] == '-' ) ? 1 : 0;
  return i < n && ( ( s[i] | 0x20 ) == 'n' || ( s[i] | 0x20 ) == 'i' );
}

/* A decimal float, written to out.  With out NULL, only whether s is one. */
static int
ca_decimal_float (const char *s, long n, double *out)
{
  char buf[64];
  long i = 0, digits = 0;
  double nonfinite;
  if ( n == 0 ) {
    return 0;
  }
  if ( n <= 9 && ca_decimal_may_be_word(s, n) ) {   /* longest: "+infinity" */
    memcpy(buf, s, n);
    buf[n] = '\0';
    if ( ca_str_nonfinite(buf, &nonfinite) ) {
      if ( out ) {
        *out = nonfinite;
      }
      return 1;
    }
  }
  if ( s[i] == '+' || s[i] == '-' ) {
    i++;
  }
  while ( i < n && s[i] >= '0' && s[i] <= '9' ) {
    i++;
    digits++;
  }
  if ( i < n && s[i] == '.' ) {
    i++;
    while ( i < n && s[i] >= '0' && s[i] <= '9' ) {
      i++;
      digits++;
    }
  }
  if ( digits == 0 ) {
    return 0;
  }
  if ( i < n && ( s[i] == 'e' || s[i] == 'E' ) ) {
    long exponent_digits = 0;
    i++;
    if ( i < n && ( s[i] == '+' || s[i] == '-' ) ) {
      i++;
    }
    while ( i < n && s[i] >= '0' && s[i] <= '9' ) {
      i++;
      exponent_digits++;
    }
    if ( exponent_digits == 0 ) {
      return 0;
    }
  }
  if ( i != n ) {
    return 0;
  }
  if ( out == NULL ) {
    return 1;
  }
  /* The token is validated, so the reader sees nothing but a decimal
     number. */
  if ( n < (long) sizeof(buf) ) {
    memcpy(buf, s, n);
    buf[n] = '\0';
    *out = ca_decimal_token_to_double(s, n, buf);
  }
  else {
    volatile VALUE token = rb_str_new(s, n);
    *out = ruby_strtod(RSTRING_PTR(token), NULL);
  }
  return 1;
}

static int
ca_decimal_fits (int8_t data_type, int negative, uint64_t magnitude)
{
  uint64_t positive_max, negative_max;
  switch ( data_type ) {
  case CA_INT8:   positive_max = INT8_MAX;   negative_max = (uint64_t) INT8_MAX + 1;  break;
  case CA_INT16:  positive_max = INT16_MAX;  negative_max = (uint64_t) INT16_MAX + 1; break;
  case CA_INT32:  positive_max = INT32_MAX;  negative_max = (uint64_t) INT32_MAX + 1; break;
  case CA_INT64:  positive_max = INT64_MAX;  negative_max = (uint64_t) INT64_MAX + 1; break;
  case CA_UINT8:  positive_max = UINT8_MAX;  negative_max = 0; break;
  case CA_UINT16: positive_max = UINT16_MAX; negative_max = 0; break;
  case CA_UINT32: positive_max = UINT32_MAX; negative_max = 0; break;
  case CA_UINT64: positive_max = UINT64_MAX; negative_max = 0; break;
  default:
    return 0;
  }
  return negative ? ( magnitude <= negative_max ) : ( magnitude <= positive_max );
}

/* Store a value that ca_decimal_fits accepted. */
static void
ca_decimal_store_integer (int8_t data_type, char *ptr, ca_size_t i,
                          int negative, uint64_t magnitude)
{
  int64_t v;
  if ( negative && magnitude > 0 ) {
    v = - (int64_t) ( magnitude - 1 ) - 1;
  }
  else {
    v = (int64_t) magnitude;
  }
  switch ( data_type ) {
  case CA_INT8:   ((int8_t *)   ptr)[i] = (int8_t) v;   break;
  case CA_INT16:  ((int16_t *)  ptr)[i] = (int16_t) v;  break;
  case CA_INT32:  ((int32_t *)  ptr)[i] = (int32_t) v;  break;
  case CA_INT64:  ((int64_t *)  ptr)[i] = v;            break;
  case CA_UINT8:  ((uint8_t *)  ptr)[i] = (uint8_t) magnitude;  break;
  case CA_UINT16: ((uint16_t *) ptr)[i] = (uint16_t) magnitude; break;
  case CA_UINT32: ((uint32_t *) ptr)[i] = (uint32_t) magnitude; break;
  case CA_UINT64: ((uint64_t *) ptr)[i] = magnitude;            break;
  }
}

/* Whether v is a real number other than an Integer or a Float -- a Rational,
   a BigDecimal -- which reads as the value it stands for. */
static int
ca_decimal_other_real (VALUE v)
{
  return RTEST(rb_obj_is_kind_of(v, rb_cNumeric))
      && RTEST(rb_funcall(v, rb_intern("real?"), 0));
}

static VALUE
ca_decimal_truncate (VALUE v)
{
  return rb_funcall(v, rb_intern("truncate"), 0);
}

/* A non-String cell as an integer: an Integer, or a Float or another real
   number with no fractional part, that the target can hold. */
static int
ca_decimal_object_integer (VALUE v, int *negative, uint64_t *magnitude)
{
  if ( ! RB_INTEGER_TYPE_P(v) && ! RB_FLOAT_TYPE_P(v) && ca_decimal_other_real(v) ) {
    /* truncate raises for a NaN or infinite BigDecimal, which reads as
       nothing an integer can hold. */
    int state = 0;
    VALUE whole = rb_protect(ca_decimal_truncate, v, &state);
    if ( state ) {
      rb_set_errinfo(Qnil);
      return 0;
    }
    if ( ! RB_INTEGER_TYPE_P(whole) || ! RTEST(rb_equal(whole, v)) ) {
      return 0;
    }
    v = whole;
  }
  if ( RB_INTEGER_TYPE_P(v) ) {
    VALUE zero = INT2FIX(0);
    *negative = RTEST(rb_funcall(v, '<', 1, zero));
    if ( *negative ) {
      v = rb_funcall(v, rb_intern("-@"), 0);
    }
    if ( RTEST(rb_funcall(v, '>', 1, ULL2NUM(UINT64_MAX))) ) {
      return 0;
    }
    *magnitude = NUM2ULL(v);
    return 1;
  }
  if ( RB_FLOAT_TYPE_P(v) ) {
    double d = RFLOAT_VALUE(v);
    if ( d != d || d != floor(d) || fabs(d) >= 18446744073709551616.0 ) {
      return 0;
    }
    *negative = ( d < 0 );
    *magnitude = (uint64_t) fabs(d);
    return 1;
  }
  return 0;
}

/* A String as one value of data_type (an integer or float type), written
   to out. */
static int
ca_decimal_string_read (VALUE str, int8_t data_type, void *out)
{
  const char *s = RSTRING_PTR(str);
  long n = RSTRING_LEN(str);
  ca_decimal_trim(&s, &n);
  if ( n == 0 ) {
    return CA_DECIMAL_BLANK;
  }
  if ( data_type == CA_FLOAT32 || data_type == CA_FLOAT64 ) {
    double d;
    if ( ! ca_decimal_float(s, n, &d) ) {
      return CA_DECIMAL_UNREADABLE;
    }
    if ( data_type == CA_FLOAT32 ) {
      *(float32_t *) out = (float32_t) d;
    }
    else {
      *(float64_t *) out = d;
    }
    return CA_DECIMAL_OK;
  }
  else {
    int negative = 0;
    uint64_t magnitude = 0;
    int rc = ca_decimal_integer(s, n, &negative, &magnitude);
    if ( rc != CA_DECIMAL_OK ) {
      return rc;
    }
    if ( ! ca_decimal_fits(data_type, negative, magnitude) ) {
      return CA_DECIMAL_OUT_OF_RANGE;
    }
    ca_decimal_store_integer(data_type, (char *) out, 0, negative, magnitude);
    return CA_DECIMAL_OK;
  }
}

/* The to_type reader: 1 with the value at out, or 0 for a cell that
   becomes UNDEF. */
int
ca_decimal_string_to (VALUE str, int8_t data_type, void *out)
{
  return ca_decimal_string_read(str, data_type, out) == CA_DECIMAL_OK;
}

/* The store reader: the value at out, or a raise. */
void
ca_decimal_string_store (VALUE str, int8_t data_type, void *out)
{
  switch ( ca_decimal_string_read(str, data_type, out) ) {
  case CA_DECIMAL_OK:
    return;
  case CA_DECIMAL_OUT_OF_RANGE:
    rb_raise(rb_eRangeError, "%+"PRIsVALUE" is out of range for %s",
             str, ca_type_name[data_type]);
  default:
    rb_raise(rb_eArgError, "%+"PRIsVALUE" cannot be read as %s",
             str, ca_type_name[data_type]);
  }
}

boolean8_t
OBJ2BOOL (VALUE v)
{
  if ( v == Qfalse ) {
    return 0;
  }
  else if ( v == Qtrue ) {
    return 1;
  }
  else if ( rb_obj_is_kind_of(v, rb_cInteger) ) {
    int flag = NUM2INT(v);
    if ( flag == 0 || flag == 1 ) {
      return flag;
    }
  }
  {
    VALUE inspect = rb_inspect(v);
    rb_raise(rb_eCADataTypeError,
             "can't cast object '%s' to <boolean>", StringValuePtr(inspect));
  }
}

VALUE
BOOL2OBJ (boolean8_t x)
{
  return ( x != 0 ) ? INT2NUM(1) : INT2NUM(0);
}

/* Recognise an explicit non-finite float literal.  `str` must already be
   whitespace-stripped.  The whole token is matched case-insensitively as an
   exact match (not a prefix): only nan / inf / infinity with an optional
   +/- sign map to a non-finite value.  Returns 1 and sets *out on a match,
   0 otherwise -- so "nancy" / "info" / "inflation" fall through to the
   numeric parser instead of being read as NaN/Infinity. */
static int
ca_str_nonfinite (const char *str, double *out)
{
  if ( ! strcasecmp(str, "nan")
       || ! strcasecmp(str, "+nan")
       || ! strcasecmp(str, "-nan") ) {
    *out = 0.0/0.0;
    return 1;
  }
  else if ( ! strcasecmp(str, "inf")
            || ! strcasecmp(str, "+inf")
            || ! strcasecmp(str, "infinity")
            || ! strcasecmp(str, "+infinity") ) {
    *out = 1.0/0.0;
    return 1;
  }
  else if ( ! strcasecmp(str, "-inf")
            || ! strcasecmp(str, "-infinity") ) {
    *out = -1.0/0.0;
    return 1;
  }
  return 0;
}

double
OBJ2DBL (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FLOAT:
    return NUM2DBL(val);
  case T_STRING: {
    double d;
    ca_decimal_string_store(val, CA_FLOAT64, &d);
    return d;
  }
  default:
    return NUM2DBL(rb_Float(val));
  }
}

/* rb_protect bodies: Kernel#Float / Kernel#Integer applied to one value
   that is not a String.  Used by the mask-aware object->numeric parsers
   below so a conversion error is caught (and turned into a masked cell)
   rather than raised. */
static VALUE
ca_kernel_float (VALUE v)
{
  return rb_Float(v);
}

static VALUE
ca_kernel_integer (VALUE v)
{
  return rb_Integer(v);
}

/* A real is read as a decimal number; anything else goes to Complex(). */
double complex
ca_str_to_cmplx (VALUE str)
{
  volatile VALUE rstr;
  volatile VALUE c;
  double d;
  if ( ca_decimal_string_to(str, CA_FLOAT64, &d) ) {
    return (double complex) d;
  }
  rstr = rb_funcall(str, rb_intern("strip"), 0);
  c = rb_funcall(rb_mKernel, rb_intern("Complex"), 1, rstr);
  return CMPLX(NUM2DBL(rb_complex_real(c)), NUM2DBL(rb_complex_imag(c)));
}

/* Object -> double with parse-failure signalling.  Returns 1 and sets *out
   on success; returns 0 when the cell cannot be parsed, in which case the
   caller writes UNDEF (mask) for that cell.  nil and unreadable
   strings/objects fail; already-numeric values succeed, and a String is
   read as a decimal number.  This is the reading path of to_type from an
   object array, where a cell with no number in it is a missing value; a
   store (OBJ2DBL) raises instead. */
int
ca_obj2dbl_ok (VALUE val, double *out)
{
  if ( NIL_P(val) ) {
    return 0;
  }
  if ( RB_FLOAT_TYPE_P(val) || RB_INTEGER_TYPE_P(val) ) {
    *out = NUM2DBL(val);
    return 1;
  }
  if ( RB_TYPE_P(val, T_STRING) ) {
    return ca_decimal_string_to(val, CA_FLOAT64, out);
  }
  {
    int state = 0;
    volatile VALUE r = rb_protect(ca_kernel_float, val, &state);
    if ( state ) {
      rb_set_errinfo(Qnil);
      return 0;
    }
    *out = NUM2DBL(r);
    return 1;
  }
}

/* Object -> complex with parse-failure signalling: the complex sibling of
   ca_obj2dbl_ok.  A cell is read as a store reads it (a real as a decimal
   number, the rest as Complex()); nil and a cell that does not read fail. */
static VALUE
ca_cmplx_cell_body (VALUE v)
{
  double complex z = rb_carray_num2cmplx(v);
  return rb_dbl_complex_new(creal(z), cimag(z));
}

int
ca_obj2cmplx_ok (VALUE val, double complex *out)
{
  int state = 0;
  volatile VALUE r;
  if ( NIL_P(val) ) {
    return 0;
  }
  r = rb_protect(ca_cmplx_cell_body, val, &state);
  if ( state ) {
    rb_set_errinfo(Qnil);
    return 0;
  }
  *out = CMPLX(NUM2DBL(rb_complex_real(r)), NUM2DBL(rb_complex_imag(r)));
  return 1;
}

/* Object -> integer with parse-failure signalling.  Same contract as
   ca_obj2dbl_ok: 1 + *out on success, 0 (mask) on failure.  A String is
   read as a decimal number ("1.5" fails, no truncation); any other object
   goes through Integer().  nil fails.  A valid Integer that overflows the
   widest C integer still raises (a domain error, not a parse failure). */
static int
ca_obj2integer_ok (VALUE val, int8_t wide_type, void *wide, VALUE *integer)
{
  int state = 0;
  if ( NIL_P(val) ) {
    return 0;
  }
  if ( RB_TYPE_P(val, T_STRING) ) {
    return ca_decimal_string_to(val, wide_type, wide);
  }
  *integer = rb_protect(ca_kernel_integer, val, &state);
  if ( state ) {
    rb_set_errinfo(Qnil);
    return 0;
  }
  return 1;
}

int
rb_obj2long_ok (VALUE val, long *out)
{
  int64_t wide;
  VALUE integer = Qnil;
  if ( RB_TYPE_P(val, T_FIXNUM) ) {
    *out = NUM2LONG(val);
    return 1;
  }
  if ( ! ca_obj2integer_ok(val, CA_INT64, &wide, &integer) ) {
    return 0;
  }
  *out = NIL_P(integer) ? (long) wide : NUM2LONG(integer);
  return 1;
}

int
rb_obj2ulong_ok (VALUE val, unsigned long *out)
{
  uint64_t wide;
  VALUE integer = Qnil;
  if ( RB_TYPE_P(val, T_FIXNUM) ) {
    *out = NUM2ULONG(val);
    return 1;
  }
  if ( ! ca_obj2integer_ok(val, CA_UINT64, &wide, &integer) ) {
    return 0;
  }
  *out = NIL_P(integer) ? (unsigned long) wide : NUM2ULONG(integer);
  return 1;
}

int
rb_obj2ll_ok (VALUE val, long long *out)
{
  int64_t wide;
  VALUE integer = Qnil;
  if ( RB_TYPE_P(val, T_FIXNUM) ) {
    *out = NUM2LL(val);
    return 1;
  }
  if ( ! ca_obj2integer_ok(val, CA_INT64, &wide, &integer) ) {
    return 0;
  }
  *out = NIL_P(integer) ? (long long) wide : NUM2LL(integer);
  return 1;
}

int
rb_obj2ull_ok (VALUE val, unsigned long long *out)
{
  uint64_t wide;
  VALUE integer = Qnil;
  if ( RB_TYPE_P(val, T_FIXNUM) ) {
    *out = NUM2ULL(val);
    return 1;
  }
  if ( ! ca_obj2integer_ok(val, CA_UINT64, &wide, &integer) ) {
    return 0;
  }
  *out = NIL_P(integer) ? (unsigned long long) wide : rb_num2ull(integer);
  return 1;
}

long
rb_obj2long (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FIXNUM:
    return NUM2LONG(val);
  case T_BIGNUM:
    return (long) NUM2LL(val);
  case T_NIL:
    rb_raise(rb_eTypeError, "can't convert nil into Integer");
    break;
  case T_STRING: {
    int64_t v;
    ca_decimal_string_store(val, CA_INT64, &v);
    return (long) v;
  }
  default:
    return NUM2LONG(rb_Integer(val));
  }
}

unsigned long
rb_obj2ulong (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FIXNUM:
    return NUM2ULONG(val);
  case T_BIGNUM:
    return (unsigned long) rb_num2ull(val);
  case T_NIL:
    rb_raise(rb_eTypeError, "can't convert nil into Integer");
    break;
  case T_STRING: {
    uint64_t v;
    ca_decimal_string_store(val, CA_UINT64, &v);
    return (unsigned long) v;
  }
  default:
    return NUM2ULONG(rb_Integer(val));
  }
}

long long
rb_obj2ll (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FIXNUM:
    return NUM2LONG(val);
  case T_NIL:
    rb_raise(rb_eTypeError, "can't convert nil into Integer");
    break;
  case T_STRING: {
    int64_t v;
    ca_decimal_string_store(val, CA_INT64, &v);
    return (long long) v;
  }
  default:
    return NUM2LL(rb_Integer(val));
  }
}

unsigned long long
rb_obj2ull (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FIXNUM:
    return NUM2ULONG(val);
  case T_NIL:
    rb_raise(rb_eTypeError, "can't convert nil into Integer");
    break;
  case T_STRING: {
    uint64_t v;
    ca_decimal_string_store(val, CA_UINT64, &v);
    return (unsigned long long) v;
  }
  default:
    return rb_num2ull(rb_Integer(val));
  }
}

/* Face has surface != storage; cast operates on the storage
 * data_type, which lives at the parent chain bottom (the first
 * non-Face ancestor).  This predicate is defensive: stack-allocated
 * dummy CArrays may have an uninitialised obj_type, so we additionally
 * require obj_type to fall in the valid range before treating `ca`
 * as a Face. */
static inline int
ca_face_safe_check (CArray *ca)
{
  return ca && ca_is_face(ca)
         && ca->obj_type >= 0 && ca->obj_type < CA_OBJ_TYPE_MAX;
}

static inline int8_t
ca_storage_type_of (CArray *ca)
{
  while (ca_face_safe_check(ca)) ca = ((CAView *) ca)->parent;
  return ca ? ca->data_type : CA_FIXLEN;
}

void
ca_cast_block (ca_size_t n, void *ap1, void *ptr1,
               void *ap2, void *ptr2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( n < 0 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] in ca_cast_block(): negative count");
  }
  ca_cast_func_table[ca1->data_type][ca2->data_type](n, ca1, ptr1, ca2, ptr2, NULL);
}

void
ca_cast_block_with_mask (ca_size_t n, void *ap1, void *ptr1,
                         void *ap2, void *ptr2, boolean8_t *m)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( n < 0 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] in ca_cast_block_with_mask(): negative count");
  }
  ca_cast_func_table[ca1->data_type][ca2->data_type](n, ca1, ptr1, ca2, ptr2, m);
}

VALUE
ca_ptr2obj (void *ap, void *ptr)
{
  volatile VALUE obj;
  static CArray dummy;
  CArray *ca = (CArray *) ap;
  dummy.data_type = CA_OBJECT;
  ca_cast_func_table[ca->data_type][CA_OBJECT](1, ca, ptr, &dummy, (void*)&obj, NULL);
  return obj;
}

void
ca_obj2ptr (void *ap, VALUE obj, void *ptr)
{
  CArray *ca = (CArray *)ap;
  static CArray dummy;
  dummy.data_type = CA_OBJECT;
  ca_cast_func_table[CA_OBJECT][ca->data_type](1, &dummy, &obj, ca, ptr, NULL);
  return;
}

void
ca_ptr2ptr (void *ap1, void *ptr1, void *ap2, void *ptr2)
{
  CArray *ca1 = (CArray *)ap1;
  CArray *ca2 = (CArray *)ap2;
  ca_cast_func_table[ca1->data_type][ca2->data_type](1, ca1, ptr1, ca2, ptr2, NULL);
  return;
}

void
ca_ptr2val (void *ap1, void *ptr1, int8_t data_type, void *ptr2)
{
  CArray *ca1 = (CArray *)ap1;
  static CArray dummy;
  CA_CHECK_DATA_TYPE(data_type);
  dummy.data_type = data_type;
  ca_cast_func_table[ca1->data_type][data_type](1, ca1, ptr1, &dummy, ptr2, NULL);
  return;
}

void
ca_val2ptr (int8_t data_type, void *ptr1, void *ap2, void *ptr2)
{
  CArray *ca2 = (CArray *)ap2;
  static CArray dummy;
  CA_CHECK_DATA_TYPE(data_type);
  dummy.data_type = data_type;
  ca_cast_func_table[data_type][ca2->data_type](1, &dummy, ptr1, ca2, ptr2, NULL);
  return;
}

void
ca_val2val (int8_t data_type1, void *ptr1, int8_t data_type2, void *ptr2)
{
  static CArray dummy1, dummy2;
  CA_CHECK_DATA_TYPE(data_type1);
  CA_CHECK_DATA_TYPE(data_type2);
  dummy1.data_type = data_type1;
  dummy2.data_type = data_type2;
  ca_cast_func_table[data_type1][data_type2](1, &dummy1, ptr1, &dummy2, ptr2, NULL);
  return;
}

/* --------------------------------------------------------------------- */

/* Cast to CA_OBJECT for an array whose cells mean something other than their
   storage bytes: a data_class array (CARecord / CAStruct) or a Face (CATime,
   CAConstString, CACategorical, ...).  Both decode per cell -- rb_ca_fetch_addr
   goes through the data_class decode and CA_FACE_STORAGE_TO_ELEMENT_IF_FACE --
   so the object array holds the *surface* values (labels, not codes;
   CATime::Element, not serials; the string, not the descriptor bytes).  Reading
   the storage instead is `.parent`, which stays available and explicit.  Mask
   and shape carry. */
static VALUE
rb_ca_surface_to_object (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_scalar(ca) ) {
    obj = rb_cscalar_new(CA_OBJECT, 0, ca->mask);
  }
  else {
    obj = rb_carray_new(CA_OBJECT, ca->ndim, ca->dim, 0, ca->mask);
  }

  for (i=0; i<ca->elements; i++) {
    rb_ca_store_addr(obj, i, rb_ca_fetch_addr(self, i));
  }

  return obj;
}

/* Cast a NonNumeric Face (= one whose surface declares CA_FIXLEN, so the
   numeric kernel dispatch is gated off) to a type other than :object.

   Reading the storage would hand back the bytes the surface exists to hide,
   and there is no way for the core to guess how a surface becomes a number:
   a fixed-point cell is its storage over a scale, a categorical cell is a
   label, a time cell is not a number at all.  So the Face declares it, with
   #to_numeric returning a plain CArray of its values, and everything else is
   an ordinary cast of that.  A Face that declares nothing raises: it is the
   Face saying "my values are not numbers", which is information, unlike an
   array of UNDEF.

   The projection is array-level on purpose.  Going through the surface cell
   by cell (to_type(:object) and Ruby #to_f) measured 449 ms against 1.45 ms
   for the vectorised expression the author writes anyway (1M cells,
   CAFixedPoint = parent.float64 / scale). */
static VALUE
rb_ca_face_numeric_projection (VALUE self, CArray *ca)
{
  static ID id_to_numeric = 0;
  VALUE num;
  CArray *cn;

  if ( id_to_numeric == 0 ) {
    id_to_numeric = rb_intern("to_numeric");
  }

  if ( ! rb_respond_to(self, id_to_numeric) ) {
    rb_raise(rb_eTypeError,
             "%s declares no numeric conversion: define #to_numeric to say "
             "how its values become numbers, or take the surface with "
             "to_type(:object) / the storage with #parent",
             rb_obj_classname(self));
  }

  num = rb_funcall(self, id_to_numeric, 0);

  if ( ! rb_obj_is_carray(num) ) {
    rb_raise(rb_eTypeError,
             "%s#to_numeric must return a CArray (got %s)",
             rb_obj_classname(self), rb_obj_classname(num));
  }

  TypedData_Get_Struct(num, CArray, &carray_data_type, cn);

  if ( ca_is_face(cn) ) {
    rb_raise(rb_eTypeError,
             "%s#to_numeric must return a plain CArray, not a Face (got %s)",
             rb_obj_classname(self), rb_obj_classname(num));
  }

  if ( cn->elements != ca->elements ) {
    rb_raise(rb_eArgError,
             "%s#to_numeric returned %lld elements, expected %lld",
             rb_obj_classname(self),
             (long long) cn->elements, (long long) ca->elements);
  }

  return num;
}

static VALUE
rb_ca_object_to_data_class (VALUE self, VALUE rtype, ca_size_t bytes) 
{
  volatile VALUE obj, rval;
  CArray *ca;
  int i;
  ID id_encode = rb_intern("encode");

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_scalar(ca) ) {
    obj = rb_cscalar_new(CA_FIXLEN, bytes, ca->mask);
  }
  else {
    obj = rb_carray_new(CA_FIXLEN, ca->ndim, ca->dim, bytes, ca->mask);
  }

  for (i=0; i<ca->elements; i++) {
    rval = rb_ca_fetch_addr(self, i);
    if ( TYPE(rval) == T_STRING ) {
      rb_ca_store_addr(obj, i, rval);
    }
    else {
      rb_ca_store_addr(obj, i, rb_funcall(rval, id_encode, 0));
    }
  }
  
  return obj;
}

typedef struct {
  CArray     *ca;
  CArray     *cb;
  boolean8_t *scratch;
} ca_to_type_ctx_t;

/* Marks in `m` the cells of a float or complex array that hold NaN (in
   either part).  A NaN has no integer, and C leaves its conversion
   undefined. */
static void
ca_mark_nan (CArray *ca, boolean8_t *m)
{
  ca_size_t i, n = ca->elements;
  switch ( ca->data_type ) {
  case CA_FLOAT32: { float32_t *p = (float32_t *) ca->ptr;
    for (i=0; i<n; i++) if ( isnan(p[i]) ) m[i] = 1;
    break; }
  case CA_FLOAT64: { float64_t *p = (float64_t *) ca->ptr;
    for (i=0; i<n; i++) if ( isnan(p[i]) ) m[i] = 1;
    break; }
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64: { cmplx64_t *p = (cmplx64_t *) ca->ptr;
    for (i=0; i<n; i++) if ( isnan(crealf(p[i])) || isnan(cimagf(p[i])) ) m[i] = 1;
    break; }
  case CA_CMPLX128: { cmplx128_t *p = (cmplx128_t *) ca->ptr;
    for (i=0; i<n; i++) if ( isnan(creal(p[i])) || isnan(cimag(p[i])) ) m[i] = 1;
    break; }
#endif
  default:
    break;
  }
}

/* The cast proper, with `ca` attached.  It can raise (a value the target
   type cannot hold), so it runs under rb_ensure. */
static VALUE
ca_to_type_cast (VALUE arg)
{
  ca_to_type_ctx_t *c = (ca_to_type_ctx_t *) arg;
  CArray *ca = c->ca, *cb = c->cb;
  int to_integer = ( cb->data_type >= CA_INT8 && cb->data_type <= CA_UINT64 );
  int from_float = ( ca->data_type == CA_FLOAT32 || ca->data_type == CA_FLOAT64
                     || ca->data_type == CA_CMPLX64 || ca->data_type == CA_CMPLX128 );

  if ( ( ca->data_type == CA_OBJECT
         && ( to_integer
              || cb->data_type == CA_FLOAT32 || cb->data_type == CA_FLOAT64
              || cb->data_type == CA_CMPLX64 || cb->data_type == CA_CMPLX128 ) )
       || ( from_float && to_integer ) ) {
    /* object -> int/float/complex: give the cast a mask buffer so an unparseable
       cell becomes UNDEF (see ext/carray_cast_func.rb).  Cast into a
       scratch mask seeded from the source mask, then attach it to the
       output only if some cell ended up masked -- an all-valid cast keeps
       the mask-less result the legacy path produced. */
    ca_size_t ne = cb->elements;
    ca_size_t i;
    boolean8_t any = 0;
    boolean8_t *scratch;
    c->scratch = scratch = ALLOC_N(boolean8_t, ne > 0 ? ne : 1);
    if ( cb->mask ) {
      memcpy(scratch, cb->mask->ptr, ne);   /* copy of source mask */
    }
    else {
      memset(scratch, 0, ne);
    }
    /* float -> integer: a NaN cell becomes UNDEF, as an unparseable object
       cell does.  A finite value outside the integer type is converted the
       way the machine's C converts it, which differs between machines. */
    if ( from_float ) {
      ca_mark_nan(ca, scratch);
      memset(cb->ptr, 0, ne * cb->bytes);
    }
    ca_cast_block_with_mask(ne, ca, ca->ptr, cb, cb->ptr, scratch);
    for (i=0; i<ne; i++) {
      if ( scratch[i] ) {
        any = 1;
        break;
      }
    }
    if ( any ) {
      if ( ! cb->mask ) {
        ca_create_mask(cb);
      }
      memcpy(cb->mask->ptr, scratch, ne);
    }
    xfree(scratch);
    c->scratch = NULL;
  }
  else if ( ca_has_mask(ca) ) {
    ca_cast_block_with_mask(cb->elements, ca, ca->ptr, cb, cb->ptr,
                            (boolean8_t*)ca->mask->ptr);
  }
  else {
    ca_cast_block(cb->elements, ca, ca->ptr, cb, cb->ptr);
  }
  return Qnil;
}

static VALUE
ca_to_type_release (VALUE arg)
{
  ca_to_type_ctx_t *c = (ca_to_type_ctx_t *) arg;
  if ( c->scratch ) {
    xfree(c->scratch);
    c->scratch = NULL;
  }
  ca_detach(c->ca);
  return Qnil;
}

/* CArray#to_type(data_type, bytes:) -- eager copy of self converted to
   data_type (a new entity owning its storage).  User doc lives in
   yard-stubs/carray_cast.rb. */

static VALUE rb_ca_to_type_convert (int argc, VALUE *argv, VALUE self);

/* The converted array keeps self's attributes: the values are the same
   values in another representation. */
static VALUE
rb_ca_to_type_internal (int argc, VALUE *argv, VALUE self)
{
  VALUE obj = rb_ca_to_type_convert(argc, argv, self);
  rb_ca_inherit_attr(obj, self);
  return obj;
}

static VALUE
rb_ca_to_type_convert (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rtype = Qnil, ropt, rbytes = Qnil;
  CArray *ca, *cb;
  ca_to_type_ctx_t ctx;
  int8_t data_type;
  ca_size_t bytes;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

  if ( ( rb_ca_has_data_class(self) || ca_is_face(ca) ) && data_type == CA_OBJECT ) {
    return rb_ca_surface_to_object(self);
  }

  if ( rb_ca_is_object_type(self) && rb_obj_is_data_class(rtype) ) {
    return rb_ca_object_to_data_class(self, rtype, bytes);
  }

  /* NonNumeric Face (CA_FIXLEN surface = the numeric gate) to anything but
     :object: the values come from the Face's own #to_numeric, and the
     request is then served by an ordinary cast of that plain array.  A
     Numeric Face is not routed here -- its surface *is* its storage, so the
     ordinary cast below is already right. */
  if ( ca_is_face(ca) && ca->data_type == CA_FIXLEN ) {
    return rb_ca_to_type_convert(argc, argv,
                                 rb_ca_face_numeric_projection(self, ca));
  }

  ca_update_mask(ca);

  if ( ca_is_scalar(ca) ) {
    obj = rb_cscalar_new(data_type, bytes, ca->mask);
  }
  else {
    obj = rb_carray_new(data_type, ca->ndim, ca->dim, bytes, ca->mask);
  }


  TypedData_Get_Struct(obj, CArray, &carray_data_type, cb);

  ctx.ca      = ca;
  ctx.cb      = cb;
  ctx.scratch = NULL;
  ca_attach(ca);   /* window: released by ca_to_type_release under rb_ensure */
  rb_ensure(ca_to_type_cast, (VALUE) &ctx, ca_to_type_release, (VALUE) &ctx);

  /* When rtype is a data_class (e.g. CAStruct subclass), wrap the
     result in CARecord so the cast output carries data_class. */
  if ( rb_obj_is_data_class(rtype) ) {
    obj = rb_funcall(rb_const_get(rb_cObject, rb_intern("CARecord")),
                     rb_intern("wrap"), 2, obj, rtype);
  }

  return obj;
}

VALUE
rb_ca_to_type (VALUE self, VALUE rtype, VALUE rbytes)
{
  volatile VALUE ropt = rb_hash_new();
  VALUE args[2] = { rtype, ropt };
  rb_set_options(ropt, "bytes", rbytes);
  return rb_ca_to_type_internal(2, args, self);
}

#define rb_ca_to_type_method_body(code) \
{ \
  VALUE rcode = INT2NUM(code); \
  return rb_ca_to_type_internal(1, &rcode, self); \
}

/* CArray#fixlen(bytes:) -- short-hand of to_type(:fixlen, bytes:). */

VALUE
rb_ca_to_fixlen (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE list[2];
  list[0] = INT2NUM(CA_FIXLEN);
  list[1] = ropt;
  return rb_ca_to_type_internal(2, list, self);
}

/* CArray#boolean -- short-hand of to_type(:boolean). */
VALUE rb_ca_to_boolean (VALUE self)
{
  rb_ca_to_type_method_body(CA_BOOLEAN);
}

/* CArray#int8 -- short-hand of to_type(:int8). */
VALUE rb_ca_to_int8 (VALUE self)
{
  rb_ca_to_type_method_body(CA_INT8);
}

/* CArray#uint8 -- short-hand of to_type(:uint8). */
VALUE rb_ca_to_uint8 (VALUE self)
{
  rb_ca_to_type_method_body(CA_UINT8);
}

/* CArray#int16 -- short-hand of to_type(:int16). */
VALUE rb_ca_to_int16 (VALUE self)
{
  rb_ca_to_type_method_body(CA_INT16);
}

/* CArray#uint16 -- short-hand of to_type(:uint16). */
VALUE rb_ca_to_uint16 (VALUE self)
{
  rb_ca_to_type_method_body(CA_UINT16);
}

/* CArray#int32 -- short-hand of to_type(:int32). */
VALUE rb_ca_to_int32 (VALUE self)
{
  rb_ca_to_type_method_body(CA_INT32);
}

/* CArray#uint32 -- short-hand of to_type(:uint32). */
VALUE rb_ca_to_uint32 (VALUE self)
{
  rb_ca_to_type_method_body(CA_UINT32);
}

/* CArray#int64 -- short-hand of to_type(:int64). */
VALUE rb_ca_to_int64 (VALUE self)
{
  rb_ca_to_type_method_body(CA_INT64);
}

/* CArray#uint64 -- short-hand of to_type(:uint64). */
VALUE rb_ca_to_uint64 (VALUE self)
{
  rb_ca_to_type_method_body(CA_UINT64);
}

/* CArray#float32 -- short-hand of to_type(:float32). */
VALUE rb_ca_to_float32 (VALUE self)
{
  rb_ca_to_type_method_body(CA_FLOAT32);
}

/* CArray#float64 -- short-hand of to_type(:float64). */
VALUE rb_ca_to_float64 (VALUE self)
{
  rb_ca_to_type_method_body(CA_FLOAT64);
}

/* CArray#cmplx64 -- short-hand of to_type(:cmplx64). */
VALUE rb_ca_to_cmplx64 (VALUE self)
{
  rb_ca_to_type_method_body(CA_CMPLX64);
}

/* CArray#cmplx128 -- short-hand of to_type(:cmplx128). */
VALUE rb_ca_to_cmplx128 (VALUE self)
{
  rb_ca_to_type_method_body(CA_CMPLX128);
}

/* CArray#object -- short-hand of to_type(:object). */
VALUE rb_ca_to_VALUE (VALUE self)
{
  rb_ca_to_type_method_body(CA_OBJECT);
}

/* ------------------------------------------------------------------------*/

/* CArray#as_type */

/* Forward declaration: CAMonOp builder (ext/ca_obj_monop.c).  */
extern VALUE rb_ca_monop_build (VALUE cary, uint16_t op_id);

/* Forward declaration: clip kernel (ext/carray_kernels.c, generated).  */
extern VALUE rb_ca_clip (VALUE self, VALUE lo, VALUE hi);

/* Which surface asked for a type-adapt view.  A Face's cells do not mean
   their storage bytes and there is no view that decodes them, so each
   caller says what it does instead of reinterpreting the storage.  */
enum {
  CA_ADAPT_VIEW,        /* as_type: the values are behind #to_type */
  CA_ADAPT_READONLY,    /* wrap_readonly: the eager conversion is the answer */
  CA_ADAPT_WRITABLE     /* wrap_writable: writes have nowhere to land */
};

/* Routes a type-adapt view request to CAMonOp(cast_<dt>) when the
   target is a plain numeric data_type (NOT CA_FIXLEN, NOT CA_OBJECT,
   and `rtype` is not a Class).  Falls back to CAFake
   (`rb_ca_fake_type`) for CA_FIXLEN sizing, CA_OBJECT, and class-rtype
   data_class overlay cases.
   Called by rb_ca_as_type_internal, rb_ca_wrap_readonly, and
   rb_ca_wrap_writable in this file.

   A Face whose surface is not its storage reaches neither: reinterpreting
   the storage would hand back the bytes the surface exists to hide (the
   serial instead of the time, the descriptor instead of the string).
   wrap_readonly, which already returns entities for its non-CArray inputs,
   answers with the eager conversion #to_type performs -- the surface values,
   or the Face's own #to_numeric for a numeric target.  as_type and
   wrap_writable have no honest answer and say so.  */
static VALUE
ca_type_adapt_view (VALUE obj, VALUE rtype, int8_t data_type, int mode)
{
  CArray *ca;

  TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);

  /* Same split the eager cast makes: :object is the Face's surface for every
     Face, and a NonNumeric Face (CA_FIXLEN surface) has no reading of its
     storage as a number either.  A Numeric Face falls through, because there
     its surface *is* its storage and the ordinary cast below is right.  */
  if ( ca_is_face(ca) && ( data_type == CA_OBJECT
                           || ca->data_type == CA_FIXLEN ) ) {
    VALUE args[1];
    switch ( mode ) {
    case CA_ADAPT_READONLY:
      args[0] = rtype;
      return rb_ca_to_type_internal(1, args, obj);
    case CA_ADAPT_WRITABLE:
      rb_raise(rb_eTypeError,
               "%s has no writable view in another data_type: the writes "
               "would land on the storage its surface hides -- wrap "
               "#parent to reach that storage",
               rb_obj_classname(obj));
    default:
      rb_raise(rb_eTypeError,
               "%s has no view of its values in another data_type: "
               "#to_type gives the values, #parent the raw storage",
               rb_obj_classname(obj));
    }
  }

  if ( data_type != CA_FIXLEN
       && data_type != CA_OBJECT
       && TYPE(rtype) != T_CLASS ) {
    uint16_t cast_op_id = (uint16_t)(CA_MONOP_CAST_BASE + data_type);
    return rb_ca_monop_build(obj, cast_op_id);
  }
  return rb_ca_fake_type(obj, rtype, Qnil);
}

static VALUE
rb_ca_as_type_internal (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rtype = Qnil, ropt, rbytes = Qnil;
  CArray *ca;
  int8_t data_type;
  ca_size_t bytes;

  rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ca->data_type == data_type ) {
    if ( ! ca_is_fixlen_type(ca) ) {
      return self;
    }
  }

  /* Natural-width cast: dispatch via helper (CAMonOp for numeric,
     CAFake for CA_FIXLEN sizing / CA_OBJECT / class-rtype). */
  if ( bytes == (ca_size_t) ca_sizeof[data_type] ) {
    obj = ca_type_adapt_view(self, rtype, data_type, CA_ADAPT_VIEW);
    return obj;
  }

  /* Byte-reinterpret variant (bytes != natural for non-FIXLEN, or
     explicit fixlen sizing): CAFake. */
  obj = rb_ca_fake_type(self, rtype, rbytes);

  return obj;
}

/* CArray#as_type(data_type, bytes:) -- CAFake view of self reinterpreted
   as data_type (no copy; reads/writes cast on the fly through the shared
   parent storage).  User doc lives in yard-stubs/carray_cast.rb. */

VALUE
rb_ca_as_type (VALUE self, VALUE rtype, VALUE rbytes)
{
  volatile VALUE ropt = rb_hash_new();
  VALUE args[2] = { rtype, ropt };
  rb_set_options(ropt, "bytes", rbytes);
  return rb_ca_as_type_internal(2, args, self);
}

#define rb_ca_as_type_method_body(code) \
{ \
  VALUE rcode = INT2NUM(code); \
  return rb_ca_as_type_internal(1, &rcode, self); \
}

/* CArray#as_fixlen(bytes:) -- short-hand of as_type(:fixlen, bytes:). */
VALUE
rb_ca_as_fixlen (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rtype, ropt = rb_pop_options(&argc, &argv);
  VALUE list[2];
  rb_scan_args(argc, argv, "01", (VALUE *)  &rtype);
  list[0] = ( NIL_P(rtype) ) ? INT2NUM(CA_FIXLEN) : rtype;
  list[1] = ropt;
  return rb_ca_as_type_internal(2, list, self);
}

/* CArray#as_boolean -- short-hand of as_type(:boolean). */
VALUE rb_ca_as_boolean (VALUE self)
{
  rb_ca_as_type_method_body(CA_BOOLEAN);
}

/* CArray#as_int8 -- short-hand of as_type(:int8). */
VALUE rb_ca_as_int8 (VALUE self)
{
  rb_ca_as_type_method_body(CA_INT8);
}

/* CArray#as_uint8 -- short-hand of as_type(:uint8). */
VALUE rb_ca_as_uint8 (VALUE self)
{
  rb_ca_as_type_method_body(CA_UINT8);
}

/* CArray#as_int16 -- short-hand of as_type(:int16). */
VALUE rb_ca_as_int16 (VALUE self)
{
  rb_ca_as_type_method_body(CA_INT16);
}

/* CArray#as_uint16 -- short-hand of as_type(:uint16). */
VALUE rb_ca_as_uint16 (VALUE self)
{
  rb_ca_as_type_method_body(CA_UINT16);
}

/* CArray#as_int32 -- short-hand of as_type(:int32). */
VALUE rb_ca_as_int32 (VALUE self)
{
  rb_ca_as_type_method_body(CA_INT32);
}

/* CArray#as_uint32 -- short-hand of as_type(:uint32). */
VALUE rb_ca_as_uint32 (VALUE self)
{
  rb_ca_as_type_method_body(CA_UINT32);
}

/* CArray#as_int64 -- short-hand of as_type(:int64). */
VALUE rb_ca_as_int64 (VALUE self)
{
  rb_ca_as_type_method_body(CA_INT64);
}

/* CArray#as_uint64 -- short-hand of as_type(:uint64). */
VALUE rb_ca_as_uint64 (VALUE self)
{
  rb_ca_as_type_method_body(CA_UINT64);
}

/* CArray#as_float32 -- short-hand of as_type(:float32). */
VALUE rb_ca_as_float32 (VALUE self)
{
  rb_ca_as_type_method_body(CA_FLOAT32);
}

/* CArray#as_float64 -- short-hand of as_type(:float64). */
VALUE rb_ca_as_float64 (VALUE self)
{
  rb_ca_as_type_method_body(CA_FLOAT64);
}

/* CArray#as_float128 -- short-hand of as_type(:float128). */
VALUE rb_ca_as_float128 (VALUE self)
{
  rb_ca_as_type_method_body(CA_FLOAT128);
}

/* CArray#as_cmplx64 -- short-hand of as_type(:cmplx64). */
VALUE rb_ca_as_cmplx64 (VALUE self)
{
  rb_ca_as_type_method_body(CA_CMPLX64);
}

/* CArray#as_cmplx128 -- short-hand of as_type(:cmplx128). */
VALUE rb_ca_as_cmplx128 (VALUE self)
{
  rb_ca_as_type_method_body(CA_CMPLX128);
}

/* CArray#as_cmplx256 -- short-hand of as_type(:cmplx256). */
VALUE rb_ca_as_cmplx256 (VALUE self)
{
  rb_ca_as_type_method_body(CA_CMPLX256);
}

/* CArray#as_object -- short-hand of as_type(:object). */
VALUE rb_ca_as_VALUE (VALUE self)
{
  rb_ca_as_type_method_body(CA_OBJECT);
}

/* ------------------------------------------------------------------------*/

VALUE
rb_ca_cast_block (ca_size_t n, VALUE ra1, void *ptr1,
                  VALUE ra2, void *ptr2)
{
  CArray *ca1, *ca2;
  TypedData_Get_Struct(ra1, CArray, &carray_data_type, ca1);
  TypedData_Get_Struct(ra2, CArray, &carray_data_type, ca2);
  if ( n < 0 ) {
    rb_raise(rb_eRuntimeError, "[BUG] in rb_ca_cast_block: negative count");
  }
  ca_cast_func_table[ca1->data_type][ca2->data_type](n, ca1, ptr1, ca2, ptr2, NULL);
  return Qnil;
}

VALUE
rb_ca_ptr2ptr (VALUE ra1, void *ptr1, VALUE ra2, void *ptr2)
{
  CArray *ca1, *ca2;
  TypedData_Get_Struct(ra1, CArray, &carray_data_type, ca1);
  TypedData_Get_Struct(ra2, CArray, &carray_data_type, ca2);
  ca_cast_func_table[ca1->data_type][ca2->data_type](1, ca1, ptr1, ca2, ptr2, NULL);
  return Qnil;
}


VALUE
rb_ca_ptr2obj (VALUE self, void *ptr)
{
  volatile VALUE obj;
  static CArray dummy;
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  dummy.data_type = CA_OBJECT;
  ca_cast_func_table[ca->data_type][CA_OBJECT](1, ca, ptr, &dummy, (void*)&obj, NULL);
  if ( ca_is_fixlen_type(ca) ) {
    return rb_ca_data_class_decode(self, obj);
  }
  else {
    return obj;
  }
}

/* Surface -> storage-domain conversion for a Face store (mirror of the
   storage_to_element read hook).  Non-Face `ca` returns `obj` unchanged, so
   the non-Face store path is untouched.  For a Face, the per-obj_type C
   table is consulted first (fast path); if none is registered, the Ruby
   `element_to_storage` method is called when defined.  A Face that recognizes
   `obj` returns a storage-domain value (e.g. an Integer in its unit); a bare
   Integer / String falls through unchanged to the storage cast. */
VALUE
ca_face_element_to_storage (VALUE self, CArray *ca, VALUE obj)
{
  ca_face_element_to_storage_fn fn;
  if ( ! ca_face_safe_check(ca) || obj == CA_UNDEF ) {
    return obj;
  }
  fn = ca_face_element_to_storage_table[ca->obj_type];
  if ( fn != NULL ) {
    return fn(self, obj);
  }
  else {
    static ID id_element_to_storage = 0;
    if ( id_element_to_storage == 0 ) {
      id_element_to_storage = rb_intern("element_to_storage");
    }
    if ( rb_respond_to(self, id_element_to_storage) ) {
      return rb_funcall(self, id_element_to_storage, 1, obj);
    }
  }
  return obj;
}

VALUE
rb_ca_obj2ptr (VALUE self, VALUE obj, void *ptr)
{
  static CArray dummy;
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( obj == CA_UNDEF ) {
    memset(ptr, 0, ca->bytes);
  }
  else {
    /* Face surfaces as FIXLEN but its storage is the parent chain
       bottom (e.g. int64); the obj -> bytes conversion must use the
       storage data_type, not the Face surface. */
    int8_t convert_type = ca->data_type;
    if ( ca_face_safe_check(ca) ) {
      /* Face write hook: turn a surface value object (Scalar / Time /
         DateTime) into a storage-domain value the cast below consumes. */
      obj = ca_face_element_to_storage(self, ca, obj);
      convert_type = ca_storage_type_of(ca);
    }
    if ( convert_type == CA_FIXLEN ) {
      obj = rb_ca_data_class_encode(self, obj);
    }
    dummy.data_type = CA_OBJECT;
    ca_cast_func_table[CA_OBJECT][convert_type](1, &dummy, &obj, ca, ptr, NULL);
  }
  return Qnil;
}

VALUE
rb_ca_wrap_writable (VALUE arg, VALUE rtype)
{
  volatile VALUE obj = arg;
  CArray *ca = NULL;
  int8_t data_type;

  if ( rb_obj_is_carray(obj) ) {                    /* obj == carray */
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    if ( ca_is_readonly(ca) ) {
      rb_raise(rb_eRuntimeError, "can not modify read-only array");
    }
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = ca_type_adapt_view(obj, rtype, data_type, CA_ADAPT_WRITABLE);
    }
  }
  else if ( NIL_P(obj) ) {                          /* obj == nil */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    obj = rb_cscalar_new(data_type, 0, NULL);
  }
  else if ( rb_respond_to(obj, rb_intern("to_ca")) ) { /* respond_to obj.to_ca */
    /* `writable: true` is the caller's half of the bargain: it says the
       result has to be one whose writes reach `obj`, and a to_ca that can
       only produce a copy raises rather than swallowing them.  An object
       whose to_ca predates the keyword raises ArgumentError here, which is
       the honest report that it does not implement writable intake. */
    volatile VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(rb_intern("writable")), Qtrue);
    obj = rb_funcallv_kw(obj, rb_intern("to_ca"), 1, (VALUE *) &kw,
                         RB_PASS_KEYWORDS);
    if ( ! rb_obj_is_carray(obj) ) {
      volatile VALUE inspect = rb_inspect(CLASS_OF(arg));
      rb_raise(rb_eTypeError,
               "%s#to_ca did not return a CArray", StringValuePtr(inspect));
    }
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    if ( ca_is_readonly(ca) ) {
      rb_raise(rb_eRuntimeError, "can not modify read-only array");
    }
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = ca_type_adapt_view(obj, INT2NUM(data_type), data_type,
                               CA_ADAPT_WRITABLE);
    }
  }
  else if ( rb_memory_view_available_p(obj) ) {     /* MemoryView producer */
    obj = rb_funcall(rb_cCArray, rb_intern("wrap_memory_view"), 1, obj);
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    if ( ca_is_readonly(ca) ) {
      rb_raise(rb_eRuntimeError,
               "MemoryView source is read-only; can't wrap as writable");
    }
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = ca_type_adapt_view(obj, INT2NUM(data_type), data_type,
                               CA_ADAPT_WRITABLE);
    }
  }
  else {
    volatile VALUE inspect = rb_inspect(CLASS_OF(obj));
    rb_raise(rb_eRuntimeError,
             "given object '%s' can't be wrapped as carray",
             StringValuePtr(inspect));
  }

  return obj;
}

/* CArray.wrap_writable(other, data_type = nil) -- singleton entry that
   scans (other, data_type) and delegates to rb_ca_wrap_writable.
   User doc lives in yard-stubs/carray_cast.rb. */

static VALUE
rb_ca_s_wrap_writable (int argc, VALUE *argv, VALUE klass)
{
  volatile VALUE obj, rtype;
  rb_scan_args(argc, argv, "11", (VALUE *) &obj, (VALUE *) &rtype);
  return rb_ca_wrap_writable(obj, rtype);
}

VALUE
rb_ca_wrap_readonly (VALUE arg, VALUE rtype)
{
  volatile VALUE obj = arg;
  CArray *ca = NULL;
  int8_t data_type;

  if ( rb_obj_is_carray(obj) ) {                     /* carray */
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = ca_type_adapt_view(obj, rtype, data_type, CA_ADAPT_READONLY);
    }
  }
  else if ( rb_obj_is_kind_of(obj, rb_cNumeric) ) {  /* number */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    obj = rb_cscalar_new_with_value(data_type, 0, obj);
  }
  else if ( TYPE(obj) == T_ARRAY ) {                 /* array */
    obj = rb_funcall(obj, rb_intern("to_ca"), 0);
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = ca_type_adapt_view(obj, INT2NUM(data_type), data_type,
                               CA_ADAPT_READONLY);
    }
  }
  else if ( TYPE(obj) == T_STRING ) {                /* string */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( data_type == CA_OBJECT ) {
      obj = rb_cscalar_new_with_value(data_type, 0, obj);
    }
    else {
      CArray *ca_tmp;
      volatile VALUE ref = obj;
      ca_size_t dim = RSTRING_LEN(ref)/ca_sizeof[data_type];
      obj = rb_carray_new(data_type, 1, &dim, 0, NULL);
      TypedData_Get_Struct(obj, CArray, &carray_data_type, ca_tmp);
      memcpy(ca_tmp->ptr, RSTRING_PTR(ref), dim * ca_sizeof[data_type]);
    }
  }
  else if ( NIL_P(obj) ) {                            /* nil */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    obj = rb_cscalar_new(data_type, 0, NULL);
  }
  else if ( rb_respond_to(obj, rb_intern("to_ca")) ) {
    obj = rb_funcall(obj, rb_intern("to_ca"), 0);
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = ca_type_adapt_view(obj, INT2NUM(data_type), data_type,
                               CA_ADAPT_READONLY);
    }
  }
  else if ( rb_memory_view_available_p(obj) ) {     /* MemoryView producer */
    obj = rb_funcall(rb_cCArray, rb_intern("wrap_memory_view"), 1, obj);
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = ca_type_adapt_view(obj, INT2NUM(data_type), data_type,
                               CA_ADAPT_READONLY);
    }
  }
  else {                                           /* object */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    obj = rb_cscalar_new_with_value(data_type, 0, obj);
  }

  return obj;
}

/* CArray.wrap_readonly(other, data_type = nil) -- singleton entry that
   scans (other, data_type) and delegates to rb_ca_wrap_readonly.
   User doc lives in yard-stubs/carray_cast.rb. */

static VALUE
rb_ca_s_wrap_readonly (int argc, VALUE *argv, VALUE klass)
{
  volatile VALUE obj, rtype;
  rb_scan_args(argc, argv, "11", (VALUE *) &obj, (VALUE *) &rtype);
  return rb_ca_wrap_readonly(obj, rtype);
}

VALUE
rb_ca_cast (volatile VALUE self)
{
  volatile VALUE obj = self;
  if ( ! rb_obj_is_carray(obj) ) {
    switch ( TYPE(obj) ) {
    case T_FIXNUM:
    case T_BIGNUM:
      obj = rb_cscalar_new_with_value(CA_INT64, 0, obj);
      break;
    case T_FLOAT:
      obj = rb_cscalar_new_with_value(CA_FLOAT64, 0, obj);
      break;
    case T_TRUE:
    case T_FALSE:
      obj = rb_cscalar_new_with_value(CA_BOOLEAN, 0, obj);
      break;
    case T_ARRAY:
      obj = rb_funcall(obj, rb_intern("to_ca"), 0);
      break;
    default:
      if ( rb_obj_is_kind_of(obj, rb_cRange) ) {
        obj = rb_funcall(obj, rb_intern("to_ca"), 0);
        break;
      }
#ifdef HAVE_COMPLEX_H
      if ( RB_TYPE_P(obj, T_COMPLEX) ) {
        obj = rb_cscalar_new_with_value(CA_CMPLX128, 0, obj);
        break;
      }
#endif
      obj = rb_cscalar_new_with_value(CA_OBJECT, 0, obj);
      break;
    }
  }
  return obj;
}

/* A String operand against a fixlen array is a value of that array's cell
   width.  ca_value_to_data_type answers CA_OBJECT for a String, so without
   this the operand became an object scalar and the comparison ran down the
   object lane -- an rb_funcall of String#== per cell, against the cell's
   NUL-padded text.  A fixlen array pads a short String on write
   (`a[i] = "be"` stores "be\0\0\0"), so that answered that an array does
   not equal the string it was written from, and did it 30x slower than the
   memcmp lane the fixlen comparison bodies are there to provide.

   Two fixlen *arrays* of different widths keep the variable-width byte
   string semantics those bodies implement (min-width memcmp with a length
   tiebreak); this is only about a scalar standing in for a cell. */
static int
ca_fixlen_scalar_operand (volatile VALUE *scalar, VALUE reference)
{
  CArray *cr;
  /* A String is the only operand that means a cell value here.  A Regexp
     (match) or any other object keeps its own coercion: those are asking
     something about the bytes, not standing in for them. */
  if ( ! RB_TYPE_P(*scalar, T_STRING) || ! rb_obj_is_carray(reference) ) {
    return 0;
  }
  TypedData_Get_Struct(reference, CArray, &carray_data_type, cr);
  if ( cr->data_type != CA_FIXLEN ) {
    return 0;
  }
  *scalar = rb_cscalar_new_with_value(CA_FIXLEN, cr->bytes, *scalar);
  return 1;
}

/* Where a Ruby Integer falls against the range of integer data type `dt`:
   -1 below it, 1 above it, 0 inside.  Anything but an Integer, and a
   non-integer `dt`, answer 0. */
int
ca_integer_range_side (VALUE v, int8_t dt)
{
  VALUE lo, hi;
  if ( ! RB_INTEGER_TYPE_P(v) ) return 0;
  switch ( dt ) {
  case CA_INT8:   lo = INT2FIX(INT8_MIN);   hi = INT2FIX(INT8_MAX);    break;
  case CA_UINT8:  lo = INT2FIX(0);          hi = INT2FIX(UINT8_MAX);   break;
  case CA_INT16:  lo = INT2FIX(INT16_MIN);  hi = INT2FIX(INT16_MAX);   break;
  case CA_UINT16: lo = INT2FIX(0);          hi = INT2FIX(UINT16_MAX);  break;
  case CA_INT32:  lo = LL2NUM(INT32_MIN);   hi = LL2NUM(INT32_MAX);    break;
  case CA_UINT32: lo = INT2FIX(0);          hi = ULL2NUM(UINT32_MAX);  break;
  case CA_INT64:  lo = LL2NUM(INT64_MIN);   hi = LL2NUM(INT64_MAX);    break;
  case CA_UINT64: lo = INT2FIX(0);          hi = ULL2NUM(UINT64_MAX);  break;
  default: return 0;
  }
  if ( RTEST(rb_funcall(v, rb_intern("<"), 1, lo)) ) return -1;
  if ( RTEST(rb_funcall(v, rb_intern(">"), 1, hi)) ) return 1;
  return 0;
}

/* Refuses a Ruby Integer that does not fit integer data type `dt`.  Taken
   modulo the type, 256 against a uint8 array would be 0 and compare equal
   to it. */
void
ca_check_integer_fits (VALUE v, int8_t dt)
{
  if ( ca_integer_range_side(v, dt) != 0 ) {
    rb_raise(rb_eRangeError, "%"PRIsVALUE" is out of range for %s",
             rb_inspect(v), ca_type_name[dt]);
  }
}

/* A Ruby Integer operand against an integer array is taken in the array's
   own data type, refused when it does not fit (ca_check_integer_fits).
   Widening instead would make the result's type depend on a scalar's
   value.  A Float, a Face and an object array keep the coercion below. */
static int
ca_integer_scalar_operand (volatile VALUE *scalar, VALUE reference)
{
  CArray *cr;
  if ( ! RB_INTEGER_TYPE_P(*scalar) || ! rb_obj_is_carray(reference) ) {
    return 0;
  }
  TypedData_Get_Struct(reference, CArray, &carray_data_type, cr);
  if ( ! ca_is_integer_type(cr) || ca_is_face(cr) ) {
    return 0;
  }
  ca_check_integer_fits(*scalar, cr->data_type);
  *scalar = rb_cscalar_new_with_value(cr->data_type, 0, *scalar);
  return 1;
}

/* CArray.cast(value) -- singleton entry delegating to rb_ca_cast, which
   returns a CArray unchanged and coerces a Ruby value to a CScalar / CArray.
   User doc lives in yard-stubs/carray_cast.rb. */

static VALUE
rb_ca_s_cast (VALUE klass, VALUE val)
{
  return rb_ca_cast(val);
}

/* An operator operand that exports MemoryView, as a CArray.  When the object
   also defines to_ca, that is asked first, in the order wrap_readonly uses:
   the MemoryView carries only the values buffer, while to_ca can hand over
   what the object knows besides it (the nulls of an Arrow array as a mask,
   a time type as a Face).  Only MemoryView producers come here, so an object
   with to_ca alone (a Range) is still not an operand. */
static VALUE
ca_operand_from_memory_view (VALUE obj)
{
  volatile VALUE ca;
  if ( rb_respond_to(obj, rb_intern("to_ca")) ) {
    ca = rb_funcall(obj, rb_intern("to_ca"), 0);
    if ( ! rb_obj_is_carray(ca) ) {
      volatile VALUE inspect = rb_inspect(CLASS_OF(obj));
      rb_raise(rb_eTypeError,
               "%s#to_ca did not return a CArray", StringValuePtr(inspect));
    }
    return ca;
  }
  return rb_funcall(rb_cCArray, rb_intern("wrap_memory_view"), 1, obj);
}

void
rb_ca_cast_self_or_other (volatile VALUE *self, volatile VALUE *other)
{
  CArray *ca, *cb;
  int test;
  int self_is_object = 0;
  int other_is_object = 0;

  /* Promote MemoryView-aware operands to CArray (CAWrap or CAStride).
     Excludes T_STRING which has its own legacy interpretation. */
  if ( ! rb_obj_is_carray(*self) && TYPE(*self) != T_STRING &&
       rb_memory_view_available_p(*self) ) {
    *self = ca_operand_from_memory_view(*self);
  }
  if ( ! rb_obj_is_carray(*other) && TYPE(*other) != T_STRING &&
       rb_memory_view_available_p(*other) ) {
    *other = ca_operand_from_memory_view(*other);
  }

  if ( ! rb_obj_is_carray(*self) ) {
    self_is_object = 1;
    if ( rb_ca_is_object_type(*other) ) {
      *self = rb_cscalar_new_with_value(CA_OBJECT, 0, *self);
    }
#ifdef HAVE_COMPLEX_H
    /* A Complex scalar with a non-object non-complex CArray on the other
       side must wrap as CA_CMPLX128; falling into the float branch below
       would NUM2DBL(Complex) and raise.  Downstream promotion lifts the
       other operand to cmplx128. */
    else if ( RB_TYPE_P(*self, T_COMPLEX) ) {
      *self = rb_cscalar_new_with_value(CA_CMPLX128, 0, *self);
    }
#endif
    else if ( ca_fixlen_scalar_operand(self, *other) ) {
      /* width taken from the fixlen reference; see the helper above */
    }
    else if ( ca_integer_scalar_operand(self, *other) ) {
      /* the array's own integer type; see the helper above */
    }
    else if ( rb_ca_is_float_type(*other) ) {
      *self = rb_cscalar_new_with_value(CA_FLOAT64, 0, *self);
    }
#ifdef HAVE_COMPLEX_H
    else if ( rb_ca_is_complex_type(*other) ) {
      *self = rb_cscalar_new_with_value(CA_CMPLX128, 0, *self);
    }
#endif
    else {
      *self = rb_cscalar_new_with_value(ca_value_to_data_type(*self), 0, *self);
    }
  }

  if ( ! rb_obj_is_carray(*other) ) {
    other_is_object = 1;

    if ( rb_ca_is_object_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_OBJECT, 0, *other);
    }
#ifdef HAVE_COMPLEX_H
    /* Symmetric to the self-branch above: Complex scalar wraps as
       cmplx128 regardless of the CArray operand's numeric width, so
       float64_array + Complex(0, 1) promotes rather than raising in
       NUM2DBL(Complex). */
    else if ( RB_TYPE_P(*other, T_COMPLEX) ) {
      *other = rb_cscalar_new_with_value(CA_CMPLX128, 0, *other);
    }
#endif
    else if ( ca_fixlen_scalar_operand(other, *self) ) {
      /* width taken from the fixlen reference; see the helper above */
    }
    else if ( ca_integer_scalar_operand(other, *self) ) {
      /* the array's own integer type; see the helper above */
    }
    else if ( rb_ca_is_float_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_FLOAT64, 0, *other);
    }
#ifdef HAVE_COMPLEX_H
    else if ( rb_ca_is_complex_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_CMPLX128, 0, *other);
    }
#endif
    else {
      *other = rb_cscalar_new_with_value(ca_value_to_data_type(*other), 0, *other);
    }
  }

  TypedData_Get_Struct(*self, CArray, &carray_data_type, ca);
  TypedData_Get_Struct(*other, CArray, &carray_data_type, cb);

  /* Implicit size-1 broadcasting (case A only).  No-op if either side
     is scalar, ndim differs, or shapes are already equal.  If shapes
     are incompatible (neither side is 1 nor equal on some axis), also
     no-op — the downstream element-count check in ca_set_iterator
     raises with the existing message. */
  ca_broadcast_pair(self, other);
  TypedData_Get_Struct(*self,  CArray, &carray_data_type, ca);
  TypedData_Get_Struct(*other, CArray, &carray_data_type, cb);

  if ( ca_is_scalar(ca) ^ ca_is_scalar(cb) ||
       self_is_object ||
       other_is_object ) {
    if ( other_is_object || 
         ( ( ! other_is_object ) && ca_is_scalar(cb) ) ) {
      test = ca_cast_table2[cb->data_type][ca->data_type];
      if ( test == 0 ) {
        return;
      }
      else if ( test > 0 ) {
        *other = rb_ca_wrap_readonly(*other, INT2NUM(ca->data_type));
        return;
      }
    }
    if ( self_is_object || 
         ( ( ! self_is_object ) && ca_is_scalar(ca) ) ) {
      test = ca_cast_table2[ca->data_type][cb->data_type];
      if ( test == 0 ) {
        return;
      }
      else if ( test > 0 ) {
        *self = rb_ca_wrap_readonly(*self, INT2NUM(cb->data_type));
        return;
      }
    }
  }
    
  test = ca_cast_table[cb->data_type][ca->data_type];

  if ( test == 0 ) {
    return;
  }
  else if ( test > 0 ) {
    *other = rb_ca_wrap_readonly(*other, INT2NUM(ca->data_type));
    return;
  }

  test = ca_cast_table[ca->data_type][cb->data_type];

  if ( test > 0 ) {
    *self = rb_ca_wrap_readonly(*self, INT2NUM(cb->data_type));
    return;
  }

  rb_raise(rb_eRuntimeError,
           "can't coerce carray with data_types of '%s' and '%s'",
           ca_type_name[ca->data_type],
           ca_type_name[cb->data_type]);
}

/* CArray.cast_self_or_other(self, other) — promote self and other
 * to a common data_type and return [self', other'].  Wraps the
 * void rb_ca_cast_self_or_other above into a class method.
 */

VALUE
rb_ca_s_cast_self_or_other (VALUE klass, VALUE self, VALUE other)
{
  rb_ca_cast_self_or_other(&self, &other);
  return rb_assoc_new(self, other);
}

/* Extract a data_type code (0..CA_NTYPE-1) from an argument.
   Dispatch:
   - CArray instance         -> its data_type
   - Symbol / String / Class -> data_type representation (name lookup)
   - other (Integer / Float / Complex / true / false / nil / Object)
                             -> value semantic via ca_value_to_data_type
                                (e.g. an Integer like `3` is interpreted
                                as a value -> :int64, not as a data_type
                                code). */
static int8_t
ca_arg_to_data_type (VALUE obj)
{
  int8_t data_type;
  if ( rb_obj_is_carray(obj) ) {
    CArray *ca;
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    data_type = ca->data_type;
  }
  else if ( TYPE(obj) == T_SYMBOL || TYPE(obj) == T_STRING ||
            TYPE(obj) == T_CLASS ) {
    data_type = rb_ca_guess_type(obj);
  }
  else if ( ( data_type = ca_mv_probe_data_type(obj) ) >= 0 ) {
    /* MemoryView producer -> its format's data_type (T_STRING excluded above,
       so a String never reaches here).  data_type already assigned. */
  }
  else {
    data_type = ca_value_to_data_type(obj);
  }
  CA_CHECK_DATA_TYPE(data_type);
  if ( ! ca_valid[data_type] ) {
    rb_raise(rb_eArgError,
             "data type '%s' is not valid in this build",
             ca_type_name[data_type]);
  }
  return data_type;
}

/* Infer a data_type code from a Ruby *value* (literal Numeric, true/false,
   Complex, etc.).  See declaration in carray.h for the contract.  */
int8_t
ca_value_to_data_type (VALUE obj)
{
  switch ( TYPE(obj) ) {
  case T_FIXNUM:
  case T_BIGNUM: return CA_INT64;
  case T_FLOAT:  return CA_FLOAT64;
  case T_TRUE:
  case T_FALSE:  return CA_BOOLEAN;
  case T_NIL:    return CA_OBJECT;
  default:
#ifdef HAVE_COMPLEX_H
    if ( RB_TYPE_P(obj, T_COMPLEX) ) return CA_CMPLX128;
#endif
    return CA_OBJECT;
  }
}

/* Promote two data_type codes according to ca_cast_table.
   Returns the higher (= the type both can be cast to without loss
   under the table's policy).  Raises if incompatible.

   Externally callable so the lazy view layer (CABinOp constructor)
   can compute its output_data_type using the same single-source
   promotion rule as the eager binop path. */
int8_t
ca_promote_type (int8_t a, int8_t b)
{
  int test;
  if ( a == b ) {
    return a;
  }
  test = ca_cast_table[a][b];
  if ( test == 0 ) {
    return b;
  }
  else if ( test > 0 ) {
    /* a should be cast to b */
    return b;
  }
  /* test < 0: try the other direction */
  test = ca_cast_table[b][a];
  if ( test > 0 ) {
    /* b should be cast to a */
    return a;
  }
  rb_raise(rb_eRuntimeError,
           "can't promote data_types '%s' and '%s' to a common type",
           ca_type_name[a], ca_type_name[b]);
}

/* The type in which values of types `a` and `b`, whose common type is `t`,
   are matched for equality.  It is `t`, except for an integer pair of mixed
   sign whose common type is unsigned (uint8 with int8 is uint8, where -1
   would read as 255): there the match moves to a signed type that holds
   every value of both, or, for 64 bits, where no numeric type does, to
   object, whose Integers compare by value.  `eq` answers the same pair by
   value. */
int8_t
ca_value_match_type (int8_t t, int8_t a, int8_t b)
{
  int signed_a = ( a == CA_INT8 || a == CA_INT16 || a == CA_INT32 || a == CA_INT64 );
  int signed_b = ( b == CA_INT8 || b == CA_INT16 || b == CA_INT32 || b == CA_INT64 );
  if ( ! signed_a && ! signed_b ) return t;
  switch ( t ) {
  case CA_UINT8:  return CA_INT16;
  case CA_UINT16: return CA_INT32;
  case CA_UINT32: return CA_INT64;
  case CA_UINT64: return CA_OBJECT;
  default:        return t;
  }
}

/* ca.value_match_type(t, other_type) -- ca_value_match_type with self's
   data type as the first operand, for the set family and locate_addr. */
static VALUE
rb_ca_value_match_type (VALUE self, VALUE vt, VALUE vother)
{
  CArray *ca;
  GetCArray(self, ca);
  return rb_ca_data_type_to_sym(ca_value_match_type(rb_ca_guess_type(vt), ca->data_type,
                                                    rb_ca_guess_type(vother)));
}

/* A result_type argument that is a scalar: a Ruby value (Integer, Float,
   true, ...) or a CScalar.  The operators let a scalar take the type of the
   array beside it, so result_type does too. */
static int
ca_arg_is_scalar (VALUE obj)
{
  if ( rb_obj_is_carray(obj) ) {
    CArray *ca;
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    return ca_is_scalar(ca);
  }
  if ( TYPE(obj) == T_SYMBOL || TYPE(obj) == T_STRING || TYPE(obj) == T_CLASS ) {
    return 0;
  }
  return ca_mv_probe_data_type(obj) < 0;
}

/* The type a scalar `obj` (of type `st`) and an array of type `at` share,
   by the rule the operators apply: a scalar of the same kind takes the
   array's type (0.1 beside float32 is float32, 1 beside int8 is int8); one
   of another kind promotes (1.5 beside int32 is float64).  An Integer that
   does not fit the array's integer type takes the type of its value, where
   an operator would raise RangeError. */
int8_t
ca_promote_scalar_type (int8_t at, VALUE obj, int8_t st)
{
  if ( RB_INTEGER_TYPE_P(obj) && at >= CA_INT8 && at <= CA_UINT64 ) {
    return ( ca_integer_range_side(obj, at) == 0 ) ? at : ca_promote_type(at, st);
  }
  if ( ca_cast_table2[st][at] >= 0 ) {
    return at;
  }
  return ca_promote_type(at, st);
}

/* CArray.result_type(*args) -- common data_type of the operands, by the rule
   the operators use.  Each arg is classified by ca_arg_to_data_type: a
   CArray / Symbol / String / Class gives a data_type representation, a
   Numeric / bool / nil / Object gives a value whose data_type is inferred.
   The non-scalar arguments fold pairwise via ca_promote_type; a scalar then
   joins that type through ca_promote_scalar_type.  With no non-scalar
   argument every argument folds by its own type.  Returns a Symbol.  User
   doc lives in yard-stubs/carray_cast.rb. */

static VALUE
rb_ca_s_result_type (int argc, VALUE *argv, VALUE klass)
{
  int8_t cur = -1;
  int i;

  if ( argc < 1 ) {
    rb_raise(rb_eArgError, "result_type requires at least one argument");
  }

  for ( i = 0; i < argc; i++ ) {
    if ( ! ca_arg_is_scalar(argv[i]) ) {
      int8_t t = ca_arg_to_data_type(argv[i]);
      cur = ( cur < 0 ) ? t : ca_promote_type(cur, t);
    }
  }
  for ( i = 0; i < argc; i++ ) {
    if ( ca_arg_is_scalar(argv[i]) ) {
      int8_t t = ca_arg_to_data_type(argv[i]);
      cur = ( cur < 0 ) ? t : ca_promote_scalar_type(cur, argv[i], t);
    }
  }
  /* Return Symbol for family consistency with
     CArray.value_to_data_type and ca.data_type. */
  return rb_ca_data_type_to_sym(cur);
}

/* CArray.promote_list(list, data_type: nil) -- reconcile an Array of
   CArray instances into a uniformly-handleable representation (same Face
   class, or same primitive data_type) suitable for multi-parent
   constructors like CArray.stack.  User doc lives in
   yard-stubs/carray_cast.rb; the dispatch branches are:

Auto-detect (data_type: nil):
  - All elements Face (= ca_is_face) and same Face class:
    - Reject if the class is not portable (= CAConstString)
    - Reject on pairwise state mismatch (= CATime with different units)
    - Otherwise pass through (= CAStack will lift)
  - All elements primitive: promote via result_type + wrap_readonly
  - Mixed Face + non-Face: reject (= ambiguous; user must strip Face
    manually with .parent if the storage-level layout is intended)
  - Heterogeneous Face classes: reject (= no semantics for mixing Faces)

Explicit data_type (Symbol):
  - All primitive elements: wrap_readonly to the requested type
  - Any Face element: reject (= Face cannot be coerced into a primitive
    without losing identity; the user must strip Face manually)

Explicit data_type (Class / non-Symbol):
  - Reject.  Class-shaped targets (CARecord, Face subclasses, etc.) are
    not valid promotion destinations; use auto-detect or pass a primitive
    Symbol.  Future work may relax this once Face-as-target promotion is
    designed.

Raises ArgumentError on empty list or any of the reject cases above. */
static VALUE
rb_ca_s_promote_list (int argc, VALUE *argv, VALUE klass)
{
  VALUE list, kwargs, data_type = Qnil;
  long n, i;
  int  all_face = 1, any_face = 0, all_primitive = 1;
  VALUE face_class = Qnil;
  CArray *ref_face = NULL;
  int8_t common = -1;

  rb_scan_args(argc, argv, "1:", &list, &kwargs);
  Check_Type(list, T_ARRAY);
  rb_scan_options(kwargs, "data_type", &data_type);

  n = RARRAY_LEN(list);
  if ( n <= 0 ) {
    rb_raise(rb_eArgError, "promote_list: list must not be empty");
  }

  /* Explicit data_type validation: reject Class / non-Symbol targets up
     front so the rest of the function only deals with `nil` or a
     primitive-shaped Symbol/String/Integer. */
  if ( ! NIL_P(data_type) ) {
    if ( RB_TYPE_P(data_type, T_CLASS) || RB_TYPE_P(data_type, T_MODULE) ) {
      rb_raise(rb_eArgError,
               "promote_list: data_type must be a primitive Symbol "
               "(Class targets are not supported; use auto-detect or "
               "strip Face manually)");
    }
  }

  /* Classify each element: Face / primitive CArray.  Detect Face-class
     homogeneity as we go. */
  for ( i = 0; i < n; i++ ) {
    VALUE elem = rb_ary_entry(list, i);
    CArray *ca;
    rb_check_carray_object(elem);
    TypedData_Get_Struct(elem, CArray, &carray_data_type, ca);
    if ( ca_is_face(ca) ) {
      any_face = 1;
      all_primitive = 0;
      if ( NIL_P(face_class) ) {
        face_class = rb_obj_class(elem);
        ref_face   = ca;
      } else if ( rb_obj_class(elem) != face_class ) {
        all_face = 0;   /* will be caught after the loop */
      } else if ( all_face ) {
        if ( ! ca_face_state_compatible(rb_ary_entry(list, 0), ref_face,
                                        elem, ca) ) {
          rb_raise(rb_eArgError,
                   "promote_list: Face state mismatch across elements "
                   "(= %s instance at index %ld differs from index 0)",
                   rb_class2name(face_class), i);
        }
      }
    } else {
      all_face = 0;
    }
  }

  /* Explicit data_type path: primitive Symbol, all elements must be
     primitive.  Reject if any Face in list. */
  if ( ! NIL_P(data_type) ) {
    if ( any_face ) {
      rb_raise(rb_eArgError,
               "promote_list: data_type %s cannot be applied to a list "
               "containing Face elements (= Face cannot be coerced to "
               "a primitive without losing identity)",
               RSTRING_PTR(rb_inspect(data_type)));
    }
    {
      VALUE out = rb_ary_new_capa(n);
      static ID id_wrap_readonly = 0;
      if ( id_wrap_readonly == 0 ) id_wrap_readonly = rb_intern("wrap_readonly");
      for ( i = 0; i < n; i++ ) {
        VALUE coerced = rb_funcall(klass, id_wrap_readonly, 2,
                                   rb_ary_entry(list, i), data_type);
        rb_ary_push(out, coerced);
      }
      return out;
    }
  }

  /* Auto-detect path. */
  if ( any_face && ! all_face ) {
    if ( all_primitive == 0 && any_face ) {
      /* Mixed: at least one Face and at least one non-Face,
         OR mixed Face classes.  Both are rejected. */
      rb_raise(rb_eArgError,
               "promote_list: cannot mix Face and non-Face (or heterogeneous "
               "Face classes); pass a homogeneous Face list, or strip Face "
               "manually with .parent for the storage-level layout");
    }
  }

  if ( all_face ) {
    /* Homogeneous Face: validate portability, then pass through. */
    if ( n > 1 && ! ca_face_state_portable(ref_face->obj_type, face_class) ) {
      rb_raise(rb_eArgError,
               "promote_list: %s state is not portable across multiple "
               "elements (= per-parent storage like CAConstString's buffer); "
               "strip Face manually with .parent for a storage-level list",
               rb_class2name(face_class));
    }
    /* Return a fresh Array so callers can mutate without aliasing. */
    {
      VALUE out = rb_ary_new_capa(n);
      for ( i = 0; i < n; i++ ) rb_ary_push(out, rb_ary_entry(list, i));
      return out;
    }
  }

  /* All primitive: result_type to determine common data_type, then
     wrap_readonly each element. */
  common = ca_arg_to_data_type(rb_ary_entry(list, 0));
  for ( i = 1; i < n; i++ ) {
    int8_t next = ca_arg_to_data_type(rb_ary_entry(list, i));
    common = ca_promote_type(common, next);
  }
  {
    VALUE common_sym = rb_ca_data_type_to_sym(common);
    VALUE out = rb_ary_new_capa(n);
    static ID id_wrap_readonly = 0;
    if ( id_wrap_readonly == 0 ) id_wrap_readonly = rb_intern("wrap_readonly");
    for ( i = 0; i < n; i++ ) {
      VALUE coerced = rb_funcall(klass, id_wrap_readonly, 2,
                                 rb_ary_entry(list, i), common_sym);
      rb_ary_push(out, coerced);
    }
    return out;
  }
}

void
rb_ca_cast_other (VALUE *self, volatile VALUE *other)
{
  CArray *ca, *cb;
  CScalar *cs;
  int test0, test1;

  TypedData_Get_Struct(*self, CArray, &carray_data_type, ca);

  /* Promote MemoryView-aware operand to CArray (CAWrap or CAStride).
     Excludes T_STRING which has its own legacy interpretation. */
  if ( ! rb_obj_is_carray(*other) && TYPE(*other) != T_STRING &&
       rb_memory_view_available_p(*other) ) {
    *other = ca_operand_from_memory_view(*other);
  }

  if ( ! rb_obj_is_carray(*other) ) {
    if ( rb_ca_is_object_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_OBJECT, 0, *other);
    }
    else if ( ca_fixlen_scalar_operand(other, *self) ) {
      return;   /* already the receiver's data_type and width */
    }
    else if ( rb_ca_is_float_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_FLOAT64, 0, *other);
    }
#ifdef HAVE_COMPLEX_H
    else if ( rb_ca_is_complex_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_CMPLX128, 0, *other);
      return;
    }
#endif
    else {
      *other = rb_cscalar_new_with_value(ca_value_to_data_type(*other), 0, *other);
    }

    TypedData_Get_Struct(*other, CScalar, &cscalar_data_type, cs);

    test0 = ca_cast_table2[cs->data_type][ca->data_type];

    if ( test0 > 0 ) {
      *other = rb_ca_wrap_readonly(*other, INT2NUM(ca->data_type));
    }

  }

  TypedData_Get_Struct(*other, CArray, &carray_data_type, cb);

  test1 = ca_cast_table[cb->data_type][ca->data_type];

  if ( test1 == 0 ) {
    return;
  }
  else if ( test1 > 0 ) {
    *other = rb_ca_wrap_readonly(*other, INT2NUM(ca->data_type));
    return;
  }

  rb_raise(rb_eRuntimeError,
           "can't coerce carray with data_types of '%s' and '%s'",
           ca_type_name[ca->data_type],
           ca_type_name[cb->data_type]);
}

/* CArray#cast_with(other) -- coerce self and other to a common
   representation via rb_ca_cast_self_or_other and return them as a
   two-element [self, other] array.  User doc lives in
   yard-stubs/carray_cast.rb. */

VALUE
rb_ca_cast_with (VALUE self, VALUE other)
{
  if ( rb_obj_is_carray(self) ) {
    rb_ca_cast_self_or_other(&self, &other);
  }
  else {
    rb_raise(rb_eRuntimeError, "first argument should be a carray");
  }
  return rb_assoc_new(self, other);
}

/* -----------------------------------------------------------------------
   clip_<type> family — clip into the target data type's representable
   range, then cast.  Sugar for `clip(lo, hi).as_<type>`.
----------------------------------------------------------------------- */

#define CLIP_CAST_FUNC(name, lo_expr, hi_expr, cast_func) \
static VALUE \
rb_ca_##name (VALUE self) \
{ \
  return cast_func(rb_ca_clip(self, lo_expr, hi_expr)); \
}

CLIP_CAST_FUNC(clip_int8,   INT2NUM(-128),                    INT2NUM(127),                    rb_ca_as_int8)
CLIP_CAST_FUNC(clip_int16,  INT2NUM(-32768),                  INT2NUM(32767),                  rb_ca_as_int16)
CLIP_CAST_FUNC(clip_int32,  INT2NUM(-2147483648),             INT2NUM(2147483647),             rb_ca_as_int32)
CLIP_CAST_FUNC(clip_int64,  LL2NUM(-9223372036854775807-1),   LL2NUM(9223372036854775807),     rb_ca_as_int64)
CLIP_CAST_FUNC(clip_uint8,  INT2NUM(0),                       INT2NUM(255),                    rb_ca_as_uint8)
CLIP_CAST_FUNC(clip_uint16, INT2NUM(0),                       INT2NUM(65535),                  rb_ca_as_uint16)
CLIP_CAST_FUNC(clip_uint32, INT2NUM(0),                       UINT2NUM(4294967295U),           rb_ca_as_uint32)

#undef CLIP_CAST_FUNC

/* CArray#clip_uint64 -- dedicated implementation.

   UINT64_MAX (= 2^64-1) is not exactly representable in float64; the nearest
   double rounds up to 2^64.  A generic clip-then-cast path therefore clamps
   an overflowing float source (e.g. 1e20) to 2^64 and the subsequent cast to
   uint64 wraps around to 0.  For floating-point sources we take a saturating
   path: compare in float space against 2^64 (which IS representable) and
   saturate to UINT64_MAX above it and 0 below zero.  Other source data types use
   the plain clip-then-cast path. */
static VALUE
rb_ca_clip_uint64 (VALUE self)
{
  CArray *ca;
  GetCArray(self, ca);
  int dt = ca->data_type;
  if ( dt == CA_FLOAT32 || dt == CA_FLOAT64 ) {
    volatile VALUE vsrc = ( dt == CA_FLOAT64 ) ? self : rb_ca_as_float64(self);
    CArray *src;
    GetCArray(vsrc, src);
    volatile VALUE vout = rb_carray_new(CA_UINT64, ca->ndim, ca->dim, 0, NULL);
    CArray *out;
    GetCArray(vout, out);
    ca_attach(src);   /* window: nothing raises inside */
    double  *sp = (double  *) src->ptr;
    uint64_t *op = (uint64_t *) out->ptr;
    ca_size_t n = ca->elements;
    const double LIMIT = 18446744073709551616.0; /* 2^64, exact in f64 */
    for ( ca_size_t i = 0; i < n; i++ ) {
      double v = sp[i];
      if ( v != v )         op[i] = 0;              /* NaN -> 0 */
      else if ( v >= LIMIT ) op[i] = UINT64_MAX;
      else if ( v <= 0.0 )   op[i] = 0;
      else                   op[i] = (uint64_t) v;
    }
    ca_detach(src);
    if ( ca_has_mask(ca) ) {
      ca_copy_mask(out, ca);
    }
    return vout;
  }
  return rb_ca_as_uint64(rb_ca_clip(self, INT2NUM(0),
                                    ULL2NUM(18446744073709551615ULL)));
}

/* ------------------------------------------------------------------------
   Global cast functions CA_INT32(data) ... CA_OBJECT(data) etc.

   Polymorphic cast (NOT a fresh allocator): `data` is coerced into a CArray
   of the target data_type, dispatching on its Ruby class:

     Array    -> shape-guessed CArray, element-wise store
     CArray   -> copy if same data_type, else #to_type
     nil      -> empty CArray
     Range    -> arange; a second argument, if given, is the step
     Numeric  -> CScalar, or #to_ca when the object answers it
     String   -> the whitespace / `,` / `;` / `_`->UNDEF parser, which reads
                 far more naturally in Ruby and so is the one branch that
                 calls back out to it (CArray.__cast_string__ in
                 carray/basics.rb, eager-loaded).  It receives the data_type
                 as a Symbol.

   A second argument is meaningful only for Range, and a third never is;
   anything else is refused.
   ------------------------------------------------------------------------ */

static ID id_new_cast = 0, id_guess_array_shape_cast = 0, id_cast_string = 0,
          id_to_ca_cast = 0, id_length_cast = 0,
          id_begin_cast = 0, id_end_cast = 0, id_to_a_cast = 0,
          id_exclude_end_p_cast = 0, id_abs_cast = 0, id_floor_cast = 0,
          id_op_minus = 0, id_op_div = 0, id_op_plus = 0,
          id_op_le = 0, id_op_eq = 0, id_op_uminus = 0;

/* Cross-type cast helper: v.to_type(sym) with no bytes (= in-file call to
   the #to_type implementation, no Ruby method dispatch). */
static VALUE
ca_cast_to_type1 (VALUE v, VALUE sym)
{
  VALUE list[1];
  list[0] = sym;
  return rb_ca_to_type_internal(1, list, v);
}

static VALUE
ca_cast_impl (int8_t data_type, int argc, VALUE *argv)
{
  VALUE v = ( argc >= 1 ) ? argv[0] : Qnil;
  VALUE sym = ID2SYM(ca_data_type_sym[data_type]);

  /* Only the Range branch below reads a second argument (the step), and
     nothing reads a third.  The arity is -1 for the step's sake, so the count
     is checked here; without it `CA_INT32(0, 2)`, which looks like the shape
     spelling `CArray.int32(3, 3)`, casts the 0 and drops the 2. */
  if ( argc > 2 ) {
    rb_raise(rb_eArgError,
             "wrong number of arguments (given %d, expected 0..2)", argc);
  }
  if ( argc == 2 && ! RTEST(rb_obj_is_kind_of(v, rb_cRange)) ) {
    rb_raise(rb_eArgError,
             "a step (the second argument) is only accepted "
             "when the first argument is a Range (got %s)",
             rb_obj_classname(v));
  }

  if ( TYPE(v) == T_ARRAY ) {
    volatile VALUE shape, obj;
    shape = rb_funcall(rb_cCArray, id_guess_array_shape_cast, 1, v);
    obj   = rb_funcall(rb_cCArray, id_new_cast, 2, sym, shape);
    rb_ca_store_all(obj, v);
    return obj;
  }
  else if ( RTEST(rb_obj_is_kind_of(v, rb_cCArray)) ) {
    CArray *ca;
    TypedData_Get_Struct(v, CArray, &carray_data_type, ca);
    if ( ca->data_type == data_type ) {
      return rb_ca_copy(v);
    }
    return ca_cast_to_type1(v, sym);
  }
  else if ( NIL_P(v) ) {
    ca_size_t dim0 = 0;
    return rb_carray_new(data_type, 1, &dim0, 0, NULL);
  }
  else if ( RTEST(rb_obj_is_kind_of(v, rb_cRange)) ) {
    /* arange: n = ((end - begin).abs / step).floor + 1, or for an excluded
       end ((end - begin).abs.quo(step)).ceil -- the steps that start before
       the end -- then seq(begin, sign * step.abs). */
    volatile VALUE vbeg, vend, step, n;
    int sign;
    ca_size_t dn;
    VALUE obj, step_abs, signed_step;

    vbeg = rb_funcall(v, id_begin_cast, 0);
    vend = rb_funcall(v, id_end_cast, 0);
    step = ( argc >= 2 ) ? argv[1] : Qnil;
    if ( RTEST(step) && RTEST(rb_funcall(step, id_op_eq, 1, INT2FIX(0))) ) {
      rb_raise(rb_eRuntimeError, "step should not be 0");
    }
    if ( data_type == CA_OBJECT && !RTEST(step) ) {
      VALUE va = rb_funcall(v, id_to_a_cast, 0);   /* CA_OBJECT(v.to_a) */
      return ca_cast_impl(CA_OBJECT, 1, &va);
    }
    if ( !RTEST(step) ) step = INT2FIX(1);
    n = rb_funcall(vend, id_op_minus, 1, vbeg);
    n = rb_funcall(n, id_abs_cast, 0);
    if ( RTEST(rb_funcall(v, id_exclude_end_p_cast, 0)) ) {
      n = rb_funcall(n, rb_intern("quo"), 1, rb_funcall(step, id_abs_cast, 0));
      n = rb_funcall(n, rb_intern("ceil"), 0);
    }
    else {
      n = rb_funcall(n, id_op_div, 1, step);
      n = rb_funcall(n, id_floor_cast, 0);
      n = rb_funcall(n, id_op_plus, 1, INT2FIX(1));
    }
    sign = RTEST(rb_funcall(vbeg, id_op_le, 1, vend)) ? 1 : -1;
    dn  = NUM2SIZE(n);
    obj = rb_carray_new(data_type, 1, &dn, 0, NULL);
    step_abs    = rb_funcall(step, id_abs_cast, 0);
    signed_step = ( sign == 1 ) ? step_abs : rb_funcall(step_abs, id_op_uminus, 0);
    return rb_ca_seq(obj, vbeg, signed_step);
  }
  else if ( TYPE(v) == T_STRING ) {
    /* The whitespace / `,` / `;` / `_`->UNDEF parser is far more natural in
       Ruby; only this branch stays there (carray/basics.rb). */
    return rb_funcall(rb_cCArray, id_cast_string, 2, sym, v);
  }
  else {
    /* Numeric / #to_ca responder */
    if ( rb_respond_to(v, id_to_ca_cast) ) {
      VALUE ca = rb_funcall(v, id_to_ca_cast, 0);
      CArray *cap;
      TypedData_Get_Struct(ca, CArray, &carray_data_type, cap);
      return ( cap->data_type == data_type ) ? ca : ca_cast_to_type1(ca, sym);
    }
    return rb_cscalar_new_with_value(data_type, 0, v);
  }
}

#define DEFINE_CA_CAST(cfunc, dt) \
  static VALUE \
  cfunc (int argc, VALUE *argv, VALUE self) \
  { \
    return ca_cast_impl((dt), argc, argv); \
  }

DEFINE_CA_CAST(rb_ca_cast_boolean,  CA_BOOLEAN)
DEFINE_CA_CAST(rb_ca_cast_int8,     CA_INT8)
DEFINE_CA_CAST(rb_ca_cast_uint8,    CA_UINT8)
DEFINE_CA_CAST(rb_ca_cast_int16,    CA_INT16)
DEFINE_CA_CAST(rb_ca_cast_uint16,   CA_UINT16)
DEFINE_CA_CAST(rb_ca_cast_int32,    CA_INT32)
DEFINE_CA_CAST(rb_ca_cast_uint32,   CA_UINT32)
DEFINE_CA_CAST(rb_ca_cast_int64,    CA_INT64)
DEFINE_CA_CAST(rb_ca_cast_uint64,   CA_UINT64)
DEFINE_CA_CAST(rb_ca_cast_float32,  CA_FLOAT32)
DEFINE_CA_CAST(rb_ca_cast_float64,  CA_FLOAT64)
DEFINE_CA_CAST(rb_ca_cast_cmplx64,  CA_CMPLX64)
DEFINE_CA_CAST(rb_ca_cast_cmplx128, CA_CMPLX128)
DEFINE_CA_CAST(rb_ca_cast_object,   CA_OBJECT)
DEFINE_CA_CAST(rb_ca_cast_size,     CA_SIZE)

#undef DEFINE_CA_CAST

/* to_type(:fixlen, bytes: bytes_v) via in-file #to_type implementation. */
static VALUE
ca_cast_to_fixlen (VALUE v, VALUE fixlen_sym, VALUE bytes_v)
{
  VALUE list[2], ropt;
  ropt = rb_hash_new();
  rb_hash_aset(ropt, ID2SYM(rb_intern("bytes")), bytes_v);
  list[0] = fixlen_sym;
  list[1] = ropt;
  return rb_ca_to_type_internal(2, list, v);
}

/* CA_FIXLEN(data, bytes: N) -- fully in C (no String-regex branch to keep in
   Ruby, unlike the numeric casts).
     Array   -> bytes defaults to max top-level element #length; new + store
     CArray  -> copy if already fixlen, else #to_type(:fixlen, bytes:)
     nil     -> empty fixlen (bytes 0 when omitted, matching the old default)
     other   -> #to_ca coerce, else CScalar.new(:fixlen, bytes:) { data } */
static VALUE
rb_ca_cast_fixlen (int argc, VALUE *argv, VALUE self)
{
  VALUE v, opts = Qnil, bytes_v = Qnil;
  VALUE fixlen_sym = ID2SYM(ca_data_type_sym[CA_FIXLEN]);

  rb_scan_args(argc, argv, "11", &v, &opts);
  rb_scan_options(opts, "bytes", &bytes_v);

  if ( RTEST(rb_obj_is_kind_of(v, rb_cCArray)) ) {
    CArray *ca;
    TypedData_Get_Struct(v, CArray, &carray_data_type, ca);
    if ( ca->data_type == CA_FIXLEN ) {
      return rb_ca_copy(v);
    }
    return ca_cast_to_fixlen(v, fixlen_sym, bytes_v);
  }
  else if ( TYPE(v) == T_ARRAY ) {
    volatile VALUE shape;
    ca_size_t dim[CA_RANK_MAX];
    long ndim, i;
    ca_size_t bytes;
    VALUE obj;
    if ( NIL_P(bytes_v) ) {
      /* bytes = v.map{|s| s.length}.max  (top-level #length, duck-typed) */
      long len = RARRAY_LEN(v);
      ca_size_t maxlen = 0;
      for ( i = 0; i < len; i++ ) {
        ca_size_t l = NUM2SIZE(rb_funcall(rb_ary_entry(v, i), id_length_cast, 0));
        if ( l > maxlen ) maxlen = l;
      }
      bytes = ( maxlen > 0 ) ? maxlen : 1;   /* all empty: one NUL byte */
    } else {
      bytes = NUM2SIZE(bytes_v);
    }
    shape = rb_funcall(rb_cCArray, id_guess_array_shape_cast, 1, v);
    ndim = RARRAY_LEN(shape);
    for ( i = 0; i < ndim; i++ ) dim[i] = NUM2SIZE(rb_ary_entry(shape, i));
    obj = rb_carray_new(CA_FIXLEN, (int8_t) ndim, dim, bytes, NULL);
    rb_ca_store_all(obj, v);
    return obj;
  }
  else if ( NIL_P(v) ) {
    ca_size_t dim0 = 0;
    ca_size_t bytes = NIL_P(bytes_v) ? 1 : NUM2SIZE(bytes_v);
    return rb_carray_new(CA_FIXLEN, 1, &dim0, bytes, NULL);
  }
  else {
    if ( rb_respond_to(v, id_to_ca_cast) ) {
      VALUE ca = rb_funcall(v, id_to_ca_cast, 0);
      CArray *cap;
      TypedData_Get_Struct(ca, CArray, &carray_data_type, cap);
      return ( cap->data_type == CA_FIXLEN )
               ? ca : ca_cast_to_fixlen(ca, fixlen_sym, bytes_v);
    }
    {
      /* No bytes: given: a String is as wide as it is (one NUL byte when
         empty).  Anything else has no width to infer, and the fixlen
         check reports it. */
      ca_size_t bytes = 0;
      if ( ! NIL_P(bytes_v) ) {
        bytes = NUM2SIZE(bytes_v);
      }
      else if ( RB_TYPE_P(v, T_STRING) ) {
        bytes = ( RSTRING_LEN(v) > 0 ) ? RSTRING_LEN(v) : 1;
      }
      return rb_cscalar_new_with_value(CA_FIXLEN, bytes, v);
    }
  }
}

static VALUE
rb_ca_read_text_as_number (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE src = self, out, vmask;
  VALUE rtype, report;
  CArray *ca, *co, *cmask;
  int8_t data_type;
  int is_float;
  VALUE *cells;
  boolean8_t *m_in, *m_out;
  ca_size_t i;

  rb_scan_args(argc, argv, "11", &rtype, &report);
  if ( ! NIL_P(report) ) {
    Check_Type(report, T_ARRAY);
  }

  data_type = rb_ca_guess_type(rtype);
  switch ( data_type ) {
  case CA_INT8: case CA_INT16: case CA_INT32: case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
    is_float = 0;
    break;
  case CA_FLOAT32: case CA_FLOAT64:
    is_float = 1;
    break;
  default:
    return Qnil;               /* not a number type: the caller casts */
  }

  TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  if ( ca->data_type != CA_OBJECT ) {
    rb_raise(rb_eArgError, "decimal reading needs an object array");
  }
  if ( ! ca_is_entity(ca) ) {
    src = rb_ca_copy(src);
    TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  }

  out = rb_carray_new(data_type, ca->ndim, ca->dim, 0, NULL);
  TypedData_Get_Struct(out, CArray, &carray_data_type, co);
  vmask = rb_carray_new(CA_BOOLEAN, ca->ndim, ca->dim, 0, NULL);

  cells = (VALUE *) ca->ptr;
  m_in  = ca_has_mask(ca) ? (boolean8_t *) ca->mask->ptr : NULL;
  TypedData_Get_Struct(vmask, CArray, &carray_data_type, cmask);
  m_out = (boolean8_t *) cmask->ptr;

  for (i = 0; i < ca->elements; i++) {
    VALUE v = cells[i];
    char *cell = co->ptr + i * co->bytes;
    int ok = 0;
    int missing = ( m_in && m_in[i] ) || NIL_P(v);
    if ( missing ) {
      ok = 0;
    }
    else if ( RB_TYPE_P(v, T_STRING) ) {
      int rc = ca_decimal_string_read(v, data_type, cell);
      missing = ( rc == CA_DECIMAL_BLANK );
      ok = ( rc == CA_DECIMAL_OK );
    }
    else if ( is_float ) {
      if ( RB_FLOAT_TYPE_P(v) || RB_INTEGER_TYPE_P(v) || ca_decimal_other_real(v) ) {
        double d = NUM2DBL(v);
        if ( data_type == CA_FLOAT32 ) {
          *(float32_t *) cell = (float32_t) d;
        }
        else {
          *(float64_t *) cell = d;
        }
        ok = 1;
      }
    }
    else {
      int negative = 0;
      uint64_t magnitude = 0;
      ok = ca_decimal_object_integer(v, &negative, &magnitude)
           && ca_decimal_fits(data_type, negative, magnitude);
      if ( ok ) {
        ca_decimal_store_integer(data_type, cell, 0, negative, magnitude);
      }
    }
    m_out[i] = ok ? 0 : 1;
    if ( ! ok ) {
      memset(co->ptr + i * co->bytes, 0, co->bytes);
      if ( ! missing && ! NIL_P(report) ) {
        rb_ary_push(report, SIZET2NUM(i));
      }
    }
  }

  ca_mask_from_bytes(co, m_out);
  rb_ca_inherit_attr(out, self);
  RB_GC_GUARD(src);
  RB_GC_GUARD(vmask);
  return out;
}

/* The number type a column of text reads as, for CAFrame#infer_types.

   A cell is an integer when it is digits with an optional sign and fits
   int64, and a float when it is any other decimal number (the grammar
   above, nan / inf included).  A number with a leading zero ("007",
   "007.5") is not a number here: it is a code, kept as text.  Neither is
   an integer too long for int64 (an identifier), which a float would
   round.  Blank, nil and masked cells are missing and say nothing.

   Returns :int64 when every present cell is an integer, :float64 when
   every present cell is a number and one is not an integer, and nil
   otherwise -- including when no cell is present. */

enum {
  CA_INFER_MISSING,
  CA_INFER_INTEGER,
  CA_INFER_FLOAT,
  CA_INFER_TEXT
};

static int
ca_infer_string (VALUE str)
{
  const char *s = RSTRING_PTR(str);
  long n = RSTRING_LEN(str);
  long i = 0, k;
  int digits_only = 1;
  ca_decimal_trim(&s, &n);
  if ( n == 0 ) {
    return CA_INFER_MISSING;
  }
  if ( ! ca_decimal_float(s, n, NULL) ) {
    return CA_INFER_TEXT;
  }
  if ( s[i] == '+' || s[i] == '-' ) {
    i++;
  }
  if ( i + 1 < n && s[i] == '0' && s[i+1] >= '0' && s[i+1] <= '9' ) {
    return CA_INFER_TEXT;                    /* a leading zero */
  }
  if ( i == n ) {
    return CA_INFER_TEXT;
  }
  for (k = i; k < n; k++) {
    if ( s[k] < '0' || s[k] > '9' ) {
      digits_only = 0;
      break;
    }
  }
  if ( digits_only ) {
    int negative;
    uint64_t magnitude;
    if ( ca_decimal_integer(s, n, &negative, &magnitude) == CA_DECIMAL_OK
         && ca_decimal_fits(CA_INT64, negative, magnitude) ) {
      return CA_INFER_INTEGER;
    }
    return CA_INFER_TEXT;                    /* too long for int64 */
  }
  return CA_INFER_FLOAT;
}

static VALUE
rb_ca_infer_number_type_of_text (VALUE self)
{
  volatile VALUE src = self;
  CArray *ca;
  VALUE *cells;
  boolean8_t *m;
  ca_size_t i;
  int present = 0, any_float = 0;

  TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  if ( ca->data_type != CA_OBJECT ) {
    rb_raise(rb_eArgError, "type inference needs an object array");
  }
  if ( ! ca_is_entity(ca) ) {
    src = rb_ca_copy(src);
    TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  }
  cells = (VALUE *) ca->ptr;
  m = ca_has_mask(ca) ? (boolean8_t *) ca->mask->ptr : NULL;

  for (i = 0; i < ca->elements; i++) {
    VALUE v = cells[i];
    int kind;
    if ( ( m && m[i] ) || NIL_P(v) ) {
      continue;
    }
    if ( RB_TYPE_P(v, T_STRING) ) {
      kind = ca_infer_string(v);
    }
    else if ( RB_FLOAT_TYPE_P(v) ) {
      kind = CA_INFER_FLOAT;
    }
    else if ( RB_INTEGER_TYPE_P(v) ) {
      int negative;
      uint64_t magnitude;
      kind = ( ca_decimal_object_integer(v, &negative, &magnitude)
               && ca_decimal_fits(CA_INT64, negative, magnitude) )
             ? CA_INFER_INTEGER : CA_INFER_TEXT;
    }
    else {
      kind = CA_INFER_TEXT;
    }
    if ( kind == CA_INFER_TEXT ) {
      RB_GC_GUARD(src);
      return Qnil;
    }
    if ( kind != CA_INFER_MISSING ) {
      present = 1;
      any_float |= ( kind == CA_INFER_FLOAT );
    }
  }
  RB_GC_GUARD(src);
  if ( ! present ) {
    return Qnil;
  }
  return ID2SYM(rb_intern(any_float ? "float64" : "int64"));
}

void
Init_carray_cast (void)
{
  /* CArray data_type conversion */

  /* Internal: CAFrame#infer_types asks the number type of a text column. */
  rb_define_method(rb_cCArray, "__infer_number_type_of_text__", rb_ca_infer_number_type_of_text, 0);

  /* Internal: CAFrame#cast reads text cells with this grammar.  With an
     Array as the second argument, the addresses of cells that hold
     something but do not read (blank, nil and masked cells are missing,
     not unreadable) are pushed onto it. */
  rb_define_method(rb_cCArray, "__read_text_as_number__", rb_ca_read_text_as_number, -1);

  rb_define_method(rb_cCArray, "to_type", rb_ca_to_type_internal, -1);

  rb_define_method(rb_cCArray, "fixlen", rb_ca_to_fixlen, -1);
  rb_define_method(rb_cCArray, "boolean", rb_ca_to_boolean, 0);
  rb_define_method(rb_cCArray, "int8", rb_ca_to_int8, 0);
  rb_define_method(rb_cCArray, "uint8", rb_ca_to_uint8, 0);
  rb_define_method(rb_cCArray, "int16", rb_ca_to_int16, 0);
  rb_define_method(rb_cCArray, "uint16", rb_ca_to_uint16, 0);
  rb_define_method(rb_cCArray, "int32", rb_ca_to_int32, 0);
  rb_define_method(rb_cCArray, "uint32", rb_ca_to_uint32, 0);
  rb_define_method(rb_cCArray, "int64", rb_ca_to_int64, 0);
  rb_define_method(rb_cCArray, "uint64", rb_ca_to_uint64, 0);
  rb_define_method(rb_cCArray, "float32", rb_ca_to_float32, 0);
  rb_define_method(rb_cCArray, "float64", rb_ca_to_float64, 0);
  rb_define_method(rb_cCArray, "cmplx64", rb_ca_to_cmplx64, 0);
  rb_define_method(rb_cCArray, "cmplx128", rb_ca_to_cmplx128, 0);
  rb_define_method(rb_cCArray, "object", rb_ca_to_VALUE, 0);

  rb_define_alias(rb_cCArray, "byte", "uint8");
  rb_define_alias(rb_cCArray, "short", "int16");
  rb_define_alias(rb_cCArray, "int", "int32");
  rb_define_alias(rb_cCArray, "float", "float32");
  rb_define_alias(rb_cCArray, "double", "float64");
  rb_define_alias(rb_cCArray, "complex", "cmplx64");
  rb_define_alias(rb_cCArray, "dcomplex", "cmplx128");

  rb_define_method(rb_cCArray, "as_type", rb_ca_as_type_internal, -1);

  rb_define_method(rb_cCArray, "as_fixlen", rb_ca_as_fixlen, -1);
  rb_define_method(rb_cCArray, "as_boolean", rb_ca_as_boolean, 0);
  rb_define_method(rb_cCArray, "as_int8", rb_ca_as_int8, 0);
  rb_define_method(rb_cCArray, "as_uint8", rb_ca_as_uint8, 0);
  rb_define_method(rb_cCArray, "as_int16", rb_ca_as_int16, 0);
  rb_define_method(rb_cCArray, "as_uint16", rb_ca_as_uint16, 0);
  rb_define_method(rb_cCArray, "as_int32", rb_ca_as_int32, 0);
  rb_define_method(rb_cCArray, "as_uint32", rb_ca_as_uint32, 0);
  rb_define_method(rb_cCArray, "as_int64", rb_ca_as_int64, 0);
  rb_define_method(rb_cCArray, "as_uint64", rb_ca_as_uint64, 0);
  rb_define_method(rb_cCArray, "as_float32", rb_ca_as_float32, 0);
  rb_define_method(rb_cCArray, "as_float64", rb_ca_as_float64, 0);
  rb_define_method(rb_cCArray, "as_float128", rb_ca_as_float128, 0);
  rb_define_method(rb_cCArray, "as_cmplx64", rb_ca_as_cmplx64, 0);
  rb_define_method(rb_cCArray, "as_cmplx128", rb_ca_as_cmplx128, 0);
  rb_define_method(rb_cCArray, "as_cmplx256", rb_ca_as_cmplx256, 0);
  rb_define_method(rb_cCArray, "as_object", rb_ca_as_VALUE, 0);

  rb_define_alias(rb_cCArray, "as_byte", "as_uint8");
  rb_define_alias(rb_cCArray, "as_short", "as_int16");
  rb_define_alias(rb_cCArray, "as_int", "as_int32");
  rb_define_alias(rb_cCArray, "as_float", "as_float32");
  rb_define_alias(rb_cCArray, "as_double", "as_float64");
  rb_define_alias(rb_cCArray, "as_complex", "as_cmplx64");
  rb_define_alias(rb_cCArray, "as_dcomplex", "as_cmplx128");

  rb_define_singleton_method(rb_cCArray,
           "wrap_writable", rb_ca_s_wrap_writable, -1);
  rb_define_singleton_method(rb_cCArray,
           "wrap_readonly", rb_ca_s_wrap_readonly, -1);
  rb_define_singleton_method(rb_cCArray,
                             "cast", rb_ca_s_cast, 1);
  rb_define_singleton_method(rb_cCArray,
           "cast_self_or_other", rb_ca_s_cast_self_or_other, 2);
  rb_define_singleton_method(rb_cCArray,
           "result_type", rb_ca_s_result_type, -1);
  rb_define_private_method(rb_cCArray,
           "value_match_type", rb_ca_value_match_type, 2);

  rb_define_singleton_method(rb_cCArray,
           "promote_list", rb_ca_s_promote_list, -1);

  /* Global polymorphic cast functions: CA_INT32(data), CA_FLOAT64(data),
     ... CA_OBJECT(data), CA_FIXLEN(...).  Implementation is the
     ca_cast_impl family above; dispatch on `data`'s Ruby class.
     Type-name aliases (CA_BYTE / CA_SHORT / CA_INT / CA_FLOAT /
     CA_DOUBLE / CA_COMPLEX / CA_DCOMPLEX / CA_SIZE) reuse the same C
     function as their canonical data_type.  Paired with the type-tag
     classes registered in ext/carray_data_type.c. */
  id_new_cast               = rb_intern("new");
  id_guess_array_shape_cast = rb_intern("guess_array_shape");
  id_cast_string            = rb_intern("__cast_string__");
  id_to_ca_cast             = rb_intern("to_ca");
  id_length_cast            = rb_intern("length");
  id_begin_cast             = rb_intern("begin");
  id_end_cast               = rb_intern("end");
  id_to_a_cast              = rb_intern("to_a");
  id_exclude_end_p_cast     = rb_intern("exclude_end?");
  id_abs_cast               = rb_intern("abs");
  id_floor_cast             = rb_intern("floor");
  id_op_minus               = rb_intern("-");
  id_op_div                 = rb_intern("/");
  id_op_plus                = rb_intern("+");
  id_op_le                  = rb_intern("<=");
  id_op_eq                  = rb_intern("==");
  id_op_uminus              = rb_intern("-@");

  rb_define_global_function("CA_BOOLEAN",  rb_ca_cast_boolean,  -1);
  rb_define_global_function("CA_INT8",     rb_ca_cast_int8,     -1);
  rb_define_global_function("CA_UINT8",    rb_ca_cast_uint8,    -1);
  rb_define_global_function("CA_INT16",    rb_ca_cast_int16,    -1);
  rb_define_global_function("CA_UINT16",   rb_ca_cast_uint16,   -1);
  rb_define_global_function("CA_INT32",    rb_ca_cast_int32,    -1);
  rb_define_global_function("CA_UINT32",   rb_ca_cast_uint32,   -1);
  rb_define_global_function("CA_INT64",    rb_ca_cast_int64,    -1);
  rb_define_global_function("CA_UINT64",   rb_ca_cast_uint64,   -1);
  rb_define_global_function("CA_FLOAT32",  rb_ca_cast_float32,  -1);
  rb_define_global_function("CA_FLOAT64",  rb_ca_cast_float64,  -1);
  rb_define_global_function("CA_CMPLX64",  rb_ca_cast_cmplx64,  -1);
  rb_define_global_function("CA_CMPLX128", rb_ca_cast_cmplx128, -1);
  rb_define_global_function("CA_OBJECT",   rb_ca_cast_object,   -1);
  /* type-name aliases */
  rb_define_global_function("CA_BYTE",     rb_ca_cast_uint8,    -1);
  rb_define_global_function("CA_SHORT",    rb_ca_cast_int16,    -1);
  rb_define_global_function("CA_INT",      rb_ca_cast_int32,    -1);
  rb_define_global_function("CA_FLOAT",    rb_ca_cast_float32,  -1);
  rb_define_global_function("CA_DOUBLE",   rb_ca_cast_float64,  -1);
  rb_define_global_function("CA_COMPLEX",  rb_ca_cast_cmplx64,  -1);
  rb_define_global_function("CA_DCOMPLEX", rb_ca_cast_cmplx128, -1);
  rb_define_global_function("CA_SIZE",     rb_ca_cast_size,     -1);
  rb_define_global_function("CA_FIXLEN",   rb_ca_cast_fixlen,   -1);

  rb_define_method(rb_cCArray, "cast_with", rb_ca_cast_with, 1);

  rb_define_method(rb_cCArray, "clip_int8",   rb_ca_clip_int8,   0);
  rb_define_method(rb_cCArray, "clip_int16",  rb_ca_clip_int16,  0);
  rb_define_method(rb_cCArray, "clip_int32",  rb_ca_clip_int32,  0);
  rb_define_method(rb_cCArray, "clip_int64",  rb_ca_clip_int64,  0);
  rb_define_method(rb_cCArray, "clip_uint8",  rb_ca_clip_uint8,  0);
  rb_define_method(rb_cCArray, "clip_uint16", rb_ca_clip_uint16, 0);
  rb_define_method(rb_cCArray, "clip_uint32", rb_ca_clip_uint32, 0);
  rb_define_method(rb_cCArray, "clip_uint64", rb_ca_clip_uint64, 0);
}

