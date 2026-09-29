/* ---------------------------------------------------------------------------

  ca_sort_kernels.h

  Portable textbook sort kernels (PROPOSAL_PORTABLE_TEXTBOOK_SORT).

    P.1 / P.2 : quicksort + mergesort over the 10 numeric data types
                (i8 / u8 / i16 / u16 / i32 / u32 / i64 / u64 / f32 / f64)
    P.3       : NaN pre-partition for f32 / f64
    P.4       : pair (value + index) variants for argsort kernels —
                sort_index / sort_addr / partition_index family
    P.9       : value-level quickselect for partition_copy

  Status: ext-internal.  Signatures may change across 3.x while the
  textbook sort family evolves.  Included from carray.h so internal
  consumers (carray_sort_kernel.c, carray_order.c, carray_kernels.c,
  mkkernel emit) reach it transparently via `#include "carray.h"`.

  Depends on int8_t .. uint64_t / float32_t / double / ca_size_t
  typedefs from carray.h — when this header is included from carray.h
  mid-file, those typedefs are already in scope by the time we reach
  the include site.

  --------------------------------------------------------------------------- */

#ifndef CA_SORT_KERNELS_H
#define CA_SORT_KERNELS_H 1

/* Needs int8_t .. uint64_t / float32_t / double / ca_size_t.  No longer
   pulled mid-carray.h (PROPOSAL_CARRAY_H_REORG H.4.1), so include carray.h
   directly to be self-sufficient when a consumer includes this header.
   Guard-protected, so the re-entry is a no-op when carray.h is already in
   flight. */
#include "carray.h"

/* P.1 / P.2: quicksort over 10 numeric data types. */
void ca_sort_quick_i8  (int8_t    *a, ca_size_t n);
void ca_sort_quick_u8  (uint8_t   *a, ca_size_t n);
void ca_sort_quick_i16 (int16_t   *a, ca_size_t n);
void ca_sort_quick_u16 (uint16_t  *a, ca_size_t n);
void ca_sort_quick_i32 (int32_t   *a, ca_size_t n);
void ca_sort_quick_u32 (uint32_t  *a, ca_size_t n);
void ca_sort_quick_i64 (int64_t   *a, ca_size_t n);
void ca_sort_quick_u64 (uint64_t  *a, ca_size_t n);
void ca_sort_quick_f32 (float32_t *a, ca_size_t n);
void ca_sort_quick_f64 (double    *a, ca_size_t n);

/* P.1 / P.2: mergesort over 10 numeric data types (`aux` is caller-supplied
   scratch buffer of the same length / data type as `a`). */
void ca_sort_merge_i8  (int8_t    *a, int8_t    *aux, ca_size_t n);
void ca_sort_merge_u8  (uint8_t   *a, uint8_t   *aux, ca_size_t n);
void ca_sort_merge_i16 (int16_t   *a, int16_t   *aux, ca_size_t n);
void ca_sort_merge_u16 (uint16_t  *a, uint16_t  *aux, ca_size_t n);
void ca_sort_merge_i32 (int32_t   *a, int32_t   *aux, ca_size_t n);
void ca_sort_merge_u32 (uint32_t  *a, uint32_t  *aux, ca_size_t n);
void ca_sort_merge_i64 (int64_t   *a, int64_t   *aux, ca_size_t n);
void ca_sort_merge_u64 (uint64_t  *a, uint64_t  *aux, ca_size_t n);
void ca_sort_merge_f32 (float32_t *a, float32_t *aux, ca_size_t n);
void ca_sort_merge_f64 (double    *a, double    *aux, ca_size_t n);

/* P.3: NaN pre-partition for float data types (Hoare 1-pass, returns finite count). */
ca_size_t ca_partition_nan_f32 (float32_t *a, ca_size_t n);
ca_size_t ca_partition_nan_f64 (double    *a, ca_size_t n);

/* P.4: pair variant of NaN pre-partition for float argsort kernels. */
struct ca_pair_f32;
struct ca_pair_f64;
ca_size_t ca_partition_nan_pair_f32 (struct ca_pair_f32 *a, ca_size_t n);
ca_size_t ca_partition_nan_pair_f64 (struct ca_pair_f64 *a, ca_size_t n);

/* P.9: value-level quickselect for partition_copy.
   Reorders a[0..n) so that a[kth] is exact + left/right regions
   satisfy <= / >= contracts.  Order within each region unspecified. */
void ca_partition_quick_i8  (int8_t    *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_u8  (uint8_t   *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_i16 (int16_t   *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_u16 (uint16_t  *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_i32 (int32_t   *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_u32 (uint32_t  *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_i64 (int64_t   *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_u64 (uint64_t  *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_f32 (float32_t *a, ca_size_t n, ca_size_t kth);
void ca_partition_quick_f64 (double    *a, ca_size_t n, ca_size_t kth);

/* P.4: pair sort kernels (= argsort: sort_index / sort_addr).  The pair
   struct is opaque to mkkernel-emitted callers via void*; each kernel
   has its own well-defined layout: { TYPE v; ca_size_t i; } with natural
   alignment padding. */
struct ca_pair_i8  { int8_t    v; ca_size_t i; };
struct ca_pair_u8  { uint8_t   v; ca_size_t i; };
struct ca_pair_i16 { int16_t   v; ca_size_t i; };
struct ca_pair_u16 { uint16_t  v; ca_size_t i; };
struct ca_pair_i32 { int32_t   v; ca_size_t i; };
struct ca_pair_u32 { uint32_t  v; ca_size_t i; };
struct ca_pair_i64 { int64_t   v; ca_size_t i; };
struct ca_pair_u64 { uint64_t  v; ca_size_t i; };
struct ca_pair_f32 { float32_t v; ca_size_t i; };
struct ca_pair_f64 { double    v; ca_size_t i; };
typedef struct ca_pair_i8  ca_pair_i8;
typedef struct ca_pair_u8  ca_pair_u8;
typedef struct ca_pair_i16 ca_pair_i16;
typedef struct ca_pair_u16 ca_pair_u16;
typedef struct ca_pair_i32 ca_pair_i32;
typedef struct ca_pair_u32 ca_pair_u32;
typedef struct ca_pair_i64 ca_pair_i64;
typedef struct ca_pair_u64 ca_pair_u64;
typedef struct ca_pair_f32 ca_pair_f32;
typedef struct ca_pair_f64 ca_pair_f64;

void ca_sort_quick_pair_i8  (ca_pair_i8  *a, ca_size_t n);
void ca_sort_quick_pair_u8  (ca_pair_u8  *a, ca_size_t n);
void ca_sort_quick_pair_i16 (ca_pair_i16 *a, ca_size_t n);
void ca_sort_quick_pair_u16 (ca_pair_u16 *a, ca_size_t n);
void ca_sort_quick_pair_i32 (ca_pair_i32 *a, ca_size_t n);
void ca_sort_quick_pair_u32 (ca_pair_u32 *a, ca_size_t n);
void ca_sort_quick_pair_i64 (ca_pair_i64 *a, ca_size_t n);
void ca_sort_quick_pair_u64 (ca_pair_u64 *a, ca_size_t n);
void ca_sort_quick_pair_f32 (ca_pair_f32 *a, ca_size_t n);
void ca_sort_quick_pair_f64 (ca_pair_f64 *a, ca_size_t n);

void ca_sort_merge_pair_i8  (ca_pair_i8  *a, ca_pair_i8  *aux, ca_size_t n);
void ca_sort_merge_pair_u8  (ca_pair_u8  *a, ca_pair_u8  *aux, ca_size_t n);
void ca_sort_merge_pair_i16 (ca_pair_i16 *a, ca_pair_i16 *aux, ca_size_t n);
void ca_sort_merge_pair_u16 (ca_pair_u16 *a, ca_pair_u16 *aux, ca_size_t n);
void ca_sort_merge_pair_i32 (ca_pair_i32 *a, ca_pair_i32 *aux, ca_size_t n);
void ca_sort_merge_pair_u32 (ca_pair_u32 *a, ca_pair_u32 *aux, ca_size_t n);
void ca_sort_merge_pair_i64 (ca_pair_i64 *a, ca_pair_i64 *aux, ca_size_t n);
void ca_sort_merge_pair_u64 (ca_pair_u64 *a, ca_pair_u64 *aux, ca_size_t n);
void ca_sort_merge_pair_f32 (ca_pair_f32 *a, ca_pair_f32 *aux, ca_size_t n);
void ca_sort_merge_pair_f64 (ca_pair_f64 *a, ca_pair_f64 *aux, ca_size_t n);

/* Runs of this many elements are insertion-sorted before the merge passes. */
#define CA_SORT_INSERTION_THRESHOLD 16

/* The body of a stable bottom-up mergesort over TYPE, ordered by cmp alone
   (the element type has no `<`), for a function taking
     (TYPE *a, TYPE *aux, ca_size_t n, int (*cmp)(const void *, const void *))
   aux holds n elements.  cmp may raise -- an object comparator calls <=> --
   and the raise unwinds through this code's frames, which hold nothing;
   libc's qsort / mergesort would have to be unwound instead.

   A comparison is costly here (a call into Ruby) and a move is cheap, so
   the runs are insertion-sorted with each insertion point found by binary
   search: log2(k) comparisons where a linear walk takes k/2.  Merge passes
   ping-pong between a and aux and skip a pair of runs already in order.
   Stable: an element lands after every one that does not compare greater,
   and a merge takes from the right run only on a strictly smaller one. */
#define CA_SORT_MERGE_BY_CMP(TYPE)                                            \
{                                                                             \
  if ( n <= 1 ) return;                                                       \
  for ( ca_size_t lo = 0; lo < n; lo += CA_SORT_INSERTION_THRESHOLD ) {       \
    ca_size_t hi = lo + CA_SORT_INSERTION_THRESHOLD;                          \
    if ( hi > n ) hi = n;                                                     \
    for ( ca_size_t k = lo + 1; k < hi; k++ ) {                               \
      TYPE v = a[k];                                                          \
      ca_size_t l = lo, r = k;                                                \
      while ( l < r ) {                                                       \
        ca_size_t mid = l + (r - l) / 2;                                      \
        if ( cmp(&a[mid], &v) > 0 ) r = mid;                                  \
        else                        l = mid + 1;                              \
      }                                                                       \
      if ( l < k ) {                                                          \
        memmove(a + l + 1, a + l, (size_t)(k - l) * sizeof(TYPE));            \
        a[l] = v;                                                             \
      }                                                                       \
    }                                                                         \
  }                                                                           \
  TYPE *cur  = a;                                                             \
  TYPE *next = aux;                                                           \
  for ( ca_size_t width = CA_SORT_INSERTION_THRESHOLD; width < n;             \
        width <<= 1 ) {                                                       \
    for ( ca_size_t lo = 0; lo < n; lo += (width << 1) ) {                    \
      ca_size_t mid = lo + width;                                             \
      ca_size_t hi  = lo + (width << 1);                                      \
      if ( mid > n ) mid = n;                                                 \
      if ( hi  > n ) hi  = n;                                                 \
      if ( mid >= hi || cmp(&cur[mid - 1], &cur[mid]) <= 0 ) {               \
        memcpy(next + lo, cur + lo, (size_t)(hi - lo) * sizeof(TYPE));        \
        continue;                                                             \
      }                                                                       \
      ca_size_t i = lo, j = mid, k = lo;                                      \
      while ( i < mid && j < hi ) {                                           \
        if ( cmp(&cur[j], &cur[i]) < 0 ) next[k++] = cur[j++];                \
        else                             next[k++] = cur[i++];                \
      }                                                                       \
      while ( i < mid ) next[k++] = cur[i++];                                 \
      while ( j < hi  ) next[k++] = cur[j++];                                 \
    }                                                                         \
    { TYPE *t = cur; cur = next; next = t; }                                  \
  }                                                                           \
  if ( cur != a ) {                                                           \
    memcpy(a, cur, (size_t) n * sizeof(TYPE));                                \
  }                                                                           \
}

/* (VALUE, index) pairs, as the object lane of the sort kernels holds them. */
typedef struct ca_pair_object { VALUE v; ca_size_t i; } ca_pair_object;
void ca_sort_merge_pair_object (ca_pair_object *a, ca_pair_object *aux,
                                ca_size_t n,
                                int (*cmp)(const void *, const void *));

#endif /* CA_SORT_KERNELS_H */
