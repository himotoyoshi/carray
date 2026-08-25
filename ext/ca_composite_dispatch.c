/* ---------------------------------------------------------------------------

  Geometric primitives for region-mapped views (CAWindow / CATile /
  CARoll): per-region strided gather, scatter, and broadcast fill.
  See ca_composite_dispatch.h for the full per-function API contract.

  Routines here are pure C, no Ruby VALUE handling.  They operate on
  raw pointers + byte stride arrays.  Caller is responsible for parent
  attach state and output buffer allocation.

---------------------------------------------------------------------------- */

#include "ca_composite_dispatch.h"
#include <string.h>

/* --------------------------------------------------------------------- */
/* ca_fill_typed                                                          */
/*                                                                        */
/* Per-size typed-store loops let the compiler autovectorize (NEON /      */
/* SSE), converting N tight memcpy(bytes) calls into one O(N) SIMD'd      */
/* typed-store loop.  Generic memcpy fallback covers CA_FIXLEN and        */
/* unusual widths.                                                        */
/* --------------------------------------------------------------------- */

void
ca_fill_typed (char *dst, const char *val, ca_size_t bytes, ca_size_t n)
{
  ca_size_t i;
  switch ( bytes ) {
    case 1: {
      memset(dst, *(const unsigned char *)val, n);
      break;
    }
    case 2: {
      uint16_t  v = *(const uint16_t *)val;
      uint16_t *p = (uint16_t *)dst;
      for ( i = 0; i < n; i++ ) p[i] = v;
      break;
    }
    case 4: {
      uint32_t  v = *(const uint32_t *)val;
      uint32_t *p = (uint32_t *)dst;
      for ( i = 0; i < n; i++ ) p[i] = v;
      break;
    }
    case 8: {
      uint64_t  v = *(const uint64_t *)val;
      uint64_t *p = (uint64_t *)dst;
      for ( i = 0; i < n; i++ ) p[i] = v;
      break;
    }
    case 16: {
      /* complex128 etc.  Two uint64_t stores per element.  Compiler
         pairs them into a NEON 128-bit or SSE2 store. */
      uint64_t v0 = ((const uint64_t *)val)[0];
      uint64_t v1 = ((const uint64_t *)val)[1];
      uint64_t *p = (uint64_t *)dst;
      for ( i = 0; i < n; i++ ) {
        p[2*i]     = v0;
        p[2*i + 1] = v1;
      }
      break;
    }
    default: {
      /* Generic fallback: CA_FIXLEN (struct types), unusual widths. */
      for ( i = 0; i < n; i++ ) memcpy(dst + i * bytes, val, bytes);
      break;
    }
  }
}

/* --------------------------------------------------------------------- */
/* ca_composite_region_gather                                             */
/*                                                                        */
/* Per-region strided memcpy from a parent sub-rectangle to an output    */
/* sub-rectangle, with 1D / 2D / N-D fast paths.                         */
/* --------------------------------------------------------------------- */

void
ca_composite_region_gather (char *parent_ptr,
                            const ca_size_t *parent_strides,
                            const ca_size_t *parent_start,
                            char *out_ptr,
                            const ca_size_t *output_strides,
                            const ca_size_t *output_offset,
                            const ca_size_t *count,
                            int8_t ndim,
                            ca_size_t bytes)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t parent_off, output_off, run_bytes, total_slabs, slab;
  int8_t    k;
  int8_t    outer_axes;

  /* Initial byte offsets into parent and output. */
  parent_off = 0;
  output_off = 0;
  for ( k = 0; k < ndim; k++ ) {
    parent_off += parent_start[k]  * parent_strides[k];
    output_off += output_offset[k] * output_strides[k];
    idx[k] = 0;
  }

  /* Innermost axis contributes the contig run; outer axes are walked. */
  run_bytes = count[ndim - 1] * bytes;
  outer_axes = ndim - 1;

  if ( outer_axes <= 0 ) {
    /* 1-D shortcut: single memcpy. */
    memcpy(out_ptr + output_off, parent_ptr + parent_off, run_bytes);
    return;
  }

  if ( outer_axes == 1 ) {
    /* 2-D fast path: single outer axis, pointer-advancing loop.  No
       multi-dim cursor, no idx[] array — keeps the per-iter body tight
       so SIMD-friendly memcpy can dominate. */
    char     *src = parent_ptr + parent_off;
    char     *dst = out_ptr + output_off;
    ca_size_t step_p = parent_strides[0];
    ca_size_t step_o = output_strides[0];
    ca_size_t count0 = count[0];
    ca_size_t i;
    for ( i = 0; i < count0; i++ ) {
      memcpy(dst, src, run_bytes);
      dst += step_o;
      src += step_p;
    }
    return;
  }

  /* General N-D path (ndim >= 3): multi-dim cursor walk over outer axes. */
  total_slabs = 1;
  for ( k = 0; k < outer_axes; k++ ) {
    total_slabs *= count[k];
  }

  for ( slab = 0; slab < total_slabs; slab++ ) {
    memcpy(out_ptr + output_off, parent_ptr + parent_off, run_bytes);

    /* Increment the multi-dim cursor (row-major, outer axes only). */
    for ( k = outer_axes - 1; k >= 0; k-- ) {
      idx[k]++;
      parent_off += parent_strides[k];
      output_off += output_strides[k];
      if ( idx[k] < count[k] ) break;
      parent_off -= parent_strides[k] * count[k];
      output_off -= output_strides[k] * count[k];
      idx[k] = 0;
    }
  }
}

/* --------------------------------------------------------------------- */
/* ca_composite_region_scatter                                            */
/*                                                                        */
/* Reverse direction of _gather: copies an input sub-rectangle back into */
/* a parent sub-rectangle (in_ptr -> parent_ptr).                        */
/* --------------------------------------------------------------------- */

void
ca_composite_region_scatter (char *parent_ptr,
                             const ca_size_t *parent_strides,
                             const ca_size_t *parent_start,
                             const char *in_ptr,
                             const ca_size_t *input_strides,
                             const ca_size_t *input_offset,
                             const ca_size_t *count,
                             int8_t ndim,
                             ca_size_t bytes)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t parent_off, input_off, run_bytes, total_slabs, slab;
  int8_t    k;
  int8_t    outer_axes;

  parent_off = 0;
  input_off  = 0;
  for ( k = 0; k < ndim; k++ ) {
    parent_off += parent_start[k] * parent_strides[k];
    input_off  += input_offset[k] * input_strides[k];
    idx[k] = 0;
  }

  run_bytes = count[ndim - 1] * bytes;
  outer_axes = ndim - 1;

  if ( outer_axes <= 0 ) {
    memcpy(parent_ptr + parent_off, in_ptr + input_off, run_bytes);
    return;
  }

  if ( outer_axes == 1 ) {
    char     *dst = parent_ptr + parent_off;
    const char *src = in_ptr + input_off;
    ca_size_t step_p = parent_strides[0];
    ca_size_t step_i = input_strides[0];
    ca_size_t count0 = count[0];
    ca_size_t i;
    for ( i = 0; i < count0; i++ ) {
      memcpy(dst, src, run_bytes);
      dst += step_p;
      src += step_i;
    }
    return;
  }

  total_slabs = 1;
  for ( k = 0; k < outer_axes; k++ ) {
    total_slabs *= count[k];
  }

  for ( slab = 0; slab < total_slabs; slab++ ) {
    memcpy(parent_ptr + parent_off, in_ptr + input_off, run_bytes);

    for ( k = outer_axes - 1; k >= 0; k-- ) {
      idx[k]++;
      parent_off += parent_strides[k];
      input_off  += input_strides[k];
      if ( idx[k] < count[k] ) break;
      parent_off -= parent_strides[k] * count[k];
      input_off  -= input_strides[k] * count[k];
      idx[k] = 0;
    }
  }
}

/* --------------------------------------------------------------------- */
/* ca_composite_fill_rect                                                 */
/*                                                                        */
/* Fill a rectangle sub-region of out_ptr with `fill_value` (broadcast). */
/* Mirrors _region_gather but with a fixed source value (no source       */
/* pointer/strides).  1D / 2D / N-D fast paths.                          */
/* --------------------------------------------------------------------- */

void
ca_composite_fill_rect (char *out_ptr,
                        const ca_size_t *output_strides,
                        const ca_size_t *offset,
                        const ca_size_t *count,
                        const char *fill_value,
                        ca_size_t bytes,
                        int8_t ndim)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t output_off, total_slabs, slab;
  int8_t    k;
  int8_t    outer_axes;
  ca_size_t inner_count;

  /* Initial byte offset into output. */
  output_off = 0;
  for ( k = 0; k < ndim; k++ ) {
    output_off += offset[k] * output_strides[k];
    idx[k] = 0;
  }

  /* Innermost axis = SIMD typed fill of `count[ndim-1]` cells per slab. */
  inner_count = count[ndim - 1];
  outer_axes = ndim - 1;

  /* Early exit on empty inner. */
  if ( inner_count <= 0 ) return;

  if ( outer_axes <= 0 ) {
    /* 1-D: single typed-fill. */
    ca_fill_typed(out_ptr + output_off, fill_value, bytes, inner_count);
    return;
  }

  if ( outer_axes == 1 ) {
    /* 2-D fast path. */
    ca_size_t step_o = output_strides[0];
    ca_size_t count0 = count[0];
    if ( count0 <= 0 ) return;
    /* Contig-in-output detection: if successive "rows" of the strip
       are adjacent in output memory (= step_o == inner_count * bytes),
       merge into a single big typed-fill so SIMD bandwidth is fully used.
       For complement-fill axis-0 strips this case fires (= the strip spans
       the full inner extent of output along the rows it covers). */
    if ( step_o == inner_count * bytes ) {
      ca_fill_typed(out_ptr + output_off, fill_value, bytes,
                    count0 * inner_count);
      return;
    }
    /* Generic per-row fill. */
    {
      char     *dst = out_ptr + output_off;
      ca_size_t i;
      for ( i = 0; i < count0; i++ ) {
        ca_fill_typed(dst, fill_value, bytes, inner_count);
        dst += step_o;
      }
    }
    return;
  }

  /* General N-D path (ndim >= 3): collapse all trailing axes whose
     count == output_dim (= step matches contig stride) into the inner
     run, walk only the truly outer axes via multi-dim cursor. */
  {
    int8_t   walk_axes = outer_axes;
    ca_size_t merged_inner = inner_count;
    while ( walk_axes > 0
         && output_strides[walk_axes - 1] == merged_inner * bytes
         && count[walk_axes - 1] > 0 ) {
      merged_inner *= count[walk_axes - 1];
      walk_axes--;
    }

    if ( walk_axes == 0 ) {
      /* Whole strip is contig in output. */
      ca_fill_typed(out_ptr + output_off, fill_value, bytes, merged_inner);
      return;
    }

    total_slabs = 1;
    for ( k = 0; k < walk_axes; k++ ) {
      if ( count[k] <= 0 ) return;
      total_slabs *= count[k];
    }

    for ( slab = 0; slab < total_slabs; slab++ ) {
      ca_fill_typed(out_ptr + output_off, fill_value, bytes, merged_inner);

      for ( k = walk_axes - 1; k >= 0; k-- ) {
        idx[k]++;
        output_off += output_strides[k];
        if ( idx[k] < count[k] ) break;
        output_off -= output_strides[k] * count[k];
        idx[k] = 0;
      }
    }
  }
}

/* --------------------------------------------------------------------- */
/* ca_composite_fill_complement                                           */
/*                                                                        */
/* Fill the complement of an alias rectangle.  Enumerates up to 2*ndim    */
/* disjoint strips and calls _fill_rect for each non-empty strip.        */
/*                                                                        */
/* Strip k "before": alias range on dims 0..k-1,                          */
/*                   [0..alias_offset[k]) on dim k,                       */
/*                   full [0..output_dim[i]) on dims k+1..ndim-1          */
/* Strip k "after":  alias range on dims 0..k-1,                          */
/*                   [alias_offset[k]+alias_count[k]..output_dim[k])      */
/*                   on dim k,                                            */
/*                   full on dims k+1..ndim-1                             */
/*                                                                        */
/* Strips are pairwise disjoint and together cover output minus alias.    */
/* Caller must ensure alias rectangle is within output bounds.            */
/* --------------------------------------------------------------------- */

void
ca_composite_fill_complement (char *out_ptr,
                              const ca_size_t *output_strides,
                              const ca_size_t *output_dim,
                              const ca_size_t *alias_offset,
                              const ca_size_t *alias_count,
                              const char *fill_value,
                              ca_size_t bytes,
                              int8_t ndim)
{
  ca_size_t strip_offset[CA_RANK_MAX];
  ca_size_t strip_count[CA_RANK_MAX];
  int8_t k, m;

  for ( k = 0; k < ndim; k++ ) {
    ca_size_t a_off = alias_offset[k];
    ca_size_t a_cnt = alias_count[k];
    ca_size_t a_end = a_off + a_cnt;

    /* "Before" strip on axis k:
         dims 0..k-1:    alias range
         dim k:          [0..a_off)
         dims k+1..N-1:  full output extent */
    if ( a_off > 0 ) {
      for ( m = 0; m < k; m++ ) {
        strip_offset[m] = alias_offset[m];
        strip_count[m]  = alias_count[m];
      }
      strip_offset[k] = 0;
      strip_count[k]  = a_off;
      for ( m = k + 1; m < ndim; m++ ) {
        strip_offset[m] = 0;
        strip_count[m]  = output_dim[m];
      }
      ca_composite_fill_rect(out_ptr, output_strides,
                             strip_offset, strip_count,
                             fill_value, bytes, ndim);
    }

    /* "After" strip on axis k:
         dims 0..k-1:    alias range
         dim k:          [a_end..output_dim[k])
         dims k+1..N-1:  full output extent */
    if ( a_end < output_dim[k] ) {
      for ( m = 0; m < k; m++ ) {
        strip_offset[m] = alias_offset[m];
        strip_count[m]  = alias_count[m];
      }
      strip_offset[k] = a_end;
      strip_count[k]  = output_dim[k] - a_end;
      for ( m = k + 1; m < ndim; m++ ) {
        strip_offset[m] = 0;
        strip_count[m]  = output_dim[m];
      }
      ca_composite_fill_rect(out_ptr, output_strides,
                             strip_offset, strip_count,
                             fill_value, bytes, ndim);
    }
  }
}
