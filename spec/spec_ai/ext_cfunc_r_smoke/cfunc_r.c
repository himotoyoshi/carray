/* spec_ai/ext_cfunc_r_smoke/cfunc_r.c
 *
 * TEST FIXTURE — byte-for-byte mirror of samples/c-extensions/cfunc_r/cfunc_r.c
 * (the user-facing runnable example).  Kept here so the spec_ai suite owns
 * its own build and never reaches into samples/.  If you edit one, edit both
 * (the samples copy is documentation; this copy is the regression fixture).
 */
/* ---------------------------------------------------------------------------
 *
 *  cfunc_r.c -- ca_call_cfunc_*_r usage example
 *
 *  PROPOSAL_L0_AUTHOR_SURFACE §6.2.  Demonstrates the reentrant cfunc
 *  variants (`ca_call_cfunc_M_N_r`) that thread a `void *userdata`
 *  pointer to every per-cell callback.  Idiomatic alternative to
 *  file-static / global state when porting kernels that carry outer
 *  context (= PROJ-style transformations, configurable scales, running
 *  counters, ...).
 *
 *  Build:    ruby extconf.rb && make
 *  Run:      ruby example.rb
 *
 *  --------------------------------------------------------------------------- */

#include "carray.h"

/* User-data struct: scale factor + threshold + mutable per-cell hit count.
   No file-static; the thunk carries everything. */
typedef struct {
  double  scale;
  double  threshold;
  size_t  hit_count;
} ud_t;

/* (1) 1-in 1-out kernel: y = x * scale.  Verifies basic _r plumbing. */
static void
kernel_1_1 (void *p_y, void *p_x, void *userdata)
{
  ud_t *ud = (ud_t *) userdata;
  *(double *) p_y = *(double *) p_x * ud->scale;
}

static VALUE
demo_cfunc_r_1_1 (VALUE self, VALUE r_x, VALUE r_scale)
{
  ud_t ud = { NUM2DBL(r_scale), 0.0, 0 };
  return ca_call_cfunc_1_1_r(CA_DOUBLE, CA_DOUBLE,
                              kernel_1_1, r_x, &ud);
}

/* (2) 2-in 2-out kernel: y = a*scale, x = b*scale; if a > threshold,
       bump hit_count.  Shows that userdata can be MUTATED across cells. */
static void
kernel_2_2 (void *p_y, void *p_x, void *p_a, void *p_b, void *userdata)
{
  ud_t *ud = (ud_t *) userdata;
  double a = *(double *) p_a;
  double b = *(double *) p_b;
  *(double *) p_y = a * ud->scale;
  *(double *) p_x = b * ud->scale;
  if (a > ud->threshold) ud->hit_count++;
}

static VALUE
demo_cfunc_r_2_2 (VALUE self, VALUE r_a, VALUE r_b,
                  VALUE r_scale, VALUE r_threshold)
{
  ud_t ud = { NUM2DBL(r_scale), NUM2DBL(r_threshold), 0 };
  VALUE result = ca_call_cfunc_2_2_r(CA_DOUBLE, CA_DOUBLE,
                                      CA_DOUBLE, CA_DOUBLE,
                                      kernel_2_2,
                                      r_a, r_b, &ud);
  /* Return [outputs, hit_count] so callers can inspect mutated state. */
  return rb_ary_new3(2, result, LONG2NUM((long) ud.hit_count));
}

void
Init_cfunc_r (void)
{
  rb_define_singleton_method(rb_cCArray,
      "demo_cfunc_r_1_1", demo_cfunc_r_1_1, 2);
  rb_define_singleton_method(rb_cCArray,
      "demo_cfunc_r_2_2", demo_cfunc_r_2_2, 4);
}
