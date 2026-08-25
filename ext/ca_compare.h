/* ---------------------------------------------------------------------------

  Element comparators by data_type: a 3-way compare (-1 / 0 / +1) of two
  same-typed cells, with the (const void *, const void *) prototype that
  libc qsort / bsearch expect.  This is a shared *ordering primitive*, not
  tied to any one algorithm: the index sort (carray_sort.c) and the binary
  search (carray_order.c) both dispatch through ca_elem_cmp[data_type].

  CA_FIXLEN (packed byte blobs) is intentionally `unsupported` in the table:
  a 2-arg comparator cannot carry the element byte width, so each caller
  compares fixlen cells itself (carray_order.c via a cmp_data wrapper for
  bsearch; carray_sort.c via a direct memcmp).  Float slots order NaN last.

--------------------------------------------------------------------------- */

#ifndef CA_COMPARE_H
#define CA_COMPARE_H

/* 3-way element comparator, qsort/bsearch-compatible signature. */
typedef int (*ca_cmp_func)(const void *, const void *);

/* Per-data_type element comparators, indexed by data_type (CA_NTYPE wide).
   FIXLEN / retired / unused slots hold an unsupported stub that raises. */
extern ca_cmp_func ca_elem_cmp[CA_NTYPE];

#endif /* CA_COMPARE_H */
