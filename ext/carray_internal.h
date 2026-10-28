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
#include <math.h>     /* isnan, for CA_OBJ_ISNAN */

/* ---- properties a copy or a folded view must carry (ca_obj_refer.c) -------

   Copies VALUE_ARRAY (dropping any mask), READ_ONLY and MASK_ARRAY from
   `src` onto `view` when `src` has them, for arrays whose C parent chain
   does not pass through `src`.  Used by the folded reshape / flatten and by
   CArray#initialize_dup / #initialize_clone. */
void ca_keep_chain_flags (CArray *view, CArray *src);

/* A reshape / flatten folded onto the root of its source (CA_FLAG_FOLDED,
   ca_obj_refer.c).  The source is not on the view's C parent chain, so a
   read-only flag it takes after the view is made would not be seen by
   ca_is_readonly.  The view records its source here; ca_is_readonly asks the
   source of a view that carries the flag.  The source stays alive while the
   view does (the view's @parent).  ca_fold_source answers NULL for a view
   with no record; ca_fold_forget drops the record when the view is freed. */
#define CA_FLAG_FOLDED 8192
void    ca_fold_note_source (CArray *view, CArray *src);
CArray *ca_fold_source (CArray *view);
void    ca_fold_forget (CArray *view);

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

/* Object cells are marked strictly (rb_gc_mark, which trusts what it is
   given) as soon as anything can see their buffer: a view's ca->ptr from
   the moment it is set (ca_mark), a held buffer from the moment it is held.
   A fresh buffer that will carry object cells is therefore filled with
   valid VALUEs before it is published, whether or not the code that fills
   it can call Ruby.  A buffer for an array's cells is allocated with
   ca_alloc_cells; other fresh VALUE buffers are cleared with
   ca_object_cells_clear before they are held.  utils/check_cell_buffers.rb
   finds a ptr allocated any other way. */
static inline void
ca_object_cells_clear (void *ptr, ca_size_t n_elements)
{
  VALUE *p = (VALUE *) ptr;
  while ( n_elements-- > 0 ) {
    *p++ = Qnil;
  }
}

/* A boolean cell holds 0 or 1.  Bytes copied in from outside (a String or
   an IO through load_binary, a MemoryView) are read as true when non-zero,
   so every reader of the array sees one value; an array that shares
   another's bytes cannot be held to this, and is refused instead. */
static inline void
ca_boolean_normalize_bytes (void *ptr, ca_size_t n)
{
  uint8_t *p = (uint8_t *) ptr;
  for ( ca_size_t i = 0; i < n; i++ ) {
    p[i] = ( p[i] != 0 );
  }
}

static inline char *
ca_alloc_cells (const CArray *ca)
{
  char *p = (char *) xmalloc(ca_length(ca));
  if ( ca->data_type == CA_OBJECT ) {
    ca_object_cells_clear(p, ca->elements);
  }
  return p;
}

/* Copy the attributes src shows onto dst (a new entity with src's values). */
void    rb_ca_inherit_attr (VALUE dst, VALUE src);

/* Give a dup / clone its own attribute Hash. */
void    rb_ca_own_attr (VALUE self);

/* Record the Face a lifted view was taken from, for the attribute walk. */
void    rb_ca_set_lifted_from (VALUE lifted, VALUE face);

/* A String read as a decimal number of an integer or float data_type
   (carray_cast.c): _to answers 1 / 0 (UNDEF), _store raises. */
int     ca_decimal_string_to (VALUE str, int8_t data_type, void *out);
void    ca_decimal_string_store (VALUE str, int8_t data_type, void *out);

/* Give `ca` a mask holding `m` (one byte per cell) when any cell is set,
   and leave it without one otherwise. */
static inline void
ca_mask_from_bytes (CArray *ca, const boolean8_t *m)
{
  ca_size_t i;
  for (i = 0; i < ca->elements; i++) {
    if ( m[i] ) {
      ca_create_mask(ca);
      memcpy(ca->mask->ptr, m, ca->elements);
      return;
    }
  }
}

/* ---- Attaching several parents (carray_core.c) ---------------------------

   ca_attach_all attaches all of list[0..n-1] or none: if one attach raises,
   those already attached are detached before the raise propagates.

   ca_sync_all syncs every one of list[0..n-1], carrying on past one that
   raises so that the others still receive what was written, and raises
   the first exception once all have been tried.  ca_sync_all_attached
   does the same for those of them that have a buffer out.

   ca_attach_window opens list[0..n-1] ('r' attach, 'w' attach + sync,
   'a' allocate + sync), runs body(arg), and closes every array however body
   leaves.  Any window inside which Ruby runs or something raises goes
   through it; see the definition for what a raise does to 'w' and 'a'. */

void    ca_attach_all (CArray **list, int32_t n);
void    ca_sync_all   (CArray **list, int32_t n);
void    ca_sync_all_attached (CArray **list, int32_t n);
VALUE   ca_attach_window (int32_t n, CArray **list, const char *modes,
                          VALUE (*body)(VALUE), VALUE arg);

/* A window that yields to a block can be left open for good: Ruby does not
   run the ensure of a suspended Fiber that is collected (an Enumerator
   stopped with #next and dropped).  ca_window_guard_arm makes a guard that
   runs cleanup(arg) from a finalizer when that happens; the window disarms
   it when it closes normally.  arg is heap memory the guard frees, and
   mark marks the VALUEs it holds.  ca_attach_window_yielding is
   ca_attach_window with such a guard; owners keeps the arrays alive. */
VALUE   ca_window_guard_arm (void (*cleanup)(void *), void (*mark)(void *),
                             void *arg, VALUE *sentinel);
void    ca_window_guard_disarm (VALUE guard, VALUE sentinel);
VALUE   ca_attach_window_yielding (VALUE owners, int32_t n, CArray **list,
                                   const char *modes, VALUE (*body)(VALUE),
                                   VALUE arg);

/* ---- Filling a result Ruby does not own yet (carray_copy.c) ---------------

   A C builder that allocates its result with carray_new / ca_template and
   then reads the source into it holds a struct no Ruby object owns until
   ca_wrap_struct.  A read that raises (a lazy conversion) would leave it
   behind.  ca_fill_or_free runs fill(arg) under rb_protect and, if it
   raises, frees `co` before the raise propagates. */

void    ca_fill_or_free (CArray *co, VALUE (*fill)(VALUE), VALUE arg);

/* The same for what else a step that can raise leaves behind: a buffer
   that belongs to nothing yet (freed with xfree), or arrays the caller
   attached for the step (each detached once).  A hand-written rb_protect
   outside the files that implement these parts says why it is not one
   of them; utils/check_protect_parts.rb finds one that does not. */

void    ca_fill_or_xfree  (void *buf, VALUE (*fill)(VALUE), VALUE arg);
void    ca_fill_or_detach (int n, CArray **list, VALUE (*fill)(VALUE), VALUE arg);

/* A view takes its parent's mask by asking the parent whether it has one,
   and a parent that is a CAObject answers in Ruby and can raise.  A view's
   setup therefore does not ask: its constructor calls this under
   ca_fill_or_free once the struct holds everything the setup allocated,
   and an initialize_copy, whose struct Ruby already owns, calls it
   directly.  `view` is the CArray * cast to VALUE. */

VALUE   ca_view_inherit_mask (VALUE view);

/* Whether a CAGrid has a hole: a position whose index cell was masked,
   which selects no parent cell.  The descriptor engine has no hole, so
   such a grid is delivered through its own transfers. */
int     ca_grid_has_holes (void *ap);

/* The same for the mask a CAWindow / CAShift with an axis of MASK bounds
   makes for itself (ca_obj_window.c). */

VALUE   ca_window_create_bounds_mask (VALUE view);

/* ca_stride_setup without asking the parent for its mask; see
   ca_view_inherit_mask.  The in-tree subclasses use this. */

int     ca_stride_setup_view (CAStride *ca, int8_t obj_type, CArray *parent,
                              int8_t data_type, ca_size_t bytes,
                              int8_t ndim, ca_size_t *dim,
                              ca_size_t *strides, ca_size_t base_offset);

/* Non-zero iff the object is an element-wise lazy view (CAMonOp / CABinOp /
   CABinCmp / CAMonCmp / CALazyMarker).  The streaming branch of the
   mkkernel-generated reduction kernels tests this to decide whether it can
   consume the source without materialising it. */

int     ca_is_lazy_view (void *ap);

/* The mask of an element-wise lazy operation over several operands
   (CABinOp, CABinCmp, CATriOp), computed from the operands' masks on each
   read so that it follows them as the values do; NULL when no operand has
   a mask yet.  `mode` is CA_LAZY_MASK_OR, one of the KLEENE modes for
   the boolean `|` and `&`, whose masked cells an unmasked operand can
   decide, or CA_LAZY_MASK_SELECT for select, masked where its condition
   is or where the branch the condition chooses is (carray_lazy.c). */

#define CA_LAZY_MASK_OR           0
#define CA_LAZY_MASK_KLEENE_OR    1
#define CA_LAZY_MASK_KLEENE_AND   2
#define CA_LAZY_MASK_SELECT       3

CArray *ca_lazy_operation_mask (CArray *operation, int mode);

/* The array whose memory a view's cells live in: the entity at the end of
   its parent chain, or the first view that has several parents
   (carray_attribute.c). */
CArray *ca_root_array (void *ap);

/* Whether two arrays' cells live in the same root (carray_attribute.c). */
int ca_shares_root (void *ap, void *aq);

/* The create_mask slot of a view whose cells map one-to-one onto its
   parent's in address order: the mask is the parent's mask seen in the
   view's shape (carray_mask.c).  Installed directly in operation tables. */

void    ca_view_func_create_mask (void *ap);
void    ca_view_sync_mask_after_parent (void *ap);
void    ca_view_pass_mask_to_parent (void *ap);

/* Running count of the present cells of any data type along axis (Qnil:
   the flattened array), read off the mask alone (carray_mask.c).  The
   cumcount kernel answers with it for a data type it does not load. */

VALUE   rb_ca_scan_mask_count (VALUE self, VALUE axis);

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

/* Runs eval(node, req, data, dir), the evaluation of a lazy node over the
   cells req names.  When the node or one of its operands ops[0..n) is an
   object array, the evaluation calls Ruby on each cell, and a cell holding
   an expression over the node comes back into it: the node, and the nodes
   of its chain in chain[0..nchain), are then recorded as computed over
   (ca_computing_run_nodes), so coming back is refused as cyclic.  The
   operands are not recorded: an expression over the same operand that does
   not need the node is no cycle.  Otherwise eval runs as it is. */
typedef void (*ca_lazy_eval_fn) (void *node, const ca_lazy_req_t *req,
                                 void *data, int dir);
void    ca_lazy_eval_recorded (void *node, int n, CArray **ops,
                               int nchain, CArray **chain,
                               ca_lazy_eval_fn eval, const ca_lazy_req_t *req,
                               void *data, int dir);
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
VALUE    rb_ary_flatten_for_elements (VALUE ary, ca_size_t elements, void *ap);

/* carray_utils.c */
const char *ca_calling_method_name (void);
VALUE       ca_answer_as_caller (VALUE (*body)(VALUE), VALUE arg);
long        ca_integer_arg (VALUE v, const char *arg, const char *name);
/* 1 with the position of an index key (an Integer, or a Float with no
   fraction while exact), 2 for an Integer past int64, 0 otherwise. */
int         ca_index_key_position (VALUE v, ca_size_t *out);
void        ca_refuse_without_common_type (VALUE self, VALUE other);
ca_size_t   ca_shape_elements (int8_t ndim, const ca_size_t *dim, ca_size_t bytes);
void        ca_check_index_array (VALUE v);
VALUE       ca_order_key (VALUE v, const char *name);
void        ca_check_integer_fits (VALUE v, int8_t data_type);
VALUE       ca_obj2integer_fitting (VALUE v, int8_t data_type);
int         ca_integer_range_side (VALUE v, int8_t data_type);
int         ca_bincmp_integer_prepare (volatile VALUE *self, volatile VALUE *other,
                                       int op_id, int *signed_side);
int         ca_bincmp_answer_when_negative (int op_id, int signed_side);
long        ca_axis_integer (VALUE raxis, const char *name);
/* Refuse a write into a read-only array that is not frozen (carray_test.c);
   every guard calls this rather than raising its own. */
NORETURN(void ca_refuse_read_only (void));
/* Refuse an operator with no kernel for `data_type`, naming the method and
   the type (carray_operator.c); the eager operators and the lazy builders. */
NORETURN(void ca_op_refuse_unimplemented (VALUE operand, int8_t data_type,
                                          VALUE eclass));
/* Refuse a rank above CA_RANK_MAX before any dim is written (carray_utils.c). */
void        ca_check_rank_fits (long ndim, const char *name);
/* The checks of carray.h inside the library, each naming the method the
   user called; the public ones stay as they are for extensions. */
/* A wrap of a caller's buffer lent to a CAObject hook (CA_FLAG_LENT), and
   the mark that a view was taken of it while it was lent
   (CA_FLAG_LENT_VIEWED).  rb_ca_set_parent sets the second; the hook's
   caller reads both when it takes the buffer back (ca_obj_object.c). */
#define CA_FLAG_LENT        2048
#define CA_FLAG_LENT_VIEWED 4096

/* A computation over object arrays.  A cell whose value is the array
   itself or a view of it makes the kernel call back into a computation
   over the same cells; entering an array that the same method is already
   computing over, in this thread and fiber, is refused as cyclic, as
   reading such a cell is (ca_test_cyclic_check).  ca_computing_run runs
   body(arg) with the object arrays among ops[0..n) recorded
   (rb_exec_recursive, carray_core.c); nothing is written to the arrays. */
VALUE ca_computing_run (int n, CArray **ops, VALUE (*body)(VALUE), VALUE arg);
VALUE ca_computing_run_nodes (int n, CArray **ops, VALUE (*body)(VALUE), VALUE arg);
/* Refuses as cyclic a cell among cells[0..n) that is an array reaching a
   lazy node being evaluated: computing it would come back into the node. */
void  ca_refuse_cells_reaching_evaluation (ca_size_t n, const VALUE *cells);

/* Registers a view type whose transfers only move cells between its parents
   and the caller (an index view: CAGrid, CASelect, CAWindow, CAStack, ...),
   calling no Ruby.  A transfer through such views down to entities cannot
   come back into an array, and is not recorded (ca_with_cyclic_check). */
void ca_register_cell_moving_view (int8_t obj_type);
VALUE ca_iter_ensure_computing (CArray *ca, int32_t n, ca_iter_state *states,
                                VALUE (*body)(VALUE), VALUE arg);

#define CA_CHECK_DATA_TYPE_GIVEN(data_type) \
  do { \
    int ca_dt_ = (data_type); \
    if ( ca_dt_ <= CA_NONE || ca_dt_ >= CA_NTYPE ) { \
      rb_raise(rb_eArgError, "%s: invalid data_type id %i", \
               ca_calling_method_name(), ca_dt_); \
    } \
    if ( ! ca_valid[ca_dt_] ) { \
      rb_raise(rb_eCADataTypeError, "%s: data_type %s is disabled", \
               ca_calling_method_name(), ca_type_name[ca_dt_]); \
    } \
  } while (0)

#define CA_CHECK_DIM_GIVEN(ndim, dim) \
  do { \
    int8_t i_; \
    for (i_ = 0; i_ < (ndim); i_++) { \
      if ( (dim)[i_] < 0 ) { \
        rb_raise(rb_eArgError, "%s: negative size dimension at %i-dim", \
                 ca_calling_method_name(), i_); \
      } \
    } \
  } while (0)

#define CA_CHECK_BYTES_GIVEN(data_type, bytes) \
  do { \
    if ( (data_type) == CA_FIXLEN ) { \
      if ( (bytes) <= 0 ) { \
        rb_raise(rb_eArgError, \
                 "%s: invalid bytes (a fixlen needs bytes: of 1 or more)", \
                 ca_calling_method_name()); \
      } \
    } \
    else { \
      (bytes) = ca_sizeof[(data_type)]; \
      if ( (bytes) <= 0 ) { \
        rb_raise(rb_eArgError, "%s: invalid bytes", ca_calling_method_name()); \
      } \
    } \
  } while (0)

/* CA_CHECK_RANK inside the library: no axes at all is no shape, and above
   CA_RANK_MAX goes to the part, which names the method.  The public macro
   stays as it is for extensions. */
#define CA_CHECK_RANK_GIVEN(ndim) \
  do { \
    long ca_nd_ = (long) (ndim); \
    if ( ca_nd_ <= 0 ) { \
      rb_raise(rb_eArgError, "invalid ndim"); \
    } \
    ca_check_rank_fits(ca_nd_, NULL); \
  } while (0)
/* An `axis` argument as an axis in [0, ndim): the rule every entry taking
   an axis from Ruby calls (carray_utils.c). */
int         ca_normalize_axis_arg (VALUE raxis, int ndim, const char *name);
VALUE       ca_fill_as (VALUE fill, int8_t data_type);
/* ---- Face MemoryView export (ca_obj_face.c) -------------------------------

   A Face registers 1 when its storage bytes carry its values without the
   Face (CARecord, CAFixlenString); the MemoryView producer refuses every
   other Face.  Unregistered Faces are refused. */

void    ca_face_register_memory_view (int obj_type, int exportable);
int     ca_face_memory_view_exportable (CArray *ca);

/* The reference and the operand of a comparison brought into one space (see
   ca_obj_face.c).  *pref may be replaced by a converted copy and stays a
   Face; the caller strips it. */
void    ca_face_reconcile_pair (volatile VALUE *pref, volatile VALUE *poperand,
                                const char *name);

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

/* ---- An index into n places ----------------------------------------------

   A negative index counts from the end; one outside 0...n after that raises
   IndexError, naming the method the user called, `what` the index is (an
   "index", an "address") and the value given.  Every index door decides
   this here. */

/* ca_index_out_of_range is declared in carray.h (CA_CHECK_INDEX uses it). */

static inline ca_size_t
ca_index_in_range (ca_size_t idx, ca_size_t n, const char *what)
{
  ca_size_t i = ( idx < 0 ) ? idx + n : idx;
  if ( i < 0 || i >= n ) {
    ca_index_out_of_range(idx, n, what);
  }
  return i;
}

/* The same for an index on axis `axis` of a multi-axis index. */
NORETURN(void ca_index_out_of_range_at (ca_size_t idx, ca_size_t n, int axis));

static inline ca_size_t
ca_index_in_range_at (ca_size_t idx, ca_size_t n, int axis)
{
  ca_size_t i = ( idx < 0 ) ? idx + n : idx;
  if ( i < 0 || i >= n ) {
    ca_index_out_of_range_at(idx, n, axis);
  }
  return i;
}

/* ---- How many cells a result cell needs ---------------------------------

   A reduction's result cell is UNDEF when fewer cells contribute to it than
   it needs.  It needs `least` cells -- 0 for an operation with an identity
   (sum, prod, accumulate, count, wsum: an empty cell is the identity), 1 for
   one without (mean, min, max, median, ...), 2 for a sample variance -- or
   `min_count` cells when that is given and asks for more.  A min_count below
   zero means it was not given.  Every reduction decides this here. */

static inline int
ca_too_few_present (ca_size_t present, ca_size_t min_count, ca_size_t least)
{
  return present < ( min_count > least ? min_count : least );
}

long        ca_min_count_arg (VALUE v, const char *name);
VALUE       ca_reduce_fill (VALUE result, VALUE fill, int whole);
int         ca_symbol_choice (VALUE v, const char *arg, const char *c0,
                              const char *c1, const char *name);

/* Return the value of `call`, keeping the array `v` reachable until the call
   has returned.  A kernel reads its source through the CArray pointer only,
   so a view made just to be passed in (a flattened or common-type view)
   would otherwise be left to a garbage collection that runs while its
   cells are read: `return kernel(v, ...)` lets the compiler drop `v`. */
#define CA_RETURN_KEEPING(v, call) do {  \
    VALUE ca_kept_result_ = (call);      \
    RB_GC_GUARD(v);                      \
    return ca_kept_result_;              \
  } while (0)

/* A NaN loses every contest of an extremum (min / max / minmax / the
   positions / the running cummin / cummax / pmin / pmax): it never displaces
   another value, the first number displaces it, and nothing but NaN answers
   NaN.  The two tests below are that rule for a typed cell and for an object
   cell (a stored Float NaN); each says whether `v` takes the place of the
   running `acc`.  CMP / op is `>` for a maximum, `<` for a minimum.  On an
   integer type `v == v` is always true and folds away. */

#define CA_EXTREMUM_REPLACES(v, acc, CMP) \
  ( (v) == (v) && ( !((acc) == (acc)) || (v) CMP (acc) ) )

#ifndef CA_OBJ_ISNAN
#define CA_OBJ_ISNAN(v) (RB_FLOAT_TYPE_P(v) && isnan(RFLOAT_VALUE(v)))
#endif

/* A pair `<=>` cannot order: ArgumentError "<method>: comparison of A with
   B failed", naming the method the user called.  Every object comparison
   that refuses a pair raises through here. */
NORETURN(void ca_obj_compare_refused (VALUE a, VALUE b));

/* The order of two object cells, by `<=>` as Array#min and #sort take it. */
static inline int
ca_obj_cmp (VALUE a, VALUE b)
{
  VALUE r = rb_funcall(a, rb_intern("<=>"), 1, b);
  if ( NIL_P(r) ) {
    ca_obj_compare_refused(a, b);
  }
  return rb_cmpint(r, a, b);
}

/* The order sort and every order statistic (partition, median,
   percentile, rank, nlargest, the search family) put cells in: a NaN
   after every number, NaN ties NaN.  Three-way (-1, 0, 1), ties not
   broken.  A descending order keeps NaN after the numbers too, so it
   negates only the comparison of two numbers.  ca_partition_nan_*
   (ca_sort_kernels.h) moves the NaN of a float buffer to its tail by
   the same rule; a new order kernel uses these and nothing of its own. */
#define CA_FLOAT_ORDER_CMP(a, b)                                     \
  ( isnan(a) ? ( isnan(b) ? 0 : 1 )                                  \
             : ( isnan(b) ? -1 : ( ( (a) > (b) ) - ( (a) < (b) ) ) ) )

/* The same order for object cells: a Float NaN after every other value,
   other pairs by `<=>` (ca_obj_cmp, which refuses a pair it cannot
   order). */
static inline int
ca_obj_order_cmp (VALUE a, VALUE b)
{
  int nan_a = CA_OBJ_ISNAN(a), nan_b = CA_OBJ_ISNAN(b);
  if ( nan_a || nan_b ) return nan_a - nan_b;
  return ca_obj_cmp(a, b);
}

/* op names the contest: `<` for a minimum, `>` for a maximum. */
static inline int
ca_obj_extremum_replaces (VALUE v, VALUE acc, ID op)
{
  int c;
  if ( CA_OBJ_ISNAN(v) ) return 0;
  if ( CA_OBJ_ISNAN(acc) ) return 1;
  c = ca_obj_cmp(v, acc);
  return ( op == rb_intern("<") ) ? ( c < 0 ) : ( c > 0 );
}

/* Mask stand-ins.  A view whose mask covers a parent that has no mask
   reads an all-false stand-in there instead of giving the parent one:
   asking about the mask, or writing nothing but false into it, gives the
   parent no mask.  The stand-in gives way to the parent's own mask once
   the parent has one, or once a true has been written into it.  A grid
   with holes, a window or shift that masks its out-of-range cells, and a
   stack or meld with parts that have no mask read their masks this way;
   a new view that does should use these three and nothing of its own.

   Every entry into the cells of such a mask (each transfer, fill, attach
   and allocate slot, and any walk that reads its parents directly) first
   asks ca_mask_standin_current what to read; every write that may have
   put a true into the stand-in ends with ca_mask_standin_settle. */

/* A new stand-in for `parent`: all false, read-only when the parent is. */
CArray     *ca_mask_standin_new (CArray *parent);

/* What `mask_view`, now reading `reading` in place of `parent`'s mask,
   should read: the parent's own mask once the parent has one, otherwise
   `reading` unchanged.  Also unchanged while mask_view is attached with
   its buffer out. */
CArray     *ca_mask_standin_current (CArray *mask_view, CArray *reading,
                                     CArray *parent, CArray *standin);

/* After a write into `standin`: add any true it now holds to the parent's
   mask (made for it) and clear the stand-in.  A parent that can never
   have a mask (a value array, a mask array) refuses a true with
   TypeError, the stand-in cleared.  Nothing for a read-only stand-in. */
void        ca_mask_standin_settle (CArray *parent, CArray *standin);

/* Whether any of n boolean cells at data is true: whether a write of
   them can have put a true into a stand-in. */
static inline int
ca_mask_any_true (const void *data, ca_size_t n)
{
  const boolean8_t *b = (const boolean8_t *) data;
  ca_size_t i;
  for ( i = 0; i < n; i++ ) {
    if ( b[i] ) return 1;
  }
  return 0;
}

/* The mask a multi-parent view (CAStack, CAMeld) composes for parent `p`:
   p's own mask when it has one, otherwise a stand-in
   (ca_mask_standin_new) stored in *standin for the view to free.  The
   stand-in of a value array or a mask array, which can never carry a
   mask, stays in place for good. */
CArray     *ca_multi_parent_mask (CArray *p, CArray **standin);

/* ca_mask_standin_current for each part of a multi-parent view's mask.
   `mask` is the view's mask (a CAStack or CAMeld over the parents'
   masks), `parents` / `standins` the view's. */
void        ca_multi_parent_mask_refresh (CArray *mask, CArray **parents,
                                          CArray **standins, int32_t n);

/* Before a write to a multi-parent view's mask: when a parent that can
   never carry a mask (a value array, a mask array) is among the parents,
   run the write `body(arg)` once against blank all-false masks in place of
   every parent's mask and refuse it with that TypeError if it put a true
   into such a parent's part.  A refused write then changes no parent.
   Does nothing when no such parent is there. */
/* A write entering at the mask view `mask` that can reach the part of a
   stack or meld mask whose parent can have no mask: run `body(arg)` once
   against blank masks in place of every real mask it can reach, refuse it
   with TypeError if it put a true into such a part, and run it for real
   otherwise.  ca_mask_write_needs_check says whether a write needs this.
   Writes nested inside are not checked again. */
int         ca_mask_write_needs_check (CArray *ca);
void        ca_mask_write_checked (CArray *mask, VALUE (*body)(VALUE),
                                   VALUE arg);
int         ca_stack_mask_parts (CArray *mask, CArray ***parents,
                                 CArray ***standins, int32_t *n);
int         ca_meld_mask_parts (CArray *mask, CArray ***parents,
                                CArray ***standins, int32_t *n);
int         ca_stack_data_parts (CArray *ca, CArray ***parents, int32_t *n);
int         ca_meld_data_parts (CArray *ca, CArray ***parents, int32_t *n);
CArray     *ca_stack_like (CArray *like, CArray **parents);
CArray     *ca_meld_like (CArray *like, CArray **parents);

void        ca_multi_parent_check_part (CArray *part, const char *name);
void        ca_multi_parent_mask_refuse_first (CArray *mask, CArray **parents,
                                               CArray **standins, int32_t n,
                                               VALUE (*body)(VALUE),
                                               VALUE arg);

/* ca_mask_standin_settle for each part of a multi-parent view's mask
   still reading its stand-in, the parts that can have no mask first. */
void        ca_multi_parent_mask_settle (CArray *mask, CArray **parents,
                                         CArray **standins, int32_t n);

/* The common-type rules the operators, result_type and the search family
   share (ext/carray_cast.c): the type a scalar `obj` of type `st` takes
   beside an array of type `at`, and the type two types are matched for
   equality in (a mixed-sign integer pair widened so that each value is
   kept). */
int8_t      ca_promote_scalar_type (int8_t at, VALUE obj, int8_t st);
int8_t      ca_value_match_type (int8_t t, int8_t a, int8_t b);

/* Whether a kernel can raise on a cell of type `dt`, so that a masked cell
   must be skipped rather than computed: any op on an object cell (it calls
   Ruby), an integer division, remainder or reciprocal by zero, and an
   integer power of zero to a negative exponent.  The eager operators and
   the lazy views (and the plans CArray::Fusion hands an evaluator) ask
   this alone.  `op_id` is the kind's op number, or -1 when not known. */
enum { CA_OP_KIND_MONOP, CA_OP_KIND_BINOP, CA_OP_KIND_TRIOP,
       CA_OP_KIND_MONCMP, CA_OP_KIND_BINCMP };
int         ca_op_raises_on_cell (int kind, int op_id, int8_t dt);

/* The type a value query (a Ruby value or a CArray) and a reference of
   type `ref` are compared in, as `eq` compares them: count(v) and the
   search family read the reference through a view of that type.  An
   Integer that does not fit `ref` takes the type its value needs, where it
   matches nothing.  count(v) and the search family ask it for a numeric
   reference (ca_query_match_applies): a Face query is answered by the Face
   gate first, and a string reference compares in its own type, padding
   included. */
int8_t      ca_query_match_type (int8_t ref, VALUE query);
VALUE       ca_fixlen_widen_for_query (VALUE self, VALUE query);

static inline int
ca_query_match_applies (CArray *ref, VALUE query)
{
  if ( ! ( ca_is_integer_type(ref) || ca_is_float_type(ref)
           || ref->data_type == CA_BOOLEAN ) ) {
    return 0;
  }
  if ( rb_obj_is_carray(query) ) {
    CArray *q;
    TypedData_Get_Struct(query, CArray, &carray_data_type, q);
    if ( ca_is_face(q) ) {
      return 0;
    }
  }
  return 1;
}

/* Equality of two object cells, as the float lanes answer it: Ruby's `==`,
   except that a Float NaN equals nothing, itself included.  rb_equal alone
   answers true for the same object, so whether two NaN cells matched would
   depend on whether they held one Float or two.  (The value-hash family --
   unique / is_in / the set operations -- folds every NaN into one value
   instead, in its own hash.) */
static inline int
ca_obj_equal (VALUE a, VALUE b)
{
  if ( CA_OBJ_ISNAN(a) ) return 0;
  return RTEST(rb_equal(a, b));
}

/* ---- fast paths (carray_core.c) --------------------------------------------

   A fast path answers what a general path also answers, by a different
   algorithm.  Each one tests ca_fast_path(CA_SC_name) alongside its own
   condition, so a development build run with CARRAY_GENERAL_PATH=1 in the
   environment takes the general path everywhere and the test suite
   compares the two.  A release build has no switch: the test is the
   constant 1 and costs nothing.

   A branch that only lends a pointer, or drops to memcpy when the data is
   contiguous, runs the same code either way and does not test this.

   CARRAY_GENERAL_PATH=2 goes one step further for the kernel iterator.
   Besides switching the fast paths off, it makes the iterator deliver
   every source the way it delivers a view it knows nothing about: the
   whole view gathered into scratch through the view's own transfer
   (ca_xfer_all), and on WRITE the changed cells sent back through it.
   That walk keeps no promise of its own -- the view's transfer keeps
   them -- so a run with 2 checks the iterator's other routes against
   it.  ca_iter_by_transfer_only() is constant 0 in a release build.

---------------------------------------------------------------------------- */

/* The number of obj_types carray installs for itself (carray_core.c). */
extern int ca_obj_num_builtin;

/* Each fast path has a name, so that a development build can switch it off
   alone: CARRAY_SHORTCUTS_OFF=stack,stack_outer_k in the environment turns
   off the ones named, CARRAY_GENERAL_PATH=1 all of them.  A fast path tests
   ca_fast_path(CA_SC_name) alongside its own condition.  The names are in
   ca_shortcut_names (carray_core.c) in this order; the Ruby ones are asked
   through CArray.__fast_paths_enabled__(:name). */
enum ca_shortcut {
  CA_SC_SHIFT_WHOLE_VIEW,
  CA_SC_STACK,
  CA_SC_STACK_OUTER_K,
  CA_SC_FIBER_FUSED_CONVERSION,
  CA_SC_PER_SLAB_HOIST,
  CA_SC_PROTECT_ONLY_MAY_RAISE,
  CA_SC_STACK_ADDRS_K0,
  CA_SC_STACK_STRIDE_BOX,
  CA_SC_STACK_STRIDE_RELOC,
  CA_SC_STACK_PARENTS_K0,
  CA_SC_STACK_FOLD,
  CA_SC_MELD_STRIDE_BOX,
  CA_SC_MELD_PARENTS_AXIS0,
  CA_SC_MEDIAN_PARTITION,
  CA_SC_PERCENTILE_PARTITION,
  CA_SC_LOOP_INTERCHANGE,
  CA_SC_STACK_LOOP_INTERCHANGE,
  CA_SC_LAZY_STREAMING_REDUCE,
  CA_SC_SHORT_FIBER_REDUCE,
  /* asked from lib/carray */
  CA_SC_MELD_REDUCE,
  CA_SC_SEGMENT_NUNIQUE,
  CA_SC_SEGMENT_SCAN_KERNEL,
  CA_SC_SEGMENT_EDGE_KERNEL,
  CA_SC_SEGMENT_REDUCE_KERNEL,
  CA_SC_SEGMENT_ALL_ANY_KERNEL,
  CA_SC_CATEGORICAL_GROUP_BY_INDEX,
  CA_SC_AXIS_GROUP_COUNT_KERNEL,
  CA_SC_AXIS_GROUP_WHOLE_BLOCK,
  CA_SC_AXIS_GROUP_REDUCE_KERNEL,
  CA_SC_AXIS_GROUP_SCAN_KERNEL,
  CA_SC_WINDOW_FOLD_BY_OFFSET,
  CA_SC_COUNT
};

#ifdef CARRAY_DEV_BUILD
extern int ca_fast_paths_on;
extern int ca_iter_transfer_only_on;
extern unsigned char ca_shortcut_off[CA_SC_COUNT];
#define ca_fast_paths_enabled()    (ca_fast_paths_on)
#define ca_fast_path(id)           (ca_fast_paths_on && ! ca_shortcut_off[id])
#define ca_iter_by_transfer_only() (ca_iter_transfer_only_on)
#else
#define ca_fast_paths_enabled()    (1)
#define ca_fast_path(id)           (1)
#define ca_iter_by_transfer_only() (0)
#endif

/* A logical operator between a boolean array and an object array reads the
   boolean cells as true / false (carray_operator.c).  Shared by the eager
   binop and the lazy builder. */
void ca_binop_read_boolean_as_truth (int logical, volatile VALUE *pa,
                                     volatile VALUE *pb);

/* The :linear percentile between the k-th and (k+1)-th of n sorted values,
   lo and hi, at fraction r past the k-th: lo itself when r is 0 or there is
   no (k+1)-th, else lo * (1 - r) + hi * r.  A NaN sorts last, so a hi in the
   NaN tail makes the answer NaN unless r is 0.  The core's percentile and the
   iterators' per-segment kernels answer through this one expression. */
static inline double
ca_percentile_linear (double lo, double hi, double r, ca_size_t k, ca_size_t n)
{
  if ( r == 0.0 || k + 1 >= n ) return lo;
  return lo * (1.0 - r) + hi * r;
}

/* rb_ca_ptr2obj without the Face decode and the boolean true/false: a
   boolean is 0 or 1 and a Face cell is its storage value.  For the element
   readers, which check the mask first and decode after (carray_cast.c). */
VALUE rb_ca_ptr2obj_storage (VALUE self, void *ptr);

/* Wrap a MemoryView producer without copying (carray_memory_view.c).
   explicit_data_type must agree with a typed producer's format and names
   a typeless one's type; typeless_data_type names only a typeless one's
   (-1: none).  writable asks the producer for a writable view and raises
   when the source is read-only.  wrap_readonly / wrap_writable take
   their operand through this. */
VALUE ca_mv_wrap (VALUE obj, VALUE mask_obj, VALUE target_class,
                  int8_t explicit_data_type, int8_t typeless_data_type,
                  int writable);

/* The indexer's reading of one non-CArray key along an axis, and of the
   rubber marker (carray_index_classifier.c).  grid and CASelectAxis read
   their keys through these, so a key means the same cells on every path. */
int  ca_index_axis_key (VALUE arg, ca_size_t dim, int axis,
                        ca_size_t *start, ca_size_t *count, ca_size_t *step);
long ca_index_expand_rubber (int ndim, long argc, const VALUE *argv, VALUE *out);
/* Whether a key is a scalar one (an Integer or a Float), which picks one
   cell and drops its axis.  Whether it names a cell is checked when the
   key is read. */
int  ca_index_key_is_scalar (VALUE arg);

/* Whether this runs in the main Ractor (carray_utils.c). */
int ca_in_main_ractor (void);

#endif /* CARRAY_INTERNAL_H */
