/* ---------------------------------------------------------------------------

  ca_kernel_iterator.c -- the kernel iterator engine

  A C kernel asks for the cells of an array, one slab at a time, and gets
  them whatever the array is: an entity, a view of a view, a selection, a
  lazy expression.  This file decides, for each source, how to deliver
  them (borrow its memory, gather a copy, walk a stack's parents) and, on
  a write, how the cells the kernel changed get back to the array.

  Where to read first:
    - writing a kernel: guides/devel/11_kernel_iterator.md and
      docs/authoring/HOW_TO_WRITE_KERNEL.md; the surface itself is
      ca_kernel_iterator.h
    - how the engine works (its routes, the promises every route keeps,
      and which part keeps each): docs/internal/KernelIteratorEngine.md

  Map of this file:
    - scratch buffers (ki_data_alloc / ki_data_free) and helpers
    - classification: ca_iter_classify_source, ca_iter_route_source
    - the promise parts every route calls: ki_take_mask_copy,
      ki_gather_view, ki_scratch_push_changed, ki_attach_stack_parents,
      ki_fiber_contig_data / _mask
    - opening a walk: init_l1, and for L2 ki_choose_l2_route (decides)
      then ki_open_l2 (builds the state, with ki_lay_out_slabs)
    - handing out slabs: next_slab, next_slab_axes
    - writing back: sync_slab
    - closing: finish, close, and the raise-safe entry points
      (ca_iter_protect, ca_iter_ensure)
    - development-build test surface (CARRAY_DEV_BUILD), at the end

  A route added for speed is a shortcut, tagged next to its code with
  "Shortcut NAME" and a fixed set of fields; each one is switched off by
  ca_fast_paths_enabled().

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */
#include "ca_kernel_iterator.h"
#include "ca_monop_dispatch.h"   /* ca_monop_view_is_single_cast */
#include "ca_obj_face.h"      /* ca_strip_face, to walk what a Face wraps */

#include <assert.h>
#include <string.h>
#include <ruby/ractor.h>

/* Private flags bit, kept in ca_iter_state.flags like
   CA_ITER_FLAG_WALK_MAY_RAISE below: src is a copy the walk owns (see
   ca_iter_reopen_on_copy), freed when the walk finishes. */
#define CA_ITER_FLAG_OWNS_SRC 0x40000000u

/* Data scratch.  A scratch of object cells holds VALUEs no Ruby object
   owns while the kernel calls Ruby for each cell, so it is filled with
   Qnil and held for the GC until finish releases it.

   One large scratch is kept when a walk frees it and handed to the next
   walk that fits in it: a fresh allocation of that size costs the page
   faults of touching it, which for a reduction is several times the
   reduction itself.  The kept buffer is owned by nobody, and a walk that
   takes it owns it alone until it frees it again.  Each Ractor keeps its
   own (ractor-local storage), since walks in different Ractors run at
   the same time.

   Shortcut KEEP_SCRATCH (name tag; docs/internal/KernelIteratorEngine.md
   section 3.4 has the table of all shortcuts).
     Layer       data: where a scratch comes from.  The walk is unchanged.
     Speeds up   walks with a scratch of 1 MiB or more, run one after
                 another.
     Why         no difference measured on macOS (a per-axis sum of a
                 2000x2000 fake view); the page faults it
                 avoids are expected to cost more on Linux (unmeasured).
     Enters      ki_data_alloc: bytes >= KI_KEEP_MIN and a kept buffer
                 that fits; ki_data_free: KI_KEEP_MIN <= bytes <=
                 KI_KEEP_MAX.
     Promises    4 (a kept buffer has no owner, so no exit can leave it
                 held); 7 (object cells are cleared and held either way).
     Switch      ca_fast_paths_enabled(): off, every scratch is fresh.
     Checked by  test_iter_ractor_scratch.rb; the buffer count in
                 test_iter_delivery_detectors.rb. */

#define KI_KEEP_MIN ((ca_size_t) 1 << 20)
#define KI_KEEP_MAX ((ca_size_t) 64 << 20)

typedef struct {
  void      *p;
  ca_size_t  bytes;
} ki_kept_t;

static rb_ractor_local_key_t ki_kept_key;

static void
ki_kept_free (void *ptr)
{
  ki_kept_t *k = (ki_kept_t *) ptr;
  if ( k ) {
    if ( k->p ) ruby_xfree(k->p);
    ruby_xfree(k);
  }
}

static const struct rb_ractor_local_storage_type ki_kept_type = {
  NULL, ki_kept_free
};

static ki_kept_t *
ki_kept_slot (void)
{
  ki_kept_t *k = (ki_kept_t *) rb_ractor_local_storage_ptr(ki_kept_key);
  if ( k == NULL ) {
    k = ALLOC(ki_kept_t);
    k->p     = NULL;
    k->bytes = 0;
    rb_ractor_local_storage_ptr_set(ki_kept_key, k);
  }
  return k;
}

/* Development build: the number of buffers ki_data_alloc has handed out
   that ki_data_free has not taken back (CArray.__iter_buffers__).  A walk
   that ends leaves the count where it found it; the spec suite compares it
   around each walk. */
#ifdef CARRAY_DEV_BUILD
static long ki_buffers_out = 0;
#define KI_BUFFERS_OUT(d) ( ki_buffers_out += (d) )
#else
#define KI_BUFFERS_OUT(d) ((void) 0)
#endif

static void *
ki_data_alloc (int8_t data_type, ca_size_t bytes)
{
  void *p = NULL;
  KI_BUFFERS_OUT(1);
  if ( bytes >= KI_KEEP_MIN && ca_fast_paths_enabled() ) {
    ki_kept_t *k = ki_kept_slot();
    if ( k->p && bytes <= k->bytes ) {
      p = k->p;
      k->p = NULL;
      k->bytes = 0;
    }
  }
  if ( p == NULL ) {
    p = xmalloc(bytes > 0 ? bytes : 1);
  }
  if ( data_type == CA_OBJECT ) {
    ca_size_t n = bytes / (ca_size_t) sizeof(VALUE);
    ca_object_cells_clear(p, n);
    ca_gc_hold_buffer(p, n);
  }
  return p;
}

/* `bytes` is the size p was allocated with (0 when unknown: never kept). */
static void
ki_data_free (void *p, ca_size_t bytes)
{
  KI_BUFFERS_OUT(-1);
  ca_gc_release_buffer(p);
  if ( bytes >= KI_KEEP_MIN && bytes <= KI_KEEP_MAX && ca_fast_paths_enabled() ) {
    ki_kept_t *k = ki_kept_slot();
    if ( bytes > k->bytes ) {
      void *old = k->p;
      k->p     = p;
      k->bytes = bytes;
      if ( old ) {
        xfree(old);
      }
      return;
    }
  }
  xfree(p);
}

/* Defined in carray_core.c. (ca_is_readonly / ca_has_mask /
   ca_sync_data are already declared in carray.h.) */
extern int  ca_attach_is_alias (void *ap);
extern int  ca_root_lends_no_memory (void *ap);

/* CAStride family attach-fn marker. */
extern ca_operation_function_t ca_stride_func;

/* Descriptor framework view ops.  Each view's describe_axes emits the
   per-axis descriptor + parent dim snapshot consumed by the
   ca_axis_dispatch_* engine.  CAShift shares CAWindow's operation table
   (ca_shift_func is a copy with only free / clone / create_mask
   overridden), so it is recognised by its attach pointer matching
   ca_window_func.attach. */
extern ca_operation_function_t ca_select_axis_func;
extern ca_operation_function_t ca_grid_func;
extern ca_operation_function_t ca_select_func;
extern ca_operation_function_t ca_window_func;

/* Operation tables the classifier compares a source's attach slot
   against.  Every view below is delivered as CA_ITER_SRC_ATTACH: the
   engine gathers its cells into a scratch buffer of its own through the
   view's transfer (ki_gather_view = ca_xfer_all GET) and, on a WRITE
   walk, sends back the cells the kernel changed (ki_scratch_push_changed
   = ca_xfer_addrs, or ca_xfer_all PUT when every cell changed).  The
   view's attach / sync slots are not called.  Cast / byte swap / bit
   unpack / reduction views: */
extern ca_operation_function_t ca_fake_func;
extern ca_operation_function_t ca_byte_swap_func;
extern ca_operation_function_t ca_bitfield_func;
extern ca_operation_function_t ca_bitarray_func;
extern ca_operation_function_t ca_reduce_func;
extern ca_operation_function_t ca_object_func;

/* CATile / CARoll: the per-cell modulo wrap has no STRIDE / INDEX /
   SHIFT descriptor, so they are delivered as SRC_ATTACH (above). */
extern ca_operation_function_t ca_tile_func;
extern ca_operation_function_t ca_roll_func;

/* CAStack / CAMeld: SRC_ATTACH (above).  A stack can also be walked
   through its parents directly (CA_ITER_ALIAS_STACK / STACK_OUTER_K,
   see init_l2). */
extern ca_operation_function_t ca_stack_func;
extern ca_operation_function_t ca_meld_func;

/* CARemap (internal, no Ruby class constant): a per-element gather with
   no STRIDE structure, delivered as SRC_ATTACH (above). */
extern ca_operation_function_t ca_remap_func;

/* Lazy element-wise views (CAMonOp / CABinOp / CABinCmp / CAMonCmp /
   CATriOp): SRC_ATTACH (above); gathering evaluates the expression into
   the scratch, so every generated reduction accepts a lazy operand. */
extern ca_operation_function_t ca_monop_func;
extern ca_operation_function_t ca_binop_func;
extern ca_operation_function_t ca_bincmp_func;
extern ca_operation_function_t ca_moncmp_func;
extern ca_operation_function_t ca_triop_func;
extern CArray *ca_remap_new (CArray *ref, CArray *idx);

/* ca_reduce_new is declared in carray.h; rb_cCAReduce defined in
   ca_obj_reduce.c — needed by 9.3 smoke helpers since CAReduce has
   no public Ruby surface. */
extern VALUE rb_cCAReduce;
extern void ca_select_axis_describe_axes (void *ap, ca_axis_desc_t *out,
                                          ca_size_t *out_parent_dims);
extern void ca_grid_describe_axes        (void *ap, ca_axis_desc_t *out,
                                          ca_size_t *out_parent_dims);
extern void ca_select_describe_axes      (void *ap, ca_axis_desc_t *out,
                                          ca_size_t *out_parent_dims);
extern void ca_window_describe_axes      (void *ap, ca_axis_desc_t *out,
                                          ca_size_t *out_parent_dims);

/* ---- helpers -------------------------------------------------------- */

/* True iff src is a CAStride-family view (contig or not). Entity
   arrays are not CAStride family — they're tested separately. */
static int
ca_iter_is_castride_family (CArray *src)
{
  if ( src == NULL ) return 0;
  return ca_func[src->obj_type].attach == ca_stride_func.attach;
}

/* Source kinds declared by view classes installed from outside the core
   (ca_install_obj_type).  Sized to CA_OBJ_TYPE_MAX so any obj_type can be
   indexed directly; file-scope zero-init leaves unregistered slots at
   CA_ITER_SRC_NONE (= 0), which is exactly "the classifier decides".
   See ca_kernel_iterator.h for the contract an external class accepts by
   registering. */
static uint8_t ca_iter_registered_source_kind[CA_OBJ_TYPE_MAX];

void
ca_iter_register_source_kind (int obj_type, uint8_t kind)
{
  if ( obj_type < 0 || obj_type >= CA_OBJ_TYPE_MAX ) {
    rb_raise(rb_eArgError,
             "ca_iter_register_source_kind: obj_type %d out of range",
             obj_type);
  }
  if ( kind != CA_ITER_SRC_ATTACH ) {
    rb_raise(rb_eArgError,
             "ca_iter_register_source_kind: only CA_ITER_SRC_ATTACH (%d) "
             "may be registered, got %d",
             CA_ITER_SRC_ATTACH, (int) kind);
  }
  ca_iter_registered_source_kind[obj_type] = kind;
}

/* Classify the source by how its cells are delivered.  Returns
   CA_ITER_SRC_NONE only for a NULL source or one with no attach slot;
   every other view is delivered, as SRC_ATTACH if nothing more specific
   applies. */
static uint8_t
ca_iter_classify_source (CArray *src)
{
  if ( src == NULL ) return CA_ITER_SRC_NONE;

  /* Development build, CARRAY_GENERAL_PATH=2: every source takes the
     transfer walk (see ki_open_by_transfer), the reference the other
     routes are checked against. */
  if ( ca_iter_by_transfer_only() ) {
    return ca_func[src->obj_type].attach != NULL ? CA_ITER_SRC_ATTACH
                                                 : CA_ITER_SRC_NONE;
  }

  if ( ca_is_entity(src) )                return CA_ITER_SRC_CASTRIDE;
  if ( ca_iter_is_castride_family(src) )  return CA_ITER_SRC_CASTRIDE;

  /* Externally installed obj_types declare their routing.
     Placed after the two structural cases and before the built-in list:
     entity and CAStride-family sources are recognised from the struct
     itself and are read directly, so a registration must not be able to
     divert them onto a materialising path; everything below is a lookup
     of one operation table against another, and a class that registered
     is answering exactly that question about itself. */
  {
    uint8_t kind = ca_iter_registered_source_kind[src->obj_type];
    if ( kind != CA_ITER_SRC_NONE ) return kind;
  }

  /* Descriptor views: CASelectAxis / CAGrid / CASelect / CAWindow.
     CAShift shares ca_window_func's attach, so it matches the CAWindow
     check. */
  void *attach = ca_func[src->obj_type].attach;
  if ( attach == ca_select_axis_func.attach ) return CA_ITER_SRC_DESCRIPTOR;
  if ( attach == ca_grid_func.attach        ) return CA_ITER_SRC_DESCRIPTOR;
  if ( attach == ca_select_func.attach      ) return CA_ITER_SRC_DESCRIPTOR;
  if ( attach == ca_window_func.attach      ) return CA_ITER_SRC_DESCRIPTOR;  /* + CAShift */

  /* The views below are SRC_ATTACH: gathered into scratch through their
     own transfer (ki_gather_view) and, on WRITE, sent back the changed
     cells (ki_scratch_push_changed).  Their attach / sync slots are not
     called by the engine. */
  if ( attach == ca_fake_func.attach        ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_byte_swap_func.attach   ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_bitfield_func.attach    ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_bitarray_func.attach    ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_reduce_func.attach      ) return CA_ITER_SRC_ATTACH;
  /* CAObject: each transfer calls the Ruby callback.  A read-only
     CAObject is refused for WRITE by the ca_is_readonly check. */
  if ( attach == ca_object_func.attach      ) return CA_ITER_SRC_ATTACH;

  if ( attach == ca_tile_func.attach        ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_roll_func.attach        ) return CA_ITER_SRC_ATTACH;

  /* CAStack: SRC_ATTACH here; init_l2 may instead walk its parents
     directly (CA_ITER_ALIAS_STACK / STACK_OUTER_K). */
  if ( attach == ca_stack_func.attach       ) return CA_ITER_SRC_ATTACH;

  /* CAMeld: reduce hot paths avoid the gather through the per-parent
     decompose in lib/carray/meld_reduce.rb. */
  if ( attach == ca_meld_func.attach        ) return CA_ITER_SRC_ATTACH;

  if ( attach == ca_remap_func.attach       ) return CA_ITER_SRC_ATTACH;

  /* Lazy views (CAMonOp / CABinOp / CABinCmp / CAMonCmp / CATriOp):
     gathering evaluates the expression.  They are read-only, so WRITE is
     refused by the ca_is_readonly check. */
  if ( attach == ca_monop_func.attach       ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_binop_func.attach       ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_bincmp_func.attach      ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_moncmp_func.attach      ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_triop_func.attach       ) return CA_ITER_SRC_ATTACH;

  /* Anything else -- a view class installed from outside that did not
     register, or an in-tree class with no case above (such as the mask
     views CAMaskOfOperands and CAObjectMask).  Attaching is the one thing every view can do, and it is
     what a registration would declare, so the array is delivered that way
     rather than refused. */
  if ( attach != NULL ) return CA_ITER_SRC_ATTACH;

  return CA_ITER_SRC_NONE;
}

/* Routes a source by running classify_source and, for descriptor-routed views, also calling
   describe_axes to inspect the innermost axis kind.  A descriptor view
   comes back as SRC_DESCRIPTOR_L2_ALIASABLE (innermost axis STRIDE) or
   SRC_DESCRIPTOR, and then out_descs / out_parent_dims / out_ndim are
   filled so the caller does not re-call describe_axes.  A grid with holes
   and a view whose parent lends no memory come back as SRC_ATTACH, and
   the out_* arguments are not touched; nor are they for any other kind,
   whose classify_source verdict is returned as-is.

   Cost: classify_source is O(1) pointer compares; a descriptor view
   adds one describe_axes call (O(ndim)), which init would make anyway,
   and init reads the descriptors from here instead of describing the
   axes again. */
static uint8_t ca_iter_classify_source (CArray *src);
static void    ca_iter_describe_axes  (CArray *src, ca_axis_desc_t *,
                                       ca_size_t *, int8_t *);

static uint8_t
ca_iter_route_source (CArray         *src,
                      ca_axis_desc_t *out_descs,
                      ca_size_t      *out_parent_dims,
                      int8_t         *out_ndim)
{
  uint8_t kind = ca_iter_classify_source(src);
  if ( kind != CA_ITER_SRC_DESCRIPTOR ) return kind;

  /* A grid with holes (masked index cells) is not described by the engine
     either: its holes are delivered by its own transfers. */
  if ( ca_func[src->obj_type].attach == ca_grid_func.attach
       && ca_grid_has_holes(src) ) {
    return CA_ITER_SRC_ATTACH;
  }

  /* The descriptor walk reads the parent's memory, which such a parent
     only has after a whole materialise -- however few cells the view
     selects.  Deliver through the view's own transfer instead: SRC_ATTACH
     gathers the view into scratch with ca_xfer_all, and the view asks its
     parent for the selected cells alone. */
  {
    CArray *parent = ((CAView *) src)->parent;
    if ( ! parent->ptr && ca_parent_lends_no_memory(parent) ) {
      return CA_ITER_SRC_ATTACH;
    }
  }

  /* Descriptor source: describe_axes + inspect innermost. */
  ca_iter_describe_axes(src, out_descs, out_parent_dims, out_ndim);
  if ( ca_axis_dispatch_is_innermost_stride(out_descs, *out_ndim) ) {
    return CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE;
  }
  return CA_ITER_SRC_DESCRIPTOR;
}

/* Dispatch to the view's describe_axes, keyed on the attach pointer
   (CAShift shares CAWindow's). */
static void
ca_iter_describe_axes (CArray         *src,
                       ca_axis_desc_t *out_descs,
                       ca_size_t      *out_parent_dims,
                       int8_t         *out_ndim)
{
  void *attach = ca_func[src->obj_type].attach;
  if ( attach == ca_select_axis_func.attach ) {
    ca_select_axis_describe_axes(src, out_descs, out_parent_dims);
    *out_ndim = src->ndim;
    return;
  }
  if ( attach == ca_grid_func.attach ) {
    ca_grid_describe_axes(src, out_descs, out_parent_dims);
    *out_ndim = src->ndim;
    return;
  }
  if ( attach == ca_select_func.attach ) {
    ca_select_describe_axes(src, out_descs, out_parent_dims);
    /* CASelect emits 1-D INDEX descriptor per its describe_axes
       contract.  src->ndim should reflect the selector-flattened
       view shape; engine reads ndim from this argument. */
    *out_ndim = src->ndim;
    return;
  }
  if ( attach == ca_window_func.attach ) {
    ca_window_describe_axes(src, out_descs, out_parent_dims);
    *out_ndim = src->ndim;
    return;
  }
  /* unreachable: validate_inputs already gated through ca_iter_classify_source */
  *out_ndim = 0;
}

/* Public alias eligibility predicate: whether a walk at `level` could
   read the source's own memory in place. */
int
ca_iter_can_alias (void *ap, int level)
{
  CArray *ca = (CArray *) ap;
  if ( ca == NULL ) return 0;

  switch ( level ) {
    case 1:
      return ca_attach_is_alias(ca);

    case 2:
      if ( ca_is_entity(ca) ) return 1;
      return ca_iter_is_castride_family(ca);

    default:
      /* L3 (and any future level) is not implemented; answer as L1 so
         the predicate stays well-defined for callers that probe ahead. */
      return ca_attach_is_alias(ca);
  }
}

/* Build row-major byte strides for an entity-shape (CA_RANK_MAX). */
static void
ca_iter_build_rowmajor_strides (ca_size_t       *strides,
                                const ca_size_t *dim,
                                int8_t           ndim,
                                ca_size_t        bytes)
{
  ca_size_t s = bytes;
  int8_t    k;
  for ( k = ndim - 1; k >= 0; k-- ) {
    strides[k] = s;
    s *= dim[k];
  }
}

/* ---- PER_FIBER_FUSED: which views take it ----------------------------- */

/* A src_kind branch, then a check of the view's operation table, then of
   the fiber axis's stride.  Returns nonzero for
   CAFake / CAByteSwap / a single-cast CAMonOp under SRC_ATTACH when the
   fiber is contiguous in the parent, and for CAWindow / CAShift under
   SRC_DESCRIPTOR; zero otherwise.

   The fiber_axis_stride argument is the effective byte stride of the
   fiber axis on the view (= what next_slab_axes would yield as
   slab_strides[0]).  fiber_axis_stride == src->bytes means the fiber is
   a contiguous run of the parent's memory, which is what lets the view's
   region transfer deliver it in one pass.

   Called from two places in init_l2: the CA_SLAB_AXES descriptor branch
   and the SRC_ATTACH branch, each before it would materialise.  When it
   returns nonzero the caller skips the materialise and sets alias_mode =
   CA_ITER_ALIAS_PER_FIBER_FUSED with the fiber dispatch state filled. */
static int
ca_iter_should_per_fiber_fused (CArray   *src,
                                int       src_kind,
                                int8_t    fiber_axis,
                                ca_size_t fiber_axis_stride,
                                uint32_t  flags)
{
  (void) fiber_axis;

  /* CAFake / CAByteSwap: when the fiber is a contiguous run of the
     parent's memory, ca_xfer_stride takes the view's converting fast
     path (ca_xfer_stride_transform_fused) and delivers the fiber in one
     pass.  A fiber along another axis was measured slower this way, so
     the stride gate keeps it on the gathered route.  A single-cast
     CAMonOp (ca_monop_view_is_single_cast) is the lazy form of the same
     conversion and takes the same route; a chain of lazy operations
     gathers through the lazy arena instead, which this does not fit. */
  void *attach = ca_func[src->obj_type].attach;
  /* A conversion view is read-only on this path.  Its put-back sends the
     whole fiber, and a cell the kernel did not write does not come back
     unchanged through a conversion that loses information (an int64
     above 2^53 seen as float64), so a write takes the transfer walk,
     which sends back only the changed cells (promise 3). */
  if ( src_kind == CA_ITER_SRC_ATTACH && !(flags & CA_KERNEL_WRITE) ) {
    if ( attach == ca_fake_func.attach
         || attach == ca_byte_swap_func.attach
         || ca_monop_view_is_single_cast(src) ) {
      return fiber_axis_stride == (ca_size_t) src->bytes;
    }
  }

  /* CAShift / CAWindow: the view's region transfer fills out-of-bounds
     cells itself, so a fiber can be fetched in one call instead of a
     per-slab or whole-view gather (SRC_DESCRIPTOR).  A view that can
     lend the parent's memory (SRC_DESCRIPTOR_L2_ALIASABLE, an interior
     CAWindow) is already read in place; fetching it fiber by fiber was
     measured slower (0.35-0.82x), so only SRC_DESCRIPTOR takes it. */
  if ( src_kind == CA_ITER_SRC_DESCRIPTOR ) {
    /* CAWindow and CAShift share ca_window_func.attach. */
    if ( attach == ca_window_func.attach ) {
      return 1;
    }
  }

  /* Not taken by the other views, each measured slower fiber by fiber:
     CASelectAxis / CAGrid / CASelect (1.25-4.7x), whose descriptor
     engine already gathers the whole view in one batched pass and has no
     per-region fast path to enter; CABitarray / CABitfield (1.2-5.9x,
     through a fake over them), where N per-fiber calls each pay the bit
     alignment that one whole-view transfer pays once.  CAReduce is not
     routed here either. */
  return 0;
}

/* ---- state machine -------------------------------------------------- */

/* Shared input validation for init_l1 / init_l2.  Returns CA_ITER_OK
   if the (src, policy, flags) tuple is acceptable, else the
   corresponding CA_ITER_ERR_*. */
static int
ca_iter_validate_inputs (ca_iter_state    *st,
                         struct _CArray   *src,
                         ca_slab_policy_t  policy,
                         uint32_t          flags)
{
  if ( st == NULL || src == NULL )         return CA_ITER_ERR_FLAGS;
  /* CA_SLAB_AXES is accepted here and refused by init_l1 itself; init_l2
     refuses CA_SLAB_WHOLE (see each init's policy gate). */
  if ( policy != CA_SLAB_WHOLE && policy != CA_SLAB_AXES )
    return CA_ITER_ERR_POLICY;

  /* Accepted: CA_KERNEL_WRITE, CA_KERNEL_NO_MASK (enforced below) and
     CA_KERNEL_FIBER_CONTIG (per-fiber contig delivery for naxes==1 in
     next_slab_axes).  CA_KERNEL_CHUNK_HINT is reserved and rejected. */
  const uint32_t accepted = CA_KERNEL_WRITE | CA_KERNEL_NO_MASK
                          | CA_KERNEL_FIBER_CONTIG;
  if ( flags & ~accepted ) return CA_ITER_ERR_FLAGS;

  /* WRITE on a readonly view (CARepeat stride-0 / a lazy expression /
     a read-only CAWrap / any view of a frozen or read-only array) --
     explicit reject, would otherwise SEGV on write. */
  if ( (flags & CA_KERNEL_WRITE) && ca_is_readonly(src) ) {
    return CA_ITER_ERR_READONLY;
  }

  /* Masked sources are accepted; the mask travels with the slab, so
     nothing returns CA_ITER_ERR_MASK.  CA_KERNEL_NO_MASK is the kernel
     declaring it cannot handle a mask: a masked source is then refused
     with a dedicated code, so the caller can decide whether to peel via
     .value / .strip_mask(fill) or pick a mask-aware kernel. */
  if ( (flags & CA_KERNEL_NO_MASK) && ca_has_mask(src) ) {
    return CA_ITER_ERR_MASK_NOT_ALLOWED;
  }

  /* Gate: classify source.  Entity, CAStride family, descriptor views
     and SRC_ATTACH views are accepted; a source the classifier does not
     recognise (an externally installed view that has not registered a
     kind) is refused. */
  if ( ca_iter_classify_source(src) == CA_ITER_SRC_NONE ) {
    return CA_ITER_ERR_NOT_CHEAP;
  }
  return CA_ITER_OK;
}

/* Storage-identical wrapper strip for the kernel-compute entry.

   A Face layers a semantic identifier and a CALazyMarker layers "read this
   as the leaf of a lazy chain"; neither changes the storage, so routing and
   alias decisions belong to what they wrap.  ca_strip_face answers this for
   Face alone and is read that way in ~60 other places, so the marker is
   added here rather than inside it.

   The marker is NOT classified as a source in its own right.  Routing it to
   CA_ITER_SRC_ATTACH would work but would allocate elements * bytes and pull
   the whole array through ca_xfer_all first -- a.lazy.sum(axis: 0) would copy
   what a.sum(axis: 0) aliases.  Descending instead lets the parent be
   classified on its own merits, which costs nothing.

   Unlike Face, nothing re-wraps the result: a reduction over a lazy marker
   yields a plain entity, not a lazy view.

   CAREFUL: a marker carries CA_FLAG_READ_ONLY and its parent usually does
   not, so the WRITE rejection has to happen against the wrapper.  The caller
   does that before stripping. */
static CArray *
ca_iter_strip_storage_wrapper (CArray *src)
{
  while ( src && ( ca_is_face(src) || ca_is_lazy_marker(src) ) ) {
    src = ((CAView *) src)->parent;
  }
  return src;
}

/* Raise unless a and b have the same shape.  The INOUT and PAIR fiber
   macros call it before opening either walk, so a refusal leaves nothing
   to close. */
int
ca_iter_check_same_shape (struct _CArray *a, struct _CArray *b)
{
  int8_t k;
  int    same = ( a->ndim == b->ndim );
  for ( k = 0; same && k < a->ndim; k++ ) {
    if ( a->dim[k] != b->dim[k] ) same = 0;
  }
  if ( ! same ) {
    VALUE sa = rb_ary_new(), sb = rb_ary_new();
    for ( k = 0; k < a->ndim; k++ ) rb_ary_push(sa, SIZE2NUM(a->dim[k]));
    for ( k = 0; k < b->ndim; k++ ) rb_ary_push(sb, SIZE2NUM(b->dim[k]));
    rb_raise(rb_eArgError,
             "kernel iterator: the two arrays of a paired walk "
             "differ in shape (%"PRIsVALUE" vs %"PRIsVALUE")",
             rb_inspect(sa), rb_inspect(sb));
  }
  return 0;
}

int
ca_iter_check_init (int rc)
{
  const char *why;

  if ( rc == CA_ITER_OK ) return rc;

  switch ( rc ) {
  case CA_ITER_ERR_NOT_CHEAP:
    why = "the iterator does not recognise this kind of source";
    break;
  case CA_ITER_ERR_POLICY:
    why = "the slab policy or the axes given do not apply to this source";
    break;
  case CA_ITER_ERR_FLAGS:
    why = "this flag combination is not supported for this source";
    break;
  case CA_ITER_ERR_READONLY:
    why = "the array is read-only and the kernel asked to write";
    break;
  case CA_ITER_ERR_MASK:
    why = "the source carries a mask";
    break;
  case CA_ITER_ERR_MASK_NOT_ALLOWED:
    why = "the kernel declared CA_KERNEL_NO_MASK and the source carries a mask";
    break;
  default:
    why = "the request was refused";
    break;
  }
  rb_raise(rb_eRuntimeError, "kernel iterator: %s (rc=%d)", why, rc);
  return rc;   /* not reached */
}

/* Attaches a CAStack's parents and keeps their buffers.  stack_n_parents
   counts the parents attached so far, so an attach that raises leaves
   finish with exactly those to detach (promise 4).  The mask of a stack
   reads its parts' masks, some perhaps through stand-ins: those give way
   first, as the stack's own slots would let them. */
static void
ki_attach_stack_parents (ca_iter_state *st, CAStack *stack)
{
  if ( stack->mask_owner != NULL ) {
    CAStack *o = (CAStack *) stack->mask_owner;
    ca_multi_parent_mask_refresh((CArray *) stack, o->parents,
                                 o->mask_standins, o->n_parents);
  }
  st->stack_n_parents = 0;
  st->stack_parent_ptrs =
      (char **) xmalloc(stack->n_parents * sizeof(char *));
  for ( int32_t kk = 0; kk < stack->n_parents; kk++ ) {
    ca_attach(stack->parents[kk]);   /* window: finish detaches the counted parents */
    st->stack_parent_ptrs[kk] = (char *) stack->parents[kk]->ptr;
    st->stack_n_parents = kk + 1;
  }
}

/* Promise 2: the mask cursor a walk hands out is the walk's own copy of
   the source's mask, taken when the walk opens -- one flag per cell, in
   the view's row-major order -- never the live mask, so a write through
   it reaches nothing.  A source without a mask leaves alias_mask NULL.
   finish frees the copy. */
static void
ki_take_mask_copy (ca_iter_state *st, CArray *src)
{
  if ( ! ca_has_mask(src) ) return;
  st->scratch_mask = (boolean8_t *) xmalloc(src->elements > 0 ? src->elements : 1);
  if ( src->elements > 0 ) {
    ca_xfer_all(src->mask, (char *) st->scratch_mask, CA_XFER_GET);
  }
  st->alias_mask = st->scratch_mask;
}

/* Whole-view scratch.  The view is gathered into the walk's scratch,
   by the view's own transfer (by_copy = 0) or by ca_copy_data (by_copy =
   1, the CAStride compose-fold).  A WRITE walk sends back only the cells
   the kernel changed (ki_scratch_push_changed), so the scratch is twice
   the view and its second half keeps what was gathered: a cell the
   kernel left alone must not be sent back, for it may be another copy
   of a cell the kernel did write (a tile, a stack of one array with
   itself) or a cell a conversion view would not bring back unchanged. */
static void
ki_gather_view (ca_iter_state *st, CArray *src, uint32_t flags, int by_copy)
{
  ca_size_t view_bytes = (ca_size_t) src->elements * src->bytes;
  st->scratch_cap = (flags & CA_KERNEL_WRITE) ? 2 * view_bytes : view_bytes;
  st->scratch_ptr = (char *) ki_data_alloc(src->data_type, st->scratch_cap);
  if ( src->elements > 0 ) {
    if ( by_copy ) {
      ca_copy_data(src, st->scratch_ptr);
    }
    else {
      ca_xfer_all(src, st->scratch_ptr, CA_XFER_GET);
    }
    if ( flags & CA_KERNEL_WRITE ) {
      memcpy(st->scratch_ptr + view_bytes, st->scratch_ptr, view_bytes);
    }
  }
}

/* Send back the cells of the current slab (the whole view for a WHOLE
   walk) that differ from what was gathered, and record them as sent.
   The slab of a CA_SLAB_AXES walk starts at last_data_off in the
   scratch, which is laid out row-major over the view, so a cell's
   offset divided by the cell size is its address in the view. */
static void
ki_scratch_push_changed (ca_iter_state *st)
{
  CArray    *src        = st->src;
  ca_size_t  bytes      = src->bytes;
  ca_size_t  view_bytes = (ca_size_t) src->elements * bytes;
  char      *now        = st->scratch_ptr;
  char      *was        = st->scratch_ptr + view_bytes;
  int        whole      = ( st->level == 1 );   /* L1 is the whole array */
  ca_size_t  n          = whole ? src->elements : st->slab_elements;
  ca_size_t  idx[CA_RANK_MAX];
  ca_size_t *addrs;
  char      *vals;
  ca_size_t  n_changed = 0;
  ca_size_t  i;
  int8_t     k;
  volatile VALUE h_addrs = 0, h_vals = 0;

  if ( n <= 0 ) return;

  addrs = ALLOCV_N(ca_size_t, h_addrs, n);
  vals  = (char *) ALLOCV(h_vals, n * bytes);
  for ( k = 0; k < st->slab_ndim; k++ ) idx[k] = 0;

  for ( i = 0; i < n; i++ ) {
    ca_size_t off;
    if ( whole ) {
      off = i * bytes;
    }
    else {
      off = st->last_data_off;
      for ( k = 0; k < st->slab_ndim; k++ ) off += idx[k] * st->slab_strides[k];
      for ( k = st->slab_ndim - 1; k >= 0; k-- ) {
        if ( ++idx[k] < st->slab_dims[k] ) break;
        idx[k] = 0;
      }
    }
    if ( memcmp(now + off, was + off, bytes) != 0 ) {
      memcpy(was + off, now + off, bytes);
      memcpy(vals + n_changed * bytes, now + off, bytes);
      addrs[n_changed++] = off / bytes;
    }
  }

  /* Shortcut PUSH_ALL_CHANGED.
       Layer       write-back.
       Speeds up   a whole-view write walk that changed every cell: one
                   ca_xfer_all PUT instead of a list of all the addresses.
       Why         about 5% on a whole write of a fake view of 1M cells.
       Enters      whole && n_changed == n.
       Promises    3 (the same cells go back; the list would hold them all).
       Switch      ca_fast_paths_enabled(): off, the address list.
       Checked by  the write rows of the delivery matrix (L1 / L2 whole). */
  if ( whole && n_changed == n && ca_fast_paths_enabled() ) {
    ca_xfer_all(src, now, CA_XFER_PUT);
  }
  else if ( n_changed > 0 ) {
    ca_xfer_addrs(src, n_changed, addrs, vals, CA_XFER_PUT);
  }
  ALLOCV_END(h_vals);
  ALLOCV_END(h_addrs);
}

/* The transfer walk: the whole view gathered into scratch through the
   view's own transfer, its mask likewise, and yielded as one contiguous
   slab; on WRITE, sync_slab sends the changed cells back through the same
   transfer (ki_scratch_push_changed).

   Every promise the iterator makes is kept here by the view itself --
   what a cell is, where its mask flag lives, which root cell a write
   lands on -- so this walk is the reference the other routes are checked
   against (CARRAY_GENERAL_PATH=2 sends every source through it).  It is
   also the route for a view the classifier knows nothing more about.

   The caller has filled src / src_kind / level / policy / ndim / flags /
   bytes / naxes. */
static void
ki_open_by_transfer (ca_iter_state *st, CArray *src, uint32_t flags)
{
  ki_gather_view(st, src, flags, 0);
  st->alias_mode          = CA_ITER_ALIAS_NONE;
  st->alias_ptr           = st->scratch_ptr;
  st->composed_strides[0] = src->bytes;
  st->composed_base       = 0;
  st->slab_n              = src->elements;
  st->total_slabs         = 1;
  st->slabs_emitted       = 0;
  st->chunk_size          = st->slab_n;
  st->outer_idx           = NULL;

  ki_take_mask_copy(st, src);
}

static int
ca_iter_state_init_l1_unprotected (ca_iter_state    *st,
                       struct _CArray   *src,
                       ca_slab_policy_t  policy,
                       int8_t           *axes,
                       int8_t            naxes,
                       uint32_t          flags)
{
  /* Leave the state defined before anything can return.  Every error
     return below hands control back to a caller that may not look at the
     code, so what it is left holding has to be a state that iterates zero
     times rather than whatever its stack frame happened to contain. */
  if ( st == NULL ) return CA_ITER_ERR_FLAGS;
  memset(st, 0, sizeof(*st));
  if ( src == NULL ) return CA_ITER_ERR_FLAGS;

  /* A Face or a lazy marker wraps storage identical to its parent, so it
     is stripped at entry (the same reason as in init_l2 below), before
     validate_inputs.

     The WRITE rejection is taken against the wrapper, not what it wraps: a
     CALazyMarker is read-only while its parent is not, and stripping first
     would let a destructive kernel through to the parent.  validate_inputs
     re-checks the stripped source, which is harmless. */
  if ( (flags & CA_KERNEL_WRITE) && ca_is_readonly(src) ) {
    return CA_ITER_ERR_READONLY;
  }
  if ( ca_is_face(src) || ca_is_lazy_marker(src) ) {
    src = ca_iter_strip_storage_wrapper(src);
  }

  int rc = ca_iter_validate_inputs(st, src, policy, flags);
  if ( rc != CA_ITER_OK ) return rc;

  /* CA_SLAB_AXES is L2 only (a kernel that wants a K-D slab uses
     init_l2); init_l1 refuses it rather than walking the whole array. */
  if ( policy == CA_SLAB_AXES ) return CA_ITER_ERR_POLICY;

  /* The same routing as init_l2: a descriptor view whose parent lends no
     memory, or a grid with holes, takes the transfer walk.  An L1 walk
     yields the whole view as one slab, so a descriptor view the L2 walk
     could borrow is gathered here like any other descriptor view. */
  ca_axis_desc_t route_descs[CA_RANK_MAX];
  ca_size_t      route_pdims[CA_RANK_MAX];
  int8_t         route_ndim = 0;
  uint8_t src_kind = ca_iter_route_source(src, route_descs, route_pdims,
                                          &route_ndim);
  if ( src_kind == CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE ) {
    src_kind = CA_ITER_SRC_DESCRIPTOR;
  }
  /* A write over a descriptor view takes the transfer walk, as an L2
     write over an INDEX or SHIFT slab axis does.  Gathering with the
     descriptor engine would leave nothing to send back but the whole
     view, and a view that shows a root cell twice (a grid with a
     repeated index) would then let the copy the kernel did not write
     overwrite the one it did (promise 3: only the changed cells go
     back). */
  if ( src_kind == CA_ITER_SRC_DESCRIPTOR && (flags & CA_KERNEL_WRITE) ) {
    src_kind = CA_ITER_SRC_ATTACH;
  }

  st->src      = src;
  st->src_kind = src_kind;
  st->level    = 1;
  st->policy   = policy;
  st->ndim     = src->ndim;
  st->flags    = flags;
  st->bytes    = src->bytes;
  st->naxes    = naxes;

  st->slab_n        = src->elements;
  st->total_slabs   = 1;
  st->slabs_emitted = 0;
  st->chunk_size    = st->slab_n;

  if ( src_kind == CA_ITER_SRC_ATTACH ) {
    ki_open_by_transfer(st, src, flags);
    return CA_ITER_OK;
  }

  if ( src_kind == CA_ITER_SRC_DESCRIPTOR ) {
    /* === descriptor path (CASelectAxis / CAGrid / CASelect / CAWindow /
       CAShift) ==========================================================
       describe_axes → prepare → layout, then gather the view into
       scratch with ca_axis_dispatch_gather and yield one contig slab
       (alias_mode = NONE).  The kernel sees a flat slab whatever the
       per-axis kinds are; an INDEX / SHIFT mix is handled inside the
       engine. */
    ca_axis_desc_t raw_descs[CA_RANK_MAX];
    int8_t         raw_ndim = 0;
    ca_iter_describe_axes(src, raw_descs, st->parent_axis_dims, &raw_ndim);
    /* Cache the post-merge layout for next_slab / sync_slab. */
    ca_axis_dispatch_prepare(st->parent_axis_dims, raw_descs, raw_ndim,
                             st->bytes, st->descs, st->pstrides,
                             st->mdim, &st->desc_ndim);
    ca_axis_dispatch_layout(st->descs, st->pstrides, st->mdim,
                            st->desc_ndim, st->bytes,
                            &st->slab_start, &st->slab_bytes_desc,
                            &st->slab_base);
    if ( st->slab_start > 0 ) {
      ca_axis_dispatch_classify_prefix(st->descs, st->pstrides,
                                       st->slab_start, st->prefix);
    }
    st->total_elements = src->elements;

    /* Materialise: attach the parent here, allocate the scratch, and
       gather into it with ca_axis_dispatch_gather (INDEX axes included);
       the iterator owns the buffer.  Descriptor views inherit from CAView
       so parent is at the CAVIEW prefix slot. */
    CArray *parent = CAVIEW(src)->parent;
    ca_attach(parent);                 /* engine reads parent->ptr */
    st->root = parent;                 /* finish() detaches */
    st->scratch_cap = src->elements * src->bytes;
    /* bound_fill = the CAWindow / CAShift fill value for an out-of-bounds
       SHIFT cell; NULL for the other descriptor views, which have no
       SHIFT axes. */
    const void *bound_fill = NULL;
    if ( ca_func[src->obj_type].attach == ca_window_func.attach ) {
      bound_fill = ((CAWindow *) src)->fill;
    }
    st->scratch_cap = st->total_elements * src->bytes;
    st->scratch_ptr = (char *) ki_data_alloc(src->data_type, st->scratch_cap);
    ca_axis_dispatch_gather(parent, st->parent_axis_dims, raw_descs, raw_ndim,
                            src->bytes, st->total_elements, bound_fill,
                            st->scratch_ptr);
    st->alias_mode = CA_ITER_ALIAS_NONE;
    st->alias_ptr  = st->scratch_ptr;

    ki_take_mask_copy(st, src);
    return CA_ITER_OK;
  }

  /* === CAStride path ========================================= */
  if ( ca_iter_can_alias(src, 1) ) {
    /* alias path: entity or CAStride contig */
    st->alias_mode = CA_ITER_ALIAS_CONTIG;
    ca_attach(src);
    st->alias_ptr = (char *) src->ptr;
  } else {
    /* scratch path: CAStride family non-contig.  ca_copy_data routes
       to ca_stride_func_copy_data which composes leaf strides up to
       the root entity and gathers in one pass — no per-intermediate
       view materialise. */
    ki_gather_view(st, src, flags, 1);
    st->alias_mode = CA_ITER_ALIAS_NONE;
    st->alias_ptr  = st->scratch_ptr;
  }

  ki_take_mask_copy(st, src);
  return CA_ITER_OK;
}

/* ---- L2 walks: choosing a route, then building the state for it --------

   init_l2 checks the request, classifies the source and chooses one of the
   routes below (ki_choose_l2_route, which only decides).  ki_open_l2 then
   builds the state for that route: the part only that route needs, the
   axis layout every route shares (ki_lay_out_slabs) and the mask.  So the
   state is assembled in one place and init_l2 has one way out. */

typedef enum {
  KI_L2_FIBER_FUSED,   /* PER_FIBER_FUSED: a CAWindow / CAShift fiber, or a
                          read of a conversion view's innermost fiber */
  KI_L2_PER_SLAB,      /* descriptor view, read, a slab axis INDEX or SHIFT:
                          one slab gathered at a time (PER_SLAB / _HOIST) */
  KI_L2_DESC_WHOLE,    /* descriptor view, read: the whole view gathered by
                          the descriptor engine (outer SHIFT, SHIFT_WHOLE_VIEW) */
  KI_L2_DESC_STRIDED,  /* descriptor view whose slab axes are all STRIDE:
                          the parent's memory is borrowed */
  KI_L2_STACK,         /* CAStack read along its stack axis */
  KI_L2_STACK_OUTER_K, /* CAStack read with the stack axis outside the slab */
  KI_L2_TRANSFER,      /* the whole view gathered by its own transfer */
  KI_L2_ROOT_STRIDED,  /* CAStride: the root walked through composed strides */
  KI_L2_VIEW_SCRATCH,  /* CAStride over a root that lends no memory */
  KI_L2_CONTIG         /* entity, or a contiguous CAStride */
} ki_l2_route;

typedef struct {
  ki_l2_route    route;
  uint8_t        src_kind;              /* what st->src_kind records */
  int8_t         in_slab[CA_RANK_MAX];  /* 1 for each slab axis */
  ca_axis_desc_t descs[CA_RANK_MAX];    /* descriptor routes: the view's */
  ca_size_t      pdims[CA_RANK_MAX];    /*   axes and the parent's dims  */
  int8_t         ndesc;
  CArray        *root;                  /* KI_L2_ROOT_STRIDED */
  ca_size_t      composed[CA_RANK_MAX];
  ca_size_t      base;
} ki_l2_plan;

/* Per view axis: its extent, its byte stride when it is a slab axis, its
   byte stride when it is an outer axis, and its mask element stride. */
typedef struct {
  ca_size_t dims[CA_RANK_MAX];
  ca_size_t slab_strides[CA_RANK_MAX];
  ca_size_t outer_strides[CA_RANK_MAX];
  ca_size_t mask_strides[CA_RANK_MAX];
} ki_axis_layout;

/* Row-major byte and element strides over the view's own shape. */
static void
ki_view_row_major (CArray *src, ca_size_t *bytes, ca_size_t *elems)
{
  ca_size_t b = src->bytes, e = 1;
  for ( int8_t k = src->ndim - 1; k >= 0; k-- ) {
    if ( bytes ) bytes[k] = b;
    if ( elems ) elems[k] = e;
    b *= src->dim[k];
    e *= src->dim[k];
  }
}

/* Splits the view's axes into slab and outer axes (both in ascending axis
   order, so the user's order does not matter), counts the slabs and opens
   the outer cursor. */
static void
ki_lay_out_slabs (ca_iter_state *st, CArray *src, const int8_t *in_slab,
                  const ki_axis_layout *lay)
{
  int8_t sp = 0, op = 0;
  st->slab_elements = 1;
  for ( int8_t k = 0; k < src->ndim; k++ ) {
    if ( in_slab[k] ) {
      st->slab_axes_buf[sp]     = k;
      st->slab_dims[sp]         = lay->dims[k];
      st->slab_strides[sp]      = lay->slab_strides[k];
      st->slab_mask_strides[sp] = lay->mask_strides[k];
      st->slab_elements        *= lay->dims[k];
      sp++;
    } else {
      st->outer_axes[op]         = k;
      st->outer_dims[op]         = lay->dims[k];
      st->outer_strides[op]      = lay->outer_strides[k];
      st->outer_mask_strides[op] = lay->mask_strides[k];
      op++;
    }
  }
  st->slab_ndim  = sp;
  st->outer_ndim = op;

  ca_size_t total = 1;
  for ( int8_t m = 0; m < st->outer_ndim; m++ ) total *= st->outer_dims[m];
  st->total_slabs   = total;
  st->slab_n        = st->slab_elements;
  st->slabs_emitted = 0;
  st->chunk_size    = st->slab_n;

  if ( st->outer_ndim > 0 ) {
    CA_ASSUME(st->outer_ndim <= CA_RANK_MAX);   /* bound alloc over rank */
    st->outer_idx = ALLOC_N(ca_size_t, st->outer_ndim);
    for ( int8_t m = 0; m < st->outer_ndim; m++ ) st->outer_idx[m] = 0;
  } else {
    st->outer_idx = NULL;
  }
}

/* Chooses the route.  Decides only: nothing is attached or allocated, so
   a refusal leaves nothing to close. */
static int
ki_choose_l2_route (CArray *src, int8_t *axes, int8_t naxes, uint32_t flags,
                    ki_l2_plan *plan)
{
  const int8_t *in_slab = plan->in_slab;
  ca_size_t     row_bytes[CA_RANK_MAX];
  int8_t        k;

  ki_view_row_major(src, row_bytes, NULL);

  if ( plan->src_kind == CA_ITER_SRC_DESCRIPTOR
       || plan->src_kind == CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE ) {
    /* Shortcut PER_FIBER_FUSED (CAWindow / CAShift).
       Layer       all three, per fiber: each fiber is fetched with the
                   view's ca_xfer_stride (which fills out-of-bounds
                   cells itself) and put back the same way.
       Speeds up   a fiber walk of a CAWindow / CAShift whose innermost
                   axis is SHIFT.
       Why         none measured: about 8% slower than the descriptor
                   route on a sort of a 2000x2000 shift view.
       Enters      CA_KERNEL_FIBER_CONTIG, one slab axis, the view's
                   own rank, and ca_iter_should_per_fiber_fused.  An
                   outer-only SHIFT arrives as L2_ALIASABLE and never
                   reaches this hook.
       Promises    1 (the fiber scratch is contiguous), 2 (the mask is
                   fetched into the fiber mask scratch), 3 (ca_xfer_stride
                   PUT of a fiber that neither converts nor repeats a
                   cell), 4 (CA_ITER_FLAG_WALK_MAY_RAISE).
       Switch      ca_fast_paths_enabled(): off, the descriptor route.
       Checked by  the fiber rows of the "shift" view in the delivery
                   matrix. */
    if ( (flags & CA_KERNEL_FIBER_CONTIG) && naxes == 1
         && plan->ndesc == src->ndim && ca_fast_paths_enabled()
         && ca_iter_should_per_fiber_fused(src, plan->src_kind, axes[0],
                                           row_bytes[axes[0]], flags) ) {
      plan->route = KI_L2_FIBER_FUSED;
      return CA_ITER_OK;
    }

    /* The rank check guards a descriptor whose rank differs from the
       view's (it would not expose the axis partition slab_axes names).
       Every describe_axes in the engine reports the view's rank, so the
       check does not fire today; it stays as the contract's guard. */
    if ( plan->ndesc != src->ndim ) return CA_ITER_ERR_POLICY;

    int slab_has_non_stride = 0;
    int slab_has_index      = 0;
    int outer_has_shift     = 0;
    for ( k = 0; k < src->ndim; k++ ) {
      if ( in_slab[k] && plan->descs[k].kind != CA_AXIS_KIND_STRIDE ) {
        slab_has_non_stride = 1;
        if ( plan->descs[k].kind == CA_AXIS_KIND_INDEX ) slab_has_index = 1;
      }
      if ( !in_slab[k] && plan->descs[k].kind == CA_AXIS_KIND_SHIFT ) {
        outer_has_shift = 1;
      }
    }

    /* A slab with a SHIFT axis that leaves out the innermost view axis
       would be gathered one strided cell at a time, once per slab.  Read
       walks take the whole-view route instead: the view is gathered
       once, row by row, and the slabs are walked in the copy.

       Shortcut SHIFT_WHOLE_VIEW.
       Layer       data; the fiber layer (ki_fiber_contig_*) sits on top.
       Speeds up   read walks of a CAWindow / CAShift whose slab has a
                   SHIFT axis and not the innermost axis.
       Why         about 1.5x on a median along axis 0 of a 2000x2000
                   shift view.
       Enters      a non-stride slab axis, no INDEX slab axis, the
                   innermost axis outside the slab, a read walk.
       Promises    2 and 6 (the mask is copied by ki_take_mask_copy, and
                   only when the view has one).
       Switch      ca_fast_paths_enabled(): off, the per-slab gather.
       Checked by  the slab-axis rows of the "shift" and "window" views
                   in the delivery matrix. */
    int whole_view = slab_has_non_stride && ! slab_has_index
                     && ! in_slab[src->ndim - 1]
                     && ! ( flags & CA_KERNEL_WRITE )
                     && ca_fast_paths_enabled();

    /* The descriptor engine's gathers (per slab and whole view) read
       only.  A write takes the transfer walk instead: the view is
       gathered whole and the changed cells go back through its own
       transfer (promise 3). */
    if ( (slab_has_non_stride && ! whole_view) || outer_has_shift ) {
      if ( flags & CA_KERNEL_WRITE ) {
        plan->src_kind = CA_ITER_SRC_ATTACH;
        goto by_transfer;
      }
    }
    plan->src_kind = CA_ITER_SRC_DESCRIPTOR;
    if ( slab_has_non_stride && ! whole_view ) {
      plan->route = KI_L2_PER_SLAB;
    }
    else if ( outer_has_shift || whole_view ) {
      plan->route = KI_L2_DESC_WHOLE;
    }
    else {
      plan->route = KI_L2_DESC_STRIDED;
    }
    return CA_ITER_OK;
  }

  if ( plan->src_kind == CA_ITER_SRC_ATTACH ) {
 by_transfer:
    /* Shortcut STACK.
       Layer       data and fiber: the slab is cut contiguous from the K
                   parents through a tile cache.
       Speeds up   read walks of an unmasked CAStack whose one slab axis
                   is the stack axis.
       Why         about 2x on a mean along the stack axis of 4 parents
                   of 500x2000.
       Enters      a CAStack, no mask, a read walk, one slab axis that is
                   k_axis.
       Promises    1 (the slab is contiguous), 6 (no mask exists to touch).
       Switch      ca_fast_paths_enabled(): off, the transfer walk.
       Checked by  the slab-axis and fiber rows of the stack parent along
                   axis 0 in the delivery matrix. */
    if ( ca_func[src->obj_type].attach == ca_stack_func.attach
         && !ca_has_mask(src)
         && !(flags & CA_KERNEL_WRITE)
         && naxes == 1 && axes[0] == ((CAStack *) src)->k_axis
         && ca_fast_paths_enabled() ) {
      plan->route = KI_L2_STACK;
      return CA_ITER_OK;
    }
    /* Shortcut STACK_OUTER_K.
       Layer       data; the fiber layer sits on top.
       Speeds up   read walks of a CAStack whose stack axis is an outer
                   axis: each slab is cut from the one parent the outer
                   index picks, without gathering the stack.
       Why         about 11x on a mean along axis 1 of 4 parents of
                   500x2000.
       Enters      a CAStack, a read walk, the stack axis outside the slab.
       Promises    2 (the parents' masks are copied), 6 (masks are read
                   only when a parent has one), 8 (alias_ptr stays NULL,
                   so no slab is lent as a window).
       Switch      ca_fast_paths_enabled(): off, the transfer walk.
       Checked by  the slab-axis, fiber and two-slab-axes rows of the
                   stack parent along axes 1 and 2 in the delivery matrix. */
    if ( ca_func[src->obj_type].attach == ca_stack_func.attach
         && !(flags & CA_KERNEL_WRITE)
         && naxes >= 1 && !in_slab[((CAStack *) src)->k_axis]
         && ca_fast_paths_enabled() ) {
      plan->route = KI_L2_STACK_OUTER_K;
      return CA_ITER_OK;
    }
    /* Shortcut PER_FIBER_FUSED (conversion views).
       Layer       all three, per fiber: each fiber is fetched with the
                   view's ca_xfer_stride into the fiber scratch, without
                   gathering the whole view.
       Speeds up   a read of a fiber of a fake or byte-swap view, or of a
                   lazy monop that only casts, along its innermost axis.
       Why         no difference measured on a sort along the last axis
                   of a 2000x2000 fake view.
       Enters      CA_KERNEL_FIBER_CONTIG, one slab axis, a read walk, and
                   ca_iter_should_per_fiber_fused.
       Promises    1, 2 and 4, as the CAWindow / CAShift hook above.  A
                   write takes the transfer walk (promise 3).
       Switch      ca_fast_paths_enabled(): off, the transfer walk.
       Checked by  the fiber rows of the fake parent in the delivery
                   matrix. */
    if ( (flags & CA_KERNEL_FIBER_CONTIG) && naxes == 1
         && ca_fast_paths_enabled()
         && ca_iter_should_per_fiber_fused(src, CA_ITER_SRC_ATTACH, axes[0],
                                           row_bytes[axes[0]], flags) ) {
      plan->route = KI_L2_FIBER_FUSED;
      return CA_ITER_OK;
    }
    plan->route = KI_L2_TRANSFER;
    return CA_ITER_OK;
  }

  if ( plan->src_kind != CA_ITER_SRC_CASTRIDE ) return CA_ITER_ERR_POLICY;

  if ( ca_iter_can_alias(src, 1) ) {
    plan->route = KI_L2_CONTIG;
    return CA_ITER_OK;
  }
  /* A non-contiguous CAStride: compose the strides up to the root.  A
     root that holds nothing to read through would cost one whole-root
     materialise no matter how few cells the view touches -- the cliff
     the xfer path avoids by asking for a region -- so that view is
     gathered by its own region protocol instead: ca_copy_data walks the
     leaf's request up the chain, so a 1000x1000 slice of a 2014x3040
     CAObject asks for exactly that block. */
  ca_stride_compose_to_root((CAStride *) src, &plan->root, plan->composed,
                            &plan->base);
  plan->route = ca_root_lends_no_memory(plan->root) ? KI_L2_VIEW_SCRATCH
                                                    : KI_L2_ROOT_STRIDED;
  return CA_ITER_OK;
}

/* Builds the state for the chosen route. */
static void
ki_open_l2 (ca_iter_state *st, CArray *src, ca_slab_policy_t policy,
            int8_t *axes, int8_t naxes, uint32_t flags, ki_l2_plan *plan)
{
  ki_axis_layout lay;
  int8_t         k;

  st->src      = src;
  st->src_kind = plan->src_kind;
  st->level    = 2;
  st->policy   = policy;
  st->ndim     = src->ndim;
  st->flags    = flags;
  st->bytes    = src->bytes;
  st->naxes    = naxes;

  /* The default layout: the view's own row-major strides, which is how
     a scratch the walk gathered is laid out and how the mask copy is
     laid out on every route that takes one. */
  for ( k = 0; k < src->ndim; k++ ) lay.dims[k] = src->dim[k];
  ki_view_row_major(src, lay.slab_strides, lay.mask_strides);
  memcpy(lay.outer_strides, lay.slab_strides, src->ndim * sizeof(ca_size_t));

  switch ( plan->route ) {

  case KI_L2_FIBER_FUSED:
    st->alias_mode = CA_ITER_ALIAS_PER_FIBER_FUSED;
    st->alias_ptr  = NULL;      /* no whole-view buffer */
    st->fiber_axis = axes[0];
    memcpy(st->fiber_native_strides, lay.slab_strides,
           src->ndim * sizeof(ca_size_t));
    break;

  case KI_L2_PER_SLAB: {
    /* One slab is gathered into a slab-sized scratch per outer index, so
       a slab axis steps through that scratch (packed row-major over the
       slab axes) and an outer axis moves nothing in it.  The descriptors
       are kept for next_slab_axes to build each slab's subset. */
    CArray   *parent = CAVIEW(src)->parent;
    ca_size_t b = src->bytes;
    ca_attach(parent);    /* window: finish detaches st->root */
    st->root = parent;
    memcpy(st->descs, plan->descs, src->ndim * sizeof(ca_axis_desc_t));
    memcpy(st->parent_axis_dims, plan->pdims, src->ndim * sizeof(ca_size_t));
    {
      ca_size_t s = src->bytes;
      for ( k = src->ndim - 1; k >= 0; k-- ) {
        st->pstrides[k] = s;
        s *= plan->pdims[k];
      }
    }
    st->desc_ndim = src->ndim;
    for ( k = src->ndim - 1; k >= 0; k-- ) {
      lay.dims[k]          = plan->descs[k].count;
      lay.outer_strides[k] = 0;
      if ( plan->in_slab[k] ) {
        lay.slab_strides[k] = b;
        b *= plan->descs[k].count;
      }
    }
    break;
  }

  case KI_L2_DESC_WHOLE: {
    /* The view gathered whole into a row-major scratch by the
       descriptor engine (which fills out-of-bounds cells), then walked
       with the default layout. */
    CArray        *parent = CAVIEW(src)->parent;
    ca_axis_desc_t local_descs[CA_RANK_MAX];
    const void    *bound_fill = NULL;
    ca_attach(parent);    /* window: finish detaches st->root */
    st->root = parent;
    memcpy(local_descs, plan->descs, src->ndim * sizeof(ca_axis_desc_t));
    if ( ca_func[src->obj_type].attach == ca_window_func.attach ) {
      bound_fill = ((CAWindow *) src)->fill;
    }
    st->scratch_cap = src->elements * src->bytes;
    st->scratch_ptr = (char *) ki_data_alloc(src->data_type, st->scratch_cap);
    ca_axis_dispatch_gather(parent, plan->pdims, local_descs, src->ndim,
                            src->bytes, src->elements, bound_fill,
                            st->scratch_ptr);
    st->total_elements = src->elements;
    st->alias_mode     = CA_ITER_ALIAS_NONE;
    st->alias_ptr      = st->scratch_ptr;
    break;
  }

  case KI_L2_DESC_STRIDED: {
    /* The parent's memory is walked in place.  Each slab axis is a
       STRIDE axis; an outer axis is STRIDE or INDEX (an outer SHIFT went
       to KI_L2_DESC_WHOLE).  The start of every STRIDE axis is folded
       into composed_base, so a slab or STRIDE outer offset is step *
       index; an INDEX outer axis is looked up in its indices[] by
       next_slab_axes, which needs the descriptors kept. */
    CArray   *parent = CAVIEW(src)->parent;
    ca_size_t base = 0;
    {
      ca_size_t s = src->bytes;
      for ( k = src->ndim - 1; k >= 0; k-- ) {
        st->pstrides[k] = s;
        s *= plan->pdims[k];
      }
    }
    for ( k = 0; k < src->ndim; k++ ) {
      const ca_axis_desc_t *d = &plan->descs[k];
      lay.dims[k] = d->count;
      if ( plan->in_slab[k] ) {
        base += d->start * st->pstrides[k];
        lay.slab_strides[k] = d->step * st->pstrides[k];
      }
      else if ( d->kind == CA_AXIS_KIND_STRIDE ) {
        base += d->start * st->pstrides[k];
        lay.outer_strides[k] = d->step * st->pstrides[k];
      }
      else {
        lay.outer_strides[k] = st->pstrides[k];
      }
    }
    st->composed_base = base;
    memcpy(st->descs, plan->descs, src->ndim * sizeof(ca_axis_desc_t));
    memcpy(st->parent_axis_dims, plan->pdims, src->ndim * sizeof(ca_size_t));
    st->desc_ndim = src->ndim;
    ca_attach(parent);    /* window: finish detaches st->root */
    st->root       = parent;
    st->alias_mode = CA_ITER_ALIAS_STRIDED;
    st->alias_ptr  = (char *) parent->ptr;
    break;
  }

  case KI_L2_STACK: {
    /* The K parents are attached and read directly; the slab (the K cells
       along the stack axis) is cut into a slab-sized scratch, refilled
       from a tile cache of TILE fibers that the parents fill in one pass.
       CAStack guarantees one shape across its parents, so parents[0]
       gives the native strides of all of them. */
    CAStack  *stack       = (CAStack *) src;
    int8_t    parent_ndim = src->ndim - 1;
    ca_size_t K           = (ca_size_t) stack->n_parents;
    ca_size_t bytes       = (ca_size_t) src->bytes;
    ca_size_t tile;
    lay.slab_strides[axes[0]] = src->bytes;
    lay.mask_strides[axes[0]] = 1;
    ki_attach_stack_parents(st, stack);
    {
      ca_size_t s = src->bytes;
      for ( k = parent_ndim - 1; k >= 0; k-- ) {
        st->stack_parent_strides[k] = s;
        s *= stack->parents[0]->dim[k];
      }
    }
    st->scratch_cap = (ca_size_t) src->dim[axes[0]] * src->bytes;
    st->scratch_ptr = (char *) ki_data_alloc(src->data_type, st->scratch_cap);
    /* TILE budget = ~32 KB (half of M2 L1d), clamped to [8, 64] to keep
       the refill loop tight. */
    tile = K > 0 ? (32 * 1024) / (K * bytes) : 0;
    if ( tile < 8 )  tile = 8;
    if ( tile > 64 ) tile = 64;
    st->stack_tile_cap   = tile;
    st->stack_tile_pos   = 0;
    st->stack_tile_have  = 0;     /* force refill on first call */
    st->stack_tile_cache = (char *) ki_data_alloc(src->data_type, K * tile * bytes);
    st->alias_mode = CA_ITER_ALIAS_STACK;
    st->alias_ptr  = NULL;        /* no whole-view buffer */
    break;
  }

  case KI_L2_STACK_OUTER_K: {
    /* Each slab is a region inside ONE parent, picked by
       outer_idx[stack_k_outer_pos]; next_slab_axes points into
       parents[k]->ptr + parent_off.  A slab axis s of the stack is parent
       axis s, or s - 1 past the stack axis. */
    CAStack *stack       = (CAStack *) src;
    int8_t   k_axis      = stack->k_axis;
    int8_t   parent_ndim = src->ndim - 1;
    {
      ca_size_t sb = src->bytes, se = 1;
      for ( k = parent_ndim - 1; k >= 0; k-- ) {
        st->stack_parent_strides[k]      = sb;
        st->stack_parent_mask_strides[k] = se;
        sb *= stack->parents[0]->dim[k];
        se *= stack->parents[0]->dim[k];
      }
    }
    st->stack_k_outer_pos = 0;
    for ( k = 0; k < src->ndim; k++ ) {
      if ( plan->in_slab[k] ) {
        int8_t parent_ax = (k < k_axis) ? k : (k - 1);
        lay.slab_strides[k] = st->stack_parent_strides[parent_ax];
        lay.mask_strides[k] = st->stack_parent_mask_strides[parent_ax];
      }
      else if ( k < k_axis ) {
        st->stack_k_outer_pos++;
      }
    }
    ki_attach_stack_parents(st, stack);
    /* A masked stack: copy the K parent masks as they are at the start
       of the walk, and next_slab_axes points into the copy of parent k
       (promise 2).  The stack's mask may still read stand-ins for
       parents that have gained a mask since; read through to those. */
    if ( ca_has_mask(src) ) {
      ca_multi_parent_mask_refresh(src->mask, stack->parents,
                                   stack->mask_standins,
                                   stack->n_parents);
      /* Zero-filled: a slot is set once its copy is made, and finish
         frees the copies whose slot is set. */
      st->stack_parent_mask_ptrs =
          (boolean8_t **) xmalloc(stack->n_parents * sizeof(boolean8_t *));
      memset(st->stack_parent_mask_ptrs, 0,
             stack->n_parents * sizeof(boolean8_t *));
      for ( int32_t kk = 0; kk < stack->n_parents; kk++ ) {
        CArray     *pm   = ((CAStack *) src->mask)->parents[kk];
        ca_size_t   n    = pm->elements;
        boolean8_t *copy = (boolean8_t *) xmalloc(n > 0 ? n : 1);
        st->stack_parent_mask_ptrs[kk] = copy;
        ca_attach(pm);   /* window: only a memcpy before the detach */
        memcpy(copy, pm->ptr, n);
        ca_detach(pm);
      }
    }
    st->alias_mode = CA_ITER_ALIAS_STACK_OUTER_K;
    st->alias_ptr  = NULL;
    break;
  }

  case KI_L2_TRANSFER:
    ki_gather_view(st, src, flags, 0);
    st->alias_mode = CA_ITER_ALIAS_NONE;
    st->alias_ptr  = st->scratch_ptr;
    break;

  case KI_L2_ROOT_STRIDED:
    memcpy(st->composed_strides, plan->composed, src->ndim * sizeof(ca_size_t));
    st->composed_base = plan->base;
    memcpy(lay.slab_strides,  plan->composed, src->ndim * sizeof(ca_size_t));
    memcpy(lay.outer_strides, plan->composed, src->ndim * sizeof(ca_size_t));
    ca_attach(plan->root);            /* window: finish detaches st->root */
    st->root       = plan->root;      /* recorded once attached */
    st->alias_mode = CA_ITER_ALIAS_STRIDED;
    st->alias_ptr  = (char *) plan->root->ptr;
    break;

  case KI_L2_VIEW_SCRATCH:
    ca_iter_build_rowmajor_strides(st->composed_strides,
                                   src->dim, src->ndim, src->bytes);
    ki_gather_view(st, src, flags, 1);
    st->alias_mode = CA_ITER_ALIAS_NONE;
    st->alias_ptr  = st->scratch_ptr;
    break;

  case KI_L2_CONTIG:
    ca_iter_build_rowmajor_strides(st->composed_strides,
                                   src->dim, src->ndim, src->bytes);
    ca_attach(src);
    st->alias_mode = CA_ITER_ALIAS_CONTIG;
    st->alias_ptr  = (char *) src->ptr;
    break;
  }

  ki_lay_out_slabs(st, src, plan->in_slab, &lay);

  if ( plan->route == KI_L2_PER_SLAB ) {
    /* One max-slab buffer refilled per outer index, sized now that the
       slab is known.

       Shortcut PER_SLAB_HOIST.
       Layer       data; the fiber layer sits on top.
       Speeds up   per-slab gathers whose innermost slab axis is STRIDE
                   and with no SHIFT axis in the view: the outer and
                   non-innermost slab offsets are hoisted and the inner
                   run is copied with memcpy.
       Why         no difference measured on a row-selected 2-D read.
       Enters      at least one slab axis, the innermost slab axis
                   STRIDE, no SHIFT axis.
       Promises    2 and 6 (the mask is copied by ki_take_mask_copy, and
                   only when the view has one).
       Switch      ca_fast_paths_enabled(): off, the PER_SLAB gather.
       Checked by  the two-slab-axes rows of the grid parent in the
                   delivery matrix. */
    ca_size_t slab_bytes = st->slab_elements * src->bytes;
    int       hoist      = (st->slab_ndim > 0) && ca_fast_paths_enabled()
                           && plan->descs[st->slab_axes_buf[st->slab_ndim - 1]].kind
                              == CA_AXIS_KIND_STRIDE;
    for ( k = 0; hoist && k < src->ndim; k++ ) {
      if ( plan->descs[k].kind == CA_AXIS_KIND_SHIFT ) hoist = 0;
    }
    st->scratch_cap = slab_bytes > 0 ? slab_bytes : 1;
    st->scratch_ptr = (char *) ki_data_alloc(src->data_type, st->scratch_cap);
    st->alias_ptr   = st->scratch_ptr;  /* refilled per slab in next_slab_axes */
    st->alias_mode  = hoist ? CA_ITER_ALIAS_PER_SLAB_HOIST
                            : CA_ITER_ALIAS_PER_SLAB;
  }

  /* The mask cursor (promise 2): fiber by fiber through fiber_mask_scratch
     on PER_FIBER_FUSED, the parents' copies on STACK_OUTER_K, none on
     STACK (an unmasked stack), and the walk's copy of the whole view's
     mask everywhere else. */
  if ( plan->route == KI_L2_FIBER_FUSED || plan->route == KI_L2_STACK
       || plan->route == KI_L2_STACK_OUTER_K ) {
    st->alias_mask = NULL;
  }
  else {
    ki_take_mask_copy(st, src);
  }
}

static int
ca_iter_state_init_l2_unprotected (ca_iter_state    *st,
                       struct _CArray   *src,
                       ca_slab_policy_t  policy,
                       int8_t           *axes,
                       int8_t            naxes,
                       uint32_t          flags)
{
  ki_l2_plan plan;
  int        rc;

  /* Leave the state defined before anything can return.  Every error
     return below hands control back to a caller that may not look at the
     code, so what it is left holding has to be a state that iterates zero
     times rather than whatever its stack frame happened to contain. */
  if ( st == NULL ) return CA_ITER_ERR_FLAGS;
  memset(st, 0, sizeof(*st));
  if ( src == NULL ) return CA_ITER_ERR_FLAGS;

  /* A Face only layers a semantic identifier and a CALazyMarker only
     layers "leaf of a lazy chain"; storage is identical to the parent
     either way, so strip at the kernel-compute entry and descend.
     Routing and alias decisions belong to the parent.  Strip before
     validate_inputs: left on, both would classify as SRC_ATTACH (they
     have attach slots) and be materialised whole (see
     ca_iter_strip_storage_wrapper).

     The Face identifier is re-wrapped onto the result by the caller's lift
     hook (= primary operators / reductions / etc.).  The marker is not:
     a reduction over a lazy marker yields a plain entity.

     WRITE is rejected against the wrapper, before the strip — a marker is
     read-only while its parent is not.  validate_inputs re-checks the
     stripped source, which is harmless. */
  if ( (flags & CA_KERNEL_WRITE) && ca_is_readonly(src) ) {
    return CA_ITER_ERR_READONLY;
  }
  if ( ca_is_face(src) || ca_is_lazy_marker(src) ) {
    src = ca_iter_strip_storage_wrapper(src);
  }

  rc = ca_iter_validate_inputs(st, src, policy, flags);
  if ( rc != CA_ITER_OK ) return rc;
  /* L2 walks a slab of named axes.  The whole-array walk is L1
     (init_l1 with CA_SLAB_WHOLE); one strided run per innermost row is
     CA_SLAB_AXES with the last axis. */
  if ( policy != CA_SLAB_AXES ) return CA_ITER_ERR_POLICY;

  /* The slab axes: in range, no repeats. */
  if ( axes == NULL || naxes <= 0 || naxes > src->ndim ) {
    return CA_ITER_ERR_POLICY;
  }
  memset(plan.in_slab, 0, sizeof(plan.in_slab));
  for ( int8_t k = 0; k < naxes; k++ ) {
    int8_t ax = axes[k];
    if ( ax < 0 || ax >= src->ndim ) return CA_ITER_ERR_POLICY;
    if ( plan.in_slab[ax] )          return CA_ITER_ERR_POLICY;
    plan.in_slab[ax] = 1;
  }

  /* route_source returns the refined src_kind and, for descriptor
     sources, the descriptors, so the choice below does not describe the
     axes again. */
  plan.ndesc    = 0;
  plan.root     = NULL;
  plan.base     = 0;
  plan.src_kind = ca_iter_route_source(src, plan.descs, plan.pdims,
                                       &plan.ndesc);
  rc = ki_choose_l2_route(src, axes, naxes, flags, &plan);
  if ( rc != CA_ITER_OK ) return rc;

  ki_open_l2(st, src, policy, axes, naxes, flags, &plan);
  return CA_ITER_OK;
}

static int
ca_iter_state_next_slab_unprotected (ca_iter_state *st,
                         char         **out_ptr,
                         boolean8_t   **out_mask,
                         ca_size_t     *out_n)
{
  if ( st == NULL || st->level != 1
       || st->slabs_emitted >= st->total_slabs ) {
    if ( out_ptr  ) *out_ptr  = NULL;
    if ( out_mask ) *out_mask = NULL;
    if ( out_n    ) *out_n    = 0;
    return 0;
  }
  /* L1 WHOLE policy: a single slab whose ptr is either parent->ptr
     (alias) or the scratch buffer.  alias_mask is populated in init
     when the source carries a mask (NULL otherwise). */
  if ( out_ptr  ) *out_ptr  = st->alias_ptr;
  if ( out_mask ) *out_mask = st->alias_mask;
  if ( out_n    ) *out_n    = st->slab_n;
  st->slabs_emitted += 1;
  return 1;
}


/* CA_KERNEL_FIBER_CONTIG: a fiber (a walk with one slab axis) reaches the
   kernel as a contiguous run of cells and of mask flags.  Each path of
   next_slab_axes finds the fiber's first cell and the step along it, and
   hands both through these two functions, which copy a fiber with any
   other step into the walk's fiber scratch.  Other walks get the pointer
   back unchanged. */
static int
ki_fiber_contig_wanted (const ca_iter_state *st)
{
  return (st->flags & CA_KERNEL_FIBER_CONTIG)
         && st->naxes == 1 && st->slab_ndim == 1;
}

static char *
ki_fiber_contig_data (ca_iter_state *st, char *data, ca_size_t step)
{
  ca_size_t n     = st->slab_dims[0];
  ca_size_t bytes = st->bytes;
  ca_size_t need  = n * bytes;
  if ( ! ki_fiber_contig_wanted(st) || step == bytes ) {
    return data;
  }
  if ( st->fiber_data_scratch_cap < need ) {
    if ( st->fiber_data_scratch ) ki_data_free(st->fiber_data_scratch, st->fiber_data_scratch_cap);
    st->fiber_data_scratch     = (char *) ki_data_alloc(st->src->data_type, need);
    st->fiber_data_scratch_cap = need;
  }
  ca_stride_gather_run(st->fiber_data_scratch, data, bytes, n, step);
  return st->fiber_data_scratch;
}

static boolean8_t *
ki_fiber_contig_mask (ca_iter_state *st, boolean8_t *mask, ca_size_t step)
{
  ca_size_t n = st->slab_dims[0];
  if ( mask == NULL || ! ki_fiber_contig_wanted(st) || step == 1 ) {
    return mask;
  }
  if ( st->fiber_mask_scratch_cap < n ) {
    if ( st->fiber_mask_scratch ) xfree(st->fiber_mask_scratch);
    st->fiber_mask_scratch     = (boolean8_t *) xmalloc(n > 0 ? n : 1);
    st->fiber_mask_scratch_cap = n;
  }
  for ( ca_size_t i = 0; i < n; i++ ) {
    st->fiber_mask_scratch[i] = mask[i * step];
  }
  return st->fiber_mask_scratch;
}

static int
ca_iter_state_next_slab_axes_unprotected (ca_iter_state *st,
                              char         **out_ptr,
                              boolean8_t   **out_mask)
{
  if ( st == NULL || st->policy != CA_SLAB_AXES || st->level != 2
       || st->slabs_emitted >= st->total_slabs ) {
    if ( out_ptr  ) *out_ptr  = NULL;
    if ( out_mask ) *out_mask = NULL;
    return 0;
  }

  /* PER_SLAB_HOIST (see its name tag in ki_open_l2): the innermost slab
     axis is STRIDE and no axis is SHIFT.  The outer and non-innermost
     slab offsets are computed once per slab row, and the inner run is a
     plain memcpy instead of the descriptor engine's per-cell walk. */
  if ( st->alias_mode == CA_ITER_ALIAS_PER_SLAB_HOIST ) {
    int8_t    inner_view_ax   = st->slab_axes_buf[st->slab_ndim - 1];
    ca_size_t inner_count     = st->descs[inner_view_ax].count;
    ca_size_t inner_pstride   = st->pstrides[inner_view_ax];
    ca_size_t inner_byte_step = st->descs[inner_view_ax].step * inner_pstride;
    ca_size_t inner_byte_base = st->descs[inner_view_ax].start * inner_pstride;
    ca_size_t bytes           = st->bytes;

    /* Outer contribution (hoisted, computed once per next_slab_axes
       call): walks outer_axes with their kind-specific offset.  No
       SHIFT here (init ruled out SHIFT-anywhere). */
    ca_size_t outer_off = 0;
    for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
      int8_t    ax  = st->outer_axes[m];
      ca_size_t pos = st->outer_idx[m];
      if ( st->descs[ax].kind == CA_AXIS_KIND_STRIDE ) {
        outer_off += (st->descs[ax].start + pos * st->descs[ax].step)
                   * st->pstrides[ax];
      } else { /* INDEX */
        outer_off += st->descs[ax].indices[pos] * st->pstrides[ax];
      }
    }

    /* Non-innermost slab axes: walk row-major via single linear cursor.
       For sp = 1 (single slab axis = innermost STRIDE), the outer
       row-major loop runs once with nonin_off = 0. */
    int8_t    nonin_n = st->slab_ndim - 1;
    int8_t    nonin_view_ax[CA_RANK_MAX];
    ca_size_t nonin_count[CA_RANK_MAX];
    ca_size_t nonin_idx[CA_RANK_MAX];
    ca_size_t nonin_total = 1;
    for ( int8_t s = 0; s < nonin_n; s++ ) {
      nonin_view_ax[s] = st->slab_axes_buf[s];
      nonin_count[s]   = st->descs[nonin_view_ax[s]].count;
      nonin_idx[s]     = 0;
      nonin_total     *= nonin_count[s];
    }

    char *parent_base = (char *) st->root->ptr + outer_off + inner_byte_base;
    for ( ca_size_t nlin = 0; nlin < nonin_total; nlin++ ) {
      /* Compute non-innermost-slab contribution at current nonin_idx. */
      ca_size_t nonin_off = 0;
      for ( int8_t s = 0; s < nonin_n; s++ ) {
        int8_t    ax  = nonin_view_ax[s];
        ca_size_t pos = nonin_idx[s];
        if ( st->descs[ax].kind == CA_AXIS_KIND_STRIDE ) {
          nonin_off += (st->descs[ax].start + pos * st->descs[ax].step)
                     * st->pstrides[ax];
        } else { /* INDEX */
          nonin_off += st->descs[ax].indices[pos] * st->pstrides[ax];
        }
      }

      /* Inner loop: pure STRIDE linear copy of inner_count cells.
         For unit-bytes step == bytes (= contig run) the compiler can
         hoist this into a single memcpy.  Otherwise per-cell memcpy
         with linear stride (= SIMD-friendly). */
      char *dst      = st->scratch_ptr + nlin * inner_count * bytes;
      char *src_base = parent_base + nonin_off;
      if ( inner_byte_step == (ca_size_t) bytes ) {
        memcpy(dst, src_base, inner_count * bytes);
      } else {
        for ( ca_size_t i = 0; i < inner_count; i++ ) {
          memcpy(dst + i * bytes, src_base + i * inner_byte_step, bytes);
        }
      }

      /* Advance nonin_idx row-major (last axis ticks fastest). */
      for ( int8_t s = nonin_n - 1; s >= 0; s-- ) {
        if ( ++nonin_idx[s] < nonin_count[s] ) break;
        nonin_idx[s] = 0;
      }
    }

    /* Mask offset (= same as fallback path, whole-view mask scratch). */
    ca_size_t mask_off = 0;
    for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
      mask_off += st->outer_idx[m] * st->outer_mask_strides[m];
    }

    if ( out_ptr  ) *out_ptr  = st->scratch_ptr;
    if ( out_mask ) {
      *out_mask = ki_fiber_contig_mask(st,
                    st->scratch_mask ? st->scratch_mask + mask_off : NULL,
                    st->slab_mask_strides[0]);
    }

    st->slabs_emitted += 1;
    for ( int8_t m = st->outer_ndim - 1; m >= 0; m-- ) {
      if ( ++st->outer_idx[m] < st->outer_dims[m] ) break;
      st->outer_idx[m] = 0;
    }
    return 1;
  }

  /* CAStack source with the stack axis k_axis in the outer iteration.
     Each slab is a region inside parents[k]->ptr where k =
     outer_idx[K_outer_pos].  Parent inner byte offset = Σ outer_idx[m] *
     stack_parent_strides[parent_ax] over all outer axes except the K-axis
     itself.  Mask: a pointer into the copy of parent k's mask that init
     took (stack_parent_mask_ptrs[k] + mask_off); a write through it
     reaches nothing.  The data is yielded in place unless FIBER_CONTIG
     needs a strided fiber gathered (ki_fiber_contig_data).  A stack axis
     s other than k_axis is parent axis s, or s - 1 past k_axis. */
  if ( st->alias_mode == CA_ITER_ALIAS_STACK_OUTER_K ) {
    int8_t   kpos = st->stack_k_outer_pos;
    int32_t  k    = (int32_t) st->outer_idx[kpos];
    int8_t   k_axis = ((CAStack *) st->src)->k_axis;

    ca_size_t parent_off = 0;     /* byte offset within parent data */
    ca_size_t mask_off   = 0;     /* element offset within parent mask */
    for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
      if ( m == kpos ) continue;
      int8_t stack_ax  = st->outer_axes[m];
      int8_t parent_ax = (stack_ax < k_axis) ? stack_ax : (stack_ax - 1);
      parent_off += st->outer_idx[m] * st->stack_parent_strides[parent_ax];
      mask_off   += st->outer_idx[m] * st->stack_parent_mask_strides[parent_ax];
    }

    if ( out_ptr  ) {
      *out_ptr = ki_fiber_contig_data(st, st->stack_parent_ptrs[k] + parent_off,
                                      st->slab_strides[0]);
    }
    if ( out_mask ) {
      *out_mask = ki_fiber_contig_mask(st,
                    st->stack_parent_mask_ptrs
                    ? st->stack_parent_mask_ptrs[k] + mask_off : NULL,
                    st->slab_mask_strides[0]);
    }

    st->slabs_emitted += 1;
    for ( int8_t m = st->outer_ndim - 1; m >= 0; m-- ) {
      if ( ++st->outer_idx[m] < st->outer_dims[m] ) break;
      st->outer_idx[m] = 0;
    }
    return 1;
  }

  /* CAStack read along its stack axis, from the parents' memory.  For
     each outer index, compute the
     parent inner byte offset (= same across all K parents, uniform
     shape), and yield the K cells of that fiber out of stack_tile_cache,
     which is refilled TILE fibers at a time from the cached parent ptrs
     (below).  No ca_xfer_stride dispatch.  The scratch_ptr init
     allocates is not used by this path.

     init engages this path only for slab_axes == [k_axis], so the outer
     axes are the stack axes other than k_axis, which are the parent axes
     in order: outer_idx[m] maps to parent axis m. */
  if ( st->alias_mode == CA_ITER_ALIAS_STACK ) {
    /* Tile cache.  Outer iter
       walks parent storage in row-major order so parent_off increments
       by `bytes` per call monotonically.  Refill TILE fibers at once
       via K contig parent streams (= TILE consecutive cells from each
       parent), transposed into cache[t][k] layout.  Subsequent (TILE-1)
       next_slab calls alias into the cache. */
    if ( st->stack_tile_pos >= st->stack_tile_have ) {
      ca_size_t bytes = st->bytes;
      ca_size_t parent_off = 0;
      for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
        parent_off += st->outer_idx[m] * st->stack_parent_strides[m];
      }
      ca_size_t want = st->stack_tile_cap;
      ca_size_t remaining = st->total_slabs - st->slabs_emitted;
      if ( want > remaining ) want = remaining;
      st->stack_tile_have = want;
      st->stack_tile_pos  = 0;

      char    **pptrs = st->stack_parent_ptrs;
      int32_t   K     = st->stack_n_parents;
      char     *cache = st->stack_tile_cache;
      ca_size_t stride_t = (ca_size_t) K * bytes;   /* cache[t][*] stride */

      if ( bytes == 8 ) {
        /* f64 / i64 hot path: store one cell per inner iter, compiler
           can keep `src` in a vector reg and stream cleanly. */
        for ( int32_t kk = 0; kk < K; kk++ ) {
          const uint64_t *src = (const uint64_t *)
                                (pptrs[kk] + parent_off);
          uint64_t *dst = (uint64_t *) (cache + (ca_size_t) kk * bytes);
          for ( ca_size_t t = 0; t < want; t++ ) {
            *(uint64_t *)((char *) dst + t * stride_t) = src[t];
          }
        }
      } else if ( bytes == 4 ) {
        for ( int32_t kk = 0; kk < K; kk++ ) {
          const uint32_t *src = (const uint32_t *)
                                (pptrs[kk] + parent_off);
          uint32_t *dst = (uint32_t *) (cache + (ca_size_t) kk * bytes);
          for ( ca_size_t t = 0; t < want; t++ ) {
            *(uint32_t *)((char *) dst + t * stride_t) = src[t];
          }
        }
      } else {
        for ( int32_t kk = 0; kk < K; kk++ ) {
          const char *src = pptrs[kk] + parent_off;
          char       *dst = cache + (ca_size_t) kk * bytes;
          for ( ca_size_t t = 0; t < want; t++ ) {
            memcpy(dst + t * stride_t, src + t * bytes, bytes);
          }
        }
      }
    }

    if ( out_ptr  ) {
      *out_ptr = st->stack_tile_cache
               + st->stack_tile_pos
                 * (ca_size_t) st->stack_n_parents * st->bytes;
    }
    if ( out_mask ) *out_mask = NULL;

    st->stack_tile_pos += 1;
    st->slabs_emitted  += 1;
    for ( int8_t m = st->outer_ndim - 1; m >= 0; m-- ) {
      if ( ++st->outer_idx[m] < st->outer_dims[m] ) break;
      st->outer_idx[m] = 0;
    }
    return 1;
  }

  /* PER_SLAB: one slab gathered by ca_axis_dispatch_gather, from a
     subset of the descriptors with the outer axes pinned at the current
     outer_idx position.  scratch_ptr is sized for one slab and reused for
     every slab. */
  if ( st->alias_mode == CA_ITER_ALIAS_PER_SLAB ) {
    ca_axis_desc_t subset_descs[CA_RANK_MAX];
    memcpy(subset_descs, st->descs, st->ndim * sizeof(ca_axis_desc_t));

    for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
      int8_t    ax  = st->outer_axes[m];
      ca_size_t pos = st->outer_idx[m];
      switch ( st->descs[ax].kind ) {
        case CA_AXIS_KIND_STRIDE:
          subset_descs[ax].start = st->descs[ax].start
                                 + pos * st->descs[ax].step;
          subset_descs[ax].step  = 0;
          subset_descs[ax].count = 1;
          break;
        case CA_AXIS_KIND_INDEX:
          /* Borrow into the indices[] array at offset pos; count=1
             means engine reads indices[0] which is original indices[pos].
             No allocation, no mutation of the producer's array. */
          subset_descs[ax].indices = &st->descs[ax].indices[pos];
          subset_descs[ax].count   = 1;
          break;
        case CA_AXIS_KIND_SHIFT:
          /* SHIFT outer pinned at pos: collapse to a count=1 axis at the
             projected start.  size0 / policy unchanged so engine's
             bound check + bound_fill writeback still applies if the
             projected position is OOB. */
          subset_descs[ax].start = st->descs[ax].start
                                 + pos * st->descs[ax].step;
          subset_descs[ax].step  = 0;
          subset_descs[ax].count = 1;
          break;
      }
    }

    /* CAWindow fill value (the same lookup as in ki_open_l2). */
    const void *bound_fill = NULL;
    if ( ca_func[st->src->obj_type].attach == ca_window_func.attach ) {
      bound_fill = ((CAWindow *) st->src)->fill;
    }

    ca_axis_dispatch_gather(st->root, st->parent_axis_dims, subset_descs,
                            st->ndim, st->bytes, st->slab_elements,
                            bound_fill, st->scratch_ptr);

    /* Mask offset into the whole-view mask copy, which is view
       row-major to match slab_mask_strides. */
    ca_size_t mask_off = 0;
    for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
      mask_off += st->outer_idx[m] * st->outer_mask_strides[m];
    }

    if ( out_ptr  ) *out_ptr  = st->scratch_ptr;
    if ( out_mask ) {
      *out_mask = ki_fiber_contig_mask(st,
                    st->scratch_mask ? st->scratch_mask + mask_off : NULL,
                    st->slab_mask_strides[0]);
    }

    st->slabs_emitted += 1;
    /* Advance outer_idx row-major (innermost outer axis ticks first). */
    for ( int8_t m = st->outer_ndim - 1; m >= 0; m-- ) {
      if ( ++st->outer_idx[m] < st->outer_dims[m] ) break;
      st->outer_idx[m] = 0;
    }
    return 1;
  }

  /* Per-slab base offsets via outer_idx walk.  Data offset uses
     outer_strides (byte units); mask offset uses outer_mask_strides
     (element units, view row-major).  Both are zero when outer_ndim
     == 0 (= all-axes WHOLE-equivalent case).

     STRIDE outer axes (SRC_CASTRIDE, and the STRIDE axes of a descriptor
     view) use outer_idx[m] directly as the multiplier.  INDEX outer axes
     of a descriptor view need an indices[] lookup: multiplier = descs[axis].indices[outer_idx[m]].
     Mask offset uses outer_idx[m] directly in both cases (= mask
     scratch is in view row-major order, outer_idx walks view-axis
     positions). */
  ca_size_t data_off = st->composed_base;
  ca_size_t mask_off = 0;
  int       has_descs = (st->src_kind == CA_ITER_SRC_DESCRIPTOR
                         && st->desc_ndim > 0);
  for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
    ca_size_t multiplier = st->outer_idx[m];
    if ( has_descs ) {
      int8_t ax = st->outer_axes[m];
      if ( st->descs[ax].kind == CA_AXIS_KIND_INDEX ) {
        multiplier = st->descs[ax].indices[st->outer_idx[m]];
      }
    }
    data_off += multiplier * st->outer_strides[m];
    mask_off += st->outer_idx[m] * st->outer_mask_strides[m];
  }

  /* PER_FIBER_FUSED: there is no whole-view buffer to alias from.  Build
     the fiber region from outer_idx + fiber_axis and call
     ca_xfer_stride(src, ..., GET) directly into fiber_data_scratch; the
     view's region transfer (out-of-bounds filling for CAWindow / CAShift,
     the conversion for a fake or byte-swap view) delivers it in one
     pass.

     last_data_off carries the fiber region's outer footprint so
     sync_slab can reconstruct the same region for WRITE PUT.  Encode
     it as the linear outer_idx position scaled by fiber_axis stride
     equivalence; for PER_FIBER_FUSED sync_slab reads outer_idx state
     directly rather than data_off so the value is informational. */
  if ( st->alias_mode == CA_ITER_ALIAS_PER_FIBER_FUSED ) {
    ca_size_t  fiber_n     = st->slab_dims[0];
    ca_size_t  need        = fiber_n * st->bytes;
    int8_t     fiber_ax    = st->fiber_axis;
    int8_t     nd          = st->ndim;
    ca_size_t  starts[CA_RANK_MAX];
    ca_size_t  counts[CA_RANK_MAX];

    if ( st->fiber_data_scratch_cap < need ) {
      if ( st->fiber_data_scratch ) ki_data_free(st->fiber_data_scratch, st->fiber_data_scratch_cap);
      st->fiber_data_scratch     = (char *) ki_data_alloc(st->src->data_type, need);
      st->fiber_data_scratch_cap = need;
    }

    /* Build fiber region: fiber_axis spans the full fiber, all other
       axes pinned to outer_idx position (count=1).  Cache starts[] in
       state so sync_slab can rebuild the same region for WRITE PUT
       (= captured BEFORE the outer_idx advance below, the same hazard as
       last_data_off; see sync_slab). */
    {
      int8_t op = 0;
      for ( int8_t k = 0; k < nd; k++ ) {
        if ( k == fiber_ax ) {
          starts[k] = 0;
          counts[k] = fiber_n;
        } else {
          starts[k] = st->outer_idx ? st->outer_idx[op] : 0;
          counts[k] = 1;
          op++;
        }
        st->fiber_region_starts[k] = starts[k];
      }
    }

    st->last_data_off = 0;  /* not used for PER_FIBER_FUSED */

    ca_xfer_stride(st->src, starts, counts, st->fiber_native_strides,
                   st->fiber_data_scratch, CA_XFER_GET);

    char       *yield_ptr  = st->fiber_data_scratch;
    boolean8_t *yield_mask = NULL;

    if ( ca_has_mask(st->src) ) {
      if ( st->fiber_mask_scratch_cap < fiber_n ) {
        if ( st->fiber_mask_scratch ) xfree(st->fiber_mask_scratch);
        st->fiber_mask_scratch     = (boolean8_t *) xmalloc(fiber_n > 0 ? fiber_n : 1);
        st->fiber_mask_scratch_cap = fiber_n;
      }
      /* Mask uses element strides (= bytes 1 per cell, identity).
         Reuse fiber_native_strides scaled down by bytes for mask;
         actually mask is boolean8_t (1 byte per cell), so native
         strides over src->mask are simply Π dims (= element index
         strides).  Compute on the fly. */
      ca_size_t mask_strides[CA_RANK_MAX];
      {
        ca_size_t s = 1;
        for ( int8_t k = nd - 1; k >= 0; k-- ) {
          mask_strides[k] = s;
          s *= st->src->dim[k];
        }
      }
      ca_xfer_stride(st->src->mask, starts, counts, mask_strides,
                     (char *) st->fiber_mask_scratch, CA_XFER_GET);
      yield_mask = st->fiber_mask_scratch;
    }

    if ( out_ptr  ) *out_ptr  = yield_ptr;
    if ( out_mask ) *out_mask = yield_mask;

    /* Advance outer_idx (= same logic as default fall-through). */
    st->slabs_emitted += 1;
    for ( int8_t m = st->outer_ndim - 1; m >= 0; m-- ) {
      if ( ++st->outer_idx[m] < st->outer_dims[m] ) break;
      st->outer_idx[m] = 0;
    }
    return 1;
  }

  /* Contiguous fiber delivery (promise 1).  For naxes==1 (= single slab axis = fiber) the catalog contract
     CA_FOR_EACH_FIBER promises contig data delivery.  When the fiber
     is not innermost-contig (= slab_strides[0] != bytes), the engine
     gathers the fiber into fiber_data_scratch before yielding so the
     author can write p[i] without stride math.

     Capture last_data_off BEFORE the outer_idx advance below; sync_slab
     consumes it for WRITE scatter.  See the header field and the hazard
     comment in sync_slab. */
  /* sync_slab finds the slab here: the fiber it scatters back, and the
     cells of a whole-view scratch it compares. */
  st->last_data_off = data_off;
  char       *yield_ptr  = ki_fiber_contig_data(st, st->alias_ptr + data_off,
                                                st->slab_strides[0]);
  boolean8_t *yield_mask = ki_fiber_contig_mask(st,
                             st->alias_mask ? st->alias_mask + mask_off : NULL,
                             st->slab_mask_strides[0]);

  if ( out_ptr ) *out_ptr = yield_ptr;
  if ( out_mask ) *out_mask = yield_mask;

  st->slabs_emitted += 1;

  /* Advance outer_idx row-major (innermost outer axis ticks first).
     No-op when outer_ndim == 0 (= single slab walk). */
  for ( int8_t m = st->outer_ndim - 1; m >= 0; m-- ) {
    if ( ++st->outer_idx[m] < st->outer_dims[m] ) break;
    st->outer_idx[m] = 0;
  }
  return 1;
}

static void
ca_iter_state_sync_slab_unprotected (ca_iter_state *st)
{
  /* READ walk: nothing to sync. */
  if ( st == NULL || !(st->flags & CA_KERNEL_WRITE) ) return;

  /* Neither stack mode can be reached with WRITE set: both are declined
     at init, which sends a write destination down the generic SRC_ATTACH
     path instead.  They cannot serve a write themselves -- ALIAS_STACK
     hands out a tile cache that finish frees, and STACK_OUTER_K aliases
     parents[k]->ptr, which is the attach buffer rather than the parent's
     own memory whenever the parent is a view.  Scattering per parent
     would let the fast paths carry writes too; until then this branch is
     just the assertion that they are not asked to. */
  if ( st->alias_mode == CA_ITER_ALIAS_STACK
       || st->alias_mode == CA_ITER_ALIAS_STACK_OUTER_K ) {
    st->write_dirty = 0;
    return;
  }

  /* ======================================================================
   *           !!! CORRECTNESS HAZARD - DO NOT MOVE !!!
   *
   * Per-fiber scratch reuse + scatter correctness depends on the strict
   * evaluation order of the CA_FOR_EACH_FIBER_* macro sandwich:
   *
   *     for ( init ; next_slab_axes(k) ; sync_slab(k) ) { body(k) }
   *
   * Concretely: sync_slab(fiber k) MUST run BEFORE next_slab_axes(k+1).
   * The invariant at sync_slab(k) time:
   *
   *   - st->fiber_data_scratch holds author-written data for fiber k
   *     (= body(k) just modified it, no other call has touched it since)
   *   - st->last_data_off holds the source byte offset for fiber k
   *     (= captured by next_slab_axes(k) before outer_idx advance)
   *
   * next_slab_axes(k+1) will overwrite BOTH (= refill scratch + advance
   * last_data_off) BEFORE body(k+1) starts.  Per-fiber scratch reuse
   * (= only one buffer for all fibers) is correct ONLY because this
   * sequence holds.
   *
   * DO NOT introduce: prefetch of next_slab_axes(k+1), async sync_slab,
   * sandwich reordering, batched sync, or any pattern that breaks the
   * (next -> body -> sync -> next -> body -> sync ...) sequence.  Per-
   * fiber scratch reuse becomes UB the moment this invariant is violated.
   * If lookahead / batching is needed, allocate one scratch per fiber
   * instead of reusing -- separate phase, separate design.
   * ====================================================================== */

  /* PER_FIBER_FUSED write: the author
     wrote into fiber_data_scratch and there is no whole-view buffer
     to xfer_all PUT.  Rebuild the same fiber region from cached
     fiber_region_starts[] (= captured pre-advance in next_slab_axes,
     the same hazard as last_data_off) and call ca_xfer_stride(src, ...,
     PUT), which puts the fiber back through the view's region transfer
     in one pass. */
  if ( st->alias_mode == CA_ITER_ALIAS_PER_FIBER_FUSED ) {
    ca_size_t fiber_n = st->slab_dims[0];
    int8_t    nd      = st->ndim;
    ca_size_t counts[CA_RANK_MAX];
    for ( int8_t k = 0; k < nd; k++ ) {
      counts[k] = (k == st->fiber_axis) ? fiber_n : 1;
    }
    ca_xfer_stride(st->src, st->fiber_region_starts, counts,
                   st->fiber_native_strides,
                   st->fiber_data_scratch, CA_XFER_PUT);
    st->write_dirty = 0;
    return;
  }

  /* Per-fiber gather path scatter.
     When next_slab_axes gathered the fiber into fiber_data_scratch
     (= naxes==1 + slab_strides[0] != bytes), scatter it back to the
     source layout via the strided write.  When the fiber was the
     contig fast path (= data_step == bytes), the author wrote directly
     into the source via alias_ptr; no scatter needed. */
  if ( (st->flags & CA_KERNEL_FIBER_CONTIG)
       && st->naxes == 1 && st->slab_ndim == 1
       && st->fiber_data_scratch != NULL ) {
    ca_size_t n         = st->slab_dims[0];
    ca_size_t data_step = st->slab_strides[0];
    ca_size_t bytes     = st->bytes;
    if ( data_step != (ca_size_t) bytes ) {
      char *dst = st->alias_ptr + st->last_data_off;
      /*                          ^ captured by next_slab_axes(k) BEFORE
       *                            outer_idx advance; see hazard above. */
      /* Typed scatter helper (ca_iter_substrate.h): same SIMD-friendly
         loop structure as ca_stride_gather_run, in reverse direction. */
      ca_stride_scatter_run(dst, st->fiber_data_scratch,
                            bytes, n, data_step);
    }
    /* Fall through.  The gather above is not specific to a src_kind --
       it fires for any source whose fiber is not innermost-contig -- so
       for SRC_ATTACH this has just written the fiber back into the
       whole-view scratch, and the push-back below carries it to the
       source.  For the alias paths scratch_ptr is NULL and the push-back
       below is skipped. */
  }

  /* alias path: the kernel wrote through alias_ptr into the memory the
     walk borrowed, so nothing is scattered.  Applies to all CAStride alias and to
     STRIDE-only descriptor alias (SRC_DESCRIPTOR_L2_ALIASABLE), whose
     scratch_ptr is NULL too.  An alias walk over a view root is written
     back once, by finish (ca_sync_detach on the root). */
  if ( st->scratch_ptr == NULL ) return;

  /* scratch path: the kernel wrote into a whole-view scratch, and the
     changed cells go back through the view's own transfer, which
     converts, packs or scatters them as the view requires (promise 3).
     Every write walk that reads a scratch gathered it with
     ki_gather_view, which keeps the copy the comparison needs: the
     transfer walk (SRC_ATTACH) and the CAStride paths that read a
     gathered copy.  The descriptor engine's own gathers serve reads
     only; a write over a descriptor view is sent to the transfer walk
     at init.

     This has to stay below the two per-fiber blocks: pushing back first
     would send the whole-view buffer while the fiber the author actually
     wrote sat unscattered in fiber_data_scratch. */
  if ( st->src_kind != CA_ITER_SRC_ATTACH
       && st->src_kind != CA_ITER_SRC_CASTRIDE ) {
    rb_bug("kernel iterator: a write walk over a scratch with nothing to "
           "compare it against (src_kind %d)", (int) st->src_kind);
  }
  ki_scratch_push_changed(st);
  st->write_dirty = 0;
}

static VALUE ca_iter_finish_sync (VALUE arg);

static VALUE
ki_sync_detach_root (VALUE root)
{
  ca_sync_detach((CArray *) root);
  return Qnil;
}

void
ca_iter_state_finish (ca_iter_state *st)
{
  if ( st == NULL || st->src == NULL ) {
    return;
  }
  /* A slab still handed out is dropped: finish abandons it.  The block
     macros close with ca_iter_state_close, which writes it back first. */
  st->write_dirty = 0;
  /* composed_strides is inline — no free needed.  outer_idx is heap
     for L2 multi-d sources (NULL on L1 paths and on L2 0/1-d). */
  if ( st->outer_idx ) {
    xfree(st->outer_idx);
    st->outer_idx = NULL;
  }
  /* Lifecycle cleanup — orders matter slightly (free scratch before
     detaching parent so the kernel iterator's resources are released
     symmetrically with init):
       - scratch_ptr: owned by the iterator (every gather into scratch:
         CAStride non-contig, descriptor, SRC_ATTACH, per-slab, stack).
         ki_data_free.
       - root: descriptor parent or CAStride compose-fold root attached
         at init.  ca_detach, or ca_sync_detach on a WRITE walk.
       - else (alias paths): src was attached at init, detach. */
  if ( st->scratch_ptr ) {
    ki_data_free(st->scratch_ptr, st->scratch_cap);
    st->scratch_ptr = NULL;
    st->scratch_cap = 0;
  }
  if ( st->scratch_mask ) {
    xfree(st->scratch_mask);
    st->scratch_mask = NULL;
  }
  /* The per-fiber scratch. */
  if ( st->fiber_data_scratch ) {
    ki_data_free(st->fiber_data_scratch, st->fiber_data_scratch_cap);
    st->fiber_data_scratch     = NULL;
    st->fiber_data_scratch_cap = 0;
  }
  if ( st->fiber_mask_scratch ) {
    xfree(st->fiber_mask_scratch);
    st->fiber_mask_scratch     = NULL;
    st->fiber_mask_scratch_cap = 0;
  }
  /* Detach the K parents init attached and free the cached ptr array
     (symmetric with init_l2's per-parent ca_attach loop).  The parent
     mask copies are freed separately below; they were never attached
     for the walk. */
  if ( st->stack_parent_ptrs ) {
    CAStack *stack = (CAStack *) st->src;
    for ( int32_t kk = 0; kk < st->stack_n_parents; kk++ ) {
      ca_detach(stack->parents[kk]);
    }
    xfree(st->stack_parent_ptrs);
    st->stack_parent_ptrs = NULL;
  }
  /* The STACK tile cache. */
  if ( st->stack_tile_cache ) {
    ki_data_free(st->stack_tile_cache, 0);
    st->stack_tile_cache = NULL;
    st->stack_tile_cap   = 0;
    st->stack_tile_pos   = 0;
    st->stack_tile_have  = 0;
  }
  if ( st->stack_parent_mask_ptrs ) {
    for ( int32_t kk = 0; kk < st->stack_n_parents; kk++ ) {
      if ( st->stack_parent_mask_ptrs[kk] ) {
        xfree(st->stack_parent_mask_ptrs[kk]);
      }
    }
    xfree(st->stack_parent_mask_ptrs);
    st->stack_parent_mask_ptrs = NULL;
  }
  st->stack_n_parents = 0;
  {
    /* The state is emptied before anything here can raise: syncing a
       write walk's root goes through the root's slots.  A finish that
       raised is then finished already, and a second call returns at once
       instead of detaching src again. */
    CArray *root       = st->root;
    CArray *src        = st->src;
    CArray *own        = (st->flags & CA_ITER_FLAG_OWNS_SRC) ? src : NULL;
    int     write      = (st->flags & CA_KERNEL_WRITE) != 0;
    int     detach_src = root == NULL
                         && ( st->alias_mode == CA_ITER_ALIAS_CONTIG
                              || st->alias_mode == CA_ITER_ALIAS_STRIDED );
    int     tag        = 0;
    st->root       = NULL;
    st->src        = NULL;
    st->alias_ptr  = NULL;
    st->flags     &= ~CA_ITER_FLAG_OWNS_SRC;
    if ( root ) {
      /* A write walk wrote into the root's attach buffer, which is the root
         itself only for an entity: a view root (a transpose, a non-contig
         block, a view lending no memory) gave a buffer of its own. */
      if ( write ) {
        /* protect: frees the iterator's own copy before the raise passes on */
        rb_protect(ki_sync_detach_root, (VALUE) root, &tag);
      }
      else {
        ca_detach(root);
      }
    }
    else if ( detach_src ) {
      /* alias path (CONTIG/STRIDED for CAStride family): we attached
         src directly at init, so detach it here.  A SRC_ATTACH walk owns
         its own scratch (alias_mode = NONE, freed above) and attached
         nothing to detach. */
      ca_detach(src);
    }
    if ( own ) {
      if ( ca_is_object_type(own) ) {
        ca_gc_release_buffer(own->ptr);
      }
      ca_free(own);
    }
    if ( tag ) {
      rb_jump_tag(tag);
    }
  }
}

/* Finish a walk the way the block macros leave it: a slab of a write walk
   still handed out -- the body left with `break` -- is written back
   first.  A raise from the write-back is passed on once the walk is
   finished. */
void
ca_iter_state_close (ca_iter_state *st)
{
  int tag = 0;
  if ( st != NULL && st->src != NULL && st->write_dirty ) {
    rb_protect(ca_iter_finish_sync, (VALUE) st, &tag);
  }
  ca_iter_state_finish(st);
  if ( tag ) {
    rb_jump_tag(tag);
  }
}

/* ---- Raise-safe entry points ----------------------------------------
 *
 * A walk reads its source, and a source that converts as it is read (a
 * lazy view over an object array, say) raises when it meets a cell it
 * cannot convert.  The caller's loop then never reaches
 * ca_iter_state_finish -- the block macros put it in the `for`
 * increment, which a raise jumps over, and it is past the raise in
 * hand-written walks too.  So the walk finishes itself on the way out.
 *
 * Every entry point that can raise is called through rb_protect here,
 * and ca_iter_state_finish is idempotent (it clears st->src), so the
 * caller's own finish after an ordinary walk stays correct.
 *
 * Not covered here: a kernel body that raises.  It runs in the caller's
 * frame, between two calls of these functions, where the engine has no
 * hold on it.  A body that can raise runs through ca_iter_ensure below.
 *
 * init runs protected always -- once per walk, next to a materialise.
 * next_slab / sync_slab are called once per slab, in walks whose whole
 * per-fiber cost can be a few nanoseconds, so they are protected only
 * when this walk can raise at all: when it gathers each fiber through
 * the source's own transfer slots, or when it writes scratch back
 * through them.  Every other shape hands out pointers into memory that
 * init already materialised, and moves it with memcpy. */

/* Private flags bit, kept in ca_iter_state.flags rather than a field of
   its own: the state is stack-allocated by ext authors through the block
   macros, so growing it would overrun states built against an older
   header. */
#define CA_ITER_FLAG_WALK_MAY_RAISE 0x80000000u


typedef struct {
  ca_iter_state    *st;
  CArray           *src;
  ca_slab_policy_t  policy;
  int8_t           *axes;
  int8_t            naxes;
  uint32_t          flags;
  char            **out_ptr;
  boolean8_t      **out_mask;
  ca_size_t        *out_n;
  int               rc;
} ca_iter_call_t;

/* Whether next_slab / sync_slab on this walk need the protection.

   Shortcut PROTECT_ONLY_MAY_RAISE.
     Layer       the exits (promise 4): which walks run next_slab /
                 sync_slab under rb_protect.
     Speeds up   walks that cannot raise there: they skip rb_protect.
     Why         about 1.5x on a per-axis sum over 200k short fibers.
     Enters      the route is not PER_FIBER_FUSED and the walk does not
                 write back out of scratch.
     Promises    4 (a walk left out cannot raise between init and finish).
     Switch      ca_fast_paths_enabled(): off, every walk is protected.
     Checked by  test_iter_raise_cleanup.rb; the raise rows of
                 test_iter_delivery_detectors.rb. */
static void
ca_iter_mark_walk_may_raise (ca_iter_state *st)
{
  if ( st == NULL ) return;
  if ( ! ca_fast_paths_enabled() ) {
    /* the general path protects every walk */
    st->flags |= CA_ITER_FLAG_WALK_MAY_RAISE;
    return;
  }
  if ( st->alias_mode == CA_ITER_ALIAS_PER_FIBER_FUSED ) {
    /* gathers each fiber through the source's xfer_stride slot */
    st->flags |= CA_ITER_FLAG_WALK_MAY_RAISE;
  }
  else if ( (st->flags & CA_KERNEL_WRITE)
            && (st->scratch_ptr != NULL
                || st->src_kind == CA_ITER_SRC_ATTACH) ) {
    /* writes back out of iterator-owned scratch, through the source's
       transfer (ki_scratch_push_changed: ca_xfer_addrs / ca_xfer_all PUT)
       or the descriptor scatter.  A write into aliased memory needs no
       push-back at all: sync_slab returns at once. */
    st->flags |= CA_ITER_FLAG_WALK_MAY_RAISE;
  }
}

/* When body raises, finish st -- and the state it is paired with (see
   ca_iter_state_init_l2_paired), which is open in the same frame and
   would otherwise be jumped over. */
static VALUE ca_iter_ensure_finish_one (VALUE arg);

static void
ca_iter_protect (ca_iter_state *st, VALUE (*body)(VALUE), VALUE arg)
{
  int tag = 0;
  rb_protect(body, arg, &tag);
  if ( tag ) {
    ca_iter_state *pair = (ca_iter_state *) st->pair;
    volatile VALUE error = rb_errinfo();
    int ignored = 0;
    /* protect: finishes the pair even when finishing st raises; the
       body's exception is the one passed on */
    rb_protect(ca_iter_ensure_finish_one, (VALUE) st, &ignored);
    if ( pair != NULL ) {
      /* protect: as above */
      rb_protect(ca_iter_ensure_finish_one, (VALUE) pair, &ignored);
    }
    rb_set_errinfo(error);
    rb_jump_tag(tag);
  }
}

static VALUE
ca_iter_call_init_l1 (VALUE arg)
{
  ca_iter_call_t *c = (ca_iter_call_t *) arg;
  c->rc = ca_iter_state_init_l1_unprotected(c->st, c->src, c->policy,
                                            c->axes, c->naxes, c->flags);
  return Qnil;
}

static VALUE
ca_iter_call_init_l2 (VALUE arg)
{
  ca_iter_call_t *c = (ca_iter_call_t *) arg;
  c->rc = ca_iter_state_init_l2_unprotected(c->st, c->src, c->policy,
                                            c->axes, c->naxes, c->flags);
  return Qnil;
}

static VALUE
ca_iter_call_next_slab (VALUE arg)
{
  ca_iter_call_t *c = (ca_iter_call_t *) arg;
  c->rc = ca_iter_state_next_slab_unprotected(c->st, c->out_ptr,
                                              c->out_mask, c->out_n);
  return Qnil;
}


static VALUE
ca_iter_call_next_slab_axes (VALUE arg)
{
  ca_iter_call_t *c = (ca_iter_call_t *) arg;
  c->rc = ca_iter_state_next_slab_axes_unprotected(c->st, c->out_ptr,
                                                   c->out_mask);
  return Qnil;
}

static VALUE
ca_iter_call_sync_slab (VALUE arg)
{
  ca_iter_call_t *c = (ca_iter_call_t *) arg;
  ca_iter_state_sync_slab_unprotected(c->st);
  return Qnil;
}

int
ca_iter_state_init_l1 (ca_iter_state    *st,
                       struct _CArray   *src,
                       ca_slab_policy_t  policy,
                       int8_t           *axes,
                       int8_t            naxes,
                       uint32_t          flags)
{
  ca_iter_call_t c;
  c.st = st; c.src = src; c.policy = policy;
  c.axes = axes; c.naxes = naxes; c.flags = flags; c.rc = CA_ITER_OK;
  if ( st != NULL ) {
    st->pair = NULL;       /* read by ca_iter_protect if the init raises */
  }
  ca_iter_protect(st, ca_iter_call_init_l1, (VALUE) &c);
  if ( c.rc == CA_ITER_OK ) ca_iter_mark_walk_may_raise(st);
  return c.rc;
}

int
ca_iter_state_init_l2 (ca_iter_state    *st,
                       struct _CArray   *src,
                       ca_slab_policy_t  policy,
                       int8_t           *axes,
                       int8_t            naxes,
                       uint32_t          flags)
{
  ca_iter_call_t c;
  c.st = st; c.src = src; c.policy = policy;
  c.axes = axes; c.naxes = naxes; c.flags = flags; c.rc = CA_ITER_OK;
  if ( st != NULL ) {
    st->pair = NULL;       /* read by ca_iter_protect if the init raises */
  }
  ca_iter_protect(st, ca_iter_call_init_l2, (VALUE) &c);
  if ( c.rc == CA_ITER_OK ) ca_iter_mark_walk_may_raise(st);
  return c.rc;
}

/* A slab handed out by a write walk is dirty until sync_slab writes it
   back; finish writes back one the caller left with `break`. */
static int
ca_iter_mark_dirty (ca_iter_state *st, int rc)
{
  if ( rc && st != NULL && (st->flags & CA_KERNEL_WRITE) ) {
    st->write_dirty = 1;
  }
  return rc;
}

static VALUE
ca_iter_finish_sync (VALUE arg)
{
  ca_iter_state_sync_slab_unprotected((ca_iter_state *) arg);
  return Qnil;
}

int
ca_iter_state_next_slab (ca_iter_state *st,
                         char         **out_ptr,
                         boolean8_t   **out_mask,
                         ca_size_t     *out_n)
{
  ca_iter_call_t c;
  if ( st == NULL || !(st->flags & CA_ITER_FLAG_WALK_MAY_RAISE) ) {
    return ca_iter_mark_dirty(st,
             ca_iter_state_next_slab_unprotected(st, out_ptr, out_mask, out_n));
  }
  c.st = st; c.out_ptr = out_ptr; c.out_mask = out_mask; c.out_n = out_n;
  c.rc = 0;
  ca_iter_protect(st, ca_iter_call_next_slab, (VALUE) &c);
  return ca_iter_mark_dirty(st, c.rc);
}


int
ca_iter_state_next_slab_axes (ca_iter_state *st,
                              char         **out_ptr,
                              boolean8_t   **out_mask)
{
  ca_iter_call_t c;
  if ( st == NULL || !(st->flags & CA_ITER_FLAG_WALK_MAY_RAISE) ) {
    return ca_iter_mark_dirty(st,
             ca_iter_state_next_slab_axes_unprotected(st, out_ptr, out_mask));
  }
  c.st = st; c.out_ptr = out_ptr; c.out_mask = out_mask; c.rc = 0;
  ca_iter_protect(st, ca_iter_call_next_slab_axes, (VALUE) &c);
  return ca_iter_mark_dirty(st, c.rc);
}

void
ca_iter_state_sync_slab (ca_iter_state *st)
{
  ca_iter_call_t c;
  if ( st == NULL || !(st->flags & CA_ITER_FLAG_WALK_MAY_RAISE) ) {
    ca_iter_state_sync_slab_unprotected(st);
    return;
  }
  c.st = st;
  ca_iter_protect(st, ca_iter_call_sync_slab, (VALUE) &c);
}

typedef struct {
  ca_iter_state *st;
  CArray        *src;
  CArray        *copy;
} ca_iter_reopen_t;

static VALUE
ca_iter_reopen_copy (VALUE arg)
{
  ca_iter_reopen_t *r = (ca_iter_reopen_t *) arg;
  r->copy = ca_copy(r->src);
  return Qnil;
}

/* A read walk whose source lives in the root a paired write walk writes
   into would read cells the kernel has already written: an aliased fiber
   is the written memory itself, and a gathered one is read from the root
   after earlier fibers were written back.  Such a read walk is reopened
   on a copy of its source, taken before anything is written and owned by
   the walk.  Returns the init's rc; a raise finishes `first` first. */
static int
ca_iter_reopen_on_copy (ca_iter_state *first)
{
  ca_iter_reopen_t r;
  ca_iter_call_t c;
  int8_t axes[CA_RANK_MAX];
  int8_t naxes = first->naxes;
  uint32_t flags = first->flags & ~(CA_ITER_FLAG_WALK_MAY_RAISE
                                    | CA_ITER_FLAG_OWNS_SRC);
  ca_slab_policy_t policy = first->policy;
  int tag = 0;

  memcpy(axes, first->slab_axes_buf, (size_t) naxes);
  r.st = first; r.src = first->src; r.copy = NULL;
  rb_protect(ca_iter_reopen_copy, (VALUE) &r, &tag);
  if ( tag ) {
    ca_iter_state_finish(first);
    rb_jump_tag(tag);
  }
  if ( ca_is_object_type(r.copy) ) {
    /* the walk overwrites the cells that held these VALUEs */
    ca_gc_hold_buffer(r.copy->ptr, r.copy->elements);
  }
  ca_iter_state_finish(first);

  c.st = first; c.src = r.copy; c.policy = policy;
  c.axes = axes; c.naxes = naxes; c.flags = flags; c.rc = CA_ITER_OK;
  rb_protect(ca_iter_call_init_l2, (VALUE) &c, &tag);
  if ( tag || c.rc != CA_ITER_OK ) {
    ca_iter_state_finish(first);
    if ( ca_is_object_type(r.copy) ) {
      ca_gc_release_buffer(r.copy->ptr);
    }
    ca_free(r.copy);
    if ( tag ) {
      rb_jump_tag(tag);
    }
    return c.rc;
  }
  first->flags |= CA_ITER_FLAG_OWNS_SRC;
  ca_iter_mark_walk_may_raise(first);
  return CA_ITER_OK;
}

int
ca_iter_state_init_l2_paired (ca_iter_state    *st,
                              ca_iter_state    *first,
                              struct _CArray   *src,
                              ca_slab_policy_t  policy,
                              int8_t           *axes,
                              int8_t            naxes,
                              uint32_t          flags)
{
  ca_iter_call_t c;
  int tag = 0;
  if ( (flags & CA_KERNEL_WRITE) && first->src != NULL &&
       ! (first->flags & CA_KERNEL_WRITE) &&
       policy == CA_SLAB_AXES && first->policy == CA_SLAB_AXES &&
       ca_shares_root(first->src, src) ) {
    int rc = ca_iter_reopen_on_copy(first);
    if ( rc != CA_ITER_OK ) {
      return rc;
    }
  }
  c.st = st; c.src = src; c.policy = policy;
  c.axes = axes; c.naxes = naxes; c.flags = flags; c.rc = CA_ITER_OK;
  rb_protect(ca_iter_call_init_l2, (VALUE) &c, &tag);
  if ( tag ) {
    ca_iter_state_finish(st);
    ca_iter_state_finish(first);
    rb_jump_tag(tag);
  }
  if ( c.rc != CA_ITER_OK ) {
    ca_iter_state_finish(first);
    return c.rc;
  }
  ca_iter_mark_walk_may_raise(st);
  st->pair    = first;
  first->pair = st;
  return c.rc;
}

typedef struct {
  int32_t        n;
  ca_iter_state *states;
} ca_iter_ensure_t;

static VALUE
ca_iter_ensure_finish_one (VALUE arg)
{
  ca_iter_state_finish((ca_iter_state *) arg);
  return Qnil;
}

/* Finishes the walks in reverse order of their slots, as nested windows
   close.  A finish can raise: on a WRITE walk whose root is a view, it
   syncs the root (ca_sync_detach) through the view's slots.  Each finish
   is therefore run under rb_protect, so a raise from one does not leave
   the states before it unfinished; the first raise is re-raised once
   every state is closed. */
static VALUE
ca_iter_ensure_close (VALUE arg)
{
  ca_iter_ensure_t *e = (ca_iter_ensure_t *) arg;
  int first = 0;
  volatile VALUE first_err = Qnil;
  for ( int32_t i = e->n - 1; i >= 0; i-- ) {
    int status = 0;
    rb_protect(ca_iter_ensure_finish_one, (VALUE) &e->states[i], &status);
    if ( status ) {
      if ( ! first ) {
        first     = status;
        first_err = rb_errinfo();
      }
      rb_set_errinfo(Qnil);
    }
  }
  if ( first ) {
    rb_set_errinfo(first_err);
    rb_jump_tag(first);
  }
  return Qnil;
}

VALUE
ca_iter_ensure (int32_t n, ca_iter_state *states,
                VALUE (*body)(VALUE), VALUE arg)
{
  ca_iter_ensure_t e;
  if ( n < 0 ) {
    rb_raise(rb_eArgError, "ca_iter_ensure: negative state count %d", (int) n);
  }
  /* Unopened: finish returns at once on a state whose src is NULL, and
     init clears the whole state before it takes anything. */
  for ( int32_t i = 0; i < n; i++ ) {
    states[i].src = NULL;
  }
  e.n      = n;
  e.states = states;
  return rb_ensure(body, arg, ca_iter_ensure_close, (VALUE) &e);
}

#ifdef CARRAY_DEV_BUILD
/* ============================================================
 * smoke surface (dev-only, stripped in release)
 *
 * Gated by CARRAY_DEV_BUILD (enabled via `extconf.rb --enable-dev-build`
 * or `CARRAY_DEV=1 rake build_ext`).  These helpers expose internal
 * engine state to Ruby for spec_ai regression pins.  Do not consume
 * from user code.
 * ============================================================ */

/* The innermost-axis walk the L2 smokes run: one strided run per
   innermost row, handed out as (pointer, cell count, byte stride). */
static int
t1_smoke_open_rows (ca_iter_state *st, CArray *src, uint32_t flags)
{
  int8_t ax = (int8_t) (src->ndim - 1);
  return ca_iter_state_init_l2(st, src, CA_SLAB_AXES, &ax, 1, flags);
}

static int
t1_smoke_next_row (ca_iter_state *st, char **p, ca_size_t *n,
                   ca_size_t *stride)
{
  if ( ! ca_iter_state_next_slab_axes(st, p, NULL) ) return 0;
  *n      = st->slab_dims[0];
  *stride = st->slab_strides[0];
  return 1;
}

/* ---- Ruby smoke surface --------------------------------------------- */

/* L1 smoke (steps 1+2): CArray.t1_smoke(ca) -> Hash with
   rc / slabs / total_elems / ptr_nonnull / alias_mode / data. */
static VALUE
rb_t1_smoke (VALUE klass, VALUE vsrc)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n;
  int             rc;
  int             slabs       = 0;
  ca_size_t       total_elems = 0;
  int             ptr_nonnull = 0;
  int             alias_mode  = CA_ITER_ALIAS_NONE;
  VALUE           result;
  VALUE           data;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  data = rb_str_new(0, 0);

  rc = ca_iter_state_init_l1(&st, src, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc == CA_ITER_OK ) {
    while ( ca_iter_state_next_slab(&st, &p, NULL, &n) ) {
      if ( slabs == 0 && p != NULL ) ptr_nonnull = 1;
      if ( p != NULL && n > 0 ) rb_str_cat(data, p, n * st.bytes);
      total_elems += n;
      slabs++;
    }
    alias_mode = st.alias_mode;
    ca_iter_state_finish(&st);
  }

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("rc")),          INT2NUM(rc));
  rb_hash_aset(result, ID2SYM(rb_intern("slabs")),       INT2NUM(slabs));
  rb_hash_aset(result, ID2SYM(rb_intern("total_elems")), SIZE2NUM(total_elems));
  rb_hash_aset(result, ID2SYM(rb_intern("ptr_nonnull")), ptr_nonnull ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("alias_mode")),  INT2NUM(alias_mode));
  rb_hash_aset(result, ID2SYM(rb_intern("data")),        data);
  return result;
}

/* L2 smoke: CArray.t1_smoke_strided(ca) -> Hash with
     rc            => Integer
     slabs         => Integer (= total_slabs)
     total_elems   => Integer
     alias_mode    => Integer
     data          => String — slab bytes reconstructed via the
                     reported (ptr, n, stride_bytes) tuples, in
                     iteration order; should equal view.to_ca.dump_binary
     strides       => Array<Integer> — stride_bytes per yielded slab
   On error rc != OK, the walk fields are 0 / empty. */
static VALUE
rb_t1_smoke_strided (VALUE klass, VALUE vsrc)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, stride_bytes;
  int             rc;
  int             slabs       = 0;
  ca_size_t       total_elems = 0;
  int             alias_mode  = CA_ITER_ALIAS_NONE;
  VALUE           result, data, strides_arr;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  data        = rb_str_new(0, 0);
  strides_arr = rb_ary_new();

  rc = t1_smoke_open_rows(&st, src, 0);
  if ( rc == CA_ITER_OK ) {
    while ( t1_smoke_next_row(&st, &p, &n, &stride_bytes) ) {
      if ( p != NULL && n > 0 ) {
        ca_size_t i;
        for ( i = 0; i < n; i++ ) {
          rb_str_cat(data, p + i * stride_bytes, st.bytes);
        }
      }
      total_elems += n;
      slabs++;
      rb_ary_push(strides_arr, SIZE2NUM(stride_bytes));
    }
    alias_mode = st.alias_mode;
    ca_iter_state_finish(&st);
  }

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("rc")),          INT2NUM(rc));
  rb_hash_aset(result, ID2SYM(rb_intern("slabs")),       INT2NUM(slabs));
  rb_hash_aset(result, ID2SYM(rb_intern("total_elems")), SIZE2NUM(total_elems));
  rb_hash_aset(result, ID2SYM(rb_intern("alias_mode")),  INT2NUM(alias_mode));
  rb_hash_aset(result, ID2SYM(rb_intern("data")),        data);
  rb_hash_aset(result, ID2SYM(rb_intern("strides")),     strides_arr);
  return result;
}

/* Bench-grade L2 sum kernel: total reduction via L2 iteration with no
   Ruby String materialisation in the hot loop.  Use this rather than
   t1_smoke_strided when measuring the actual L2 dispatch overhead
   (the smoke variant's rb_str_cat dominates timing for moderate
   slab counts).  Only supports float64 sources for now — the smoke
   API isn't a public surface and this is bench scaffolding. */
static VALUE
rb_t1_smoke_sum_strided_f64 (VALUE klass, VALUE vsrc)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, stride_bytes, i;
  int             rc;
  double          acc = 0.0;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eTypeError,
             "t1_smoke_sum_strided_f64 expects a float64 source");
  }

  rc = t1_smoke_open_rows(&st, src, 0);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "ca_iter_state_init L2 failed (rc=%d)", rc);
  }

  while ( t1_smoke_next_row(&st, &p, &n, &stride_bytes) ) {
    /* CA_L2_FOR_EACH takes a contiguous loop when stride ==
       sizeof(double), which the compiler can vectorise, and a strided
       loop otherwise. */
    CA_L2_FOR_EACH(double, p, n, stride_bytes, dp, {
      acc += *dp;
    });
  }
  (void) i;
  ca_iter_state_finish(&st);
  return DBL2NUM(acc);
}

/* WRITE smoke: in-place fill via L1.  Fills every element with `val`
   using next_slab (alias direct write if cheap, scratch+sync if not).
   Returns iter rc; on rc != OK src is not modified. */
static VALUE
rb_t1_smoke_write_fill_f64 (VALUE klass, VALUE vsrc, VALUE vval)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, i;
  double          v = NUM2DBL(vval);
  int             rc;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eTypeError, "expects a float64 source");
  }

  rc = ca_iter_state_init_l1(&st, src, CA_SLAB_WHOLE, NULL, 0,
                             CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) return INT2NUM(rc);

  while ( ca_iter_state_next_slab(&st, &p, NULL, &n) ) {
    double *d = (double *) p;
    for ( i = 0; i < n; i++ ) d[i] = v;
    ca_iter_state_sync_slab(&st);
  }
  ca_iter_state_finish(&st);
  return INT2NUM(CA_ITER_OK);
}

/* WRITE smoke: in-place fill via an L2 walk (the L1 form is
   t1_smoke_write_fill_f64).  Kernel walks the strided
   slab and writes val at every position; sync_slab scatters back. */
static VALUE
rb_t1_smoke_write_fill_strided_f64 (VALUE klass, VALUE vsrc, VALUE vval)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, stride, i;
  double          v = NUM2DBL(vval);
  int             rc;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eTypeError, "expects a float64 source");
  }

  rc = t1_smoke_open_rows(&st, src, CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) return INT2NUM(rc);

  while ( t1_smoke_next_row(&st, &p, &n, &stride) ) {
    /* Contiguous loop when stride == sizeof(double) (a gathered
       scratch), strided otherwise. */
    CA_L2_FOR_EACH(double, p, n, stride, dp, {
      *dp = v;
    });
    ca_iter_state_sync_slab(&st);
  }
  (void) i;
  ca_iter_state_finish(&st);
  return INT2NUM(CA_ITER_OK);
}

/* WRITE smoke: partial write then ruby raise — used by exception
   safety tests.  Writes the first `raise_at` elements, then raises.
   Parent is left in a partially-written state (alias path) or
   unchanged (scratch path, pre-sync). */
static VALUE
rb_t1_smoke_write_partial_raise_f64 (VALUE klass, VALUE vsrc,
                                     VALUE vval, VALUE vraise_at)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, i;
  double          v        = NUM2DBL(vval);
  ca_size_t       raise_at = NUM2SIZET(vraise_at);
  int             rc;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eTypeError, "expects a float64 source");
  }

  rc = ca_iter_state_init_l1(&st, src, CA_SLAB_WHOLE, NULL, 0,
                             CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "init_l1 failed (rc=%d)", rc);
  }

  while ( ca_iter_state_next_slab(&st, &p, NULL, &n) ) {
    double *d = (double *) p;
    for ( i = 0; i < n; i++ ) {
      if ( i == raise_at ) {
        /* Raise without finishing the walk.  alias path: writes 0..raise_at-1
           are now visible to parent.  scratch path: scratch has the partial
           writes but sync_slab was not called, so parent is unchanged. */
        ca_iter_state_finish(&st);   /* release lifecycle */
        rb_raise(rb_eRuntimeError, "kernel raise at %ld", (long) raise_at);
      }
      d[i] = v;
    }
    ca_iter_state_sync_slab(&st);
  }
  ca_iter_state_finish(&st);
  return INT2NUM(CA_ITER_OK);
}

/* qsort comparator for double */
static int
cmp_double (const void *a, const void *b)
{
  double da = *(const double *)a, db = *(const double *)b;
  if ( da < db ) return -1;
  if ( da > db ) return 1;
  return 0;
}

/* WRITE smoke: per-row sort via L2 strided dispatch.  For a 2D
   float64 src of shape [m, n], sort each of the m rows in ascending
   order.  Walks the innermost axis so each row is a strided slab; the
   kernel materialises into a tight contig scratch, qsorts, then
   writes back via the same stride.  This exercises L2 WRITE
   mechanics (multi-slab walk, per-slab fill of strided cells)
   without a strided qsort of its own. */
static VALUE
rb_t1_smoke_sort_row_f64 (VALUE klass, VALUE vsrc)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, stride_bytes;
  int             rc;
  double          scratch[CA_DIM_MAX > 0 ? 4096 : 4096];  /* row-cap, see below */

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eTypeError, "expects a float64 source");
  }

  rc = t1_smoke_open_rows(&st, src, CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) return INT2NUM(rc);

  while ( t1_smoke_next_row(&st, &p, &n, &stride_bytes) ) {
    if ( n > (ca_size_t) (sizeof(scratch) / sizeof(double)) ) {
      ca_iter_state_finish(&st);
      rb_raise(rb_eRuntimeError, "row too large for smoke scratch");
    }
    /* strided -> contig scratch (CA_L2_FOR_EACH takes the contiguous
       loop when stride == bytes). */
    ca_size_t _sc_i = 0;
    CA_L2_FOR_EACH(double, p, n, stride_bytes, dp, {
      scratch[_sc_i++] = *dp;
    });
    /* in-place qsort on the contig scratch */
    qsort(scratch, n, sizeof(double), cmp_double);
    /* contig scratch -> strided (writes back to parent via alias_ptr,
       a direct write). */
    ca_size_t _wb_i = 0;
    CA_L2_FOR_EACH(double, p, n, stride_bytes, dp, {
      *dp = scratch[_wb_i++];
    });
    ca_iter_state_sync_slab(&st);   /* no-op for L2 alias, by invariant */
  }
  ca_iter_state_finish(&st);
  return INT2NUM(CA_ITER_OK);
}

/* Mask smoke: L1 walk that exposes BOTH the value slab and the
   mask slab.  Used to pin "mask is delivered to kernel" semantics.
   Returns rc + mask_seen (Boolean: was out_mask non-NULL at first
   yield) + mask_bytes (String: concatenated mask bytes). */
static VALUE
rb_t1_smoke_with_mask (VALUE klass, VALUE vsrc)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  boolean8_t     *m;
  ca_size_t       n;
  int             rc;
  int             mask_seen = 0;
  VALUE           mask_bytes, result;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  mask_bytes = rb_str_new(0, 0);

  rc = ca_iter_state_init_l1(&st, src, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc != CA_ITER_OK ) {
    result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("rc")),         INT2NUM(rc));
    rb_hash_aset(result, ID2SYM(rb_intern("mask_seen")),  Qfalse);
    rb_hash_aset(result, ID2SYM(rb_intern("mask_bytes")), mask_bytes);
    return result;
  }

  while ( ca_iter_state_next_slab(&st, &p, &m, &n) ) {
    if ( m != NULL ) {
      mask_seen = 1;
      if ( n > 0 ) rb_str_cat(mask_bytes, (char *) m, n);
    }
  }
  ca_iter_state_finish(&st);

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("rc")),         INT2NUM(rc));
  rb_hash_aset(result, ID2SYM(rb_intern("mask_seen")),  mask_seen ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("mask_bytes")), mask_bytes);
  return result;
}

/* Bench-grade smoke for the L1 walk (CAStride + descriptor sources).
   Runs the full init / next_slab / finish cycle with no Ruby String
   materialisation in the hot loop — the kernel "consumes" the slab
   by xoring its first byte into a volatile sink (defeats dead-code
   elimination, costs nothing measurable on top of the materialise
   already done inside init).  Returns total elements walked as an
   Integer.  Use this when comparing against view.to_ca; the regular
   t1_smoke includes an rb_str_cat that doubles the materialise
   memcpy cost. */
static VALUE
rb_t1_smoke_attach (VALUE klass, VALUE vsrc)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n;
  int             rc;
  ca_size_t       total = 0;
  volatile char   sink  = 0;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  rc = ca_iter_state_init_l1(&st, src, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc != CA_ITER_OK ) return INT2NUM(rc);

  while ( ca_iter_state_next_slab(&st, &p, NULL, &n) ) {
    if ( p != NULL && n > 0 ) sink ^= p[0];
    total += n;
  }
  (void) sink;
  ca_iter_state_finish(&st);
  return SIZE2NUM(total);
}

/* L2 bench-grade smoke.  Same shape as t1_smoke_attach
   but walks the innermost axis through init_l2 so descriptor sources
   can be exercised through the L2 path. */
static VALUE
rb_t1_smoke_attach_strided (VALUE klass, VALUE vsrc)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, stride;
  int             rc;
  ca_size_t       total = 0;
  volatile char   sink  = 0;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  rc = t1_smoke_open_rows(&st, src, 0);
  if ( rc != CA_ITER_OK ) return INT2NUM(rc);

  while ( t1_smoke_next_row(&st, &p, &n, &stride) ) {
    if ( p != NULL && n > 0 ) sink ^= p[0];
    total += n;
  }
  (void) sink;
  ca_iter_state_finish(&st);
  return SIZE2NUM(total);
}

/* Flags smoke: minimal smoke that exposes the `flags` argument to Ruby
   tests.  Just runs init_l1 with the requested flags and returns
   the rc — used to verify NO_MASK enforcement (and any future
   flag-gated rejection paths) without needing a full kernel walk. */
static VALUE
rb_t1_smoke_init_rc (VALUE klass, VALUE vsrc, VALUE vflags)
{
  CArray         *src;
  ca_iter_state   st;
  int             rc;
  /* fits: a development smoke argument, not a cell */
  uint32_t        flags = (uint32_t) NUM2UINT(vflags);

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  rc = ca_iter_state_init_l1(&st, src, CA_SLAB_WHOLE, NULL, 0, flags);
  if ( rc == CA_ITER_OK ) ca_iter_state_finish(&st);
  return INT2NUM(rc);
}

/* ---- CA_SLAB_AXES smoke ----------------------------------------------
   sum a float64 source over user-specified slab axes via init_l2 +
   next_slab_axes.  K-D walk over slab dims using slab_strides for data
   and slab_mask_strides for mask (so non-contig CAStride sources work
   too).  Returns total sum as a Float.  Variadic int axes arg
   (= matches CArray#sum surface):
     CArray.t1_smoke_sum_axes_f64(ca, 0)
     CArray.t1_smoke_sum_axes_f64(ca, 0, 2)
*/
static VALUE
rb_t1_smoke_sum_axes_f64 (int argc, VALUE *argv, VALUE klass)
{
  CArray         *src;
  ca_iter_state   st;
  char           *p;
  boolean8_t     *m;
  int             rc;
  int8_t          slab_axes[CA_RANK_MAX];
  int8_t          naxes;
  double          acc = 0.0;
  int             i;

  if ( argc < 2 ) {
    rb_raise(rb_eArgError, "t1_smoke_sum_axes_f64 expects (ca, axis...)");
  }
  TypedData_Get_Struct(argv[0], CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eTypeError, "t1_smoke_sum_axes_f64 expects a float64 source");
  }
  naxes = (int8_t) (argc - 1);
  if ( naxes > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "too many axes");
  }
  for ( i = 0; i < naxes; i++ ) {
    /* fits: an axis number, checked by the engine's init */
    slab_axes[i] = (int8_t) NUM2INT(argv[i + 1]);
  }

  rc = ca_iter_state_init_l2(&st, src, CA_SLAB_AXES, slab_axes, naxes, 0);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "init_l2 CA_SLAB_AXES failed rc=%d", rc);
  }

  while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
    /* K-D walk over slab via outer_idx-style iteration over slab_dims.
       For simplicity / correctness, use a flat counter that decomposes
       into per-axis indices (= general-purpose walk, no SIMD pattern). */
    ca_size_t cell_count = st.slab_elements;
    ca_size_t idx[CA_RANK_MAX] = { 0 };
    for ( ca_size_t c = 0; c < cell_count; c++ ) {
      ca_size_t data_off = 0;
      ca_size_t mask_off = 0;
      for ( int8_t k = 0; k < st.slab_ndim; k++ ) {
        data_off += idx[k] * st.slab_strides[k];
        mask_off += idx[k] * st.slab_mask_strides[k];
      }
      if ( m == NULL || !m[mask_off] ) {
        acc += *(double *)(p + data_off);
      }
      /* advance idx row-major (innermost first) */
      for ( int8_t k = st.slab_ndim - 1; k >= 0; k-- ) {
        if ( ++idx[k] < st.slab_dims[k] ) break;
        idx[k] = 0;
      }
    }
  }
  ca_iter_state_finish(&st);
  return DBL2NUM(acc);
}

/* ---- helper smoke: rb_ca_parse_reduce_axes ---------------------------
   Calls the helper and returns the parsed axes as a Ruby Array of
   Integer.  Lets tests inspect parsing behaviour directly.
   Signature: CArray.t1_test_parse_reduce_axes(ca, *args) */
static VALUE
rb_t1_test_parse_reduce_axes (int argc, VALUE *argv, VALUE klass)
{
  CArray *ca;
  int8_t  axes[CA_RANK_MAX];
  int8_t  naxes;
  int     i;

  if ( argc < 1 ) {
    rb_raise(rb_eArgError,
             "t1_test_parse_reduce_axes expects (ca, *axis_args)");
  }
  TypedData_Get_Struct(argv[0], CArray, &carray_data_type, ca);
  naxes = rb_ca_parse_reduce_axes(argc - 1, argv + 1, ca, axes);

  VALUE arr = rb_ary_new_capa(naxes);
  for ( i = 0; i < naxes; i++ ) {
    rb_ary_push(arr, INT2NUM((int) axes[i]));
  }
  return arr;
}

/* ---- helper smoke: rb_ca_parse_reduce_axes_kw ------------------------
   Calls the kwarg helper and returns the parsed axes as a Ruby Array.
   Lets tests inspect kwarg-form parsing (Qnil / Integer / Array) +
   validation parity with the variadic entry.
   Signature: CArray.test_parse_reduce_axes_kw(ca, axis: ...) */
static VALUE
rb_test_parse_reduce_axes_kw (int argc, VALUE *argv, VALUE klass)
{
  CArray *ca;
  int8_t  axes[CA_RANK_MAX];
  int8_t  naxes;
  int     i;
  VALUE   ca_obj, kw_hash, axis_val = Qnil;

  rb_scan_args(argc, argv, "1:", &ca_obj, &kw_hash);
  TypedData_Get_Struct(ca_obj, CArray, &carray_data_type, ca);

  rb_scan_options(kw_hash, "axis", &axis_val);

  naxes = rb_ca_parse_reduce_axes_kw(axis_val, ca, axes);

  VALUE arr = rb_ary_new_capa(naxes);
  for ( i = 0; i < naxes; i++ ) {
    rb_ary_push(arr, INT2NUM((int) axes[i]));
  }
  return arr;
}

/* ---- helper smoke: rb_ca_new_reduced ---------------------------------
   Exposes rb_ca_new_reduced (carray_core.c) for unit testing.  Returns
   the newly allocated output CArray (= tests verify shape + data_type).
   Signature: CArray.t1_test_new_reduced(ca, data_type, axis1, axis2, ...) */
static VALUE
rb_t1_test_new_reduced (int argc, VALUE *argv, VALUE klass)
{
  int8_t  axes[CA_RANK_MAX];
  int8_t  naxes;
  int32_t data_type;

  if ( argc < 3 ) {
    rb_raise(rb_eArgError,
             "t1_test_new_reduced expects (ca, data_type, axis...) with >= 1 axis");
  }
  /* Accept Symbol / Integer / Class / String alike through
     rb_ca_guess_type. */
  data_type = (int32_t) rb_ca_guess_type(argv[1]);
  naxes = (int8_t) (argc - 2);
  if ( naxes > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "too many axes");
  }
  for ( int i = 0; i < naxes; i++ ) {
    /* fits: an axis number, checked by the engine's init */
    axes[i] = (int8_t) NUM2INT(argv[2 + i]);
  }
  return rb_ca_new_reduced(argv[0], axes, naxes, data_type, 0);
}

/* ---- CAReduce smoke --------------------------------------------------
   CAReduce has no public Ruby ctor (it's an internal class used by
   CARefer mask handling).  Tests need to drive kernel_iterator over
   a CAReduce, so we expose a thin construction helper plus dedicated
   read / write smokes.  All three accept a boolean parent — CAReduce
   is fixed to CA_BOOLEAN (ca_obj_reduce.c:71). */

static VALUE
rb_t1_make_reduce (VALUE klass, VALUE vparent, VALUE vcount, VALUE voffset)
{
  CArray *parent;
  TypedData_Get_Struct(vparent, CArray, &carray_data_type, parent);
  ca_size_t count  = NUM2SIZE(vcount);
  ca_size_t offset = NUM2SIZE(voffset);
  CArray *r = (CArray *) ca_reduce_new(parent, count, offset);
  return ca_wrap_struct(r);
}

/* READ smoke for CAReduce: returns Hash mirroring t1_smoke (rc / slabs /
   total_elems / alias_mode / data) so binary parity is checkable. */
static VALUE
rb_t1_smoke_reduce_read (VALUE klass, VALUE vparent, VALUE vcount, VALUE voffset)
{
  CArray         *parent;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n;
  int             rc;
  int             slabs       = 0;
  ca_size_t       total_elems = 0;
  int             alias_mode  = CA_ITER_ALIAS_NONE;
  VALUE           result, data;
  CArray         *reduce;

  TypedData_Get_Struct(vparent, CArray, &carray_data_type, parent);
  ca_size_t count  = NUM2SIZE(vcount);
  ca_size_t offset = NUM2SIZE(voffset);
  reduce = (CArray *) ca_reduce_new(parent, count, offset);
  data   = rb_str_new(0, 0);

  rc = ca_iter_state_init_l1(&st, reduce, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc == CA_ITER_OK ) {
    while ( ca_iter_state_next_slab(&st, &p, NULL, &n) ) {
      if ( p != NULL && n > 0 ) rb_str_cat(data, p, n * st.bytes);
      total_elems += n;
      slabs++;
    }
    alias_mode = st.alias_mode;
    ca_iter_state_finish(&st);
  }
  /* reduce was allocated via ALLOC (ca_reduce_new) but not wrapped in
     a Ruby VALUE, so it would leak.  ca_free dispatches to the view's
     free_object which already xfrees the struct (ca_obj_reduce.c:113). */
  ca_free(reduce);

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("rc")),          INT2NUM(rc));
  rb_hash_aset(result, ID2SYM(rb_intern("slabs")),       INT2NUM(slabs));
  rb_hash_aset(result, ID2SYM(rb_intern("total_elems")), SIZE2NUM(total_elems));
  rb_hash_aset(result, ID2SYM(rb_intern("alias_mode")),  INT2NUM(alias_mode));
  rb_hash_aset(result, ID2SYM(rb_intern("data")),        data);
  return result;
}

/* WRITE broadcast smoke for CAReduce: fills the reduce view with
   `val` (boolean / 0 or 1) and lets sync_slab send the changed cells
   back through the view (ki_scratch_push_changed), which broadcasts them
   to the parent.  After the call parent's
   [offset..offset+elems*count) bytes should all equal val.  Returns
   rc; on rc != OK parent is not modified. */
static VALUE
rb_t1_smoke_reduce_write_broadcast (VALUE klass, VALUE vparent,
                                    VALUE vcount, VALUE voffset, VALUE vval)
{
  CArray         *parent;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, i;
  int             rc;
  CArray         *reduce;
  /* fits: a development smoke argument, not a cell */
  uint8_t         v = (uint8_t) NUM2UINT(vval);

  TypedData_Get_Struct(vparent, CArray, &carray_data_type, parent);
  ca_size_t count  = NUM2SIZE(vcount);
  ca_size_t offset = NUM2SIZE(voffset);
  reduce = (CArray *) ca_reduce_new(parent, count, offset);

  rc = ca_iter_state_init_l1(&st, reduce, CA_SLAB_WHOLE, NULL, 0,
                             CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) {
    ca_free(reduce);
    return INT2NUM(rc);
  }
  while ( ca_iter_state_next_slab(&st, &p, NULL, &n) ) {
    for ( i = 0; i < n; i++ ) p[i] = v;
    ca_iter_state_sync_slab(&st);  /* sends the changed cells back */
  }
  ca_iter_state_finish(&st);
  ca_free(reduce);
  return INT2NUM(CA_ITER_OK);
}

/* ---- CARemap smoke helpers --------------------------------------------
   CARemap has no public Ruby constructor, so we
   construct it from C using the (ref, idx) args.  Pattern mirrors
   rb_t1_smoke_reduce_*: build the view, run the iterator state
   machine, return the standard hash (rc / slabs / total_elems /
   alias_mode / data).  Expected alias_mode = ALIAS_NONE since
   SRC_ATTACH always materialises via xfer_all into iter-owned
   scratch.                                                            */

static VALUE
rb_t1_smoke_remap_read (VALUE klass, VALUE vref, VALUE vidx)
{
  CArray         *ref, *idx, *view;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n;
  int             rc;
  int             slabs       = 0;
  ca_size_t       total_elems = 0;
  int             alias_mode  = CA_ITER_ALIAS_NONE;
  VALUE           result, data;

  (void) klass;
  TypedData_Get_Struct(vref, CArray, &carray_data_type, ref);
  TypedData_Get_Struct(vidx, CArray, &carray_data_type, idx);
  view = ca_remap_new(ref, idx);
  data = rb_str_new(0, 0);

  rc = ca_iter_state_init_l1(&st, view, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc == CA_ITER_OK ) {
    while ( ca_iter_state_next_slab(&st, &p, NULL, &n) ) {
      if ( p != NULL && n > 0 ) rb_str_cat(data, p, n * st.bytes);
      total_elems += n;
      slabs++;
    }
    alias_mode = st.alias_mode;
    ca_iter_state_finish(&st);
  }
  ca_free(view);

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("rc")),          INT2NUM(rc));
  rb_hash_aset(result, ID2SYM(rb_intern("slabs")),       INT2NUM(slabs));
  rb_hash_aset(result, ID2SYM(rb_intern("total_elems")), SIZE2NUM(total_elems));
  rb_hash_aset(result, ID2SYM(rb_intern("alias_mode")),  INT2NUM(alias_mode));
  rb_hash_aset(result, ID2SYM(rb_intern("data")),        data);
  return result;
}

static VALUE
rb_t1_smoke_remap_read_strided (VALUE klass, VALUE vref, VALUE vidx)
{
  CArray         *ref, *idx, *view;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n;
  int             rc;
  int             slabs       = 0;
  ca_size_t       total_elems = 0;
  int             alias_mode  = CA_ITER_ALIAS_NONE;
  VALUE           result, data;

  (void) klass;
  TypedData_Get_Struct(vref, CArray, &carray_data_type, ref);
  TypedData_Get_Struct(vidx, CArray, &carray_data_type, idx);
  view = ca_remap_new(ref, idx);
  data = rb_str_new(0, 0);

  rc = t1_smoke_open_rows(&st, view, 0);
  if ( rc == CA_ITER_OK ) {
    ca_size_t stride;
    while ( t1_smoke_next_row(&st, &p, &n, &stride) ) {
      ca_size_t i;
      for ( i = 0; i < n; i++ ) {
        rb_str_cat(data, p + i * stride, st.bytes);
      }
      total_elems += n;
      slabs++;
    }
    alias_mode = st.alias_mode;
    ca_iter_state_finish(&st);
  }
  ca_free(view);

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("rc")),          INT2NUM(rc));
  rb_hash_aset(result, ID2SYM(rb_intern("slabs")),       INT2NUM(slabs));
  rb_hash_aset(result, ID2SYM(rb_intern("total_elems")), SIZE2NUM(total_elems));
  rb_hash_aset(result, ID2SYM(rb_intern("alias_mode")),  INT2NUM(alias_mode));
  rb_hash_aset(result, ID2SYM(rb_intern("data")),        data);
  return result;
}

/* WRITE smoke: fill view's slab buffer with `val` (float64), let
   sync_slab send the changed cells back to ref through the view
   (ki_scratch_push_changed: ca_xfer_addrs or ca_xfer_all PUT). */
static VALUE
rb_t1_smoke_remap_write_fill_f64 (VALUE klass, VALUE vref, VALUE vidx,
                                  VALUE vval)
{
  CArray         *ref, *idx, *view;
  ca_iter_state   st;
  char           *p;
  ca_size_t       n, i;
  int             rc;
  double          v = NUM2DBL(vval);

  (void) klass;
  TypedData_Get_Struct(vref, CArray, &carray_data_type, ref);
  TypedData_Get_Struct(vidx, CArray, &carray_data_type, idx);
  view = ca_remap_new(ref, idx);

  rc = ca_iter_state_init_l1(&st, view, CA_SLAB_WHOLE, NULL, 0,
                             CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) {
    ca_free(view);
    return INT2NUM(rc);
  }
  while ( ca_iter_state_next_slab(&st, &p, NULL, &n) ) {
    double *q = (double *) p;
    for ( i = 0; i < n; i++ ) q[i] = v;
    ca_iter_state_sync_slab(&st);
  }
  ca_iter_state_finish(&st);
  ca_free(view);
  return INT2NUM(CA_ITER_OK);
}

/* ---- CA_FOR_EACH_SLAB macro smoke surfaces ---------------------------
   Smoke kernels that exercise the block macros end-to-end.  Used by
   spec_ai/test_ca_for_each_slab_macros.rb to pin behavioural
   correctness of the macro expansion (= same byte-parity result as
   the raw API equivalent). */

/* sum reduction using CA_FOR_EACH_SLAB over the slab axes given in
   argv[1..] (K-D slabs).  Reads the source as float64 without checking
   its data_type.  Accumulator = scalar (single full-reduction slab when
   naxes == src->ndim, otherwise per-outer-slab accumulator written to a
   row-major output buffer). */
static VALUE
rb_caf_smoke_sum_f64 (int argc, VALUE *argv, VALUE klass)
{
  (void) klass;
  if ( argc < 2 ) {
    rb_raise(rb_eArgError, "expected (src, axis_int, ...)");
  }

  VALUE   vsrc = argv[0];
  CArray *ca;
  GetCArray(vsrc, ca);

  int8_t slab_axes[CA_RANK_MAX];
  int8_t naxes = (int8_t) (argc - 1);
  if ( naxes < 1 || naxes > ca->ndim ) {
    rb_raise(rb_eArgError, "bad axes count");
  }
  for ( int8_t k = 0; k < naxes; k++ ) {
    /* fits: an axis number, checked by the engine's init */
    slab_axes[k] = (int8_t) NUM2INT(argv[1 + k]);
    if ( slab_axes[k] < 0 ) slab_axes[k] += ca->ndim;
  }

  /* Output: same layout policy as sum_ki (= reduced shape via
     rb_ca_new_reduced).  For full reduction naxes == ndim, output
     is a 1-element CArray that we unwrap to Float below. */
  VALUE   vout = rb_ca_new_reduced(vsrc, slab_axes, naxes, CA_FLOAT64, 0);
  CArray *co;
  GetCArray(vout, co);
  double *op = (double *) co->ptr;

  ca_iter_state st;
  char       *p;
  boolean8_t *m;
  ca_size_t   out_i = 0;

  CA_FOR_EACH_SLAB(st, ca, slab_axes, naxes, 0, p, m) {
    /* K-1 outer carry + innermost inner walk (= same shape as sum_ki).
       Required for slab_ndim > 1 because slab cells aren't a single
       contig run with one stride — outer slab axes have their own
       strides. */
    double    acc       = 0.0;
    int8_t    K         = st.slab_ndim;
    int8_t    outer_K   = K - 1;
    ca_size_t inner_n   = st.slab_dims[K - 1];
    ca_size_t inner_s   = st.slab_strides[K - 1];
    ca_size_t inner_ms  = st.slab_mask_strides[K - 1];

    ca_size_t outer_count = 1;
    for ( int8_t k = 0; k < outer_K; k++ ) outer_count *= st.slab_dims[k];

    ca_size_t idx[CA_RANK_MAX] = { 0 };
    for ( ca_size_t o = 0; o < outer_count; o++ ) {
      ca_size_t data_off = 0;
      ca_size_t mask_off = 0;
      for ( int8_t k = 0; k < outer_K; k++ ) {
        data_off += idx[k] * st.slab_strides[k];
        mask_off += idx[k] * st.slab_mask_strides[k];
      }
      const char *q = p + data_off;
      if ( m == NULL ) {
        for ( ca_size_t j = 0; j < inner_n; j++ ) {
          acc += *(const double *) (q + j * inner_s);
        }
      } else {
        const boolean8_t *mm = m + mask_off;
        for ( ca_size_t j = 0; j < inner_n; j++ ) {
          if ( ! mm[j * inner_ms] ) {
            acc += *(const double *) (q + j * inner_s);
          }
        }
      }
      for ( int8_t k = outer_K - 1; k >= 0; k-- ) {
        if ( ++idx[k] < st.slab_dims[k] ) break;
        idx[k] = 0;
      }
    }
    op[out_i++] = acc;
  }

  if ( naxes == ca->ndim ) {
    return rb_float_new(op[0]);
  }
  return vout;
}

/* map kernel using CA_FOR_EACH_SLAB_INOUT.  Doubles each element of
   a float64 source into a fresh same-shape output.  Slab axis is
   always the innermost (ca->ndim - 1); there is no axis argument.
   Demonstrates the 2-iter pattern. */
static VALUE
rb_caf_smoke_double_f64 (VALUE klass, VALUE vsrc)
{
  (void) klass;
  CArray *ca;
  GetCArray(vsrc, ca);
  if ( ca->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eTypeError, "expected float64 source");
  }

  VALUE   vout = rb_ca_template_with_type(vsrc, INT2NUM(CA_FLOAT64), Qnil);
  CArray *co;
  GetCArray(vout, co);

  int8_t slab_axes[CA_RANK_MAX];
  int8_t naxes = 1;
  slab_axes[0] = (int8_t) (ca->ndim - 1);

  ca_iter_state st_in, st_out;
  char       *p_in,  *p_out;
  boolean8_t *m_in,  *m_out;

  CA_FOR_EACH_SLAB_INOUT(st_in, st_out, ca, co,
                         slab_axes, naxes,
                         p_in, p_out, m_in, m_out) {
    ca_size_t n        = st_in.slab_n;
    ca_size_t in_s     = st_in.slab_strides[st_in.slab_ndim - 1];
    ca_size_t out_s    = st_out.slab_strides[st_out.slab_ndim - 1];
    /* Both sides float64; for the typical entity output, in_s = out_s
       = sizeof(double).  Mask propagation: if input is masked at cell
       j, just leave output alone (= CArray's default mask propagation
       happens via co's own mask, not our concern here for the smoke). */
    (void) m_in;
    (void) m_out;
    for ( ca_size_t j = 0; j < n; j++ ) {
      double v = *(const double *) (p_in + j * in_s);
      *(double *) (p_out + j * out_s) = v * 2.0;
    }
  }

  return vout;
}

/* ---- CA_FOR_EACH_FIBER macro smokes ----------------------------------
   Exercise each of the 4 catalog forms end-to-end with float64 fibers,
   verifying contig delivery for both innermost (= stride==bytes) and
   non-innermost (= stride>bytes, gather path) axis positions.  Used by
   spec_ai/test_fiber_delivery.rb. */

/* form 1 (NO_MASK single): per-axis sum, returns total sum.
   Catalog: CA_FOR_EACH_FIBER. */
static VALUE
rb_caf_fiber_smoke_sum_f64 (VALUE klass, VALUE vsrc, VALUE vaxis)
{
  CArray        *src;
  ca_iter_state  st;
  char          *p;
  ca_size_t      n;
  double         total = 0.0;
  int            axis  = NUM2INT(vaxis);

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "caf_fiber_smoke_sum_f64: requires float64");
  }
  CA_FOR_EACH_FIBER(st, src, axis, CA_KERNEL_NO_MASK, p, n) {
    const double *pd = (const double *) p;
    for ( ca_size_t i = 0; i < n; i++ ) total += pd[i];
  }
  return rb_float_new(total);
}

/* form 2 (NO_MASK INOUT): per-axis fiber copy * scalar.
   Catalog: CA_FOR_EACH_FIBER_INOUT.  Doubles each cell of each fiber. */
static VALUE
rb_caf_fiber_smoke_double_f64 (VALUE klass, VALUE vsrc, VALUE vaxis)
{
  CArray        *src, *out;
  ca_iter_state  st_in, st_out;
  char          *pi, *po;
  ca_size_t      n;
  int            axis = NUM2INT(vaxis);
  VALUE          vout;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "caf_fiber_smoke_double_f64: requires float64");
  }
  vout = rb_ca_template(vsrc);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, out);

  CA_FOR_EACH_FIBER_INOUT(st_in, st_out, src, out, axis,
                          CA_KERNEL_NO_MASK, pi, po, n) {
    double *dpi = (double *) pi;
    double *dpo = (double *) po;
    for ( ca_size_t i = 0; i < n; i++ ) dpo[i] = dpi[i] * 2.0;
  }
  return vout;
}

/* form 3 (mask-aware single): unmasked sum.
   Catalog: CA_FOR_EACH_FIBER_MASKED. */
static VALUE
rb_caf_fiber_smoke_unmasked_sum_f64 (VALUE klass, VALUE vsrc, VALUE vaxis)
{
  CArray        *src;
  ca_iter_state  st;
  char          *p;
  boolean8_t    *m;
  ca_size_t      n;
  double         total = 0.0;
  int            axis  = NUM2INT(vaxis);

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "caf_fiber_smoke_unmasked_sum_f64: requires float64");
  }
  CA_FOR_EACH_FIBER_MASKED(st, src, axis, 0, p, n, m) {
    double *dp = (double *) p;
    for ( ca_size_t i = 0; i < n; i++ ) {
      if ( !m || !m[i] ) total += dp[i];
    }
  }
  return rb_float_new(total);
}

/* form 4 (mask-aware INOUT): copy input but zero out masked cells in
   output.  Catalog: CA_FOR_EACH_FIBER_INOUT_MASKED. */
static VALUE
rb_caf_fiber_smoke_zero_masked_f64 (VALUE klass, VALUE vsrc, VALUE vaxis)
{
  CArray        *src, *out;
  ca_iter_state  st_in, st_out;
  char          *pi, *po;
  boolean8_t    *m;
  ca_size_t      n;
  int            axis = NUM2INT(vaxis);
  VALUE          vout;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "caf_fiber_smoke_zero_masked_f64: requires float64");
  }
  vout = rb_ca_template(vsrc);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, out);

  CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, src, out, axis,
                                  0, pi, po, n, m) {
    double *dpi = (double *) pi;
    double *dpo = (double *) po;
    for ( ca_size_t i = 0; i < n; i++ ) {
      dpo[i] = (m && m[i]) ? 0.0 : dpi[i];
    }
  }
  return vout;
}

/* Bench helper: sort_copy via CA_FOR_EACH_FIBER_INOUT.
   Functional equivalent of the per-axis sort_copy (rb_ca_sort_copy in
   ext/carray_sort.c).
   The macro form lets us A/B the author-side overhead of stride math
   vs the catalog-macro-driven engine gather/scatter. */
static int
caf_fiber_bench_cmp_double (const void *a, const void *b)
{
  double da = *(const double *) a;
  double db = *(const double *) b;
  return (da > db) - (da < db);
}

static VALUE
rb_caf_fiber_bench_sort_copy_f64 (VALUE klass, VALUE vsrc, VALUE vaxis)
{
  CArray        *src, *out;
  ca_iter_state  st_in, st_out;
  char          *pi, *po;
  ca_size_t      n;
  int            axis = NUM2INT(vaxis);
  VALUE          vout;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "caf_fiber_bench_sort_copy_f64: requires float64");
  }
  vout = rb_ca_template(vsrc);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, out);

  CA_FOR_EACH_FIBER_INOUT(st_in, st_out, src, out, axis,
                          CA_KERNEL_NO_MASK, pi, po, n) {
    double *dpo = (double *) po;
    memcpy(po, pi, n * sizeof(double));
#ifdef HAVE_MERGESORT
    if ( mergesort(dpo, n, sizeof(double), caf_fiber_bench_cmp_double) != 0 ) {
      qsort(dpo, n, sizeof(double), caf_fiber_bench_cmp_double);
    }
#else
    qsort(dpo, n, sizeof(double), caf_fiber_bench_cmp_double);
#endif
  }
  return vout;
}

/* Bench helper variant: sort_copy via SLAB macro + manual
   gather/scatter (= what hand-rolled sort_copy effectively does, but
   driven through the public CA_FOR_EACH_SLAB_INOUT macro instead of
   the raw next_slab_axes API).  Lets us isolate macro overhead from
   gather/scatter overhead. */
static VALUE
rb_caf_slab_bench_sort_copy_f64 (VALUE klass, VALUE vsrc, VALUE vaxis)
{
  CArray        *src, *out;
  ca_iter_state  st_in, st_out;
  char          *pi, *po;
  boolean8_t    *mi, *mo;
  int            axis = NUM2INT(vaxis);
  VALUE          vout;
  int8_t         slab_axes[1];

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError, "caf_slab_bench_sort_copy_f64: requires float64");
  }
  vout = rb_ca_template(vsrc);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, out);
  slab_axes[0] = (int8_t) axis;

  if ( axis < 0 || axis >= src->ndim ) {
    rb_raise(rb_eArgError, "caf_slab_bench_sort_copy_f64: axis out of range");
  }
  ca_size_t fiber_n = src->dim[axis];
  ca_size_t bytes   = sizeof(double);
  volatile VALUE holder;        /* the walk can raise while buf is held */
  char *buf = ALLOCV_N(char, holder, fiber_n * bytes);

  CA_FOR_EACH_SLAB_INOUT(st_in, st_out, src, out,
                         slab_axes, 1,
                         pi, po, mi, mo) {
    ca_size_t n  = st_in.slab_dims[0];
    ca_size_t is = st_in.slab_strides[0];
    ca_size_t os = st_out.slab_strides[0];
    /* Author-side gather (= what hand-rolled sort_copy does). */
    if ( is == (ca_size_t) bytes ) {
      memcpy(buf, pi, n * bytes);
    } else {
      for ( ca_size_t k = 0; k < n; k++ ) {
        memcpy(buf + k * bytes, pi + k * is, bytes);
      }
    }
#ifdef HAVE_MERGESORT
    if ( mergesort(buf, n, bytes, caf_fiber_bench_cmp_double) != 0 ) {
      qsort(buf, n, bytes, caf_fiber_bench_cmp_double);
    }
#else
    qsort(buf, n, bytes, caf_fiber_bench_cmp_double);
#endif
    /* Author-side scatter. */
    if ( os == (ca_size_t) bytes ) {
      memcpy(po, buf, n * bytes);
    } else {
      for ( ca_size_t k = 0; k < n; k++ ) {
        memcpy(po + k * os, buf + k * bytes, bytes);
      }
    }
  }
  ALLOCV_END(holder);
  return vout;
}

/* Bench helper: per-fiber fused xfer_stride direct into a contig
   scratch, skipping the kernel_iterator SRC_ATTACH whole-view materialise.
   Tests user's hypothesis: for transform views (CAFake/CAByteSwap etc.),
   does bypassing the whole-view scratch_ptr and calling ca_xfer_stride
   per-fiber (= fused 1-pass per fiber) beat the current FIBER path?

   Scope: float64 view, sum along a single axis.  No kernel_iterator
   state is created -- this directly walks fiber regions via outer
   odometer + per-fiber ca_xfer_stride call. */
static VALUE
rb_caf_bench_per_fiber_xfer_sum_f64 (VALUE klass, VALUE vsrc, VALUE vaxis)
{
  CArray   *src;
  int       axis;
  double    total = 0.0;
  ca_size_t starts[CA_RANK_MAX], counts[CA_RANK_MAX], strides[CA_RANK_MAX];
  ca_size_t outer_idx[CA_RANK_MAX];
  int8_t    nd, k;

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eArgError,
             "caf_bench_per_fiber_xfer_sum_f64: requires float64 view");
  }
  axis = NUM2INT(vaxis);
  nd   = src->ndim;
  if ( axis < 0 || axis >= nd ) {
    rb_raise(rb_eArgError, "axis out of range");
  }

  /* Fiber length = src->dim[axis], fiber count = product of other dims. */
  ca_size_t fiber_n = src->dim[axis];
  ca_size_t total_fibers = 1;
  for ( k = 0; k < nd; k++ ) {
    if ( k != axis ) total_fibers *= src->dim[k];
    outer_idx[k] = 0;
  }

  /* Per-axis native byte strides (row-major) for use in ca_xfer_stride. */
  ca_size_t native[CA_RANK_MAX];
  {
    ca_size_t s = src->bytes;
    for ( k = nd - 1; k >= 0; k-- ) { native[k] = s; s *= src->dim[k]; }
  }

  /* Fiber-sized contig scratch. */
  volatile VALUE holder;
  char *buf = ALLOCV_N(char, holder, fiber_n * src->bytes);

  for ( ca_size_t f = 0; f < total_fibers; f++ ) {
    /* Build region: counts = 1 on all non-axis, fiber_n on axis;
       starts from outer_idx (0 on axis); strides = native bytes. */
    for ( k = 0; k < nd; k++ ) {
      starts[k]  = (k == axis) ? 0 : outer_idx[k];
      counts[k]  = (k == axis) ? fiber_n : 1;
      strides[k] = native[k];
    }

    /* ONE fused xfer_stride per fiber: for CAFake/CAByteSwap this
       routes to ca_xfer_stride_transform_fused (= 1-pass cast direct
       from parent to buf, no intermediate whole-view scratch). */
    ca_xfer_stride(src, starts, counts, strides, buf, CA_XFER_GET);

    /* Sum the fiber. */
    double *p = (double *) buf;
    for ( ca_size_t i = 0; i < fiber_n; i++ ) total += p[i];

    /* Advance outer_idx row-major over non-axis dims. */
    for ( k = nd - 1; k >= 0; k-- ) {
      if ( k == axis ) continue;
      if ( ++outer_idx[k] < src->dim[k] ) break;
      outer_idx[k] = 0;
    }
  }

  ALLOCV_END(holder);
  return rb_float_new(total);
}

/* CArray.__iter_buffers__: see ki_buffers_out. */
static VALUE
rb_ki_buffers_out (VALUE klass)
{
  (void) klass;
  return LONG2NUM(ki_buffers_out);
}

#endif /* CARRAY_DEV_BUILD — end smoke surface fence */

void
Init_ca_kernel_iterator (void)
{
  ki_kept_key = rb_ractor_local_storage_ptr_newkey(&ki_kept_type);

#ifdef CARRAY_DEV_BUILD
  /* ==== smoke surface registrations (dev-only, stripped in release) ====
   * All `t1_smoke_*`, `caf_smoke_*`,
   * `caf_fiber_smoke_*`, `caf_*_bench_*`, helper smokes, and `T1_*` test
   * constants are gated here together — none of them are consumed by
   * production code (lib/ / other ext/), only by spec_ai regression pins. */
  rb_define_singleton_method(rb_cCArray, "__iter_buffers__",
                             rb_ki_buffers_out, 0);
  rb_define_singleton_method(rb_cCArray, "t1_smoke",
                             rb_t1_smoke, 1);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_strided",
                             rb_t1_smoke_strided, 1);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_sum_strided_f64",
                             rb_t1_smoke_sum_strided_f64, 1);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_write_fill_f64",
                             rb_t1_smoke_write_fill_f64, 2);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_write_fill_strided_f64",
                             rb_t1_smoke_write_fill_strided_f64, 2);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_write_partial_raise_f64",
                             rb_t1_smoke_write_partial_raise_f64, 3);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_sort_row_f64",
                             rb_t1_smoke_sort_row_f64, 1);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_attach",
                             rb_t1_smoke_attach, 1);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_attach_strided",
                             rb_t1_smoke_attach_strided, 1);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_with_mask",
                             rb_t1_smoke_with_mask, 1);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_init_rc",
                             rb_t1_smoke_init_rc, 2);
  /* CA_SLAB_AXES smoke (variadic axes) */
  rb_define_singleton_method(rb_cCArray, "t1_smoke_sum_axes_f64",
                             rb_t1_smoke_sum_axes_f64, -1);
  /* rb_ca_new_reduced helper smoke */
  rb_define_singleton_method(rb_cCArray, "t1_test_new_reduced",
                             rb_t1_test_new_reduced, -1);
  /* rb_ca_parse_reduce_axes helper smoke */
  rb_define_singleton_method(rb_cCArray, "t1_test_parse_reduce_axes",
                             rb_t1_test_parse_reduce_axes, -1);

  /* rb_ca_parse_reduce_axes_kw helper smoke */
  rb_define_singleton_method(rb_cCArray, "test_parse_reduce_axes_kw",
                             rb_test_parse_reduce_axes_kw, -1);
  /* CAReduce: no public Ruby API */
  rb_define_singleton_method(rb_cCArray, "t1_make_reduce",
                             rb_t1_make_reduce, 3);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_reduce_read",
                             rb_t1_smoke_reduce_read, 3);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_reduce_write_broadcast",
                             rb_t1_smoke_reduce_write_broadcast, 4);

  /* CARemap smokes (test-only). */
  rb_define_singleton_method(rb_cCArray, "t1_smoke_remap_read",
                             rb_t1_smoke_remap_read, 2);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_remap_read_strided",
                             rb_t1_smoke_remap_read_strided, 2);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_remap_write_fill_f64",
                             rb_t1_smoke_remap_write_fill_f64, 3);
  /* block macro smokes */
  rb_define_singleton_method(rb_cCArray, "caf_smoke_sum_f64",
                             rb_caf_smoke_sum_f64, -1);
  rb_define_singleton_method(rb_cCArray, "caf_smoke_double_f64",
                             rb_caf_smoke_double_f64, 1);
  /* fiber macro smokes */
  rb_define_singleton_method(rb_cCArray, "caf_fiber_smoke_sum_f64",
                             rb_caf_fiber_smoke_sum_f64, 2);
  rb_define_singleton_method(rb_cCArray, "caf_fiber_smoke_double_f64",
                             rb_caf_fiber_smoke_double_f64, 2);
  rb_define_singleton_method(rb_cCArray, "caf_fiber_smoke_unmasked_sum_f64",
                             rb_caf_fiber_smoke_unmasked_sum_f64, 2);
  rb_define_singleton_method(rb_cCArray, "caf_fiber_smoke_zero_masked_f64",
                             rb_caf_fiber_smoke_zero_masked_f64, 2);
  /* bench helper */
  rb_define_singleton_method(rb_cCArray, "caf_fiber_bench_sort_copy_f64",
                             rb_caf_fiber_bench_sort_copy_f64, 2);
  rb_define_singleton_method(rb_cCArray, "caf_slab_bench_sort_copy_f64",
                             rb_caf_slab_bench_sort_copy_f64, 2);
  rb_define_singleton_method(rb_cCArray, "caf_bench_per_fiber_xfer_sum_f64",
                             rb_caf_bench_per_fiber_xfer_sum_f64, 2);

  rb_define_const(rb_cCArray, "T1_ITER_OK",              INT2NUM(CA_ITER_OK));
  rb_define_const(rb_cCArray, "T1_ITER_ERR_NOT_CHEAP",   INT2NUM(CA_ITER_ERR_NOT_CHEAP));
  rb_define_const(rb_cCArray, "T1_ITER_ERR_POLICY",      INT2NUM(CA_ITER_ERR_POLICY));
  rb_define_const(rb_cCArray, "T1_ITER_ERR_FLAGS",       INT2NUM(CA_ITER_ERR_FLAGS));
  rb_define_const(rb_cCArray, "T1_ITER_ERR_READONLY",    INT2NUM(CA_ITER_ERR_READONLY));
  rb_define_const(rb_cCArray, "T1_ITER_ERR_MASK",        INT2NUM(CA_ITER_ERR_MASK));
  rb_define_const(rb_cCArray, "T1_ITER_ERR_MASK_NOT_ALLOWED", INT2NUM(CA_ITER_ERR_MASK_NOT_ALLOWED));
  rb_define_const(rb_cCArray, "T1_KERNEL_NO_MASK",       INT2NUM(CA_KERNEL_NO_MASK));
  rb_define_const(rb_cCArray, "T1_ITER_ALIAS_NONE",      INT2NUM(CA_ITER_ALIAS_NONE));
  rb_define_const(rb_cCArray, "T1_ITER_ALIAS_CONTIG",    INT2NUM(CA_ITER_ALIAS_CONTIG));
  rb_define_const(rb_cCArray, "T1_ITER_ALIAS_STRIDED",   INT2NUM(CA_ITER_ALIAS_STRIDED));
  rb_define_const(rb_cCArray, "T1_ITER_ALIAS_ATTACH",    INT2NUM(CA_ITER_ALIAS_ATTACH));
  rb_define_const(rb_cCArray, "T1_ITER_ALIAS_PER_SLAB",  INT2NUM(CA_ITER_ALIAS_PER_SLAB));
#endif /* CARRAY_DEV_BUILD */
}
