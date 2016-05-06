/* ---------------------------------------------------------------------------

  carray/mathfunc/carray_mathfunc.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include <math.h>

#ifdef HAVE_TGMATH_H
#include <tgmath.h>
#endif

/* ----------------------------------------------------------------------- */

static void
mathfunc_deg_360 (void *p0, void *p1)
{
  double a = *(double*) p1;
  double fa = a / 360.0;
  if ( a >= 0 ) {
    *(double*) p0 = (fa - floor(fa)) * 360.0;
  }
  else {
    *(double*) p0 = (fa - ceil(fa) + 1) * 360.0;
  }
}

static VALUE 
rb_ca_deg_360 (VALUE self)
{
  return ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_deg_360, self);
}

static VALUE 
rb_ca_deg_360_bang (VALUE self)
{
  volatile VALUE out;
  out = ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_deg_360, self);
  rb_funcall(self, rb_intern("[]="), 1, out);
  return self;
}

static VALUE
rb_num_deg_360 (VALUE self)
{
  double v0, v1 = NUM2DBL(self);
  mathfunc_deg_360(&v0, &v1);
  return rb_float_new(v0);
}

/* ----------------------------------------------------------------------- */

static void
mathfunc_deg_180 (void *p0, void *p1)
{
  double a = *(double*) p1, b;
  double fa = (a+180.0) / 360.0;
  if ( a >= 0 ) {
    b = (fa - floor(fa)) * 360.0 - 180;
  }
  else {
    b = (fa - ceil(fa)) * 360.0 - 180;
  }
  if ( b <= -180 ) {
    b += 360.0;
  }
  *(double*) p0 = b;
}

static VALUE 
rb_ca_deg_180 (VALUE self)
{
  return ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_deg_180, self);
}

static VALUE 
rb_ca_deg_180_bang (VALUE self)
{
  volatile VALUE out;
  out = ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_deg_180, self);
  rb_funcall(self, rb_intern("[]="), 1, out);
  return self;
}

static VALUE
rb_num_deg_180 (VALUE self)
{
  double v0, v1 = NUM2DBL(self);
  mathfunc_deg_180(&v0, &v1);
  return rb_float_new(v0);
}

/* ----------------------------------------------------------------------- */

static void
mathfunc_rad_2pi (void *p0, void *p1)
{
  double a = *(double*) p1;
  double fa = a / (2*M_PI);
  if ( a >= 0 ) {
    *(double*) p0 = (fa - floor(fa)) * 2*M_PI;
  }
  else {
    *(double*) p0 = (fa - ceil(fa) + 1) * 2*M_PI;
  }
}

static VALUE 
rb_ca_rad_2pi (VALUE self)
{
  return ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_rad_2pi, self);
}

static VALUE 
rb_ca_rad_2pi_bang (VALUE self)
{
  volatile VALUE out;
  out = ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_rad_2pi, self);
  rb_funcall(self, rb_intern("[]="), 1, out);
  return self;
}

static VALUE
rb_num_rad_2pi (VALUE self)
{
  double v0, v1 = NUM2DBL(self);
  mathfunc_rad_2pi(&v0, &v1);
  return rb_float_new(v0);
}

/* ----------------------------------------------------------------------- */

static void
mathfunc_rad_pi (void *p0, void *p1)
{
  double a = *(double*) p1, b;
  double fa = (a+M_PI) / (2*M_PI);
  if ( a >= 0 ) {
    b = (fa - floor(fa)) * 2*M_PI - M_PI;
  }
  else {
    b = (fa - ceil(fa)) * 2*M_PI - M_PI;
  }
  if ( b <= -M_PI ) {
    b += 2*M_PI;
  }
  *(double*) p0 = b;
}

static VALUE 
rb_ca_rad_pi (VALUE self)
{
  return ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_rad_pi, self);
}

static VALUE 
rb_ca_rad_pi_bang (VALUE self)
{
  volatile VALUE out;
  out = ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_rad_pi, self);
  rb_funcall(self, rb_intern("[]="), 1, out);
  return self;
}

static VALUE
rb_num_rad_pi (VALUE self)
{
  double v0, v1 = NUM2DBL(self);
  mathfunc_rad_pi(&v0, &v1);
  return rb_float_new(v0);
}

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

static void
mathfunc_atan2 (void *p0, void *p1, void *p2)
{
#ifdef HAVE_ATAN2
  *(double*)p0 = atan2(*(double*)p1, *(double*)p2);
#else
  rb_raise(rb_eRuntimeError, "atan2 is not defined");
#endif
}

static VALUE 
rb_camath_atan2 (VALUE mod, VALUE rx1, VALUE rx2)
{
  return ca_call_cfunc_1_2(CA_DOUBLE, CA_DOUBLE, CA_DOUBLE, 
                             mathfunc_atan2, rx1, rx2);
}

/* ----------------------------------------------------------------------- */

static void
mathfunc_hypot (void *p0, void *p1, void *p2)
{
#ifdef HAVE_HYPOT
  *(double *)p0 = hypot(*(double*)p1, *(double*)p2);
#else
  rb_raise(rb_eRuntimeError, "hypot is not defined");
#endif
}

static VALUE 
rb_camath_hypot (VALUE mod, VALUE rx1, VALUE rx2)
{
  return ca_call_cfunc_1_2(CA_DOUBLE, CA_DOUBLE, CA_DOUBLE, 
                             mathfunc_hypot, rx1, rx2);
}

/* ----------------------------------------------------------------------- */

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

/* ----------------------------------------------------------------------- */

static void
mathfunc_expm1 (void *p0, void *p1)
{
#ifdef HAVE_EXP1M
  *(double *)p0 = expm1(*(double*)p1);
#else
  rb_raise(rb_eRuntimeError, "expm1 is not defined ");
#endif
}

static VALUE
rb_camath_expm1 (VALUE mod, VALUE rx1)
{
  return ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE, mathfunc_expm1, rx1);
}

void
Init_carray_mathfunc ()
{
  rb_define_method(rb_cCArray, "deg_360", rb_ca_deg_360, 0);
  rb_define_method(rb_cCArray, "deg_360!", rb_ca_deg_360_bang, 0);
  rb_define_method(rb_cCArray, "deg_180", rb_ca_deg_180, 0);
  rb_define_method(rb_cCArray, "deg_180!", rb_ca_deg_180_bang, 0);
  rb_define_method(rb_cCArray, "rad_2pi", rb_ca_rad_2pi, 0);
  rb_define_method(rb_cCArray, "rad_2pi!", rb_ca_rad_2pi_bang, 0);
  rb_define_method(rb_cCArray, "rad_pi", rb_ca_rad_pi, 0);
  rb_define_method(rb_cCArray, "rad_pi!", rb_ca_rad_pi_bang, 0);

  rb_define_module_function(rb_mCAMath, "spherical_to_xyz", rb_camath_sph_to_xyz, 3);
  rb_define_module_function(rb_mCAMath, "xyz_to_spherical", rb_camath_xyz_to_sph, 3);

  rb_define_module_function(rb_mCAMath, "atan2", rb_camath_atan2, 2);
  rb_define_module_function(rb_mCAMath, "hypot", rb_camath_hypot, 2);

  rb_define_module_function(rb_mCAMath, "lgamma",  rb_camath_lgamma, 1);
  rb_define_module_function(rb_mCAMath, "expm1",   rb_camath_expm1, 1);

  rb_define_method(rb_cNumeric, "deg_360", rb_num_deg_360, 0);
  rb_define_method(rb_cNumeric, "deg_180", rb_num_deg_180, 0);
  rb_define_method(rb_cNumeric, "rad_2pi", rb_num_rad_2pi, 0);
  rb_define_method(rb_cNumeric, "rad_pi", rb_num_rad_pi, 0);
}
