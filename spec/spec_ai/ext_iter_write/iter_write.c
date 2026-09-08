/* A kernel whose WRITE destination is a view the caller supplies.

   Every kernel inside carray writes into an array it just allocated
   (rb_ca_template_with_type, ca_template_safe, rb_carray_new), so the
   destination is always a fresh entity and the iterator's WRITE half is
   only ever exercised on obj_type 0.  A C extension using the author
   macros is under no such restriction: it can hand any view to
   CA_FOR_EACH_SLAB with CA_KERNEL_WRITE.  This fixture is that caller.

   The entry points are deliberately thin -- they fill the destination
   with one value and let the test compare the base entity before and
   after, so what is being measured is whether the write reached memory,
   not what the kernel computed. */

#include <string.h>
#include "ruby.h"
#include "carray.h"
#include "ca_kernel_iterator.h"

/* CA_SLAB_AXES + CA_KERNEL_FIBER_CONTIG.  dst must be float64. */
static VALUE
iw_fiber_fill (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v    = NUM2DBL(vval);
  int           axis = NUM2INT(vaxis);
  ca_iter_state st;
  char         *p;
  ca_size_t     n;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);

  CA_FOR_EACH_FIBER(st, dst, axis,
                    CA_KERNEL_WRITE | CA_KERNEL_NO_MASK, p, n) {
    double *d = (double *) p;
    for ( ca_size_t i = 0; i < n; i++ ) d[i] = v;
  }
  return Qnil;
}

/* CA_SLAB_AXES without FIBER_CONTIG: the slab is walked with strides. */
static VALUE
iw_slab_fill (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v = NUM2DBL(vval);
  int8_t        ax[1];
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  ax[0] = (int8_t) NUM2INT(vaxis);

  CA_FOR_EACH_SLAB(st, dst, ax, 1, CA_KERNEL_WRITE, p, m) {
    ca_size_t n = st.slab_dims[0];
    ca_size_t s = st.slab_strides[0];
    for ( ca_size_t i = 0; i < n; i++ ) *(double *)(p + i * s) = v;
  }
  return Qnil;
}

/* Writes the mask half of the yielded slab as well as the data half.
   Returns whether a mask pointer was yielded at all. */
static VALUE
iw_slab_fill_mask (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v = NUM2DBL(vval);
  int8_t        ax[1];
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;
  int           mask_seen = 0;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  ax[0] = (int8_t) NUM2INT(vaxis);

  CA_FOR_EACH_SLAB(st, dst, ax, 1, CA_KERNEL_WRITE, p, m) {
    ca_size_t n  = st.slab_dims[0];
    ca_size_t s  = st.slab_strides[0];
    ca_size_t ms = st.slab_mask_strides[0];
    for ( ca_size_t i = 0; i < n; i++ ) {
      *(double *)(p + i * s) = v;
      if ( m ) { m[i * ms] = 1; mask_seen = 1; }
    }
  }
  return mask_seen ? Qtrue : Qfalse;
}

/* The return code init_l2 gives for (dst, axis, flags), without iterating.
   The block macros discard this value; this entry point is how the test
   sees what they discarded. */
static VALUE
iw_init_rc (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vflags)
{
  CArray       *dst;
  ca_iter_state st;
  int8_t        ax[1];
  int           rc;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  ax[0] = (int8_t) NUM2INT(vaxis);
  memset(&st, 0, sizeof(st));

  rc = ca_iter_state_init_l2(&st, dst, CA_SLAB_AXES, ax, 1,
                             (uint32_t) NUM2UINT(vflags));
  if ( rc == CA_ITER_OK ) ca_iter_state_finish(&st);
  return INT2NUM(rc);
}

/* iw_slab_fill with the state struct poisoned first, which is what a real
   caller frame looks like when init returns early without writing to it.
   A caller that happens to sit on zeroed stack sees the write vanish; this
   one sees whatever the garbage decodes to. */
static VALUE
iw_slab_fill_poisoned (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v = NUM2DBL(vval);
  int8_t        ax[1];
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  ax[0] = (int8_t) NUM2INT(vaxis);
  memset(&st, 0x5A, sizeof(st));

  CA_FOR_EACH_SLAB(st, dst, ax, 1, CA_KERNEL_WRITE, p, m) {
    ca_size_t n = st.slab_dims[0];
    ca_size_t s = st.slab_strides[0];
    for ( ca_size_t i = 0; i < n; i++ ) *(double *)(p + i * s) = v;
  }
  return Qnil;
}

void
Init_iter_write (void)
{
  rb_define_singleton_method(rb_cCArray, "iw_fiber_fill", iw_fiber_fill, 3);
  rb_define_singleton_method(rb_cCArray, "iw_slab_fill", iw_slab_fill, 3);
  rb_define_singleton_method(rb_cCArray, "iw_slab_fill_mask", iw_slab_fill_mask, 3);
  rb_define_singleton_method(rb_cCArray, "iw_init_rc", iw_init_rc, 3);
  rb_define_singleton_method(rb_cCArray, "iw_slab_fill_poisoned", iw_slab_fill_poisoned, 3);
}
