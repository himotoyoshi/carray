/* spec_ai/ext_with_buffer_smoke/with_buffer.c
 *
 * TEST FIXTURE — byte-for-byte mirror of examples/c-extensions/with_buffer/with_buffer.c
 * (the user-facing runnable example).  Kept here so the spec_ai suite owns
 * its own build and never reaches into examples/.  If you edit one, edit both
 * (the samples copy is documentation; this copy is the regression fixture).
 */
/* ---------------------------------------------------------------------------
 *
 *  with_buffer.c -- rb_ca_call_with_buffer usage example
 *
 *  rb_ca_call_with_buffer hands a body function the whole array as one
 *  contig buffer: the array's own memory when it is a contig entity, a
 *  materialised scratch otherwise.  A writable call syncs the buffer back
 *  when the body returns.  The body may raise; the view is closed however
 *  the body is left.
 *
 *  Build:    ruby extconf.rb && make
 *  Run:      ruby example.rb
 *
 *  --------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_for_buffer.h"

static void
require_float64 (VALUE r_ca)
{
  CArray *ca;
  TypedData_Get_Struct(r_ca, CArray, &carray_data_type, ca);
  if (ca->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "requires float64");
  }
}

/* (1) Read-only: sum the cells. */
static void
sum_body (void *ud, void *ptr, ca_size_t n)
{
  double *sum = (double *) ud;
  double *p   = (double *) ptr;
  ca_size_t i;
  for (i = 0; i < n; i++) *sum += p[i];
}

static VALUE
demo_with_buffer_sum_f64 (VALUE self, VALUE r_ca)
{
  double sum = 0.0;
  require_float64(r_ca);
  rb_ca_call_with_buffer(r_ca, /*writable=*/0, sum_body, &sum);
  return rb_float_new(sum);
}

/* (2) Writable: scale in place. */
static void
scale_body (void *ud, void *ptr, ca_size_t n)
{
  double  factor = *(double *) ud;
  double *p      = (double *) ptr;
  ca_size_t i;
  for (i = 0; i < n; i++) p[i] *= factor;
}

static VALUE
demo_with_buffer_scale_f64 (VALUE self, VALUE r_ca, VALUE r_factor)
{
  double factor = NUM2DBL(r_factor);
  require_float64(r_ca);
  rb_ca_call_with_buffer(r_ca, /*writable=*/1, scale_body, &factor);
  return r_ca;
}

/* (3) A body that raises part way.  A writable view is synced before it
 *     is detached, so the cells written before the raise reach the array. */
typedef struct {
  int raise_at_index;
  int writable;
} raise_ud_t;

static void
raise_body (void *ud, void *ptr, ca_size_t n)
{
  raise_ud_t *u = (raise_ud_t *) ud;
  double *p = (double *) ptr;
  ca_size_t i;
  for (i = 0; i < n; i++) {
    if (u->writable) {
      p[i] = -1.0;
    }
    if ((int) i == u->raise_at_index) {
      rb_raise(rb_eRuntimeError, "demo raise at index %d", u->raise_at_index);
    }
  }
}

static VALUE
demo_with_buffer_raise (VALUE self, VALUE r_ca, VALUE r_index,
                        VALUE r_writable)
{
  raise_ud_t ud;
  require_float64(r_ca);
  ud.raise_at_index = NUM2INT(r_index);
  ud.writable       = RTEST(r_writable) ? 1 : 0;
  rb_ca_call_with_buffer(r_ca, ud.writable, raise_body, &ud);
  return r_ca;
}

void
Init_with_buffer (void)
{
  rb_define_singleton_method(rb_cCArray,
      "demo_with_buffer_sum_f64",   demo_with_buffer_sum_f64, 1);
  rb_define_singleton_method(rb_cCArray,
      "demo_with_buffer_scale_f64", demo_with_buffer_scale_f64, 2);
  rb_define_singleton_method(rb_cCArray,
      "demo_with_buffer_raise",     demo_with_buffer_raise, 3);
}
