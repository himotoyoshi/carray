/* ---------------------------------------------------------------------------

  ca_categorical_iterator.c — counting-sort scatter for CACategoricalIterator.

  __categorical_scatter__ lays a flat payload out as a category-contiguous
  copy in a single pass, driven by the categorical codes and a per-category
  write cursor (a mutable copy of reduceat_index's segment starts).  No
  permutation array is built; O(n), stable (ascending scan keeps each
  category's members in source order).  It is the discrete, value-carrying
  sibling of histogram_scatter_ki (ext/carray_histogram.c): where the histogram
  scatters a +1 into counts, this scatters the payload cell into grouped.

  Two masks meet here and are kept distinct:
    - the CODES mask is authoritative for exclusion — a masked code cell does
      not join any group (the sentinel value never has to be read; `c < k` is a
      defensive assert only).
    - the VALUE mask propagates into grouped, so a group with a masked payload
      cell reduces as CArray does (the cell is skipped by mask-aware reductions).

  The output position is data-dependent (cursor[code]++), which the aligned
  kernel_iterator macros do not model, so the flat inputs are materialised here:
  ca_attach aliases a contiguous entity (codes / a contiguous value) and gathers
  a view.  Codes dispatch on their native integer type (no coercion); the value
  move is a bytes-wide memcpy (grouped shares the value data type, so no value-type
  dispatch is needed).

  Surface (private): codes.__categorical_scatter__(value, cursor, grouped, k)
    self    = codes   (integer, carries the exclusion mask), read flat
    value   = payload (any data type, may carry a mask), read flat, same length
    cursor  = int64 length-k segment starts (mutated in place, consumed)
    grouped = pre-allocated contiguous entity of the value data type, length nvalid
    k       = number of categories
  Returns grouped.

--------------------------------------------------------------------------- */

#include "carray.h"
#include <stdlib.h>   /* qsort */
#include <math.h>     /* floor */

#define CATEGORICAL_SCATTER_BODY(CODE_T)                                        \
  do {                                                                          \
    const CODE_T *cp = (const CODE_T *) codes->ptr;                             \
    for ( j = 0; j < n; j++ ) {                                                 \
      if ( cmask && cmask[j] ) continue;          /* excluded by codes mask */  \
      c = (int64_t) cp[j];                                                      \
      if ( c < 0 || c >= k ) continue;            /* defensive */               \
      pos = (ca_size_t) cur[c];                                                 \
      cur[c] = (int64_t) (pos + 1);                                            \
      memcpy(gp + pos * bytes, vp + j * bytes, (size_t) bytes);                 \
      if ( vmask && vmask[j] ) gmask[pos] = 1;    /* propagate value mask */    \
    }                                                                           \
  } while (0)

static VALUE
rb_ca_categorical_scatter (VALUE self, VALUE rvalue, VALUE rcursor,
                           VALUE rgrouped, VALUE rk)
{
  CArray     *codes, *value, *cursor, *grouped;
  int64_t     k, c, *cur;
  ca_size_t   n, j, pos, bytes;
  boolean8_t *cmask, *vmask, *gmask = NULL;
  char       *gp, *vp;

  GetCArray(self,     codes);
  GetCArray(rvalue,   value);
  GetCArray(rcursor,  cursor);
  GetCArray(rgrouped, grouped);
  k = (int64_t) NUM2LL(rk);

  n     = codes->elements;
  bytes = value->bytes;
  if ( value->elements != n ) {
    rb_raise(rb_eArgError,
             "__categorical_scatter__: value length %lld != codes length %lld",
             (long long) value->elements, (long long) n);
  }
  if ( cursor->data_type != CA_INT64 || cursor->elements != k ) {
    rb_raise(rb_eArgError, "__categorical_scatter__: cursor must be int64[k]");
  }
  if ( grouped->bytes != bytes ) {
    rb_raise(rb_eArgError, "__categorical_scatter__: grouped/value data type mismatch");
  }

  ca_attach(codes);
  ca_attach(value);
  cmask = ca_mask_ptr(codes);
  vmask = ca_mask_ptr(value);
  cur   = (int64_t *) cursor->ptr;
  gp    = grouped->ptr;
  vp    = value->ptr;

  if ( vmask ) {                        /* grouped needs a mask to receive it */
    ca_create_mask(grouped);
    gmask = (boolean8_t *) grouped->mask->ptr;
  }

  switch ( codes->data_type ) {
  case CA_INT8:   CATEGORICAL_SCATTER_BODY(int8_t);   break;
  case CA_UINT8:  CATEGORICAL_SCATTER_BODY(uint8_t);  break;
  case CA_INT16:  CATEGORICAL_SCATTER_BODY(int16_t);  break;
  case CA_UINT16: CATEGORICAL_SCATTER_BODY(uint16_t); break;
  case CA_INT32:  CATEGORICAL_SCATTER_BODY(int32_t);  break;
  case CA_UINT32: CATEGORICAL_SCATTER_BODY(uint32_t); break;
  case CA_INT64:  CATEGORICAL_SCATTER_BODY(int64_t);  break;
  case CA_UINT64: CATEGORICAL_SCATTER_BODY(uint64_t); break;
  default:
    ca_detach(codes);
    ca_detach(value);
    rb_raise(rb_eCADataTypeError,
             "__categorical_scatter__: integer codes required (got data_type %d)",
             codes->data_type);
  }

  ca_detach(codes);
  ca_detach(value);
  return rgrouped;
}

/* ---------------------------------------------------------------------------

  __reduceat_moments__ — faithful single-pass reduceat over the contiguous
  grouped copy.  One walk delimited by the segment offsets fills the per-segment
  count / sum / min / max; no per-segment view is created (that is the whole
  point of paying for the eager grouped copy: one scatter, then cheap single-pass
  reductions).  Value-mask-aware; matches CArray's per-array contract per segment
  (empty / all-masked -> sum 0 identity, count 0, min/max masked).

  Surface (private): grouped.__reduceat_moments__(offsets, counts, sums, mins, maxs)
    self    = grouped  (numeric value data type, may carry a mask), contiguous entity
    offsets = int64[k] segment STARTS; segment c = [offsets[c], offsets[c+1]),
              the last ends at grouped.elements
    counts  = int64[k]   output: present (non-masked) cells per segment
    sums    = float64[k] output: sum per segment (0 for empty, unmasked)
    mins/maxs = value-type[k] output: min / max per segment; the kernel masks
              the empty/all-masked segments (no value to report)
  Derived on the Ruby side: mean = sum/count, count_masked = sizes - count, etc.

--------------------------------------------------------------------------- */

#define REDUCEAT_MOMENTS_BODY(T)                                                 \
  do {                                                                          \
    const T *gp = (const T *) grouped->ptr;                                     \
    T *minv = (T *) minp, *maxv = (T *) maxp;                                   \
    for ( c = 0; c < k; c++ ) {                                                 \
      ca_size_t lo = (ca_size_t) offs[c];                                       \
      ca_size_t hi = (c + 1 < k) ? (ca_size_t) offs[c+1] : n;                   \
      ca_size_t j, cnt = 0;                                                     \
      double sacc = 0.0;                                                        \
      T mn = 0, mx = 0; int seen = 0;                                           \
      for ( j = lo; j < hi; j++ ) {                                             \
        if ( gm && gm[j] ) continue;            /* masked value cell */         \
        { T v = gp[j];                                                          \
          sacc += (double) v;                                                   \
          if ( ! seen ) { mn = v; mx = v; seen = 1; }                          \
          else { if ( v < mn ) mn = v; if ( v > mx ) mx = v; }                  \
          cnt++; }                                                              \
      }                                                                         \
      countp[c] = (int64_t) cnt;                                                \
      sump[c]   = sacc;                                                         \
      if ( seen ) { minv[c] = mn; maxv[c] = mx; }                              \
      else { minv[c] = 0; maxv[c] = 0; minm[c] = 1; maxm[c] = 1; }             \
    }                                                                           \
  } while (0)

static VALUE
rb_ca_reduceat_moments (VALUE self, VALUE roffsets, VALUE rcounts,
                        VALUE rsums, VALUE rmins, VALUE rmaxs)
{
  CArray     *grouped, *offsets, *counts, *sums, *mins, *maxs;
  int64_t     k, *offs, *countp;
  ca_size_t   n, c;
  double     *sump;
  char       *minp, *maxp;
  boolean8_t *gm, *minm, *maxm;

  GetCArray(self,     grouped);
  GetCArray(roffsets, offsets);
  GetCArray(rcounts,  counts);
  GetCArray(rsums,    sums);
  GetCArray(rmins,    mins);
  GetCArray(rmaxs,    maxs);

  k = (int64_t) offsets->elements;
  n = grouped->elements;
  if ( offsets->data_type != CA_INT64 || counts->data_type != CA_INT64 ||
       sums->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "__reduceat_moments__: offsets/counts int64, sums float64");
  }
  if ( counts->elements != k || sums->elements != k ||
       mins->elements != k || maxs->elements != k ||
       mins->data_type != grouped->data_type || maxs->data_type != grouped->data_type ) {
    rb_raise(rb_eArgError, "__reduceat_moments__: output shape/data type mismatch");
  }

  offs   = (int64_t *) offsets->ptr;
  countp = (int64_t *) counts->ptr;
  sump   = (double *)  sums->ptr;
  minp   = mins->ptr;
  maxp   = maxs->ptr;
  gm     = ca_mask_ptr(grouped);
  ca_create_mask(mins);                 /* empty segments have no min / max */
  ca_create_mask(maxs);
  minm = (boolean8_t *) mins->mask->ptr;
  maxm = (boolean8_t *) maxs->mask->ptr;

  switch ( grouped->data_type ) {
  case CA_INT8:    REDUCEAT_MOMENTS_BODY(int8_t);    break;
  case CA_UINT8:   REDUCEAT_MOMENTS_BODY(uint8_t);   break;
  case CA_INT16:   REDUCEAT_MOMENTS_BODY(int16_t);   break;
  case CA_UINT16:  REDUCEAT_MOMENTS_BODY(uint16_t);  break;
  case CA_INT32:   REDUCEAT_MOMENTS_BODY(int32_t);   break;
  case CA_UINT32:  REDUCEAT_MOMENTS_BODY(uint32_t);  break;
  case CA_INT64:   REDUCEAT_MOMENTS_BODY(int64_t);   break;
  case CA_UINT64:  REDUCEAT_MOMENTS_BODY(uint64_t);  break;
  case CA_FLOAT32: REDUCEAT_MOMENTS_BODY(float32_t); break;
  case CA_FLOAT64: REDUCEAT_MOMENTS_BODY(float64_t); break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__reduceat_moments__: numeric value required (got data_type %d)",
             grouped->data_type);
  }

  return Qnil;
}

/* ---------------------------------------------------------------------------

  __reduceat_percentile__ — order-statistic reduceat over the grouped copy.
  Order statistics cannot be scattered (they need every value of a group held
  together), so they are the reason the eager copy exists.  One walk delimited by
  the segment offsets gathers each segment's present (non-masked) values into a
  reused double scratch, sorts it, and takes the `:linear`-interpolated
  percentile — the same interpolation as CArray#percentile
  (f = (m-1)*p/100, k = floor(f), lo + (f-k)*(hi-lo)).  No per-segment view.

  Surface (private): grouped.__reduceat_percentile__(offsets, p, out)
    self    = grouped  (numeric value data type, may carry a mask)
    offsets = int64[k] segment STARTS (last ends at grouped.elements)
    p       = percentile in 0..100 (median = 50, quantile(q) = q*100)
    out     = float64[k] output; empty / all-masked segments are masked

--------------------------------------------------------------------------- */

/* Wirth quickselect: rearrange a[0..n) so a[kth] is the kth-smallest, with
   a[0..kth) <= a[kth] <= a[kth..n).  O(n) average — the same order-of-work as
   CArray#percentile's partition, and far cheaper than a full sort for the large
   segments (few categories) case. */
static void
ca_nth_element_double (double *a, ca_size_t n, ca_size_t kth)
{
  long l = 0, m = (long) n - 1, kk = (long) kth;
  while ( l < m ) {
    double x = a[kk];
    long i = l, j = m;
    do {
      while ( a[i] < x ) i++;
      while ( x < a[j] ) j--;
      if ( i <= j ) { double t = a[i]; a[i] = a[j]; a[j] = t; i++; j--; }
    } while ( i <= j );
    if ( j < kk ) l = i;
    if ( kk < i ) m = j;
  }
}

#define REDUCEAT_PCT_BODY(T)                                                     \
  do {                                                                          \
    const T *gp = (const T *) grouped->ptr;                                     \
    for ( c = 0; c < k; c++ ) {                                                 \
      ca_size_t lo = (ca_size_t) offs[c];                                       \
      ca_size_t hi = (c + 1 < k) ? (ca_size_t) offs[c+1] : n;                   \
      ca_size_t jj, m = 0;                                                       \
      for ( jj = lo; jj < hi; jj++ ) {                                          \
        if ( gm && gm[jj] ) continue;                                           \
        scratch[m++] = (double) gp[jj];                                         \
      }                                                                         \
      if ( m == 0 ) { outp[c] = 0.0; outm[c] = 1; continue; }                   \
      { double f = (double) (m - 1) * p / 100.0;                               \
        ca_size_t ki = (ca_size_t) floor(f);                                   \
        double vlo, vhi;                                                        \
        ca_nth_element_double(scratch, m, ki);   /* scratch[ki] = ki-th */      \
        vlo = scratch[ki];                                                      \
        if ( ki + 1 < m ) {          /* (ki+1)-th = min of upper partition */   \
          double mn = scratch[ki+1]; ca_size_t t;                             \
          for ( t = ki + 2; t < m; t++ ) if ( scratch[t] < mn ) mn = scratch[t]; \
          vhi = mn;                                                            \
        } else vhi = vlo;                                                      \
        outp[c] = vlo + (f - (double) ki) * (vhi - vlo); }                      \
    }                                                                           \
  } while (0)

static VALUE
rb_ca_reduceat_percentile (VALUE self, VALUE roffsets, VALUE rp, VALUE rout)
{
  CArray     *grouped, *offsets, *out;
  int64_t     k, *offs;
  ca_size_t   n, c, maxseg = 0;
  double      p, *outp, *scratch = NULL;
  boolean8_t *gm, *outm;

  GetCArray(self,     grouped);
  GetCArray(roffsets, offsets);
  GetCArray(rout,     out);
  p = NUM2DBL(rp);
  k = (int64_t) offsets->elements;
  n = grouped->elements;
  if ( offsets->data_type != CA_INT64 || out->data_type != CA_FLOAT64 ||
       out->elements != k ) {
    rb_raise(rb_eArgError, "__reduceat_percentile__: offsets int64, out float64[k]");
  }

  offs = (int64_t *) offsets->ptr;
  outp = (double *) out->ptr;
  gm   = ca_mask_ptr(grouped);
  ca_create_mask(out);
  outm = (boolean8_t *) out->mask->ptr;

  for ( c = 0; c < (ca_size_t) k; c++ ) {           /* scratch = largest segment */
    ca_size_t lo = (ca_size_t) offs[c];
    ca_size_t hi = (c + 1 < (ca_size_t) k) ? (ca_size_t) offs[c+1] : n;
    if ( hi - lo > maxseg ) maxseg = hi - lo;
  }
  if ( maxseg > 0 ) scratch = (double *) xmalloc((size_t) maxseg * sizeof(double));

  switch ( grouped->data_type ) {
  case CA_INT8:    REDUCEAT_PCT_BODY(int8_t);    break;
  case CA_UINT8:   REDUCEAT_PCT_BODY(uint8_t);   break;
  case CA_INT16:   REDUCEAT_PCT_BODY(int16_t);   break;
  case CA_UINT16:  REDUCEAT_PCT_BODY(uint16_t);  break;
  case CA_INT32:   REDUCEAT_PCT_BODY(int32_t);   break;
  case CA_UINT32:  REDUCEAT_PCT_BODY(uint32_t);  break;
  case CA_INT64:   REDUCEAT_PCT_BODY(int64_t);   break;
  case CA_UINT64:  REDUCEAT_PCT_BODY(uint64_t);  break;
  case CA_FLOAT32: REDUCEAT_PCT_BODY(float32_t); break;
  case CA_FLOAT64: REDUCEAT_PCT_BODY(float64_t); break;
  default:
    if ( scratch ) xfree(scratch);
    rb_raise(rb_eCADataTypeError,
             "__reduceat_percentile__: numeric value required (got data_type %d)",
             grouped->data_type);
  }
  if ( scratch ) xfree(scratch);
  return Qnil;
}

/* ---------------------------------------------------------------------------

  __reduceat_variance__ — centred two-pass SAMPLE variance (ddof=1) reduceat.
  The means (from the cached moments: sum/count) drive a second walk that
  accumulates the per-segment centred sum of squares; variance = SS / (n-1).
  Centred (not the one-pass sum-of-squares) so the ε-close contract holds — a
  one-pass formula cancels catastrophically.  Matches CArray#variance per group:
  count 0 -> masked (undefined), count 1 -> 0.0 (the n=1 contract), count >= 2 ->
  SS / (count-1).

  Surface (private): grouped.__reduceat_variance__(offsets, means, counts, out)
    self    = grouped  (numeric value data type, may carry a mask)
    offsets = int64[k] segment STARTS
    means   = float64[k] per-segment mean (ignored where count < 2)
    counts  = int64[k]   per-segment present count
    out     = float64[k] output: variance; count 0 masked, count 1 -> 0.0

--------------------------------------------------------------------------- */

#define REDUCEAT_VAR_BODY(T)                                                     \
  do {                                                                          \
    const T *gp = (const T *) grouped->ptr;                                     \
    for ( c = 0; c < k; c++ ) {                                                 \
      int64_t cnt = countp[c];                                                  \
      if ( cnt == 0 ) { outp[c] = 0.0; outm[c] = 1; continue; } /* -> masked */ \
      if ( cnt == 1 ) { outp[c] = 0.0; continue; }  /* n=1 contract: 0.0 */     \
      { double mean = meanp[c], ss = 0.0;                                       \
        ca_size_t lo = (ca_size_t) offs[c];                                     \
        ca_size_t hi = (c + 1 < k) ? (ca_size_t) offs[c+1] : n, j;              \
        if ( gm ) {                                                             \
          for ( j = lo; j < hi; j++ ) {                                         \
            if ( gm[j] ) continue;                                              \
            { double d = (double) gp[j] - mean; ss += d * d; }                  \
          }                                                                     \
        } else {                    /* no mask: SIMD-reassociable reduction */  \
          _Pragma("omp simd reduction(+:ss)")                                   \
          for ( j = lo; j < hi; j++ ) {                                         \
            double d = (double) gp[j] - mean; ss += d * d;                      \
          }                                                                     \
        }                                                                       \
        outp[c] = ss / (double) (cnt - 1); }                                    \
    }                                                                           \
  } while (0)

static VALUE
rb_ca_reduceat_variance (VALUE self, VALUE roffsets, VALUE rmeans,
                         VALUE rcounts, VALUE rout)
{
  CArray     *grouped, *offsets, *means, *counts, *out;
  int64_t     k, *offs, *countp;
  ca_size_t   n, c;
  double     *meanp, *outp;
  boolean8_t *gm, *outm;

  GetCArray(self,     grouped);
  GetCArray(roffsets, offsets);
  GetCArray(rmeans,   means);
  GetCArray(rcounts,  counts);
  GetCArray(rout,     out);

  k = (int64_t) offsets->elements;
  n = grouped->elements;
  if ( offsets->data_type != CA_INT64 || counts->data_type != CA_INT64 ||
       means->data_type != CA_FLOAT64 || out->data_type != CA_FLOAT64 ||
       means->elements != k || counts->elements != k || out->elements != k ) {
    rb_raise(rb_eArgError, "__reduceat_variance__: offsets/counts int64, means/out float64[k]");
  }

  offs   = (int64_t *) offsets->ptr;
  countp = (int64_t *) counts->ptr;
  meanp  = (double *)  means->ptr;
  outp   = (double *)  out->ptr;
  gm     = ca_mask_ptr(grouped);
  ca_create_mask(out);
  outm = (boolean8_t *) out->mask->ptr;

  switch ( grouped->data_type ) {
  case CA_INT8:    REDUCEAT_VAR_BODY(int8_t);    break;
  case CA_UINT8:   REDUCEAT_VAR_BODY(uint8_t);   break;
  case CA_INT16:   REDUCEAT_VAR_BODY(int16_t);   break;
  case CA_UINT16:  REDUCEAT_VAR_BODY(uint16_t);  break;
  case CA_INT32:   REDUCEAT_VAR_BODY(int32_t);   break;
  case CA_UINT32:  REDUCEAT_VAR_BODY(uint32_t);  break;
  case CA_INT64:   REDUCEAT_VAR_BODY(int64_t);   break;
  case CA_UINT64:  REDUCEAT_VAR_BODY(uint64_t);  break;
  case CA_FLOAT32: REDUCEAT_VAR_BODY(float32_t); break;
  case CA_FLOAT64: REDUCEAT_VAR_BODY(float64_t); break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__reduceat_variance__: numeric value required (got data_type %d)",
             grouped->data_type);
  }

  return Qnil;
}

/* ---------------------------------------------------------------------------

  Fused reduceat kernels for the categorical iterator's remaining reductions
  (prod / argmin+argmax / all+any / count(v) / five-number quantile). Each is a
  single walk over the grouped copy delimited by the segment offsets, replacing
  a per-category Ruby fallback. Value-mask-aware; each matches CArray's per-array
  contract per segment.

--------------------------------------------------------------------------- */

/* __reduceat_prod__(offsets, out) — per-segment product as float64; an empty /
   all-masked segment is 1.0 (the multiplicative identity). */
#define REDUCEAT_PROD_BODY(T)                                                    \
  do {                                                                          \
    const T *gp = (const T *) grouped->ptr;                                     \
    for ( c = 0; c < k; c++ ) {                                                 \
      ca_size_t lo = (ca_size_t) offs[c];                                       \
      ca_size_t hi = (c + 1 < k) ? (ca_size_t) offs[c+1] : n, j;               \
      double p = 1.0;                                                           \
      for ( j = lo; j < hi; j++ ) {                                             \
        if ( gm && gm[j] ) continue;                                            \
        p *= (double) gp[j];                                                    \
      }                                                                         \
      outp[c] = p;                                                              \
    }                                                                           \
  } while (0)

static VALUE
rb_ca_reduceat_prod (VALUE self, VALUE roffsets, VALUE rout)
{
  CArray     *grouped, *offsets, *out;
  int64_t     k, *offs;
  ca_size_t   n, c;
  double     *outp;
  boolean8_t *gm;

  GetCArray(self, grouped);
  GetCArray(roffsets, offsets);
  GetCArray(rout, out);
  k = (int64_t) offsets->elements;
  n = grouped->elements;
  if ( offsets->data_type != CA_INT64 || out->data_type != CA_FLOAT64 ||
       out->elements != k ) {
    rb_raise(rb_eArgError, "__reduceat_prod__: offsets int64, out float64[k]");
  }
  offs = (int64_t *) offsets->ptr;
  outp = (double *) out->ptr;
  gm   = ca_mask_ptr(grouped);

  switch ( grouped->data_type ) {
  case CA_INT8:    REDUCEAT_PROD_BODY(int8_t);    break;
  case CA_UINT8:   REDUCEAT_PROD_BODY(uint8_t);   break;
  case CA_INT16:   REDUCEAT_PROD_BODY(int16_t);   break;
  case CA_UINT16:  REDUCEAT_PROD_BODY(uint16_t);  break;
  case CA_INT32:   REDUCEAT_PROD_BODY(int32_t);   break;
  case CA_UINT32:  REDUCEAT_PROD_BODY(uint32_t);  break;
  case CA_INT64:   REDUCEAT_PROD_BODY(int64_t);   break;
  case CA_UINT64:  REDUCEAT_PROD_BODY(uint64_t);  break;
  case CA_FLOAT32: REDUCEAT_PROD_BODY(float32_t); break;
  case CA_FLOAT64: REDUCEAT_PROD_BODY(float64_t); break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__reduceat_prod__: numeric value required (got data_type %d)",
             grouped->data_type);
  }
  return Qnil;
}

/* __reduceat_argminmax__(offsets, min_idx, max_idx) — per-segment GROUP-LOCAL
   index of the min / max (position within the segment, first occurrence on
   ties). Empty / all-masked segments are masked. */
#define REDUCEAT_ARGMINMAX_BODY(T)                                              \
  do {                                                                          \
    const T *gp = (const T *) grouped->ptr;                                     \
    for ( c = 0; c < k; c++ ) {                                                 \
      ca_size_t lo = (ca_size_t) offs[c];                                       \
      ca_size_t hi = (c + 1 < k) ? (ca_size_t) offs[c+1] : n, j;               \
      ca_size_t mni = 0, mxi = 0; int seen = 0; T mn = 0, mx = 0;              \
      for ( j = lo; j < hi; j++ ) {                                             \
        if ( gm && gm[j] ) continue;                                            \
        { T v = gp[j]; ca_size_t li = j - lo;                                  \
          if ( ! seen ) { mn = mx = v; mni = mxi = li; seen = 1; }             \
          else { if ( v < mn ) { mn = v; mni = li; }                           \
                 if ( v > mx ) { mx = v; mxi = li; } } }                       \
      }                                                                         \
      if ( seen ) { minp[c] = (int64_t) mni; maxp[c] = (int64_t) mxi; }        \
      else { minp[c] = 0; maxp[c] = 0; minm[c] = 1; maxm[c] = 1; }             \
    }                                                                           \
  } while (0)

static VALUE
rb_ca_reduceat_argminmax (VALUE self, VALUE roffsets, VALUE rminidx, VALUE rmaxidx)
{
  CArray     *grouped, *offsets, *minidx, *maxidx;
  int64_t     k, *offs, *minp, *maxp;
  ca_size_t   n, c;
  boolean8_t *gm, *minm, *maxm;

  GetCArray(self, grouped);
  GetCArray(roffsets, offsets);
  GetCArray(rminidx, minidx);
  GetCArray(rmaxidx, maxidx);
  k = (int64_t) offsets->elements;
  n = grouped->elements;
  if ( offsets->data_type != CA_INT64 ||
       minidx->data_type != CA_INT64 || maxidx->data_type != CA_INT64 ||
       minidx->elements != k || maxidx->elements != k ) {
    rb_raise(rb_eArgError, "__reduceat_argminmax__: offsets/min_idx/max_idx int64[k]");
  }
  offs = (int64_t *) offsets->ptr;
  minp = (int64_t *) minidx->ptr;
  maxp = (int64_t *) maxidx->ptr;
  gm   = ca_mask_ptr(grouped);
  ca_create_mask(minidx);
  ca_create_mask(maxidx);
  minm = (boolean8_t *) minidx->mask->ptr;
  maxm = (boolean8_t *) maxidx->mask->ptr;

  switch ( grouped->data_type ) {
  case CA_INT8:    REDUCEAT_ARGMINMAX_BODY(int8_t);    break;
  case CA_UINT8:   REDUCEAT_ARGMINMAX_BODY(uint8_t);   break;
  case CA_INT16:   REDUCEAT_ARGMINMAX_BODY(int16_t);   break;
  case CA_UINT16:  REDUCEAT_ARGMINMAX_BODY(uint16_t);  break;
  case CA_INT32:   REDUCEAT_ARGMINMAX_BODY(int32_t);   break;
  case CA_UINT32:  REDUCEAT_ARGMINMAX_BODY(uint32_t);  break;
  case CA_INT64:   REDUCEAT_ARGMINMAX_BODY(int64_t);   break;
  case CA_UINT64:  REDUCEAT_ARGMINMAX_BODY(uint64_t);  break;
  case CA_FLOAT32: REDUCEAT_ARGMINMAX_BODY(float32_t); break;
  case CA_FLOAT64: REDUCEAT_ARGMINMAX_BODY(float64_t); break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__reduceat_argminmax__: numeric value required (got data_type %d)",
             grouped->data_type);
  }
  return Qnil;
}

/* __reduceat_all_any__(offsets, all_out, any_out) — per-segment boolean AND / OR
   over present cells. Value data type must be boolean. Empty segment: all -> true,
   any -> false. */
static VALUE
rb_ca_reduceat_all_any (VALUE self, VALUE roffsets, VALUE rall, VALUE rany)
{
  CArray     *grouped, *offsets, *all, *any;
  int64_t     k, *offs;
  ca_size_t   n, c;
  boolean8_t *gm, *gp, *allp, *anyp;

  GetCArray(self, grouped);
  GetCArray(roffsets, offsets);
  GetCArray(rall, all);
  GetCArray(rany, any);
  k = (int64_t) offsets->elements;
  n = grouped->elements;
  if ( grouped->data_type != CA_BOOLEAN ) {
    rb_raise(rb_eCADataTypeError,
             "__reduceat_all_any__: boolean value required (got data_type %d)",
             grouped->data_type);
  }
  if ( offsets->data_type != CA_INT64 ||
       all->data_type != CA_BOOLEAN || any->data_type != CA_BOOLEAN ||
       all->elements != k || any->elements != k ) {
    rb_raise(rb_eArgError, "__reduceat_all_any__: offsets int64, all/any boolean[k]");
  }
  offs = (int64_t *) offsets->ptr;
  gp   = (boolean8_t *) grouped->ptr;
  allp = (boolean8_t *) all->ptr;
  anyp = (boolean8_t *) any->ptr;
  gm   = ca_mask_ptr(grouped);

  for ( c = 0; c < (ca_size_t) k; c++ ) {
    ca_size_t lo = (ca_size_t) offs[c];
    ca_size_t hi = (c + 1 < (ca_size_t) k) ? (ca_size_t) offs[c+1] : n, j;
    boolean8_t av = 1, ov = 0;               /* empty: all true, any false */
    for ( j = lo; j < hi; j++ ) {
      if ( gm && gm[j] ) continue;
      if ( gp[j] ) ov = 1; else av = 0;
    }
    allp[c] = av;
    anyp[c] = ov;
  }
  return Qnil;
}

/* __reduceat_quantile__(offsets, p0, p25, p50, p75, p100) — fused five-number
   summary: one sort per segment yields all five percentiles (:linear
   interpolation, matching CArray#percentile). Empty / all-masked segments are
   masked in all five outputs. */
static int
cmp_double (const void *a, const void *b)
{
  double x = *(const double *) a, y = *(const double *) b;
  return (x < y) ? -1 : (x > y) ? 1 : 0;
}

#define REDUCEAT_QUANTILE_BODY(T)                                               \
  do {                                                                          \
    const T *gp = (const T *) grouped->ptr;                                     \
    static const double P[5] = { 0.0, 25.0, 50.0, 75.0, 100.0 };              \
    for ( c = 0; c < k; c++ ) {                                                 \
      ca_size_t lo = (ca_size_t) offs[c];                                       \
      ca_size_t hi = (c + 1 < k) ? (ca_size_t) offs[c+1] : n, jj, m = 0;       \
      int t;                                                                    \
      for ( jj = lo; jj < hi; jj++ ) {                                          \
        if ( gm && gm[jj] ) continue;                                           \
        scratch[m++] = (double) gp[jj];                                         \
      }                                                                         \
      if ( m == 0 ) { for ( t = 0; t < 5; t++ ) { outp[t][c] = 0.0; outm[t][c] = 1; } continue; } \
      qsort(scratch, (size_t) m, sizeof(double), cmp_double);                   \
      for ( t = 0; t < 5; t++ ) {                                               \
        double f = (double) (m - 1) * P[t] / 100.0;                            \
        ca_size_t ki = (ca_size_t) floor(f);                                   \
        double vlo = scratch[ki];                                              \
        double vhi = (ki + 1 < m) ? scratch[ki+1] : vlo;                       \
        outp[t][c] = vlo + (f - (double) ki) * (vhi - vlo);                     \
      }                                                                         \
    }                                                                           \
  } while (0)

static VALUE
rb_ca_reduceat_quantile (VALUE self, VALUE roffsets, VALUE rp0, VALUE rp25,
                         VALUE rp50, VALUE rp75, VALUE rp100)
{
  CArray     *grouped, *offsets, *outs[5];
  VALUE       routs[5];
  int64_t     k, *offs;
  ca_size_t   n, c, maxseg = 0;
  double     *outp[5], *scratch = NULL;
  boolean8_t *gm, *outm[5];
  int         t;

  GetCArray(self, grouped);
  GetCArray(roffsets, offsets);
  routs[0] = rp0; routs[1] = rp25; routs[2] = rp50; routs[3] = rp75; routs[4] = rp100;
  k = (int64_t) offsets->elements;
  n = grouped->elements;
  if ( offsets->data_type != CA_INT64 ) {
    rb_raise(rb_eArgError, "__reduceat_quantile__: offsets int64");
  }
  offs = (int64_t *) offsets->ptr;
  gm   = ca_mask_ptr(grouped);
  for ( t = 0; t < 5; t++ ) {
    GetCArray(routs[t], outs[t]);
    if ( outs[t]->data_type != CA_FLOAT64 || outs[t]->elements != k ) {
      rb_raise(rb_eArgError, "__reduceat_quantile__: each out float64[k]");
    }
    outp[t] = (double *) outs[t]->ptr;
    ca_create_mask(outs[t]);
    outm[t] = (boolean8_t *) outs[t]->mask->ptr;
  }

  for ( c = 0; c < (ca_size_t) k; c++ ) {
    ca_size_t lo = (ca_size_t) offs[c];
    ca_size_t hi = (c + 1 < (ca_size_t) k) ? (ca_size_t) offs[c+1] : n;
    if ( hi - lo > maxseg ) maxseg = hi - lo;
  }
  if ( maxseg > 0 ) scratch = (double *) xmalloc((size_t) maxseg * sizeof(double));

  switch ( grouped->data_type ) {
  case CA_INT8:    REDUCEAT_QUANTILE_BODY(int8_t);    break;
  case CA_UINT8:   REDUCEAT_QUANTILE_BODY(uint8_t);   break;
  case CA_INT16:   REDUCEAT_QUANTILE_BODY(int16_t);   break;
  case CA_UINT16:  REDUCEAT_QUANTILE_BODY(uint16_t);  break;
  case CA_INT32:   REDUCEAT_QUANTILE_BODY(int32_t);   break;
  case CA_UINT32:  REDUCEAT_QUANTILE_BODY(uint32_t);  break;
  case CA_INT64:   REDUCEAT_QUANTILE_BODY(int64_t);   break;
  case CA_UINT64:  REDUCEAT_QUANTILE_BODY(uint64_t);  break;
  case CA_FLOAT32: REDUCEAT_QUANTILE_BODY(float32_t); break;
  case CA_FLOAT64: REDUCEAT_QUANTILE_BODY(float64_t); break;
  default:
    if ( scratch ) xfree(scratch);
    rb_raise(rb_eCADataTypeError,
             "__reduceat_quantile__: numeric value required (got data_type %d)",
             grouped->data_type);
  }
  if ( scratch ) xfree(scratch);
  return Qnil;
}

/* __reduceat_wsum_wmean__(offsets, wg, wsum_out, wmean_out) — fused per-segment
   weighted sum and weighted mean in one pass. `wg` is the weights laid out in
   group order (float64, weight mask propagated). A cell contributes iff its
   value AND its weight are present. wsum_out = Sum(v*w) (0.0 for a segment with
   no present pair, the additive identity). wmean_out = Sum(v*w)/Sum(w), masked
   when the segment has no present pair (matching CArray#wmean UNDEF); a present
   segment whose weights sum to zero yields NaN/Inf from the division (core's
   0/0 contract). */
#define REDUCEAT_WSUM_BODY(T)                                                   \
  do {                                                                          \
    const T *gp = (const T *) grouped->ptr;                                     \
    for ( c = 0; c < k; c++ ) {                                                 \
      ca_size_t lo = (ca_size_t) offs[c];                                       \
      ca_size_t hi = (c + 1 < k) ? (ca_size_t) offs[c+1] : n, j, cnt = 0;      \
      double svw = 0.0, sw = 0.0;                                              \
      for ( j = lo; j < hi; j++ ) {                                             \
        if ( gm && gm[j] ) continue;                    /* value masked */      \
        if ( wgm && wgm[j] ) continue;                  /* weight masked */     \
        { double wv = wp[j]; svw += (double) gp[j] * wv; sw += wv; cnt++; }     \
      }                                                                         \
      wsp[c] = svw;                                                             \
      if ( cnt == 0 ) { wmp[c] = 0.0; wmm[c] = 1; }     /* no present pair */    \
      else wmp[c] = svw / sw;                                                   \
    }                                                                           \
  } while (0)

static VALUE
rb_ca_reduceat_wsum_wmean (VALUE self, VALUE roffsets, VALUE rwg,
                           VALUE rwsum, VALUE rwmean)
{
  CArray     *grouped, *offsets, *wg, *wsum, *wmean;
  int64_t     k, *offs;
  ca_size_t   n, c;
  double     *wp, *wsp, *wmp;
  boolean8_t *gm, *wgm, *wmm;

  GetCArray(self, grouped);
  GetCArray(roffsets, offsets);
  GetCArray(rwg, wg);
  GetCArray(rwsum, wsum);
  GetCArray(rwmean, wmean);
  k = (int64_t) offsets->elements;
  n = grouped->elements;
  if ( offsets->data_type != CA_INT64 || wg->data_type != CA_FLOAT64 ||
       wsum->data_type != CA_FLOAT64 || wmean->data_type != CA_FLOAT64 ||
       wg->elements != n || wsum->elements != k || wmean->elements != k ) {
    rb_raise(rb_eArgError,
             "__reduceat_wsum_wmean__: offsets int64, wg/out float64, wg[n] out[k]");
  }
  offs = (int64_t *) offsets->ptr;
  wp   = (double *) wg->ptr;
  wsp  = (double *) wsum->ptr;
  wmp  = (double *) wmean->ptr;
  gm   = ca_mask_ptr(grouped);
  wgm  = ca_mask_ptr(wg);
  ca_create_mask(wmean);
  wmm = (boolean8_t *) wmean->mask->ptr;

  switch ( grouped->data_type ) {
  case CA_INT8:    REDUCEAT_WSUM_BODY(int8_t);    break;
  case CA_UINT8:   REDUCEAT_WSUM_BODY(uint8_t);   break;
  case CA_INT16:   REDUCEAT_WSUM_BODY(int16_t);   break;
  case CA_UINT16:  REDUCEAT_WSUM_BODY(uint16_t);  break;
  case CA_INT32:   REDUCEAT_WSUM_BODY(int32_t);   break;
  case CA_UINT32:  REDUCEAT_WSUM_BODY(uint32_t);  break;
  case CA_INT64:   REDUCEAT_WSUM_BODY(int64_t);   break;
  case CA_UINT64:  REDUCEAT_WSUM_BODY(uint64_t);  break;
  case CA_FLOAT32: REDUCEAT_WSUM_BODY(float32_t); break;
  case CA_FLOAT64: REDUCEAT_WSUM_BODY(float64_t); break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__reduceat_wsum_wmean__: numeric value required (got data_type %d)",
             grouped->data_type);
  }
  return Qnil;
}

/* ---------------------------------------------------------------------------

  __fiber_scatter_moments__ — per-fiber scatter-reduce (count + sum fused).

  The band-preserving sibling of __reduceat_moments__: reduces `h` along `axis`
  per (band-coord) fiber, dispatched by `codes`.  Ruby side broadcasts codes to
  h.shape before this call so all three shape cases (A / B / band-only,
  PROPOSAL_CATEGORICAL_REDUCE_AXIS §2.2) collapse to one kernel signature.

  Not aligned kernel_iterator: output position depends on the codes value
  (data-dependent scatter), so ca_attach materialises the inputs into
  contiguous flat buffers — same pattern as sibling __categorical_scatter__.

  Surface (private):
    h.__fiber_scatter_moments__(codes, axis, K, counts_out, sums_out)
      self       = h        (numeric, mask allowed, shape H)
      codes      = classifier (integer, mask allowed, shape H, pre-broadcast)
      axis       = reduce axis (Integer)
      K          = category count (Integer)
      counts_out = int64,   shape [K, ...H.band]  (present cells per group)
      sums_out   = float64, shape [K, ...H.band]  (per-group sum, 0 for empty)

  Sums as float64 mirrors __reduceat_moments__; Ruby side casts to h data type in
  #sum (matches existing empty→0 identity contract).  Mins/maxs are in h data type
  (empty group cell → 0 + masked, matching __reduceat_moments__).
--------------------------------------------------------------------------- */

#define FIBER_SCATTER_BODY(H_T, C_T)                                          \
  do {                                                                        \
    const H_T *hp   = (const H_T *) h->ptr;                                   \
    const C_T *cp   = (const C_T *) codes->ptr;                               \
    H_T       *minv = (H_T *) minp;                                           \
    H_T       *maxv = (H_T *) maxp;                                           \
    for ( outer = 0; outer < outer_prod; outer++ ) {                          \
      ca_size_t outer_off = outer * axis_size * inner_prod;                   \
      ca_size_t out_outer = outer * inner_prod;                               \
      for ( ax = 0; ax < axis_size; ax++ ) {                                  \
        ca_size_t row_off = outer_off + ax * inner_prod;                      \
        for ( inn = 0; inn < inner_prod; inn++ ) {                            \
          ca_size_t off = row_off + inn;                                      \
          int64_t c;                                                          \
          ca_size_t out_off;                                                  \
          H_T v;                                                              \
          if ( hm && hm[off] ) continue;    /* value cell masked */           \
          if ( cm && cm[off] ) continue;    /* codes cell masked (excluded) */\
          c = (int64_t) cp[off];                                              \
          if ( c < 0 || c >= K ) continue;  /* out-of-vocabulary */           \
          out_off = c * band_size + out_outer + inn;                          \
          v = hp[off];                                                        \
          if ( countp[out_off] == 0 ) {                                       \
            minv[out_off] = v; maxv[out_off] = v;                             \
          } else {                                                            \
            if ( v < minv[out_off] ) minv[out_off] = v;                       \
            if ( v > maxv[out_off] ) maxv[out_off] = v;                       \
          }                                                                   \
          countp[out_off]++;                                                  \
          sump[out_off] += (double) v;                                        \
        }                                                                     \
      }                                                                       \
    }                                                                         \
  } while (0)

#define FIBER_SCATTER_DISPATCH_C(H_T)                                         \
  switch ( codes->data_type ) {                                               \
  case CA_INT8:    FIBER_SCATTER_BODY(H_T, int8_t);    break;                 \
  case CA_UINT8:   FIBER_SCATTER_BODY(H_T, uint8_t);   break;                 \
  case CA_INT16:   FIBER_SCATTER_BODY(H_T, int16_t);   break;                 \
  case CA_UINT16:  FIBER_SCATTER_BODY(H_T, uint16_t);  break;                 \
  case CA_INT32:   FIBER_SCATTER_BODY(H_T, int32_t);   break;                 \
  case CA_UINT32:  FIBER_SCATTER_BODY(H_T, uint32_t);  break;                 \
  case CA_INT64:   FIBER_SCATTER_BODY(H_T, int64_t);   break;                 \
  case CA_UINT64:  FIBER_SCATTER_BODY(H_T, uint64_t);  break;                 \
  default:                                                                    \
    ca_detach(h); ca_detach(codes);                                           \
    rb_raise(rb_eCADataTypeError,                                             \
             "__fiber_scatter_moments__: codes must be integer (got %d)",     \
             codes->data_type);                                               \
  }

static VALUE
rb_ca_fiber_scatter_moments (VALUE self, VALUE rcodes, VALUE raxis, VALUE rk,
                             VALUE rcounts, VALUE rsums,
                             VALUE rmins, VALUE rmaxs)
{
  CArray     *h, *codes, *counts, *sums, *mins, *maxs;
  int64_t     K, *countp;
  int         axis;
  ca_size_t   ax, inn, outer, cell;
  ca_size_t   axis_size, inner_prod, outer_prod, band_size, total;
  double     *sump;
  char       *minp, *maxp;
  boolean8_t *hm, *cm, *minm, *maxm;
  int8_t      i, j;

  GetCArray(self,    h);
  GetCArray(rcodes,  codes);
  GetCArray(rcounts, counts);
  GetCArray(rsums,   sums);
  GetCArray(rmins,   mins);
  GetCArray(rmaxs,   maxs);
  axis = NUM2INT(raxis);
  K    = NUM2LL(rk);

  if ( axis < 0 || axis >= h->ndim ) {
    rb_raise(rb_eArgError, "__fiber_scatter_moments__: axis %d out of range [0, %d)",
             axis, h->ndim);
  }
  if ( codes->ndim != h->ndim ) {
    rb_raise(rb_eArgError,
             "__fiber_scatter_moments__: codes.ndim=%d != h.ndim=%d "
             "(Ruby side must broadcast codes to h.shape)",
             codes->ndim, h->ndim);
  }
  for ( i = 0; i < h->ndim; i++ ) {
    if ( codes->dim[i] != h->dim[i] ) {
      rb_raise(rb_eArgError,
               "__fiber_scatter_moments__: codes.dim[%d]=%lld != h.dim[%d]=%lld",
               (int) i, (long long) codes->dim[i], (int) i, (long long) h->dim[i]);
    }
  }
  if ( counts->data_type != CA_INT64 || sums->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError,
             "__fiber_scatter_moments__: counts must be int64, sums must be float64");
  }
  if ( mins->data_type != h->data_type || maxs->data_type != h->data_type ) {
    rb_raise(rb_eArgError,
             "__fiber_scatter_moments__: mins/maxs must match h data type");
  }
  if ( counts->ndim != h->ndim || sums->ndim != h->ndim ||
       mins->ndim != h->ndim   || maxs->ndim != h->ndim ||
       counts->dim[0] != K || sums->dim[0] != K ||
       mins->dim[0]   != K || maxs->dim[0] != K ) {
    rb_raise(rb_eArgError,
             "__fiber_scatter_moments__: counts/sums/mins/maxs must have shape [K=%lld, ...band]",
             (long long) K);
  }
  j = 1;
  for ( i = 0; i < h->ndim; i++ ) {
    if ( i == axis ) continue;
    if ( counts->dim[j] != h->dim[i] || sums->dim[j] != h->dim[i] ||
         mins->dim[j]   != h->dim[i] || maxs->dim[j] != h->dim[i] ) {
      rb_raise(rb_eArgError,
               "__fiber_scatter_moments__: counts/sums/mins/maxs band dim mismatch at output axis %d",
               (int) j);
    }
    j++;
  }

  axis_size  = h->dim[axis];
  inner_prod = 1;
  for ( i = (int8_t)(axis + 1); i < h->ndim; i++ ) inner_prod *= h->dim[i];
  outer_prod = 1;
  for ( i = 0; i < axis; i++ ) outer_prod *= h->dim[i];
  band_size  = outer_prod * inner_prod;
  total      = (ca_size_t)(K * band_size);

  ca_attach(h);
  ca_attach(codes);
  hm = ca_mask_ptr(h);
  cm = ca_mask_ptr(codes);
  countp = (int64_t *) counts->ptr;
  sump   = (double  *) sums->ptr;
  minp   = mins->ptr;
  maxp   = maxs->ptr;

  memset(countp, 0, (size_t) total * sizeof(int64_t));
  memset(sump,   0, (size_t) total * sizeof(double));
  memset(minp,   0, (size_t) total * (size_t) h->bytes);
  memset(maxp,   0, (size_t) total * (size_t) h->bytes);

  switch ( h->data_type ) {
  case CA_INT8:    FIBER_SCATTER_DISPATCH_C(int8_t);    break;
  case CA_UINT8:   FIBER_SCATTER_DISPATCH_C(uint8_t);   break;
  case CA_INT16:   FIBER_SCATTER_DISPATCH_C(int16_t);   break;
  case CA_UINT16:  FIBER_SCATTER_DISPATCH_C(uint16_t);  break;
  case CA_INT32:   FIBER_SCATTER_DISPATCH_C(int32_t);   break;
  case CA_UINT32:  FIBER_SCATTER_DISPATCH_C(uint32_t);  break;
  case CA_INT64:   FIBER_SCATTER_DISPATCH_C(int64_t);   break;
  case CA_UINT64:  FIBER_SCATTER_DISPATCH_C(uint64_t);  break;
  case CA_FLOAT32: FIBER_SCATTER_DISPATCH_C(float32_t); break;
  case CA_FLOAT64: FIBER_SCATTER_DISPATCH_C(float64_t); break;
  default:
    ca_detach(h); ca_detach(codes);
    rb_raise(rb_eCADataTypeError,
             "__fiber_scatter_moments__: numeric value required (got %d)",
             h->data_type);
  }

  /* Mask empty (count == 0) cells in mins/maxs: value slot is 0 but meaningless.
     Matches __reduceat_moments__ contract for empty segments. */
  ca_create_mask(mins);
  ca_create_mask(maxs);
  minm = (boolean8_t *) mins->mask->ptr;
  maxm = (boolean8_t *) maxs->mask->ptr;
  for ( cell = 0; cell < total; cell++ ) {
    if ( countp[cell] == 0 ) { minm[cell] = 1; maxm[cell] = 1; }
  }

  ca_detach(h);
  ca_detach(codes);
  return Qnil;
}

/* ---------------------------------------------------------------------------

  __fiber_scatter_prod__ — per-fiber scatter product (identity 1.0).

  Sibling of __fiber_scatter_moments__ separated for the different identity:
  sum's zero-init memset would give 0 for empty groups, which is prod's
  annihilator not identity.  Ruby side broadcasts codes to h.shape.

  Surface (private):
    h.__fiber_scatter_prod__(codes, axis, K, out)
      self = h        (numeric, mask allowed, shape H)
      codes           (integer, mask allowed, shape H, pre-broadcast)
      axis            (Integer)
      K               (Integer)
      out             (float64, shape [K, ...H.band]) — 1.0 for empty groups
--------------------------------------------------------------------------- */

#define FIBER_SCATTER_PROD_BODY(H_T, C_T)                                     \
  do {                                                                        \
    const H_T *hp = (const H_T *) h->ptr;                                     \
    const C_T *cp = (const C_T *) codes->ptr;                                 \
    for ( outer = 0; outer < outer_prod; outer++ ) {                          \
      ca_size_t outer_off = outer * axis_size * inner_prod;                   \
      ca_size_t out_outer = outer * inner_prod;                               \
      for ( ax = 0; ax < axis_size; ax++ ) {                                  \
        ca_size_t row_off = outer_off + ax * inner_prod;                      \
        for ( inn = 0; inn < inner_prod; inn++ ) {                            \
          ca_size_t off = row_off + inn;                                      \
          int64_t c;                                                          \
          ca_size_t out_off;                                                  \
          if ( hm && hm[off] ) continue;                                      \
          if ( cm && cm[off] ) continue;                                      \
          c = (int64_t) cp[off];                                              \
          if ( c < 0 || c >= K ) continue;                                    \
          out_off = c * band_size + out_outer + inn;                          \
          outp[out_off] *= (double) hp[off];                                  \
        }                                                                     \
      }                                                                       \
    }                                                                         \
  } while (0)

#define FIBER_SCATTER_PROD_DISPATCH_C(H_T)                                    \
  switch ( codes->data_type ) {                                               \
  case CA_INT8:    FIBER_SCATTER_PROD_BODY(H_T, int8_t);    break;            \
  case CA_UINT8:   FIBER_SCATTER_PROD_BODY(H_T, uint8_t);   break;            \
  case CA_INT16:   FIBER_SCATTER_PROD_BODY(H_T, int16_t);   break;            \
  case CA_UINT16:  FIBER_SCATTER_PROD_BODY(H_T, uint16_t);  break;            \
  case CA_INT32:   FIBER_SCATTER_PROD_BODY(H_T, int32_t);   break;            \
  case CA_UINT32:  FIBER_SCATTER_PROD_BODY(H_T, uint32_t);  break;            \
  case CA_INT64:   FIBER_SCATTER_PROD_BODY(H_T, int64_t);   break;            \
  case CA_UINT64:  FIBER_SCATTER_PROD_BODY(H_T, uint64_t);  break;            \
  default:                                                                    \
    ca_detach(h); ca_detach(codes);                                           \
    rb_raise(rb_eCADataTypeError,                                             \
             "__fiber_scatter_prod__: codes must be integer (got %d)",        \
             codes->data_type);                                               \
  }

static VALUE
rb_ca_fiber_scatter_prod (VALUE self, VALUE rcodes, VALUE raxis,
                          VALUE rk, VALUE rout)
{
  CArray     *h, *codes, *out;
  int64_t     K;
  int         axis;
  ca_size_t   ax, inn, outer, cell;
  ca_size_t   axis_size, inner_prod, outer_prod, band_size, total;
  double     *outp;
  boolean8_t *hm, *cm;
  int8_t      i, j;

  GetCArray(self,   h);
  GetCArray(rcodes, codes);
  GetCArray(rout,   out);
  axis = NUM2INT(raxis);
  K    = NUM2LL(rk);

  if ( axis < 0 || axis >= h->ndim ) {
    rb_raise(rb_eArgError, "__fiber_scatter_prod__: axis %d out of range [0, %d)",
             axis, h->ndim);
  }
  if ( codes->ndim != h->ndim ) {
    rb_raise(rb_eArgError,
             "__fiber_scatter_prod__: codes.ndim=%d != h.ndim=%d",
             codes->ndim, h->ndim);
  }
  for ( i = 0; i < h->ndim; i++ ) {
    if ( codes->dim[i] != h->dim[i] ) {
      rb_raise(rb_eArgError,
               "__fiber_scatter_prod__: codes.dim[%d]=%lld != h.dim[%d]=%lld",
               (int) i, (long long) codes->dim[i], (int) i, (long long) h->dim[i]);
    }
  }
  if ( out->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "__fiber_scatter_prod__: out must be float64");
  }
  if ( out->ndim != h->ndim || out->dim[0] != K ) {
    rb_raise(rb_eArgError,
             "__fiber_scatter_prod__: out must have shape [K=%lld, ...band]",
             (long long) K);
  }
  j = 1;
  for ( i = 0; i < h->ndim; i++ ) {
    if ( i == axis ) continue;
    if ( out->dim[j] != h->dim[i] ) {
      rb_raise(rb_eArgError,
               "__fiber_scatter_prod__: out band dim mismatch at output axis %d",
               (int) j);
    }
    j++;
  }

  axis_size  = h->dim[axis];
  inner_prod = 1;
  for ( i = (int8_t)(axis + 1); i < h->ndim; i++ ) inner_prod *= h->dim[i];
  outer_prod = 1;
  for ( i = 0; i < axis; i++ ) outer_prod *= h->dim[i];
  band_size  = outer_prod * inner_prod;
  total      = (ca_size_t)(K * band_size);

  ca_attach(h);
  ca_attach(codes);
  hm   = ca_mask_ptr(h);
  cm   = ca_mask_ptr(codes);
  outp = (double *) out->ptr;

  /* identity 1.0 for prod (empty group -> 1.0, matches CArray#prod) */
  for ( cell = 0; cell < total; cell++ ) outp[cell] = 1.0;

  switch ( h->data_type ) {
  case CA_INT8:    FIBER_SCATTER_PROD_DISPATCH_C(int8_t);    break;
  case CA_UINT8:   FIBER_SCATTER_PROD_DISPATCH_C(uint8_t);   break;
  case CA_INT16:   FIBER_SCATTER_PROD_DISPATCH_C(int16_t);   break;
  case CA_UINT16:  FIBER_SCATTER_PROD_DISPATCH_C(uint16_t);  break;
  case CA_INT32:   FIBER_SCATTER_PROD_DISPATCH_C(int32_t);   break;
  case CA_UINT32:  FIBER_SCATTER_PROD_DISPATCH_C(uint32_t);  break;
  case CA_INT64:   FIBER_SCATTER_PROD_DISPATCH_C(int64_t);   break;
  case CA_UINT64:  FIBER_SCATTER_PROD_DISPATCH_C(uint64_t);  break;
  case CA_FLOAT32: FIBER_SCATTER_PROD_DISPATCH_C(float32_t); break;
  case CA_FLOAT64: FIBER_SCATTER_PROD_DISPATCH_C(float64_t); break;
  default:
    ca_detach(h); ca_detach(codes);
    rb_raise(rb_eCADataTypeError,
             "__fiber_scatter_prod__: numeric value required (got %d)",
             h->data_type);
  }

  ca_detach(h);
  ca_detach(codes);
  return Qnil;
}

/* ---------------------------------------------------------------------------

  __fiber_scatter_wsum_wmean__ — fused per-fiber weighted sum + weighted mean.

  Per-fiber sibling of __reduceat_wsum_wmean__.  Ruby side broadcasts codes to
  h.shape; weights must already match h.shape exactly (rev3 requires explicit
  broadcast for weights).  A cell contributes iff its value AND its weight are
  present (masked either way skips), matching CArray#wsum / #wmean per fiber.

  Surface (private):
    h.__fiber_scatter_wsum_wmean__(codes, weights, axis, K, wsum_out, wmean_out)
      self      = h        (numeric, mask allowed, shape H)
      codes     = classifier (integer, mask allowed, shape H, pre-broadcast)
      weights   = weight   (float64, mask allowed, shape H, pre-broadcast)
      axis      = reduce axis (Integer)
      K         = category count (Integer)
      wsum_out  = float64, shape [K, ...H.band]  (0.0 for empty)
      wmean_out = float64, shape [K, ...H.band]  (MASKED where no present pair)
--------------------------------------------------------------------------- */

#define FIBER_SCATTER_WSUM_BODY(H_T, C_T)                                     \
  do {                                                                        \
    const H_T *hp = (const H_T *) h->ptr;                                     \
    const C_T *cp = (const C_T *) codes->ptr;                                 \
    for ( outer = 0; outer < outer_prod; outer++ ) {                          \
      ca_size_t outer_off = outer * axis_size * inner_prod;                   \
      ca_size_t out_outer = outer * inner_prod;                               \
      for ( ax = 0; ax < axis_size; ax++ ) {                                  \
        ca_size_t row_off = outer_off + ax * inner_prod;                      \
        for ( inn = 0; inn < inner_prod; inn++ ) {                            \
          ca_size_t off = row_off + inn;                                      \
          int64_t c;                                                          \
          ca_size_t out_off;                                                  \
          double wv;                                                          \
          if ( hm && hm[off] ) continue;    /* value cell masked */           \
          if ( wm && wm[off] ) continue;    /* weight cell masked */          \
          if ( cm && cm[off] ) continue;    /* codes cell masked */           \
          c = (int64_t) cp[off];                                              \
          if ( c < 0 || c >= K ) continue;                                    \
          out_off = c * band_size + out_outer + inn;                          \
          wv = wp[off];                                                       \
          wsp[out_off] += (double) hp[off] * wv;                              \
          wsw[out_off] += wv;                                                 \
          cntp[out_off]++;                                                    \
        }                                                                     \
      }                                                                       \
    }                                                                         \
  } while (0)

#define FIBER_SCATTER_WSUM_DISPATCH_C(H_T)                                    \
  switch ( codes->data_type ) {                                               \
  case CA_INT8:    FIBER_SCATTER_WSUM_BODY(H_T, int8_t);    break;            \
  case CA_UINT8:   FIBER_SCATTER_WSUM_BODY(H_T, uint8_t);   break;            \
  case CA_INT16:   FIBER_SCATTER_WSUM_BODY(H_T, int16_t);   break;            \
  case CA_UINT16:  FIBER_SCATTER_WSUM_BODY(H_T, uint16_t);  break;            \
  case CA_INT32:   FIBER_SCATTER_WSUM_BODY(H_T, int32_t);   break;            \
  case CA_UINT32:  FIBER_SCATTER_WSUM_BODY(H_T, uint32_t);  break;            \
  case CA_INT64:   FIBER_SCATTER_WSUM_BODY(H_T, int64_t);   break;            \
  case CA_UINT64:  FIBER_SCATTER_WSUM_BODY(H_T, uint64_t);  break;            \
  default:                                                                    \
    ca_detach(h); ca_detach(codes); ca_detach(weights);                       \
    rb_raise(rb_eCADataTypeError,                                             \
             "__fiber_scatter_wsum_wmean__: codes must be integer (got %d)",  \
             codes->data_type);                                               \
  }

static VALUE
rb_ca_fiber_scatter_wsum_wmean (VALUE self, VALUE rcodes, VALUE rweights,
                                VALUE raxis, VALUE rk,
                                VALUE rwsum, VALUE rwmean)
{
  CArray     *h, *codes, *weights, *wsum, *wmean;
  int64_t     K, *cntp;
  int         axis;
  ca_size_t   ax, inn, outer, cell;
  ca_size_t   axis_size, inner_prod, outer_prod, band_size, total;
  double     *wp, *wsp, *wsw, *wmp;
  boolean8_t *hm, *cm, *wm, *wmm;
  int8_t      i, j;
  int64_t    *cnt_scratch = NULL;

  GetCArray(self,     h);
  GetCArray(rcodes,   codes);
  GetCArray(rweights, weights);
  GetCArray(rwsum,    wsum);
  GetCArray(rwmean,   wmean);
  axis = NUM2INT(raxis);
  K    = NUM2LL(rk);

  if ( axis < 0 || axis >= h->ndim ) {
    rb_raise(rb_eArgError, "__fiber_scatter_wsum_wmean__: axis %d out of range [0, %d)",
             axis, h->ndim);
  }
  if ( codes->ndim != h->ndim || weights->ndim != h->ndim ) {
    rb_raise(rb_eArgError,
             "__fiber_scatter_wsum_wmean__: codes.ndim=%d, weights.ndim=%d, "
             "expected h.ndim=%d (Ruby side must broadcast/expand to h.shape)",
             codes->ndim, weights->ndim, h->ndim);
  }
  for ( i = 0; i < h->ndim; i++ ) {
    if ( codes->dim[i] != h->dim[i] || weights->dim[i] != h->dim[i] ) {
      rb_raise(rb_eArgError,
               "__fiber_scatter_wsum_wmean__: codes/weights dim[%d] must equal h.dim[%d]=%lld",
               (int) i, (int) i, (long long) h->dim[i]);
    }
  }
  if ( weights->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "__fiber_scatter_wsum_wmean__: weights must be float64");
  }
  if ( wsum->data_type != CA_FLOAT64 || wmean->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "__fiber_scatter_wsum_wmean__: wsum/wmean must be float64");
  }
  if ( wsum->ndim != h->ndim || wmean->ndim != h->ndim ||
       wsum->dim[0] != K || wmean->dim[0] != K ) {
    rb_raise(rb_eArgError,
             "__fiber_scatter_wsum_wmean__: wsum/wmean must have shape [K=%lld, ...band]",
             (long long) K);
  }
  j = 1;
  for ( i = 0; i < h->ndim; i++ ) {
    if ( i == axis ) continue;
    if ( wsum->dim[j] != h->dim[i] || wmean->dim[j] != h->dim[i] ) {
      rb_raise(rb_eArgError,
               "__fiber_scatter_wsum_wmean__: wsum/wmean band dim mismatch at output axis %d",
               (int) j);
    }
    j++;
  }

  axis_size  = h->dim[axis];
  inner_prod = 1;
  for ( i = (int8_t)(axis + 1); i < h->ndim; i++ ) inner_prod *= h->dim[i];
  outer_prod = 1;
  for ( i = 0; i < axis; i++ ) outer_prod *= h->dim[i];
  band_size  = outer_prod * inner_prod;
  total      = (ca_size_t)(K * band_size);

  ca_attach(h);
  ca_attach(codes);
  ca_attach(weights);
  hm  = ca_mask_ptr(h);
  cm  = ca_mask_ptr(codes);
  wm  = ca_mask_ptr(weights);
  wp  = (double *) weights->ptr;
  wsp = (double *) wsum->ptr;    /* wsum output */
  wmp = (double *) wmean->ptr;   /* wmean output (temp = sum-of-weights, then divide) */

  /* Two auxiliary scratches: sum-of-weights (per cell) and present-pair count. */
  wsw = (double *) xmalloc((size_t) total * sizeof(double));
  cnt_scratch = (int64_t *) xmalloc((size_t) total * sizeof(int64_t));

  memset(wsp,         0, (size_t) total * sizeof(double));
  memset(wsw,         0, (size_t) total * sizeof(double));
  memset(cnt_scratch, 0, (size_t) total * sizeof(int64_t));
  cntp = cnt_scratch;

  switch ( h->data_type ) {
  case CA_INT8:    FIBER_SCATTER_WSUM_DISPATCH_C(int8_t);    break;
  case CA_UINT8:   FIBER_SCATTER_WSUM_DISPATCH_C(uint8_t);   break;
  case CA_INT16:   FIBER_SCATTER_WSUM_DISPATCH_C(int16_t);   break;
  case CA_UINT16:  FIBER_SCATTER_WSUM_DISPATCH_C(uint16_t);  break;
  case CA_INT32:   FIBER_SCATTER_WSUM_DISPATCH_C(int32_t);   break;
  case CA_UINT32:  FIBER_SCATTER_WSUM_DISPATCH_C(uint32_t);  break;
  case CA_INT64:   FIBER_SCATTER_WSUM_DISPATCH_C(int64_t);   break;
  case CA_UINT64:  FIBER_SCATTER_WSUM_DISPATCH_C(uint64_t);  break;
  case CA_FLOAT32: FIBER_SCATTER_WSUM_DISPATCH_C(float32_t); break;
  case CA_FLOAT64: FIBER_SCATTER_WSUM_DISPATCH_C(float64_t); break;
  default:
    xfree(wsw); xfree(cnt_scratch);
    ca_detach(h); ca_detach(codes); ca_detach(weights);
    rb_raise(rb_eCADataTypeError,
             "__fiber_scatter_wsum_wmean__: numeric value required (got %d)",
             h->data_type);
  }

  /* Compute wmean = wsum / sum-of-weights; mask cells with no present pair. */
  ca_create_mask(wmean);
  wmm = (boolean8_t *) wmean->mask->ptr;
  for ( cell = 0; cell < total; cell++ ) {
    if ( cntp[cell] == 0 ) {
      wmp[cell] = 0.0;
      wmm[cell] = 1;
    } else {
      wmp[cell] = wsp[cell] / wsw[cell];    /* 0/0 -> NaN naturally (core contract) */
    }
  }

  xfree(wsw);
  xfree(cnt_scratch);
  ca_detach(h);
  ca_detach(codes);
  ca_detach(weights);
  return Qnil;
}

void
Init_ca_categorical_iterator (void)
{
  rb_define_private_method(rb_cCArray, "__categorical_scatter__",
                           rb_ca_categorical_scatter, 4);
  rb_define_private_method(rb_cCArray, "__fiber_scatter_moments__",
                           rb_ca_fiber_scatter_moments, 7);
  rb_define_private_method(rb_cCArray, "__fiber_scatter_prod__",
                           rb_ca_fiber_scatter_prod, 4);
  rb_define_private_method(rb_cCArray, "__fiber_scatter_wsum_wmean__",
                           rb_ca_fiber_scatter_wsum_wmean, 6);
  rb_define_private_method(rb_cCArray, "__reduceat_moments__",
                           rb_ca_reduceat_moments, 5);
  rb_define_private_method(rb_cCArray, "__reduceat_percentile__",
                           rb_ca_reduceat_percentile, 3);
  rb_define_private_method(rb_cCArray, "__reduceat_variance__",
                           rb_ca_reduceat_variance, 4);
  rb_define_private_method(rb_cCArray, "__reduceat_prod__",
                           rb_ca_reduceat_prod, 2);
  rb_define_private_method(rb_cCArray, "__reduceat_argminmax__",
                           rb_ca_reduceat_argminmax, 3);
  rb_define_private_method(rb_cCArray, "__reduceat_all_any__",
                           rb_ca_reduceat_all_any, 3);
  rb_define_private_method(rb_cCArray, "__reduceat_quantile__",
                           rb_ca_reduceat_quantile, 6);
  rb_define_private_method(rb_cCArray, "__reduceat_wsum_wmean__",
                           rb_ca_reduceat_wsum_wmean, 4);
}
