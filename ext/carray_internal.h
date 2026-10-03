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
   against.

   A region that can raise -- one that transfers from a view, or calls Ruby
   through an object lane -- goes through ca_lazy_arena_protect, never a
   bare _enter / _exit pair: a skipped _exit is process-wide. */

void    ca_lazy_arena_enter   (void);
void    ca_lazy_arena_exit    (void);
void   *ca_lazy_arena_acquire (ca_size_t bytes);
void   *ca_lazy_arena_acquire_object (ca_size_t n_elements);
void    ca_lazy_arena_release (void *ptr);
VALUE   ca_lazy_arena_protect (VALUE (*body)(VALUE),
                               VALUE (*cleanup)(VALUE), VALUE arg);
VALUE   ca_lazy_arena_release_held (VALUE arg);

/* ---- CA_OBJECT GC guard (carray_lazy.c) ----------------------------------

   A CA_OBJECT cell is a VALUE, and a materialise writes those cells into a
   buffer no Ruby object owns.  Object-lane kernels call rb_funcall per cell,
   so a collection can happen halfway through and free what has been written
   so far.  Hold the buffer while it is exposed like that, and after the
   materialise until a Ruby object takes ownership of it.

   The cells must already be valid VALUEs, so a fresh buffer is Qnil-filled
   before it is held.  ca_gc_hold_push returns the depth to hand back to
   ca_gc_hold_pop_to, so nested holds unwind in order. */

int     ca_gc_hold_push   (void *ptr, ca_size_t n_elements);
void    ca_gc_hold_pop_to (int depth);

/* A buffer of object cells whose lifetime is not nested in the others' --
   a kernel iterator's scratch lives from init to finish, and two walks
   opened together may close in either order.  Registered buffers are
   marked until released, in any order; releasing one that was never
   registered does nothing.  The cells must be valid VALUEs when it is
   registered. */
void    ca_gc_hold_buffer    (void *ptr, ca_size_t n_elements);
void    ca_gc_release_buffer (void *ptr);

/* Copy the attributes src shows onto dst (a new entity with src's values). */
void    rb_ca_inherit_attr (VALUE dst, VALUE src);

/* ---- Attaching several parents (carray_core.c) ---------------------------

   ca_attach_all attaches all of list[0..n-1] or none: if one attach raises,
   those already attached are detached before the raise propagates.

   ca_sync_all syncs every one of list[0..n-1], carrying on past one that
   raises so that the others still receive what was written, and raises
   the first exception once all have been tried.

   ca_attach_window opens list[0..n-1] ('r' attach, 'w' attach + sync,
   'a' allocate + sync), runs body(arg), and closes every array however body
   leaves.  Any window inside which Ruby runs or something raises goes
   through it; see the definition for what a raise does to 'w' and 'a'. */

void    ca_attach_all (CArray **list, int32_t n);
void    ca_sync_all   (CArray **list, int32_t n);
VALUE   ca_attach_window (int32_t n, CArray **list, const char *modes,
                          VALUE (*body)(VALUE), VALUE arg);

/* ---- Filling a result Ruby does not own yet (carray_copy.c) ---------------

   A C builder that allocates its result with carray_new / ca_template and
   then reads the source into it holds a struct no Ruby object owns until
   ca_wrap_struct.  A read that raises (a lazy conversion) would leave it
   behind.  ca_fill_or_free runs fill(arg) under rb_protect and, if it
   raises, frees `co` before the raise propagates. */

void    ca_fill_or_free (CArray *co, VALUE (*fill)(VALUE), VALUE arg);

/* Non-zero iff the object is an element-wise lazy view (CAMonOp / CABinOp /
   CABinCmp / CAMonCmp / CALazyMarker).  The streaming branch of the
   mkkernel-generated reduction kernels tests this to decide whether it can
   consume the source without materialising it. */

int     ca_is_lazy_view (void *ap);

/* The mask of an element-wise lazy operation over several operands
   (CABinOp, CABinCmp, CATriOp), computed from the operands' masks on each
   read so that it follows them as the values do; NULL when no operand has
   a mask yet.  `mode` is CA_LAZY_MASK_OR, or one of the KLEENE modes for
   the boolean `|` and `&`, whose masked cells an unmasked operand can
   decide (carray_lazy.c). */

#define CA_LAZY_MASK_OR           0
#define CA_LAZY_MASK_KLEENE_OR    1
#define CA_LAZY_MASK_KLEENE_AND   2

CArray *ca_lazy_operation_mask (CArray *operation, int mode);

/* The registered expression evaluator's answer for a lazy expression the
   caller is about to compute whole, or Qnil to go on with self (see
   carray_lazy.c). */

VALUE   ca_lazy_evaluated (VALUE self);

/* A request to an element-wise lazy view (CAMonOp, CABinOp, CAMonCmp,
   CABinCmp, CATriOp): either a region of the view's addresses -- the
   xfer_stride form, strides in bytes of the view's cells -- or a list of
   addresses.  The view answers either with one evaluation: it pulls each
   operand over the same cells with ca_lazy_req_pull and runs its kernel
   once over the n cells (carray_lazy.c). */

typedef struct {
  ca_size_t  n;
  ca_size_t *addrs;                       /* list form when non-NULL */
  ca_size_t *starts, *counts, *strides;   /* region form */
  ca_size_t  bytes;                       /* cell width the strides use */
  int8_t     ndim;
} ca_lazy_req_t;

void    ca_lazy_req_region (ca_lazy_req_t *req, void *view, ca_size_t *starts,
                            ca_size_t *counts, ca_size_t *strides);
void    ca_lazy_req_addrs  (ca_lazy_req_t *req, ca_size_t n, ca_size_t *addrs);
int     ca_lazy_req_is_packed (const ca_lazy_req_t *req, void *view);
void    ca_lazy_req_pull   (void *operand, const ca_lazy_req_t *req,
                            void *buf, int dir);
boolean8_t *ca_lazy_req_mask (const ca_lazy_req_t *req, int n, CArray **ops);
VALUE   ca_lazy_settle_scalar (VALUE operand, int was_scalar);

/* Non-zero iff the array a view's cells come from -- the parent, or the
   root a CAStride-family parent folds to -- computes them rather than
   lending memory (ca_obj_stride.c).  Depends only on what the arrays are,
   never on whether they are attached, so the attach / sync / detach slots
   of one view all take the same branch. */

int     ca_parent_lends_no_memory (void *ap);

/* Transfers of the descriptor views (CAGrid, CASelect, CASelectAxis,
   CAWindow) whose parent holds no ptr (ca_axis_dispatch.c).

   ca_axis_view_xfer_all serves an xfer_all slot: `fast` is the view's
   transfer against parent->ptr, and region_ok says whether the view's
   xfer_stride answers a whole-view request without going cell by cell.
   ca_axis_view_attach_owned / ca_axis_view_sync_owned are the attach and
   sync of such a view over a parent with no memory to lend: the view owns
   its buffer and the parent is never attached.  attach_owned also serves
   any view that owns its buffer and fills it through its own transfers
   (CARemap, CAStack, CAMeld): it publishes the buffer only once filled. */

typedef void (*ca_axis_view_fast_t) (void *ap, char *data, int dir);

void    ca_axis_view_xfer_all     (void *ap, ca_axis_view_fast_t fast,
                                   int region_ok, void *data, int dir);
void    ca_axis_view_attach_owned (void *ap);
void    ca_axis_view_sync_owned   (void *ap);

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
/* An owned, unmasked copy of a boolean selector: a masked cell becomes
   false.  Shared by CASelect and CASelectAxis. */
CArray  *ca_select_snapshot (CArray *select);

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

/* ca_obj_reduce.c */
CAReduce *ca_reduce_new (CArray *carray, ca_size_t count, ca_size_t offset);

/* carray_broadcast.c */
void     ca_broadcast_to_destination (VALUE dst, volatile VALUE *src);

/* carray_utils.c */
const char *ca_calling_method_name (void);
long        ca_integer_arg (VALUE v, const char *arg, const char *name);
long        ca_axis_integer (VALUE raxis, const char *name);
VALUE       ca_fill_as (VALUE fill, int8_t data_type);
/* ---- Face MemoryView export (ca_obj_face.c) -------------------------------

   A Face registers 1 when its storage bytes carry its values without the
   Face (CARecord, CAFixlenString); the MemoryView producer refuses every
   other Face.  Unregistered Faces are refused. */

void    ca_face_register_memory_view (int obj_type, int exportable);
int     ca_face_memory_view_exportable (CArray *ca);

/* ---- Empty regions ---------------------------------------------------------

   A region with a zero count on some axis has no cells.  The per-cell walks
   visit their first cell before they test the counts, so every region
   transfer returns on an empty region before it walks: a zero-cell caller
   buffer has no room for that first cell. */

static inline int
ca_region_is_empty (int8_t ndim, const ca_size_t *counts)
{
  int8_t k;
  for ( k = 0; k < ndim; k++ ) {
    if ( counts[k] <= 0 ) return 1;
  }
  return 0;
}

VALUE       ca_reduce_fill (VALUE result, VALUE fill, int whole);
int         ca_symbol_choice (VALUE v, const char *arg, const char *c0,
                              const char *c1, const char *name);

#endif /* CARRAY_INTERNAL_H */
