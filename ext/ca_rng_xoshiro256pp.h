/* ---------------------------------------------------------------------------

   ca_rng_xoshiro256pp.h -- the xoshiro256++ generator, as text

   This file is not a header in the usual sense.  It carries no include
   guard and includes nothing, because it is read two ways:

     - ext/carray_random.c #includes it, and the extension compiles it.
       That is what `CArray#random!(rng: r)` runs.

     - CArray::Rng::SOURCE[:xoshiro256pp] is this file's text, read at
       runtime.  carray-jit pastes it into the translation unit it
       generates for a kernel, beside its own `static inline` helpers.
       That is what a kernel's `random(rng:)` runs.

   One text, so the two cannot drift: a kernel that draws after
   `random!` continues the same sequence because it is running the same
   code, not because two implementations were checked against each
   other.  Anything added here has to stay pasteable -- `static inline`,
   no directives, and nothing beyond <stdint.h>, which both sides have.

   xoshiro256++ 1.0 by David Blackman and Sebastiano Vigna, released to
   the public domain (https://prng.di.unimi.it/xoshiro256plusplus.c).
   The state is seeded through splitmix64, as its authors prescribe.

   The state is held as int64_t[4] rather than uint64_t[4] so that it is
   a plain CA_INT64 array a caller can look at.  C says an object may be
   read through the corresponding signed or unsigned type, so the cast
   below is the language's own allowance and not a reinterpretation.

   --------------------------------------------------------------------------- */

/* splitmix64: the state seeder.  A single 64-bit seed is a poor state
   for xoshiro on its own -- an all-but-zero state takes many draws to
   escape -- so the seed is stretched through a generator whose output
   is well mixed from the first call. */
static inline uint64_t
ca_splitmix64_next (uint64_t *x)
{
  uint64_t z = (*x += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}

/* Fill a state from one seed. */
static inline void
ca_xoshiro256pp_seed (int64_t *s, uint64_t seed)
{
  uint64_t *u = (uint64_t *) s;
  uint64_t x = seed;
  u[0] = ca_splitmix64_next(&x);
  u[1] = ca_splitmix64_next(&x);
  u[2] = ca_splitmix64_next(&x);
  u[3] = ca_splitmix64_next(&x);
}

static inline uint64_t
ca_xoshiro256pp_rotl (uint64_t x, int k)
{
  return (x << k) | (x >> (64 - k));
}

/* One draw: 64 random bits, the state advanced. */
static inline uint64_t
ca_xoshiro256pp_next (int64_t *s)
{
  uint64_t *u = (uint64_t *) s;
  const uint64_t result = ca_xoshiro256pp_rotl(u[0] + u[3], 23) + u[0];
  const uint64_t t = u[1] << 17;

  u[2] ^= u[0];
  u[3] ^= u[1];
  u[1] ^= u[2];
  u[0] ^= u[3];
  u[2] ^= t;
  u[3] = ca_xoshiro256pp_rotl(u[3], 45);

  return result;
}

/* A double in [0, 1).  The top 53 bits are the ones taken: that is the
   whole mantissa, so no two draws collide merely because the generator
   handed back fewer bits than a double can hold. */
static inline double
ca_xoshiro256pp_next_real (int64_t *s)
{
  return (double) (ca_xoshiro256pp_next(s) >> 11) * 0x1.0p-53;
}

/* One standard normal, which is two draws.  ca_rng_normal is what turns
   them into one, and it is in a file of its own because it belongs to no
   generator.

   The two draws are taken into locals rather than written as two
   arguments: C does not say which order a call's arguments are
   evaluated in, and these two are not interchangeable -- they advance a
   state. */
static inline double
ca_xoshiro256pp_next_normal (int64_t *s)
{
  const double u1 = ca_xoshiro256pp_next_real(s);
  const double u2 = ca_xoshiro256pp_next_real(s);
  return ca_rng_normal(u1, u2);
}
