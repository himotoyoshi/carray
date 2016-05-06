/* ---------------------------------------------------------------------------

  carray/carray_imagemap.c

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

#define CA_REF(ca, i, j) ca_ref_2d(int8_t, (ca), (i), (j))

#define round(x) (int)(((x)>0) ? floor((x)+0.5) : ((x)<0) ? ceil((x)-0.5) : 0)

static void
draw_linex (CArray *ca, float x0, float y0, float x1, float y1, char *ptr)
{
  float x, y;
  int ix, iy;
  int dim0 = ca->dim[0];
  int dim1 = ca->dim[1];
  float a = (y1-y0)/(x1-x0);
  for (x=x0; x<x1; x+=1) {
    y = a*(x-x0)+y0;
    ix = round(x);
    iy = round(y);
    if ( ix < 0 || ix >= dim0 || iy < 0 || iy >= dim1 ) {
      continue;
    }
    memcpy(ca_ptr_2d(ca, ix, iy), ptr, ca->bytes);
  }
}

static void
draw_liney (CArray *ca, float x0, float y0, float x1, float y1, char *ptr)
{
  float x, y;
  int ix, iy;
  int dim0 = ca->dim[0];
  int dim1 = ca->dim[1];
  float a = (x1-x0)/(y1-y0);
  for (y=y0; y<y1; y+=1) {
    x = a*(y-y0)+x0;
    ix = round(x);
    iy = round(y);
    if ( ix < 0 || ix >= dim0 || iy < 0 || iy >= dim1 ) {
      continue;
    }
    memcpy(ca_ptr_2d(ca, ix, iy), ptr, ca->bytes);
  }
}

void
draw_line (CArray *ca, float x0, float y0, float x1, float y1, char *ptr)
{
  if ( fabs(y1-y0) < fabs(x1-x0) ) {
    if ( x1 > x0 ) {
      draw_linex(ca, x0, y0, x1, y1, ptr);
    }
    else if ( x1 < x0 ) {
      draw_linex(ca, x1, y1, x0, y0, ptr);
    }
  }
  else {
    if ( y1 > y0 ) {
      draw_liney(ca, x0, y0, x1, y1, ptr);
    }
    else if ( y1 < y0 ) {
      draw_liney(ca, x1, y1, x0, y0, ptr);
    }
  }
}

static VALUE
rb_img_draw_line (VALUE self, 
                  VALUE vx0, VALUE vy0, VALUE vx1, VALUE vy1, volatile VALUE vz)
{
  CArray *ca, *cz;

  Data_Get_Struct(self, CArray, ca);
  cz = ca_wrap_readonly(vz, ca->data_type);

  ca_attach(ca);

  draw_line(ca, NUM2DBL(vx0), NUM2DBL(vy0), NUM2DBL(vx1), NUM2DBL(vy1), cz->ptr);

  ca_detach(ca);

  return Qnil;
}

/*
  def self.fill_rect2(image, x, y, val)
    xmin, xmax = x.min, x.max
    ymin, ymax = y.min, y.max
    img = CArray.int8(xmax.round-xmin.round+1, ymax.round-ymin.round+1) { 0 }
    if (xmax + img.dim0 >= image.dim0 ) or 
        (xmin < 0 ) or 
        (ymax + img.dim1 >= image.dim1) or 
        (ymin < 0)
      return
    end
    subimg = image[[xmin.round,img.dim0],[ymin.round,img.dim1]]
    gx = x-xmin.round
    gy = y-ymin.round
    img.draw_box(gx, gy)
    img.fill_out()
    subimg[img] = val
  end
*/

static void
fill_rect (CArray *image, float x[4], float y[4], char *ptr)
{
  CArray *mask;
  float xmin, xmax, ymin, ymax;
  float gx[4], gy[4];
  int32_t dim[2];
  int32_t i, j, ixmin, iymin, ixmax, iymax;
  char  one = 1;

  xmin = x[0];
  xmax = x[0];
  ymin = y[0];
  ymax = y[0];

  for (i=1; i<4; i++) {
    if ( isnan(x[i]) || isnan(y[i]) )
      return;
    if ( x[i] < xmin ) {
      xmin = x[i];
    }
    if ( x[i] > xmax ) {
      xmax = x[i];
    }
    if ( y[i] < ymin ) {
      ymin = y[i];
    }
    if ( y[i] > ymax ) {
      ymax = y[i];
    }
  }

  ixmin = (int32_t) floor(xmin);
  iymin = (int32_t) floor(ymin);

  ixmax = (int32_t) ceil(xmax) + 1;
  iymax = (int32_t) ceil(ymax) + 1;

  dim[0] = ixmax - ixmin + 1;
  dim[1] = iymax - iymin + 1;

  mask = carray_new(CA_BOOLEAN, 2, dim, 0, NULL);
  memset(mask->ptr, 0, mask->elements);

  for (i=0; i<4; i++) {
    gx[i] = x[i] - ixmin + 1;
    gy[i] = y[i] - iymin + 1;
  }

  draw_line(mask, gx[0], gy[0], gx[1], gy[1], &one);
  draw_line(mask, gx[1], gy[1], gx[3], gy[3], &one);
  draw_line(mask, gx[3], gy[3], gx[2], gy[2], &one);
  draw_line(mask, gx[2], gy[2], gx[0], gy[0], &one);

  for (i=0; i<dim[0]; i++) {
    for (j=0; j<dim[1]; j++) {
      if ( CA_REF(mask,i,j) ) {
        break;
      }
      CA_REF(mask,i,j) = -1;
    }
    for (j=dim[1]-1; j>=0; j--) {
      if ( CA_REF(mask,i,j) ) {
        break;
      }
      CA_REF(mask,i,j) = -1;
    }
  }

  for (i=0; i<dim[0]; i++) {
    if ( ixmin+i < 0 || ixmin+i >= image->dim[0] )
      continue;
    for (j=0; j<dim[1]; j++) 
      if ( CA_REF(mask,i,j) >= 0 ) {
        if ( iymin+j < 0 || iymin+j >= image->dim[1] ) {
          continue;
        }
        memcpy(ca_ptr_2d(image, ixmin+i, iymin+j), ptr, image->bytes);
      }
  }

  ca_free(mask);
}


static VALUE
rb_im_fill_rect (VALUE self, 
     VALUE vimg, 
     volatile VALUE vx, volatile VALUE vy, volatile VALUE vval)
{
  CArray *image, *val, *cx, *cy;

  Data_Get_Struct(vimg, CArray, image);
  Data_Get_Struct(vx, CArray, cx);
  Data_Get_Struct(vy, CArray, cy);

  cx  = ca_wrap_readonly(vx, CA_FLOAT);
  cy  = ca_wrap_readonly(vy, CA_FLOAT);
  val = ca_wrap_readonly(vval, image->data_type);

  ca_attach_n(3, cx, cy, val);

  fill_rect(image, (float*)cx->ptr, (float*)cy->ptr, val->ptr);

  ca_detach_n(3, cx, cy, val);

  return Qnil;
}

void
draw_hline_gradation (CArray *image, int iy, 
          float x0, float x1, float z0, float z1);

static VALUE
rb_img_draw_hline_gradation (VALUE self, VALUE viy,
           VALUE vx0, VALUE vx1, VALUE vz0, VALUE vz1)
{
  CArray *image;

  Data_Get_Struct(self, CArray, image);

  draw_hline_gradation(image, NUM2INT(viy),
           NUM2DBL(vx0), NUM2DBL(vx1), NUM2DBL(vz0), NUM2DBL(vz1));

  return Qnil;
}

void
draw_triangle_gradation (CArray *image, float y[3], float x[3], float z[3]);

static VALUE
rb_img_draw_triangle_gradation (VALUE self, 
        VALUE vy, VALUE vx, VALUE vz)
{
  CArray *image;
  float y[3], x[3], z[3];
  int i;

  Data_Get_Struct(self, CArray, image);

  for (i=0; i<3; i++) {
    y[i] = NUM2DBL(rb_ary_entry(vy, i));
    x[i] = NUM2DBL(rb_ary_entry(vx, i));
    z[i] = NUM2DBL(rb_ary_entry(vz, i));
  }

  draw_triangle_gradation(image, y, x, z);

  return Qnil;
}

void
fill_rectangle (CArray *image, float y[4], float x[4], char *ptr);

static VALUE
rb_img_fill_rectangle (VALUE self, 
           volatile VALUE vy, volatile VALUE vx, volatile VALUE vz)
{
  CArray *image, *cy, *cx, *cz;

  Data_Get_Struct(self, CArray, image);

  cy = ca_wrap_readonly(vy, CA_FLOAT);
  cx = ca_wrap_readonly(vx, CA_FLOAT);
  cz = ca_wrap_readonly(vz, image->data_type);

  if ( cy->elements != 4 || cx->elements != 4 ) {
    rb_raise(rb_eRuntimeError, "invalid size of y or x");
  }

  ca_attach_n(4, image, cy, cx, cz);

  fill_rectangle(image, (float*)cy->ptr, (float*)cx->ptr, cz->ptr);

  ca_detach_n(4, image, cy, cx, cz);

  return Qnil;
}

void
fill_rectangle_image (CArray *image, CArray *cy, CArray *cx, CArray *cv);

static VALUE
rb_img_fill_rectangle_image (VALUE self, 
          volatile VALUE vy, volatile VALUE vx, volatile VALUE vz)
{
  CArray *image, *cy, *cx, *cz;

  Data_Get_Struct(self, CArray, image);

  cy = ca_wrap_readonly(vy, CA_FLOAT);
  cx = ca_wrap_readonly(vx, CA_FLOAT);
  cz = ca_wrap_readonly(vz, image->data_type);

  ca_attach_n(4, image, cy, cx, cz);

  fill_rectangle_image(image, cy, cx, cz);

  ca_sync(image);

  ca_detach_n(4, image, cy, cx, cz);

  return Qnil;
}

void
fill_rectangle_grid (CArray *image, CArray *cy, CArray *cx, CArray *cv);

static VALUE
rb_img_fill_rectangle_grid (VALUE self, 
     volatile VALUE vy, volatile VALUE vx, volatile VALUE vz)
{
  CArray *image, *cy, *cx, *cz;

  Data_Get_Struct(self, CArray, image);

  cy = ca_wrap_readonly(vy, CA_FLOAT);
  cx = ca_wrap_readonly(vx, CA_FLOAT);
  cz = ca_wrap_readonly(vz, image->data_type);

  ca_attach_n(4, image, cy, cx, cz);

  fill_rectangle_grid(image, cy, cx, cz);

  ca_detach_n(4, image, cy, cx, cz);

  return Qnil;
}

void
draw_rectangle_gradation (CArray *image, float y[4], float x[4], float z[4]);

static VALUE
rb_img_draw_rectangle_gradation (VALUE self, 
          volatile VALUE vy, volatile VALUE vx, volatile VALUE vz)
{
  CArray *image, *cy, *cx, *cz;

  Data_Get_Struct(self, CArray, image);

  cy = ca_wrap_readonly(vy, CA_FLOAT);
  cx = ca_wrap_readonly(vx, CA_FLOAT);
  cz = ca_wrap_readonly(vz, CA_FLOAT);

  if ( cy->elements != 4 || cx->elements != 4 || cz->elements != 4) {
    rb_raise(rb_eRuntimeError, "invalid size of y or x or z");
  }

  ca_attach_n(4, image, cy, cx, cz);

  draw_rectangle_gradation(image, 
         (float*)cy->ptr, (float*)cx->ptr, (float*)cz->ptr);

  ca_detach_n(4, image, cy, cx, cz);

  return Qnil;
}

void
draw_rectangle_gradation_grid (CArray *image, 
             CArray *cy, CArray *cx, CArray *cv);

static VALUE
rb_img_draw_rectangle_gradation_grid (VALUE self, 
                     volatile VALUE vy, volatile VALUE vx, volatile VALUE vz)
{
  CArray *image, *cy, *cx, *cz;

  Data_Get_Struct(self, CArray, image);

  cy = ca_wrap_readonly(vy, CA_FLOAT);
  cx = ca_wrap_readonly(vx, CA_FLOAT);
  cz = ca_wrap_readonly(vz, image->data_type);

  ca_attach_n(4, image, cy, cx, cz);

  draw_rectangle_gradation_grid(image, cy, cx, cz);

  ca_detach_n(4, image, cy, cx, cz);

  return Qnil;
}

void
draw_points (CArray *image, 
       CArray *cy, CArray *cx, CArray *cz);

static VALUE
rb_img_draw_points (VALUE self, 
                    volatile VALUE vy, volatile VALUE vx, volatile VALUE vz)
{
  CArray *image, *cy, *cx, *cz;

  Data_Get_Struct(self, CArray, image);

  cy = ca_wrap_readonly(vy, CA_FLOAT);
  cx = ca_wrap_readonly(vx, CA_FLOAT);
  cz = ca_wrap_readonly(vz, image->data_type);

  ca_attach_n(4, image, cy, cx, cz);

  draw_points(image, cy, cx, cz);

  ca_detach_n(4, image, cy, cx, cz);

  return Qnil;
}

void
draw_polyline (CArray *image, 
         CArray *cy, CArray *cx, char *ptr);

static VALUE
rb_img_draw_polyline (VALUE self, 
          volatile VALUE vy, volatile VALUE vx, volatile VALUE vz)
{
  CArray *image, *cy, *cx, *cz;

  Data_Get_Struct(self, CArray, image);

  cy = ca_wrap_readonly(vy, CA_FLOAT);
  cx = ca_wrap_readonly(vx, CA_FLOAT);
  cz = ca_wrap_readonly(vz, image->data_type);

  ca_attach_n(4, image, cy, cx, cz);

  draw_polyline(image, cy, cx, cz->ptr);

  ca_detach_n(4, image, cy, cx, cz);

  return Qnil;
}

void
Init_carray_imagemap ()
{
  VALUE rb_cImage = rb_const_get(rb_cObject, rb_intern("ImageMap"));
  
  rb_define_singleton_method(rb_cImage, "fill_rect", rb_im_fill_rect, 4);

  rb_define_method(rb_cImage, "fill_rectangle", 
                         rb_img_fill_rectangle, 3);
  rb_define_method(rb_cImage, "fill_rectangle_image", 
                         rb_img_fill_rectangle_image, 3);
  rb_define_method(rb_cImage, "fill_rectangle_grid", 
                         rb_img_fill_rectangle_grid, 3);

  rb_define_method(rb_cImage, "draw_line", rb_img_draw_line, 5);
  rb_define_method(rb_cImage, "draw_hline_gradation", 
                            rb_img_draw_hline_gradation, 5);
  rb_define_method(rb_cImage, "draw_triangle_gradation", 
                         rb_img_draw_triangle_gradation, 3);
  rb_define_method(rb_cImage, "draw_rectangle_gradation", 
                         rb_img_draw_rectangle_gradation, 3);
  rb_define_method(rb_cImage, "draw_rectangle_gradation_grid", 
                       rb_img_draw_rectangle_gradation_grid, 3);

  rb_define_method(rb_cImage, "draw_points", rb_img_draw_points, 3);
  rb_define_method(rb_cImage, "draw_polyline", rb_img_draw_polyline, 3);

}


