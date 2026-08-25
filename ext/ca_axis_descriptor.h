/* ---------------------------------------------------------------------------

  ca_axis_descriptor.h

  Per-axis descriptor framework (D1 + D2 + D3) — shared C-level vocabulary
  that lets CSA, CAGrid, CASelectAxis, CAWindow, CAShift, and future
  per-axis-mixed views describe each axis the same way so a common
  attach dispatch engine (D3, ca_axis_dispatch.c) can drive them
  uniformly.

  See devel/PROPOSAL_AXIS_DESCRIPTOR_FRAMEWORK.md for the design.

  Status: TWO-TIER FREEZE CONTRACT (3.0 onward), the same split
  ca_kernel_iterator.h declares, for the same reason: this header is
  installed and reachable from `#include "carray.h"`, so what it declares
  is visible to downstream gems whether or not they were meant to use it.

    FROZEN (additions only; renaming or re-laying-out is a 3.x break):
      - ca_axis_kind_t and the layout of ca_axis_desc_t

      Not because view authors were invited to build descriptors, but
      because ca_iter_state -- whose slab-delivery fields ARE frozen
      author contract -- embeds ca_axis_desc_t descs[CA_RANK_MAX] by
      value.  The type is already part of that struct's layout, so it
      cannot move or shrink without breaking kernels that were promised
      stability.  It is frozen by consequence, not by invitation.

    INTERNAL (free to change across 3.x; no downstream contract):
      - every function below: ca_axis_dispatch_gather / _attach /
        _scatter / _fill_value / _fill_value_via_parent, and the
        ca_*_describe_axes producers

      An external obj_type cannot participate in this engine anyway:
      ca_iter_register_source_kind accepts CA_ITER_SRC_ATTACH only and
      raises on CA_ITER_SRC_DESCRIPTOR, precisely because the engine
      looks describe_axes up in its own table and an external type has no
      way to supply one.  A contract nobody outside can invoke is a
      contract not worth keeping, so these stay free to move.

  In-tree consumers (ca_obj_grid.c, ca_obj_select.c, ca_obj_select_axis.c,
  ca_obj_window.c, ca_iter_substrate.h, ca_kernel_iterator.c) pick this up
  transitively from carray.h without an explicit include.

  --------------------------------------------------------------------------- */

#ifndef CA_AXIS_DESCRIPTOR_H
#define CA_AXIS_DESCRIPTOR_H 1

/* Depends on int8_t / uint8_t / ca_size_t typedefs from carray.h.
   When this header is included from carray.h mid-file, those typedefs
   are already in scope by the time we reach the include site. */

/* ---- D1: per-axis descriptor types ----------------------------------------

   STRIDE = linear stride axis: parent index = start + i*step,
            i in [0, count).  Subsumes nil / Integer / Range index args.
   INDEX  = integer index axis:  parent index = indices[i],
            i in [0, count).  Subsumes integer-array (CAGrid)
            and boolean-mask-after-snapshot (CASelectAxis) axes.
   SHIFT  = bound-aware stride axis (CAWindow/CAShift, Tier 2.B):
            parent index = start + i*step normalised by `policy`
            (CA_BOUNDS_FILL / PERIODIC / REFLECT / NEAREST / ...)
            against `size0` (= parent dim along this axis).  When
            normalisation fails (still out of range, e.g. FILL
            policy), the engine writes `bound_fill` to the gather
            buffer (or skips the parent write on scatter). */
typedef enum {
  CA_AXIS_KIND_STRIDE = 0,
  CA_AXIS_KIND_INDEX  = 1,
  CA_AXIS_KIND_SHIFT  = 2
} ca_axis_kind_t;

typedef struct {
  ca_axis_kind_t  kind;
  ca_size_t       count;     /* output size contributed by this axis */
  /* STRIDE / SHIFT fields (unused / undefined when kind == INDEX) */
  ca_size_t       start;
  ca_size_t       step;
  /* INDEX-only field (unused / NULL when kind != INDEX).
     Ownership: borrowed from the producer view; lifetime tied to
     the view that produced the descriptor array.  Consumer (D3
     dispatch) must not free or mutate. */
  ca_size_t      *indices;
  /* SHIFT-only fields (unused / undefined when kind != SHIFT) */
  ca_size_t       size0;     /* parent dim along this axis (bounds check) */
  uint8_t         policy;    /* CA_BOUNDS_FILL / PERIODIC / REFLECT / ... */
} ca_axis_desc_t;

/* ---- D2: producer interface ----------------------------------------------

   Both implementations write ndim entries into `out` (caller-allocated)
   and `out_parent_dims` (caller-allocated, sized CA_RANK_MAX).  See
   devel/PROPOSAL_AXIS_DESCRIPTOR_FRAMEWORK.md §5 Framework Phase 1 and
   devel/PROPOSAL_FLAT_INDEX_VIEWS.md §2.3 for rationale.

   `out_parent_dims[k]` is the **effective** parent dim along descriptor
   axis k — for CSA / CAGrid this is just `parent->dim[k]`, but for
   flat-index views (CASelect / CAMapping, Tier 2.A.3+) it is
   `{parent->elements}` (a single-axis flat view of parent).  This
   decouples descriptor.ndim from parent.ndim so the engine can drive
   views whose iteration axes don't match the parent's physical shape.

   Pointer arguments are typed `void *` here to avoid pulling the
   private CASelectAxis / CAGrid struct definitions (which live in
   their respective .c files) into this header.  Each implementation
   casts to its concrete type inside the .c file. */
void ca_select_axis_describe_axes (void *ca, ca_axis_desc_t *out,
                                   ca_size_t *out_parent_dims);
void ca_grid_describe_axes        (void *ca, ca_axis_desc_t *out,
                                   ca_size_t *out_parent_dims);

/* ---- D3: common attach engine --------------------------------------------

   Drives gather from `parent` into an output buffer driven by the
   per-axis descriptor array.  Caller must have parent attached before
   invoking.

   `parent_axis_dims[ndim]` carries the effective parent dim per
   descriptor axis (see producer interface above).  The engine never
   reads `parent->dim` directly — it only reads `parent->ptr` for
   data access — which is what allows flat-index views to lie about
   parent's apparent shape (Tier 2.A, PROPOSAL_FLAT_INDEX_VIEWS.md).

   `bound_fill` is the bytes-wide value written into gather output
   cells whose SHIFT axes resolve to an out-of-bounds parent index
   (Tier 2.B, PROPOSAL_BOUND_AWARE_VIEWS.md).  Pass NULL when no
   SHIFT axis is present (CSA / CAGrid / CASelect / CAMapping); the
   engine ignores it.  On scatter, the engine simply skips parent
   writes for OOB cells regardless of bound_fill.

   _gather — caller provides out_buf (must be sized total_elements*bytes)
   _attach — wrapper that mallocs the buffer; caller xfrees

   Returns a 1-byte placeholder when total_elements == 0 (the
   _attach variant); _gather becomes a no-op in that case.

   Forward-declare struct _CArray so these declarations can sit in a
   stand-alone header without dragging in the full CArray definition. */
struct _CArray;
void  ca_axis_dispatch_gather  (struct _CArray  *parent,
                                const ca_size_t *parent_axis_dims,
                                ca_axis_desc_t  *axes,
                                int8_t           ndim,
                                ca_size_t        bytes,
                                ca_size_t        total_elements,
                                const void      *bound_fill,
                                char            *out_buf);
char *ca_axis_dispatch_attach  (struct _CArray  *parent,
                                const ca_size_t *parent_axis_dims,
                                ca_axis_desc_t  *axes,
                                int8_t           ndim,
                                ca_size_t        bytes,
                                ca_size_t        total_elements,
                                const void      *bound_fill);
void  ca_axis_dispatch_scatter (struct _CArray  *parent,
                                const ca_size_t *parent_axis_dims,
                                ca_axis_desc_t  *axes,
                                int8_t           ndim,
                                ca_size_t        bytes,
                                ca_size_t        total_elements,
                                const char      *in_buf);
/* Broadcast scatter: write the single value `val` (bytes wide) into
   every selected parent cell.  See D6 of the framework piece.
   (SHIFT axis OOB cells are skipped — fill semantics aren't
   meaningful for broadcast-write since the destination value already
   IS the broadcast value.) */
void  ca_axis_dispatch_fill_value (struct _CArray  *parent,
                                   const ca_size_t *parent_axis_dims,
                                   ca_axis_desc_t  *axes,
                                   int8_t           ndim,
                                   ca_size_t        bytes,
                                   ca_size_t        total_elements,
                                   const void      *val);

/* As above, but each slab is handed to the parent as a region of its own via
   ca_fill_stride, so a parent that has to be materialised to be addressed is
   never gathered and written back whole to set the cells this view selected. */
void  ca_axis_dispatch_fill_value_via_parent (struct _CArray  *parent,
                                              const ca_size_t *parent_axis_dims,
                                              ca_axis_desc_t  *axes,
                                              int8_t           ndim,
                                              ca_size_t        bytes,
                                              ca_size_t        total_elements,
                                              const void      *val);

#endif /* CA_AXIS_DESCRIPTOR_H */
