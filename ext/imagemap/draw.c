/* ---------------------------------------------------------------------------

  carray/draw.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"
#include <math.h>

#define ca_ptr_1d(ap, i)      \
  ca_ptr_at_addr((ap), (i))
#define ca_ptr_2d(ap, i, j)   \
  ca_ptr_at_addr((ap), ((CArray*)(ap))->dim[1]*(i) + (j))
#define ca_ptr_3d(ap, i, j, k)    \
  ca_ptr_at_addr(ap,            \
   ((CArray*)(ap))->dim[2]*( ((CArray*)(ap))->dim[1]*(i) + (j) ) + (k))

#define ca_ref_1d(type, ap, i)      \
  (*(type*) ca_ptr_at_addr((ap), (i)))
#define ca_ref_2d(type, ap, i, j)   \
  (*(type*) ca_ptr_at_addr((ap), ((CArray*)(ap))->dim[1]*(i) + (j)))
#define ca_ref_3d(type, ap, i, j, k)    \
  (*(type*) ca_ptr_at_addr(ap,            \
   ((CArray*)(ap))->dim[2]*( ((CArray*)(ap))->dim[1]*(i) + (j) ) + (k)))


#define ROUND(x) (int)(((x)>0) ? floor((x)+0.5) : ((x)<0) ? ceil((x)-0.5) : 0)
#define FLOOR(x) (int)(floor((float)x)+0.5)
#define CEIL(x)  (int)(ceil((float)x)+0.5)

enum { is=0, ib=1 };

void
draw_hline (CArray *image, int iy, float x0, float x1, char *ptr)
{
  int ix;

  if ( iy < 0 || iy >= image->dim[0] ) 
    return;

  for (ix=FLOOR(x0); ix<=FLOOR(x1); ix++) {
    if ( ix >= 0 && ix < image->dim[1] ) {
      memcpy(ca_ptr_2d(image, iy, ix), ptr, image->bytes);
    }
  }
}

void
fill_triangle (CArray *image, float y[3], float x[3], char *ptr)
{
  int imin, imid, imax;
  float xmin, xmax;
  float ax[2], x0[2], xt[2], y0;
  int iy;
  int il, ir, pass1;
  int i;

  imin = imid = imax = 0;
  xmin = xmax = x[0];

  for (i=1; i<3; i++) {
    if ( y[i] <= y[imin] ) {
      imid = imin;
      imin = i;
    }
    else if ( y[i] >= y[imax] ) {
      imid = imax;
      imax = i;
    }
    else
      imid = i;

    if ( x[i] <= xmin )
      xmin = x[i];
    else if ( x[i] >= x[imax] )
      xmax = x[i];
  }

  if ( y[imid] != y[imin] ) {
    ax[is] = (x[imax] - x[imin])/(y[imax] - y[imin]);
    ax[ib] = (x[imid] - x[imin])/(y[imid] - y[imin]);
    if ( ax[is] < ax[ib] ) {
      il = is;
      ir = ib;
    }
    else {
      il = ib;
      ir = is;
    }
  }
  else {
    if ( x[imin] < x[imid] ) {
      il = is;
      ir = ib;
    }
    else {
      il = ib;
      ir = is;
    }
  }

  /* --------------------------------------------------------
  iy = FLOOR(y[imin]);
  draw_hline(image, iy, x[imin], x[imin], ptr);
  ---------------------------------------------------------- */

  pass1 = 0;

  if ( FLOOR(y[imid]) != FLOOR(y[imin]) ) {

    ax[is] = (x[imax] - x[imin])/(y[imax] - y[imin]);
    ax[ib] = (x[imid] - x[imin])/(y[imid] - y[imin]);
    x0[is] = x[imin];
    x0[ib] = x[imin];
    y0     = y[imin];

    iy = CEIL(y[imin]);
    while ( iy <= FLOOR(y[imid]) ) {
      xt[is] = ax[is]*((float)iy-y0)+x0[is];
      xt[ib] = ax[ib]*((float)iy-y0)+x0[ib];
      draw_hline(image, iy, xt[il], xt[ir], ptr);
      iy += 1;
      pass1 = 1;
    }

  }

  if ( FLOOR(y[imax]) != FLOOR(y[imid]) ) {

    ax[is] = (x[imax] - x[imin])/(y[imax] - y[imin]);
    ax[ib] = (x[imax] - x[imid])/(y[imax] - y[imid]);
    x0[is] = ax[is]*(y[imid]-y[imin])+x[imin];
    x0[ib] = x[imid];
    y0     = y[imid];

    /* --------------------------------------------------------
    if ( pass1 ) {
      iy = FLOOR(y[imid]);
      xt[is] = ax[is]*(iy-y0)+x0[is];
      xt[ib] = x0[ib];
      draw_hline(image, iy, xt[il], xt[ir], ptr);
    }
    ---------------------------------------------------------- */

    iy = FLOOR(y[imid]);
    xt[is] = x0[is];
    xt[ib] = x0[ib];
    draw_hline(image, iy, xt[il], xt[ir], ptr);

    iy = CEIL(y[imid]);
    while ( iy <= FLOOR(y[imax]) ) {
      xt[is] = ax[is]*(iy-y0)+x0[is];
      xt[ib] = ax[ib]*(iy-y0)+x0[ib];
      draw_hline(image, iy, xt[il], xt[ir], ptr);
      iy += 1;
    }

  }

  /* --------------------------------------------------------
  iy = FLOOR(y[imax]);
  draw_hline_gradation(image, iy, x[imax], x[imax], z[imax], z[imax]);
  ---------------------------------------------------------- */
}

void
fill_rectangle (CArray *image, float y[4], float x[4], char *ptr)
{
  float yt[3], xt[3], xmin, xmax, ymin, ymax;
  int i;

  xmin = x[0];
  xmax = x[0];
  ymin = y[0];
  ymax = y[0];

  for (i=0; i<4; i++) {
    if ( ! ( isfinite(y[i]) && isfinite(x[i]) ) ) 
      return;
    if ( x[i] < xmin )
      xmin = x[i];
    else if ( x[i] > xmax )
      xmax = x[i];
    if ( y[i] < ymin )
      ymin = y[i];
    else if ( y[i] > ymax )
      ymax = y[i];
  }

  if ( ymin >= image->dim[0] || ymax < 0 )
    return;

  if ( xmin >= image->dim[1] || xmax < 0 )
    return;

  yt[0] = y[0]; yt[1] = y[1]; yt[2] = y[3];
  xt[0] = x[0]; xt[1] = x[1]; xt[2] = x[3];
  fill_triangle(image, yt, xt, ptr);
  yt[0] = y[0]; yt[1] = y[2]; yt[2] = y[3];
  xt[0] = x[0]; xt[1] = x[2]; xt[2] = x[3];
  fill_triangle(image, yt, xt, ptr);
}

void
fill_rectangle_image (CArray *image, CArray *cy, CArray *cx, CArray *cv)
{
  float by[4], bx[4];
  int i,j;
  
  for (i=0; i<cv->dim[0]; i++)
    for (j=0; j<cv->dim[1]; j++) {
      by[0] = ca_ref_2d(float, cy, i, j);
      by[1] = ca_ref_2d(float, cy, i, j+1);
      by[2] = ca_ref_2d(float, cy, i+1, j);
      by[3] = ca_ref_2d(float, cy, i+1, j+1);
      bx[0] = ca_ref_2d(float, cx, i, j);
      bx[1] = ca_ref_2d(float, cx, i, j+1);
      bx[2] = ca_ref_2d(float, cx, i+1, j);
      bx[3] = ca_ref_2d(float, cx, i+1, j+1);
      fill_rectangle(image, by, bx, ca_ptr_2d(cv, i, j));
    }
}

void
fill_rectangle_grid (CArray *image, CArray *cy, CArray *cx, CArray *cv)
{
  float by[4], bx[4], bv[4], mean;
  int i,j;
  char *val;

  val = ALLOC_N(char, cv->bytes);
  
  for (i=0; i<cv->dim[0]-1; i++) {
    for (j=0; j<cv->dim[1]-1; j++) {
      by[0] = ca_ref_2d(float, cy, i, j);
      by[1] = ca_ref_2d(float, cy, i, j+1);
      by[2] = ca_ref_2d(float, cy, i+1, j);
      by[3] = ca_ref_2d(float, cy, i+1, j+1);
      bx[0] = ca_ref_2d(float, cx, i, j);
      bx[1] = ca_ref_2d(float, cx, i, j+1);
      bx[2] = ca_ref_2d(float, cx, i+1, j);
      bx[3] = ca_ref_2d(float, cx, i+1, j+1);
      ca_ptr2val(cv, ca_ptr_2d(cv, i, j), CA_FLOAT, &bv[0]);
      ca_ptr2val(cv, ca_ptr_2d(cv, i, j+1), CA_FLOAT, &bv[1]);
      ca_ptr2val(cv, ca_ptr_2d(cv, i+1, j), CA_FLOAT, &bv[2]);
      ca_ptr2val(cv, ca_ptr_2d(cv, i+1, j+1), CA_FLOAT, &bv[3]);
      mean = (bv[0] + bv[1] + bv[2] + bv[3])/4.0;
      ca_val2ptr(CA_FLOAT, &mean, cv, val);
      fill_rectangle(image, by, bx, val);
    }
  }
  free(val);
}

/* ----------------------------------------------------------------- */

void
draw_hline_gradation (CArray *image, int iy, 
                     float x0, float x1, float z0, float z1)
{
  int ix;
  float az, gz;

  if ( iy < 0 || iy >= image->dim[0] ) {
    return;
  }

  ix = FLOOR(x0);
  if ( ix >= 0 && ix < image->dim[1] ) {
    ca_val2ptr(CA_FLOAT, &z0, image, ca_ptr_2d(image, iy, ix));
  }

  if ( x1 != x0 ) {
    az = (z1-z0)/(x1-x0);
    ix = CEIL(x0);
    while ( ix <= FLOOR(x1) ) {
      gz = az * (ix - x0) + z0;
      if ( ix >= 0 && ix < image->dim[1] ) {
        ca_val2ptr(CA_FLOAT, &gz, image, ca_ptr_2d(image, iy, ix));
      }
      ix += 1;
    }
  }

  ix = FLOOR(x1);
  if ( ix >= 0 && ix < image->dim[1] ) {
    ca_val2ptr(CA_FLOAT, &z1, image, ca_ptr_2d(image, iy, ix));
  }
}

void
draw_triangle_gradation (CArray *image, float y[3], float x[3], float z[3])
{
  int imin, imid, imax;
  float xmin, xmax;
  float ax[2], az[2], x0[2], z0[2], xt[2], zt[2], y0;
  int iy;
  int il, ir, pass1;
  int i;

  imin = imid = imax = 0;
  xmin = xmax = x[0];

  for (i=1; i<3; i++) {
    if ( y[i] <= y[imin] ) {
      imid = imin;
      imin = i;
    }
    else if ( y[i] >= y[imax] ) {
      imid = imax;
      imax = i;
    }
    else
      imid = i;

    if ( x[i] <= xmin )
      xmin = x[i];
    else if ( x[i] >= x[imax] )
      xmax = x[i];
  }

  if ( y[imid] != y[imin] ) {

    ax[is]  = (x[imax] - x[imin])/(y[imax] - y[imin]);
    ax[ib]  = (x[imid] - x[imin])/(y[imid] - y[imin]);

    if ( ax[is] < ax[ib] ) {
      il = is;
      ir = ib;
    }
    else {
      il = ib;
      ir = is;
    }
  }
  else {
    if ( x[imin] < x[imid] ) {
      il = is;
      ir = ib;
    }
    else {
      il = ib;
      ir = is;
    }
  }

  /* --------------------------------------------------------
  iy = FLOOR(y[imin]);
  draw_hline_gradation(image, iy, x[imin], x[imin], z[imin], z[imin]);
  ---------------------------------------------------------- */

  pass1 = 0;

  if ( FLOOR(y[imid]) != FLOOR(y[imin]) ) {

    ax[is] = (x[imax] - x[imin])/(y[imax] - y[imin]);
    ax[ib] = (x[imid] - x[imin])/(y[imid] - y[imin]);
    az[is] = (z[imax] - z[imin])/(y[imax] - y[imin]);
    az[ib] = (z[imid] - z[imin])/(y[imid] - y[imin]);
    x0[is] = x[imin];
    x0[ib] = x[imin];
    z0[is] = z[imin];
    z0[ib] = z[imin];
    y0     = y[imin];

    iy = CEIL(y[imin]);
    while ( iy <= FLOOR(y[imid]) ) {
      xt[is] = ax[is]*((float)iy-y0)+x0[is];
      xt[ib] = ax[ib]*((float)iy-y0)+x0[ib];
      zt[is] = az[is]*((float)iy-y0)+z0[is];
      zt[ib] = az[ib]*((float)iy-y0)+z0[ib];
      draw_hline_gradation(image, iy, xt[il], xt[ir], zt[il], zt[ir]);
      iy += 1;
      pass1 = 1;
    }

  }

  if ( FLOOR(y[imax]) != FLOOR(y[imid]) ) {

    ax[is] = (x[imax] - x[imin])/(y[imax] - y[imin]);
    ax[ib] = (x[imax] - x[imid])/(y[imax] - y[imid]);
    az[is] = (z[imax] - z[imin])/(y[imax] - y[imin]);
    az[ib] = (z[imax] - z[imid])/(y[imax] - y[imid]);
    x0[is] = ax[is]*(y[imid]-y[imin])+x[imin];
    x0[ib] = x[imid];
    z0[is] = az[is]*(y[imid]-y[imin])+z[imin];
    z0[ib] = z[imid];
    y0     = y[imid];

    /* --------------------------------------------------------
    if ( pass1 ) {
      iy = FLOOR(y[imid]);
      xt[is] = ax[is]*(iy-y0)+x0[is];
      xt[ib] = x0[ib];
      zt[is] = az[is]*(iy-y0)+z0[is];
      zt[ib] = z0[ib];
      draw_hline_gradation(image, iy, xt[il], xt[ir], zt[il], zt[ir]);
    }
    ---------------------------------------------------------- */

    iy = FLOOR(y[imid]);
    xt[is] = x0[is];
    xt[ib] = x0[ib];
    zt[is] = z0[is];
    zt[ib] = z0[ib];
    draw_hline_gradation(image, iy, xt[il], xt[ir], zt[il], zt[ir]);

    iy = CEIL(y[imid]);
    while ( iy <= FLOOR(y[imax]) ) {
      xt[is] = ax[is]*(iy-y0)+x0[is];
      xt[ib] = ax[ib]*(iy-y0)+x0[ib];
      zt[is] = az[is]*(iy-y0)+z0[is];
      zt[ib] = az[ib]*(iy-y0)+z0[ib];
      draw_hline_gradation(image, iy, xt[il], xt[ir], zt[il], zt[ir]);
      iy += 1;
    }

  }

  /* --------------------------------------------------------
  iy = FLOOR(y[imax]);
  draw_hline_gradation(image, iy, x[imax], x[imax], z[imax], z[imax]);
  ---------------------------------------------------------- */
}

#include <math.h>

void
draw_rectangle_gradation (CArray *image, float y[4], float x[4], float z[4])
{
  float yt[3], xt[3], zt[3], xmin, xmax, ymin, ymax;
  float y0, x0, z0;
  int i;

  xmin = x[0];
  xmax = x[0];
  ymin = y[0];
  ymax = y[0];

  y0 = x0 = z0 = 0;
  for (i=0; i<4; i++) {
    if ( x[i] < xmin )
      xmin = x[i];
    else if ( x[i] > xmax )
      xmax = x[i];
    if ( y[i] < ymin )
      ymin = y[i];
    else if ( y[i] > ymax )
      ymax = y[i];
    y0 += y[i]; x0 += x[i]; z0 += z[i];
  }

  if ( ymin >= image->dim[0] || ymax < 0 )
    return;

  if ( xmin >= image->dim[1] || xmax < 0 )
    return;

  if ( ! ( isfinite(y0) && isfinite(x0) ) )
    return;

  y0 /= 4.0; x0 /= 4.0; z0 /= 4.0;

  yt[0] = y0; xt[0] = x0; zt[0] = z0;

  yt[1] = y[0]; yt[2] = y[1];
  xt[1] = x[0]; xt[2] = x[1];
  zt[1] = z[0]; zt[2] = z[1];
  draw_triangle_gradation(image, yt, xt, zt);
  yt[1] = y[3]; 
  xt[1] = x[3]; 
  zt[1] = z[3]; 
  draw_triangle_gradation(image, yt, xt, zt);
  yt[2] = y[2];
  xt[2] = x[2];
  zt[2] = z[2];
  draw_triangle_gradation(image, yt, xt, zt);
  yt[1] = y[0]; 
  xt[1] = x[0]; 
  zt[1] = z[0]; 
  draw_triangle_gradation(image, yt, xt, zt);

}

void
draw_rectangle_gradation_grid (CArray *image, 
                               CArray *cy, CArray *cx, CArray *cz)
{
  float by[4], bx[4], bz[4];
  int i,j;
  
  for (i=0; i<cz->dim[0]-1; i++) {
    for (j=0; j<cz->dim[1]-1; j++) {
      by[0] = ca_ref_2d(float, cy, i, j);
      by[1] = ca_ref_2d(float, cy, i, j+1);
      by[2] = ca_ref_2d(float, cy, i+1, j);
      by[3] = ca_ref_2d(float, cy, i+1, j+1);
      bx[0] = ca_ref_2d(float, cx, i, j);
      bx[1] = ca_ref_2d(float, cx, i, j+1);
      bx[2] = ca_ref_2d(float, cx, i+1, j);
      bx[3] = ca_ref_2d(float, cx, i+1, j+1);
      ca_ptr2val(cz, ca_ptr_2d(cz, i, j), CA_FLOAT, &bz[0]);
      ca_ptr2val(cz, ca_ptr_2d(cz, i, j+1), CA_FLOAT, &bz[1]);
      ca_ptr2val(cz, ca_ptr_2d(cz, i+1, j), CA_FLOAT, &bz[2]);
      ca_ptr2val(cz, ca_ptr_2d(cz, i+1, j+1), CA_FLOAT, &bz[3]);
      draw_rectangle_gradation(image, by, bx, bz);
    }
  }
}

void
draw_points (CArray *image, 
             CArray *cy, CArray *cx, CArray *cz)
{
  float y, x;
  int32_t iy, ix;
  int32_t i,j;

  ca_check_type(cz, image->data_type);
  ca_check_same_shape (cz, cy);
  ca_check_same_shape (cz, cx);

  for (i=0; i<cz->dim[0]; i++)
    for (j=0; j<cz->dim[1]; j++) {
      y = ca_ref_2d(float, cy, i, j);
      x = ca_ref_2d(float, cx, i, j);
      iy = ROUND(y);
      ix = ROUND(x);
      if ( ix < 0 || ix >= image->dim[1] ||
           iy < 0 || iy >= image->dim[0] )
        continue;
      memcpy(ca_ptr_2d(image, iy, ix), ca_ptr_2d(cz, i, j), image->bytes);
    }
}

void
draw_line (CArray *ca, float y0, float x0, float y1, float x1, char *ptr);

void
draw_polyline (CArray *image, 
               CArray *cy, CArray *cx, char *ptr)
{
  float y1, x1, y2, x2;
  int32_t i;

  ca_check_same_shape (cx, cy);

  y1 = *(float *) ca_ptr_at_addr(cy, 0);
  x1 = *(float *) ca_ptr_at_addr(cx, 0);

  for (i=1; i<cx->elements; i++) {
    y2 = *(float *) ca_ptr_at_addr(cy, i);
    x2 = *(float *) ca_ptr_at_addr(cx, i);
    draw_line(image, y1, x1, y2, x2, ptr);
    y1 = y2;
    x1 = x2;
  }

}

