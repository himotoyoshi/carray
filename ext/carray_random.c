/* ---------------------------------------------------------------------------

  Random-number fill and shuffle: random / randomn / shuffle (+ bang
  variants).  Ruby-facing docs live in yard-stubs/carray_random.rb.

  Backend: Ruby's built-in Random (MT19937) via public C API.  When
  the `rng:` kwarg is nil, uses the per-ractor default RNG
  (rb_genrand_*); otherwise uses the given Random instance
  (rb_random_*).

  Dispatch:
    random!       -> uniform fill (per-dtype branch below)
    randomn!      -> standard normal via Box-Muller (float / complex only)
    shuffle!      -> Fisher-Yates over the flat buffer, or per-slice
                     when axis: is given (byte-chunk swap)
    non-bang      -> template / copy then delegate to the bang form

---------------------------------------------------------------------------- */

#include "carray.h"
#include <math.h>
#include <string.h>


static inline double
ca_random_real(VALUE rng)
{
  if (NIL_P(rng))
    return rb_genrand_real();
  else
    return rb_random_real(rng);
}

static inline unsigned long
ca_random_ulong_limited(VALUE rng, unsigned long limit)
{
  if (NIL_P(rng))
    return rb_genrand_ulong_limited(limit);
  else
    return rb_random_ulong_limited(rng, limit);
}

/* ---- random! ----------------------------------------------------------- */

/* CArray#random!([low,] [high], rng:) — fill self with uniform random
 * numbers in-place, returning self.  Range surface mirrors Numo/NumPy
 * (half-open [low, high) as the default) plus Ruby idiom (`..` closed,
 * `...` half-open):
 *
 *   random!                    float [0.0, 1.0); integer -> ArgumentError
 *   random!(high)              [0, high)                (Ruby rand shorthand)
 *   random!(low, high)         [low, high)              (Numo positional)
 *   random!(a..b)              [a, b]  closed           (integer: b included)
 *   random!(a...b)             [a, b)  half-open
 *   random!(..., rng: r)       any of the above with a custom Random source
 *
 * For float, `..` and `...` return the same distribution (endpoint
 * probability ~2^-53); the closed form is honored syntactically but not
 * enforced at the mantissa level, matching NumPy/SciPy convention.
 * Boolean fills 0/1 with 50% probability each and ignores the range
 * argument.  Rejects CA_OBJECT / CA_FIXLEN. */
static VALUE
rb_ca_random_bang(int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  VALUE arg1 = Qnil, arg2 = Qnil, opts = Qnil;
  VALUE low_val = Qnil, high_val = Qnil;
  int is_default = 1;
  int high_is_closed = 0;
  double low_dbl = 0.0, high_dbl = 0.0;
  long low_long = 0, high_long = 0;
  unsigned long limit = 0;
  ca_size_t i, n;
  VALUE rng = Qnil;

  rb_scan_args(argc, argv, "02:", &arg1, &arg2, &opts);
  rb_scan_options(opts, "rng", &rng);

  /* Parse positional args into (low_val, high_val) + high_is_closed. */
  if (rb_obj_is_kind_of(arg1, rb_cRange)) {
    if (!NIL_P(arg2)) {
      rb_raise(rb_eArgError,
               "random: cannot combine a Range with a second positional arg");
    }
    low_val  = rb_funcall(arg1, rb_intern("begin"), 0);
    high_val = rb_funcall(arg1, rb_intern("end"), 0);
    if (NIL_P(low_val) || NIL_P(high_val)) {
      rb_raise(rb_eArgError,
               "random: Range must have finite begin and end");
    }
    high_is_closed = ! RTEST(rb_funcall(arg1, rb_intern("exclude_end?"), 0));
    is_default = 0;
  } else if (!NIL_P(arg1) && !NIL_P(arg2)) {
    low_val  = arg1;
    high_val = arg2;
    is_default = 0;
  } else if (!NIL_P(arg1)) {
    low_val  = INT2FIX(0);
    high_val = arg1;
    is_default = 0;
  }

  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if (ca->data_type == CA_OBJECT || ca->data_type == CA_FIXLEN) {
    rb_raise(rb_eCADataTypeError,
             "random! is not supported for object/fixlen arrays");
  }

  /* Materialize (low, high) as the correct scalar type and validate.
   * For integer dtypes, `..` closed adds 1 to high (turns into half-open
   * for the sampler); for float dtypes, closed and half-open are
   * equivalent so no adjustment. */
  if (!is_default) {
    int is_integer_dtype = (ca->data_type >= CA_INT8
                            && ca->data_type <= CA_UINT64);
    if (is_integer_dtype) {
      low_long  = NUM2LONG(low_val);
      high_long = NUM2LONG(high_val);
      if (high_is_closed) high_long += 1;
      if (low_long >= high_long) {
        rb_raise(rb_eArgError,
                 "random: low must be less than high "
                 "(got low=%ld, high=%ld)",
                 low_long, high_long);
      }
      limit = (unsigned long)(high_long - low_long) - 1;
    } else {
      low_dbl  = NUM2DBL(low_val);
      high_dbl = NUM2DBL(high_val);
      if (low_dbl >= high_dbl) {
        rb_raise(rb_eArgError,
                 "random: low must be less than high "
                 "(got low=%g, high=%g)",
                 low_dbl, high_dbl);
      }
    }
  }

  n = ca->elements;
  ca_attach(ca);

  switch (ca->data_type) {
  case CA_FLOAT64: {
    double *p = (double *)ca->ptr;
    if (is_default) {
      for (i = 0; i < n; i++)
        p[i] = ca_random_real(rng);
    } else {
      double range = high_dbl - low_dbl;
      for (i = 0; i < n; i++)
        p[i] = low_dbl + ca_random_real(rng) * range;
    }
    break;
  }
  case CA_FLOAT32: {
    float *p = (float *)ca->ptr;
    if (is_default) {
      for (i = 0; i < n; i++)
        p[i] = (float)ca_random_real(rng);
    } else {
      double range = high_dbl - low_dbl;
      for (i = 0; i < n; i++)
        p[i] = (float)(low_dbl + ca_random_real(rng) * range);
    }
    break;
  }
  case CA_CMPLX128: {
    double complex *p = (double complex *)ca->ptr;
    if (is_default) {
      for (i = 0; i < n; i++)
        p[i] = ca_random_real(rng) + ca_random_real(rng) * I;
    } else {
      double range = high_dbl - low_dbl;
      for (i = 0; i < n; i++)
        p[i] = (low_dbl + ca_random_real(rng) * range)
             + (low_dbl + ca_random_real(rng) * range) * I;
    }
    break;
  }
  case CA_CMPLX64: {
    float complex *p = (float complex *)ca->ptr;
    if (is_default) {
      for (i = 0; i < n; i++)
        p[i] = (float)ca_random_real(rng) + (float)ca_random_real(rng) * I;
    } else {
      double range = high_dbl - low_dbl;
      for (i = 0; i < n; i++)
        p[i] = (float)(low_dbl + ca_random_real(rng) * range)
             + (float)(low_dbl + ca_random_real(rng) * range) * I;
    }
    break;
  }
  case CA_BOOLEAN: {
    boolean8_t *p = (boolean8_t *)ca->ptr;
    for (i = 0; i < n; i++)
      p[i] = (ca_random_real(rng) < 0.5) ? 1 : 0;
    break;
  }
  default: {
    /* integer types: CA_INT8..CA_UINT64 */
    if (is_default) {
      ca_sync(ca);
      ca_detach(ca);
      rb_raise(rb_eArgError,
               "random! on an integer array requires a range: "
               "a.random!(high), a.random!(low, high), or "
               "a.random!(low..high) / a.random!(low...high)");
    }
    switch (ca->data_type) {
    case CA_INT8: {
      int8_t *p = (int8_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (int8_t)(low_long + ca_random_ulong_limited(rng, limit));
      break;
    }
    case CA_UINT8: {
      uint8_t *p = (uint8_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (uint8_t)(low_long + ca_random_ulong_limited(rng, limit));
      break;
    }
    case CA_INT16: {
      int16_t *p = (int16_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (int16_t)(low_long + ca_random_ulong_limited(rng, limit));
      break;
    }
    case CA_UINT16: {
      uint16_t *p = (uint16_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (uint16_t)(low_long + ca_random_ulong_limited(rng, limit));
      break;
    }
    case CA_INT32: {
      int32_t *p = (int32_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (int32_t)(low_long + ca_random_ulong_limited(rng, limit));
      break;
    }
    case CA_UINT32: {
      uint32_t *p = (uint32_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (uint32_t)(low_long + ca_random_ulong_limited(rng, limit));
      break;
    }
    case CA_INT64: {
      int64_t *p = (int64_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (int64_t)(low_long + ca_random_ulong_limited(rng, limit));
      break;
    }
    case CA_UINT64: {
      uint64_t *p = (uint64_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (uint64_t)(low_long + ca_random_ulong_limited(rng, limit));
      break;
    }
    default:
      ca_sync(ca);
      ca_detach(ca);
      rb_raise(rb_eCADataTypeError,
               "random! is not supported for this data type");
    }
    break;
  }
  }

  ca_sync(ca);
  ca_detach(ca);
  return self;
}

/* ---- randomn! ---------------------------------------------------------- */

static inline void
box_muller_pair(VALUE rng, double *r1, double *r2)
{
  double u1 = ca_random_real(rng);
  double u2 = ca_random_real(rng);
  while (u1 == 0.0)
    u1 = ca_random_real(rng);
  double r = sqrt(-2.0 * log(u1));
  double theta = 2.0 * M_PI * u2;
  *r1 = r * cos(theta);
  *r2 = r * sin(theta);
}

/* CArray#randomn!(rng:) — fill self with standard normal N(0, 1)
 * samples in-place via Box-Muller, returning self.
 *
 * Restricted to float / complex dtypes.  Complex fills real + imag as
 * two independent normals per cell. */
static VALUE
rb_ca_randomn_bang(int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  VALUE opts = Qnil;
  ca_size_t i, n;

  rb_scan_args(argc, argv, "0:", &opts);
  VALUE rng = Qnil;
  rb_scan_options(opts, "rng", &rng);

  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if (ca->data_type != CA_FLOAT64 && ca->data_type != CA_FLOAT32 &&
      ca->data_type != CA_CMPLX128 && ca->data_type != CA_CMPLX64) {
    rb_raise(rb_eCADataTypeError,
             "randomn! requires float or complex array");
  }

  n = ca->elements;
  ca_attach(ca);

  switch (ca->data_type) {
  case CA_FLOAT64: {
    double *p = (double *)ca->ptr;
    ca_size_t pairs = n / 2;
    for (i = 0; i < pairs; i++) {
      box_muller_pair(rng, &p[2*i], &p[2*i+1]);
    }
    if (n % 2 == 1) {
      double r1, r2;
      box_muller_pair(rng, &r1, &r2);
      p[n-1] = r1;
    }
    break;
  }
  case CA_FLOAT32: {
    float *p = (float *)ca->ptr;
    ca_size_t pairs = n / 2;
    for (i = 0; i < pairs; i++) {
      double r1, r2;
      box_muller_pair(rng, &r1, &r2);
      p[2*i]   = (float)r1;
      p[2*i+1] = (float)r2;
    }
    if (n % 2 == 1) {
      double r1, r2;
      box_muller_pair(rng, &r1, &r2);
      p[n-1] = (float)r1;
    }
    break;
  }
  case CA_CMPLX128: {
    double complex *p = (double complex *)ca->ptr;
    for (i = 0; i < n; i++) {
      double r1, r2;
      box_muller_pair(rng, &r1, &r2);
      p[i] = r1 + r2 * I;
    }
    break;
  }
  case CA_CMPLX64: {
    float complex *p = (float complex *)ca->ptr;
    for (i = 0; i < n; i++) {
      double r1, r2;
      box_muller_pair(rng, &r1, &r2);
      p[i] = (float)r1 + (float)r2 * I;
    }
    break;
  }
  default:
    break;
  }

  ca_sync(ca);
  ca_detach(ca);
  return self;
}

/* ---- shuffle! ---------------------------------------------------------- */

static void
swap_chunks(char *a, char *b, ca_size_t chunk_bytes, char *tmp)
{
  memcpy(tmp, a,   chunk_bytes);
  memcpy(a,   b,   chunk_bytes);
  memcpy(b,   tmp, chunk_bytes);
}

/* CArray#shuffle!(axis:, rng:) — Fisher-Yates permute self in-place,
 * returning self.
 *
 * Without axis:, shuffles all cells as if flattened.  With axis:,
 * permutes slices along that axis (the trailing sub-slab is treated
 * as a byte chunk and swapped whole, so multi-dim slices move
 * together). */
static VALUE
rb_ca_shuffle_bang(int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  VALUE opts = Qnil, v_axis = Qnil;
  ca_size_t n;
  int axis = -1;

  rb_scan_args(argc, argv, "0:", &opts);
  VALUE rng = Qnil;
  rb_scan_options(opts, "rng,axis", &rng, &v_axis);

  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if (ca->elements <= 1) return self;

  ca_attach(ca);

  if (NIL_P(v_axis)) {
    /* shuffle all elements */
    n = ca->elements;
    ca_size_t elem_bytes = ca->bytes;
    char *tmp = (char *)xmalloc(elem_bytes);
    char *p = ca->ptr;

    for (ca_size_t i = n - 1; i > 0; i--) {
      unsigned long j = ca_random_ulong_limited(rng, (unsigned long)i);
      if ((ca_size_t)j != i) {
        swap_chunks(p + i * elem_bytes, p + j * elem_bytes, elem_bytes, tmp);
      }
    }
    xfree(tmp);
  }
  else {
    axis = NUM2INT(v_axis);
    if (axis < 0) axis += ca->ndim;
    if (axis < 0 || axis >= ca->ndim) {
      ca_sync(ca);
      ca_detach(ca);
      rb_raise(rb_eArgError,
               "axis %d is out of range for ndim %d", axis, ca->ndim);
    }

    n = ca->dim[axis];
    if (n <= 1) {
      ca_sync(ca);
      ca_detach(ca);
      return self;
    }

    ca_size_t outer = 1;
    for (int d = 0; d < axis; d++)
      outer *= ca->dim[d];

    ca_size_t inner = 1;
    for (int d = axis + 1; d < ca->ndim; d++)
      inner *= ca->dim[d];

    ca_size_t chunk_bytes = inner * ca->bytes;
    ca_size_t stride = n * chunk_bytes;
    char *tmp = (char *)xmalloc(chunk_bytes);

    for (ca_size_t o = 0; o < outer; o++) {
      char *base = ca->ptr + o * stride;
      for (ca_size_t i = n - 1; i > 0; i--) {
        unsigned long j = ca_random_ulong_limited(rng, (unsigned long)i);
        if ((ca_size_t)j != i) {
          swap_chunks(base + i * chunk_bytes,
                      base + j * chunk_bytes,
                      chunk_bytes, tmp);
        }
      }
    }
    xfree(tmp);
  }

  ca_sync(ca);
  ca_detach(ca);
  return self;
}

/* ---- shuffle (copy) ---------------------------------------------------- */

/* CArray#shuffle(axis:, rng:) — non-bang variant: shuffle a copy of self. */
static VALUE
rb_ca_shuffle(int argc, VALUE *argv, VALUE self)
{
  volatile VALUE copy = rb_funcall(self, rb_intern("copy"), 0);
  return rb_ca_shuffle_bang(argc, argv, copy);
}

/* ---- random (copy) ----------------------------------------------------- */

/* CArray#random([low,] [high], rng:) — non-bang variant: return a
 * newly templated array filled uniformly.  Shape and dtype come from
 * CArray#template, so the receiver is only consulted for those.
 * Accepts the same argument forms as {rb_ca_random_bang}. */
static VALUE
rb_ca_random(int argc, VALUE *argv, VALUE self)
{
  volatile VALUE copy = rb_funcall(self, rb_intern("template"), 0);
  return rb_ca_random_bang(argc, argv, copy);
}

/* CArray#randomn(rng:) — non-bang variant: return a newly templated
 * array filled with standard normal samples. */
static VALUE
rb_ca_randomn(int argc, VALUE *argv, VALUE self)
{
  volatile VALUE copy = rb_funcall(self, rb_intern("template"), 0);
  return rb_ca_randomn_bang(argc, argv, copy);
}

/* ---- Init -------------------------------------------------------------- */

void
Init_carray_random (void)
{
  rb_define_method(rb_cCArray, "random!",  rb_ca_random_bang,  -1);
  rb_define_method(rb_cCArray, "randomn!", rb_ca_randomn_bang, -1);
  rb_define_method(rb_cCArray, "shuffle!", rb_ca_shuffle_bang, -1);

  rb_define_method(rb_cCArray, "random",   rb_ca_random,  -1);
  rb_define_method(rb_cCArray, "randomn",  rb_ca_randomn, -1);
  rb_define_method(rb_cCArray, "shuffle",  rb_ca_shuffle,  -1);
}
