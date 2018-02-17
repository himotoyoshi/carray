/* ---------------------------------------------------------------------------

  carray/carray_fortio.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include <math.h>

static int
read_F (char *buf, int buflen, int scale, int length, int prec, double *a)
{
  char fmt[128];
  int status;
  if ( ! strchr(buf, '.') ) {
    int tmp = 0;
    snprintf(fmt, 128, "%%%i", length);
    status = sscanf(buf, fmt, &tmp);
    *a = tmp * pow(10, -prec);
  }
  else {
    snprintf(fmt, 128, "%%%i.%if", length, prec);     
    status = sscanf(buf, fmt, a);
  }
  return status;
}

static VALUE
rb_ff_read_F (VALUE mod, VALUE vbuffer, VALUE vscale, VALUE vlength, VALUE vprec)
{
  double val;
  int status;
  status = read_F(StringValuePtr(vbuffer), (int) RSTRING_LEN(vbuffer),
                  NUM2INT(vscale), NUM2INT(vlength), NUM2INT(vprec), &val);
  if ( ! status ) {
    rb_raise(rb_eRuntimeError, "invalid string for F descriptor");
  }
  return rb_float_new(val);
}

static int
write_F (char *buf, int buflen, int plus, int scale, int length, int prec, double a)
{
  char fmt[128];
  if ( plus ) {
    snprintf(fmt, 128, "%%+%i.%if", length, prec);
  }
  else {
    snprintf(fmt, 128, "%%%i.%if", length, prec);
  }
  if ( scale == 0 ) {
    return snprintf(buf, buflen, fmt, a);
  }
  else {
    return snprintf(buf, buflen, fmt, a * pow(10, scale));
  }
}

static VALUE
rb_ff_write_F (VALUE mod, VALUE vsign, VALUE vscale, VALUE vlength, VALUE vprec, VALUE va)
{
  int length = NUM2INT(vlength);
  char buf[256];
  if ( length > 255 ) {
    rb_raise(rb_eRuntimeError, "too long decimal format for FortranFormat");
  }
  write_F(buf, 255, 
             RTEST(vsign), NUM2INT(vscale), length, NUM2INT(vprec),  NUM2DBL(va));
  return rb_str_new2(buf);
}


static int
write_E (char *buf, int buflen, int plus, int scale, int length, int prec, int iexp, double a)
{
  char fmt[128];
  int prec0;
  int e, sign = 1;
  prec0 = ( 1 - scale < 0 ) ? prec - scale + 1 : prec;
  sign = 1;
  if ( a < 0 ) {
    e = floor(log10(-a))+1;
    sign = -1;
  }
  if ( a > 0 ) {
    e = floor(log10(a))+1;      
  }
  else {
    e = 0;
  }
  if ( prec0 == 0 ) {
    if ( plus ) {
      snprintf(fmt, 128, "%%+%i.0f.E%%+0%ii", length-iexp-3, iexp+1);
    }
    else {
      snprintf(fmt, 128, "%%%i.0f.E%%+0%ii", length-iexp-3, iexp+1);
    }
  }
  else {
    if ( plus ) {
      snprintf(fmt, 128, "%%+%i.%ifE%%+0%ii", length-iexp-2, prec0, iexp+1);
    }
    else {
      snprintf(fmt, 128, "%%%i.%ifE%%+0%ii", length-iexp-2, prec0, iexp+1);
    }
  }
  return snprintf(buf, buflen, fmt, sign * a * pow(10,scale-e), e-scale);
}

static VALUE
rb_ff_write_E (VALUE mod, VALUE vsign, VALUE vscale, VALUE vlength, VALUE vprec, VALUE vexp, VALUE va)
{
  int length = NUM2INT(vlength);
  int iexp   = NIL_P(vexp) ? 2 : NUM2INT(vexp);
  char buf[256];
  if ( length > 255 ) {
    rb_raise(rb_eRuntimeError, "too long decimal format for FortranFormat");
  }
  write_E(buf, 255, 
             RTEST(vsign), NUM2INT(vscale), length, NUM2INT(vprec), iexp, NUM2DBL(va));
  return rb_str_new2(buf);
}

static int
write_GF (char *buf, int buflen, int plus, int length, int prec, int iexp, double a)
{
  int e;
  if ( a < 0 ) {
    e = floor(log10(-a))+1;
  }
  if ( a > 0 ) {
    e = floor(log10(a))+1;      
  }
  else {
    e = 0;
  }
  write_E(buf, 255, plus, e, length, prec-1, iexp, a);
  memset(buf+(length-iexp-2), ' ', iexp+2);
  return 1;
}

static VALUE
rb_ff_write_G (VALUE mod, VALUE vsign, VALUE vscale, VALUE vlength, VALUE vprec, VALUE vexp, VALUE va)
{
  int length = NUM2INT(vlength);
  int iprec  = NUM2INT(vprec);
  int iexp   = NIL_P(vexp) ? 2 : NUM2INT(vexp);
  double val = NUM2DBL(va);
  char buf[256];
  if ( length > 255 ) {
    rb_raise(rb_eRuntimeError, "too long decimal format for FortranFormat");
  }
  if ( ( fabs(val) <= 0.1 ) ||
       ( fabs(val) >= pow(10, iprec) ) ) {
    write_E(buf, 255, 
            RTEST(vsign), NUM2INT(vscale), length, iprec, iexp, val);
  }
  else {
    write_GF(buf, 255, RTEST(vsign), length, iprec, iexp, val);
  }
  return rb_str_new2(buf);
}

void
Init_fortio_ext ()
{
  VALUE rb_cFF = rb_define_class("FortranFormat", rb_cObject);
  rb_define_singleton_method(rb_cFF, "read_F",  rb_ff_read_F,  4);
  rb_define_singleton_method(rb_cFF, "write_F", rb_ff_write_F, 5);
  rb_define_singleton_method(rb_cFF, "write_E", rb_ff_write_E, 6);
  rb_define_singleton_method(rb_cFF, "write_G", rb_ff_write_G, 6);
}




