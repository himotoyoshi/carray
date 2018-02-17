/* ---------------------------------------------------------------------------

  carray_math_call.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

VALUE
ca_call_cfunc_1 (void (*func)(void *p0), const char *fsync,
                          VALUE rcx0)
{
  CArray *cx0;
  ca_size_t n;

  if ( strlen(fsync) != 1 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] invalid length of fsync arg in rb_ca_call_mathfunc");
  }

  Data_Get_Struct(rcx0, CArray, cx0);

  ca_attach(cx0);

  {
    char      *p0;
    char      *q0;
    ca_size_t    s0;
    ca_size_t    k;
    n = ca_set_iterator(1, cx0, &q0, &s0);
    s0 *= cx0->bytes;
    #ifdef _OPENMP
    #pragma omp parallel for private(p0)
    #endif
    for (k=0; k<n; k++) {
      p0 = q0 + k*s0;
      func(p0);
    }
  }

  ca_sync(cx0);
  ca_detach(cx0);

  return rcx0;
}


VALUE
ca_call_cfunc_2 (void (*func)(void *p0, void *p1), const char *fsync,
                          VALUE rcx0, VALUE rcx1)
{
  CArray *cx0, *cx1;
  boolean8_t *m0 = NULL, *m;
  ca_size_t n;

  if ( strlen(fsync) != 2 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] invalid length of fsync arg in rb_ca_call_mathfunc");
  }

  Data_Get_Struct(rcx0, CArray, cx0);
  Data_Get_Struct(rcx1, CArray, cx1);

  ca_attach_n(2, cx0, cx1);

  {
    CArray *cx[2];
    int i = 0;
    if ( fsync[0] == '0' ) cx[i++] = cx0;
    if ( fsync[1] == '0' ) cx[i++] = cx1;
    m = m0 = ca_allocate_mask_iterator_n(i, cx);
    if ( fsync[0] == '1' ) ca_copy_mask_overwrite_n(cx0, cx0->elements, i, cx);
    if ( fsync[1] == '1' ) ca_copy_mask_overwrite_n(cx1, cx1->elements, i, cx);
  }

  {
    char      *p0, *p1;
    char      *q0, *q1;
    ca_size_t    s0,  s1;
    ca_size_t    k;

    n = ca_set_iterator(2, cx0, &q0, &s0,
                           cx1, &q1, &s1);
    s0 *= cx0->bytes;
    s1 *= cx1->bytes;

    if ( m0 ) {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1)
      #endif
      for (k=0; k<n; k++) {
        m = m0 + k;
        if ( ! *m ) { 
          p0 = q0 + k*s0; 
          p1 = q1 + k*s1;
          func(p0, p1);        
        }
      }
    }
    else {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1)
      #endif
      for (k=0; k<n; k++) {
        p0 = q0 + k*s0; 
        p1 = q1 + k*s1;
        func(p0, p1);        
      }
    }
  }
  if ( fsync[0] == '1' ) ca_sync(cx0);
  if ( fsync[1] == '1' ) ca_sync(cx1);
  ca_detach_n(2, cx0, cx1);

  free(m0);

  return rcx0;
}

VALUE
ca_call_cfunc_3 (void (*func)(void *p0, void *p1, void *p2), const char *fsync,
                          VALUE rcx0, VALUE rcx1, VALUE rcx2)
{
  CArray *cx0, *cx1, *cx2;
  boolean8_t *m0 = NULL, *m;
  ca_size_t n;

  if ( strlen(fsync) != 3 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] invalid length of fsync arg in rb_ca_call_mathfunc");
  }

  Data_Get_Struct(rcx0, CArray, cx0);
  Data_Get_Struct(rcx1, CArray, cx1);
  Data_Get_Struct(rcx2, CArray, cx2);

  ca_attach_n(3, cx0, cx1, cx2);

  {
    CArray *cx[3];
    int i = 0;
    if ( fsync[0] == '0' ) cx[i++] = cx0;
    if ( fsync[1] == '0' ) cx[i++] = cx1;
    if ( fsync[2] == '0' ) cx[i++] = cx2;
    m = m0 = ca_allocate_mask_iterator_n(i, cx);
    if ( fsync[0] == '1' ) ca_copy_mask_overwrite_n(cx0, cx0->elements, i, cx);
    if ( fsync[1] == '1' ) ca_copy_mask_overwrite_n(cx1, cx1->elements, i, cx);
    if ( fsync[2] == '1' ) ca_copy_mask_overwrite_n(cx2, cx2->elements, i, cx);
  }

  {
    char      *p0, *p1, *p2;
    char      *q0, *q1, *q2;
    ca_size_t    s0,  s1,  s2;
    ca_size_t    k;

    n = ca_set_iterator(3, cx0, &q0, &s0,
                           cx1, &q1, &s1,
                           cx2, &q2, &s2);
    s0 *= cx0->bytes;
    s1 *= cx1->bytes;
    s2 *= cx2->bytes;

    if ( m0 ) {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2)
      #endif
      for (k=0; k<n; k++) {
        m = m0 + k;
        if ( ! *m ) { 
          p0 = q0 + k*s0; 
          p1 = q1 + k*s1;
          p2 = q2 + k*s2;
          func(p0, p1, p2);      
        }
      }
    }
    else {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2)
      #endif
      for (k=0; k<n; k++) {
        p0 = q0 + k*s0; 
        p1 = q1 + k*s1;
        p2 = q2 + k*s2;
        func(p0, p1, p2);      
      }
    }
  }
  if ( fsync[0] == '1' ) ca_sync(cx0);
  if ( fsync[1] == '1' ) ca_sync(cx1);
  if ( fsync[2] == '1' ) ca_sync(cx2);
  ca_detach_n(3, cx0, cx1, cx2);

  free(m0);

  return rcx0;
}

VALUE
ca_call_cfunc_4 (void (*func)(void *p0, void *p1, void *p2, void *p3), const char *fsync,
                                            VALUE rcx0, VALUE rcx1, VALUE rcx2, VALUE rcx3)
{
  CArray *cx0, *cx1, *cx2, *cx3;
  boolean8_t *m0 = NULL, *m;
  ca_size_t n;

  if ( strlen(fsync) != 4 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] invalid length of fsync arg in rb_ca_call_mathfunc");
  }

  Data_Get_Struct(rcx0, CArray, cx0);
  Data_Get_Struct(rcx1, CArray, cx1);
  Data_Get_Struct(rcx2, CArray, cx2);
  Data_Get_Struct(rcx3, CArray, cx3);

  ca_attach_n(4, cx0, cx1, cx2, cx3);

  {
    CArray *cx[4];
    int i = 0;
    if ( fsync[0] == '0' ) cx[i++] = cx0;
    if ( fsync[1] == '0' ) cx[i++] = cx1;
    if ( fsync[2] == '0' ) cx[i++] = cx2;
    if ( fsync[3] == '0' ) cx[i++] = cx3;
    m = m0 = ca_allocate_mask_iterator_n(i, cx);
    if ( fsync[0] == '1' ) ca_copy_mask_overwrite_n(cx0, cx0->elements, i, cx);
    if ( fsync[1] == '1' ) ca_copy_mask_overwrite_n(cx1, cx1->elements, i, cx);
    if ( fsync[2] == '1' ) ca_copy_mask_overwrite_n(cx2, cx2->elements, i, cx);
    if ( fsync[3] == '1' ) ca_copy_mask_overwrite_n(cx3, cx3->elements, i, cx);
  }

  {
    char      *p0, *p1, *p2, *p3;
    char      *q0, *q1, *q2, *q3;
    ca_size_t    s0,  s1,  s2,  s3;
    ca_size_t    k;

    n = ca_set_iterator(4, cx0, &q0, &s0,
                           cx1, &q1, &s1,
                           cx2, &q2, &s2,
                           cx3, &q3, &s3);

    s0 *= cx0->bytes;
    s1 *= cx1->bytes;
    s2 *= cx2->bytes;
    s3 *= cx3->bytes;

    if ( m0 ) {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2,p3)
      #endif
      for (k=0; k<n; k++) {
        m = m0 + k;
        if ( ! *m ) { 
          p0 = q0 + k*s0; 
          p1 = q1 + k*s1;
          p2 = q2 + k*s2;
          p3 = q3 + k*s3;
          func(p0, p1, p2, p3);      
        }
      }
    }
    else {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2,p3)
      #endif
      for (k=0; k<n; k++) {
        p0 = q0 + k*s0; 
        p1 = q1 + k*s1;
        p2 = q2 + k*s2;
        p3 = q3 + k*s3;
        func(p0, p1, p2, p3);      
      }
    }
  }
  if ( fsync[0] == '1' ) ca_sync(cx0);
  if ( fsync[1] == '1' ) ca_sync(cx1);
  if ( fsync[2] == '1' ) ca_sync(cx2);
  if ( fsync[3] == '1' ) ca_sync(cx3);
  ca_detach_n(4, cx0, cx1, cx2, cx3);

  free(m0);

  return rcx0;
}

VALUE
ca_call_cfunc_5 (void (*func)(void*,void*,void*,void*,void*), const char *fsync,
                                            VALUE rcx0, VALUE rcx1, VALUE rcx2, VALUE rcx3, VALUE rcx4)
{
  CArray *cx0, *cx1, *cx2, *cx3, *cx4;
  boolean8_t *m0 = NULL, *m;
  ca_size_t n;

  if ( strlen(fsync) != 5 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] invalid length of fsync arg in rb_ca_call_mathfunc");
  }

  Data_Get_Struct(rcx0, CArray, cx0);
  Data_Get_Struct(rcx1, CArray, cx1);
  Data_Get_Struct(rcx2, CArray, cx2);
  Data_Get_Struct(rcx3, CArray, cx3);
  Data_Get_Struct(rcx4, CArray, cx4);

  ca_attach_n(5, cx0, cx1, cx2, cx3, cx4);

  {
    CArray *cx[5];
    int i = 0;
    if ( fsync[0] == '0' ) cx[i++] = cx0;
    if ( fsync[1] == '0' ) cx[i++] = cx1;
    if ( fsync[2] == '0' ) cx[i++] = cx2;
    if ( fsync[3] == '0' ) cx[i++] = cx3;
    if ( fsync[4] == '0' ) cx[i++] = cx4;
    m = m0 = ca_allocate_mask_iterator_n(i, cx);
    if ( fsync[0] == '1' ) ca_copy_mask_overwrite_n(cx0, cx0->elements, i, cx);
    if ( fsync[1] == '1' ) ca_copy_mask_overwrite_n(cx1, cx1->elements, i, cx);
    if ( fsync[2] == '1' ) ca_copy_mask_overwrite_n(cx2, cx2->elements, i, cx);
    if ( fsync[3] == '1' ) ca_copy_mask_overwrite_n(cx3, cx3->elements, i, cx);
    if ( fsync[4] == '1' ) ca_copy_mask_overwrite_n(cx4, cx4->elements, i, cx);
  }

  {
    char      *p0, *p1, *p2, *p3, *p4;
    char      *q0, *q1, *q2, *q3, *q4;
    ca_size_t    s0,  s1,  s2,  s3,  s4;
    ca_size_t    k;

    n = ca_set_iterator(5, cx0, &q0, &s0,
                           cx1, &q1, &s1,
                           cx2, &q2, &s2,
                           cx3, &q3, &s3,
                           cx4, &q4, &s4);

    s0 *= cx0->bytes;
    s1 *= cx1->bytes;
    s2 *= cx2->bytes;
    s3 *= cx3->bytes;
    s4 *= cx4->bytes;

    if ( m0 ) {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2,p3,p4)
      #endif
      for (k=0; k<n; k++) {
        m = m0 + k;
        if ( ! *m ) { 
          p0 = q0 + k*s0; 
          p1 = q1 + k*s1;
          p2 = q2 + k*s2;
          p3 = q3 + k*s3;
          p4 = q4 + k*s4;
          func(p0, p1, p2, p3, p4);      
        }
      }
    }
    else {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2,p3,p4)
      #endif
      for (k=0; k<n; k++) {
        p0 = q0 + k*s0; 
        p1 = q1 + k*s1;
        p2 = q2 + k*s2;
        p3 = q3 + k*s3;
        p4 = q4 + k*s4;
        func(p0, p1, p2, p3, p4);      
      }
    }
  }
  if ( fsync[0] == '1' ) ca_sync(cx0);
  if ( fsync[1] == '1' ) ca_sync(cx1);
  if ( fsync[2] == '1' ) ca_sync(cx2);
  if ( fsync[3] == '1' ) ca_sync(cx3);
  if ( fsync[4] == '1' ) ca_sync(cx4);
  ca_detach_n(5, cx0, cx1, cx2, cx3, cx4);

  free(m0);

  return rcx0;
}

VALUE
ca_call_cfunc_6 (void (*func)(void*,void*,void*,void*,void*,void*), const char *fsync,
                                            VALUE rcx0, VALUE rcx1, VALUE rcx2, VALUE rcx3, VALUE rcx4, VALUE rcx5)
{
  CArray *cx0, *cx1, *cx2, *cx3, *cx4, *cx5;
  boolean8_t *m0 = NULL, *m;
  ca_size_t n;

  if ( strlen(fsync) != 6 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] invalid length of fsync arg in rb_ca_call_mathfunc");
  }

  Data_Get_Struct(rcx0, CArray, cx0);
  Data_Get_Struct(rcx1, CArray, cx1);
  Data_Get_Struct(rcx2, CArray, cx2);
  Data_Get_Struct(rcx3, CArray, cx3);
  Data_Get_Struct(rcx4, CArray, cx4);
  Data_Get_Struct(rcx5, CArray, cx5);

  ca_attach_n(6, cx0, cx1, cx2, cx3, cx4, cx5);

  {
    CArray *cx[6];
    int i = 0;
    if ( fsync[0] == '0' ) cx[i++] = cx0;
    if ( fsync[1] == '0' ) cx[i++] = cx1;
    if ( fsync[2] == '0' ) cx[i++] = cx2;
    if ( fsync[3] == '0' ) cx[i++] = cx3;
    if ( fsync[4] == '0' ) cx[i++] = cx4;
    if ( fsync[5] == '0' ) cx[i++] = cx5;
    m = m0 = ca_allocate_mask_iterator_n(i, cx);
    if ( fsync[0] == '1' ) ca_copy_mask_overwrite_n(cx0, cx0->elements, i, cx);
    if ( fsync[1] == '1' ) ca_copy_mask_overwrite_n(cx1, cx1->elements, i, cx);
    if ( fsync[2] == '1' ) ca_copy_mask_overwrite_n(cx2, cx2->elements, i, cx);
    if ( fsync[3] == '1' ) ca_copy_mask_overwrite_n(cx3, cx3->elements, i, cx);
    if ( fsync[4] == '1' ) ca_copy_mask_overwrite_n(cx4, cx4->elements, i, cx);
    if ( fsync[5] == '1' ) ca_copy_mask_overwrite_n(cx5, cx5->elements, i, cx);
  }

  {
    char      *p0, *p1, *p2, *p3, *p4, *p5;
    char      *q0, *q1, *q2, *q3, *q4, *q5;
    ca_size_t    s0,  s1,  s2,  s3,  s4,  s5;
    ca_size_t    k;

    n = ca_set_iterator(6, cx0, &q0, &s0,
                           cx1, &q1, &s1,
                           cx2, &q2, &s2,
                           cx3, &q3, &s3,
                           cx4, &q4, &s4,
                           cx5, &q5, &s5);

    s0 *= cx0->bytes;
    s1 *= cx1->bytes;
    s2 *= cx2->bytes;
    s3 *= cx3->bytes;
    s4 *= cx4->bytes;
    s5 *= cx5->bytes;

    if ( m0 ) {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2,p3,p4,p5)
      #endif
      for (k=0; k<n; k++) {
        m = m0 + k;
        if ( ! *m ) { 
          p0 = q0 + k*s0; 
          p1 = q1 + k*s1;
          p2 = q2 + k*s2;
          p3 = q3 + k*s3;
          p4 = q4 + k*s4;
          p5 = q5 + k*s5;
          func(p0, p1, p2, p3, p4, p5);      
        }
      }
    }
    else {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2,p3,p4,p5)
      #endif
      for (k=0; k<n; k++) {
        p0 = q0 + k*s0; 
        p1 = q1 + k*s1;
        p2 = q2 + k*s2;
        p3 = q3 + k*s3;
        p4 = q4 + k*s4;
        p5 = q5 + k*s5;
        func(p0, p1, p2, p3, p4, p5);      
      }
    }
  }
  if ( fsync[0] == '1' ) ca_sync(cx0);
  if ( fsync[1] == '1' ) ca_sync(cx1);
  if ( fsync[2] == '1' ) ca_sync(cx2);
  if ( fsync[3] == '1' ) ca_sync(cx3);
  if ( fsync[4] == '1' ) ca_sync(cx4);
  if ( fsync[5] == '1' ) ca_sync(cx5);
  ca_detach_n(6, cx0, cx1, cx2, cx3, cx4, cx5);

  free(m0);

  return rcx0;
}

VALUE
ca_call_cfunc_7 (void (*func)(void*,void*,void*,void*,void*,void*,void*), const char *fsync,
                                            VALUE rcx0, VALUE rcx1, VALUE rcx2, VALUE rcx3, VALUE rcx4, VALUE rcx5, VALUE rcx6)
{
  CArray *cx0, *cx1, *cx2, *cx3, *cx4, *cx5, *cx6;
  boolean8_t *m0 = NULL, *m;
  ca_size_t n;

  if ( strlen(fsync) != 7 ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] invalid length of fsync arg in rb_ca_call_mathfunc");
  }

  Data_Get_Struct(rcx0, CArray, cx0);
  Data_Get_Struct(rcx1, CArray, cx1);
  Data_Get_Struct(rcx2, CArray, cx2);
  Data_Get_Struct(rcx3, CArray, cx3);
  Data_Get_Struct(rcx4, CArray, cx4);
  Data_Get_Struct(rcx5, CArray, cx5);
  Data_Get_Struct(rcx6, CArray, cx6);

  ca_attach_n(7, cx0, cx1, cx2, cx3, cx4, cx5, cx6);

  {
    CArray *cx[7];
    int i = 0;
    if ( fsync[0] == '0' ) cx[i++] = cx0;
    if ( fsync[1] == '0' ) cx[i++] = cx1;
    if ( fsync[2] == '0' ) cx[i++] = cx2;
    if ( fsync[3] == '0' ) cx[i++] = cx3;
    if ( fsync[4] == '0' ) cx[i++] = cx4;
    if ( fsync[5] == '0' ) cx[i++] = cx5;
    if ( fsync[6] == '0' ) cx[i++] = cx6;
    m = m0 = ca_allocate_mask_iterator_n(i, cx);
    if ( fsync[0] == '1' ) ca_copy_mask_overwrite_n(cx0, cx0->elements, i, cx);
    if ( fsync[1] == '1' ) ca_copy_mask_overwrite_n(cx1, cx1->elements, i, cx);
    if ( fsync[2] == '1' ) ca_copy_mask_overwrite_n(cx2, cx2->elements, i, cx);
    if ( fsync[3] == '1' ) ca_copy_mask_overwrite_n(cx3, cx3->elements, i, cx);
    if ( fsync[4] == '1' ) ca_copy_mask_overwrite_n(cx4, cx4->elements, i, cx);
    if ( fsync[5] == '1' ) ca_copy_mask_overwrite_n(cx5, cx5->elements, i, cx);
    if ( fsync[6] == '1' ) ca_copy_mask_overwrite_n(cx6, cx6->elements, i, cx);
  }

  {
    char      *p0, *p1, *p2, *p3, *p4, *p5, *p6;
    char      *q0, *q1, *q2, *q3, *q4, *q5, *q6;
    ca_size_t    s0,  s1,  s2,  s3,  s4,  s5,  s6;
    ca_size_t    k;

    n = ca_set_iterator(7, cx0, &q0, &s0,
                           cx1, &q1, &s1,
                           cx2, &q2, &s2,
                           cx3, &q3, &s3,
                           cx4, &q4, &s4,
                           cx5, &q5, &s5,
                           cx6, &q6, &s6);

    s0 *= cx0->bytes;
    s1 *= cx1->bytes;
    s2 *= cx2->bytes;
    s3 *= cx3->bytes;
    s4 *= cx4->bytes;
    s5 *= cx5->bytes;
    s6 *= cx6->bytes;

    if ( m0 ) {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2,p3,p4,p5,p6)
      #endif
      for (k=0; k<n; k++) {
        m = m0 + k;
        if ( ! *m ) { 
          p0 = q0 + k*s0; 
          p1 = q1 + k*s1;
          p2 = q2 + k*s2;
          p3 = q3 + k*s3;
          p4 = q4 + k*s4;
          p5 = q5 + k*s5;
          p6 = q6 + k*s6;
          func(p0, p1, p2, p3, p4, p5, p6);      
        }
      }
    }
    else {
      #ifdef _OPENMP
      #pragma omp parallel for private(p0,p1,p2,p3,p4,p5,p6)
      #endif
      for (k=0; k<n; k++) {
        p0 = q0 + k*s0; 
        p1 = q1 + k*s1;
        p2 = q2 + k*s2;
        p3 = q3 + k*s3;
        p4 = q4 + k*s4;
        p5 = q5 + k*s5;
        p6 = q6 + k*s6;
        func(p0, p1, p2, p3, p4, p5, p6);      
      }
    }

  }
  if ( fsync[0] == '1' ) ca_sync(cx0);
  if ( fsync[1] == '1' ) ca_sync(cx1);
  if ( fsync[2] == '1' ) ca_sync(cx2);
  if ( fsync[3] == '1' ) ca_sync(cx3);
  if ( fsync[4] == '1' ) ca_sync(cx4);
  if ( fsync[5] == '1' ) ca_sync(cx5);
  if ( fsync[6] == '1' ) ca_sync(cx6);
  ca_detach_n(7, cx0, cx1, cx2, cx3, cx4, cx5, cx6);

  free(m0);

  return rcx0;
}

/* -------------------------------------------------------------------- */

VALUE
ca_call_cfunc_1_1 (int8_t dty, int8_t dtx, 
                     void (*mathfunc)(void*,void*), VALUE rx) 
{ 
  volatile VALUE ry; 
  rx = rb_ca_wrap_readonly(rx, INT2NUM(dtx)); 
  if ( dty != dtx ) {
    ry = rb_ca_template(rb_ca_wrap_readonly(rx, INT2NUM(dty))); 
  }
  else {
    ry = rb_ca_template(rx);
  }
  ca_call_cfunc_2(mathfunc, "10", ry, rx); 
  if ( rb_ca_is_scalar(ry) ) {
    return rb_ca_fetch_addr(ry, 0);
  }
  else {
    return ry;
  }
}

VALUE
ca_call_cfunc_1_2 (int8_t dty, 
                     int8_t dtx1, 
                     int8_t dtx2, 
                     void (*mathfunc)(void*,void*,void*), 
                     volatile VALUE rx1, 
                     volatile VALUE rx2) 
{ 
  volatile VALUE ry = Qnil; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  if ( dty != dtx1 || dty != dtx2 ) {
    ry  = rb_ca_template_n(2,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty))); 
  }
  else {
    ry  = rb_ca_template_n(2, rx1, rx2);
  }
  ca_call_cfunc_3(mathfunc, "100", ry, rx1, rx2); 
  if ( rb_ca_is_scalar(ry) ) {
    return rb_ca_fetch_addr(ry, 0);
  }
  else {
    return ry;
  }
}


VALUE
ca_call_cfunc_1_3 (int8_t dty, 
                     int8_t dtx1, 
                     int8_t dtx2, 
                     int8_t dtx3, 
                     void (*mathfunc)(void*,void*,void*,void*), 
                     volatile VALUE rx1, 
                     volatile VALUE rx2, 
                     volatile VALUE rx3) 
{ 
  volatile VALUE ry; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  rx3 = rb_ca_wrap_readonly(rx3, INT2NUM(dtx3)); 
  ry  = rb_ca_template_n(3,
                         rb_ca_wrap_readonly(rx1, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx2, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx3, INT2NUM(dty))); 
  ca_call_cfunc_4(mathfunc, "1000", ry, rx1, rx2, rx3); 
  if ( rb_ca_is_scalar(ry) ) {
    return rb_ca_fetch_addr(ry, 0);
  }
  else {
    return ry;
  }
}

VALUE
ca_call_cfunc_1_4 (int8_t dty, 
                     int8_t dtx1, 
                     int8_t dtx2, 
                     int8_t dtx3, 
                     int8_t dtx4, 
                     void (*mathfunc)(void*,void*,void*,void*,void*), 
                     volatile VALUE rx1, 
                     volatile VALUE rx2, 
                     volatile VALUE rx3,
                     volatile VALUE rx4) 
{ 
  volatile VALUE ry; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  rx3 = rb_ca_wrap_readonly(rx3, INT2NUM(dtx3)); 
  rx4 = rb_ca_wrap_readonly(rx4, INT2NUM(dtx4)); 
  ry  = rb_ca_template_n(4,
                         rb_ca_wrap_readonly(rx1, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx2, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx3, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx4, INT2NUM(dty))); 
  ca_call_cfunc_5(mathfunc, "10000", ry, rx1, rx2, rx3, rx4); 
  if ( rb_ca_is_scalar(ry) ) {
    return rb_ca_fetch_addr(ry, 0);
  }
  else {
    return ry;
  }
}

VALUE
ca_call_cfunc_1_5 (int8_t dty, 
                     int8_t dtx1, 
                     int8_t dtx2, 
                     int8_t dtx3, 
                     int8_t dtx4, 
                     int8_t dtx5, 
                     void (*mathfunc)(void*,void*,void*,void*,void*,void*), 
                     volatile VALUE rx1, 
                     volatile VALUE rx2, 
                     volatile VALUE rx3,
                     volatile VALUE rx4,
                     volatile VALUE rx5) 
{ 
  volatile VALUE ry; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  rx3 = rb_ca_wrap_readonly(rx3, INT2NUM(dtx3)); 
  rx4 = rb_ca_wrap_readonly(rx4, INT2NUM(dtx4)); 
  rx5 = rb_ca_wrap_readonly(rx5, INT2NUM(dtx5)); 
  ry  = rb_ca_template_n(5,
                         rb_ca_wrap_readonly(rx1, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx2, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx3, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx4, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx5, INT2NUM(dty))); 
  ca_call_cfunc_6(mathfunc, "10000", ry, rx1, rx2, rx3, rx4, rx5); 
  if ( rb_ca_is_scalar(ry) ) {
    return rb_ca_fetch_addr(ry, 0);
  }
  else {
    return ry;
  }
}

VALUE
ca_call_cfunc_1_6 (int8_t dty, 
                     int8_t dtx1, 
                     int8_t dtx2, 
                     int8_t dtx3, 
                     int8_t dtx4, 
                     int8_t dtx5, 
                     int8_t dtx6, 
                     void (*mathfunc)(void*,void*,void*,void*,void*,void*,void*), 
                     volatile VALUE rx1, 
                     volatile VALUE rx2, 
                     volatile VALUE rx3,
                     volatile VALUE rx4,
                     volatile VALUE rx5,
                     volatile VALUE rx6) 
{ 
  volatile VALUE ry; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  rx3 = rb_ca_wrap_readonly(rx3, INT2NUM(dtx3)); 
  rx4 = rb_ca_wrap_readonly(rx4, INT2NUM(dtx4)); 
  rx5 = rb_ca_wrap_readonly(rx5, INT2NUM(dtx5)); 
  rx6 = rb_ca_wrap_readonly(rx5, INT2NUM(dtx6)); 
  ry  = rb_ca_template_n(5,
                         rb_ca_wrap_readonly(rx1, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx2, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx3, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx4, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx5, INT2NUM(dty)), 
                         rb_ca_wrap_readonly(rx6, INT2NUM(dty))); 
  ca_call_cfunc_7(mathfunc, "100000", ry, rx1, rx2, rx3, rx4, rx5, rx6); 
  if ( rb_ca_is_scalar(ry) ) {
    return rb_ca_fetch_addr(ry, 0);
  }
  else {
    return ry;
  }
}

VALUE
ca_call_cfunc_2_1 (int8_t dty1, 
                    int8_t dty2, 
                    int8_t dtx1, 
                    void (*mathfunc)(void*,void*,void*), 
                    volatile VALUE rx1) 
{ 
  volatile VALUE ry1 = Qnil, ry2 = Qnil; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  if ( dty1 != dtx1 ) {
    ry1  = rb_ca_template_n(1,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty1))); 
  }
  else {
    ry1  = rb_ca_template_n(1, rx1);
  }
  if ( dty2 != dtx1 ) {
    ry2  = rb_ca_template_n(1,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty2))); 
  }
  else {
    ry2  = rb_ca_template_n(1, rx1);
  }
  ca_call_cfunc_3(mathfunc, "110", ry1, ry2, rx1); 
  if ( rb_ca_is_scalar(ry1) ) {
    ry1 = rb_ca_fetch_addr(ry1, 0);
  }
  if ( rb_ca_is_scalar(ry2) ) {
    ry2 = rb_ca_fetch_addr(ry2, 0);
  }
  return rb_ary_new3(2, ry1, ry2);
}


VALUE
ca_call_cfunc_2_2 (int8_t dty1, 
                      int8_t dty2, 
                      int8_t dtx1, 
                      int8_t dtx2, 
                      void (*mathfunc)(void*,void*,void*,void*), 
                      volatile VALUE rx1, 
                      volatile VALUE rx2) 
{ 
  volatile VALUE ry1 = Qnil, ry2 = Qnil; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  if ( dty1 != dtx1 || dty1 != dtx2 ) {
    ry1  = rb_ca_template_n(2,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty1)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty1))); 
  }
  else {
    ry1  = rb_ca_template_n(2, rx1, rx2);
  }
  if ( dty2 != dtx1 || dty2 != dtx2 ) {
    ry2  = rb_ca_template_n(2,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty2)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty2))); 
  }
  else {
    ry2  = rb_ca_template_n(2, rx1, rx2);
  }
  ca_call_cfunc_4(mathfunc, "1100", ry1, ry2, rx1, rx2); 
  if ( rb_ca_is_scalar(ry1) ) {
    ry1 = rb_ca_fetch_addr(ry1, 0);
  }
  if ( rb_ca_is_scalar(ry2) ) {
    ry2 = rb_ca_fetch_addr(ry2, 0);
  }
  return rb_ary_new3(2, ry1, ry2);
}

VALUE
ca_call_cfunc_2_3 (int8_t dty1, 
                      int8_t dty2, 
                      int8_t dtx1, 
                      int8_t dtx2, 
                      int8_t dtx3, 
                      void (*mathfunc)(void*,void*,void*,void*,void*), 
                      volatile VALUE rx1, 
                      volatile VALUE rx2, 
                      volatile VALUE rx3) 
{ 
  volatile VALUE ry1 = Qnil, ry2 = Qnil; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  rx3 = rb_ca_wrap_readonly(rx3, INT2NUM(dtx3)); 
  if ( dty1 != dtx1 || dty1 != dtx2 || dty1 != dtx3 ) {
    ry1  = rb_ca_template_n(3,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty1)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty1)), 
                           rb_ca_wrap_readonly(rx3, INT2NUM(dty1))); 
  }
  else {
    ry1  = rb_ca_template_n(3, rx1, rx2, rx3);
  }
  if ( dty2 != dtx1 || dty2 != dtx2 || dty2 != dtx3 ) {
    ry2  = rb_ca_template_n(3,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty2)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty2)), 
                           rb_ca_wrap_readonly(rx3, INT2NUM(dty2))); 
  }
  else {
    ry2  = rb_ca_template_n(3, rx1, rx2, rx3);
  }
  ca_call_cfunc_5(mathfunc, "11000", ry1, ry2, rx1, rx2, rx3); 
  if ( rb_ca_is_scalar(ry1) ) {
    ry1 = rb_ca_fetch_addr(ry1, 0);
  }
  if ( rb_ca_is_scalar(ry2) ) {
    ry2 = rb_ca_fetch_addr(ry2, 0);
  }
  return rb_ary_new3(2, ry1, ry2);
}

VALUE
ca_call_cfunc_2_4 (int8_t dty1, 
                      int8_t dty2, 
                      int8_t dtx1, 
                      int8_t dtx2, 
                      int8_t dtx3, 
                      int8_t dtx4, 
                      void (*mathfunc)(void*,void*,void*,void*,void*,void*), 
                      volatile VALUE rx1, 
                      volatile VALUE rx2, 
                      volatile VALUE rx3,
                      volatile VALUE rx4) 
{ 
  volatile VALUE ry1 = Qnil, ry2 = Qnil; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  rx3 = rb_ca_wrap_readonly(rx3, INT2NUM(dtx3)); 
  rx4 = rb_ca_wrap_readonly(rx3, INT2NUM(dtx4)); 
  if ( dty1 != dtx1 || dty1 != dtx2 || dty1 != dtx3 || dty1 != dtx4 ) {
    ry1  = rb_ca_template_n(4,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty1)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty1)), 
                           rb_ca_wrap_readonly(rx3, INT2NUM(dty1)),
                           rb_ca_wrap_readonly(rx4, INT2NUM(dty1))); 
  }
  else {
    ry1  = rb_ca_template_n(4, rx1, rx2, rx3, rx4);
  }
  if ( dty2 != dtx1 || dty2 != dtx2 || dty2 != dtx3 || dty2 != dtx4 ) {
    ry2  = rb_ca_template_n(4,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty2)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty2)), 
                           rb_ca_wrap_readonly(rx3, INT2NUM(dty2)),
                           rb_ca_wrap_readonly(rx4, INT2NUM(dty2))); 
  }
  else {
    ry2  = rb_ca_template_n(4, rx1, rx2, rx3, rx4);
  }
  ca_call_cfunc_6(mathfunc, "110000", ry1, ry2, rx1, rx2, rx3, rx4); 
  if ( rb_ca_is_scalar(ry1) ) {
    ry1 = rb_ca_fetch_addr(ry1, 0);
  }
  if ( rb_ca_is_scalar(ry2) ) {
    ry2 = rb_ca_fetch_addr(ry2, 0);
  }
  return rb_ary_new3(2, ry1, ry2);
}

VALUE
ca_call_cfunc_3_1 (int8_t dty1, 
                      int8_t dty2, 
                      int8_t dty3, 
                      int8_t dtx1, 
                      void (*mathfunc)(void*,void*,void*,void*), 
                      volatile VALUE rx1) 
{ 
  volatile VALUE ry1 = Qnil, ry2 = Qnil, ry3 = Qnil; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  if ( dty1 != dtx1 ) {
    ry1  = rb_ca_template_n(1,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty1))); 
  }
  else {
    ry1  = rb_ca_template_n(1, rx1);
  }
  if ( dty2 != dtx1 ) {
    ry2  = rb_ca_template_n(1,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty2))); 
  }
  else {
    ry2  = rb_ca_template_n(1, rx1);
  }
  if ( dty3 != dtx1  ) {
    ry3  = rb_ca_template_n(1,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty3))); 
  }
  else {
    ry3  = rb_ca_template_n(1, rx1);
  }
  ca_call_cfunc_4(mathfunc, "1110", ry1, ry2, ry3, rx1); 
  if ( rb_ca_is_scalar(ry1) ) {
    ry1 = rb_ca_fetch_addr(ry1, 0);
  }
  if ( rb_ca_is_scalar(ry2) ) {
    ry2 = rb_ca_fetch_addr(ry2, 0);
  }
  if ( rb_ca_is_scalar(ry3) ) {
    ry3 = rb_ca_fetch_addr(ry3, 0);
  }
  return rb_ary_new3(3, ry1, ry2, ry3);
}

VALUE
ca_call_cfunc_3_2 (int8_t dty1, 
                      int8_t dty2, 
                      int8_t dty3, 
                      int8_t dtx1, 
                      int8_t dtx2, 
                      void (*mathfunc)(void*,void*,void*,void*,void*), 
                      volatile VALUE rx1, 
                      volatile VALUE rx2) 
{ 
  volatile VALUE ry1 = Qnil, ry2 = Qnil, ry3 = Qnil; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  if ( dty1 != dtx1 || dty1 != dtx2 ) {
    ry1  = rb_ca_template_n(2,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty1)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty1))); 
  }
  else {
    ry1  = rb_ca_template_n(2, rx1, rx2);
  }
  if ( dty2 != dtx1 || dty2 != dtx2 ) {
    ry2  = rb_ca_template_n(2,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty2)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty2))); 
  }
  else {
    ry2  = rb_ca_template_n(2, rx1, rx2);
  }
  if ( dty3 != dtx1 || dty3 != dtx2 ) {
    ry3  = rb_ca_template_n(2,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty3)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty3))); 
  }
  else {
    ry3  = rb_ca_template_n(2, rx1, rx2);
  }
  ca_call_cfunc_5(mathfunc, "11100", ry1, ry2, ry3, rx1, rx2); 
  if ( rb_ca_is_scalar(ry1) ) {
    ry1 = rb_ca_fetch_addr(ry1, 0);
  }
  if ( rb_ca_is_scalar(ry2) ) {
    ry2 = rb_ca_fetch_addr(ry2, 0);
  }
  if ( rb_ca_is_scalar(ry3) ) {
    ry3 = rb_ca_fetch_addr(ry3, 0);
  }
  return rb_ary_new3(3, ry1, ry2, ry3);
}

VALUE
ca_call_cfunc_3_3 (int8_t dty1, 
                      int8_t dty2, 
                      int8_t dty3, 
                      int8_t dtx1, 
                      int8_t dtx2, 
                      int8_t dtx3, 
                      void (*mathfunc)(void*,void*,void*,void*,void*,void*), 
                      volatile VALUE rx1, 
                      volatile VALUE rx2,                       
                      volatile VALUE rx3) 
{ 
  volatile VALUE ry1 = Qnil, ry2 = Qnil, ry3 = Qnil; 
  rx1 = rb_ca_wrap_readonly(rx1, INT2NUM(dtx1)); 
  rx2 = rb_ca_wrap_readonly(rx2, INT2NUM(dtx2)); 
  rx3 = rb_ca_wrap_readonly(rx3, INT2NUM(dtx3)); 
  if ( dty1 != dtx1 || dty1 != dtx2 || dty1 != dtx3 ) {
    ry1  = rb_ca_template_n(3,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty1)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty1)), 
                           rb_ca_wrap_readonly(rx3, INT2NUM(dty1))); 
  }
  else {
    ry1  = rb_ca_template_n(3, rx1, rx2, rx3);
  }
  if ( dty2 != dtx1 || dty2 != dtx2 || dty2 != dtx3 ) {
    ry2  = rb_ca_template_n(3,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty2)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty2)), 
                           rb_ca_wrap_readonly(rx3, INT2NUM(dty2))); 
  }
  else {
    ry2  = rb_ca_template_n(3, rx1, rx2, rx3);
  }
  if ( dty3 != dtx1 || dty3 != dtx2 || dty3 != dtx3 ) {
    ry3  = rb_ca_template_n(3,
                           rb_ca_wrap_readonly(rx1, INT2NUM(dty3)), 
                           rb_ca_wrap_readonly(rx2, INT2NUM(dty3)), 
                           rb_ca_wrap_readonly(rx3, INT2NUM(dty3))); 
  }
  else {
    ry3  = rb_ca_template_n(3, rx1, rx2, rx3);
  }

  ca_call_cfunc_6(mathfunc, "111000", ry1, ry2, ry3, rx1, rx2, rx3); 
  if ( rb_ca_is_scalar(ry1) ) {
    ry1 = rb_ca_fetch_addr(ry1, 0);
  }
  if ( rb_ca_is_scalar(ry2) ) {
    ry2 = rb_ca_fetch_addr(ry2, 0);
  }
  if ( rb_ca_is_scalar(ry3) ) {
    ry3 = rb_ca_fetch_addr(ry3, 0);
  }
  return rb_ary_new3(3, ry1, ry2, ry3);
}
