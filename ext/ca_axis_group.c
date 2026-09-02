/* ---------------------------------------------------------------------------

  Axis-group compute kernels: the grouped reduction and the grouped segment
  scan.

  INTERNAL kernels behind `__...__`-named methods.  The user-facing surface
  (CACategorical / AxisGroup type gate in `[]`, CAGroupIterator, the :group
  reduce dispatch, GroupLabels) is wired in ca_group_iter.c (the `[]` gate and
  the iterator) + `axis_group` (lib/carray/axis_group.rb).  Both kernels are
  written in the general form: several group axes + rank-N categorical (an N-D
  codes map) via a per-slab-element composite code, native data type dispatch,
  mask support.  They take pre-built code bundles, so they are independent of
  how the classifier is constructed.

  Mechanism, shared by both kernels:
    - CA_FOR_EACH_SLAB pins the union of grouped source axes as the slab and
      walks the band (= non-grouped) axes in the outer iter.
    - For each slab element a composite group code is computed on the fly from
      the per-bundle code tables (per-axis code, flat-collapsed; a rank-N
      categorical = one bundle consuming more than one source axis).  The
      composite code is never materialised — it is a per-element local.
    - reduce: scatter out[composite * band + b] op= value, sort-free.  Peak
      memory = output + per-group accumulators (O(K*band)), never O(N).
    - scan: emit the running value per element into a source-shaped output
      (see the section comment above `rb_ca_axis_group_scan`).

  Group codes outside [0, k) at any bundle mark the slab element unassigned
  (skipped, contributing to no group) — mirrors digitize OOB.

  Float reductions carry the CArray ε-close contract: relative error bounded,
  not bit-exact.

--------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_kernel_iterator.h"
#include <math.h>

/* op codes */
enum {
  GR_SUM = 0, GR_PROD, GR_MEAN, GR_MIN, GR_MAX,
  GR_VARIANCE, GR_STDDEV, GR_COUNT, GR_ALL, GR_ANY,
  GR_VARIANCEP, GR_STDDEVP, GR_MINADDR, GR_MAXADDR,
  GR_ACCUM
};

static int
group_op_code (VALUE vop)
{
  ID id = SYM2ID(vop);
  if      ( id == rb_intern("sum") )      return GR_SUM;
  else if ( id == rb_intern("accumulate") ) return GR_ACCUM;
  else if ( id == rb_intern("prod") )     return GR_PROD;
  else if ( id == rb_intern("mean") )     return GR_MEAN;
  else if ( id == rb_intern("min") )      return GR_MIN;
  else if ( id == rb_intern("max") )      return GR_MAX;
  else if ( id == rb_intern("variance") ) return GR_VARIANCE;
  else if ( id == rb_intern("stddev") )   return GR_STDDEV;
  else if ( id == rb_intern("variancep") ) return GR_VARIANCEP;
  else if ( id == rb_intern("stddevp") )   return GR_STDDEVP;
  else if ( id == rb_intern("count") )    return GR_COUNT;
  else if ( id == rb_intern("count_not_masked") ) return GR_COUNT;
  else if ( id == rb_intern("min_addr") ) return GR_MINADDR;
  else if ( id == rb_intern("max_addr") ) return GR_MAXADDR;
  else if ( id == rb_intern("all") )      return GR_ALL;
  else if ( id == rb_intern("any") )      return GR_ANY;
  rb_raise(rb_eArgError, "axis_group_reduce: unsupported op :%s",
           rb_id2name(id));
}

/* ---- per-slab-element composite-code walk, templated on the load type ----

   Reads `*(T *)(p + data_off)` for each slab element, computes the composite
   group code, applies the mask, and folds the value into whichever
   accumulator buffers are non-NULL.  Accumulation is always in `double` (or
   counts in ca_size_t), so the op-finalisation below is type-agnostic — only
   the LOAD is monomorphised per data type, keeping the inner loop autovectorisable
   while avoiding a forced float64 materialise of the (large) source. */

/* GROUP_WALK(T, ACCUM): one CA_FOR_EACH_SLAB pass.  For each slab element it
   computes the composite group code, applies the mask, then runs ACCUM with
   `v` (the element, widened to double) and `o` (the output flat index =
   code * band + band_flat) in scope.  ACCUM is the only per-op-varying part,
   so the data type is monomorphised once per type while sum / mean / variance /
   ... reuse the same walk. */
/* Sentinel o-code for a slab element whose composite code is out of range
   (excluded categorical), stored in the precomputed plan below. */
#define GW_SKIP (~(ca_size_t) 0)

/* CAREFUL: the slab-emission counter `b` is used directly as the band flat
   index of the output — here and in the scan walks below.  That identity holds
   only because the outer iter advances row-major over the complement axes in
   ascending source order (next_slab_axes in ca_kernel_iterator.c).  If that
   iteration order changes, every band lands in the wrong output row and
   nothing raises. */

/* The composite code, data/mask byte offsets and (for min_addr / max_addr) the
   group-relative source address of a slab element depend only on the slab
   odometer position, not on the band.  So they are identical for every band.
   Precompute them once (on the first band, O(slab_elements) = O(group_prod)
   metadata) and let each band pass just gather the plan + scatter.  This keeps
   the composite-code bundle walk and the odometer out of the per-(band x
   element) hot path.  Peak memory stays O(output + group_prod), not O(input). */
#define GROUP_WALK(T, ACCUM)                                                   \
  do {                                                                         \
    ca_iter_state st;                                                          \
    char       *p;                                                             \
    boolean8_t *m;                                                             \
    ca_size_t   b = 0;                                                         \
    ca_size_t  *gw_ocode = NULL, *gw_doff = NULL, *gw_moff = NULL,             \
               *gw_gaddr = NULL;                                               \
    int         gw_ready = 0;                                                  \
    int         gw_need_addr = ( op == GR_MINADDR || op == GR_MAXADDR );       \
    CA_FOR_EACH_SLAB(st, ca, axes, (int8_t) ngroup, CA_KERNEL_READ, p, m) {    \
      int8_t    sndim = st.slab_ndim;                                          \
      ca_size_t SE    = st.slab_elements;                                      \
      if ( SE > 0 ) {                                                          \
        if ( ! gw_ready ) {                                                    \
          gw_ocode = ALLOC_N(ca_size_t, SE);                                   \
          gw_doff  = ALLOC_N(ca_size_t, SE);                                   \
          gw_moff  = ALLOC_N(ca_size_t, SE);                                   \
          gw_gaddr = ALLOC_N(ca_size_t, SE);                                   \
          ca_size_t sidx[CA_RANK_MAX];                                         \
          for ( int8_t k = 0; k < sndim; k++ ) sidx[k] = 0;                    \
          for ( ca_size_t e = 0; e < SE; e++ ) {                               \
            /* composite group code from the per-bundle code tables */         \
            int       skip = 0;                                                \
            ca_size_t code = 0;                                                \
            for ( int bi = 0; bi < n_bundles; bi++ ) {                         \
              ca_size_t sub = 0;                                               \
              for ( int j = 0; j < bundle_nconsumed[bi]; j++ )                 \
                sub += sidx[ bundle_slot[bi][j] ] * bundle_cstride[bi][j];     \
              int32_t c = bundle_codes[bi][sub];                               \
              if ( c < 0 || (ca_size_t) c >= bundle_k[bi] ) { skip = 1; break; } \
              code += (ca_size_t) c * bundle_placeval[bi];                     \
            }                                                                  \
            ca_size_t doff = 0, moff = 0, gaddr = 0;                           \
            for ( int8_t k = 0; k < sndim; k++ ) {                             \
              doff += sidx[k] * st.slab_strides[k];                            \
              if ( m ) moff += sidx[k] * st.slab_mask_strides[k];             \
            }                                                                  \
            if ( gw_need_addr )                                                \
              for ( long s = 0; s < ngroup; s++ )                             \
                gaddr += (ca_size_t) sidx[s] * grstride[s];                    \
            gw_ocode[e] = skip ? GW_SKIP : code * band;                        \
            gw_doff[e]  = doff;                                                \
            gw_moff[e]  = moff;                                                \
            gw_gaddr[e] = gaddr;                                               \
            /* odometer advance (last slab axis ticks fastest) */             \
            for ( int8_t k = sndim - 1; k >= 0; k-- ) {                       \
              if ( ++sidx[k] < st.slab_dims[k] ) break;                       \
              sidx[k] = 0;                                                     \
            }                                                                  \
          }                                                                    \
          gw_ready = 1;                                                        \
        }                                                                      \
        for ( ca_size_t e = 0; e < SE; e++ ) {                                 \
          ca_size_t oc = gw_ocode[e];                                          \
          if ( oc == GW_SKIP ) continue;                                       \
          if ( m && m[ gw_moff[e] ] ) continue;                                \
          double    v = (double) ( *(T *)(p + gw_doff[e]) );                   \
          ca_size_t o = oc + b;                                                \
          ca_size_t gaddr = gw_gaddr[e];                                       \
          ACCUM;                                                               \
          (void) v; (void) o; (void) gaddr;                                    \
        }                                                                      \
      }                                                                        \
      b++;                                                                     \
    }                                                                          \
    if ( gw_ocode ) xfree(gw_ocode);                                          \
    if ( gw_doff )  xfree(gw_doff);                                           \
    if ( gw_moff )  xfree(gw_moff);                                           \
    if ( gw_gaddr ) xfree(gw_gaddr);                                          \
  } while (0)

/* Run one walk over every supported native data type.  Dispatched on the source
   data_type so the inner loop stays monomorphic (no forced float64 cast). */
#define GROUP_DISPATCH(ACCUM)                                                  \
  switch ( ca->data_type ) {                                                   \
  case CA_BOOLEAN: GROUP_WALK(boolean8_t, ACCUM); break;                       \
  case CA_INT8:    GROUP_WALK(int8_t,     ACCUM); break;                       \
  case CA_UINT8:   GROUP_WALK(uint8_t,    ACCUM); break;                       \
  case CA_INT16:   GROUP_WALK(int16_t,    ACCUM); break;                       \
  case CA_UINT16:  GROUP_WALK(uint16_t,   ACCUM); break;                       \
  case CA_INT32:   GROUP_WALK(int32_t,    ACCUM); break;                       \
  case CA_UINT32:  GROUP_WALK(uint32_t,   ACCUM); break;                       \
  case CA_INT64:   GROUP_WALK(int64_t,    ACCUM); break;                       \
  case CA_UINT64:  GROUP_WALK(uint64_t,   ACCUM); break;                       \
  case CA_FLOAT32: GROUP_WALK(float,      ACCUM); break;                       \
  case CA_FLOAT64: GROUP_WALK(double,     ACCUM); break;                       \
  default: break;                                                              \
  }

/* `accumulate` is the one op that folds in the SOURCE's own type instead of in
   double, so it wraps at that width exactly as CArray#accumulate does.  It
   folds straight into the (zeroed) output — whose data type is the source's —
   so an empty group already holds the additive identity 0 and needs no mask.
   The type cannot travel inside a GROUP_WALK ACCUM argument (an argument's own
   tokens are not substituted for the macro's parameters), so the walk below
   names its type twice. */
#define GACC_ADD(T) ( ((T *) co->ptr)[o] += *(T *)(p + gw_doff[e]) )
/* A boolean accumulate is XOR parity, matching the core: the result stays
   boolean, so a second `true` has nowhere to carry into. */
#define GACC_XOR \
  ( ((boolean8_t *) co->ptr)[o] ^= (*(boolean8_t *)(p + gw_doff[e]) ? 1 : 0) )

/* __axis_group_reduce__(group_axes, bundles, op) — group-reduces self along
 * the union of `group_axes` (ascending source-axis indices = the slab) into
 * composite groups described by `bundles`, preserving the band (= non-grouped)
 * axes.  Internal: the Ruby surface is CAGroupIterator.

   bundles: Array of [codes, k, bundle_axes]
     - codes       : integer CArray, row-major over `bundle_axes` dims, giving
                     the group code in [0, k) for each cell of the consumed
                     axes (rank-1 = per-axis classifier; rank-N = one bundle
                     consuming >1 source axes = non-rectangular categorical).
     - k           : Integer, group count for this bundle.
     - bundle_axes : Array of source-axis indices this bundle consumes
                     (in the row-major order matching `codes`).

   The bundles' axes together equal `group_axes` (as a set).  Output shape is
   [K_total, *band_dims] with K_total = Π k over bundles (bundle 0 most
   significant, row-major) and band_dims = the non-grouped source dims in
   ascending order.  The Ruby surface reshapes the leading K_total axis into
   the individual group axes.

   op: :sum :prod :mean :min :max :variance :stddev :variancep :stddevp
   :count (:count_not_masked is a synonym) :min_addr :max_addr :all :any.
   :min_addr / :max_addr return the flat raveled source address of the group's
   extremum, not a group-local index.

   Empty / all-masked groups follow the CArray zero-contribution contract: an
   identity-bearing op returns its identity (sum 0, prod 1, count 0, all true,
   any false), a ratio / extremum returns UNDEF.  Sample variance / stddev:
   n == 0 UNDEF, n == 1 -> 0.0, n >= 2 the formula.
*/
static VALUE
rb_ca_axis_group_reduce (VALUE self, VALUE vgaxes, VALUE vbundles, VALUE vop)
{
  CArray *src, *ca, *co;
  int     op = group_op_code(vop);

  GetCArray(self, src);

  if ( src->ndim <= 0 ) {
    rb_raise(rb_eRuntimeError, "axis_group_reduce: scalar source");
  }

  /* --- group (slab) axes --- */
  Check_Type(vgaxes, T_ARRAY);
  long ngroup = RARRAY_LEN(vgaxes);
  if ( ngroup <= 0 || ngroup > src->ndim ) {
    rb_raise(rb_eArgError, "axis_group_reduce: bad group axis count %ld", ngroup);
  }
  int8_t    axes[CA_RANK_MAX];
  char      is_group[CA_RANK_MAX];
  for ( int8_t i = 0; i < src->ndim; i++ ) is_group[i] = 0;
  ca_size_t group_prod = 1;
  for ( long i = 0; i < ngroup; i++ ) {
    int a = NUM2INT(RARRAY_AREF(vgaxes, i));
    if ( a < 0 || a >= src->ndim ) {
      rb_raise(rb_eArgError, "axis_group_reduce: group axis %d out of range", a);
    }
    if ( is_group[a] ) {
      rb_raise(rb_eArgError, "axis_group_reduce: duplicate group axis %d", a);
    }
    if ( i > 0 && a <= NUM2INT(RARRAY_AREF(vgaxes, i - 1)) ) {
      rb_raise(rb_eArgError, "axis_group_reduce: group axes must be ascending");
    }
    is_group[a]  = 1;
    axes[i]      = (int8_t) a;
    group_prod  *= src->dim[a];
  }

  /* --- bundles: small per-group code tables (metadata, kept alive) --- */
  Check_Type(vbundles, T_ARRAY);
  int  n_bundles = (int) RARRAY_LEN(vbundles);
  if ( n_bundles <= 0 || n_bundles > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "axis_group_reduce: bad bundle count %d", n_bundles);
  }
  int32_t  *bundle_codes[CA_RANK_MAX];
  ca_size_t bundle_k[CA_RANK_MAX];
  ca_size_t bundle_placeval[CA_RANK_MAX];
  int       bundle_nconsumed[CA_RANK_MAX];
  int       bundle_slot[CA_RANK_MAX][CA_RANK_MAX];
  ca_size_t bundle_cstride[CA_RANK_MAX][CA_RANK_MAX];
  CArray   *bundle_ca[CA_RANK_MAX];
  volatile VALUE keep = rb_ary_new();   /* GC-pin int32 code views */

  ca_size_t K_total = 1;
  long consumed_total = 0;
  for ( int bi = 0; bi < n_bundles; bi++ ) {
    VALUE bundle = RARRAY_AREF(vbundles, bi);
    Check_Type(bundle, T_ARRAY);
    if ( RARRAY_LEN(bundle) != 3 ) {
      rb_raise(rb_eArgError, "axis_group_reduce: bundle must be [codes, k, axes]");
    }
    VALUE vcodes = RARRAY_AREF(bundle, 0);
    ca_size_t k  = (ca_size_t) NUM2LONG(RARRAY_AREF(bundle, 1));
    VALUE vbaxes = RARRAY_AREF(bundle, 2);
    Check_Type(vbaxes, T_ARRAY);
    if ( k <= 0 ) {
      rb_raise(rb_eArgError, "axis_group_reduce: bundle k must be positive");
    }

    /* int32 view of the codes (metadata-sized, O(consumed-axis dims)) */
    VALUE v32 = rb_ca_wrap_readonly(vcodes, INT2NUM(CA_INT32));
    rb_ary_push((VALUE) keep, v32);
    GetCArray(v32, bundle_ca[bi]);
    ca_attach(bundle_ca[bi]);
    bundle_codes[bi] = (int32_t *) bundle_ca[bi]->ptr;

    int nb = (int) RARRAY_LEN(vbaxes);
    if ( nb <= 0 || nb > src->ndim ) {
      rb_raise(rb_eArgError, "axis_group_reduce: bad bundle axis count %d", nb);
    }
    bundle_nconsumed[bi] = nb;
    bundle_k[bi]         = k;
    K_total             *= k;
    consumed_total      += nb;

    /* codes must be row-major over the consumed axes' dims */
    ca_size_t expect = 1;
    ca_size_t dims[CA_RANK_MAX];
    for ( int j = 0; j < nb; j++ ) {
      int a = NUM2INT(RARRAY_AREF(vbaxes, j));
      if ( a < 0 || a >= src->ndim || ! is_group[a] ) {
        rb_raise(rb_eArgError,
                 "axis_group_reduce: bundle axis %d not a group axis", a);
      }
      dims[j]  = src->dim[a];
      expect  *= src->dim[a];
      /* slot = position of source axis `a` within the ascending slab axes */
      int slot = -1;
      for ( long s = 0; s < ngroup; s++ ) {
        if ( axes[s] == a ) { slot = (int) s; break; }
      }
      bundle_slot[bi][j] = slot;   /* always found: a is a group axis */
    }
    if ( bundle_ca[bi]->elements != expect ) {
      rb_raise(rb_eArgError,
               "axis_group_reduce: codes length %lld != Π consumed dims %lld",
               (long long) bundle_ca[bi]->elements, (long long) expect);
    }
    /* row-major code strides over the consumed axes (in given order) */
    ca_size_t st = 1;
    for ( int j = nb - 1; j >= 0; j-- ) {
      bundle_cstride[bi][j] = st;
      st *= dims[j];
    }
  }
  if ( consumed_total != ngroup ) {
    rb_raise(rb_eArgError,
             "axis_group_reduce: Σ bundle ranks %ld != group axis count %ld",
             consumed_total, ngroup);
  }
  /* place values: bundle 0 most significant (row-major over bundles) */
  {
    ca_size_t pv = 1;
    for ( int bi = n_bundles - 1; bi >= 0; bi-- ) {
      bundle_placeval[bi] = pv;
      pv *= bundle_k[bi];
    }
  }

  /* --- band layout + output shape [K_total, *band_dims] --- */
  ca_size_t band = (group_prod > 0) ? (src->elements / group_prod) : 0;
  ca_size_t odim[CA_RANK_MAX];
  int8_t    ondim = 1;
  odim[0] = K_total;
  for ( int8_t i = 0; i < src->ndim; i++ ) {
    if ( ! is_group[i] ) odim[ondim++] = src->dim[i];
  }
  ca_size_t nout = K_total * band;

  /* --- supported data type gate (before any allocation) --- */
  ca = src;
  switch ( src->data_type ) {
  case CA_BOOLEAN: case CA_INT8:  case CA_UINT8:  case CA_INT16: case CA_UINT16:
  case CA_INT32:   case CA_UINT32: case CA_INT64: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64: break;
  default:
    for ( int bi = 0; bi < n_bundles; bi++ ) ca_detach(bundle_ca[bi]);
    rb_raise(rb_eRuntimeError,
             "axis_group_reduce: unsupported source data_type %d",
             src->data_type);
  }

  /* output data type per op */
  int8_t out_dt = CA_FLOAT64;
  if      ( op == GR_COUNT )              out_dt = CA_INT64;
  else if ( op == GR_MINADDR || op == GR_MAXADDR ) out_dt = CA_INT64;
  else if ( op == GR_ALL || op == GR_ANY ) out_dt = CA_BOOLEAN;
  else if ( op == GR_ACCUM )              out_dt = src->data_type;
  VALUE vout = rb_carray_new(out_dt, ondim, odim, 0, NULL);
  GetCArray(vout, co);

  /* --- accumulator buffers (only those the op needs; all O(nout)) --- */
  ca_size_t *cnt   = ALLOC_N(ca_size_t, nout);  MEMZERO(cnt, ca_size_t, nout);
  double    *sum   = NULL, *sumsq = NULL, *prod = NULL, *mn = NULL, *mx = NULL;
  ca_size_t *nz    = NULL;
  int64_t   *mnaddr = NULL, *mxaddr = NULL;   /* flat source addr of min / max */
  ca_size_t *band_addr = NULL;                /* raveled addr of each band cell */
  if ( op == GR_SUM || op == GR_MEAN || op == GR_VARIANCE || op == GR_STDDEV ||
       op == GR_VARIANCEP || op == GR_STDDEVP ) {
    sum = ALLOC_N(double, nout);  MEMZERO(sum, double, nout);
  }
  if ( op == GR_PROD ) {
    prod = ALLOC_N(double, nout);
    for ( ca_size_t o = 0; o < nout; o++ ) prod[o] = 1.0;
  }
  if ( op == GR_MIN || op == GR_MINADDR ) {
    mn = ALLOC_N(double, nout);
    for ( ca_size_t o = 0; o < nout; o++ ) mn[o] = HUGE_VAL;
  }
  if ( op == GR_MAX || op == GR_MAXADDR ) {
    mx = ALLOC_N(double, nout);
    for ( ca_size_t o = 0; o < nout; o++ ) mx[o] = -HUGE_VAL;
  }
  if ( op == GR_MINADDR ) { mnaddr = ALLOC_N(int64_t, nout); MEMZERO(mnaddr, int64_t, nout); }
  if ( op == GR_MAXADDR ) { mxaddr = ALLOC_N(int64_t, nout); MEMZERO(mxaddr, int64_t, nout); }
  if ( op == GR_ALL || op == GR_ANY ) {
    nz = ALLOC_N(ca_size_t, nout);  MEMZERO(nz, ca_size_t, nout);
  }

  /* min_addr / max_addr need the flat raveled source address of each cell.
     Precompute the raveled stride per axis, the group-axis strides (paired with
     the slab odometer sidx), and the band cell's base address per band flat
     index b. Then addr(cell) = band_addr[b] + Σ sidx[s]*grstride[s]. */
  ca_size_t rstride[CA_RANK_MAX], grstride[CA_RANK_MAX];
  if ( op == GR_MINADDR || op == GR_MAXADDR ) {
    rstride[src->ndim - 1] = 1;
    for ( int8_t k = (int8_t)(src->ndim - 2); k >= 0; k-- )
      rstride[k] = rstride[k+1] * src->dim[k+1];
    for ( long s = 0; s < ngroup; s++ ) grstride[s] = rstride[axes[s]];
    int band_axis[CA_RANK_MAX]; int nband_axes = 0;
    for ( int8_t k = 0; k < src->ndim; k++ )
      if ( ! is_group[k] ) band_axis[nband_axes++] = k;
    band_addr = ALLOC_N(ca_size_t, band > 0 ? band : 1);
    for ( ca_size_t bb = 0; bb < band; bb++ ) {
      ca_size_t rem = bb, addr = 0;
      for ( int j = nband_axes - 1; j >= 0; j-- ) {     /* last band axis fastest */
        ca_size_t d = src->dim[band_axis[j]];
        addr += (rem % d) * rstride[band_axis[j]];
        rem  /= d;
      }
      band_addr[bb] = addr;
    }
  }

  /* --- compute pass(es), native data type dispatch, no forced float64 cast ---
     variance / stddev use a centred two-pass (= matches CArray's own
     variance, avoids the one-pass sumsq cancellation that breaks ε-close
     for small near-constant groups).  Pass 1 fills sum + cnt; sum is then
     overwritten in place with the per-group mean; pass 2 accumulates the
     centred sum of squares.  Every other op is a single pass. */
  if ( op == GR_VARIANCE || op == GR_STDDEV ||
       op == GR_VARIANCEP || op == GR_STDDEVP ) {
    GROUP_DISPATCH( cnt[o] += 1; sum[o] += v; );
    for ( ca_size_t o = 0; o < nout; o++ )
      if ( cnt[o] > 0 ) sum[o] /= (double) cnt[o];   /* sum -> mean */
    sumsq = ALLOC_N(double, nout);  MEMZERO(sumsq, double, nout);
    GROUP_DISPATCH( { double _d = v - sum[o]; sumsq[o] += _d * _d; } );
  }
  else if ( op == GR_MINADDR ) {
    GROUP_DISPATCH(
      cnt[o] += 1;
      if ( v < mn[o] ) {
        ca_size_t faddr = band_addr[b] + gaddr;
        mn[o] = v; mnaddr[o] = (int64_t) faddr;
      }
    );
  }
  else if ( op == GR_MAXADDR ) {
    GROUP_DISPATCH(
      cnt[o] += 1;
      if ( v > mx[o] ) {
        ca_size_t faddr = band_addr[b] + gaddr;
        mx[o] = v; mxaddr[o] = (int64_t) faddr;
      }
    );
  }
  else if ( op == GR_ACCUM ) {
    MEMZERO(co->ptr, char, (size_t) nout * co->bytes);
    switch ( ca->data_type ) {
    case CA_BOOLEAN: GROUP_WALK(boolean8_t, GACC_XOR);           break;
    case CA_INT8:    GROUP_WALK(int8_t,   GACC_ADD(int8_t));     break;
    case CA_UINT8:   GROUP_WALK(uint8_t,  GACC_ADD(uint8_t));    break;
    case CA_INT16:   GROUP_WALK(int16_t,  GACC_ADD(int16_t));    break;
    case CA_UINT16:  GROUP_WALK(uint16_t, GACC_ADD(uint16_t));   break;
    case CA_INT32:   GROUP_WALK(int32_t,  GACC_ADD(int32_t));    break;
    case CA_UINT32:  GROUP_WALK(uint32_t, GACC_ADD(uint32_t));   break;
    case CA_INT64:   GROUP_WALK(int64_t,  GACC_ADD(int64_t));    break;
    case CA_UINT64:  GROUP_WALK(uint64_t, GACC_ADD(uint64_t));   break;
    case CA_FLOAT32: GROUP_WALK(float,    GACC_ADD(float));      break;
    case CA_FLOAT64: GROUP_WALK(double,   GACC_ADD(double));     break;
    default: break;
    }
  }
  else {
    GROUP_DISPATCH(
      cnt[o] += 1;
      if ( sum )  sum[o]  += v;
      if ( prod ) prod[o] *= v;
      if ( mn )   { if ( v < mn[o] ) mn[o] = v; }
      if ( mx )   { if ( v > mx[o] ) mx[o] = v; }
      if ( nz )   { if ( v != 0.0 ) nz[o] += 1; }
    );
  }

  /* --- finalise into the output, UNDEF for empty groups --- */
  boolean8_t *omask = NULL;
  #define MARK_UNDEF(o) do {                       \
      if ( ! omask ) {                             \
        ca_create_mask(co);                        \
        omask = (boolean8_t *) co->mask->ptr;      \
      }                                            \
      omask[o] = 1;                                \
    } while (0)

  /* Empty / all-masked groups follow the same zero-contribution contract as
     CArray reductions (ERI, matching the categorical sibling): an identity-
     bearing op returns its identity (sum 0, prod 1, count 0, all true, any
     false), a ratio / extremum returns UNDEF. Sample variance/stddev: n==0
     UNDEF, n==1 -> 0.0 (the n=1 contract), n>=2 the formula. */
  if ( op == GR_COUNT ) {
    int64_t *out = (int64_t *) co->ptr;
    for ( ca_size_t o = 0; o < nout; o++ ) out[o] = (int64_t) cnt[o];
  }
  else if ( op == GR_MINADDR || op == GR_MAXADDR ) {
    int64_t *out  = (int64_t *) co->ptr;
    int64_t *addr = ( op == GR_MINADDR ) ? mnaddr : mxaddr;
    for ( ca_size_t o = 0; o < nout; o++ ) {
      if ( cnt[o] == 0 ) { out[o] = 0; MARK_UNDEF(o); }   /* empty -> UNDEF */
      else out[o] = addr[o];
    }
  }
  else if ( op == GR_ACCUM ) {
    /* already folded in place, in the source's own type; empty groups hold 0 */
  }
  else if ( op == GR_ALL ) {
    boolean8_t *out = (boolean8_t *) co->ptr;    /* empty -> true (vacuous) */
    for ( ca_size_t o = 0; o < nout; o++ )
      out[o] = ( cnt[o] == 0 ) ? 1 : (nz[o] == cnt[o]);
  }
  else if ( op == GR_ANY ) {
    boolean8_t *out = (boolean8_t *) co->ptr;    /* empty -> false */
    for ( ca_size_t o = 0; o < nout; o++ )
      out[o] = ( cnt[o] == 0 ) ? 0 : (nz[o] > 0);
  }
  else {
    double *out = (double *) co->ptr;
    for ( ca_size_t o = 0; o < nout; o++ ) {
      switch ( op ) {
      case GR_SUM:  out[o] = sum[o];  break;   /* empty -> 0.0 (identity) */
      case GR_PROD: out[o] = prod[o]; break;   /* empty -> 1.0 (identity) */
      case GR_MEAN:
        if ( cnt[o] == 0 ) { out[o] = 0.0; MARK_UNDEF(o); }
        else out[o] = sum[o] / (double) cnt[o];
        break;
      case GR_MIN:
        if ( cnt[o] == 0 ) { out[o] = 0.0; MARK_UNDEF(o); } else out[o] = mn[o];
        break;
      case GR_MAX:
        if ( cnt[o] == 0 ) { out[o] = 0.0; MARK_UNDEF(o); } else out[o] = mx[o];
        break;
      case GR_VARIANCE:
      case GR_STDDEV:
        if ( cnt[o] == 0 ) { out[o] = 0.0; MARK_UNDEF(o); }
        else if ( cnt[o] == 1 ) { out[o] = 0.0; }         /* n=1 contract */
        else { double var = sumsq[o] / ( (double) cnt[o] - 1.0 );
               out[o] = ( op == GR_STDDEV ) ? sqrt(var) : var; }
        break;
      case GR_VARIANCEP:
      case GR_STDDEVP:
        if ( cnt[o] == 0 ) { out[o] = 0.0; MARK_UNDEF(o); }
        else { double varp = sumsq[o] / (double) cnt[o];   /* n>=1, n=1 -> 0.0 */
               out[o] = ( op == GR_STDDEVP ) ? sqrt(varp) : varp; }
        break;
      }
    }
  }
  #undef MARK_UNDEF

  for ( int bi = 0; bi < n_bundles; bi++ ) ca_detach(bundle_ca[bi]);
  xfree(cnt);
  if ( sum ) xfree(sum);
  if ( sumsq ) xfree(sumsq);
  if ( prod ) xfree(prod);
  if ( mn ) xfree(mn);
  if ( mx ) xfree(mx);
  if ( nz ) xfree(nz);
  if ( mnaddr ) xfree(mnaddr);
  if ( mxaddr ) xfree(mxaddr);
  if ( band_addr ) xfree(band_addr);

  RB_GC_GUARD(keep);
  return vout;
}

/* =========================================================================
   Grouped segment scan — the per-element-emit sibling of the reduce above.

   Same fused single pass (CA_FOR_EACH_SLAB pins the grouped-axis union as the
   slab, the band axes as the outer iter, composite group code per slab element
   from the bundles), but instead of reading a dense accumulator at the end it
   EMITS the running value per element into a source-shaped output:

     reduce:  acc[code] op= v            then out[code, band] = acc[code]
     scan:    acc[code] op= v ; out[cell] = acc[code]   (shape = source)

   The group axis is NOT collapsed — output shape == source shape. Within each
   band the slab elements are walked in odometer (row-major over the grouped
   axes) order, so per group the accumulation runs in position order along the
   grouped axes. The flat case (all axes grouped, one band) is the same walk
   with a single slab = row-major appearance order, so flat and band-preserving
   agree by construction.

   The accumulator is dense [0, K_total) and is RESET at each band (each slab
   is one band position, fully processed before the next), so peak extra memory
   is O(K_total) — never O(input). Peak = output (= input size) + O(K_total).

   Masked / excluded cells follow the core CArray scan: a slab element masked in
   the source but with a valid group code does not update its group's total; it
   HOLDS the current running value and its output is NOT masked (identity ops
   always; extrema only once a member has been seen, else UNDEF — the empty
   max/min reduction contract).  A slab element excluded by the classifier (code
   out of [0, k)) belongs to no group and stays UNDEF.
   ------------------------------------------------------------------------- */

enum { GS_CUMSUM = 0, GS_CUMCOUNT, GS_CUMMAX, GS_CUMMIN, GS_CUMPROD };

/* Build the band-independent scatter plan for one slab.  For each slab element
   (in odometer order over the grouped axes) it records: the composite group
   code (GW_SKIP if excluded by some bundle), the source data / mask byte
   offsets from the slab pointers, and the group-relative raveled output address
   (Σ sidx[s]*grstride[s]).  These depend only on the slab odometer position,
   not on the band, so every band reuses this one plan (built on the first
   band).  Keeps the bundle walk + odometer out of the per-(band × element) hot
   path; peak metadata is O(slab_elements) = O(group_prod), never O(input). */
static void
group_scan_build_plan (ca_iter_state *st, boolean8_t *m,
                       int n_bundles, int32_t **bundle_codes,
                       ca_size_t *bundle_k, ca_size_t *bundle_placeval,
                       int *bundle_nconsumed, int (*bundle_slot)[CA_RANK_MAX],
                       ca_size_t (*bundle_cstride)[CA_RANK_MAX],
                       long ngroup, ca_size_t *grstride,
                       ca_size_t *sw_code, ca_size_t *sw_doff,
                       ca_size_t *sw_moff, ca_size_t *sw_addr)
{
  int8_t    sndim = st->slab_ndim;
  ca_size_t SE    = st->slab_elements;
  ca_size_t sidx[CA_RANK_MAX];
  for ( int8_t k = 0; k < sndim; k++ ) {
    sidx[k] = 0;
  }
  for ( ca_size_t e = 0; e < SE; e++ ) {
    int       skip = 0;
    ca_size_t code = 0;
    for ( int bi = 0; bi < n_bundles; bi++ ) {
      ca_size_t sub = 0;
      for ( int j = 0; j < bundle_nconsumed[bi]; j++ ) {
        sub += sidx[ bundle_slot[bi][j] ] * bundle_cstride[bi][j];
      }
      int32_t c = bundle_codes[bi][sub];
      if ( c < 0 || (ca_size_t) c >= bundle_k[bi] ) {
        skip = 1;
        break;
      }
      code += (ca_size_t) c * bundle_placeval[bi];
    }
    ca_size_t doff = 0, moff = 0, gaddr = 0;
    for ( int8_t k = 0; k < sndim; k++ ) {
      doff += sidx[k] * st->slab_strides[k];
      if ( m ) {
        moff += sidx[k] * st->slab_mask_strides[k];
      }
    }
    for ( long s = 0; s < ngroup; s++ ) {
      gaddr += (ca_size_t) sidx[s] * grstride[s];
    }
    sw_code[e] = skip ? GW_SKIP : code;
    sw_doff[e] = doff;
    sw_moff[e] = moff;
    sw_addr[e] = gaddr;
    for ( int8_t k = sndim - 1; k >= 0; k-- ) {   /* last slab axis ticks fastest */
      if ( ++sidx[k] < st->slab_dims[k] ) {
        break;
      }
      sidx[k] = 0;
    }
  }
}

/* GROUP_SCAN_WALK(T, EMIT, HOLD): the accumulate-in-double walk (cumsum /
   cumprod / cumcount).  One CA_FOR_EACH_SLAB pass monomorphised on the load
   type T; the band-independent plan is built once (group_scan_build_plan) on
   the first band.  EMIT (a present cell) writes the running value at the cell's
   raveled output address `addr`, with `v` (the element widened to double),
   `code` (composite group code) and the accumulators accd / accn in scope.
   These ops have an identity (0.0 sum / 1.0 prod / 0 count), so the accumulator
   is valid before any member: a cell masked WITHIN its group holds the current
   running value (HOLD) and its output is NOT masked — it just does not update
   the accumulator, matching the core scan where a masked cell holds the running
   acc.  Only a cell excluded from every group (GW_SKIP) stays UNDEF.  At each
   band accd is reset to acc_init and accn to 0, so groups do not run across
   bands. */
#define GROUP_SCAN_WALK(T, EMIT, HOLD)                                        \
  do {                                                                        \
    ca_iter_state st;                                                         \
    char       *p;                                                            \
    boolean8_t *m;                                                            \
    ca_size_t   b = 0;                                                        \
    int         ready = 0;                                                    \
    CA_FOR_EACH_SLAB(st, ca, axes, (int8_t) ngroup, CA_KERNEL_READ, p, m) {   \
      ca_size_t SE = st.slab_elements;                                        \
      if ( SE > 0 ) {                                                         \
        if ( ! ready ) {                                                      \
          group_scan_build_plan(&st, m, n_bundles, bundle_codes, bundle_k,   \
                                bundle_placeval, bundle_nconsumed,            \
                                bundle_slot, bundle_cstride, ngroup,          \
                                grstride, sw_code, sw_doff, sw_moff, sw_addr);\
          ready = 1;                                                          \
        }                                                                     \
        for ( ca_size_t o = 0; o < K_total; o++ ) {                          \
          accd[o] = acc_init;                                                 \
          accn[o] = 0;                                                        \
        }                                                                     \
        ca_size_t base = band_addr[b];                                       \
        for ( ca_size_t e = 0; e < SE; e++ ) {                               \
          ca_size_t code = sw_code[e];                                        \
          ca_size_t addr = base + sw_addr[e];                                 \
          if ( code == GW_SKIP ) { MARK_OUT_UNDEF(addr); continue; }          \
          if ( m && m[ sw_moff[e] ] ) { HOLD; continue; }                     \
          double v = (double) ( *(T *)(p + sw_doff[e]) );                     \
          (void) v;                                                           \
          EMIT;                                                               \
        }                                                                     \
      }                                                                       \
      b++;                                                                    \
    }                                                                         \
  } while (0)

#define GROUP_SCAN_DISPATCH(EMIT, HOLD)                                       \
  switch ( ca->data_type ) {                                                  \
  case CA_BOOLEAN: GROUP_SCAN_WALK(boolean8_t, EMIT, HOLD); break;            \
  case CA_INT8:    GROUP_SCAN_WALK(int8_t,     EMIT, HOLD); break;            \
  case CA_UINT8:   GROUP_SCAN_WALK(uint8_t,    EMIT, HOLD); break;            \
  case CA_INT16:   GROUP_SCAN_WALK(int16_t,    EMIT, HOLD); break;            \
  case CA_UINT16:  GROUP_SCAN_WALK(uint16_t,   EMIT, HOLD); break;            \
  case CA_INT32:   GROUP_SCAN_WALK(int32_t,    EMIT, HOLD); break;            \
  case CA_UINT32:  GROUP_SCAN_WALK(uint32_t,   EMIT, HOLD); break;            \
  case CA_INT64:   GROUP_SCAN_WALK(int64_t,    EMIT, HOLD); break;            \
  case CA_UINT64:  GROUP_SCAN_WALK(uint64_t,   EMIT, HOLD); break;            \
  case CA_FLOAT32: GROUP_SCAN_WALK(float,      EMIT, HOLD); break;            \
  case CA_FLOAT64: GROUP_SCAN_WALK(double,     EMIT, HOLD); break;            \
  default: break;                                                             \
  }

/* GROUP_SCAN_EXTREMUM_WALK(T, CMP): running extremum (cummax / cummin).  The
   extremum keeps the source data type (its magnitude never grows), so it holds a
   native T accumulator, not a widened double.  The first member of a group
   emits its own value: a per-group `seen` byte initialises the accumulator
   lazily on first hit — no sentinel like HUGE_VAL, which an integer data type could
   not represent.  CMP is > for max, < for min: a later member replaces the
   running extremum when `rv CMP acc`.  A cell masked within its group holds the
   current extremum once a member has been seen (output NOT masked, like sum);
   before any member the extremum is undefined so the cell stays UNDEF (the
   CArray reduction contract: empty max/min has no value — deliberately NOT the
   type-min/-Inf init the core cumulative uses).  GW_SKIP (excluded) stays
   UNDEF. */
#define GROUP_SCAN_EXTREMUM_WALK(T, CMP)                                      \
  do {                                                                        \
    ca_iter_state st;                                                         \
    char       *p;                                                            \
    boolean8_t *m;                                                            \
    ca_size_t   b = 0;                                                        \
    int         ready = 0;                                                    \
    T          *acce = ALLOC_N(T, K_total);                                   \
    T          *outp = (T *) co->ptr;                                         \
    CA_FOR_EACH_SLAB(st, ca, axes, (int8_t) ngroup, CA_KERNEL_READ, p, m) {   \
      ca_size_t SE = st.slab_elements;                                        \
      if ( SE > 0 ) {                                                         \
        if ( ! ready ) {                                                      \
          group_scan_build_plan(&st, m, n_bundles, bundle_codes, bundle_k,   \
                                bundle_placeval, bundle_nconsumed,            \
                                bundle_slot, bundle_cstride, ngroup,          \
                                grstride, sw_code, sw_doff, sw_moff, sw_addr);\
          ready = 1;                                                          \
        }                                                                     \
        for ( ca_size_t o = 0; o < K_total; o++ ) {                          \
          seen[o] = 0;                                                        \
        }                                                                     \
        ca_size_t base = band_addr[b];                                       \
        for ( ca_size_t e = 0; e < SE; e++ ) {                               \
          ca_size_t code = sw_code[e];                                        \
          ca_size_t addr = base + sw_addr[e];                                 \
          if ( code == GW_SKIP ) { MARK_OUT_UNDEF(addr); continue; }          \
          if ( m && m[ sw_moff[e] ] ) {                                       \
            if ( seen[code] ) { outp[addr] = acce[code]; }                    \
            else { MARK_OUT_UNDEF(addr); }                                    \
            continue;                                                         \
          }                                                                   \
          T rv = *(T *)(p + sw_doff[e]);                                      \
          if ( ! seen[code] ) { acce[code] = rv; seen[code] = 1; }            \
          else if ( rv CMP acce[code] ) { acce[code] = rv; }                  \
          outp[addr] = acce[code];                                            \
        }                                                                     \
      }                                                                       \
      b++;                                                                    \
    }                                                                         \
    xfree(acce);                                                              \
  } while (0)

#define GROUP_SCAN_EXTREMUM_DISPATCH(CMP)                                     \
  switch ( ca->data_type ) {                                                  \
  case CA_BOOLEAN: GROUP_SCAN_EXTREMUM_WALK(boolean8_t, CMP); break;          \
  case CA_INT8:    GROUP_SCAN_EXTREMUM_WALK(int8_t,     CMP); break;          \
  case CA_UINT8:   GROUP_SCAN_EXTREMUM_WALK(uint8_t,    CMP); break;          \
  case CA_INT16:   GROUP_SCAN_EXTREMUM_WALK(int16_t,    CMP); break;          \
  case CA_UINT16:  GROUP_SCAN_EXTREMUM_WALK(uint16_t,   CMP); break;          \
  case CA_INT32:   GROUP_SCAN_EXTREMUM_WALK(int32_t,    CMP); break;          \
  case CA_UINT32:  GROUP_SCAN_EXTREMUM_WALK(uint32_t,   CMP); break;          \
  case CA_INT64:   GROUP_SCAN_EXTREMUM_WALK(int64_t,    CMP); break;          \
  case CA_UINT64:  GROUP_SCAN_EXTREMUM_WALK(uint64_t,   CMP); break;          \
  case CA_FLOAT32: GROUP_SCAN_EXTREMUM_WALK(float,      CMP); break;          \
  case CA_FLOAT64: GROUP_SCAN_EXTREMUM_WALK(double,     CMP); break;          \
  default: break;                                                             \
  }

/* GROUP_SCAN_OBJECT_WALK(EMIT, HOLD): the CA_OBJECT lane (source holds VALUEs).
   A per-cell rb_funcall walk: cumcount is an int64 running count; the arithmetic
   ops (cumsum / cumprod) accumulate a per-group VALUE from an identity seed (0 /
   1) and the extremum ops (cummax / cummin) from the first member itself, all
   emitting into a CA_OBJECT output.  EMIT sees `ev` (the source element VALUE)
   and writes each running acc to the output cell immediately after computing it,
   so between rb_funcall and the store no allocation runs and every live
   accumulator is reachable from co (GC-safe).
   A cell masked within its group runs HOLD, not the emit: cumcount holds the
   running count and cumsum / cumprod hold their identity-seeded acc (0 / 1),
   both unmasked (matching core object cumsum / cumprod); cummax / cummin hold
   the running VALUE only once a member has been seen and stay UNDEF before that
   (no identity for arbitrary objects).  GW_SKIP (excluded) stays UNDEF.  accn /
   seen are reset at each band; acco carries the running VALUE. */
#define GROUP_SCAN_OBJECT_WALK(EMIT, HOLD)                                    \
  do {                                                                        \
    ca_iter_state st;                                                         \
    char       *p;                                                            \
    boolean8_t *m;                                                            \
    ca_size_t   b = 0;                                                        \
    int         ready = 0;                                                    \
    CA_FOR_EACH_SLAB(st, ca, axes, (int8_t) ngroup, CA_KERNEL_READ, p, m) {   \
      ca_size_t SE = st.slab_elements;                                        \
      if ( SE > 0 ) {                                                         \
        if ( ! ready ) {                                                      \
          group_scan_build_plan(&st, m, n_bundles, bundle_codes, bundle_k,   \
                                bundle_placeval, bundle_nconsumed,            \
                                bundle_slot, bundle_cstride, ngroup,          \
                                grstride, sw_code, sw_doff, sw_moff, sw_addr);\
          ready = 1;                                                          \
        }                                                                     \
        for ( ca_size_t o = 0; o < K_total; o++ ) {                          \
          seen[o] = 0;                                                        \
          accn[o] = 0;                                                        \
        }                                                                     \
        ca_size_t base = band_addr[b];                                       \
        for ( ca_size_t e = 0; e < SE; e++ ) {                               \
          ca_size_t code = sw_code[e];                                        \
          ca_size_t addr = base + sw_addr[e];                                 \
          if ( code == GW_SKIP ) { MARK_OUT_UNDEF(addr); continue; }          \
          if ( m && m[ sw_moff[e] ] ) { HOLD; continue; }                     \
          VALUE ev = *(VALUE *)(p + sw_doff[e]);                              \
          (void) ev;                                                          \
          EMIT;                                                               \
        }                                                                     \
      }                                                                       \
      b++;                                                                    \
    }                                                                         \
  } while (0)

static int
group_scan_op_code (VALUE vop)
{
  ID id = SYM2ID(vop);
  if      ( id == rb_intern("cumsum") )   return GS_CUMSUM;
  else if ( id == rb_intern("cumcount") ) return GS_CUMCOUNT;
  else if ( id == rb_intern("cummax") )   return GS_CUMMAX;
  else if ( id == rb_intern("cummin") )   return GS_CUMMIN;
  else if ( id == rb_intern("cumprod") )  return GS_CUMPROD;
  rb_raise(rb_eArgError, "axis_group_scan: unsupported op :%s", rb_id2name(id));
}

/* __axis_group_scan__(group_axes, bundles, op) — group-keyed segment scan of
 * self over the union of `group_axes` into composite groups described by
 * `bundles` (same argument shape as __axis_group_reduce__).  Internal.
 *
 * Unlike the reduce the grouped axes are not collapsed: the result is a new
 * CArray of the same shape as self, each cell holding the running statistic of
 * its group up to and including that cell, in row-major position order along
 * the grouped axes (per band).

   op / output data type:
     :cumsum   -> float64, inclusive within-group running sum.
     :cumprod  -> float64, inclusive within-group running product (init 1.0;
                  float64 like cumsum since the product grows).
     :cummax   -> source data type, running within-group maximum (extrema do not
                  grow magnitude, so the data type is preserved; int stays int).
     :cummin   -> source data type, running within-group minimum.
     :cumcount -> int64, 1-based within-group running count of present cells
                  (matching the core CArray#cumcount): the first present member
                  of a group emits 1, the next 2, ...
   cumsum / cumprod keep float64 (matching the reduce siblings sum / prod);
   integer-preserving sum / prod is a deliberate non-goal (overflow / data type
   consistency), as on the reduce side.  A CA_OBJECT source emits a CA_OBJECT
   result for cumsum / cumprod / cummax / cummin (cumcount stays int64).

   Masked-cell / excluded-cell policy (matches the core CArray scan): a cell
   masked WITHIN its group holds its group's current running value and its
   output is NOT masked — for cumsum / cumprod / cumcount (which have an
   identity) always, for cummax / cummin (no identity) only once a member has
   been seen; before any member the extremum is undefined so the cell stays
   UNDEF.  A cell excluded from every group (composite code out of [0,k)) belongs
   to no group and stays UNDEF. */
static VALUE
rb_ca_axis_group_scan (VALUE self, VALUE vgaxes, VALUE vbundles, VALUE vop)
{
  CArray *src, *ca, *co;
  int     op = group_scan_op_code(vop);

  GetCArray(self, src);

  if ( src->ndim <= 0 ) {
    rb_raise(rb_eRuntimeError, "axis_group_scan: scalar source");
  }

  /* --- group (slab) axes (same validation as reduce) --- */
  Check_Type(vgaxes, T_ARRAY);
  long ngroup = RARRAY_LEN(vgaxes);
  if ( ngroup <= 0 || ngroup > src->ndim ) {
    rb_raise(rb_eArgError, "axis_group_scan: bad group axis count %ld", ngroup);
  }
  int8_t    axes[CA_RANK_MAX];
  char      is_group[CA_RANK_MAX];
  for ( int8_t i = 0; i < src->ndim; i++ ) is_group[i] = 0;
  ca_size_t group_prod = 1;
  for ( long i = 0; i < ngroup; i++ ) {
    int a = NUM2INT(RARRAY_AREF(vgaxes, i));
    if ( a < 0 || a >= src->ndim ) {
      rb_raise(rb_eArgError, "axis_group_scan: group axis %d out of range", a);
    }
    if ( is_group[a] ) {
      rb_raise(rb_eArgError, "axis_group_scan: duplicate group axis %d", a);
    }
    if ( i > 0 && a <= NUM2INT(RARRAY_AREF(vgaxes, i - 1)) ) {
      rb_raise(rb_eArgError, "axis_group_scan: group axes must be ascending");
    }
    is_group[a]  = 1;
    axes[i]      = (int8_t) a;
    group_prod  *= src->dim[a];
  }

  /* --- bundles: small per-group code tables (same as reduce) --- */
  Check_Type(vbundles, T_ARRAY);
  int  n_bundles = (int) RARRAY_LEN(vbundles);
  if ( n_bundles <= 0 || n_bundles > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "axis_group_scan: bad bundle count %d", n_bundles);
  }
  int32_t  *bundle_codes[CA_RANK_MAX];
  ca_size_t bundle_k[CA_RANK_MAX];
  ca_size_t bundle_placeval[CA_RANK_MAX];
  int       bundle_nconsumed[CA_RANK_MAX];
  int       bundle_slot[CA_RANK_MAX][CA_RANK_MAX];
  ca_size_t bundle_cstride[CA_RANK_MAX][CA_RANK_MAX];
  CArray   *bundle_ca[CA_RANK_MAX];
  volatile VALUE keep = rb_ary_new();

  ca_size_t K_total = 1;
  long consumed_total = 0;
  for ( int bi = 0; bi < n_bundles; bi++ ) {
    VALUE bundle = RARRAY_AREF(vbundles, bi);
    Check_Type(bundle, T_ARRAY);
    if ( RARRAY_LEN(bundle) != 3 ) {
      rb_raise(rb_eArgError, "axis_group_scan: bundle must be [codes, k, axes]");
    }
    VALUE vcodes = RARRAY_AREF(bundle, 0);
    ca_size_t k  = (ca_size_t) NUM2LONG(RARRAY_AREF(bundle, 1));
    VALUE vbaxes = RARRAY_AREF(bundle, 2);
    Check_Type(vbaxes, T_ARRAY);
    if ( k <= 0 ) {
      rb_raise(rb_eArgError, "axis_group_scan: bundle k must be positive");
    }

    VALUE v32 = rb_ca_wrap_readonly(vcodes, INT2NUM(CA_INT32));
    rb_ary_push((VALUE) keep, v32);
    GetCArray(v32, bundle_ca[bi]);
    ca_attach(bundle_ca[bi]);
    bundle_codes[bi] = (int32_t *) bundle_ca[bi]->ptr;

    int nb = (int) RARRAY_LEN(vbaxes);
    if ( nb <= 0 || nb > src->ndim ) {
      rb_raise(rb_eArgError, "axis_group_scan: bad bundle axis count %d", nb);
    }
    bundle_nconsumed[bi] = nb;
    bundle_k[bi]         = k;
    K_total             *= k;
    consumed_total      += nb;

    ca_size_t expect = 1;
    ca_size_t dims[CA_RANK_MAX];
    for ( int j = 0; j < nb; j++ ) {
      int a = NUM2INT(RARRAY_AREF(vbaxes, j));
      if ( a < 0 || a >= src->ndim || ! is_group[a] ) {
        rb_raise(rb_eArgError,
                 "axis_group_scan: bundle axis %d not a group axis", a);
      }
      dims[j]  = src->dim[a];
      expect  *= src->dim[a];
      int slot = -1;
      for ( long s = 0; s < ngroup; s++ ) {
        if ( axes[s] == a ) { slot = (int) s; break; }
      }
      bundle_slot[bi][j] = slot;
    }
    if ( bundle_ca[bi]->elements != expect ) {
      rb_raise(rb_eArgError,
               "axis_group_scan: codes length %lld != Π consumed dims %lld",
               (long long) bundle_ca[bi]->elements, (long long) expect);
    }
    ca_size_t cs = 1;
    for ( int j = nb - 1; j >= 0; j-- ) {
      bundle_cstride[bi][j] = cs;
      cs *= dims[j];
    }
  }
  if ( consumed_total != ngroup ) {
    rb_raise(rb_eArgError,
             "axis_group_scan: Σ bundle ranks %ld != group axis count %ld",
             consumed_total, ngroup);
  }
  {
    ca_size_t pv = 1;
    for ( int bi = n_bundles - 1; bi >= 0; bi-- ) {
      bundle_placeval[bi] = pv;
      pv *= bundle_k[bi];
    }
  }

  ca_size_t band = (group_prod > 0) ? (src->elements / group_prod) : 0;

  /* --- supported data type gate (CA_OBJECT handled by its own lane below) --- */
  ca = src;
  switch ( src->data_type ) {
  case CA_BOOLEAN: case CA_INT8:  case CA_UINT8:  case CA_INT16: case CA_UINT16:
  case CA_INT32:   case CA_UINT32: case CA_INT64: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64: case CA_OBJECT: break;
  default:
    for ( int bi = 0; bi < n_bundles; bi++ ) ca_detach(bundle_ca[bi]);
    rb_raise(rb_eRuntimeError,
             "axis_group_scan: unsupported source data_type %d",
             src->data_type);
  }

  /* --- output data type per op: cumcount int64; cumsum / cumprod float64 (object
     source -> object); cummax / cummin preserve the source data type (object ->
     object). --- */
  int8_t out_dt;
  if      ( op == GS_CUMCOUNT )                        { out_dt = CA_INT64; }
  else if ( src->data_type == CA_OBJECT )              { out_dt = CA_OBJECT; }
  else if ( op == GS_CUMSUM || op == GS_CUMPROD )      { out_dt = CA_FLOAT64; }
  else                                                 { out_dt = src->data_type; }

  /* --- source-shaped output --- */
  ca_size_t odim[CA_RANK_MAX];
  for ( int8_t i = 0; i < src->ndim; i++ ) odim[i] = src->dim[i];
  VALUE vout = rb_carray_new(out_dt, src->ndim, odim, 0, NULL);
  GetCArray(vout, co);

  /* --- band raveled base address per band flat index (same construction as
     the reduce min_addr / max_addr path): addr(cell) = band_addr[b] +
     Σ sidx[s]*grstride[s].

     CAREFUL: the walks below index the output by that raveled source address.
     This is only valid because `vout` is a freshly allocated contiguous
     entity of the source's shape, so output offset == source row-major
     raveled address.  Handing a view here would scatter into wrong cells. --- */
  ca_size_t rstride[CA_RANK_MAX], grstride[CA_RANK_MAX];
  rstride[src->ndim - 1] = 1;
  for ( int8_t k = (int8_t)(src->ndim - 2); k >= 0; k-- )
    rstride[k] = rstride[k+1] * src->dim[k+1];
  for ( long s = 0; s < ngroup; s++ ) grstride[s] = rstride[axes[s]];
  int band_axis[CA_RANK_MAX]; int nband_axes = 0;
  for ( int8_t k = 0; k < src->ndim; k++ )
    if ( ! is_group[k] ) band_axis[nband_axes++] = k;
  ca_size_t *band_addr = ALLOC_N(ca_size_t, band > 0 ? band : 1);
  for ( ca_size_t bb = 0; bb < band; bb++ ) {
    ca_size_t rem = bb, addr = 0;
    for ( int j = nband_axes - 1; j >= 0; j-- ) {
      ca_size_t d = src->dim[band_axis[j]];
      addr += (rem % d) * rstride[band_axis[j]];
      rem  /= d;
    }
    band_addr[bb] = addr;
  }

  /* band-independent scatter plan (built once on the first band, sized to the
     slab = group_prod), + per-band dense [0, K_total) accumulators reset each
     band.  accd (sum / prod), accn (running count) and seen (extremum first
     member / object identity init) are all tiny; acco (object running VALUE) is
     allocated only for the object arithmetic / extremum ops. */
  ca_size_t  plan_n  = (group_prod > 0) ? group_prod : 1;
  ca_size_t *sw_code = ALLOC_N(ca_size_t, plan_n);
  ca_size_t *sw_doff = ALLOC_N(ca_size_t, plan_n);
  ca_size_t *sw_moff = ALLOC_N(ca_size_t, plan_n);
  ca_size_t *sw_addr = ALLOC_N(ca_size_t, plan_n);
  double    *accd    = ALLOC_N(double,    K_total);
  ca_size_t *accn    = ALLOC_N(ca_size_t, K_total);
  char      *seen    = ALLOC_N(char,      K_total);
  VALUE     *acco    = NULL;
  double     acc_init = ( op == GS_CUMPROD ) ? 1.0 : 0.0;

  boolean8_t *omask = NULL;
  #define MARK_OUT_UNDEF(o) do {                   \
      if ( ! omask ) {                             \
        ca_create_mask(co);                        \
        omask = (boolean8_t *) co->mask->ptr;      \
      }                                            \
      omask[o] = 1;                                \
    } while (0)

  if ( src->data_type == CA_OBJECT ) {
    if ( op == GS_CUMCOUNT ) {                    /* int64 1-based running count */
      int64_t *outi = (int64_t *) co->ptr;
      GROUP_SCAN_OBJECT_WALK(
        accn[code] += 1; outi[addr] = (int64_t) accn[code];,
        outi[addr] = (int64_t) accn[code];
      );
    }
    else {                                        /* object running VALUE */
      VALUE *outo = (VALUE *) co->ptr;
      acco = ALLOC_N(VALUE, K_total);
      switch ( op ) {
      case GS_CUMSUM:
        /* Identity 0 (matching the core object cumsum): a group's acc is lazily
           seeded to 0 (Fixnum, so 0 + ev promotes to ev's class), so a cell
           masked before any present member holds 0 unmasked and an all-masked
           group yields 0 everywhere.  seen doubles as the per-band init flag. */
        GROUP_SCAN_OBJECT_WALK(
          if ( ! seen[code] ) { acco[code] = INT2FIX(0); seen[code] = 1; }
          acco[code] = rb_funcall(acco[code], rb_intern("+"), 1, ev);
          outo[addr] = acco[code];,
          if ( ! seen[code] ) { acco[code] = INT2FIX(0); seen[code] = 1; }
          outo[addr] = acco[code];
        );
        break;
      case GS_CUMPROD:
        /* Identity 1, same lazy-init as cumsum. */
        GROUP_SCAN_OBJECT_WALK(
          if ( ! seen[code] ) { acco[code] = INT2FIX(1); seen[code] = 1; }
          acco[code] = rb_funcall(acco[code], rb_intern("*"), 1, ev);
          outo[addr] = acco[code];,
          if ( ! seen[code] ) { acco[code] = INT2FIX(1); seen[code] = 1; }
          outo[addr] = acco[code];
        );
        break;
      case GS_CUMMAX:
        /* No identity: seed from the first member, hold only once seen; a cell
           masked before any member stays UNDEF (empty-max contract). */
        GROUP_SCAN_OBJECT_WALK(
          if ( ! seen[code] ) { acco[code] = ev; seen[code] = 1; }
          else if ( NUM2INT(rb_funcall(ev, rb_intern("<=>"), 1, acco[code])) > 0 ) {
            acco[code] = ev;
          }
          outo[addr] = acco[code];,
          if ( seen[code] ) { outo[addr] = acco[code]; }
          else { MARK_OUT_UNDEF(addr); }
        );
        break;
      case GS_CUMMIN:
        GROUP_SCAN_OBJECT_WALK(
          if ( ! seen[code] ) { acco[code] = ev; seen[code] = 1; }
          else if ( NUM2INT(rb_funcall(ev, rb_intern("<=>"), 1, acco[code])) < 0 ) {
            acco[code] = ev;
          }
          outo[addr] = acco[code];,
          if ( seen[code] ) { outo[addr] = acco[code]; }
          else { MARK_OUT_UNDEF(addr); }
        );
        break;
      }
    }
  }
  else {                                          /* native data type dispatch */
    switch ( op ) {
    case GS_CUMSUM: {
      double *outd = (double *) co->ptr;
      GROUP_SCAN_DISPATCH( accd[code] += v; outd[addr] = accd[code];,
                           outd[addr] = accd[code]; );
      break;
    }
    case GS_CUMPROD: {
      double *outd = (double *) co->ptr;
      GROUP_SCAN_DISPATCH( accd[code] *= v; outd[addr] = accd[code];,
                           outd[addr] = accd[code]; );
      break;
    }
    case GS_CUMCOUNT: {                           /* 1-based running count */
      int64_t *outi = (int64_t *) co->ptr;
      GROUP_SCAN_DISPATCH( accn[code] += 1; outi[addr] = (int64_t) accn[code];,
                           outi[addr] = (int64_t) accn[code]; );
      break;
    }
    case GS_CUMMAX:
      GROUP_SCAN_EXTREMUM_DISPATCH( > );
      break;
    case GS_CUMMIN:
      GROUP_SCAN_EXTREMUM_DISPATCH( < );
      break;
    }
  }
  #undef MARK_OUT_UNDEF

  for ( int bi = 0; bi < n_bundles; bi++ ) ca_detach(bundle_ca[bi]);
  xfree(band_addr);
  xfree(sw_code);
  xfree(sw_doff);
  xfree(sw_moff);
  xfree(sw_addr);
  xfree(accd);
  xfree(accn);
  xfree(seen);
  if ( acco ) xfree(acco);

  RB_GC_GUARD(keep);
  return vout;
}

void
Init_ca_axis_group (void)
{
  rb_define_method(rb_cCArray, "__axis_group_reduce__",
                   rb_ca_axis_group_reduce, 3);
  rb_define_method(rb_cCArray, "__axis_group_scan__",
                   rb_ca_axis_group_scan, 3);
}
