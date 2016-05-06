/* ---------------------------------------------------------------------------

  carray/carray_calculus.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include <math.h>
#include <float.h>

/* ----------------------------------------------------------------- */

static double
simpson (double *x, double *y, int n)
{
  double s;

  if ( n < 2 ) {
    return 0.0/0.0;
  }
  else if ( n == 2 ) {
    s = (x[1]-x[0])*(y[1]+y[0])*0.5;
    return s;
  }
  else if ( n % 2 == 0 ) {
    double x0, x1, x2, x3;
    double h, m, a1, a2, c0, c1, c2, c3;
    x0 = x[0];
    x1 = x[1];
    x2 = x[2];
    x3 = x[3];
    h  = x3 - x0;
    m  = (x3 + x0)/2;
    a1 = x1 - m;
    a2 = x2 - m;
    c0 = 1.0 + 2.0*a1*a2/((x0-x1)*(x0-x2));
    c1 =       h*h*a2/((x1-x2)*(x1-x0)*(x1-x3));
    c2 =       h*h*a1/((x2-x1)*(x2-x0)*(x2-x3));
    c3 = 1.0 + 2.0*a1*a2/((x3-x1)*(x3-x2));
    s  = (c0*y[0]+c1*y[1]+c2*y[2]+c3*y[3])*h/6.0;
    if ( n > 4 ) {
      s += simpson(x+3, y+3, n-3);
    }
    return s;
  }
  else {
    double x0, x1, x2;
    double h, m, c0, c1, c2;
    int i;
    s = 0.0;
    for (i=0; i<n-2; i+=2) {
      x0 = x[i];
      x1 = x[i+1];
      x2 = x[i+2];
      h = x2-x0;
      m = 0.5*(x2+x0);
      c0 = 3.0 - h/(x1-x0);
      c1 =       h*(x2-x0)/((x2-x1)*(x1-x0));
      c2 = 3.0 - h/(x2-x1);
      s += (c0*y[i]+c1*y[i+1]+c2*y[i+2])*h/6.0;
    }
    return s;
  }
}

static VALUE
rb_ca_integrate (volatile VALUE self, volatile VALUE vsc)
{
  CArray *sc, *ca;
  double ans;

  ca = ca_wrap_readonly(self, CA_DOUBLE);
  sc = ca_wrap_readonly(vsc, CA_DOUBLE);

  if ( ca->elements != sc->elements ) {
    rb_raise(rb_eRuntimeError, "data num mismatch");
  }

  if ( ca_is_any_masked(ca) || ca_is_any_masked(sc) ) {
    rb_raise(rb_eRuntimeError,
             "can't calculate integrattion when masked elements exist");
  }

  ca_attach_n(2, ca, sc);

  ans = simpson((double*)sc->ptr, (double*)ca->ptr, ca->elements);

  ca_detach_n(2, ca, sc);

  return rb_float_new(ans);
}


/* ----------------------------------------------------------------- */

static int
linear_index (int n, double *y, double yy, double *idx)
{
  int   a, b, c, x1;
  double ya, yb, yc;
  double y1, y2;
  double rest;

  if ( yy <= y[0] ) {
    x1 = 0;
    goto found;
  }

  if ( yy >= y[n-1] ) {
    x1 = n-2;
    goto found;
  }

  /* check for equally spaced scale */

  a = (int)((yy-y[0])/(y[n-1]-y[0])*(n-1));

  if ( a >= 0 && a < n-1 ) {
    if ( (y[a] - yy) * (y[a+1] - yy) <= 0 ) { /* lucky case */
      x1 = a;
      goto found; 
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

 found:

  y1 = y[x1];
  y2 = y[x1+1];
  rest = (yy-y1)/(y2-y1);

  if ( fabs(y2-yy)/fabs(y2) < DBL_EPSILON*100 ) {
    *idx = (double) (x1 + 1);
  }
  else if ( fabs(y1-yy)/fabs(y1) < DBL_EPSILON*100 ) {
    *idx = (double) x1;
  }
  else {
    *idx = rest + (double) x1;
  }

  return 0;
}

static VALUE
rb_ca_binary_search_linear_index (volatile VALUE self, volatile VALUE vx)
{
  volatile VALUE out, out0;
  CArray *ca, *sc, *cx, *co0, *co;
  int32_t n;
  double *x;
  double *px;
  double *po;
  int i;

  Data_Get_Struct(self, CArray, ca);

  if ( rb_ca_is_any_masked(self) ) {
    rb_raise(rb_eRuntimeError, "self should not have any masked elements");
  }

  sc = ca_wrap_readonly(self, CA_FLOAT64);
  cx = ca_wrap_readonly(vx, CA_FLOAT64);

  co0 = carray_new(ca->data_type, cx->rank, cx->dim, 0, NULL);
  out = out0 = ca_wrap_struct(co0);
  co = ca_wrap_writable(out, CA_FLOAT64);

  ca_attach_n(3, sc, cx, co);

  n = sc->elements;
  x  = (double*) sc->ptr;
  px = (double*) cx->ptr;
  po = (double*) co->ptr;

  ca_update_mask(cx);
  if ( cx->mask ) {
    boolean8_t *mx, *mo;
    ca_create_mask(co);
    mx = (boolean8_t *) cx->mask->ptr;
    mo = (boolean8_t *) co->mask->ptr;
    for (i=0; i<cx->elements; i++) {
      if ( ! *mx ) {
        linear_index(n, x, *px, po);
      }
      else {
        *mo = 1;
      }
      mx++; mo++; px++, po++;
    }
  }
  else {
    for (i=0; i<cx->elements; i++) {
      linear_index(n, x, *px, po);
      px++, po++;
    }
  }

  ca_sync(co);
  ca_detach_n(3, sc, cx, co);

  if ( rb_ca_is_scalar(vx) ) {
    return rb_funcall(out0, rb_intern("[]"), 1, INT2FIX(0));
  }
  else {
    return out0;
  }
}

static double
interp_lin (double *x, double *y, double xx)
{
  double a, b;
  double xa, xb;
  double ab;
  double fa, fb;
  a = x[0];
  b = x[1];
  fa = y[0];
  fb = y[1];
  xa = xx - a;
  xb = xx - b;
  ab = a - b;
  return -xa*fb/ab + xb*fa/ab;
}

static double
deriv_lin (double *x, double *y, double xx)
{
  double a, b;
  double ab;
  double fa, fb;
  a = x[0];
  b = x[1];
  fa = y[0];
  fb = y[1];
  ab = a - b;
  return -fb/ab + fa/ab;
}

static double
interp_qual (double *x, double *y, double xx)
{
  double a, b, c;
  double xa, xb, xc;
  double ab, bc, ca;
  double fa, fb, fc;
  a  = x[0];
  b  = x[1];
  c  = x[2];
  fa = y[0];
  fb = y[1];
  fc = y[2];
  xa = xx - a;
  xb = xx - b;
  xc = xx - c;
  ab = a - b;
  bc = b - c;
  ca = c - a;
  return -(xa*xb*fc/ca/bc + xb*xc*fa/ab/ca + xc*xa*fb/bc/ab);
}

static double
deriv_qual (double *x, double *y, double xx)
{
  double a, b, c;
  double xa, xb, xc;
  double ab, bc, ca;
  double fa, fb, fc;
  a  = x[0];
  b  = x[1];
  c  = x[2];
  fa = y[0];
  fb = y[1];
  fc = y[2];
  xa = xx - a;
  xb = xx - b;
  xc = xx - c;
  ab = a - b;
  bc = b - c;
  ca = c - a;
  return - (xa+xb)*fc/ca/bc
         - (xb+xc)*fa/ab/ca
         - (xc+xa)*fb/bc/ab;
}

static double
interp_cubic (double *x, double *y, double xx)
{
  double a, b, c, d;
  double xa, xb, xc, xd;
  double ab, bc, cd, da, db, ac;
  double fa, fb, fc, fd;
  a  = x[0];
  b  = x[1];
  c  = x[2];
  d  = x[3];
  fa = y[0];
  fb = y[1];
  fc = y[2];
  fd = y[3];
  xa = xx - a;
  xb = xx - b;
  xc = xx - c;
  xd = xx - d;
  ab = a - b;
  bc = b - c;
  cd = c - d;
  da = d - a;
  db = d - b;
  ac = a - c;
  return -xa*xb*xc*fd/da/db/cd - xb*xc*xd*fa/ab/ac/da +
      xc*xd*xa*fb/bc/db/ab + xd*xa*xb*fc/cd/ac/bc;
}

static double
deriv_cubic (double *x, double *y, double xx)
{
  double a, b, c, d;
  double xa, xb, xc, xd;
  double ab, bc, cd, da, db, ac;
  double fa, fb, fc, fd;
  a  = x[0];
  b  = x[1];
  c  = x[2];
  d  = x[3];
  fa = y[0];
  fb = y[1];
  fc = y[2];
  fd = y[3];
  xa = xx - a;
  xb = xx - b;
  xc = xx - c;
  xd = xx - d;
  ab = a - b;
  bc = b - c;
  cd = c - d;
  da = d - a;
  db = d - b;
  ac = a - c;
  return - (xb*xc+xa*xc+xa*xb)*fd/da/db/cd
         - (xc*xd+xb*xd+xb*xc)*fa/ab/ac/da
         + (xd*xa+xc*xa+xc*xd)*fb/bc/db/ab
         + (xa*xb+xd*xb+xd*xa)*fc/cd/ac/bc;
}

static double
interp_penta (double *x, double *y, double xx)
{
  double a, b, c, d, e, f;
  double xa, xb, xc, xd, xe, xf;
  double ya, yb, yc, yd, ye, yf;
  double ab, ac, ad, ae, af;
  double     bc, bd, be, bf;
  double         cd, ce, cf;
  double             de, df;
  double                 ef;
  a  = x[0];
  b  = x[1];
  c  = x[2];
  d  = x[3];
  e  = x[4];
  f  = x[5];
  ya = y[0];
  yb = y[1];
  yc = y[2];
  yd = y[3];
  ye = y[4];
  yf = y[5];
  xa = xx - a;
  xb = xx - b;
  xc = xx - c;
  xd = xx - d;
  xe = xx - e;
  xf = xx - f;
  ab = a - b;
  ac = a - c;
  ad = a - d;  
  ae = a - e;  
  af = a - f;  
  bc = b - c;
  bd = b - d;
  be = b - e;
  bf = b - f;
  cd = c - d;
  ce = c - e;
  cf = c - f;
  de = d - e;
  df = d - f;
  ef = e - f;
  return   ya*xb*xc*xd*xe*xf/(ab*ac*ad*ae*af)
         - xa*yb*xc*xd*xe*xf/(ab*bc*bd*be*bf)   
         + xa*xb*yc*xd*xe*xf/(ac*bc*cd*ce*cf) 
         - xa*xb*xc*yd*xe*xf/(ad*bd*cd*de*df) 
         + xa*xb*xc*xd*ye*xf/(ae*be*ce*de*ef)        
         - xa*xb*xc*xd*xe*yf/(af*bf*cf*df*ef);        
}


static double
deriv_penta (double *x, double *y, double xx)
{
  double a, b, c, d, e, f;
  double xa, xb, xc, xd, xe, xf;
  double ya, yb, yc, yd, ye, yf;
  double ab, ac, ad, ae, af;
  double     bc, bd, be, bf;
  double         cd, ce, cf;
  double             de, df;
  double                 ef;
  a  = x[0];
  b  = x[1];
  c  = x[2];
  d  = x[3];
  e  = x[4];
  f  = x[5];
  ya = y[0];
  yb = y[1];
  yc = y[2];
  yd = y[3];
  ye = y[4];
  yf = y[5];
  xa = xx - a;
  xb = xx - b;
  xc = xx - c;
  xd = xx - d;
  xe = xx - e;
  xf = xx - f;
  ab = a - b;
  ac = a - c;
  ad = a - d;  
  ae = a - e;  
  af = a - f;  
  bc = b - c;
  bd = b - d;
  be = b - e;
  bf = b - f;
  cd = c - d;
  ce = c - e;
  cf = c - f;
  de = d - e;
  df = d - f;
  ef = e - f;
  return   (xc*xd*xe*xf+xb*xd*xe*xf+xb*xc*xe*xf+xb*xc*xd*xf+xb*xc*xd*xe)*ya/(ab*ac*ad*ae*af)
         - (xc*xd*xe*xf+xa*xd*xe*xf+xa*xc*xe*xf+xa*xc*xd*xf+xa*xc*xd*xe)*yb/(ab*bc*bd*be*bf)   
         + (xb*xd*xe*xf+xa*xd*xe*xf+xa*xb*xe*xf+xa*xb*xd*xf+xa*xb*xd*xe)*yc/(ac*bc*cd*ce*cf) 
         - (xb*xc*xe*xf+xa*xc*xe*xf+xa*xb*xe*xf+xa*xb*xc*xf+xa*xb*xc*xe)*yd/(ad*bd*cd*de*df) 
         + (xb*xc*xd*xf+xa*xc*xd*xf+xa*xb*xd*xf+xa*xb*xc*xf+xa*xb*xc*xd)*ye/(ae*be*ce*de*ef)        
         - (xb*xc*xd*xe+xa*xc*xd*xe+xa*xb*xd*xe+xa*xb*xc*xe+xa*xb*xc*xd)*yf/(af*bf*cf*df*ef);        
}

static double
interpolate_linear (double *x, double *y, int n, double xx)
{
  double ri;
  int i0;
  if ( n == 1) {
    return y[0];
  }
  if ( xx == x[0] ) {
    return y[0];
  }
  if ( xx == x[1] ) {
    return y[1];
  }
  if ( n == 2 ) {
    return interp_lin(x, y, xx);
  }
  linear_index(n, x, xx, &ri);
  i0 = floor(ri);
  if ( i0 <= 0 ) {
    i0 = 0;
  }
  else if ( i0 + 1 >= n - 1 ) {
    i0 = n - 2;
  }
  return interp_lin(&x[i0], &y[i0], xx);
}

static double
interpolate_cubic (double *x, double *y, int n, double xx)
{
  double ri;
  int i0;
  if ( n == 1) {
    return y[0];
  }
  if ( xx == x[0] ) {
    return y[0];
  }
  if ( xx == x[1] ) {
    return y[1];
  }
  if ( xx == x[2] ) {
    return y[2];
  }
  if ( n == 2 ) {
    return interp_lin(x, y, xx);
  }
  if ( n == 3 ) {
    return interp_qual(x, y, xx);
  }
  linear_index(n, x, xx, &ri);
  i0 = floor(ri) - 1;
  if ( i0 <= 0 ) {
    i0 = 0;
  }
  else if ( i0 + 3 >= n - 1 ) {
    i0 = n - 4;
  }
  return interp_cubic(&x[i0], &y[i0], xx);
}

static double
differentiate (double *x, double *y, int n, double xx)
{
  double ri;
  int i0;
  switch ( n ) {
  case 1:
    return 0.0/0.0;
  case 2:    
    return deriv_lin(x, y, xx);
  case 3:
    return deriv_qual(x, y, xx);    
  case 4:
    return deriv_cubic(x, y, xx);    
  }
  linear_index(n, x, xx, &ri);
  i0 = floor(ri) - 1;
  if ( i0 <= 0 ) {
    i0 = 0;
  }
  else if ( n == 5 && i0 + 4 > n - 1 ) {
    i0 = n - 5;
  }
  else if ( i0 + 5 > n - 1 ) {
    i0 = n - 6;
  }
  if ( n == 5 ) {
    return deriv_cubic(&x[i0], &y[i0], xx);
  }
  else {
    return deriv_penta(&x[i0], &y[i0], xx);    
  }
}

static VALUE
rb_ca_interpolate (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rval = self;
  volatile VALUE vsc, vx, ropt, rtype = Qnil, out0, out;
  CArray *ca, *sc, *cv, *cx, *co0, *co;
  char *typename = NULL;
  int type = 0;
  double *px, *po;
  int32_t i;

  Data_Get_Struct(self, CArray, ca);

  rb_scan_args(argc, argv, "21", &vsc, &vx, &ropt);
  rb_scan_options(ropt, "type", &rtype);

  if ( ! NIL_P(rtype) ) {
    Check_Type(rtype, T_STRING);
    typename = StringValuePtr(rtype);
  }


  if ( typename == NULL || ! strncmp("cubic", typename, 5) ) {
    type = 3;
  }
  else if ( ! strncmp("linear", typename, 6) ) {
    type = 1;
  }
  else {
    volatile VALUE inspect = rb_inspect(rtype);
    rb_raise(rb_eRuntimeError, 
             "invalid interpolation type <%s>", StringValuePtr(inspect));
  }

  cv = ca_wrap_readonly(rval, CA_DOUBLE);
  sc = ca_wrap_readonly(vsc,  CA_DOUBLE);

  if ( ca_is_any_masked(cv) || ca_is_any_masked(sc) ) {
    rb_raise(rb_eRuntimeError,
             "can't calculate interpolation when masked elements exist");
  }

  if ( cv->elements != sc->elements ) {
    rb_raise(rb_eRuntimeError, "data num mismatch with scale");
  }

  cx = ca_wrap_readonly(vx,   CA_DOUBLE);

  co0 = carray_new(ca->data_type, cx->rank, cx->dim, 0, NULL);
  out = out0 = ca_wrap_struct(co0);
  co = ca_wrap_writable(out, CA_DOUBLE);

  ca_attach_n(4, cv, sc, cx, co);

  px = (double*) cx->ptr;
  po = (double*) co->ptr;

  ca_update_mask(cx);
  if ( cx->mask ) {
    boolean8_t *mx, *mo;
    ca_create_mask(co);
    mx = (boolean8_t *) cx->mask->ptr;
    mo = (boolean8_t *) co->mask->ptr;
    if ( type == 3 ) {
      for (i=0; i<cx->elements; i++) {
        if ( ! *mx ) {
          *po = interpolate_cubic((double*)sc->ptr, (double*)cv->ptr, 
                                  cv->elements, *px);
        }
        else {
          *mo = 1;
        }
        mx++; mo++; po++; px++;
      }
    }
    else {
      for (i=0; i<cx->elements; i++) {
        if ( ! *mx ) {
          *po = interpolate_linear((double*)sc->ptr, (double*)cv->ptr, 
                                   cv->elements, *px);
        }
        else {
          *mo = 1;
        }
        mx++; mo++; po++; px++;
      }
    }
  }
  else {
    if ( type == 3 ) {
      for (i=0; i<cx->elements; i++) {
        *po++ = interpolate_cubic((double*)sc->ptr, (double*)cv->ptr, 
                                  cv->elements, *px++);
      }
    }
    else {
      for (i=0; i<cx->elements; i++) {
        *po++ = interpolate_linear((double*)sc->ptr, (double*)cv->ptr, 
                                   cv->elements, *px++);
      }
    }
  }

  ca_sync(co);
  ca_detach_n(4, cv, sc, cx, co);

  if ( rb_ca_is_scalar(vx) ) {
    return rb_funcall(out0, rb_intern("[]"), 1, INT2FIX(0));
  }
  else {
    return out0;
  }
}

static VALUE
rb_ca_differentiate (volatile VALUE self,
                     volatile VALUE vsc, volatile VALUE vx)
{
  volatile VALUE rval = self;
  volatile VALUE out0, out;
  CArray *ca, *cv, *sc, *cx, *co0, *co;
  double *px, *po;
  int32_t i;

  Data_Get_Struct(self, CArray, ca);

  cv = ca_wrap_readonly(rval, CA_DOUBLE);
  sc = ca_wrap_readonly(vsc,  CA_DOUBLE);

  if ( ca_is_any_masked(cv) || ca_is_any_masked(sc) ) {
    rb_raise(rb_eRuntimeError,
             "can't calculate differentiation when masked elements exist");
  }

  if ( cv->elements != sc->elements ) {
    rb_raise(rb_eRuntimeError, "data num mismatch with scale");
  }

  cx = ca_wrap_readonly(vx,   CA_DOUBLE);

  co0 = carray_new(ca->data_type, cx->rank, cx->dim, 0, NULL);
  out = out0 = ca_wrap_struct(co0);
  co = ca_wrap_writable(out, CA_DOUBLE);

  ca_attach_n(4, cv, sc, cx, co);

  px = (double*) cx->ptr;
  po = (double*) co->ptr;

  ca_update_mask(cx);
  if ( cx->mask ) {
    boolean8_t *mx, *mo;
    ca_create_mask(co);
    mx = (boolean8_t *) cx->mask->ptr;
    mo = (boolean8_t *) co->mask->ptr;
    for (i=0; i<cx->elements; i++) {
      if ( ! *mx ) {
        *po = differentiate((double*)sc->ptr, (double*)ca->ptr, 
                            ca->elements, *px);
      }
      else {
        *mo = 1;
      }
      mx++; mo++; px++, po++;
    }
  }
  else {
    for (i=0; i<cx->elements; i++) {
      *po = differentiate((double*)sc->ptr, (double*)ca->ptr, 
                          ca->elements, *px);
      px++, po++;
    }
  }

  ca_sync(co);
  ca_detach_n(4, cv, sc, cx, co);

  if ( rb_ca_is_scalar(vx) ) {
    return rb_funcall(out0, rb_intern("[]"), 1, INT2FIX(0));
  }
  else {
    return out0;
  }
}

void
Init_carray_interpolate ();

void
Init_carray_calculus ()
{
  rb_define_method(rb_cCArray,  "section",
                   rb_ca_binary_search_linear_index, 1);
  rb_define_method(rb_cCArray,  "integrate",    rb_ca_integrate, 1);
  rb_define_method(rb_cCArray,  "interpolate",  rb_ca_interpolate, -1);
  rb_define_method(rb_cCArray,  "differentiate", rb_ca_differentiate, 2);

  Init_carray_interpolate();
}
