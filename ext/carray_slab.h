/* ---------------------------------------------------------------------------

  carray_slab.h

  PROPOSAL_SLAB_FAMILY (= Phase E "Ruby surface β") — engine state struct.

  After the PROPOSAL_SLAB_API_REFACTOR landing, the per-call state is no
  longer Ruby-wrapped: each `CArray#map_slab` / `#reduce_slab` /
  `#each_slab` entry stack-allocates a zeroed `ca_slab_iter_state_t`,
  populates it via `slab_state_init` (nofail), and `rb_ensure`-runs
  `slab_state_run_body` + `slab_state_finish` to acquire/release T1
  substrate + scratch within a leak-free scope.

  Constraints (PROPOSAL_SLAB_FAMILY §2 — still apply):
    - Calls T1 substrate (ext/ca_kernel_iterator.h) only.  No new helpers
      added to T1 / CAStride.
    - `ca_detach(slab_view)` is NEVER called in finish (= memo §5.2.5
      hazard: T1 buffer would be mis-identified as slab_view-owned).
      Instead, the slab_view VALUE handle is dropped from the iter state
      and GC reclaims the CAStride wrapper without freeing the borrowed ptr.

  --------------------------------------------------------------------------- */

#ifndef CARRAY_SLAB_H
#define CARRAY_SLAB_H 1

#include "carray.h"
#include "ca_kernel_iterator.h"

/* form enum (= PROPOSAL §3 surface 3 form + reduce_slab dual surface
   split into per-element fiber / per-slab block).  Dispatch is fixed at
   __init__ time from `init:` kwarg presence; loop body branches on this
   enum exactly once per iter via a switch. */
typedef enum {
  CA_SLAB_FORM_MAP          = 0,
  CA_SLAB_FORM_REDUCE_FIBER = 1,   /* `init:` given, per-element yield */
  CA_SLAB_FORM_REDUCE_SLAB  = 2,   /* `init:` absent, per-slab block scalar */
  CA_SLAB_FORM_EACH         = 3
} ca_slab_form_t;

/* mode enum (= mirrors T1's alias_mode).  Populated at __init__ probe time. */
typedef enum {
  CA_SLAB_MODE_ALIAS           = 0,
  CA_SLAB_MODE_SCRATCH_CONTIG  = 1,
  CA_SLAB_MODE_SCRATCH_STRIDED = 2
} ca_slab_mode_t;

/* SlabIterator state struct.  All Ruby-VALUE fields are marked by dmark.
   T1 ca_iter_state (`t1`) is heap-allocated; dfree xfrees it.  Other
   resources (carrier / mask_carrier / output / *_slab_view) are GC-managed
   CArray VALUEs — no explicit free is performed. */
typedef struct ca_slab_iter_state {
  VALUE  self;              /* source CArray (= @reference compatible) */
  VALUE  slab_view;         /* CAStride view, per-iter ptr mutate target */
  VALUE  carrier;           /* SCRATCH mode owning CArray, Qnil in ALIAS */
  VALUE  mask_carrier;      /* β.xb: unused (always Qnil) — the mask
                               sibling is owned by `carrier` via its
                               C-level mask field, no separate Ruby pin
                               needed.  Kept here for forward compat.   */
  VALUE  output;            /* map_slab output / reduce_slab accumulator */
  VALUE  output_slab_view;  /* write-side CAStride, Qnil unless MAP */
  ca_iter_state *t1;        /* T1 substrate state (READ side), heap, freed in finish */
  ca_iter_state *t1_out;    /* T1 substrate state (WRITE side, MAP only), heap */
  uint8_t  t1_started;      /* 1 once t1 init_l2 returned OK (= finish gate) */
  uint8_t  t1_out_started;  /* 1 once t1_out init_l2 returned OK */
  int8_t   form;            /* ca_slab_form_t */
  int8_t   mode;            /* ca_slab_mode_t */
  int8_t   slab_ndim;       /* number of slab axes */
  int8_t   slab_axes[CA_RANK_MAX];
  int8_t   out_data_type;       /* output data_type (MAP / REDUCE forms) */
  ca_size_t out_bytes;      /* output element size in bytes */
  VALUE    init_val;        /* REDUCE_FIBER initial accumulator, Qnil if N/A */

  /* β.xc' Piece B: own gather/scatter scratch for non-contig multi-axis.
     Allocated at setup when (slab_ndim > 1 && slab not row-major contig
     in src memory), freed in dfree.  Lifecycle is independent of T1's
     scratch (= which is naxes==1 only for FIBER_CONTIG).                 */
  char        *own_data_scratch;       /* per-iter K-D gather (input side) */
  boolean8_t  *own_mask_scratch;       /* per-iter K-D gather (input mask) */
  char        *own_out_scratch;        /* per-iter K-D scatter (map output) */
  ca_size_t    own_scratch_elements;   /* Π slab_dims (= scratch size in cells) */
} ca_slab_iter_state_t;

#endif /* CARRAY_SLAB_H */
