/* ---------------------------------------------------------------------------

  Random-number fill and shuffle: random / randomn / shuffle (+ bang
  variants).  Ruby-facing docs live in yard-stubs/carray_random.rb.

  Backend: Ruby's built-in Random (MT19937) via public C API.  When
  the `rng:` kwarg is nil, uses the per-ractor default RNG
  (rb_genrand_*); otherwise uses the given Random instance
  (rb_random_*).

  Dispatch:
    random!       -> uniform fill (per-type branch below)
    randomn!      -> standard normal via Box-Muller (float / complex only)
    shuffle!      -> Fisher-Yates over the flat buffer, or per-slice
                     when axis: is given (byte-chunk swap)
    non-bang      -> template / copy then delegate to the bang form

---------------------------------------------------------------------------- */

#include "carray.h"
#include <math.h>
#include <string.h>
#include <stdint.h>

/* The generator itself, shared verbatim with carray-jit.  See the file's
   own comment for why it carries no include guard. */
#include "ca_rng_xoshiro256pp.h"

VALUE rb_cCARng;

/* Where a fill's numbers come from.  Resolved once per call rather than
   per cell: the `rng:` argument is one object for the whole array, and
   asking what it is inside the loop would put a Ruby type test between
   every pair of draws.

   CA_RNG_OWN holds the state's cells directly.  That array belongs to
   the CArray::Rng the caller passed, so the draws advance it and the
   next call -- here or in a kernel -- carries on from where this one
   stopped. */
enum {
  CA_RNG_DEFAULT = 0,  /* no rng: given -- the per-ractor MT */
  CA_RNG_RUBY    = 1,  /* a ::Random instance -- also MT */
  CA_RNG_OWN     = 2   /* a CArray::Rng -- the generator above */
};

typedef struct {
  int kind;
  VALUE rng;
  CArray *state;       /* attached for CA_RNG_OWN, else NULL */
  int64_t *cells;
} ca_rng_t;

static void
ca_rng_open (VALUE rng, ca_rng_t *source)
{
  source->rng = rng;
  source->state = NULL;
  source->cells = NULL;
  if (NIL_P(rng)) {
    source->kind = CA_RNG_DEFAULT;
  }
  else if (rb_obj_is_kind_of(rng, rb_cCARng)) {
    VALUE state = rb_ivar_get(rng, rb_intern("@state"));
    CArray *ca;
    TypedData_Get_Struct(state, CArray, &carray_data_type, ca);
    ca_attach(ca);
    source->kind = CA_RNG_OWN;
    source->state = ca;
    source->cells = (int64_t *) ca->ptr;
  }
  else {
    source->kind = CA_RNG_RUBY;
  }
}

/* Writes the advanced state back where it came from.  Safe to call twice,
   which is what lets an error path close before it raises. */
static void
ca_rng_close (ca_rng_t *source)
{
  if (source->state) {
    ca_sync(source->state);
    ca_detach(source->state);
    source->state = NULL;
    source->cells = NULL;
  }
}

static inline double
ca_random_real (ca_rng_t *source)
{
  switch (source->kind) {
  case CA_RNG_OWN:    return ca_xoshiro256pp_next_real(source->cells);
  case CA_RNG_RUBY:   return rb_random_real(source->rng);
  default:            return rb_genrand_real();
  }
}

/* A draw in [0, limit], inclusive, matching what Ruby's own bounded draw
   promises.  For the generator above that is rejection sampling: taking
   the remainder alone would favour the low end of the range whenever the
   range does not divide 2**64. */
static inline uint64_t
ca_xoshiro256pp_below (int64_t *state, uint64_t range)
{
  uint64_t threshold, draw;
  if (range == 0) return ca_xoshiro256pp_next(state);   /* the whole word */
  threshold = (0 - range) % range;                      /* 2**64 mod range */
  do {
    draw = ca_xoshiro256pp_next(state);
  } while (draw < threshold);
  return draw % range;
}

static inline unsigned long
ca_random_ulong_limited (ca_rng_t *source, unsigned long limit)
{
  switch (source->kind) {
  case CA_RNG_OWN:
    return (unsigned long)
             ca_xoshiro256pp_below(source->cells, (uint64_t) limit + 1);
  case CA_RNG_RUBY:
    return rb_random_ulong_limited(source->rng, limit);
  default:
    return rb_genrand_ulong_limited(limit);
  }
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
  ca_rng_t source;

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
   * For integer data types, `..` closed adds 1 to high (turns into half-open
   * for the sampler); for float data types, closed and half-open are
   * equivalent so no adjustment. */
  if (!is_default) {
    int is_integer_type = (ca->data_type >= CA_INT8
                            && ca->data_type <= CA_UINT64);
    if (is_integer_type) {
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
  ca_rng_open(rng, &source);

  switch (ca->data_type) {
  case CA_FLOAT64: {
    double *p = (double *)ca->ptr;
    if (is_default) {
      for (i = 0; i < n; i++)
        p[i] = ca_random_real(&source);
    } else {
      double range = high_dbl - low_dbl;
      for (i = 0; i < n; i++)
        p[i] = low_dbl + ca_random_real(&source) * range;
    }
    break;
  }
  case CA_FLOAT32: {
    float *p = (float *)ca->ptr;
    if (is_default) {
      for (i = 0; i < n; i++)
        p[i] = (float)ca_random_real(&source);
    } else {
      double range = high_dbl - low_dbl;
      for (i = 0; i < n; i++)
        p[i] = (float)(low_dbl + ca_random_real(&source) * range);
    }
    break;
  }
  case CA_CMPLX128: {
    double complex *p = (double complex *)ca->ptr;
    if (is_default) {
      for (i = 0; i < n; i++)
        p[i] = ca_random_real(&source) + ca_random_real(&source) * I;
    } else {
      double range = high_dbl - low_dbl;
      for (i = 0; i < n; i++)
        p[i] = (low_dbl + ca_random_real(&source) * range)
             + (low_dbl + ca_random_real(&source) * range) * I;
    }
    break;
  }
  case CA_CMPLX64: {
    float complex *p = (float complex *)ca->ptr;
    if (is_default) {
      for (i = 0; i < n; i++)
        p[i] = (float)ca_random_real(&source) + (float)ca_random_real(&source) * I;
    } else {
      double range = high_dbl - low_dbl;
      for (i = 0; i < n; i++)
        p[i] = (float)(low_dbl + ca_random_real(&source) * range)
             + (float)(low_dbl + ca_random_real(&source) * range) * I;
    }
    break;
  }
  case CA_BOOLEAN: {
    boolean8_t *p = (boolean8_t *)ca->ptr;
    for (i = 0; i < n; i++)
      p[i] = (ca_random_real(&source) < 0.5) ? 1 : 0;
    break;
  }
  default: {
    /* integer types: CA_INT8..CA_UINT64 */
    if (is_default) {
      ca_rng_close(&source);
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
        p[i] = (int8_t)(low_long + ca_random_ulong_limited(&source, limit));
      break;
    }
    case CA_UINT8: {
      uint8_t *p = (uint8_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (uint8_t)(low_long + ca_random_ulong_limited(&source, limit));
      break;
    }
    case CA_INT16: {
      int16_t *p = (int16_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (int16_t)(low_long + ca_random_ulong_limited(&source, limit));
      break;
    }
    case CA_UINT16: {
      uint16_t *p = (uint16_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (uint16_t)(low_long + ca_random_ulong_limited(&source, limit));
      break;
    }
    case CA_INT32: {
      int32_t *p = (int32_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (int32_t)(low_long + ca_random_ulong_limited(&source, limit));
      break;
    }
    case CA_UINT32: {
      uint32_t *p = (uint32_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (uint32_t)(low_long + ca_random_ulong_limited(&source, limit));
      break;
    }
    case CA_INT64: {
      int64_t *p = (int64_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (int64_t)(low_long + ca_random_ulong_limited(&source, limit));
      break;
    }
    case CA_UINT64: {
      uint64_t *p = (uint64_t *)ca->ptr;
      for (i = 0; i < n; i++)
        p[i] = (uint64_t)(low_long + ca_random_ulong_limited(&source, limit));
      break;
    }
    default:
      ca_rng_close(&source);
      ca_sync(ca);
      ca_detach(ca);
      rb_raise(rb_eCADataTypeError,
               "random! is not supported for this data type");
    }
    break;
  }
  }

  ca_rng_close(&source);
  ca_sync(ca);
  ca_detach(ca);
  return self;
}

/* ---- randomn! ---------------------------------------------------------- */

static inline void
box_muller_pair(ca_rng_t *source, double *r1, double *r2)
{
  double u1 = ca_random_real(source);
  double u2 = ca_random_real(source);
  while (u1 == 0.0)
    u1 = ca_random_real(source);
  double r = sqrt(-2.0 * log(u1));
  double theta = 2.0 * M_PI * u2;
  *r1 = r * cos(theta);
  *r2 = r * sin(theta);
}

/* CArray#randomn!(rng:) — fill self with standard normal N(0, 1)
 * samples in-place via Box-Muller, returning self.
 *
 * Restricted to float / complex data types.  Complex fills real + imag as
 * two independent normals per cell. */
static VALUE
rb_ca_randomn_bang(int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  VALUE opts = Qnil;
  ca_size_t i, n;

  rb_scan_args(argc, argv, "0:", &opts);
  VALUE rng = Qnil;
  ca_rng_t source;
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
  ca_rng_open(rng, &source);

  switch (ca->data_type) {
  case CA_FLOAT64: {
    double *p = (double *)ca->ptr;
    ca_size_t pairs = n / 2;
    for (i = 0; i < pairs; i++) {
      box_muller_pair(&source, &p[2*i], &p[2*i+1]);
    }
    if (n % 2 == 1) {
      double r1, r2;
      box_muller_pair(&source, &r1, &r2);
      p[n-1] = r1;
    }
    break;
  }
  case CA_FLOAT32: {
    float *p = (float *)ca->ptr;
    ca_size_t pairs = n / 2;
    for (i = 0; i < pairs; i++) {
      double r1, r2;
      box_muller_pair(&source, &r1, &r2);
      p[2*i]   = (float)r1;
      p[2*i+1] = (float)r2;
    }
    if (n % 2 == 1) {
      double r1, r2;
      box_muller_pair(&source, &r1, &r2);
      p[n-1] = (float)r1;
    }
    break;
  }
  case CA_CMPLX128: {
    double complex *p = (double complex *)ca->ptr;
    for (i = 0; i < n; i++) {
      double r1, r2;
      box_muller_pair(&source, &r1, &r2);
      p[i] = r1 + r2 * I;
    }
    break;
  }
  case CA_CMPLX64: {
    float complex *p = (float complex *)ca->ptr;
    for (i = 0; i < n; i++) {
      double r1, r2;
      box_muller_pair(&source, &r1, &r2);
      p[i] = (float)r1 + (float)r2 * I;
    }
    break;
  }
  default:
    break;
  }

  ca_rng_close(&source);
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
  ca_rng_t source;
  rb_scan_options(opts, "rng,axis", &rng, &v_axis);

  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if (ca->elements <= 1) return self;

  ca_attach(ca);
  ca_rng_open(rng, &source);

  if (NIL_P(v_axis)) {
    /* shuffle all elements */
    n = ca->elements;
    ca_size_t elem_bytes = ca->bytes;
    char *tmp = (char *)xmalloc(elem_bytes);
    char *p = ca->ptr;

    for (ca_size_t i = n - 1; i > 0; i--) {
      unsigned long j = ca_random_ulong_limited(&source, (unsigned long)i);
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
      ca_rng_close(&source);
      ca_sync(ca);
      ca_detach(ca);
      rb_raise(rb_eArgError,
               "axis %d is out of range for ndim %d", axis, ca->ndim);
    }

    n = ca->dim[axis];
    if (n <= 1) {
      ca_rng_close(&source);
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
        unsigned long j = ca_random_ulong_limited(&source, (unsigned long)i);
        if ((ca_size_t)j != i) {
          swap_chunks(base + i * chunk_bytes,
                      base + j * chunk_bytes,
                      chunk_bytes, tmp);
        }
      }
    }
    xfree(tmp);
  }

  ca_rng_close(&source);
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
 * newly templated array filled uniformly.  Shape and data type come from
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

/* ---- CArray::Rng ---------------------------------------------------- */

/* A generator with its own state, so that a sequence belongs to an object
 * rather than to the process:
 *
 *   r = CArray::Rng.new(seed: 4)
 *   a.random!(rng: r)                        # fills, advancing r
 *   CArray.jit_for(n) { |i| b[i] = r.call }  # carries on from there
 *
 * The state is an ordinary CA_INT64 array of four cells, which is what
 * lets the second line work: carray-jit hands that array's address to a
 * kernel that pasted the same generator, and the kernel advances the
 * same cells this file does.  Nothing about the generator is hidden
 * behind a struct only this extension can read.
 *
 * The seed is not part of the state.  It is remembered so that #reset
 * with no argument can repeat a run, and so `inspect` can say what a
 * generator was started from. */

static VALUE rb_ca_rng_reset (int argc, VALUE *argv, VALUE self);

/* The state's cells, attached.  Every entry point here goes through this
 * rather than reaching into the ivar, so that "what is the state" has one
 * answer even after another generator is added. */
static CArray *
ca_rng_cells (VALUE self, int64_t **cells)
{
  CArray *ca;
  VALUE state = rb_ivar_get(self, rb_intern("@state"));
  TypedData_Get_Struct(state, CArray, &carray_data_type, ca);
  ca_attach(ca);
  *cells = (int64_t *) ca->ptr;
  return ca;
}

/* CArray::Rng.new(generator = :xoshiro256pp, seed: nil) */
static VALUE
rb_ca_rng_initialize (int argc, VALUE *argv, VALUE self)
{
  VALUE gen = Qnil, opts = Qnil, seed = Qnil, state;

  rb_scan_args(argc, argv, "01:", &gen, &opts);
  rb_scan_options(opts, "seed", &seed);

  if (NIL_P(gen)) gen = ID2SYM(rb_intern("xoshiro256pp"));
  if (!SYMBOL_P(gen) || SYM2ID(gen) != rb_intern("xoshiro256pp")) {
    rb_raise(rb_eArgError,
             "unknown generator %"PRIsVALUE"; carray has :xoshiro256pp",
             rb_inspect(gen));
  }

  state = rb_funcall(rb_cCArray, rb_intern("int64"), 1, INT2FIX(4));
  rb_ivar_set(self, rb_intern("@generator"), gen);
  rb_ivar_set(self, rb_intern("@state"), state);

  return rb_ca_rng_reset(NIL_P(seed) ? 0 : 1, &seed, self);
}

/* CArray::Rng#reset(seed = nil) — start the sequence over.
 *
 * With no argument, from the seed this generator already carries, which
 * repeats the run exactly.  A generator made without a seed is given one
 * from Random.new_seed, so two of them differ; that drawn seed is kept,
 * so even an unseeded run can be repeated once it has begun. */
static VALUE
rb_ca_rng_reset (int argc, VALUE *argv, VALUE self)
{
  VALUE seed = Qnil, masked;
  CArray *ca;
  int64_t *cells;

  rb_scan_args(argc, argv, "01", &seed);
  if (NIL_P(seed)) seed = rb_ivar_get(self, rb_intern("@seed"));
  if (NIL_P(seed)) {
    seed = rb_funcall(rb_path2class("Random"), rb_intern("new_seed"), 0);
  }

  /* Any Integer is a seed: a negative one and one wider than a word are
     folded into 64 bits rather than refused, which is what `&` does. */
  masked = rb_funcall(rb_to_int(seed), rb_intern("&"),
                      1, ULL2NUM(0xFFFFFFFFFFFFFFFFULL));

  ca = ca_rng_cells(self, &cells);
  ca_xoshiro256pp_seed(cells, (uint64_t) NUM2ULL(masked));
  ca_sync(ca);
  ca_detach(ca);

  rb_ivar_set(self, rb_intern("@seed"), seed);
  return self;
}

/* CArray::Rng#rand — one draw in [0.0, 1.0), the state advanced.
 *
 * Named as Ruby names it: `Random#rand` with no argument is a float in
 * [0.0, 1.0), and this is the same thing from a different generator.
 *
 * It is the same draw `random!` takes for one cell, and the same one a
 * kernel's `random(rng:)` takes, because all three run the code in
 * ca_rng_xoshiro256pp.h. */
static VALUE
rb_ca_rng_rand (VALUE self)
{
  CArray *ca;
  int64_t *cells;
  double value;

  ca = ca_rng_cells(self, &cells);
  value = ca_xoshiro256pp_next_real(cells);
  ca_sync(ca);
  ca_detach(ca);
  return rb_float_new(value);
}

/* CArray::Rng#bits — the same draw as the generator's raw 64 bits.
 *
 * Not a bounded draw and not Ruby's `rand(n)`: it is the word the
 * generator produced, before it was turned into a double.  What that is
 * for is checking this generator against the sequence its authors
 * published, which is the one question `#rand` cannot answer. */
static VALUE
rb_ca_rng_bits (VALUE self)
{
  CArray *ca;
  int64_t *cells;
  uint64_t value;

  ca = ca_rng_cells(self, &cells);
  value = ca_xoshiro256pp_next(cells);
  ca_sync(ca);
  ca_detach(ca);
  return ULL2NUM(value);
}

static VALUE
rb_ca_rng_inspect (VALUE self)
{
  return rb_sprintf("#<CArray::Rng %"PRIsVALUE" seed=%"PRIsVALUE">",
                    rb_ivar_get(self, rb_intern("@generator")),
                    rb_ivar_get(self, rb_intern("@seed")));
}

/* ---- Init -------------------------------------------------------------- */

void
Init_carray_random (void)
{
  rb_cCARng = rb_define_class_under(rb_cCArray, "Rng", rb_cObject);
  rb_define_method(rb_cCARng, "initialize", rb_ca_rng_initialize, -1);
  rb_define_method(rb_cCARng, "reset",      rb_ca_rng_reset,      -1);
  rb_define_method(rb_cCARng, "rand",       rb_ca_rng_rand,        0);
  rb_define_method(rb_cCARng, "bits",       rb_ca_rng_bits,        0);
  rb_define_method(rb_cCARng, "inspect",    rb_ca_rng_inspect,     0);
  rb_define_attr(rb_cCARng, "generator", 1, 0);
  rb_define_attr(rb_cCARng, "state",     1, 0);
  rb_define_attr(rb_cCARng, "seed",      1, 0);

  rb_define_method(rb_cCArray, "random!",  rb_ca_random_bang,  -1);
  rb_define_method(rb_cCArray, "randomn!", rb_ca_randomn_bang, -1);
  rb_define_method(rb_cCArray, "shuffle!", rb_ca_shuffle_bang, -1);

  rb_define_method(rb_cCArray, "random",   rb_ca_random,  -1);
  rb_define_method(rb_cCArray, "randomn",  rb_ca_randomn, -1);
  rb_define_method(rb_cCArray, "shuffle",  rb_ca_shuffle,  -1);
}
