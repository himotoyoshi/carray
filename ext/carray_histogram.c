/* ---------------------------------------------------------------------------

  Private histogram kernels called from lib/carray/histogram.rb (and
  lib/carray/bincount_nd.rb for the discrete sibling):
    histbin_ki(edges, include_max)          val=self extended binning
    histogram_scatter_ki(counts, edges,     fused per-sample scatter
                         incmax, weights)   into extended counts
    bincount_nd_count_ki(counts, weights)   discrete joint count (fiber)

  Extended bin index layout produced by the binning helpers:
    0        under  (v < edges[0])
    1..n     in-range bin 0..n-1
    n+1      over   (v >= edges[-1], unless include_max snaps to n)

  Orientation is val=self: the data array drives the output shape,
  edges is a constant operand.  Sample data is delivered strided via
  the kernel_iterator (CA_FOR_EACH_FIBER_INOUT_MASKED / SLAB_AXES) so
  channel views over a joint sample array are not materialised; only
  `edges` (small, constant) is attached.

  histbin_ki self must be float64 (Ruby side coerces).

---------------------------------------------------------------------------- */

#include "carray.h"
#include <math.h>

/* Resolve `redges` to a contiguous, attached, 1-D float64 CArray.
   Returns the CArray* and (via out params) the data pointer + element
   count.  Caller must ca_detach when done. */
static CArray *
histbin_attach_edges (VALUE self, VALUE redges, double **ep_out, ca_size_t *ne_out)
{
  CArray *ce;

  if ( ! rb_obj_is_carray(redges) ) {
    redges = rb_ca_wrap_readonly(redges, INT2NUM(CA_FLOAT64));
  }
  GetCArray(redges, ce);

  if ( ce->data_type != CA_FLOAT64 ) {
    redges = rb_ca_wrap_readonly(redges, INT2NUM(CA_FLOAT64));
    GetCArray(redges, ce);
  }
  if ( ce->ndim != 1 ) {
    rb_raise(rb_eArgError, "histbin_ki: edges must be 1-D");
  }
  if ( ce->elements < 2 ) {
    rb_raise(rb_eArgError, "histbin_ki: edges needs at least 2 values");
  }

  ca_attach(ce);
  *ep_out = (double *) ce->ptr;
  *ne_out = ce->elements;
  return ce;
}

/* ---- shared binning helpers (used by histbin_ki + the fused kernel) ---- */

typedef struct {
  const double *ep;
  ca_size_t     n;            /* number of bins */
  double        lo, hi, inv_dx;
  int           uniform;
  int           include_max;
} histbin_axis_t;

/* Extended index 0..n+1 for finite v (caller handles NaN / masked cells).
   The uniform fast path's linearised floor is corrected against the actual
   stored edges, so boundary values bin identically to the binary-search
   path — exact, no relative-tolerance "snap" magic.  Correction is normally
   0 iterations; it fires only for the ~few values sitting on / within a ULP
   of an edge where (v-lo)*inv_dx rounds to the wrong side. */
static inline ca_size_t
histbin_index (const histbin_axis_t *ax, double v)
{
  if ( v < ax->lo ) return 0;                          /* under */
  if ( v >= ax->hi )
    return (ax->include_max && v == ax->hi) ? ax->n    /* top bin */
                                            : ax->n + 1; /* over */
  if ( ax->uniform ) {
    double    pos = (v - ax->lo) * ax->inv_dx;
    ca_size_t k   = (ca_size_t) floor(pos);
    double    frac;
    if ( k >= ax->n ) k = ax->n - 1;                   /* float guard near hi */
    /* Only values sitting within a hair of a bin boundary can be on the wrong
       side of the linearised floor; verify just those against the real edges.
       Interior values (the bulk) skip the data-dependent edge loads, keeping
       the fast path vectorisable. */
    frac = pos - (double) k;
    if ( frac < 1e-9 || frac > 1.0 - 1e-9 ) {
      while ( k + 1 < ax->n && v >= ax->ep[k + 1] ) k++;
      while ( k > 0       && v <  ax->ep[k]     ) k--;
    }
    return k + 1;
  }
  else {
    ca_size_t a = 0, b = ax->n;                        /* ep[k] <= v < ep[k+1] */
    while ( b - a > 1 ) {
      ca_size_t mid = (a + b) / 2;
      if ( ax->ep[mid] <= v ) a = mid; else b = mid;
    }
    return a + 1;
  }
}

static void
histbin_axis_setup (histbin_axis_t *ax, CArray *ce, int include_max)
{
  ca_size_t ne = ce->elements, kk;
  double    dx, tol;

  ax->ep = (const double *) ce->ptr;
  ax->n  = ne - 1;
  ax->lo = ax->ep[0];
  ax->hi = ax->ep[ne - 1];
  dx     = (ax->hi - ax->lo) / (double) ax->n;
  tol    = fabs(dx) * 1e-9 + 1e-12;
  ax->uniform = 1;
  for ( kk = 0; kk <= ax->n; kk++ ) {
    if ( fabs(ax->ep[kk] - (ax->lo + (double) kk * dx)) > tol ) { ax->uniform = 0; break; }
  }
  ax->inv_dx      = (dx != 0.0) ? 1.0 / dx : 0.0;
  ax->include_max = include_max;
}

static VALUE
rb_ca_histbin_ki (VALUE self, VALUE redges, VALUE rinclude_max)
{
  CArray         *ca, *co, *ce;
  VALUE           vout;
  double         *ep;
  ca_size_t       ne;
  histbin_axis_t  ax;

  GetCArray(self, ca);
  if ( ca->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eCADataTypeError,
             "histbin_ki: self must be float64 (got %s)",
             ca_type_name[ca->data_type]);
  }

  ce = histbin_attach_edges(self, redges, &ep, &ne);
  (void) ep; (void) ne;                  /* axis setup reads ce directly */
  histbin_axis_setup(&ax, ce, RTEST(rinclude_max));

  /* output: fresh contiguous int64, same shape as self. */
  vout = rb_carray_new(CA_INT64, ca->ndim, ca->dim, 0, NULL);
  GetCArray(vout, co);

  if ( ca->elements > 0 ) {
    ca_iter_state st_in, st_out;
    char         *p_in, *p_out;
    boolean8_t   *m;
    boolean8_t   *omask = NULL;       /* lazily created on first masked cell */
    ca_size_t     out_pos = 0;        /* flat element offset of current fiber */
    int8_t        axis = (int8_t) (ca->ndim - 1);
    ca_size_t     i, nfib;

    CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, ca, co, axis, 0,
                                   p_in, p_out, nfib, m) {
      const double  *vp = (const double *) p_in;
      int64_t       *op = (int64_t *)      p_out;

      for ( i = 0; i < nfib; i++ ) {
        double v = vp[i];
        if ( (m && m[i]) || isnan(v) ) {
          if ( ! omask ) {
            ca_create_mask(co);
            omask = (boolean8_t *) co->mask->ptr;
          }
          omask[out_pos + i] = 1;
          op[i] = 0;
          continue;
        }
        op[i] = (int64_t) histbin_index(&ax, v);
      }
      out_pos += nfib;
    }
  }

  ca_detach(ce);

  return vout;
}

/* ===========================================================================
   histogram_scatter_ki — fused histogram scatter over M channels per
   sample, writing directly into the extended counts buffer with no
   intermediate index arrays (peak-memory minimal).

     self    = chunk transposed to [fiber..., A, M].
     counts  = [fiber..., ext_0..ext_{M-1}] (int64 unweighted / float64 weighted).
     weights = nil (unweighted, +1) OR float64 [fiber..., A] delivered by
               a second iterator in lockstep so weights[fiber, a] aligns
               with sample a of the chunk slab (no materialise).

   Per fiber slab (slab axes = [sample, channel], outer = fiber):
     fiber_base = Σ outer_idx[mm] * fiber_stride[mm]
     for each sample a: union mask across channels; else
       off = fiber_base + Σ_k histbin_index(axis_k, v_{a,k}) * ext_stride[k]
       counts[off] += 1  (or += weight when weighted)
   =========================================================================== */
static VALUE
rb_ca_histogram_scatter_ki (VALUE self, VALUE rcounts, VALUE redges,
                            VALUE rincmax, VALUE rweights)
{
  CArray         *ca, *cc, *cw = NULL;
  long            M, nf, k;
  int             weighted;
  histbin_axis_t  axes[CA_RANK_MAX];
  CArray         *edge_ca[CA_RANK_MAX];
  ca_size_t       ext_stride[CA_RANK_MAX];
  ca_size_t       fiber_stride[CA_RANK_MAX];
  ca_size_t       total_ext, s;

  GetCArray(self, ca);
  GetCArray(rcounts, cc);
  Check_Type(redges, T_ARRAY);
  Check_Type(rincmax, T_ARRAY);
  M = RARRAY_LEN(redges);
  weighted = ! NIL_P(rweights);

  if ( ca->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eCADataTypeError, "histogram_scatter_ki: self must be float64");
  }
  if ( weighted ) {
    GetCArray(rweights, cw);
    if ( cw->data_type != CA_FLOAT64 ) {
      rb_raise(rb_eCADataTypeError, "histogram_scatter_ki: weights must be float64");
    }
    if ( cc->data_type != CA_FLOAT64 ) {
      rb_raise(rb_eCADataTypeError, "histogram_scatter_ki: weighted counts must be float64");
    }
    if ( cw->ndim != ca->ndim - 1 ) {
      rb_raise(rb_eArgError,
               "histogram_scatter_ki: weights ndim %d != fiber+sample", cw->ndim);
    }
  }
  else if ( cc->data_type != CA_INT64 ) {
    rb_raise(rb_eCADataTypeError, "histogram_scatter_ki: unweighted counts must be int64");
  }
  nf = cc->ndim - M;
  if ( nf < 0 ) {
    rb_raise(rb_eArgError, "histogram_scatter_ki: counts ndim %d < M %ld", cc->ndim, M);
  }
  if ( ca->ndim != nf + 2 ) {
    rb_raise(rb_eArgError,
             "histogram_scatter_ki: self ndim %d != fiber(%ld)+sample+channel",
             ca->ndim, nf);
  }
  if ( (long) ca->dim[ca->ndim - 1] != M ) {
    rb_raise(rb_eArgError,
             "histogram_scatter_ki: self channel axis %d != M %ld",
             (int) ca->dim[ca->ndim - 1], M);
  }

  for ( k = 0; k < M; k++ ) {
    VALUE e = RARRAY_AREF(redges, k);
    GetCArray(e, edge_ca[k]);
    ca_attach(edge_ca[k]);
    histbin_axis_setup(&axes[k], edge_ca[k], RTEST(RARRAY_AREF(rincmax, k)));
  }

  /* ext strides (row-major within the trailing M bin axes of counts). */
  total_ext = 1;
  for ( k = M - 1; k >= 0; k-- ) {
    ext_stride[k] = total_ext;
    total_ext *= cc->dim[nf + k];
  }
  /* fiber strides already fold in total_ext: counts flat = fiber_base + bin_off. */
  s = total_ext;
  for ( k = nf - 1; k >= 0; k-- ) {
    fiber_stride[k] = s;
    s *= cc->dim[k];
  }

  if ( ca->elements > 0 ) {
    int64_t      *cpi = (int64_t *) cc->ptr;   /* unweighted */
    double       *cpd = (double *)  cc->ptr;   /* weighted   */
    ca_iter_state st, stw;
    char         *p, *pw = NULL;
    boolean8_t   *m, *mw = NULL;
    ca_size_t     cur_outer_idx[CA_RANK_MAX];
    int8_t        slab_axes[2] = { (int8_t)(ca->ndim - 2), (int8_t)(ca->ndim - 1) };
    int8_t        w_slab_axes[1] = { (int8_t)(ca->ndim - 2) };  /* weights sample axis */
    int8_t        mm;
    int           rc;

    rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, slab_axes, 2, 0);
    if ( rc != CA_ITER_OK ) {
      for ( k = 0; k < M; k++ ) ca_detach(edge_ca[k]);
      rb_raise(rb_eRuntimeError, "histogram_scatter_ki: iter init failed rc=%d", rc);
    }
    if ( weighted ) {
      rc = ca_iter_state_init_l2(&stw, cw, CA_SLAB_AXES, w_slab_axes, 1, 0);
      if ( rc != CA_ITER_OK ) {
        ca_iter_state_finish(&st);
        for ( k = 0; k < M; k++ ) ca_detach(edge_ca[k]);
        rb_raise(rb_eRuntimeError, "histogram_scatter_ki: weights iter init failed rc=%d", rc);
      }
    }
    for ( mm = 0; mm < st.outer_ndim; mm++ ) cur_outer_idx[mm] = 0;

    while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
      ca_size_t fiber_base = 0;
      ca_size_t A, a, kk;
      ca_size_t ss, cs, sms, cms, ws = 0, wms = 0;

      if ( weighted && ! ca_iter_state_next_slab_axes(&stw, &pw, &mw) ) break;

      for ( mm = 0; mm < st.outer_ndim; mm++ )
        fiber_base += cur_outer_idx[mm] * fiber_stride[mm];

      A   = st.slab_dims[0];               /* samples */
      ss  = st.slab_strides[0];            /* sample byte stride */
      cs  = st.slab_strides[1];            /* channel byte stride */
      sms = st.slab_mask_strides[0];
      cms = st.slab_mask_strides[1];
      if ( weighted ) {
        ws  = stw.slab_strides[0];
        wms = stw.slab_mask_strides[0];
      }

      for ( a = 0; a < A; a++ ) {
        ca_size_t off = fiber_base;
        int       masked = 0;
        for ( kk = 0; kk < (ca_size_t) M; kk++ ) {
          double v = *(const double *)(p + a * ss + kk * cs);
          if ( (m && m[a * sms + kk * cms]) || isnan(v) ) { masked = 1; break; }
          off += histbin_index(&axes[kk], v) * ext_stride[kk];
        }
        if ( masked ) continue;
        if ( weighted ) {
          double w = *(const double *)(pw + a * ws);
          if ( (mw && mw[a * wms]) || isnan(w) ) continue;  /* skip masked / NaN weight */
          cpd[off] += w;
        }
        else {
          cpi[off] += 1;
        }
      }

      for ( mm = (int8_t)(st.outer_ndim - 1); mm >= 0; mm-- ) {
        if ( ++cur_outer_idx[mm] < st.outer_dims[mm] ) break;
        cur_outer_idx[mm] = 0;
      }
    }
    ca_iter_state_finish(&st);
    if ( weighted ) ca_iter_state_finish(&stw);
  }

  for ( k = 0; k < M; k++ ) ca_detach(edge_ca[k]);

  return rcounts;
}

/* ===========================================================================
   bincount_nd_count_ki — discrete sibling of histogram_scatter_ki for
   the fiber case.  Value == bin index directly; the upper overflow cell
   (ext_k-1) absorbs v >= ext_k-1.  Labels dispatch on their native
   integer type so int32 input is read without coercion / materialise.

   The flat case is handled on the Ruby side (ravel + bincount).  Negative
   labels are rejected on the Ruby side before this kernel runs, so here
   v >= 0 is assumed.

     self    = chunk [fiber..., A, M] (integer).
     counts  = [fiber..., ext_0..ext_{M-1}] (int64 / float64).
     weights = nil OR float64 [fiber..., A] (second iterator in lockstep).
   =========================================================================== */

#define BINCOUNT_ND_BODY(LABEL_T)                                              \
  do {                                                                         \
    while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {                      \
      ca_size_t fiber_base = 0, A, a, kk, ss, cs, sms, cms, ws = 0, wms = 0;   \
      if ( weighted && ! ca_iter_state_next_slab_axes(&stw, &pw, &mw) ) break; \
      for ( mm = 0; mm < st.outer_ndim; mm++ )                                \
        fiber_base += cur_outer_idx[mm] * fiber_stride[mm];                    \
      A = st.slab_dims[0]; ss = st.slab_strides[0]; cs = st.slab_strides[1];   \
      sms = st.slab_mask_strides[0]; cms = st.slab_mask_strides[1];            \
      if ( weighted ) { ws = stw.slab_strides[0]; wms = stw.slab_mask_strides[0]; } \
      for ( a = 0; a < A; a++ ) {                                             \
        ca_size_t off = fiber_base; int masked = 0;                           \
        for ( kk = 0; kk < (ca_size_t) M; kk++ ) {                            \
          int64_t v = (int64_t) *(const LABEL_T *)(p + a * ss + kk * cs);     \
          if ( m && m[a * sms + kk * cms] ) { masked = 1; break; }            \
          if ( v >= ext_dim[kk] - 1 ) v = ext_dim[kk] - 1;                    \
          off += (ca_size_t) v * ext_stride[kk];                             \
        }                                                                     \
        if ( masked ) continue;                                              \
        if ( weighted ) {                                                    \
          double w = *(const double *)(pw + a * ws);                         \
          if ( (mw && mw[a * wms]) || isnan(w) ) continue;                   \
          cpd[off] += w;                                                     \
        } else { cpi[off] += 1; }                                            \
      }                                                                       \
      for ( mm = (int8_t)(st.outer_ndim - 1); mm >= 0; mm-- ) {              \
        if ( ++cur_outer_idx[mm] < st.outer_dims[mm] ) break;                \
        cur_outer_idx[mm] = 0;                                               \
      }                                                                       \
    }                                                                         \
  } while (0)

static VALUE
rb_ca_bincount_nd_count_ki (VALUE self, VALUE rcounts, VALUE rweights)
{
  CArray   *ca, *cc, *cw = NULL;
  long      M, nf, k;
  int       weighted;
  ca_size_t ext_dim[CA_RANK_MAX], ext_stride[CA_RANK_MAX], fiber_stride[CA_RANK_MAX];
  ca_size_t total_ext, s;

  GetCArray(self, ca);
  GetCArray(rcounts, cc);
  weighted = ! NIL_P(rweights);
  M  = ca->dim[ca->ndim - 1];
  nf = cc->ndim - M;
  if ( nf < 0 || ca->ndim != nf + 2 ) {
    rb_raise(rb_eArgError, "bincount_nd_count_ki: shape mismatch");
  }
  if ( weighted ) {
    GetCArray(rweights, cw);
    if ( cw->data_type != CA_FLOAT64 || cc->data_type != CA_FLOAT64 ) {
      rb_raise(rb_eCADataTypeError, "bincount_nd_count_ki: weighted needs float64 weights/counts");
    }
  }
  else if ( cc->data_type != CA_INT64 ) {
    rb_raise(rb_eCADataTypeError, "bincount_nd_count_ki: unweighted counts must be int64");
  }

  total_ext = 1;
  for ( k = M - 1; k >= 0; k-- ) {
    ext_dim[k] = cc->dim[nf + k]; ext_stride[k] = total_ext; total_ext *= ext_dim[k];
  }
  s = total_ext;
  for ( k = nf - 1; k >= 0; k-- ) { fiber_stride[k] = s; s *= cc->dim[k]; }

  if ( ca->elements > 0 ) {
    int64_t      *cpi = (int64_t *) cc->ptr;
    double       *cpd = (double *)  cc->ptr;
    ca_iter_state st, stw;
    char         *p, *pw = NULL;
    boolean8_t   *m, *mw = NULL;
    ca_size_t     cur_outer_idx[CA_RANK_MAX];
    int8_t        slab_axes[2] = { (int8_t)(ca->ndim - 2), (int8_t)(ca->ndim - 1) };
    int8_t        w_slab_axes[1] = { (int8_t)(ca->ndim - 2) };
    int8_t        mm;
    int           rc;

    rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, slab_axes, 2, 0);
    if ( rc != CA_ITER_OK ) rb_raise(rb_eRuntimeError, "bincount_nd_count_ki: iter init %d", rc);
    if ( weighted ) {
      rc = ca_iter_state_init_l2(&stw, cw, CA_SLAB_AXES, w_slab_axes, 1, 0);
      if ( rc != CA_ITER_OK ) { ca_iter_state_finish(&st); rb_raise(rb_eRuntimeError, "weights iter %d", rc); }
    }
    for ( mm = 0; mm < st.outer_ndim; mm++ ) cur_outer_idx[mm] = 0;

    switch ( ca->data_type ) {
    case CA_INT8:   BINCOUNT_ND_BODY(int8_t);   break;
    case CA_UINT8:  BINCOUNT_ND_BODY(uint8_t);  break;
    case CA_INT16:  BINCOUNT_ND_BODY(int16_t);  break;
    case CA_UINT16: BINCOUNT_ND_BODY(uint16_t); break;
    case CA_INT32:  BINCOUNT_ND_BODY(int32_t);  break;
    case CA_UINT32: BINCOUNT_ND_BODY(uint32_t); break;
    case CA_INT64:  BINCOUNT_ND_BODY(int64_t);  break;
    case CA_UINT64: BINCOUNT_ND_BODY(uint64_t); break;
    default:
      ca_iter_state_finish(&st);
      if ( weighted ) ca_iter_state_finish(&stw);
      rb_raise(rb_eCADataTypeError, "bincount_nd_count_ki: integer labels required");
    }
    ca_iter_state_finish(&st);
    if ( weighted ) ca_iter_state_finish(&stw);
  }

  return rcounts;
}

#undef BINCOUNT_ND_BODY

void
Init_carray_histogram (void)
{
  rb_define_private_method(rb_cCArray, "histbin_ki", rb_ca_histbin_ki, 2);
  rb_define_private_method(rb_cCArray, "histogram_scatter_ki",
                           rb_ca_histogram_scatter_ki, 4);
  rb_define_private_method(rb_cCArray, "bincount_nd_count_ki",
                           rb_ca_bincount_nd_count_ki, 2);
}
