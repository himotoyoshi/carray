/* ---------------------------------------------------------------------------

   ca_rng_normal.h -- uniform to standard normal, as text

   Read the two ways ca_rng_xoshiro256pp.h is read: compiled into this
   extension, and handed out through CArray::Rng::COMMON_SOURCE for
   another gem to paste.  The same rules apply -- no include guard,
   nothing beyond <math.h>, `static inline` only.

   Separate from any generator's file because it belongs to none of
   them: it takes two uniforms and gives a normal, whichever generator
   the uniforms came from.  Whoever pastes it pastes it once however
   many generators are drawing, which is why it is not simply repeated
   inside each generator's text.

   --------------------------------------------------------------------------- */

/* One standard normal from two uniforms in [0.0, 1.0), by Box-Muller.
 *
 * Exactly two, always.  The classical form takes two uniforms and gives
 * two normals, and keeping the second would make the cost one uniform
 * apiece -- but the spare has to live somewhere between calls, and the
 * place it would live is the generator's state.  A kernel draws one
 * number per cell and `CArray#random!` fills whole arrays, so a spare
 * held across that boundary is a second kind of state to keep in step,
 * on top of the one this design exists to keep in step.  Two uniforms
 * and no spare costs an extra draw, at about a nanosecond, and buys a
 * rule with nothing behind it: one normal is two draws, wherever it is
 * taken.
 *
 * `1.0 - u1` rather than `u1`, so the argument to log is in (0.0, 1.0]
 * and never zero.  Redrawing on a zero -- which is what the paired form
 * does -- would make the number of uniforms per normal depend on the
 * draw, and then "where is this generator" has no answer that can be
 * worked out rather than run. */
static inline double
ca_rng_normal (double u1, double u2)
{
  const double radius = sqrt(-2.0 * log(1.0 - u1));
  const double theta = 2.0 * M_PI * u2;
  return radius * cos(theta);
}
