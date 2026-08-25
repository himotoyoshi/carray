/* ---------------------------------------------------------------------------

  CAMath module functions whose semantics are not a 1-arg/1-arg
  numeric kernel (= multi-input / multi-output cartesian conversions,
  hand-written lgamma).  Single-arg numeric ops (deg_360 / rad_pi /
  atan2 / hypot / expm1 / etc.) live in ext/mkkernel.rb and are
  registered via Init_carray_kernels.

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include <math.h>

#ifdef HAVE_TGMATH_H
#include <tgmath.h>
#endif

/* ----------------------------------------------------------------------- */

static void
mathfunc_sph_to_xyz (void *p0, void *p1, void *p2, void *p3, void *p4, void *p5)
{
  double r = *(double*)p3, theta = *(double*)p4, phi = *(double*)p5;
  *(double*) p0 = r * sin(theta) * cos(phi);
  *(double*) p1 = r * sin(theta) * sin(phi);
  *(double*) p2 = r * cos(theta);
}

static VALUE 
rb_camath_sph_to_xyz (VALUE mod, VALUE rx1, VALUE rx2, VALUE rx3)
{
  return ca_call_cfunc_3_3(CA_DOUBLE, CA_DOUBLE, CA_DOUBLE, CA_DOUBLE, CA_DOUBLE, CA_DOUBLE,
                             mathfunc_sph_to_xyz, rx1, rx2, rx3);
}

/* ----------------------------------------------------------------------- */

static void
mathfunc_xyz_to_sph (void *p0, void *p1, void *p2, void *p3, void *p4, void *p5)
{
#ifdef HAVE_ATAN2
  double x = *(double*)p3, y = *(double*)p4, z = *(double*)p5;
  double r;
  *(double*) p0 = r = sqrt(x*x+y*y+z*z);
  *(double*) p1 = acos(z/r);
  *(double*) p2 = atan2(y, x);
#else
  rb_raise(rb_eRuntimeError, "atan2 is not defined");
#endif
}

static VALUE 
rb_camath_xyz_to_sph (VALUE mod, VALUE rx1, VALUE rx2, VALUE rx3)
{
  return ca_call_cfunc_3_3(CA_DOUBLE, CA_DOUBLE, CA_DOUBLE, CA_DOUBLE, CA_DOUBLE, CA_DOUBLE,
                             mathfunc_xyz_to_sph, rx1, rx2, rx3);
}

/* ----------------------------------------------------------------------- */

/* [MOVED] atan2 / hypot / expm1 -> ext/mkkernel.rb (binop / monfunc
   tables); their CAMath wrappers live in lib/carray/math.rb.  lgamma
   stays hand-written here because no mkkernel slot exists for it. */

static void
mathfunc_lgamma (void *p0, void *p1)
{
#ifdef HAVE_LGAMMA
  *(double *)p0 = lgamma(*(double*)p1);
#else
  rb_raise(rb_eRuntimeError, "lgamma is not defined ");
#endif
}

static VALUE
rb_camath_lgamma (VALUE mod, VALUE rx1)
{
  return ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_lgamma, rx1);
}

void
Init_carray_mathfunc (void)
{
  rb_define_module_function(rb_mCAMath, "spherical_to_xyz", rb_camath_sph_to_xyz, 3);
  rb_define_module_function(rb_mCAMath, "xyz_to_spherical", rb_camath_xyz_to_sph, 3);
  rb_define_module_function(rb_mCAMath, "lgamma",            rb_camath_lgamma,    1);
}
