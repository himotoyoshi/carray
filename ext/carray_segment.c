/* ---------------------------------------------------------------------------

  carray_segment.c

  Conversions between the representations of a flat sequence cut into
  consecutive segments:

    lengths   [2, 0, 3]          one count per segment (k)
    offsets   [0, 2, 2, 5]       every boundary, first and last included (k+1)
    segment index [0, 0, 2, 2, 2]  the segment each element belongs to (n)

    CArray.segment_offsets(lengths: l)   lengths -> offsets
    CArray.segment_index(lengths: l)     lengths -> segment index
    CArray.segment_index(offsets: o)     offsets -> segment index

  Everything is computed in int64, so a total beyond 2**53 stays exact
  (a cumsum would go through float64).  Offsets need not start at 0: the
  offsets of rows a..b cut out of a longer table start at offsets[a], and
  the segment index then covers offsets[0]...offsets[-1] with the segments
  numbered from 0.

  Inputs are read through ca_copy_data straight into an int64 array that
  Ruby already owns, so a refusal after reading leaks nothing.

--------------------------------------------------------------------------- */

#include "carray.h"

static ID id_lengths, id_offsets;

/* Read `v` (any integer or boolean CArray, or an Array of Integers) as
   int64 into a fresh Ruby-owned array of `pad_front + v.elements`
   elements, starting after `pad_front` cells.  Refuses a non-integer
   data type and masked cells, since neither names a count or a
   position. */
static VALUE
segment_read_int64 (VALUE v, const char *name, int is_lengths,
                    ca_size_t pad_front, CArray **out_ca, ca_size_t *out_k)
{
  CArray *src, *dst;
  VALUE rsrc, rdst;
  ca_size_t k;
  const char *role = is_lengths ? "lengths" : "offsets";

  if ( TYPE(v) == T_ARRAY ) {
    long i;
    for (i = 0; i < RARRAY_LEN(v); i++) {
      if ( ! RB_INTEGER_TYPE_P(RARRAY_AREF(v, i)) ) {
        rb_raise(rb_eArgError, "%s: %s must be integers", name, role);
      }
    }
  }
  else if ( ! rb_obj_is_carray(v) ) {
    rb_raise(rb_eTypeError, "%s: %s must be a CArray or an Array of Integers",
             name, role);
  }
  else {
    GetCArray(v, src);
    if ( ! ca_is_integer_type(src) && src->data_type != CA_BOOLEAN ) {
      rb_raise(rb_eCADataTypeError, "%s: %s must be integers (got %s)",
               name, role, ca_type_name[src->data_type]);
    }
    if ( ca_has_mask(src) &&
         NUM2LL(rb_funcall(v, rb_intern("count_masked"), 0)) > 0 ) {
      rb_raise(rb_eArgError, is_lengths ? "%s: a masked length is not a count"
                                        : "%s: a masked offset is not a position",
               name);
    }
  }

  rsrc = rb_ca_wrap_readonly(v, INT2NUM(CA_INT64));
  GetCArray(rsrc, src);
  k = src->elements;
  {
    ca_size_t dim[1];
    dim[0] = pad_front + k;
    rdst = rb_carray_new(CA_INT64, 1, dim, 0, NULL);
  }
  GetCArray(rdst, dst);
  if ( k > 0 ) {
    ca_copy_data(src, dst->ptr + pad_front * sizeof(int64_t));
  }
  RB_GC_GUARD(rsrc);
  *out_ca = dst;
  *out_k  = k;
  return rdst;
}

/* Turn a lengths array read into o[1..k] into offsets in place, o[0] = 0. */
static void
segment_prefix_sum (int64_t *o, ca_size_t k, const char *name)
{
  int64_t s = 0;
  ca_size_t c;
  o[0] = 0;
  for (c = 1; c <= k; c++) {
    int64_t l = o[c];
    if ( l < 0 ) {
      rb_raise(rb_eArgError, "%s: lengths must not be negative (got %lld at %lld)",
               name, (long long) l, (long long) (c - 1));
    }
    if ( s > INT64_MAX - l ) {
      rb_raise(rb_eRangeError, "%s: the total length overflows int64", name);
    }
    s += l;
    o[c] = s;
  }
}

/* Parse the one role keyword.  Returns the value and sets *is_lengths. */
static VALUE
segment_role (int argc, VALUE *argv, const char *name, int allow_offsets,
              int *is_lengths)
{
  VALUE opts, vals[2];
  ID ids[2];
  int nids;

  rb_scan_args(argc, argv, ":", &opts);
  ids[0] = id_lengths;
  ids[1] = id_offsets;
  nids = allow_offsets ? 2 : 1;
  vals[0] = vals[1] = Qundef;
  rb_get_kwargs(opts, ids, 0, nids, vals);

  if ( vals[0] != Qundef && nids == 2 && vals[1] != Qundef ) {
    rb_raise(rb_eArgError, "%s: give lengths: or offsets:, not both", name);
  }
  if ( vals[0] != Qundef ) {
    *is_lengths = 1;
    return vals[0];
  }
  if ( nids == 2 && vals[1] != Qundef ) {
    *is_lengths = 0;
    return vals[1];
  }
  rb_raise(rb_eArgError, allow_offsets ? "%s: lengths: or offsets: is required"
                                       : "%s: lengths: is required", name);
  return Qnil;
}

/* CArray.segment_offsets(lengths: l) -> int64[k+1] */
static VALUE
rb_ca_s_segment_offsets (int argc, VALUE *argv, VALUE klass)
{
  const char *name = "segment_offsets";
  int is_lengths;
  VALUE v, ro;
  CArray *co;
  ca_size_t k;

  v  = segment_role(argc, argv, name, 0, &is_lengths);
  ro = segment_read_int64(v, name, 1, 1, &co, &k);
  segment_prefix_sum((int64_t *) co->ptr, k, name);
  return ro;
}

/* CArray.segment_index(lengths: l)  -> int64[l.sum]
   CArray.segment_index(offsets: o)  -> int64[o[-1] - o[0]] */
static VALUE
rb_ca_s_segment_index (int argc, VALUE *argv, VALUE klass)
{
  const char *name = "segment_index";
  int is_lengths;
  VALUE v, ro, rout;
  CArray *co, *cout;
  ca_size_t k, c;
  int64_t *o, *q, base, total;

  v = segment_role(argc, argv, name, 1, &is_lengths);

  if ( is_lengths ) {
    ro = segment_read_int64(v, name, 1, 1, &co, &k);
    o  = (int64_t *) co->ptr;
    segment_prefix_sum(o, k, name);
  }
  else {
    ro = segment_read_int64(v, name, 0, 0, &co, &k);
    if ( k == 0 ) {
      rb_raise(rb_eArgError,
               "%s: offsets need at least one element (the start of the first segment)",
               name);
    }
    o = (int64_t *) co->ptr;
    for (c = 1; c < k; c++) {
      if ( o[c] < o[c-1] ) {
        rb_raise(rb_eArgError,
                 "%s: offsets must not decrease (%lld after %lld at %lld)",
                 name, (long long) o[c], (long long) o[c-1], (long long) c);
      }
    }
    k -= 1;                              /* k+1 boundaries -> k segments */
  }

  base  = o[0];
  total = o[k] - base;
  {
    ca_size_t dim[1];
    dim[0] = (ca_size_t) total;
    rout = rb_carray_new(CA_INT64, 1, dim, 0, NULL);
  }
  GetCArray(rout, cout);
  q = (int64_t *) cout->ptr;
  for (c = 0; c < k; c++) {
    int64_t p = o[c] - base, e = o[c+1] - base;
    for (; p < e; p++) {
      q[p] = (int64_t) c;
    }
  }
  RB_GC_GUARD(ro);
  return rout;
}

void
Init_carray_segment (void)
{
  id_lengths = rb_intern("lengths");
  id_offsets = rb_intern("offsets");
  rb_define_singleton_method(rb_cCArray, "segment_offsets", rb_ca_s_segment_offsets, -1);
  rb_define_singleton_method(rb_cCArray, "segment_index",   rb_ca_s_segment_index,   -1);
}
