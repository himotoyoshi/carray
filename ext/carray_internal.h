/* ---------------------------------------------------------------------------

  carray_internal.h -- declarations that are only ever called by CArray's
  own translation units, kept out of the public surface.

  carray.h is what a downstream gem gets from `#include "carray.h"`, so
  everything it declares is a contract.  Symbols with no external caller
  live here instead, and are moved in one audited cluster at a time (see
  devel/PROPOSAL_CARRAY_H_REORG.md for the layering and the backlog).

  This header is NOT installed (see ext/extconf.rb $INSTALLFILES) and must
  NOT be included by carray.h -- including it there would put every symbol
  below straight back into the public closure.  Wiring is per-move: a .c
  gains `#include "carray_internal.h"` when it consumes a symbol that has
  landed here.

  Some internal clusters keep their own non-installed header rather than
  folding in (ca_sort_kernels.h, ca_op_powi.h, ca_composite_dispatch.h);
  what matters is only that they stay out of carray.h and out of the
  install list.

---------------------------------------------------------------------------- */

#ifndef CARRAY_INTERNAL_H
#define CARRAY_INTERNAL_H

#include "carray.h"

/* ---- bulk bit pack / unpack (ca_obj_bitarray.c) --------------------------

   Drive the CABitarray whole-view xfer_all / xfer_addrs fast paths, which
   read or write every bit of the parent in one pass instead of going
   through per-element fetch.

   multibyte_byteswap = 1 walks the bytes within each parent element in
   reverse (big-endian network byte order); pbytes = 1 ignores the flag
   (the walk is linear either way).  Bit order within a byte is LSB-first
   and is NOT configurable -- both directions assume it, so changing one
   without the other silently transposes every bit. */

void ca_bit_unpack (const uint8_t *src, ca_size_t elements, ca_size_t pbytes,
                    int multibyte_byteswap, boolean8_t *dst);
void ca_bit_pack   (const boolean8_t *src, ca_size_t elements, ca_size_t pbytes,
                    int multibyte_byteswap, uint8_t *dst);

/* ---- lazy arena (carray_lazy.c) ------------------------------------------

   Slot-pool scratch reuse for the CAMonOp / CABinOp materialise paths, so a
   chain of lazy views does not xmalloc a fresh buffer per link.  _enter and
   _exit bracket a region in which _acquire may hand back a pooled buffer;
   outside such a region _acquire falls back to a plain allocation.  See
   ext/carray_lazy.c for the pool semantics.

   The pool is global static state, so this is single-owner by construction.
   Thread-safety is a non-goal: operating on one array family from more than
   one thread is the caller's responsibility, not something this pool guards
   against. */

void    ca_lazy_arena_enter   (void);
void    ca_lazy_arena_exit    (void);
void   *ca_lazy_arena_acquire (ca_size_t bytes);
void    ca_lazy_arena_release (void *ptr);

/* Non-zero iff the object is an element-wise lazy view (CAMonOp / CABinOp /
   CABinCmp / CAMonCmp / CALazyMarker).  The streaming branch of the
   mkkernel-generated reduction kernels tests this to decide whether it can
   consume the source without materialising it. */

int     ca_is_lazy_view (void *ap);

/* ---- per-obj_type view constructors --------------------------------------

   Constructors for view types that only carray itself builds.  Ruby-side
   construction goes through the indexer and the view methods, and no ext
   author has been given a reason to reach for these from C.

   The constructors that DO belong to the ext-author surface stay in
   carray.h and are not repeated here: ca_wrap_new / rb_ca_wrap_new (adopt
   external memory), ca_stride_setup / ca_stride_new / rb_ca_stride_new
   (author a strided view -- see devel/CAStride.md), and ca_refer_new /
   rb_ca_refer_new (reinterpret / re-mask, which a bridge gem does use). */

/* ca_obj_block.c */
CABlock *ca_block_new (CArray *carray,
                       int8_t ndim, ca_size_t *dim,
                       ca_size_t *start, ca_size_t *step, ca_size_t *count,
                       ca_size_t offset);
VALUE    rb_ca_block_new (VALUE cary, int8_t ndim, ca_size_t *dim,
                       ca_size_t *start, ca_size_t *step, ca_size_t *count,
                       ca_size_t offset);
/* Recompute base_offset from offset/start/size0/bytes after a caller has
   mutated start[] in place; the prefix goes stale otherwise and the view
   silently reads the wrong cells. */
void     ca_block_sync_base_offset (CABlock *cb);

/* ca_obj_select.c */
VALUE    rb_ca_select_new (VALUE cary, VALUE select);
VALUE    rb_ca_select_new_share (VALUE cary, VALUE select);

/* ca_obj_mapping.c */
VALUE    rb_ca_mapping_new (VALUE cary, CArray *mapper);

/* ca_obj_field.c */
VALUE    rb_ca_field_new (VALUE cary,
                          ca_size_t offset, int8_t data_type, ca_size_t bytes);

/* ca_obj_fake.c */
VALUE    rb_ca_fake_new (VALUE cary, int8_t data_type, ca_size_t bytes);

/* ca_obj_repeat.c */
CARepeat *ca_repeat_new (CArray *carray, int8_t ndim, ca_size_t *count);
VALUE     rb_ca_repeat_new (VALUE cary, int8_t ndim, ca_size_t *count);

/* ca_obj_unbound_repeat.c */
VALUE    rb_ca_ubrep_new (VALUE cary, int32_t rep_ndim, ca_size_t *rep_dim);

/* ca_obj_reduce.c */
CAReduce *ca_reduce_new (CArray *carray, ca_size_t count, ca_size_t offset);

#endif /* CARRAY_INTERNAL_H */
