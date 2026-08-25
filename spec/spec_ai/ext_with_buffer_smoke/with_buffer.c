/* spec_ai/ext_with_buffer_smoke/with_buffer.c
 *
 * TEST FIXTURE — byte-for-byte mirror of samples/c-extensions/with_buffer/with_buffer.c
 * (the user-facing runnable example).  Kept here so the spec_ai suite owns
 * its own build and never reaches into samples/.  If you edit one, edit both
 * (the samples copy is documentation; this copy is the regression fixture).
 */
/* ---------------------------------------------------------------------------
 *
 *  with_buffer.c -- CA_WITH_BUFFER / rb_ca_call_with_buffer usage example
 *
 *  PROPOSAL_L0_AUTHOR_SURFACE L0.2c.  Demonstrates the whole-view family:
 *
 *    CA_WITH_BUFFER            scoped read-only view (attach+sync+detach
 *                            handled by the macro for the scope body)
 *    CA_WITH_BUFFER_WRITABLE   scoped writable view
 *    rb_ca_call_with_buffer       function-form alternative with rb_ensure
 *                            protection (= guarantees detach on raise)
 *
 *  Build:    ruby extconf.rb && make
 *  Run:      ruby example.rb
 *
 *  --------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_for_buffer.h"

/* (1) CA_WITH_BUFFER: sum f64 cells via direct ptr access. */
static VALUE
demo_with_buffer_sum_f64 (VALUE self, VALUE r_ca)
{
  CArray *ca;
  double *ptr = NULL;
  ca_size_t n = 0, i;
  double sum = 0.0;

  TypedData_Get_Struct(r_ca, CArray, &carray_data_type, ca);
  if (ca->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "requires float64");
  }

  CA_WITH_BUFFER(ca, double, ptr, n) {
    for (i = 0; i < n; i++) sum += ptr[i];
  }
  return rb_float_new(sum);
}

/* (2) CA_WITH_BUFFER_WRITABLE: scale in place via direct ptr write. */
static VALUE
demo_with_buffer_scale_f64 (VALUE self, VALUE r_ca, VALUE r_factor)
{
  CArray *ca;
  double *ptr = NULL;
  ca_size_t n = 0, i;
  double factor = NUM2DBL(r_factor);

  TypedData_Get_Struct(r_ca, CArray, &carray_data_type, ca);
  if (ca->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "requires float64");
  }

  CA_WITH_BUFFER_WRITABLE(ca, double, ptr, n) {
    for (i = 0; i < n; i++) ptr[i] *= factor;
  }
  return r_ca;
}

/* (3) Break from body still runs ca_detach (no leak). */
static VALUE
demo_with_buffer_break_after_k (VALUE self, VALUE r_ca, VALUE r_k)
{
  CArray *ca;
  double *ptr = NULL;
  ca_size_t n = 0, i;
  ca_size_t k = (ca_size_t) NUM2LONG(r_k);
  double partial = 0.0;

  TypedData_Get_Struct(r_ca, CArray, &carray_data_type, ca);
  if (ca->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "requires float64");
  }

  CA_WITH_BUFFER(ca, double, ptr, n) {
    for (i = 0; i < n; i++) {
      if (i >= (ca_size_t) k) break;  /* inner break */
      partial += ptr[i];
    }
    break;  /* outer body break: macro's wrapping for-loop still runs detach */
  }
  return rb_float_new(partial);
}

/* (4) rb_ca_call_with_buffer: function form, sum via callback. */
typedef struct {
  double sum;
} call_with_buffer_sum_ud_t;

static void
call_with_buffer_sum_body (void *ud, void *ptr, ca_size_t n)
{
  call_with_buffer_sum_ud_t *u = (call_with_buffer_sum_ud_t *) ud;
  double *p = (double *) ptr;
  ca_size_t i;
  u->sum = 0.0;
  for (i = 0; i < n; i++) u->sum += p[i];
}

static VALUE
demo_call_with_buffer_sum_f64 (VALUE self, VALUE r_ca)
{
  call_with_buffer_sum_ud_t ud;
  CArray *ca;
  TypedData_Get_Struct(r_ca, CArray, &carray_data_type, ca);
  if (ca->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "requires float64");
  }
  ud.sum = 0.0;
  rb_ca_call_with_buffer(r_ca, /*writable=*/0, call_with_buffer_sum_body, &ud);
  return rb_float_new(ud.sum);
}

/* (5) rb_ca_call_with_buffer that intentionally raises mid-body.
 *     Demonstrates that rb_ensure runs ca_sync + ca_detach so the view
 *     is left clean even when the body throws. */
typedef struct {
  int     raise_at_index;
  int     writable;
  ca_size_t modified_before_raise;
} call_with_buffer_raise_ud_t;

static void
call_with_buffer_raise_body (void *ud, void *ptr, ca_size_t n)
{
  call_with_buffer_raise_ud_t *u = (call_with_buffer_raise_ud_t *) ud;
  double *p = (double *) ptr;
  ca_size_t i;
  for (i = 0; i < n; i++) {
    if (u->writable) {
      p[i] = -1.0;
      u->modified_before_raise++;
    }
    if ((int) i == u->raise_at_index) {
      rb_raise(rb_eRuntimeError, "demo raise at index %d", u->raise_at_index);
    }
  }
}

static VALUE
demo_call_with_buffer_raise (VALUE self, VALUE r_ca, VALUE r_index,
                           VALUE r_writable)
{
  call_with_buffer_raise_ud_t ud;
  CArray *ca;
  TypedData_Get_Struct(r_ca, CArray, &carray_data_type, ca);
  if (ca->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "requires float64");
  }
  ud.raise_at_index        = NUM2INT(r_index);
  ud.writable              = RTEST(r_writable) ? 1 : 0;
  ud.modified_before_raise = 0;
  rb_ca_call_with_buffer(r_ca, ud.writable, call_with_buffer_raise_body, &ud);
  /* unreachable: body always raises before returning */
  return LONG2NUM((long) ud.modified_before_raise);
}

void
Init_with_buffer (void)
{
  rb_define_singleton_method(rb_cCArray,
      "demo_with_buffer_sum_f64",       demo_with_buffer_sum_f64, 1);
  rb_define_singleton_method(rb_cCArray,
      "demo_with_buffer_scale_f64",     demo_with_buffer_scale_f64, 2);
  rb_define_singleton_method(rb_cCArray,
      "demo_with_buffer_break_after_k", demo_with_buffer_break_after_k, 2);
  rb_define_singleton_method(rb_cCArray,
      "demo_call_with_buffer_sum_f64",  demo_call_with_buffer_sum_f64, 1);
  rb_define_singleton_method(rb_cCArray,
      "demo_call_with_buffer_raise",    demo_call_with_buffer_raise, 3);
}
