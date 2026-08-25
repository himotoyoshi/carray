/* ---------------------------------------------------------------------------

  Geometric primitives for region-mapped views (CAWindow / CATile /
  CARoll).  These helpers are the "per-region routine" called by each
  region-mapped view's attach/sync path.

  Design pattern (= split routines, not a tagged union over source kind):
  - the region descriptor carries only geometric metadata
    (output_offset, count); source info (parent, parent_start, fill_value)
    is passed as a per-call parameter.
  - ALIAS regions use _region_gather / _region_scatter; broadcast fill
    is ca_fill_typed (full output) or _fill_rect / _fill_complement for
    sub-regions.

---------------------------------------------------------------------------- */

#ifndef CA_COMPOSITE_DISPATCH_H
#define CA_COMPOSITE_DISPATCH_H

#include "carray.h"

/* Fill `n` cells of `dst`, each `bytes` wide, with the value at `val`.

   SIMD-friendly typed-store dispatch on bytes ∈ {1, 2, 4, 8, 16}, generic
   memcpy fallback for other widths (CA_FIXLEN, unusual struct sizes).
   Compiler vectorises the uint16/32/64 stores into NEON / SSE2 stores.

   Called from ca_obj_window.c and ca_axis_dispatch.c for the
   broadcast-fill step. */
void ca_fill_typed (char *dst, const char *val,
                    ca_size_t bytes, ca_size_t n);

/* Strided memcpy from a sub-rectangle of `parent_ptr` to a sub-rectangle
   of `out_ptr`.  Both rectangles have the same shape (`count`).

   parent_ptr     : base pointer of parent's row-major contig buffer
                    (caller has attached parent; parent->ptr is valid)
   parent_strides : per-axis byte stride within parent (row-major)
   parent_start   : per-axis start index in parent for the source rectangle
   out_ptr        : base pointer of the output buffer (row-major contig
                    over the view's own shape)
   output_strides : per-axis byte stride within output
   output_offset  : per-axis start index in output for the destination rectangle
   count          : per-axis size of the rectangle (same for both)
   ndim, bytes    : view ndim and element bytes

   Internal fast paths:
   - ndim == 1: single memcpy
   - ndim == 2 (outer_axes == 1): pointer-advancing 2D loop, no idx[]
   - ndim >= 3: multi-dim cursor walk over outer axes

   Called from the attach paths of ca_obj_window.c, ca_obj_tile.c and
   ca_obj_roll.c. */
void ca_composite_region_gather (char *parent_ptr,
                                 const ca_size_t *parent_strides,
                                 const ca_size_t *parent_start,
                                 char *out_ptr,
                                 const ca_size_t *output_strides,
                                 const ca_size_t *output_offset,
                                 const ca_size_t *count,
                                 int8_t ndim,
                                 ca_size_t bytes);

/* Reverse direction: copy from out_ptr rectangle to parent rectangle.
   Called from the sync (write-back) paths of ca_obj_window.c,
   ca_obj_tile.c and ca_obj_roll.c.  Same parameter geometry as
   _region_gather. */
void ca_composite_region_scatter (char *parent_ptr,
                                  const ca_size_t *parent_strides,
                                  const ca_size_t *parent_start,
                                  const char *in_ptr,
                                  const ca_size_t *input_strides,
                                  const ca_size_t *input_offset,
                                  const ca_size_t *count,
                                  int8_t ndim,
                                  ca_size_t bytes);

/* Complement-aware fill.

   ca_composite_fill_rect: fill a rectangle sub-region of out_ptr with
   typed value `fill_value` (broadcast).  Same rectangle geometry as
   _region_gather but the source is a single value, not a parent
   rectangle.  1D / 2D / N-D internal fast paths.

   ca_composite_fill_complement: fill the complement of an alias
   rectangle (= output minus alias).  Enumerates up to 2*ndim disjoint
   strip regions and calls _fill_rect for each non-empty strip.  Each
   strip is a rectangle:
     axis k "before" strip: alias range on dims 0..k-1, [0..alias_offset[k])
                            on dim k, full on dims k+1..ndim-1
     axis k "after"  strip: alias range on dims 0..k-1,
                            [alias_offset[k]+alias_count[k]..output_dim[k])
                            on dim k, full on dims k+1..ndim-1
   Strips are pairwise disjoint and together cover output minus alias.

   Called from CAWindow's attach path: rather than fill_typed over the
   entire output and then overwrite the alias rectangle, fill only the
   complement strips (= no wasted writes on the alias region). */
void ca_composite_fill_rect       (char *out_ptr,
                                   const ca_size_t *output_strides,
                                   const ca_size_t *offset,
                                   const ca_size_t *count,
                                   const char *fill_value,
                                   ca_size_t bytes,
                                   int8_t ndim);

void ca_composite_fill_complement (char *out_ptr,
                                   const ca_size_t *output_strides,
                                   const ca_size_t *output_dim,
                                   const ca_size_t *alias_offset,
                                   const ca_size_t *alias_count,
                                   const char *fill_value,
                                   ca_size_t bytes,
                                   int8_t ndim);

#endif /* CA_COMPOSITE_DISPATCH_H */
