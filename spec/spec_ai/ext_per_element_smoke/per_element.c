/* spec_ai/ext_per_element_smoke/per_element.c
 *
 * TEST FIXTURE — byte-for-byte mirror of examples/c-extensions/per_element/per_element.c
 * (the user-facing runnable example).  Kept here so the spec_ai suite owns
 * its own build and never reaches into examples/.  If you edit one, edit both
 * (the samples copy is documentation; this copy is the regression fixture).
 */
/* ---------------------------------------------------------------------------
 *
 *  per_element.c -- CA_FOR_EACH_ELEMENT macro family usage example
 *
 *  Demonstrates the 5 forms of the
 *  CA_FOR_EACH_ELEMENT macro family for per-cell iteration:
 *
 *    CA_FOR_EACH_ELEMENT                  read-only, no mask
 *    CA_FOR_EACH_ELEMENT_MASKED           read-only, mask-aware
 *    CA_FOR_EACH_ELEMENT_INOUT            map in→out, no mask
 *    CA_FOR_EACH_ELEMENT_INOUT_MASKED     map in→out, mask in/out
 *    CA_FOR_EACH_ELEMENT_OUT              fill output only
 *
 *  Build:    ruby extconf.rb && make
 *  Run:      ruby example.rb
 *
 *  --------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_for_each_element.h"

/* (1) READ-only NO_MASK: sum float64 cells. */
static VALUE
demo_sum_f64 (VALUE self, VALUE r_ca)
{
  CArray *ca;
  ca_each_state_t st;
  double x = 0.0;
  double sum = 0.0;

  TypedData_Get_Struct(r_ca, CArray, &carray_data_type, ca);
  if (ca->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "demo_sum_f64: requires float64 CArray");
  }

  CA_FOR_EACH_ELEMENT(st, ca, double, x) {
    sum += x;
  }
  return rb_float_new(sum);
}

/* (2) READ-only MASKED: count non-masked cells. */
static VALUE
demo_count_unmasked_f64 (VALUE self, VALUE r_ca)
{
  CArray *ca;
  ca_each_state_t st;
  double x = 0.0;
  boolean8_t m = 0;
  ca_size_t cnt = 0;

  TypedData_Get_Struct(r_ca, CArray, &carray_data_type, ca);
  if (ca->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "demo_count_unmasked_f64: requires float64");
  }

  CA_FOR_EACH_ELEMENT_MASKED(st, ca, double, x, m) {
    (void) x;
    if (!m) cnt++;
  }
  return LONG2NUM((long) cnt);
}

/* (3) INOUT NO_MASK: y = x * x. */
static VALUE
demo_square_f64 (VALUE self, VALUE r_in, VALUE r_out)
{
  CArray *ca_in, *ca_out;
  ca_each_map_state_t st;
  double in = 0.0, out = 0.0;

  TypedData_Get_Struct(r_in,  CArray, &carray_data_type, ca_in);
  TypedData_Get_Struct(r_out, CArray, &carray_data_type, ca_out);
  if (ca_in->data_type != CA_FLOAT64 || ca_out->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "demo_square_f64: requires float64 both");
  }

  CA_FOR_EACH_ELEMENT_INOUT(st, ca_in, ca_out, double, double, in, out) {
    out = in * in;
  }
  return r_out;
}

/* (4) INOUT MASKED: y = sqrt(x) but mark negative as masked. */
static VALUE
demo_safe_sqrt_f64 (VALUE self, VALUE r_in, VALUE r_out)
{
  CArray *ca_in, *ca_out;
  ca_each_map_state_t st;
  double in = 0.0, out = 0.0;
  boolean8_t m_in = 0, m_out = 0;

  TypedData_Get_Struct(r_in,  CArray, &carray_data_type, ca_in);
  TypedData_Get_Struct(r_out, CArray, &carray_data_type, ca_out);
  if (ca_in->data_type != CA_FLOAT64 || ca_out->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "demo_safe_sqrt_f64: requires float64 both");
  }

  CA_FOR_EACH_ELEMENT_INOUT_MASKED(st, ca_in, ca_out, double, double,
                                    in, out, m_in, m_out) {
    if (m_in) {
      m_out = 1;
      out = 0.0;
    } else if (in < 0.0) {
      m_out = 1;
      out = 0.0;
    } else {
      m_out = 0;
      extern double sqrt(double);
      out = sqrt(in);
    }
  }
  return r_out;
}

/* (5) WRITE-only: fill with offset + k * step. */
static VALUE
demo_iota_f64 (VALUE self, VALUE r_out, VALUE r_offset, VALUE r_step)
{
  CArray *ca_out;
  ca_each_state_t st;
  double out = 0.0;
  double offset = NUM2DBL(r_offset);
  double step   = NUM2DBL(r_step);
  ca_size_t k = 0;

  TypedData_Get_Struct(r_out, CArray, &carray_data_type, ca_out);
  if (ca_out->data_type != CA_FLOAT64) {
    rb_raise(rb_eTypeError, "demo_iota_f64: requires float64");
  }

  CA_FOR_EACH_ELEMENT_OUT(st, ca_out, double, out) {
    out = offset + step * (double) k;
    k++;
  }
  return r_out;
}

void
Init_per_element (void)
{
  rb_define_singleton_method(rb_cCArray, "demo_sum_f64",            demo_sum_f64,            1);
  rb_define_singleton_method(rb_cCArray, "demo_count_unmasked_f64", demo_count_unmasked_f64, 1);
  rb_define_singleton_method(rb_cCArray, "demo_square_f64",         demo_square_f64,         2);
  rb_define_singleton_method(rb_cCArray, "demo_safe_sqrt_f64",      demo_safe_sqrt_f64,      2);
  rb_define_singleton_method(rb_cCArray, "demo_iota_f64",           demo_iota_f64,           3);
}
