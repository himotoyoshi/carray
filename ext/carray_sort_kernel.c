/* ---------------------------------------------------------------------------

   Portable textbook sort kernels: per-type quicksort + bottom-up
   mergesort with inline comparison (no function-pointer indirection
   like libc qsort / mergesort).  All 10 numeric data types plus paired
   forms for argsort.

   Internal C API only (no Ruby surface, no Init function).  Declared
   in ca_sort_kernels.h.  Callers: rb_ca_sort_copy (carray_sort.c),
   rb_ca_partition_copy_c (carray_partition.c), and the mkkernel-
   emitted sort_addr_ki kernels in carray_kernels.c.

   Algorithms:

   * quicksort (ca_sort_quick_<type>)
       median-of-3 pivot, Hoare partition, strict `<`, insertion-sort
       base (threshold 16), smaller-side recursion / larger-side
       iterate (stack O(log n)).  Depth-limit escape to mergesort for
       worst-case O(n log n).

   * mergesort (ca_sort_merge_<type>)
       Bottom-up, ping-pong (cur / next) per pass with no inter-pass
       memcpy.  Strict `<` (stable: equal -> take-left).  Insertion-
       sort pre-pass that converts the input into R=16-wide sorted
       blocks before the merge loop.  Single-compare sorted-skip
       (per-merge `!(cur[mid] < cur[mid-1])` test, true -> memcpy and
       skip the merge loop; no run-state machine, distinct from
       Timsort galloping).

   * paired forms (ca_sort_quick_pair_<type> / ca_sort_merge_pair_<type>)
       Same algorithms over (value, index) pairs for argsort
       (sort_index / sort_addr).  Stable tie-break by index is built
       into the comparison, so quicksort is effectively stable for
       argsort even though the algorithm itself is not.

   * NaN partitioning (ca_partition_nan_<type> + _pair_<type>)
       float32 / float64 only.  One-pass Hoare-style partition that
       separates `[finite | NaN]` regions so the downstream sort
       kernel can operate on the finite slice with plain `<`.

   * value-level quickselect (ca_partition_quick_<type>)
       median-of-3 + Hoare + insertion base + one-sided recursion
       into the side containing kth (quickselect property, expected
       O(n)).  Depth-limit escape to mergesort matches the sort
       kernels.

   ---------------------------------------------------------------------------*/

#include "carray.h"
#include "ca_sort_kernels.h"
#include <string.h>
#include <math.h>

#define CA_SORT_INSERTION_THRESHOLD 16

/* ---------------------------------------------------------------------------
   DEFINE_SORT_MERGE(TYPE, SUFFIX)

   Emits public `void ca_sort_merge_<SUFFIX>(TYPE *a, TYPE *aux,
                                             ca_size_t n)`.
   `aux` must be a caller-provided buffer of `n * sizeof(TYPE)` bytes.
   --------------------------------------------------------------------------- */

#define DEFINE_SORT_MERGE(TYPE, SUFFIX)                                     \
                                                                            \
/* insertion-sort pre-pass on a[lo..hi-1] (half-open).  R-wide blocks.    \
   Writes only into `a` (no buffer juggling).  Body is intentionally       \
   identical to the quicksort insertion base. */                           \
static void                                                                 \
ca_sort_merge_##SUFFIX##_inspass (TYPE *a, ca_size_t n)                     \
{                                                                           \
  ca_size_t lo = 0;                                                         \
  while ( lo < n ) {                                                        \
    ca_size_t hi_excl = lo + CA_SORT_INSERTION_THRESHOLD;                   \
    if ( hi_excl > n ) hi_excl = n;                                         \
    for ( ca_size_t k = lo + 1; k < hi_excl; k++ ) {                        \
      TYPE v = a[k];                                                        \
      ca_size_t m = k;                                                      \
      while ( m > lo && v < a[m - 1] ) {                                    \
        a[m] = a[m - 1];                                                    \
        m--;                                                                \
      }                                                                     \
      a[m] = v;                                                             \
    }                                                                       \
    lo = hi_excl;                                                           \
  }                                                                         \
}                                                                           \
                                                                            \
void                                                                        \
ca_sort_merge_##SUFFIX (TYPE *a, TYPE *aux, ca_size_t n)                    \
{                                                                           \
  if ( n <= 1 ) return;                                                     \
                                                                            \
  /* Pre-pass: convert a[] into R=16-wide sorted blocks in place. */        \
  ca_sort_merge_##SUFFIX##_inspass(a, n);                                   \
                                                                            \
  TYPE *cur  = a;                                                           \
  TYPE *next = aux;                                                         \
                                                                            \
  /* Start width = R (= pre-pass output run width). */                      \
  for ( ca_size_t width = CA_SORT_INSERTION_THRESHOLD;                      \
        width < n;                                                          \
        width <<= 1 ) {                                                     \
    for ( ca_size_t lo = 0; lo < n; lo += (width << 1) ) {                  \
      ca_size_t mid = lo + width;                                           \
      ca_size_t hi  = lo + (width << 1);                                    \
      /* CAREFUL: tail run clamp must run before the drain `while`          \
         loops below; without these the drains over-walk the buffer        \
         when n is not a power of 2 times width. */                        \
      if ( mid > n ) mid = n;                                               \
      if ( hi  > n ) hi  = n;                                               \
                                                                            \
      /* Single-compare sorted-skip: if left tail <= right head, the merge  \
         is the identity in [lo, hi).  Strict `<` here so equal heads also  \
         skip (stable: take-left).  Cheap memcpy keeps invariant that       \
         `next[lo..hi)` is the merged output. */                            \
      if ( mid < hi && !(cur[mid] < cur[mid - 1]) ) {                       \
        memcpy(next + lo, cur + lo, (size_t)(hi - lo) * sizeof(TYPE));      \
        continue;                                                           \
      }                                                                     \
                                                                            \
      ca_size_t i = lo, j = mid, k = lo;                                    \
      /* strict `<` -> equal-key left-take -> stable. */                    \
      while ( i < mid && j < hi ) {                                         \
        if ( cur[j] < cur[i] ) next[k++] = cur[j++];                        \
        else                   next[k++] = cur[i++];                        \
      }                                                                     \
      /* Drain residual tail (paired with the clamp above). */              \
      while ( i < mid ) next[k++] = cur[i++];                               \
      while ( j < hi  ) next[k++] = cur[j++];                               \
    }                                                                       \
    /* ping-pong: swap roles for next pass. */                              \
    { TYPE *t = cur; cur = next; next = t; }                                \
  }                                                                         \
                                                                            \
  /* CAREFUL: parity check by POINTER IDENTITY, never by pass counter.      \
     The pre-pass + width loop may leave `cur` pointing at either `a` or   \
     `aux` depending on dataset size and the sorted-skip short-circuit;    \
     a pass-count parity check is unreliable.  Single fix-up memcpy when  \
     the result landed in `aux`. */                                        \
  if ( cur != a ) {                                                         \
    memcpy(a, cur, (size_t) n * sizeof(TYPE));                              \
  }                                                                         \
}                                                                           \
struct ca_sort_merge_##SUFFIX##_eat_semicolon


/* ---------------------------------------------------------------------------
   DEFINE_SORT_QUICK(TYPE, SUFFIX)

   Emits public `void ca_sort_quick_<SUFFIX>(TYPE *a, ca_size_t n)`.
   Algorithm: median-of-3 pivot + Hoare partition + insertion-sort
   base (threshold 16) + smaller-side recursion / larger-side
   iterate (stack O(log n)).

   Worst-case guarantee: a recursion depth counter starts at
   2*floor(log2(n)) + 2.  Once a branch exceeds that limit the
   remaining subrange escapes to ca_sort_merge_<SUFFIX>, which is
   O(n log n) regardless of input shape (= avoids heapsort by
   reusing the existing merge path).
   --------------------------------------------------------------------- */

#define DEFINE_SORT_QUICK(TYPE, SUFFIX)                                     \
                                                                            \
static void                                                                 \
ca_sort_quick_##SUFFIX##_range (TYPE *a, ca_size_t lo, ca_size_t hi,        \
                                int depth_limit)                            \
{                                                                           \
  while ( hi - lo > CA_SORT_INSERTION_THRESHOLD ) {                         \
    if ( depth_limit <= 0 ) {                                               \
      /* Depth-limit escape: mergesort the remaining subrange.              \
         The surrounding quicksort loop has already partitioned the         \
         higher subranges, so only this [lo, hi] window needs the aux       \
         buffer (local malloc/free). */                                     \
      ca_size_t n_remain = hi - lo + 1;                                     \
      TYPE *aux = (TYPE *) xmalloc((size_t) n_remain * sizeof(TYPE));       \
      ca_sort_merge_##SUFFIX(a + lo, aux, n_remain);                        \
      xfree(aux);                                                           \
      return;                                                               \
    }                                                                       \
    depth_limit--;                                                          \
    ca_size_t mid = lo + (hi - lo) / 2;                                     \
    /* median-of-3: order a[lo] <= a[mid] <= a[hi] */                       \
    if ( a[mid] < a[lo]  ) { TYPE t = a[lo];  a[lo]  = a[mid]; a[mid] = t; } \
    if ( a[hi]  < a[lo]  ) { TYPE t = a[lo];  a[lo]  = a[hi];  a[hi]  = t; } \
    if ( a[hi]  < a[mid] ) { TYPE t = a[mid]; a[mid] = a[hi];  a[hi]  = t; } \
    TYPE pivot = a[mid];                                                    \
    /* Hoare partition */                                                   \
    ca_size_t i = lo, j = hi;                                               \
    for (;;) {                                                              \
      while ( a[i] < pivot ) i++;                                           \
      while ( pivot < a[j] ) j--;                                           \
      if ( i >= j ) break;                                                  \
      { TYPE t = a[i]; a[i] = a[j]; a[j] = t; }                             \
      i++;                                                                  \
      j--;                                                                  \
    }                                                                       \
    /* smaller side recurse, larger side iterate (stack O(log n)) */        \
    if ( j - lo < hi - (j + 1) ) {                                          \
      ca_sort_quick_##SUFFIX##_range(a, lo, j, depth_limit);                \
      lo = j + 1;                                                           \
    } else {                                                                \
      ca_sort_quick_##SUFFIX##_range(a, j + 1, hi, depth_limit);            \
      hi = j;                                                               \
    }                                                                       \
  }                                                                         \
  /* insertion-sort base case */                                            \
  for ( ca_size_t k = lo + 1; k <= hi; k++ ) {                              \
    TYPE v = a[k];                                                          \
    ca_size_t m = k;                                                        \
    while ( m > lo && v < a[m - 1] ) {                                      \
      a[m] = a[m - 1];                                                      \
      m--;                                                                  \
    }                                                                       \
    a[m] = v;                                                               \
  }                                                                         \
}                                                                           \
                                                                            \
void                                                                        \
ca_sort_quick_##SUFFIX (TYPE *a, ca_size_t n)                               \
{                                                                           \
  if ( n <= 1 ) return;                                                     \
  /* depth_limit = 2 * floor(log2(n)) + 2, computed via integer            \
     bit-length (cheap and exact for ca_size_t). */                        \
  int depth_limit = 0;                                                      \
  ca_size_t m = n;                                                          \
  while ( m > 0 ) { depth_limit++; m >>= 1; }                               \
  depth_limit *= 2;                                                         \
  ca_sort_quick_##SUFFIX##_range(a, 0, n - 1, depth_limit);                 \
}                                                                           \
struct ca_sort_quick_##SUFFIX##_eat_semicolon


/* ---------------------------------------------------------------------------
   PAIR sort macros (argsort kernels).

   The pair form sorts an array of (value, index) structs by value,
   used by sort_index / sort_addr to obtain the permutation.  Stable
   tie-break is built into the comparison (equal values fall through
   to compare indices), so quicksort is effectively stable for
   argsort even though the algorithm itself is not.

   Structurally identical to the scalar quick / merge macros above;
   the only differences are (a) pair struct typedef, (b) inline cmp
   that includes the index tie-break, (c) per-cell swap copies the
   whole pair via TYPE temp.

   Pair memory footprint: sizeof(TYPE) + sizeof(ca_size_t) (8 bytes
   alignment-padded).  Caller allocates N pairs once per fiber
   (mkkernel emit_sort_native in carray_kernels.c).
   --------------------------------------------------------------------- */

/* Pair struct typedefs live in carray.h so callers (mkkernel emit) can
   allocate them by name.  The macro below skips the typedef and only
   defines the algorithm. */
#define DEFINE_SORT_PAIR(TYPE, SUFFIX)                                      \
                                                                            \
/* ---- pair mergesort (= stable; called by quick escape too) ---- */       \
                                                                            \
static void                                                                 \
ca_sort_merge_pair_##SUFFIX##_inspass (ca_pair_##SUFFIX *a, ca_size_t n)    \
{                                                                           \
  ca_size_t lo = 0;                                                         \
  while ( lo < n ) {                                                        \
    ca_size_t hi_excl = lo + CA_SORT_INSERTION_THRESHOLD;                   \
    if ( hi_excl > n ) hi_excl = n;                                         \
    for ( ca_size_t k = lo + 1; k < hi_excl; k++ ) {                        \
      ca_pair_##SUFFIX v = a[k];                                            \
      ca_size_t m = k;                                                      \
      /* stable cmp: equal values keep ascending index (= left-take) */     \
      while ( m > lo &&                                                     \
              ( v.v < a[m - 1].v ||                                         \
                (!(a[m - 1].v < v.v) && v.i < a[m - 1].i) ) ) {             \
        a[m] = a[m - 1];                                                    \
        m--;                                                                \
      }                                                                     \
      a[m] = v;                                                             \
    }                                                                       \
    lo = hi_excl;                                                           \
  }                                                                         \
}                                                                           \
                                                                            \
void                                                                        \
ca_sort_merge_pair_##SUFFIX (ca_pair_##SUFFIX *a,                           \
                             ca_pair_##SUFFIX *aux,                         \
                             ca_size_t n)                                   \
{                                                                           \
  if ( n <= 1 ) return;                                                     \
  ca_sort_merge_pair_##SUFFIX##_inspass(a, n);                              \
  ca_pair_##SUFFIX *cur  = a;                                               \
  ca_pair_##SUFFIX *next = aux;                                             \
  for ( ca_size_t width = CA_SORT_INSERTION_THRESHOLD;                      \
        width < n;                                                          \
        width <<= 1 ) {                                                     \
    for ( ca_size_t lo = 0; lo < n; lo += (width << 1) ) {                  \
      ca_size_t mid = lo + width;                                           \
      ca_size_t hi  = lo + (width << 1);                                    \
      if ( mid > n ) mid = n;                                               \
      if ( hi  > n ) hi  = n;                                               \
      /* sorted-skip: left-tail <= right-head (stable cmp) */               \
      if ( mid < hi ) {                                                     \
        TYPE lt = cur[mid - 1].v;                                           \
        TYPE rh = cur[mid].v;                                               \
        ca_size_t li = cur[mid - 1].i;                                      \
        ca_size_t ri = cur[mid].i;                                          \
        int strict_left_smaller = (lt < rh) ||                              \
                                  (!(rh < lt) && li < ri);                  \
        int equal               = !(lt < rh) && !(rh < lt) && (li == ri);   \
        if ( strict_left_smaller || equal ) {                               \
          memcpy(next + lo, cur + lo,                                       \
                 (size_t)(hi - lo) * sizeof(ca_pair_##SUFFIX));             \
          continue;                                                         \
        }                                                                   \
      }                                                                     \
      ca_size_t i = lo, j = mid, k = lo;                                    \
      while ( i < mid && j < hi ) {                                         \
        /* stable: if cur[j] < cur[i] strictly, take j; else take i */      \
        int take_j = (cur[j].v < cur[i].v) ||                               \
                     (!(cur[i].v < cur[j].v) && cur[j].i < cur[i].i);       \
        if ( take_j ) next[k++] = cur[j++];                                 \
        else          next[k++] = cur[i++];                                 \
      }                                                                     \
      while ( i < mid ) next[k++] = cur[i++];                               \
      while ( j < hi  ) next[k++] = cur[j++];                               \
    }                                                                       \
    { ca_pair_##SUFFIX *t = cur; cur = next; next = t; }                    \
  }                                                                         \
  if ( cur != a ) {                                                         \
    memcpy(a, cur, (size_t) n * sizeof(ca_pair_##SUFFIX));                  \
  }                                                                         \
}                                                                           \
                                                                            \
/* ---- pair quicksort (= stable via index tie-break + depth-limit escape) ----*/ \
                                                                            \
static void                                                                 \
ca_sort_quick_pair_##SUFFIX##_range (ca_pair_##SUFFIX *a,                   \
                                     ca_size_t lo, ca_size_t hi,            \
                                     int depth_limit)                       \
{                                                                           \
  while ( hi - lo > CA_SORT_INSERTION_THRESHOLD ) {                         \
    if ( depth_limit <= 0 ) {                                               \
      ca_size_t n_remain = hi - lo + 1;                                     \
      ca_pair_##SUFFIX *aux =                                               \
        (ca_pair_##SUFFIX *) xmalloc((size_t) n_remain * sizeof(ca_pair_##SUFFIX)); \
      ca_sort_merge_pair_##SUFFIX(a + lo, aux, n_remain);                   \
      xfree(aux);                                                           \
      return;                                                               \
    }                                                                       \
    depth_limit--;                                                          \
    ca_size_t mid = lo + (hi - lo) / 2;                                     \
    /* median-of-3 by value (tie-break NOT applied here -- approximate      \
       median is fine; full stable cmp applies during partition). */        \
    if ( a[mid].v < a[lo].v )  { ca_pair_##SUFFIX t = a[lo];  a[lo]  = a[mid]; a[mid] = t; } \
    if ( a[hi].v  < a[lo].v )  { ca_pair_##SUFFIX t = a[lo];  a[lo]  = a[hi];  a[hi]  = t; } \
    if ( a[hi].v  < a[mid].v ) { ca_pair_##SUFFIX t = a[mid]; a[mid] = a[hi];  a[hi]  = t; } \
    TYPE      pivot_v = a[mid].v;                                           \
    ca_size_t pivot_i = a[mid].i;                                           \
    /* Hoare partition with stable cmp (= compare by v, tie-break by i). */ \
    ca_size_t i = lo, j = hi;                                               \
    for (;;) {                                                              \
      while ( a[i].v < pivot_v ||                                           \
              (!(pivot_v < a[i].v) && a[i].i < pivot_i) ) i++;              \
      while ( pivot_v < a[j].v ||                                           \
              (!(a[j].v < pivot_v) && pivot_i < a[j].i) ) j--;              \
      if ( i >= j ) break;                                                  \
      { ca_pair_##SUFFIX t = a[i]; a[i] = a[j]; a[j] = t; }                 \
      i++;                                                                  \
      j--;                                                                  \
    }                                                                       \
    if ( j - lo < hi - (j + 1) ) {                                          \
      ca_sort_quick_pair_##SUFFIX##_range(a, lo, j, depth_limit);           \
      lo = j + 1;                                                           \
    } else {                                                                \
      ca_sort_quick_pair_##SUFFIX##_range(a, j + 1, hi, depth_limit);       \
      hi = j;                                                               \
    }                                                                       \
  }                                                                         \
  /* insertion-sort base (stable cmp). */                                   \
  for ( ca_size_t k = lo + 1; k <= hi; k++ ) {                              \
    ca_pair_##SUFFIX v = a[k];                                              \
    ca_size_t m = k;                                                        \
    while ( m > lo &&                                                       \
            ( v.v < a[m - 1].v ||                                           \
              (!(a[m - 1].v < v.v) && v.i < a[m - 1].i) ) ) {               \
      a[m] = a[m - 1];                                                      \
      m--;                                                                  \
    }                                                                       \
    a[m] = v;                                                               \
  }                                                                         \
}                                                                           \
                                                                            \
void                                                                        \
ca_sort_quick_pair_##SUFFIX (ca_pair_##SUFFIX *a, ca_size_t n)              \
{                                                                           \
  if ( n <= 1 ) return;                                                     \
  int depth_limit = 0;                                                      \
  ca_size_t m = n;                                                          \
  while ( m > 0 ) { depth_limit++; m >>= 1; }                               \
  depth_limit *= 2;                                                         \
  ca_sort_quick_pair_##SUFFIX##_range(a, 0, n - 1, depth_limit);            \
}                                                                           \
struct ca_sort_pair_##SUFFIX##_eat_semicolon


/* ===== Per-type instantiations ===========================================
   `<` is well-defined and IEEE-stable for all numeric C types used
   here; NaN handling for f32 / f64 lives in the pre-partition pass
   below. */

/* ---------------------------------------------------------------------------
   NaN pre-partition (float data types only).

   One-pass Hoare-style partition that separates `a[0..n)` into
   `[finite | NaN]` regions in place, returning the finite count k
   (the NaN region starts at a[k..n)).  Unstable within the finite
   region (original order of finite values not preserved) -- the
   downstream sort kernel reorders them anyway.

   Loop invariant:
     - a[0 .. i) all finite
     - a[j .. n) all NaN
     - a[i .. j) unprocessed
   Terminates when i == j.

   `isnan(a[i])` is the only NaN-aware logic.  The downstream sort
   kernels treat the finite slice with plain `<`, which is well-
   defined and IEEE-stable for finite operands.
   --------------------------------------------------------------------------- */

#define DEFINE_PARTITION_NAN(TYPE, SUFFIX)                                 \
ca_size_t                                                                  \
ca_partition_nan_##SUFFIX (TYPE *a, ca_size_t n)                           \
{                                                                          \
  ca_size_t i = 0, j = n;                                                  \
  while ( i < j ) {                                                        \
    if ( isnan(a[i]) ) {                                                   \
      j--;                                                                 \
      TYPE t = a[j]; a[j] = a[i]; a[i] = t;                                \
    } else {                                                               \
      i++;                                                                 \
    }                                                                      \
  }                                                                        \
  return i;                                                                \
}                                                                          \
struct ca_partition_nan_##SUFFIX##_eat_semicolon

DEFINE_PARTITION_NAN(float32_t, f32);
DEFINE_PARTITION_NAN(double,    f64);

/* Pair variant for argsort: separates ca_pair_<type> by
   isnan(v.value).  Returns the finite count.

   Stable within both finite and NaN regions (original order
   preserved), so argsort on NaN-containing input keeps NaN indices
   in ascending order.

   Implementation: 2-pass stable filter via xmalloc scratch (single
   xmalloc + xfree per fiber; negligible overhead vs the sort
   itself). */
#define DEFINE_PARTITION_NAN_PAIR(TYPE, SUFFIX)                            \
ca_size_t                                                                  \
ca_partition_nan_pair_##SUFFIX (ca_pair_##SUFFIX *a, ca_size_t n)          \
{                                                                          \
  if ( n == 0 ) return 0;                                                  \
  ca_pair_##SUFFIX *scratch =                                              \
    (ca_pair_##SUFFIX *) xmalloc((size_t) n * sizeof(ca_pair_##SUFFIX));   \
  ca_size_t fin = 0, nan_pos = 0;                                          \
  for ( ca_size_t k = 0; k < n; k++ ) {                                    \
    if ( !isnan(a[k].v) ) scratch[fin++] = a[k];                           \
  }                                                                        \
  ca_size_t finite_count = fin;                                            \
  for ( ca_size_t k = 0; k < n; k++ ) {                                    \
    if ( isnan(a[k].v) ) scratch[finite_count + nan_pos++] = a[k];         \
  }                                                                        \
  memcpy(a, scratch, (size_t) n * sizeof(ca_pair_##SUFFIX));               \
  xfree(scratch);                                                          \
  return finite_count;                                                     \
}                                                                          \
struct ca_partition_nan_pair_##SUFFIX##_eat_semicolon

DEFINE_PARTITION_NAN_PAIR(float32_t, f32);
DEFINE_PARTITION_NAN_PAIR(double,    f64);


/* ---------------------------------------------------------------------------
   DEFINE_PARTITION_QUICK(TYPE, SUFFIX) -- value-level quickselect.

   Emits public `void ca_partition_quick_<SUFFIX>(TYPE *a,
   ca_size_t n, ca_size_t kth)` that reorders `a[0..n)` so that:
     - a[kth] is the kth-smallest element under `<`
     - a[0..kth-1]   all compare <= a[kth]
     - a[kth+1..n-1] all compare >= a[kth]
   Order within the two regions is unspecified.

   Algorithm: median-of-3 pivot + Hoare partition + insertion-sort
   base (threshold 16) + one-sided recursion into the side
   containing kth (true quickselect: expected O(n), stack O(log n)).

   Worst-case guarantee: depth_limit = 2*floor(log2(n)) + 2 (matches
   the sort kernels).  On escape, mergesort the residual window;
   mergesort fully sorts the window, which is strictly stronger than
   the partition contract, so kth ends up correct as a side-effect.
   Cost on escape: O(n log n) on the residual window only.
   --------------------------------------------------------------------- */

#define DEFINE_PARTITION_QUICK(TYPE, SUFFIX)                                \
                                                                            \
static void                                                                 \
ca_partition_quick_##SUFFIX##_range (TYPE *a, ca_size_t lo, ca_size_t hi,   \
                                     ca_size_t kth, int depth_limit)        \
{                                                                           \
  while ( hi - lo > CA_SORT_INSERTION_THRESHOLD ) {                         \
    if ( depth_limit <= 0 ) {                                               \
      /* Depth-limit escape: mergesort the residual window.  A full         \
         sort is strictly stronger than the partition contract, so kth      \
         ends up correct as a side-effect.  Cheaper than continuing to      \
         degrade on adversarial input. */                                   \
      ca_size_t n_remain = hi - lo + 1;                                     \
      TYPE *aux = (TYPE *) xmalloc((size_t) n_remain * sizeof(TYPE));       \
      ca_sort_merge_##SUFFIX(a + lo, aux, n_remain);                        \
      xfree(aux);                                                           \
      return;                                                               \
    }                                                                       \
    depth_limit--;                                                          \
    ca_size_t mid = lo + (hi - lo) / 2;                                     \
    /* median-of-3: order a[lo] <= a[mid] <= a[hi]. */                      \
    if ( a[mid] < a[lo]  ) { TYPE t = a[lo];  a[lo]  = a[mid]; a[mid] = t; } \
    if ( a[hi]  < a[lo]  ) { TYPE t = a[lo];  a[lo]  = a[hi];  a[hi]  = t; } \
    if ( a[hi]  < a[mid] ) { TYPE t = a[mid]; a[mid] = a[hi];  a[hi]  = t; } \
    TYPE pivot = a[mid];                                                    \
    /* Hoare partition. */                                                  \
    ca_size_t i = lo, j = hi;                                               \
    for (;;) {                                                              \
      while ( a[i] < pivot ) i++;                                           \
      while ( pivot < a[j] ) j--;                                           \
      if ( i >= j ) break;                                                  \
      { TYPE t = a[i]; a[i] = a[j]; a[j] = t; }                             \
      i++;                                                                  \
      j--;                                                                  \
    }                                                                       \
    /* After partition:                                                     \
         a[lo..j]  all compare <= pivot                                     \
         a[j+1..hi] all compare >= pivot                                    \
       Recurse only into the side containing kth.                           \
       If kth <= j: kth is in the left half (which contains pivot           \
                    boundary), so we tighten hi = j.                        \
       Else:        kth is in the right half, lo = j + 1.                   \
       This is the quickselect property: expected O(n) work since each      \
       step halves the candidate window. */                                 \
    if ( kth <= j ) {                                                       \
      hi = j;                                                               \
    } else {                                                                \
      lo = j + 1;                                                           \
    }                                                                       \
  }                                                                         \
  /* insertion-sort the residual base window so a[kth] is exact within      \
     [lo, hi].  Cheaper than another quickselect step and gives the         \
     partition contract for free across the small window. */                \
  for ( ca_size_t k = lo + 1; k <= hi; k++ ) {                              \
    TYPE v = a[k];                                                          \
    ca_size_t m = k;                                                        \
    while ( m > lo && v < a[m - 1] ) {                                      \
      a[m] = a[m - 1];                                                      \
      m--;                                                                  \
    }                                                                       \
    a[m] = v;                                                               \
  }                                                                         \
}                                                                           \
                                                                            \
void                                                                        \
ca_partition_quick_##SUFFIX (TYPE *a, ca_size_t n, ca_size_t kth)           \
{                                                                           \
  if ( n <= 1 ) return;                                                     \
  if ( kth >= n ) return;  /* out-of-range kth = no-op, caller validates */ \
  int depth_limit = 0;                                                      \
  ca_size_t m = n;                                                          \
  while ( m > 0 ) { depth_limit++; m >>= 1; }                               \
  depth_limit *= 2;                                                         \
  ca_partition_quick_##SUFFIX##_range(a, 0, n - 1, kth, depth_limit);       \
}                                                                           \
struct ca_partition_quick_##SUFFIX##_eat_semicolon


DEFINE_SORT_QUICK(int8_t,    i8);   DEFINE_SORT_MERGE(int8_t,    i8);
DEFINE_SORT_QUICK(uint8_t,   u8);   DEFINE_SORT_MERGE(uint8_t,   u8);
DEFINE_SORT_QUICK(int16_t,   i16);  DEFINE_SORT_MERGE(int16_t,   i16);
DEFINE_SORT_QUICK(uint16_t,  u16);  DEFINE_SORT_MERGE(uint16_t,  u16);
DEFINE_SORT_QUICK(int32_t,   i32);  DEFINE_SORT_MERGE(int32_t,   i32);
DEFINE_SORT_QUICK(uint32_t,  u32);  DEFINE_SORT_MERGE(uint32_t,  u32);
DEFINE_SORT_QUICK(int64_t,   i64);  DEFINE_SORT_MERGE(int64_t,   i64);
DEFINE_SORT_QUICK(uint64_t,  u64);  DEFINE_SORT_MERGE(uint64_t,  u64);
DEFINE_SORT_QUICK(float32_t, f32);  DEFINE_SORT_MERGE(float32_t, f32);
DEFINE_SORT_QUICK(double,    f64);  DEFINE_SORT_MERGE(double,    f64);

/* Pair sort instantiations for argsort (sort_index / sort_addr). */
DEFINE_SORT_PAIR(int8_t,    i8);
DEFINE_SORT_PAIR(uint8_t,   u8);
DEFINE_SORT_PAIR(int16_t,   i16);
DEFINE_SORT_PAIR(uint16_t,  u16);
DEFINE_SORT_PAIR(int32_t,   i32);
DEFINE_SORT_PAIR(uint32_t,  u32);
DEFINE_SORT_PAIR(int64_t,   i64);
DEFINE_SORT_PAIR(uint64_t,  u64);
DEFINE_SORT_PAIR(float32_t, f32);
DEFINE_SORT_PAIR(double,    f64);

/* Value-level quickselect for partition_copy. */
DEFINE_PARTITION_QUICK(int8_t,    i8);
DEFINE_PARTITION_QUICK(uint8_t,   u8);
DEFINE_PARTITION_QUICK(int16_t,   i16);
DEFINE_PARTITION_QUICK(uint16_t,  u16);
DEFINE_PARTITION_QUICK(int32_t,   i32);
DEFINE_PARTITION_QUICK(uint32_t,  u32);
DEFINE_PARTITION_QUICK(int64_t,   i64);
DEFINE_PARTITION_QUICK(uint64_t,  u64);
DEFINE_PARTITION_QUICK(float32_t, f32);
DEFINE_PARTITION_QUICK(double,    f64);

/* No Init function: this file exposes only C kernels (via ca_sort_kernels.h);
   it registers no Ruby methods. */
