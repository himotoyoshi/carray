/* spec_ai/ext_sweep_raw/sweep_raw.c
 *
 * TEST FIXTURE -- drives the raw sweep bridge the way an ext author does
 * when it allocates the output itself: out = a + b over float64 operands,
 * with no typed layer in front to check or template the shapes.  Both the
 * whole-buffer path (ca_call_cfunc_3) and the chunked path
 * (ca_call_cslab_3) are exposed.
 */

#include "carray.h"

static void
add_cell (void *p_out, void *p_a, void *p_b)
{
  *(double *) p_out = *(double *) p_a + *(double *) p_b;
}

static void
add_slab (char **base, ca_size_t *stride, ca_size_t n, const boolean8_t *m0)
{
  ca_size_t k;
  for (k = 0; k < n; k++) {
    if (m0 && m0[k]) continue;
    *(double *)(base[0] + k * stride[0]) =
      *(double *)(base[1] + k * stride[1]) +
      *(double *)(base[2] + k * stride[2]);
  }
}

static VALUE
sweep_raw_add (VALUE self, VALUE out, VALUE a, VALUE b)
{
  return ca_call_cfunc_3(add_cell, "100", out, a, b);
}

static VALUE
sweep_raw_add_slab (VALUE self, VALUE out, VALUE a, VALUE b)
{
  return ca_call_cslab_3(add_slab, "100", out, a, b);
}

void
Init_sweep_raw (void)
{
  rb_define_singleton_method(rb_cCArray, "__sweep_raw_add__",
                             sweep_raw_add, 3);
  rb_define_singleton_method(rb_cCArray, "__sweep_raw_add_slab__",
                             sweep_raw_add_slab, 3);
}
