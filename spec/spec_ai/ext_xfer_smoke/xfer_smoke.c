/* ---------------------------------------------------------------------------
 *
 *  xfer_smoke.c -- xfer reform dispatcher parity + bench surface
 *
 *  Test-only ext under spec_ai/ext_xfer_smoke/.  Provides byte-level
 *  parity smoke (new ca_xfer_X vs legacy ca_fetch_X / ca_store_X) and
 *  bench helpers for spec_ai / devel/bench.  Lives outside ext/ so the
 *  main carray_ext.bundle stays free of test instrumentation.
 *
 *  Built only when running tests / benches:
 *    rake build_xfer_smoke
 *
 *  --------------------------------------------------------------------------- */

#include "carray.h"

/* PROPOSAL_XFER_PROTOCOL step 1 smoke: verify ca_xfer_index matches the legacy
   ca_fetch_index / ca_store_index for every cell.  Returns the number of
   mismatches (0 = parity). */
static VALUE
rb_ca_xfer_index_smoke (VALUE self, VALUE rca)
{
  CArray   *ca;
  ca_size_t addr, mism = 0;
  ca_size_t idx[CA_RANK_MAX];
  char     *ref, *got, *after;

  (void) self;
  GetCArray(rca, ca);

  ref   = ALLOC_N(char, ca->bytes);
  got   = ALLOC_N(char, ca->bytes);
  after = ALLOC_N(char, ca->bytes);

  for ( addr = 0; addr < ca->elements; addr++ ) {
    ca_addr2index(ca, addr, idx);

    /* GET parity: ca_xfer_index(GET) == ca_fetch_index */
    ca_fetch_index(ca, idx, ref);
    ca_xfer_index(ca, idx, got, CA_XFER_GET);
    if ( memcmp(ref, got, ca->bytes) != 0 ) {
      mism++;
    }

    /* PUT round-trip identity (writable only): writing the fetched value back
       via xfer_index must leave the cell unchanged. */
    if ( ! ca_is_readonly(ca) ) {
      ca_xfer_index(ca, idx, ref, CA_XFER_PUT);
      ca_fetch_index(ca, idx, after);
      if ( memcmp(ref, after, ca->bytes) != 0 ) {
        mism++;
      }
    }
  }

  xfree(ref);
  xfree(got);
  xfree(after);

  return LL2NUM(mism);
}

/* PROPOSAL_XFER_PROTOCOL step 2 smoke: verify ca_xfer_addrs matches per-element
   ca_fetch_addr over a full address list, plus PUT round-trip identity.
   Returns the number of mismatches (0 = parity). */
static VALUE
rb_ca_xfer_addrs_smoke (VALUE self, VALUE rca)
{
  CArray    *ca;
  ca_size_t  n, i, mism = 0;
  ca_size_t *addrs;
  char      *buf, *ref;

  (void) self;
  GetCArray(rca, ca);
  n = ca->elements;
  if ( n == 0 ) {
    return LL2NUM(0);
  }

  addrs = ALLOC_N(ca_size_t, n);
  for ( i = 0; i < n; i++ ) {
    addrs[i] = i;
  }
  buf = ALLOC_N(char, n * ca->bytes);
  ref = ALLOC_N(char, ca->bytes);

  ca_xfer_addrs(ca, n, addrs, buf, CA_XFER_GET);
  for ( i = 0; i < n; i++ ) {
    ca_fetch_addr(ca, i, ref);
    if ( memcmp(buf + i * ca->bytes, ref, ca->bytes) != 0 ) {
      mism++;
    }
  }

  if ( ! ca_is_readonly(ca) ) {
    ca_xfer_addrs(ca, n, addrs, buf, CA_XFER_PUT);
    for ( i = 0; i < n; i++ ) {
      ca_fetch_addr(ca, i, ref);
      if ( memcmp(buf + i * ca->bytes, ref, ca->bytes) != 0 ) {
        mism++;
      }
    }
  }

  xfree(addrs);
  xfree(buf);
  xfree(ref);
  return LL2NUM(mism);
}

/* xfer_stride smoke (semantics b): two passes validate that the SRC access
   strides are honoured (identity + reversed axis 0).  Returns mismatch count. */
static VALUE
rb_ca_xfer_stride_smoke (VALUE self, VALUE rca)
{
  CArray    *ca;
  ca_size_t  starts[CA_RANK_MAX], counts[CA_RANK_MAX], strides[CA_RANK_MAX];
  ca_size_t  native[CA_RANK_MAX];
  ca_size_t  n, i, s, mism = 0;
  char      *buf, *ref;
  int8_t     k;

  (void) self;
  GetCArray(rca, ca);
  n = ca->elements;
  if ( n == 0 ) {
    return LL2NUM(0);
  }

  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    native[k]  = s;
    starts[k]  = 0;
    counts[k]  = ca->dim[k];
    strides[k] = s;
    s *= ca->dim[k];
  }

  buf = ALLOC_N(char, n * ca->bytes);
  ref = ALLOC_N(char, ca->bytes);

  /* Pass 1: identity */
  ca_xfer_stride(ca, starts, counts, strides, buf, CA_XFER_GET);
  for ( i = 0; i < n; i++ ) {
    ca_fetch_addr(ca, i, ref);
    if ( memcmp(buf + i * ca->bytes, ref, ca->bytes) != 0 ) mism++;
  }
  if ( ! ca_is_readonly(ca) ) {
    ca_xfer_stride(ca, starts, counts, strides, buf, CA_XFER_PUT);
    for ( i = 0; i < n; i++ ) {
      ca_fetch_addr(ca, i, ref);
      if ( memcmp(buf + i * ca->bytes, ref, ca->bytes) != 0 ) mism++;
    }
  }

  /* Pass 2: reversed axis 0 (non-native access stride) */
  if ( ca->dim[0] >= 1 ) {
    ca_size_t idx[CA_RANK_MAX];
    starts[0]  = ca->dim[0] - 1;
    strides[0] = -native[0];
    ca_xfer_stride(ca, starts, counts, strides, buf, CA_XFER_GET);
    for ( k = 0; k < ca->ndim; k++ ) idx[k] = 0;
    for ( i = 0; i < n; i++ ) {
      ca_size_t vidx[CA_RANK_MAX];
      for ( k = 0; k < ca->ndim; k++ ) vidx[k] = idx[k];
      vidx[0] = ca->dim[0] - 1 - idx[0];
      ca_fetch_index(ca, vidx, ref);
      if ( memcmp(buf + i * ca->bytes, ref, ca->bytes) != 0 ) mism++;
      k = ca->ndim - 1;
      while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
    }
  }

  xfree(buf);
  xfree(ref);
  return LL2NUM(mism);
}

/* Bench: ca_xfer_all(GET) timing primitive. */
static VALUE
rb_ca_bench_xfer_all_get (VALUE self, VALUE rca, VALUE rn)
{
  CArray   *ca;
  ca_size_t i, n_iter = NUM2SIZET(rn);
  char     *buf;
  VALUE     result;
  (void) self;
  GetCArray(rca, ca);
  if ( ca->elements == 0 ) return rb_str_new("", 0);
  buf = ALLOC_N(char, ca->elements * ca->bytes);
  for ( i = 0; i < n_iter; i++ ) {
    ca_xfer_all(ca, buf, CA_XFER_GET);
  }
  result = rb_str_new(buf, ca->elements * ca->bytes);
  xfree(buf);
  return result;
}

/* Bench: ca_xfer_stride(whole-view, GET) timing primitive. */
static VALUE
rb_ca_bench_xfer_stride_get (VALUE self, VALUE rca, VALUE rn)
{
  CArray   *ca;
  ca_size_t starts[CA_RANK_MAX], counts[CA_RANK_MAX], strides[CA_RANK_MAX];
  ca_size_t s, i, n_iter = NUM2SIZET(rn);
  int8_t    k;
  char     *buf;
  VALUE     result;
  (void) self;
  GetCArray(rca, ca);
  if ( ca->elements == 0 ) return rb_str_new("", 0);
  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    starts[k]  = 0;
    counts[k]  = ca->dim[k];
    strides[k] = s;
    s *= ca->dim[k];
  }
  buf = ALLOC_N(char, ca->elements * ca->bytes);
  for ( i = 0; i < n_iter; i++ ) {
    ca_xfer_stride(ca, starts, counts, strides, buf, CA_XFER_GET);
  }
  result = rb_str_new(buf, ca->elements * ca->bytes);
  xfree(buf);
  return result;
}

/* Bench: sub-region ca_xfer_stride(GET) timing primitive. */
static VALUE
rb_ca_bench_xfer_stride_subregion_get (VALUE self, VALUE rca, VALUE rstarts,
                                       VALUE rcounts, VALUE rn)
{
  CArray   *ca;
  ca_size_t starts[CA_RANK_MAX], counts[CA_RANK_MAX], strides[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  ca_size_t s, n_cells = 1, i, n_iter = NUM2SIZET(rn);
  int8_t    k;
  char     *buf;
  VALUE     result;

  (void) self;
  GetCArray(rca, ca);
  if ( RARRAY_LEN(rstarts) != ca->ndim || RARRAY_LEN(rcounts) != ca->ndim ) {
    rb_raise(rb_eArgError, "starts/counts length must equal ca.ndim");
  }
  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) {
    starts[k] = NUM2SIZET(rb_ary_entry(rstarts, k));
    counts[k] = NUM2SIZET(rb_ary_entry(rcounts, k));
    n_cells *= counts[k];
  }
  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { strides[k] = s; s *= ca->dim[k]; }

  if ( n_cells == 0 ) return rb_str_new("", 0);

  buf = ALLOC_N(char, n_cells * ca->bytes);
  for ( i = 0; i < n_iter; i++ ) {
    ca_xfer_stride(ca, starts, counts, strides, buf, CA_XFER_GET);
  }
  result = rb_str_new(buf, n_cells * ca->bytes);
  xfree(buf);
  return result;
}

/* Region GET with caller-supplied strides (given in CELLS, scaled to bytes
   here).  The xfer_stride request is expressed over the view's linear
   addresses, so a caller may hand over a region whose axes are not the
   view's own -- a column-major (transposed) gather, say, which is what a
   Fortran-LAPACK backend asks for.  This entry exists so specs can issue
   exactly that request; the natural-stride entries above cannot. */
static VALUE
rb_ca_bench_xfer_stride_region_get (VALUE self, VALUE rca, VALUE rstarts,
                                    VALUE rcounts, VALUE rstrides)
{
  CArray   *ca;
  ca_size_t starts[CA_RANK_MAX], counts[CA_RANK_MAX], strides[CA_RANK_MAX];
  ca_size_t n_cells = 1;
  int8_t    k;
  char     *buf;
  VALUE     result;

  (void) self;
  GetCArray(rca, ca);
  if ( RARRAY_LEN(rstarts)  != ca->ndim ||
       RARRAY_LEN(rcounts)  != ca->ndim ||
       RARRAY_LEN(rstrides) != ca->ndim ) {
    rb_raise(rb_eArgError, "starts/counts/strides length must equal ca.ndim");
  }
  for ( k = 0; k < ca->ndim; k++ ) {
    starts[k]  = NUM2SIZET(rb_ary_entry(rstarts, k));
    counts[k]  = NUM2SIZET(rb_ary_entry(rcounts, k));
    strides[k] = NUM2SIZET(rb_ary_entry(rstrides, k)) * ca->bytes;
    n_cells   *= counts[k];
  }
  if ( n_cells == 0 ) return rb_str_new("", 0);

  buf = ALLOC_N(char, n_cells * ca->bytes);
  ca_xfer_stride(ca, starts, counts, strides, buf, CA_XFER_GET);
  result = rb_str_new(buf, n_cells * ca->bytes);
  xfree(buf);
  return result;
}

/* Bench: ca_xfer_addrs(whole-view, GET) timing primitive. */
static VALUE
rb_ca_bench_xfer_addrs_get (VALUE self, VALUE rca, VALUE rn)
{
  CArray   *ca;
  ca_size_t i, n_iter = NUM2SIZET(rn);
  ca_size_t *addrs;
  char     *buf;
  VALUE     result;
  volatile VALUE holder;
  (void) self;
  GetCArray(rca, ca);
  if ( ca->elements == 0 ) return rb_str_new("", 0);
  addrs = ALLOCV_N(ca_size_t, holder, ca->elements);
  for ( i = 0; i < ca->elements; i++ ) addrs[i] = i;
  buf = ALLOC_N(char, ca->elements * ca->bytes);
  for ( i = 0; i < n_iter; i++ ) {
    ca_xfer_addrs(ca, ca->elements, addrs, buf, CA_XFER_GET);
  }
  result = rb_str_new(buf, ca->elements * ca->bytes);
  xfree(buf);
  ALLOCV_END(holder);
  return result;
}

/* Y.2: ca_xfer_addrs GET with caller-supplied addr list, n_iter times. */
static VALUE
rb_ca_bench_xfer_addrs_get_addrs (VALUE self, VALUE rca, VALUE rb_addrs,
                                  VALUE rn)
{
  CArray   *ca;
  ca_size_t i, n_iter = NUM2SIZET(rn);
  ca_size_t n_addrs;
  ca_size_t *addrs;
  char     *buf;
  VALUE     result;
  volatile VALUE holder;
  (void) self;
  GetCArray(rca, ca);
  Check_Type(rb_addrs, T_ARRAY);
  n_addrs = (ca_size_t) RARRAY_LEN(rb_addrs);
  if ( n_addrs == 0 ) return rb_str_new("", 0);
  addrs = ALLOCV_N(ca_size_t, holder, n_addrs);
  for ( i = 0; i < n_addrs; i++ ) addrs[i] = NUM2SIZET(rb_ary_entry(rb_addrs, i));
  buf = ALLOC_N(char, n_addrs * ca->bytes);
  for ( i = 0; i < n_iter; i++ ) {
    ca_xfer_addrs(ca, n_addrs, addrs, buf, CA_XFER_GET);
  }
  result = rb_str_new(buf, n_addrs * ca->bytes);
  xfree(buf);
  ALLOCV_END(holder);
  return result;
}

/* Y.2 PUT counterpart: write caller-supplied data buffer to addrs locations. */
static VALUE
rb_ca_bench_xfer_addrs_put_addrs (VALUE self, VALUE rca, VALUE rb_addrs,
                                  VALUE rdata)
{
  CArray   *ca;
  ca_size_t i, n_addrs;
  ca_size_t *addrs;
  const char *src;
  volatile VALUE holder;
  (void) self;
  GetCArray(rca, ca);
  Check_Type(rb_addrs, T_ARRAY);
  StringValue(rdata);
  n_addrs = (ca_size_t) RARRAY_LEN(rb_addrs);
  if ( (ca_size_t) RSTRING_LEN(rdata) != n_addrs * ca->bytes ) {
    rb_raise(rb_eArgError, "data size mismatch");
  }
  if ( n_addrs == 0 ) return Qnil;
  addrs = ALLOCV_N(ca_size_t, holder, n_addrs);
  for ( i = 0; i < n_addrs; i++ ) addrs[i] = NUM2SIZET(rb_ary_entry(rb_addrs, i));
  src = RSTRING_PTR(rdata);
  ca_xfer_addrs(ca, n_addrs, addrs, (void *) src, CA_XFER_PUT);
  ALLOCV_END(holder);
  return Qnil;
}

void
Init_xfer_smoke (void)
{
  rb_define_singleton_method(rb_cCArray, "xfer_index_smoke",
                             rb_ca_xfer_index_smoke, 1);
  rb_define_singleton_method(rb_cCArray, "xfer_addrs_smoke",
                             rb_ca_xfer_addrs_smoke, 1);
  rb_define_singleton_method(rb_cCArray, "xfer_stride_smoke",
                             rb_ca_xfer_stride_smoke, 1);
  rb_define_singleton_method(rb_cCArray, "bench_xfer_all_get",
                             rb_ca_bench_xfer_all_get, 2);
  rb_define_singleton_method(rb_cCArray, "bench_xfer_stride_get",
                             rb_ca_bench_xfer_stride_get, 2);
  rb_define_singleton_method(rb_cCArray, "bench_xfer_stride_subregion_get",
                             rb_ca_bench_xfer_stride_subregion_get, 4);
  rb_define_singleton_method(rb_cCArray, "bench_xfer_stride_region_get",
                             rb_ca_bench_xfer_stride_region_get, 4);
  rb_define_singleton_method(rb_cCArray, "bench_xfer_addrs_get",
                             rb_ca_bench_xfer_addrs_get, 2);
  rb_define_singleton_method(rb_cCArray, "bench_xfer_addrs_get_addrs",
                             rb_ca_bench_xfer_addrs_get_addrs, 3);
  rb_define_singleton_method(rb_cCArray, "bench_xfer_addrs_put_addrs",
                             rb_ca_bench_xfer_addrs_put_addrs, 3);
}
