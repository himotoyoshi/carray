/* A kernel that reads two arrays along the same axis at once.

   The FIBER macro family covers one source (CA_FOR_EACH_FIBER) and a source
   with an output (CA_FOR_EACH_FIBER_INOUT).  CA_FOR_EACH_FIBER_PAIR is the
   third shape: two sources read together, which is what a C routine taking
   two vectors of the same length wants -- gsl_stats_correlation and its
   kin, cblas_ddot, a distance.

   Nothing inside carray needs it: every two-operand walk in the tree is a
   reduction with weights, and that goes through CA_SLAB_REDUCE_ARRAY_T_EX,
   which does its own stride arithmetic.  A kernel handing the pair to
   someone else's loop cannot do that -- the bytes have to be contiguous
   before they leave.  This fixture is that caller.

   ip_dot_raw is the same walk written against the raw API with
   CA_KERNEL_FIBER_CONTIG left out, which is what an author writes when the
   macro is not there.  It is here to be compared against, not copied. */

#include <string.h>
#include "ruby.h"
#include "carray.h"
#include "ca_kernel_iterator.h"

/* Per-fiber sum of a[i]*b[i], float64 in and out. */
static VALUE
ip_dot (VALUE klass, VALUE va, VALUE vb, VALUE vaxis)
{
  volatile VALUE vout;
  CArray   *ca, *cb, *cout;
  int       axis = NUM2INT(vaxis);
  int8_t    axes[1];
  double   *out;
  ca_size_t o = 0;

  (void) klass;
  TypedData_Get_Struct(va, CArray, &carray_data_type, ca);
  TypedData_Get_Struct(vb, CArray, &carray_data_type, cb);

  axes[0] = (int8_t) axis;
  vout = rb_ca_new_reduced(va, axes, 1, CA_FLOAT64, 0);
  cout = (CArray *) DATA_PTR(vout);
  out  = (double *) cout->ptr;
  memset(out, 0, (size_t) cout->elements * sizeof(double));

  {
    ca_iter_state sa, sb;
    char       *pa, *pb;
    ca_size_t   n;

    CA_FOR_EACH_FIBER_PAIR(sa, sb, ca, cb, (int8_t) axis,
                           CA_KERNEL_READ | CA_KERNEL_NO_MASK, pa, pb, n) {
      const double *x = (const double *) pa;
      const double *y = (const double *) pb;
      double s = 0.0;
      ca_size_t i;
      for ( i = 0; i < n; i++ ) { s += x[i] * y[i]; }
      out[o++] = s;
    }
  }

  /* How many fibers the walk actually produced -- 0 when the shapes did
     not agree and the body was skipped. */
  rb_ivar_set(vout, rb_intern("@fibers"), SIZET2NUM((size_t) o));
  return vout;
}

/* Same, using only the cells present in BOTH fibers. */
static VALUE
ip_dot_masked (VALUE klass, VALUE va, VALUE vb, VALUE vaxis)
{
  volatile VALUE vout;
  CArray   *ca, *cb, *cout;
  int       axis = NUM2INT(vaxis);
  int8_t    axes[1];
  double   *out;
  ca_size_t o = 0;

  (void) klass;
  TypedData_Get_Struct(va, CArray, &carray_data_type, ca);
  TypedData_Get_Struct(vb, CArray, &carray_data_type, cb);

  axes[0] = (int8_t) axis;
  vout = rb_ca_new_reduced(va, axes, 1, CA_FLOAT64, 0);
  cout = (CArray *) DATA_PTR(vout);
  out  = (double *) cout->ptr;
  memset(out, 0, (size_t) cout->elements * sizeof(double));

  {
    ca_iter_state sa, sb;
    char       *pa, *pb;
    boolean8_t *ma, *mb;
    ca_size_t   n;

    CA_FOR_EACH_FIBER_PAIR_MASKED(sa, sb, ca, cb, (int8_t) axis,
                                  CA_KERNEL_READ, pa, pb, n, ma, mb) {
      const double *x = (const double *) pa;
      const double *y = (const double *) pb;
      double s = 0.0;
      ca_size_t i;
      for ( i = 0; i < n; i++ ) {
        if ( ma && ma[i] ) { continue; }
        if ( mb && mb[i] ) { continue; }
        s += x[i] * y[i];
      }
      out[o++] = s;
    }
  }

  rb_ivar_set(vout, rb_intern("@fibers"), SIZET2NUM((size_t) o));
  return vout;
}

/* The raw API without CA_KERNEL_FIBER_CONTIG: correct along the last axis,
   and quietly wrong along any other. */
static VALUE
ip_dot_raw (VALUE klass, VALUE va, VALUE vb, VALUE vaxis)
{
  volatile VALUE vout;
  CArray   *ca, *cb, *cout;
  int       axis = NUM2INT(vaxis);
  int8_t    axes[1];
  double   *out;
  ca_size_t o = 0;

  (void) klass;
  TypedData_Get_Struct(va, CArray, &carray_data_type, ca);
  TypedData_Get_Struct(vb, CArray, &carray_data_type, cb);

  axes[0] = (int8_t) axis;
  vout = rb_ca_new_reduced(va, axes, 1, CA_FLOAT64, 0);
  cout = (CArray *) DATA_PTR(vout);
  out  = (double *) cout->ptr;
  memset(out, 0, (size_t) cout->elements * sizeof(double));

  {
    ca_iter_state sa, sb;
    char       *pa, *pb;
    boolean8_t *ma, *mb;

    ca_iter_check_init(
      ca_iter_state_init_l2(&sa, ca, CA_SLAB_AXES, axes, 1, CA_KERNEL_READ));
    ca_iter_check_init(
      ca_iter_state_init_l2(&sb, cb, CA_SLAB_AXES, axes, 1, CA_KERNEL_READ));

    while ( ca_iter_state_next_slab_axes(&sa, &pa, &ma) &&
            ca_iter_state_next_slab_axes(&sb, &pb, &mb) ) {
      const double *x = (const double *) pa;
      const double *y = (const double *) pb;
      double s = 0.0;
      ca_size_t i, n = sa.slab_dims[0];
      for ( i = 0; i < n; i++ ) { s += x[i] * y[i]; }
      out[o++] = s;
      ca_iter_state_sync_slab(&sa);
      ca_iter_state_sync_slab(&sb);
    }

    ca_iter_state_finish(&sa);
    ca_iter_state_finish(&sb);
  }

  rb_ivar_set(vout, rb_intern("@fibers"), SIZET2NUM((size_t) o));
  return vout;
}

void
Init_iter_pair (void)
{
  VALUE mod = rb_define_module("IterPair");
  rb_define_module_function(mod, "dot",        ip_dot,        3);
  rb_define_module_function(mod, "dot_masked", ip_dot_masked, 3);
  rb_define_module_function(mod, "dot_raw",    ip_dot_raw,    3);
}
