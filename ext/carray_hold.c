/* ---------------------------------------------------------------------------

  Mask gap-fill hold: carry the last valid value forward into masked cells
  along one axis.  Backing primitive for `unmask(method:)` / `strip_mask(method:)`
  (see devel/PROPOSAL_UNMASK_FILL_METHOD.md).

  Hold copies a cell's bytes into masked cells with no arithmetic and no
  per-dtype behavior, so a single ca->bytes-width memcpy walk covers every
  data_type -- numeric, complex, bool, object (VALUE-slot byte copy of an
  already-live value), fixlen, and Face storage.  This native does forward
  hold along one axis only and returns a fresh same-shape entity; the
  backward variant (flip -> forward -> flip), flatten, and the linear method
  are composed in the Ruby wrapper.

---------------------------------------------------------------------------- */

#include <stdint.h>
#include <string.h>
#include "ruby.h"
#include "carray.h"
#include "ca_kernel_iterator.h"
#include "ca_obj_face.h"

/* Forward hold along `axis`.  Per fiber along the scan axis:
     - present cell         -> output = cell value, becomes the held value;
     - masked after a value -> output = held value, unmasked;
     - masked before any value (leading run) -> output stays masked (UNDEF),
       since there is no value to carry (hold has no identity). */
static VALUE
rb_ca_hold_forward (VALUE self, int axis)
{
  CArray *ca, *co;
  GetCArray(self, ca);

  /* Storage-typed same-shape entity.  Deliberately not rb_ca_template(), which
     re-wraps a Face in its own class: the walk below indexes op_mask off the
     raw contiguous buffer, so it needs the entity, and the Face identity is
     put back once at the end (CA_FACE_LIFT_IF_FACE). */
  volatile VALUE vout = ca_wrap_struct(ca_template_safe(ca));
  GetCArray(vout, co);

  ca_size_t K = co->bytes;

  int8_t slab_axes[CA_RANK_MAX];
  slab_axes[0] = (int8_t) axis;

  ca_iter_state st_in, st_out;
  int rc = ca_iter_state_init_l2(&st_in, ca, CA_SLAB_AXES, slab_axes, 1, 0);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "__hold__: input init failed rc=%d", rc);
  }
  rc = ca_iter_state_init_l2(&st_out, co, CA_SLAB_AXES, slab_axes, 1,
                             CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) {
    ca_iter_state_finish(&st_in);
    rb_raise(rb_eRuntimeError, "__hold__: output init failed rc=%d", rc);
  }

  /* Output mask allocated lazily on the first leading-masked (UNDEF) cell:
     a fiber can only go UNDEF on a leading masked run, so a fully filled
     result carries no mask at all.  op_mask parallels the fresh contiguous
     output value buffer co->ptr. */
  boolean8_t *op_mask = NULL;
  char       *co_root = (char *) co->ptr;

  char       *pi, *po;
  boolean8_t *mi, *mo;
  while ( ca_iter_state_next_slab_axes(&st_in,  &pi, &mi) &&
          ca_iter_state_next_slab_axes(&st_out, &po, &mo) ) {
    ca_size_t   N    = st_in.slab_dims[0];
    ca_size_t   iS   = st_in.slab_strides[0];        /* input data byte stride */
    ca_size_t   oS   = st_out.slab_strides[0];       /* output data byte stride */
    ca_size_t   iMS  = st_in.slab_mask_strides[0];   /* input mask element stride */
    ca_size_t   oMStep = oS / K;                     /* output mask element step */
    ca_size_t   oMBase = (ca_size_t)(po - co_root) / K;
    const char *held = NULL;   /* last valid cell (points into input slab) */

    for ( ca_size_t j = 0; j < N; j++ ) {
      const char *ci  = pi + j * iS;
      char       *cor = po + j * oS;
      if ( mi == NULL || ! mi[j * iMS] ) {
        memcpy(cor, ci, (size_t) K);
        held = ci;
      }
      else if ( held != NULL ) {
        memcpy(cor, held, (size_t) K);   /* carry last valid, unmasked */
      }
      else {
        memcpy(cor, ci, (size_t) K);     /* leading run: value slot masked */
        if ( op_mask == NULL ) {
          ca_create_mask(co);
          op_mask = (boolean8_t *) co->mask->ptr;
        }
        op_mask[oMBase + j * oMStep] = 1;
      }
    }
    ca_iter_state_sync_slab(&st_out);
  }
  ca_iter_state_finish(&st_in);
  ca_iter_state_finish(&st_out);

  CA_FACE_LIFT_IF_FACE(vout, self, ca);
  return vout;
}

/* __hold__(axis): private forward-hold primitive.  axis is a required
   Integer (negative counts from the end).  The Ruby wrapper composes
   backward / flatten / linear on top of this. */
static VALUE
rb_ca_hold_method (VALUE self, VALUE raxis)
{
  CArray *ca;
  GetCArray(self, ca);
  int axis = NUM2INT(raxis);
  if ( axis < 0 ) axis += ca->ndim;
  if ( axis < 0 || axis >= ca->ndim ) {
    rb_raise(rb_eArgError, "__hold__: axis %d out of range for ndim %d",
             NUM2INT(raxis), ca->ndim);
  }
  return rb_ca_hold_forward(self, axis);
}

/* first / last: the reduction sibling of hold.  Reduce each fiber to its
   first (backward = 0) or last (backward = 1) valid (unmasked) value.
   Byte-generic like hold, and identity-less: a fiber with no valid cell
   (all masked, or empty) yields UNDEF.  A user who wants a default instead
   of UNDEF completes at the call site: `a.first(axis: 0).strip_mask(v)`. */
static VALUE
rb_ca_first_last_reduce (VALUE self, int argc, VALUE *argv, int backward)
{
  CArray *ca, *co;
  GetCArray(self, ca);

  volatile VALUE ropt = rb_pop_options(&argc, &argv);
  volatile VALUE raxis = Qnil, rkeep_axis = Qnil;
  rb_scan_options(ropt, "axis,keep_axis", &raxis, &rkeep_axis);
  if ( argc > 0 ) {
    rb_raise(rb_eArgError,
             "%s: positional axis is not accepted (got %d); use axis: kwarg "
             "(e.g. a.%s(axis: 0) or a.%s(axis: [0, 1]))",
             backward ? "last" : "first", argc,
             backward ? "last" : "first", backward ? "last" : "first");
  }
  int keep_axis = RTEST(rkeep_axis);
  int8_t slab_axes[CA_RANK_MAX];
  int8_t naxes = rb_ca_parse_reduce_axes_kw(raxis, ca, slab_axes);

  ca_size_t K = ca->bytes;
  volatile VALUE vout = rb_ca_new_reduced_bytes(self, slab_axes, naxes,
                                                ca->data_type, K, keep_axis);
  GetCArray(vout, co);
  char *op = (char *) co->ptr;

  ca_iter_state st;
  int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, slab_axes, naxes, 0);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "%s: kernel_iterator init failed rc=%d",
             backward ? "last" : "first", rc);
  }

  char       *p;
  boolean8_t *m;
  ca_size_t   out_i   = 0;
  boolean8_t *op_mask = NULL;   /* lazily allocated on the first empty fiber */
  while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
    const char *found  = NULL;
    int8_t      sndim  = st.slab_ndim;
    ca_size_t   total  = st.slab_elements;
    ca_size_t   sidx[CA_RANK_MAX] = { 0 };
    for ( ca_size_t idx = 0; idx < total; idx++ ) {
      ca_size_t doff = 0, moff = 0;
      for ( int8_t sk = 0; sk < sndim; sk++ ) {
        doff += sidx[sk] * st.slab_strides[sk];
        moff += sidx[sk] * st.slab_mask_strides[sk];
      }
      if ( m == NULL || ! m[moff] ) {
        found = (const char *) p + doff;
        if ( ! backward ) break;   /* first: take the first present cell */
      }                            /* last: keep the most recent present  */
      /* row-major odometer (innermost slab axis fastest) */
      for ( int8_t sk = (int8_t)(sndim - 1); sk >= 0; sk-- ) {
        if ( ++sidx[sk] < st.slab_dims[sk] ) break;
        sidx[sk] = 0;
      }
    }
    if ( found == NULL ) {
      if ( ! op_mask ) {
        ca_create_mask(co);
        op_mask = (boolean8_t *) co->mask->ptr;
      }
      op_mask[out_i] = 1;
      memset(op + out_i * K, 0, (size_t) K);   /* sentinel; mask bit counts */
    }
    else {
      memcpy(op + out_i * K, found, (size_t) K);
    }
    out_i++;
  }
  ca_iter_state_finish(&st);

  CA_FACE_LIFT_IF_FACE(vout, self, ca);
  if ( naxes == ca->ndim && !keep_axis ) {
    return rb_ca_fetch_addr(vout, 0);   /* full reduce -> scalar (UNDEF-aware) */
  }
  return vout;
}

/* @overload first(axis: nil, keep_axis: false) */
static VALUE
rb_ca_first (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_first_last_reduce(self, argc, argv, 0);
}

/* @overload last(axis: nil, keep_axis: false) */
static VALUE
rb_ca_last (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_first_last_reduce(self, argc, argv, 1);
}

void
Init_carray_hold (void)
{
  rb_define_private_method(rb_cCArray, "__hold__", rb_ca_hold_method, 1);
  rb_define_method(rb_cCArray, "first", rb_ca_first, -1);
  rb_define_method(rb_cCArray, "last",  rb_ca_last,  -1);
}
