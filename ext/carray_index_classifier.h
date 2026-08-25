/* ---------------------------------------------------------------------------

  carray_index_classifier.h

  rb_ca_scan_index v2 — internal declarations.

  PROPOSAL_INDEXER_REDESIGN.md I.2 sub-step.  Parallel implementation
  of v1 (= rb_ca_scan_index in ext/carray_access.c).  Pre-swap (before
  I.6) v2 is dormant: not reachable from outside this file group.
  After I.6, rb_ca_scan_index forwards here.

  The public C API signature (= void rb_ca_scan_index(...)) is
  unchanged; this header is internal and intentionally not exported.

--------------------------------------------------------------------------- */

#ifndef CARRAY_INDEX_CLASSIFIER_H
#define CARRAY_INDEX_CLASSIFIER_H

#include "carray.h"

/* v2 entry point.  Signature identical to v1's rb_ca_scan_index, so
   the I.6 swap is a single-line forward call. */
void rb_ca_scan_index_v2 (int ca_ndim, ca_size_t *ca_dim, ca_size_t ca_elements,
                          long argc, VALUE *argv, CAIndexInfo *info);

#endif /* CARRAY_INDEX_CLASSIFIER_H */
