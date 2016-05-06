/* ---------------------------------------------------------------------------

  carray/carray_interp.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include <math.h>

static int
find_index (int n, double *y, double yy, int *major, double *frac)
{
  int   a, b, c, x1;
  double ya, yb, yc;
  double y1, y2;

  if ( yy <= y[0] ) {
    x1 = 0;
    goto label;
  }

  if ( yy >= y[n-1] ) {
    x1 = n-2;
    goto label;
  }

  /* check for equally spaced scale */

  a = (int)((yy-y[0])/(y[n-1]-y[0])*(n-1));

  if ( a >= 0 && a < n-1 ) {
    if ( (y[a] - yy) * (y[a+1] - yy) <= 0 ) {
      x1 = a;
      goto label;
    }
  }

  /* binary section method */

  a = 0;
  b = n-1;

  ya = y[a];
  yb = y[b];

  if ( ya > yb ) {
    return -1; /* input scale array should have accending order */
  }

  while ( (b - a) >= 1 ) {
    c  = (a + b)/2;
    yc = y[c];
    if ( a == c ) {
      break;
    }

    if ( yc == yy ) {
      a = c;
      break;
    }
    else if ( (ya - yy) * (yc - yy) <= 0 ) {
      b = c;
      yb = yc;
    }
    else {
      a = c;
      ya = yc;
    }

    if ( ya > yb ) {
      return -1; /* input scale array should have accending order */
    }
  }

  x1 = a;

 label:

  y1 = y[x1];
  y2 = y[x1+1];

  *major = x1;
  
  if ( y2 - y1 == 0 ) {
    *frac = 0.0;
  }
  else {
    *frac = (yy-y1)/(y2-y1);
  }

  return 0;
}


/*

  n-dimensional linear interpolation

  y[i+fi, j+fj, ..., n+fn]

          1     1         1
     =  Sigma Sigma ... Sigma  wi[si]*wj[sj]*...*wn[sn]*y[i+si,j+sj,...,n+sn]
         si=0  sj=0      sn=0

  i ,  j, ...,  n : major integer value
  fi, fj, ..., fn : fractional value

  wi[0] = 1-fi, wj[0] = 1-fj, ..., wn[0] = 1-fn
  wi[1] = fi,   wj[1] = fj,   ..., wn[1] = fn

*/

static int
linear_interp_loop (CArray *ca, int *major, double *frac,
                    int level, int32_t *idx, double wt, double *valp)
{
  double tmp;

  if ( level == ca->rank-1 ) {

    idx[level] = major[level];
    ca_fetch_index(ca, idx, &tmp);
    *valp += (1.0 - frac[level]) * wt * tmp;

    idx[level] = major[level] + 1;
    ca_fetch_index(ca, idx, &tmp);
    *valp += frac[level] * wt * tmp;

  }
  else {

    if ( frac[level] != 1.0 ) {   /* condition for performance issue */
      idx[level] = major[level];
      linear_interp_loop(ca, major, frac,
                         level+1, idx, (1.0 - frac[level])*wt, valp);
    }

    if ( frac[level] != 0.0 ) {   /* condition for performance issue */
      idx[level] = major[level] + 1;
      linear_interp_loop(ca, major, frac,
                         level+1, idx, frac[level]*wt, valp);
    }

  }

  return 0;
}

static double
linear_interp (CArray *ca, int *major, double *frac)
{
  int32_t idx[CA_RANK_MAX];
  double value = 0;
  linear_interp_loop(ca, major, frac, 0, idx, 1, &value);
  return value;
}

/*

If value[n] is NaN, the interpolation will be made for each index of the dimension n. So you must prepare the buffer sufficient to store these values.

*/

static int
ca_interpolate_loop (CArray *ca, double **scale,
                     CArray **value,
                     int *major, double *frac,
                     int level, double **dstp)
{
  double val, frc;
  int maj;
  int i;
  if ( level == ca->rank-1 ) {
    if ( ! value[level] ) {
      for (i=0; i<ca->dim[level]; i++) {
        major[level] = i;
        frac[level]  = 0.0;
        **dstp = linear_interp(ca, major, frac);
        *dstp += 1;
      }
    }
    else {
      for (i=0; i<value[level]->elements; i++) {
        ca_fetch_addr(value[level], i, &val);
        find_index(ca->dim[level], scale[level], val, &maj, &frc);
        major[level] = maj;
        frac[level]  = frc;
        **dstp = linear_interp(ca, major, frac);
        *dstp += 1;
      }
    }
  }
  else {
    if ( ! value[level] ) {
      for (i=0; i<ca->dim[level]; i++) {
        major[level] = i;
        frac[level]  = 0.0;
        ca_interpolate_loop(ca, scale, value, major, frac, level+1, dstp);
      }
    }
    else {
      for (i=0; i<value[level]->elements; i++) {
        ca_fetch_addr(value[level], i, &val);
        find_index(ca->dim[level], scale[level], val, &maj, &frc);
        major[level] = maj;
        frac[level]  = frc;
        ca_interpolate_loop(ca, scale, value, major, frac, level+1, dstp);
      }
    }
  }
  return 0; /* normal exit */
}

int
ca_interpolate (CArray *ca, double **scale, CArray **value, double *outp)
{
  int major[CA_RANK_MAX];
  double frac[CA_RANK_MAX];
  int status;

  status = ca_interpolate_loop(ca, scale, value, major, frac, 0, &outp);

  return status;
}


static VALUE
rb_ca_interpolate_bilinear (int argc, VALUE *argv, volatile VALUE self)
{
  volatile VALUE vscales, vvalues, vs, out;
  CArray *ca, *co, *cs;
  double *scales[CA_RANK_MAX];
  CArray *values[CA_RANK_MAX];
  CArray *scales_ca[CA_RANK_MAX];
  int32_t out_rank, out_dim[CA_RANK_MAX];
  int i;

  rb_scan_args(argc, argv, "2", &vscales, &vvalues);

  Check_Type(vscales, T_ARRAY);
  Check_Type(vvalues, T_ARRAY);

  if ( RARRAY_LEN(vscales) != RARRAY_LEN(vvalues) ) {
    rb_raise(rb_eArgError, "invalid number of values or scales");
  }

  ca = ca_wrap_readonly(self, CA_DOUBLE);

  if ( ca->rank != RARRAY_LEN(vvalues) ) {
    rb_raise(rb_eArgError, "invalid number of values");
  }

  for (i=0; i<ca->rank; i++) {
    vs = rb_ary_entry(vscales, i);
    if ( NIL_P(vs) ) {
      scales[i] = NULL;
    }
    else {
      cs = ca_wrap_readonly(vs, CA_DOUBLE);
      scales_ca[i] = cs;
      ca_attach(cs);
      scales[i] = (double *) cs->ptr;
      rb_ary_store(vscales, i, vs);
    }
  }

  out_rank = 0;
  for (i=0; i<ca->rank; i++) {
    vs = rb_ary_entry(vvalues, i);
    if ( NIL_P(vs) ) {
      out_dim[out_rank++] = ca->dim[i];
      values[i] = NULL;
    }
    else {
      values[i] = ca_wrap_readonly(vs, CA_DOUBLE);
      if ( values[i]->obj_type != CA_OBJ_SCALAR ) {
        out_dim[out_rank++] = values[i]->elements;
      }
      rb_ary_store(vvalues, i, vs);
    }
  }

  if ( out_rank == 0 ) {
    out = rb_cscalar_new(CA_DOUBLE, 0, NULL);
  }
  else {
    out = rb_carray_new(CA_DOUBLE, out_rank, out_dim, 0, NULL);
  }

  Data_Get_Struct(out, CArray, co);

  for (i=0; i<ca->rank; i++) {
    if ( values[i] ) {
      ca_attach(values[i]);
    }
  }

  ca_attach(ca);
  ca_interpolate(ca, scales, values, (double*) co->ptr);
  ca_detach(ca);

  for (i=0; i<ca->rank; i++) {
    if ( values[i] ) {
      ca_detach(values[i]);
    }
    if ( scales[i] ) {
      ca_detach(scales_ca[i]);
    }
  }

  if ( out_rank == 0 ) {
    return rb_ca_fetch_addr(out, 0);
  }
  else {
    return out;
  }
}

void
Init_carray_interpolate ()
{
  rb_define_method(rb_cCArray, "interp_nd_linear",
                                rb_ca_interpolate_bilinear, -1);
}

/*

  scales = [nil, nil, sza, vza, saz]
  values = [nil, nil,  60,  60, 120]
  brdf.interp_linear_nd(scales, values)

  interp_1d_linear
  interp_1d_parabolic
  interp_1d_cubic
  interp_1d_akima
  interp_1d_akima2
  interp_1d_curv

  interp_2d_natgrid
  interp_2d_fitpack
  interp_nd_linear

  gridding_2d_natgrid


*/


