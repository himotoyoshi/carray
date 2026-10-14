/* ---------------------------------------------------------------------------

  Key windows: the rows each row's window holds when the window is bounded by
  a width of a key (a time or a number) rather than by a count of cells.
  Backing primitive for `windows(on:)` (lib/carray/key_windows.rb).

  The Ruby side sorts the rows by (group, key), drops the rows whose key or
  group is masked, and hands the sorted keys and group codes here.  One walk
  with two pointers gives each row the range [lo, hi) of sorted positions in
  its window: within a group the key does not decrease, so both bounds of the
  window only move forward.

---------------------------------------------------------------------------- */

#include <stdint.h>
#include <math.h>
#include "ruby.h"
#include "carray.h"

/* Whether key k lies inside the window of an anchor t:
     lower bound t - before, upper bound t + after,
     each bound excluded when the matching flag is set. */
#define KW_ABOVE_LOWER(k, lo_b, ex_lo)  ((ex_lo) ? ((k) > (lo_b)) : ((k) >= (lo_b)))
#define KW_BELOW_UPPER(k, hi_b, ex_hi)  ((ex_hi) ? ((k) < (hi_b)) : ((k) <= (hi_b)))

/* The walk, written once for an int64 key and once for a float64 key.  ON_GRID
   tells whether key k lies on the interval grid that starts at anchor t.
   BOUNDS sets lo_b and hi_b, and lo_open / hi_open when a bound lies beyond
   the range of T, so that every key of the group is inside it. */
#define KW_WALK(T, ON_GRID, BOUNDS)                                           \
  {                                                                           \
    const T *key = (const T *) ck->ptr;                                       \
    const T before = (T) vbefore, after = (T) vafter, iv = (T) viv;           \
    ca_size_t lo = 0, hi = 0, gstart = 0;                                     \
    for (ca_size_t i = 0; i < n; i++) {                                       \
      if ( i > 0 && grp[i] != grp[i-1] ) {                                    \
        gstart = i; lo = i; hi = i;                                           \
      }                                                                       \
      else if ( i > 0 && key[i] < key[i-1] ) {                                \
        rb_raise(rb_eArgError,                                                \
                 "windows: the keys are not sorted within a group");          \
      }                                                                       \
      if ( lo < gstart ) lo = gstart;                                         \
      if ( hi < lo ) hi = lo;                                                 \
      const T t = key[i];                                                     \
      T lo_b, hi_b;                                                           \
      int lo_open, hi_open;                                                   \
      BOUNDS;                                                                 \
      while ( lo < n && grp[lo] == grp[i] && !lo_open &&                      \
              !KW_ABOVE_LOWER(key[lo], lo_b, ex_lo) ) lo++;                   \
      if ( hi < lo ) hi = lo;                                                 \
      while ( hi < n && grp[hi] == grp[i] &&                                  \
              ( hi_open || KW_BELOW_UPPER(key[hi], hi_b, ex_hi) ) ) hi++;     \
      plo[i] = lo;                                                            \
      phi[i] = hi;                                                            \
      if ( pcomplete ) {                                                      \
        int64_t distinct = 0;                                                 \
        int ok = 1;                                                           \
        for (ca_size_t j = lo; j < hi; j++) {                                 \
          const T k = key[j];                                                 \
          if ( j == lo || k != key[j-1] ) distinct++;                         \
          if ( !(ON_GRID) ) { ok = 0; break; }                                \
        }                                                                     \
        pcomplete[i] = ( ok && distinct == nexp ) ? 1 : 0;                    \
      }                                                                       \
    }                                                                         \
  }

/* CArray.__find_key_window_row_ranges__(keys, groups, before, after,
                                exclude_lower, exclude_upper,
                                interval, expected)
   keys:     int64 or float64 entity, sorted within each group
   groups:   int64 entity, the group code of each row (rows of a group adjacent)
   interval: nil, or the grid step for the completeness test
   expected: the number of grid points a complete window holds
   Returns [lo, hi, complete]: int64 positions into the sorted rows, and a
   boolean array (nil when no interval was given). */
static VALUE
rb_ca_s_key_window_ranges (VALUE self, VALUE vkeys, VALUE vgroups,
                           VALUE rbefore, VALUE rafter,
                           VALUE rex_lo, VALUE rex_hi,
                           VALUE rinterval, VALUE rexpected)
{
  CArray *ck, *cg, *clo, *chi, *cc = NULL;
  volatile VALUE vlo, vhi, vcomplete = Qnil;
  ca_size_t n;
  int64_t *plo, *phi;
  boolean8_t *pcomplete = NULL;
  int ex_lo = RTEST(rex_lo), ex_hi = RTEST(rex_hi);
  int64_t nexp = 0;
  const int64_t *grp;

  if ( !rb_obj_is_kind_of(vkeys, rb_cCArray) ||
       !rb_obj_is_kind_of(vgroups, rb_cCArray) ) {
    rb_raise(rb_eTypeError, "__find_key_window_row_ranges__: CArray arguments expected");
  }
  GetCArray(vkeys, ck);
  GetCArray(vgroups, cg);
  if ( ck->obj_type != CA_OBJ_ARRAY || cg->obj_type != CA_OBJ_ARRAY ||
       ck->ndim != 1 || cg->ndim != 1 || cg->data_type != CA_INT64 ||
       ck->elements != cg->elements || ca_has_mask(ck) || ca_has_mask(cg) ||
       ( ck->data_type != CA_INT64 && ck->data_type != CA_FLOAT64 ) ) {
    rb_raise(rb_eArgError, "__find_key_window_row_ranges__: unexpected arguments");
  }
  n = ck->elements;
  grp = (const int64_t *) cg->ptr;

  vlo = rb_carray_new(CA_INT64, 1, &n, 0, NULL);
  vhi = rb_carray_new(CA_INT64, 1, &n, 0, NULL);
  GetCArray(vlo, clo);
  GetCArray(vhi, chi);
  plo = (int64_t *) clo->ptr;
  phi = (int64_t *) chi->ptr;
  if ( !NIL_P(rinterval) ) {
    vcomplete = rb_carray_new(CA_BOOLEAN, 1, &n, 0, NULL);
    GetCArray(vcomplete, cc);
    pcomplete = (boolean8_t *) cc->ptr;
    nexp = NUM2LL(rexpected);
  }

  if ( ck->data_type == CA_INT64 ) {
    int64_t vbefore = NUM2LL(rbefore), vafter = NUM2LL(rafter);
    int64_t viv = NIL_P(rinterval) ? 1 : NUM2LL(rinterval);
    int64_t d;
    /* before and after are not negative, so an overflow of t - before is
       below every key and one of t + after above every key.  A difference
       k - t that overflows is not taken as on the grid. */
    KW_WALK(int64_t,
            (!__builtin_sub_overflow(k, t, &d) && d % iv == 0),
            (lo_open = __builtin_sub_overflow(t, before, &lo_b),
             hi_open = __builtin_add_overflow(t, after, &hi_b)))
  }
  else {
    double vbefore = NUM2DBL(rbefore), vafter = NUM2DBL(rafter);
    double viv = NIL_P(rinterval) ? 1.0 : NUM2DBL(rinterval);
    KW_WALK(double, (fabs((k - t) / iv - nearbyint((k - t) / iv)) <=
                     1e-9 * fmax(1.0, fabs((k - t) / iv))),
            (lo_b = t - before, hi_b = t + after, lo_open = 0, hi_open = 0))
  }

  return rb_ary_new3(3, vlo, vhi, vcomplete);
}

void
Init_carray_key_windows (void)
{
  rb_define_singleton_method(rb_cCArray, "__find_key_window_row_ranges__",
                             rb_ca_s_key_window_ranges, 8);
}
