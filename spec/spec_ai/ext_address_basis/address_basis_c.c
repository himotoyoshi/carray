/* A C extension that lends cells by address with ca_with_address_bases,
   compiled the way an extension outside carray is.

   CArray.ab_stencil(a, out) computes, for a float64 a of shape (n, m) and
   out of shape (n - 2, m),

     out[i][j] = a[i][j] + a[i + 2][j]

   reading a by address across rows (what a slab walk cannot do) and
   writing out by address.  a's box is all of it; out's box is all of it.
   A masked cell of a is read as 0 and marks out's cell when out has a
   mask.

   CArray.ab_fill_box(a, i0, j0, rows, cols, value) writes value into the
   cells of that box of a float64 a, through the box it lends, and leaves
   the rest alone. */

#include "ruby.h"
#include "carray.h"

typedef struct {
  ca_size_t n, m;
} stencil_arg;

static VALUE
stencil_body (ca_address_basis_t *b, VALUE varg)
{
  stencil_arg *s = (stencil_arg *) varg;
  ca_address_basis_t *a = &b[0], *o = &b[1];
  for ( ca_size_t i = 0; i + 2 < s->n; i++ ) {
    for ( ca_size_t j = 0; j < s->m; j++ ) {
      char  *p0 = a->ptr + i * a->strides[0] + j * a->strides[1];
      char  *p2 = a->ptr + (i + 2) * a->strides[0] + j * a->strides[1];
      int    masked = 0;
      double v0, v2;
      if ( a->mask ) {
        masked = a->mask[i * a->mask_strides[0] + j * a->mask_strides[1]]
              || a->mask[(i + 2) * a->mask_strides[0] + j * a->mask_strides[1]];
      }
      v0 = *(double *) p0;
      v2 = *(double *) p2;
      *(double *) (o->ptr + i * o->strides[0] + j * o->strides[1])
        = masked ? 0.0 : v0 + v2;
      if ( o->mask ) {
        o->mask[i * o->mask_strides[0] + j * o->mask_strides[1]] = masked ? 1 : 0;
      }
    }
  }
  return Qnil;
}

static VALUE
ab_stencil (VALUE klass, VALUE va, VALUE vout)
{
  CArray     *arrays[2];
  int         writable[2] = { 0, 1 };
  stencil_arg s;
  (void) klass;
  GetCArray(va, arrays[0]);
  GetCArray(vout, arrays[1]);
  if ( arrays[0]->data_type != CA_FLOAT64 || arrays[1]->data_type != CA_FLOAT64
       || arrays[0]->ndim != 2 || arrays[1]->ndim != 2
       || arrays[1]->dim[0] + 2 != arrays[0]->dim[0]
       || arrays[1]->dim[1] != arrays[0]->dim[1] ) {
    rb_raise(rb_eArgError, "ab_stencil: float64 (n, m) and (n - 2, m)");
  }
  s.n = arrays[0]->dim[0];
  s.m = arrays[0]->dim[1];
  ca_with_address_bases(2, arrays, writable, NULL, NULL, stencil_body,
                        (VALUE) &s);
  RB_GC_GUARD(va);
  RB_GC_GUARD(vout);
  return vout;
}

typedef struct {
  ca_size_t i0, j0, rows, cols;
  double    value;
} fill_arg;

static VALUE
fill_body (ca_address_basis_t *b, VALUE varg)
{
  fill_arg *f = (fill_arg *) varg;
  for ( ca_size_t i = f->i0; i < f->i0 + f->rows; i++ ) {
    for ( ca_size_t j = f->j0; j < f->j0 + f->cols; j++ ) {
      *(double *) (b->ptr + i * b->strides[0] + j * b->strides[1]) = f->value;
    }
  }
  return Qnil;
}

static VALUE
ab_fill_box (VALUE klass, VALUE va, VALUE vi0, VALUE vj0, VALUE vrows,
             VALUE vcols, VALUE vvalue)
{
  CArray    *arrays[1];
  int        writable[1] = { 1 };
  fill_arg   f;
  ca_size_t  start[2], count[2];
  const ca_size_t *starts[1] = { start }, *counts[1] = { count };
  (void) klass;
  GetCArray(va, arrays[0]);
  if ( arrays[0]->data_type != CA_FLOAT64 || arrays[0]->ndim != 2 ) {
    rb_raise(rb_eArgError, "ab_fill_box: a float64 (n, m)");
  }
  f.i0 = NUM2SIZET(vi0); f.j0 = NUM2SIZET(vj0);
  f.rows = NUM2SIZET(vrows); f.cols = NUM2SIZET(vcols);
  f.value = NUM2DBL(vvalue);
  start[0] = f.i0; start[1] = f.j0;
  count[0] = f.rows; count[1] = f.cols;
  ca_with_address_bases(1, arrays, writable, starts, counts, fill_body,
                        (VALUE) &f);
  RB_GC_GUARD(va);
  return va;
}

static VALUE
raise_body (ca_address_basis_t *b, VALUE varg)
{
  (void) varg;
  *(double *) b->ptr = 42.0;
  rb_raise(rb_eRuntimeError, "raised in the body");
  return Qnil;
}

/* Writes 42 into cell (0, 0) and raises: the write still lands. */
static VALUE
ab_write_then_raise (VALUE klass, VALUE va)
{
  CArray *arrays[1];
  int     writable[1] = { 1 };
  (void) klass;
  GetCArray(va, arrays[0]);
  ca_with_address_bases(1, arrays, writable, NULL, NULL, raise_body, Qnil);
  return Qnil;
}

void
Init_address_basis_c (void)
{
  rb_define_singleton_method(rb_cCArray, "ab_stencil", ab_stencil, 2);
  rb_define_singleton_method(rb_cCArray, "ab_fill_box", ab_fill_box, 6);
  rb_define_singleton_method(rb_cCArray, "ab_write_then_raise",
                             ab_write_then_raise, 1);
}
