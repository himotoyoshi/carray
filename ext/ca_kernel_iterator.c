/* ---------------------------------------------------------------------------

  T1 kernel_iterator MVP — Phase 1 step 1 + step 2 + step 3 implementation.

  Scope after step 3 (PROPOSAL_T1_KERNEL_ITERATOR.md §10.3):
    - ca_iter_state struct + init / next_slab / next_slab_strided /
      finish state machine
    - CA_SLAB_WHOLE policy only (step 5+ adds AXES / FREE)
    - level == 1 (L1, contig kernel):
        - entity / CAStride contig: alias path (single slab, alias_ptr
          = parent->ptr, stride implicit = bytes)
        - CAStride family non-contig: scratch path (ca_copy_data
          compose-fold gather into a malloc'd buffer)
        - other sources: CA_ITER_ERR_NOT_CHEAP
    - level == 2 (L2, strided kernel):
        - entity / CAStride contig: alias path (single slab,
          stride_bytes = bytes)
        - CAStride family non-contig: alias_strided path — no scratch,
          per-outer-prefix yield with native inner stride_bytes
        - other sources: CA_ITER_ERR_NOT_CHEAP
    - READ-only (flags == 0). WRITE = step 4, NO_MASK = step 7.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */
#include "ca_kernel_iterator.h"
#include "ca_monop_dispatch.h"   /* P.6.2.d: ca_monop_view_is_single_cast for F.6.2 gate */
#include "ca_obj_face.h"      /* PROPOSAL_CAFACE_PHASE_2 F.2.6 — ca_strip_face for SRC_* entry */

#include <assert.h>
#include <string.h>

/* Defined in carray_core.c. (ca_is_readonly / ca_has_mask /
   ca_sync_data are already declared in carray.h.) */
extern int  ca_attach_is_alias (void *ap);
extern int  ca_root_lends_no_memory (void *ap);

/* CAStride family attach-fn marker (step 1-4). */
extern ca_operation_function_t ca_stride_func;

/* Descriptor framework view ops (step 5+).  Each view's describe_axes
   emits the per-axis descriptor + parent dim snapshot consumed by
   the P3 ca_axis_dispatch_* substrate.  CAShift uses ca_window_func
   (Phase G typedef pattern, ca_shift_func is a copy with only free /
   clone / create_mask overridden) so it routes via attach pointer
   match against ca_window_func.attach. */
extern ca_operation_function_t ca_select_axis_func;
extern ca_operation_function_t ca_grid_func;
extern ca_operation_function_t ca_select_func;
extern ca_operation_function_t ca_window_func;
/* ca_mapping_func retired in R.3 (PROPOSAL_CAMAPPING_REMOVAL). */

/* SRC_ATTACH 5 view (step 9).  Each defines its own attach that
   materialises src->ptr via view-specific transform (cast / swap /
   bit unpack / reduction).  kernel_iterator treats them uniformly:
   ca_attach(src) → kernel sees src->ptr as contig → on WRITE,
   ca_sync(src) lets the view's sync_data scatter back. */
extern ca_operation_function_t ca_fake_func;
extern ca_operation_function_t ca_byte_swap_func;
extern ca_operation_function_t ca_bitfield_func;
extern ca_operation_function_t ca_bitarray_func;
extern ca_operation_function_t ca_reduce_func;
extern ca_operation_function_t ca_object_func;

/* F-2 follow-up (2026-05-26): connect CATile / CARoll to kernel_iterator
   via the SRC_ATTACH pattern. Per-cell modulo wrap does not fit the
   descriptor framework's kind enum {STRIDE, INDEX, SHIFT}, so the
   innermost-STRIDE L2 alias path is not used; but the view-specific
   func_attach (embed-region gather) materialises src->ptr and func_sync
   scatters back — structurally identical to SRC_ATTACH. Fills the gap
   in the "deliver" principle (= these were previously rejected via
   SRC_NONE). */
extern ca_operation_function_t ca_tile_func;
extern ca_operation_function_t ca_roll_func;

/* PROPOSAL_CASTACK.md Phase 3 (2026-06-18): CAStack via SRC_ATTACH.
   func_attach materialises src->ptr via per-parent ca_xfer_all GET
   (= K * parent.bytes alloc, caller responsibility per MEMO §3.4);
   func_sync scatters back via xfer_all PUT.  kernel sees a flat
   contig slab over the stacked output of shape (K, *parent_shape). */
extern ca_operation_function_t ca_stack_func;
extern ca_operation_function_t ca_meld_func;

/* M.6 (PROPOSAL_CAREMAP_INTERNAL.md §5.2): CARemap is internal-only
   (no Ruby class constant) but participates in kernel_iterator as an
   SRC_ATTACH source.  Per-element gather has no STRIDE structure to
   preserve, so SRC_ATTACH (scratch materialise via ca_remap_func_attach)
   is the natural acceptance path.  func_attach allocates a fresh
   buffer and runs xfer_all(GET); kernel sees a flat contig slab.
   On WRITE, ca_sync routes through xfer_all(PUT). */
extern ca_operation_function_t ca_remap_func;

/* PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4.5 P.4.5.1 (2026-06-07): lazy
   element-wise view family.  CAMonOp (Phase 1) / CABinOp (Phase 2) /
   CABinCmp + CAMonCmp (Phase 4) all expose a func_attach that pulls
   the lazy tree's materialise into a fresh contig buffer; kernel sees
   a flat slab.  Same SRC_ATTACH structural pattern as CAFake et al,
   so a 4-line addition to the classify_source list opens all 22
   mkkernel-generated reduction ops (sum / count / mean / variance /
   argmin / ...) to lazy operands — `(a.lazy + b).sum` now works.   */
extern ca_operation_function_t ca_monop_func;
extern ca_operation_function_t ca_binop_func;
extern ca_operation_function_t ca_bincmp_func;
extern ca_operation_function_t ca_moncmp_func;
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

/* Classify the source by routing kind (proposal §1 strategy table).
   Returns CA_ITER_SRC_NONE for sources not yet supported. */
static uint8_t
ca_iter_classify_source (CArray *src)
{
  if ( src == NULL ) return CA_ITER_SRC_NONE;
  if ( ca_is_entity(src) )                return CA_ITER_SRC_CASTRIDE;
  if ( ca_iter_is_castride_family(src) )  return CA_ITER_SRC_CASTRIDE;

  /* Externally installed obj_types declare their routing (2026-08-07).
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

  /* Descriptor framework views (step 5.1: CSA + CAGrid; 5.2: + CASelect /
     CAMapping / CAWindow / CAShift).  CAShift uses ca_window_func
     for attach (Phase G typedef pattern) so it matches the CAWindow
     check below. */
  void *attach = ca_func[src->obj_type].attach;
  if ( attach == ca_select_axis_func.attach ) return CA_ITER_SRC_DESCRIPTOR;
  if ( attach == ca_grid_func.attach        ) return CA_ITER_SRC_DESCRIPTOR;
  if ( attach == ca_select_func.attach      ) return CA_ITER_SRC_DESCRIPTOR;
  if ( attach == ca_window_func.attach      ) return CA_ITER_SRC_DESCRIPTOR;  /* + CAShift */

  /* Step 9: SRC_ATTACH 5 view.  Each view-specific attach materialises
     src->ptr via per-element transform; kernel sees a flat contig slab.
     CAUnboundRepeat shares ca_stride_func.attach so it was already
     classified as SRC_CASTRIDE above (prep doc §2.6). */
  if ( attach == ca_fake_func.attach        ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_byte_swap_func.attach   ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_bitfield_func.attach    ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_bitarray_func.attach    ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_reduce_func.attach      ) return CA_ITER_SRC_ATTACH;
  /* Step 11: CAObject — Ruby callback per-element bridge.  Same
     SRC_ATTACH structural pattern (func_attach materialises via Ruby
     copy_data, func_sync scatters back via Ruby sync_data, CA_FLAG_
     READ_ONLY auto-rejects WRITE via ca_is_readonly).  Bench gate
     n/a (Ruby callback overhead structurally dominant). */
  if ( attach == ca_object_func.attach      ) return CA_ITER_SRC_ATTACH;

  /* F-2 follow-up: CATile / CARoll via SRC_ATTACH (embed-region gather
     materialises src->ptr; ca_sync scatters back per view-specific
     semantics — CATile tile decomposition, CARoll cyclic permutation). */
  if ( attach == ca_tile_func.attach        ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_roll_func.attach        ) return CA_ITER_SRC_ATTACH;

  /* Phase 3 (PROPOSAL_CASTACK.md): CAStack via SRC_ATTACH.  func_attach
     materialises src->ptr via per-parent ca_xfer_all GET (= K * parent
     bytes alloc, caller responsibility per MEMO §3.4); func_sync
     scatters back via xfer_all PUT.  kernel sees a flat contig slab
     over the stacked output.  Routine ndim mismatch is irrelevant
     here (= attach delivers a self-owned buffer of shape (K, *parent
     shape), kernel reads/writes that buffer). */
  if ( attach == ca_stack_func.attach       ) return CA_ITER_SRC_ATTACH;

  /* CAMeld — ragged concatenate along an existing axis.  func_attach
     materialises via K per-parent xfer_all GET into a contig buffer at
     seg_offset[k] * tail_bytes offsets; func_sync scatters back.  Same
     SRC_ATTACH structural pattern as CAStack; reduce hot paths bypass
     this via the per-parent decompose in lib/carray/meld_reduce.rb. */
  if ( attach == ca_meld_func.attach        ) return CA_ITER_SRC_ATTACH;

  /* M.6: CARemap — per-element gather, internal-only.  Same SRC_ATTACH
     structural pattern (func_attach materialises via xfer_all GET,
     func_sync via xfer_all PUT). */
  if ( attach == ca_remap_func.attach       ) return CA_ITER_SRC_ATTACH;

  /* Phase 4.5 P.4.5.1: lazy view family — CAMonOp / CABinOp / CABinCmp /
     CAMonCmp.  func_attach pulls the lazy chain materialise (arena-pooled
     scratches under the hood from Phase 3); kernel sees a flat contig
     slab.  Read-only (= CA_FLAG_READ_ONLY) so WRITE auto-rejects at
     the ca_is_readonly check.  Opens 22 mkkernel-generated reduction
     ops to lazy operands.                                            */
  if ( attach == ca_monop_func.attach       ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_binop_func.attach       ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_bincmp_func.attach      ) return CA_ITER_SRC_ATTACH;
  if ( attach == ca_moncmp_func.attach      ) return CA_ITER_SRC_ATTACH;

  return CA_ITER_SRC_NONE;
}

/* F-2 (PROPOSAL_F2_KERNEL_ITERATOR_ALIAS rev6): route a source by
   running classify_source and, for descriptor-routed views, also calling
   describe_axes to inspect the innermost axis kind.  Returns the refined
   src_kind (= SRC_DESCRIPTOR_L2_ALIASABLE iff innermost axis is STRIDE,
   else SRC_DESCRIPTOR).  out_descs / out_parent_dims / out_ndim are
   populated for descriptor sources so the caller (init_l1 / init_l2)
   does not have to re-call describe_axes.  For non-descriptor sources
   (CASTRIDE / ATTACH / NONE) the out_* arguments are not touched and
   classify_source's verdict is returned as-is.

   Cost analysis: classify_source is O(1) pointer compares.  For
   SRC_DESCRIPTOR candidates we add one describe_axes call (O(ndim) with
   ndim ≤ CA_RANK_MAX = 16) plus one innermost-axis kind compare.
   Per-walk overhead = 1 describe_axes call (descriptor sources only),
   which init was going to do anyway -- so the routing is net zero cost
   compared to the pre-rev6 path where classify_source + init both
   computed describe_axes redundantly.  See prep doc rev2 §4.1.1. */
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

  /* Descriptor source: describe_axes + inspect innermost. */
  ca_iter_describe_axes(src, out_descs, out_parent_dims, out_ndim);
  if ( ca_axis_dispatch_is_innermost_stride(out_descs, *out_ndim) ) {
    return CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE;
  }
  return CA_ITER_SRC_DESCRIPTOR;
}

/* Dispatch to the view's describe_axes.  Routing keyed on the
   shared attach pointer (CAShift shares with CAWindow per Phase G
   typedef). */
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

/* Public alias eligibility predicate (proposal §11.3 case (a)). */
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
      /* L3 (and any future level) — not implemented in Phase 1; L1
         fallback so the predicate stays well-defined for callers that
         probe ahead. */
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

/* ---- PROPOSAL_FIBER_PER_SOURCE_PATH F.6.1 dispatch predicate -------- */

/* Hybrid (rev2 Q2): coarse src_kind branch + view-specific func pointer
   probe + fiber-axis effective stride check (Q3).
   F.6.1 substrate: returns 0 (= disabled) for all sources.  F.6.2+
   (CAFake / CAByteSwap / CAShift / CAWindow / etc.) progressively enable
   specific source kinds with bench-driven justification.

   The fiber_axis_stride argument is the effective byte stride of the
   fiber axis on the view (= what next_slab_axes would yield as
   slab_strides[0]).  Q3-equivalence: fiber_axis_stride == src->bytes
   means the fiber is parent-memory contig, which is the precondition
   for X.1/X.4 per-region fused paths to deliver a 1-pass result.

   Called from init_l2 SRC_ATTACH branch right before the whole-view
   ca_xfer_all GET.  When returning 1, caller skips xfer_all GET and
   sets alias_mode = CA_ITER_ALIAS_PER_FIBER_FUSED with fiber dispatch
   state populated. */
static int
ca_iter_should_per_fiber_fused (CArray   *src,
                                int       src_kind,
                                int8_t    fiber_axis,
                                ca_size_t fiber_axis_stride,
                                uint32_t  flags)
{
  (void) fiber_axis;
  (void) flags;

  /* F.6.2: CAFake / CAByteSwap (transform-fused, X.4 per-region).
     Enable when fiber-axis effective stride == view cell bytes
     (= Q3: fiber is parent-memory contig run, so ca_xfer_stride
     routes into ca_xfer_stride_transform_fused inner-contig fast
     path for 1-pass per-fiber delivery).

     F.5 bench: innermost-axis fiber 30-35% faster than whole-view
     materialise (CAFake) / 16-18% (CAByteSwap).  Non-innermost (=
     fiber_axis_stride != bytes) was a loser, so the stride gate
     keeps current path for that case.

     Phase 6 P.6.2.d (Q13 α): single-cast CAMonOp (= post-migration
     successor of CAFake numeric path) is recognised via
     ca_monop_view_is_single_cast and routed through the same F.6.2
     fast path.  Chain CAMonOp (depth ≥ 2) is excluded — its
     materialise path (= arena-pooled scratches from Phase 3) is
     structurally different from the X.4 inner-contig fast path.  */
  void *attach = ca_func[src->obj_type].attach;
  if ( src_kind == CA_ITER_SRC_ATTACH ) {
    if ( attach == ca_fake_func.attach
         || attach == ca_byte_swap_func.attach
         || ca_monop_view_is_single_cast(src) ) {
      return fiber_axis_stride == (ca_size_t) src->bytes;
    }
  }

  /* F.6.3: CAShift / CAWindow with OOB-fused materialise path (X.1).
     Per-fiber ca_xfer_stride wins decisively when the view would
     otherwise fall into a per-slab gather / whole-view materialise
     path (= SRC_DESCRIPTOR, e.g. CAShift always, CAWindow with SHIFT
     axes).  But when the view qualifies for the L2 alias fast path
     (SRC_DESCRIPTOR_L2_ALIASABLE, = interior-only CAWindow with F-1
     STRIDE promotion), the existing alias path is already optimal
     (parent.ptr + composed offsets, zero materialise).  Per-fiber
     dispatch in that case adds ca_xfer_stride per-call overhead with
     no payoff -- F.6.3 bench measured 0.35-0.82x (regression).  Gate
     on SRC_DESCRIPTOR only. */
  if ( src_kind == CA_ITER_SRC_DESCRIPTOR ) {
    /* Both CAWindow and CAShift match ca_window_func.attach (Phase G
       typedef pattern: ca_shift_func = ca_window_func). */
    if ( attach == ca_window_func.attach ) {
      return 1;
    }
  }

  /* F.6.4 audit (devel/bench_f6_4_audit.rb): CSA (CASelectAxis) /
     CAGrid / CASelect / CAMapping all kept on the whole-view
     materialise path.  Per-fiber ca_xfer_stride is a LOSER for
     these views (1.25-4.7x slower across all axis positions
     measured) because the descriptor framework's
     ca_axis_dispatch_gather is already a single batched per-axis
     kind gather; splitting into N per-fiber calls loses the
     batched throughput.  Structurally different from
     CAFake/CAByteSwap (transform-fused at byte level, X.4) and
     CAShift/CAWindow OOB (per-region fused with bound check, X.1):
     descriptor framework views do not have a per-region fused fast
     path designed for per-fiber entry.

     Note (rev4): bench split fiber-axis kind shows STRIDE fiber
     1.25x slower vs INDEX fiber 4-5x slower.  STRIDE-fiber case
     is close to parity and could conceivably reach win with finer
     gating (= bypass per-axis kind classification when the outer
     prefix is homogeneous STRIDE).  Not pursued at current 1.25x
     deficit; recorded as a future possible refinement should an
     application motivate it.  See proposal §3.1 SRC_DESCRIPTOR
     (CSA, CAGrid, ...) inline comment.

     F.6.6 audit (devel/bench_f6_6_bit_audit.rb): CABitarray /
     CABitfield kept on current path.  Bench measured via
     bits.fake(:float64) (= production CAFake-wrap hot path) shows
     per-fiber 1.23-5.86x slower on the F.6.2-gate-off axes.

     The CAFake wrap overhead applies equally to both per-fiber and
     whole-view paths (same total cell-cast cost), so the 5x ratio
     is essentially the CABitarray whole-view-vs-per-fiber ratio
     itself.  Phase A bench note "xfer_stride 0.98x parity" is a
     single-call comparison: N per-fiber calls cumulatively cost
     N x parity > 1 x xfer_all (+ N dispatch overhead + per-call
     bit alignment math).  This reasoning generalises to direct
     CABitarray / CABitfield source (= when a non-f64 fiber smoke
     is added in a future phase) -- no separate audit needed for
     that case.  Predicate stays unchanged.

     F.6.7 will audit CAReduce. */
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
  /* Phase A capstone: CA_SLAB_AXES accepted (init_l2 path only — init_l1
     does not implement CA_SLAB_AXES yet, see init_l1's policy gate). */
  if ( policy != CA_SLAB_WHOLE && policy != CA_SLAB_AXES )
    return CA_ITER_ERR_POLICY;

  /* Step 6: accept CA_KERNEL_WRITE and CA_KERNEL_NO_MASK.
     CA_KERNEL_CHUNK_HINT is reserved for T2 — still rejected.
     NO_MASK enforcement (= reject masked source if NO_MASK is set)
     lands in step 7; step 6 accepts the flag but does not enforce.
     CA_KERNEL_FIBER_CONTIG (PROPOSAL_FIBER_DELIVERY F.1a) accepted —
     activates per-fiber contig delivery for naxes==1 in next_slab_axes. */
  const uint32_t accepted = CA_KERNEL_WRITE | CA_KERNEL_NO_MASK
                          | CA_KERNEL_FIBER_CONTIG;
  if ( flags & ~accepted ) return CA_ITER_ERR_FLAGS;

  /* WRITE on a readonly view (CARepeat stride-0 / value_array /
     CAWrap readonly) — explicit reject, would otherwise SEGV on
     write. */
  if ( (flags & CA_KERNEL_WRITE) && ca_is_readonly(src) ) {
    return CA_ITER_ERR_READONLY;
  }

  /* Step 6: mask is default-borne (bakeoff #5).  The step-4
     CA_ITER_ERR_MASK gate is lifted (= masked sources are accepted).
     Step 7: enforce CA_KERNEL_NO_MASK as an explicit kernel-character
     declaration — if a kernel says "I cannot handle mask" and a
     masked source is handed in, reject with a dedicated error code
     so the caller can decide whether to peel via .value /
     .strip_mask(fill) or pick a mask-aware kernel. */
  if ( (flags & CA_KERNEL_NO_MASK) && ca_has_mask(src) ) {
    return CA_ITER_ERR_MASK_NOT_ALLOWED;
  }

  /* Gate: classify source.  sub-step 5.1 routing accepts entity +
     CAStride family (step 1-4) and CSA + CAGrid (step 5.1). Other
     descriptor views (CASelect / CAMapping / CAWindow / CAShift)
     and overlay views (CAFake / ...) still reject — handled in
     5.2 and Phase 2 respectively. */
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

int
ca_iter_state_init_l1 (ca_iter_state    *st,
                       struct _CArray   *src,
                       ca_slab_policy_t  policy,
                       int8_t           *axes,
                       int8_t            naxes,
                       uint32_t          flags)
{
  /* PROPOSAL_CAFACE_PHASE_2 F.2.6 + PROPOSAL_LAZY_MARKER_LIFT Phase 0:
     storage-identical wrapper strip at entry (= same rationale as init_l2
     below).  Strip before validate_inputs.

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

  /* Phase A capstone: CA_SLAB_AXES is L2-only (kernels needing K-D slab
     yield use init_l2).  init_l1 rejects so callers don't get a silent
     misdispatch. */
  if ( policy == CA_SLAB_AXES ) return CA_ITER_ERR_POLICY;

  uint8_t src_kind = ca_iter_classify_source(src);

  memset(st, 0, sizeof(*st));
  st->src      = src;
  st->src_kind = src_kind;
  st->level    = 1;
  st->policy   = policy;
  st->ndim     = src->ndim;
  st->flags    = flags;
  st->bytes    = src->bytes;
  st->axes     = axes;
  st->naxes    = naxes;

  st->slab_n        = src->elements;
  st->total_slabs   = 1;
  st->slabs_emitted = 0;
  st->chunk_size    = st->slab_n;

  if ( src_kind == CA_ITER_SRC_ATTACH ) {
    /* === SRC_ATTACH path (step 9 + 2026-05-31 refactor): CAFake /
           CAByteSwap / CABitfield / CABitarray / CAReduce =================
       View's xfer_all delivers materialised data through the unified
       dispatch surface.  Previously used `ca_attach(src) + src->ptr`
       (= view's attach slot) and `ca_sync(src)` for WRITE; now uses
       `ca_xfer_all(src, scratch, GET/PUT)` with iterator-owned scratch.
       Decouples kernel_iterator from per-view attach/sync lifecycle
       and inherits xfer reform improvements (transform-fused, etc.)
       automatically. */
    st->scratch_cap = (ca_size_t) src->elements * src->bytes;
    st->scratch_ptr = (char *) xmalloc(st->scratch_cap > 0 ? st->scratch_cap : 1);
    if ( src->elements > 0 ) {
      ca_xfer_all(src, st->scratch_ptr, CA_XFER_GET);
    }
    st->alias_mode          = CA_ITER_ALIAS_NONE;     /* scratch-owned, no src.detach */
    st->alias_ptr           = st->scratch_ptr;
    st->composed_strides[0] = src->bytes;
    st->composed_base       = 0;
    st->outer_idx           = NULL;
    /* Step 6: mask gather (xfer_all on mask -- ca_copy_data is a thin
       wrapper, this just removes the extra hop). */
    if ( ca_has_mask(src) ) {
      ca_size_t mcap = src->elements > 0 ? src->elements : 1;
      st->scratch_mask = (boolean8_t *) xmalloc(mcap);
      if ( src->elements > 0 ) {
        ca_xfer_all(src->mask, (char *) st->scratch_mask, CA_XFER_GET);
      }
      st->alias_mask = st->scratch_mask;
    }
    return CA_ITER_OK;
  }

  if ( src_kind == CA_ITER_SRC_DESCRIPTOR ) {
    /* === descriptor path (step 5.1: CSA + CAGrid) ======================
       Reuse P3 substrate: describe_axes → prepare → layout. For now
       always materialise via ca_axis_dispatch_attach into scratch and
       yield one contig slab (alias_mode = NONE). The view-transparency
       principle (proposal §0): kernel sees a flat slab regardless of
       per-axis kind; INDEX / SHIFT mix is handled inside the engine. */
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

    /* Materialise via the engine.  ca_axis_dispatch_attach handles
       parent attach + scratch alloc + gather (INDEX axes included);
       we own the resulting buffer.  Descriptor views inherit from
       CAView so parent is at the CAVIEW prefix slot. */
    CArray *parent = CAVIEW(src)->parent;
    ca_attach(parent);                 /* engine reads parent->ptr */
    st->root = parent;                 /* finish() detaches */
    st->scratch_cap = src->elements * src->bytes;
    /* Engine ndim = descriptor ndim from describe_axes (not view.ndim).
       Critical for CAMapping where view.ndim > 1 but the descriptor is
       1-D INDEX gather.
       bound_fill = CAWindow/CAShift fill value (Tier 2.B SHIFT-axis
       OOB cell), NULL for non-window views (CSA / CAGrid / CASelect /
       CAMapping don't have OOB semantics — engine sees no SHIFT axes). */
    const void *bound_fill = NULL;
    if ( ca_func[src->obj_type].attach == ca_window_func.attach ) {
      bound_fill = ((CAWindow *) src)->fill;
    }
    st->scratch_ptr = ca_axis_dispatch_attach(parent,
                                              st->parent_axis_dims,
                                              raw_descs, raw_ndim,
                                              src->bytes,
                                              st->total_elements,
                                              bound_fill);
    st->alias_mode = CA_ITER_ALIAS_NONE;
    st->alias_ptr  = st->scratch_ptr;

    /* Step 6: gather mask via ca_copy_data on src->mask (works for
       all descriptor views — mask propagates through their
       func_copy_data via the descriptor framework's own mask
       handling). */
    if ( ca_has_mask(src) ) {
      ca_size_t mcap = src->elements > 0 ? src->elements : 1;
      st->scratch_mask = (boolean8_t *) xmalloc(mcap);
      if ( src->elements > 0 ) {
        ca_copy_data(src->mask, (char *) st->scratch_mask);
      }
      st->alias_mask = st->scratch_mask;
    }
    return CA_ITER_OK;
  }

  /* === CAStride path (step 1-4) ============================== */
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
    ca_size_t cap = src->elements * src->bytes;
    st->scratch_cap = cap;
    st->scratch_ptr = xmalloc(cap > 0 ? cap : 1);
    if ( cap > 0 ) {
      ca_copy_data(src, st->scratch_ptr);
    }
    st->alias_mode = CA_ITER_ALIAS_NONE;
    st->alias_ptr  = st->scratch_ptr;
  }

  /* Step 6: gather mask into scratch_mask if source carries one.
     We always gather into a contig boolean8_t buffer for uniformity
     across alias / scratch / descriptor paths — the kernel sees a
     simple `boolean8_t *` aligned with the value slab.  Future
     optimisation: alias mask directly for CAStride contig.  Mask is
     informational; kernel uses CA_FOR_EACH_UNMASKED macros to skip
     masked cells. */
  if ( ca_has_mask(src) ) {
    ca_size_t mcap = src->elements > 0 ? src->elements : 1;
    st->scratch_mask = (boolean8_t *) xmalloc(mcap);
    if ( src->elements > 0 ) {
      ca_copy_data(src->mask, (char *) st->scratch_mask);
    }
    st->alias_mask = st->scratch_mask;
  }
  return CA_ITER_OK;
}

int
ca_iter_state_init_l2 (ca_iter_state    *st,
                       struct _CArray   *src,
                       ca_slab_policy_t  policy,
                       int8_t           *axes,
                       int8_t            naxes,
                       uint32_t          flags)
{
  /* PROPOSAL_CAFACE_PHASE_2 F.2.6 (= MEMO §3.5 kernel_iterator entry strip)
     + PROPOSAL_LAZY_MARKER_LIFT Phase 0.

     A Face only layers a semantic identifier and a CALazyMarker only layers
     "leaf of a lazy chain"; storage is identical to the parent either way, so
     strip at the kernel-compute entry and descend.  Routing and alias
     decisions belong to the parent.  Strip before validate_inputs —
     classify_source rejects both as knows-no.

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

  int rc = ca_iter_validate_inputs(st, src, policy, flags);
  if ( rc != CA_ITER_OK ) return rc;

  /* F-2 (rev6): route_source returns the refined src_kind and (for
     descriptor sources) populates raw_descs / raw_pdims / raw_ndim so we
     don't re-call describe_axes when SRC_DESCRIPTOR_L2_ALIASABLE upgrades
     into the alias branch.  Non-descriptor sources leave the out_*
     buffers untouched. */
  ca_axis_desc_t raw_descs[CA_RANK_MAX];
  ca_size_t      raw_pdims[CA_RANK_MAX];
  int8_t         raw_ndim = 0;
  uint8_t src_kind = ca_iter_route_source(src, raw_descs, raw_pdims, &raw_ndim);

  /* Phase B capstone (T2): CA_SLAB_AXES + descriptor view (= SRC_DESCRIPTOR
     and SRC_DESCRIPTOR_L2_ALIASABLE), accept when slab axes are all-STRIDE
     kind and no outer SHIFT.  Other combinations:
       - slab has INDEX/SHIFT kind → reject (Phase C T3 scope)
       - outer has SHIFT axis      → reject (B.1.5 materialise downgrade scope)
       - SRC_ATTACH                → reject (overlay views; no kind structure)
     SRC_CASTRIDE still goes through the Phase A branch below. */
  if ( policy == CA_SLAB_AXES ) {
    if ( src_kind == CA_ITER_SRC_DESCRIPTOR
         || src_kind == CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE ) {
      /* Validate axes early (range / duplicate). */
      if ( axes == NULL || naxes <= 0 || naxes > src->ndim ) {
        return CA_ITER_ERR_POLICY;
      }
      int8_t in_slab[CA_RANK_MAX];
      int8_t k;
      for ( k = 0; k < CA_RANK_MAX; k++ ) in_slab[k] = 0;
      for ( k = 0; k < naxes; k++ ) {
        int8_t ax = axes[k];
        if ( ax < 0 || ax >= src->ndim ) return CA_ITER_ERR_POLICY;
        if ( in_slab[ax] )               return CA_ITER_ERR_POLICY;
        in_slab[ax] = 1;
      }

      /* PROPOSAL_FIBER_PER_SOURCE_PATH F.6.3 hook (= parallel to
         F.6.2 SRC_ATTACH hook): for descriptor views CAWindow /
         CAShift (predicate returns 1 unconditionally per F.5 always-
         win bench), skip materialise (alias / C.1 PER_SLAB / B.1.5)
         and use per-fiber ca_xfer_stride which routes to the view's
         X.1 OOB-fused per-region fast path. */
      if ( (flags & CA_KERNEL_FIBER_CONTIG) && naxes == 1
           && raw_ndim == src->ndim ) {
        int8_t    fiber_ax = axes[0];
        ca_size_t row_byte_strides[CA_RANK_MAX];
        {
          ca_size_t b = src->bytes;
          for ( int8_t kk = src->ndim - 1; kk >= 0; kk-- ) {
            row_byte_strides[kk] = b;
            b *= src->dim[kk];
          }
        }
        if ( ca_iter_should_per_fiber_fused(src, src_kind, fiber_ax,
                                            row_byte_strides[fiber_ax],
                                            flags) ) {
          memset(st, 0, sizeof(*st));
          st->src      = src;
          st->src_kind = src_kind;
          st->level    = 2;
          st->policy   = policy;
          st->ndim     = src->ndim;
          st->flags    = flags;
          st->bytes    = src->bytes;
          st->axes     = axes;
          st->naxes    = naxes;

          st->alias_mode = CA_ITER_ALIAS_PER_FIBER_FUSED;
          st->alias_ptr  = NULL;
          st->fiber_axis = fiber_ax;
          for ( int8_t kk = 0; kk < src->ndim; kk++ ) {
            st->fiber_native_strides[kk] = row_byte_strides[kk];
          }

          /* Row-major element strides for mask (= identity element
             index strides over src->dim). */
          ca_size_t row_elem_strides[CA_RANK_MAX];
          {
            ca_size_t e = 1;
            for ( int8_t kk = src->ndim - 1; kk >= 0; kk-- ) {
              row_elem_strides[kk] = e;
              e *= src->dim[kk];
            }
          }

          int8_t sp = 0, op = 0;
          st->slab_elements = 1;
          for ( int8_t kk = 0; kk < src->ndim; kk++ ) {
            if ( in_slab[kk] ) {
              st->slab_axes_buf[sp]     = kk;
              st->slab_dims[sp]         = src->dim[kk];
              st->slab_strides[sp]      = row_byte_strides[kk];
              st->slab_mask_strides[sp] = row_elem_strides[kk];
              st->slab_elements        *= src->dim[kk];
              sp++;
            } else {
              st->outer_axes[op]         = kk;
              st->outer_dims[op]         = src->dim[kk];
              st->outer_strides[op]      = row_byte_strides[kk];
              st->outer_mask_strides[op] = row_elem_strides[kk];
              op++;
            }
          }
          st->slab_ndim  = sp;
          st->outer_ndim = op;
          st->desc_ndim  = 0;

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

          /* Mask: per-fiber gather via next_slab_axes; no whole-view
             materialise (rev2 §3.3, (data,mask) pair travels together). */
          st->alias_mask = NULL;
          return CA_ITER_OK;
        }
      }

      /* Phase C T3 (C.1): slab axis has INDEX or SHIFT kind → per-slab
         materialise fallback path (D1.1 (B) + D1.2 (A)).  CAMapping-style
         views (raw_ndim != src->ndim) are out of C.1 scope — descriptor
         exposes a flat 1-D INDEX gather that doesn't expose the view-
         axis partition the user gave via slab_axes.  Reject explicitly. */
      if ( raw_ndim != src->ndim ) {
        return CA_ITER_ERR_POLICY;
      }
      int slab_has_non_stride = 0;
      for ( k = 0; k < src->ndim; k++ ) {
        if ( in_slab[k] && raw_descs[k].kind != CA_AXIS_KIND_STRIDE ) {
          slab_has_non_stride = 1;
          break;
        }
      }
      if ( slab_has_non_stride ) {
        /* C.1 scope: READ-only.  WRITE = future sub-step (C.1c). */
        if ( flags & CA_KERNEL_WRITE ) {
          return CA_ITER_ERR_FLAGS;
        }

        memset(st, 0, sizeof(*st));
        st->src      = src;
        st->src_kind = CA_ITER_SRC_DESCRIPTOR;
        st->level    = 2;
        st->policy   = policy;
        st->ndim     = src->ndim;
        st->flags    = flags;
        st->bytes    = src->bytes;
        st->axes     = axes;
        st->naxes    = naxes;

        CArray *parent = CAVIEW(src)->parent;
        ca_attach(parent);
        st->root = parent;

        /* Persist raw_descs / pdims / pstrides for per-slab subset
           construction (PER_SLAB fallback) or for the hoisted manual
           gather (PER_SLAB_HOIST specialised path).  desc_ndim =
           src->ndim so has_descs branch in next_slab_axes can read
           st->descs (though T3 path takes its own branch before that
           check). */
        memcpy(st->descs, raw_descs, src->ndim * sizeof(ca_axis_desc_t));
        memcpy(st->parent_axis_dims, raw_pdims, src->ndim * sizeof(ca_size_t));
        {
          ca_size_t s = src->bytes;
          for ( k = src->ndim - 1; k >= 0; k-- ) {
            st->pstrides[k] = s;
            s *= raw_pdims[k];
          }
        }
        st->desc_ndim = src->ndim;

        /* View-row-major element strides (= mask scratch layout, since
           mask is gathered whole-view once at init). */
        ca_size_t row_elem_strides[CA_RANK_MAX];
        {
          ca_size_t e = 1;
          for ( k = src->ndim - 1; k >= 0; k-- ) {
            row_elem_strides[k] = e;
            e *= src->dim[k];
          }
        }

        /* Row-major byte strides over SLAB axes only (= scratch_ptr
           layout, since scratch_ptr is sized slab_elements × bytes
           and refilled per outer iter as a contig row-major slab). */
        ca_size_t slab_data_strides[CA_RANK_MAX];
        {
          ca_size_t b = src->bytes;
          ca_size_t e_slab = 1;
          for ( k = src->ndim - 1; k >= 0; k-- ) {
            if ( in_slab[k] ) {
              slab_data_strides[k] = b;
              b      *= raw_descs[k].count;
              e_slab *= raw_descs[k].count;
            } else {
              slab_data_strides[k] = 0;  /* unused for outer axes */
            }
          }
          st->slab_elements = e_slab;
        }

        int8_t sp = 0, op = 0;
        for ( k = 0; k < src->ndim; k++ ) {
          if ( in_slab[k] ) {
            st->slab_axes_buf[sp]      = k;
            st->slab_dims[sp]          = raw_descs[k].count;
            st->slab_strides[sp]       = slab_data_strides[k];
            /* Slab mask stride is view-row-major elem stride along
               this view axis (mask scratch is whole-view layout). */
            st->slab_mask_strides[sp]  = row_elem_strides[k];
            sp++;
          } else {
            st->outer_axes[op]         = k;
            st->outer_dims[op]         = raw_descs[k].count;
            /* T3 path: outer data offset is always 0 (scratch refilled
               per slab, ptr = scratch_ptr). */
            st->outer_strides[op]      = 0;
            /* Outer mask offset uses view-row-major elem stride into
               whole-view mask scratch. */
            st->outer_mask_strides[op] = row_elem_strides[k];
            op++;
          }
        }
        st->slab_ndim     = sp;
        st->outer_ndim    = op;
        st->composed_base = 0;  /* unused for T3 fallback */

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

        /* Alloc per-slab data scratch (D1.1 (B): one max-slab buffer
           refilled per outer iter, instead of per-iter alloc/free or
           full-view materialise). */
        ca_size_t slab_bytes = st->slab_elements * src->bytes;
        st->scratch_cap = slab_bytes > 0 ? slab_bytes : 1;
        st->scratch_ptr = (char *) xmalloc(st->scratch_cap);
        st->alias_ptr   = st->scratch_ptr;  /* refilled per slab in next_slab_axes */

        /* Specialisation (B-1b, C.1b): if innermost slab axis is STRIDE
           and no SHIFT axes anywhere in the view, use the hoisted
           manual gather path (= outer + non-innermost-slab hoist,
           inner pure STRIDE linear memcpy).  Else (innermost INDEX /
           SHIFT-anywhere): use the engine fallback (A). */
        int specialised_eligible = (sp > 0);
        if ( specialised_eligible ) {
          int8_t inner_view_ax = st->slab_axes_buf[sp - 1];
          if ( raw_descs[inner_view_ax].kind != CA_AXIS_KIND_STRIDE ) {
            specialised_eligible = 0;
          }
        }
        if ( specialised_eligible ) {
          /* Any SHIFT axis (slab or outer) → fallback to engine for
             clean bound_fill semantics in C.1b scope. */
          for ( k = 0; k < src->ndim; k++ ) {
            if ( raw_descs[k].kind == CA_AXIS_KIND_SHIFT ) {
              specialised_eligible = 0;
              break;
            }
          }
        }
        st->alias_mode = specialised_eligible
                       ? CA_ITER_ALIAS_PER_SLAB_HOIST
                       : CA_ITER_ALIAS_PER_SLAB;

        /* Mask: gather whole view mask once into scratch_mask (= same
           strategy as B.1.5).  Per-slab mask offset is computed via
           outer_idx × outer_mask_strides in next_slab_axes. */
        if ( ca_has_mask(src) ) {
          ca_size_t mcap = src->elements > 0 ? src->elements : 1;
          st->scratch_mask = (boolean8_t *) xmalloc(mcap);
          if ( src->elements > 0 ) {
            ca_copy_data(src->mask, (char *) st->scratch_mask);
          }
          st->alias_mask = st->scratch_mask;
        }

        return CA_ITER_OK;
      }
      /* slab is all-STRIDE: fall through to B.1.5 / Phase B paths. */
      /* Phase B.1.5: outer SHIFT axis → materialise downgrade.  Alias
         can't deliver OOB cells (= need fill_value), and the view-family
         surface prioritises delivering the cells over avoiding a copy, so
         we materialise the entire view into a row-major scratch
         buffer via ca_axis_dispatch_attach (= same engine as the
         existing SRC_DESCRIPTOR L2 NONE path), then walk it with
         Phase A-style row-major K-D strides.  Slab / outer partition
         applies to view-axes; the scratch IS the flat row-major view. */
      int outer_has_shift = 0;
      for ( k = 0; k < src->ndim; k++ ) {
        if ( !in_slab[k] && raw_descs[k].kind == CA_AXIS_KIND_SHIFT ) {
          outer_has_shift = 1;
          break;
        }
      }

      if ( outer_has_shift ) {
        memset(st, 0, sizeof(*st));
        st->src      = src;
        st->src_kind = CA_ITER_SRC_DESCRIPTOR;
        st->level    = 2;
        st->policy   = policy;
        st->ndim     = src->ndim;
        st->flags    = flags;
        st->bytes    = src->bytes;
        st->axes     = axes;
        st->naxes    = naxes;

        CArray *parent = CAVIEW(src)->parent;
        ca_attach(parent);
        st->root = parent;

        ca_axis_desc_t local_descs[CA_RANK_MAX];
        memcpy(local_descs, raw_descs, src->ndim * sizeof(ca_axis_desc_t));
        const void *bound_fill = NULL;
        if ( ca_func[src->obj_type].attach == ca_window_func.attach ) {
          bound_fill = ((CAWindow *) src)->fill;
        }
        st->scratch_cap = src->elements * src->bytes;
        st->scratch_ptr = ca_axis_dispatch_attach(parent, raw_pdims,
                                                  local_descs, src->ndim,
                                                  src->bytes, src->elements,
                                                  bound_fill);
        st->alias_mode = CA_ITER_ALIAS_NONE;
        st->alias_ptr  = st->scratch_ptr;

        /* Row-major byte / element strides on the scratch (= view layout). */
        ca_size_t row_byte_strides[CA_RANK_MAX];
        ca_size_t row_elem_strides[CA_RANK_MAX];
        {
          ca_size_t b = src->bytes, e = 1;
          for ( k = src->ndim - 1; k >= 0; k-- ) {
            row_byte_strides[k] = b;
            row_elem_strides[k] = e;
            b *= src->dim[k];
            e *= src->dim[k];
          }
        }

        int8_t sp = 0, op = 0;
        st->slab_elements = 1;
        for ( k = 0; k < src->ndim; k++ ) {
          if ( in_slab[k] ) {
            st->slab_axes_buf[sp]      = k;
            st->slab_dims[sp]          = src->dim[k];
            st->slab_strides[sp]       = row_byte_strides[k];
            st->slab_mask_strides[sp]  = row_elem_strides[k];
            st->slab_elements         *= src->dim[k];
            sp++;
          } else {
            st->outer_axes[op]         = k;
            st->outer_dims[op]         = src->dim[k];
            st->outer_strides[op]      = row_byte_strides[k];
            st->outer_mask_strides[op] = row_elem_strides[k];
            op++;
          }
        }
        st->slab_ndim     = sp;
        st->outer_ndim    = op;
        st->composed_base = 0;
        /* desc_ndim = 0: next_slab_axes treats outer like Phase A
           (no INDEX lookup), correct because scratch is row-major
           contig (= STRIDE everywhere). */
        st->desc_ndim = 0;

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

        if ( ca_has_mask(src) ) {
          ca_size_t mcap = src->elements > 0 ? src->elements : 1;
          st->scratch_mask = (boolean8_t *) xmalloc(mcap);
          if ( src->elements > 0 ) {
            ca_copy_data(src->mask, (char *) st->scratch_mask);
          }
          st->alias_mask = st->scratch_mask;
        }
        return CA_ITER_OK;
      }

      memset(st, 0, sizeof(*st));
      st->src      = src;
      st->src_kind = CA_ITER_SRC_DESCRIPTOR;  /* Phase B alias path */
      st->level    = 2;
      st->policy   = policy;
      st->ndim     = src->ndim;
      st->flags    = flags;
      st->bytes    = src->bytes;
      st->axes     = axes;
      st->naxes    = naxes;

      /* Parent row-major byte strides for offset computation. */
      ca_size_t pstrides[CA_RANK_MAX];
      {
        ca_size_t s = src->bytes;
        for ( k = src->ndim - 1; k >= 0; k-- ) {
          pstrides[k] = s;
          s *= raw_pdims[k];
        }
      }
      /* View row-major element strides (= mask scratch layout). */
      ca_size_t row_elem_strides[CA_RANK_MAX];
      {
        ca_size_t s = 1;
        for ( k = src->ndim - 1; k >= 0; k-- ) {
          row_elem_strides[k] = s;
          s *= src->dim[k];
        }
      }

      /* Partition + populate slab / outer metadata.  Slab axes contribute
         to a constant slab_base (since they're all STRIDE: start +
         step*idx, where the base is start*pstride summed).  Outer axes
         drive per-slab offset via direct (start + step*idx)*pstride or
         indices[idx]*pstride (= no classify_prefix engine, since outer
         axes here are not a prefix of raw_descs[] — they're a
         complement of slab_axes). */
      int8_t    sp = 0, op = 0;
      ca_size_t slab_base = 0;
      st->slab_elements = 1;
      for ( k = 0; k < src->ndim; k++ ) {
        if ( in_slab[k] ) {
          /* STRIDE-kind slab axis: start*pstride goes to slab_base,
             step*pstride is the per-cell byte stride. */
          slab_base += raw_descs[k].start * pstrides[k];
          st->slab_axes_buf[sp]     = k;
          st->slab_dims[sp]         = raw_descs[k].count;
          st->slab_strides[sp]      = raw_descs[k].step * pstrides[k];
          st->slab_mask_strides[sp] = row_elem_strides[k];
          st->slab_elements        *= raw_descs[k].count;
          sp++;
        } else {
          /* Outer axis: STRIDE or INDEX (SHIFT was rejected above).
             Store axis index + view's outer dim/stride for descriptor
             walk in next_slab_axes.  We reuse outer_strides/outer_mask
             _strides as the OUTER walk metadata; outer-axis kind is
             carried implicitly via raw_descs[outer_axes[m]] in the
             state struct's descs[] field (populated below). */
          st->outer_axes[op]         = k;
          st->outer_dims[op]         = raw_descs[k].count;
          /* For STRIDE: per-axis stride = step * pstride; INDEX axes
             use indices[] from raw_descs and need a 0 stride here
             (next_slab_axes branches on descs[].kind to compute the
             real offset).  We persist the full raw_descs in st->descs
             so the next_slab_axes implementation can dispatch. */
          if ( raw_descs[k].kind == CA_AXIS_KIND_STRIDE ) {
            st->outer_strides[op] = raw_descs[k].step * pstrides[k];
            /* Bake in start*pstride into slab_base for STRIDE outer too
               so per-cell offset is purely step*idx. */
            slab_base += raw_descs[k].start * pstrides[k];
          } else {
            /* INDEX kind: outer_strides[m] = pstrides[k] (element-unit
               from indices[]).  We DON'T pre-bake into slab_base for
               INDEX axes; per-iter offset = indices[idx[m]] * pstrides[k]
               is computed in next_slab_axes. */
            st->outer_strides[op] = pstrides[k];
          }
          st->outer_mask_strides[op] = row_elem_strides[k];
          op++;
        }
      }
      st->slab_ndim     = sp;
      st->outer_ndim    = op;
      st->composed_base = slab_base;

      /* Persist raw_descs / pstrides in state so next_slab_axes can
         distinguish STRIDE vs INDEX outer per axis. */
      memcpy(st->descs, raw_descs, src->ndim * sizeof(ca_axis_desc_t));
      memcpy(st->parent_axis_dims, raw_pdims, src->ndim * sizeof(ca_size_t));
      memcpy(st->pstrides, pstrides, src->ndim * sizeof(ca_size_t));
      st->desc_ndim = src->ndim;

      ca_size_t total = 1;
      for ( int8_t m = 0; m < st->outer_ndim; m++ ) total *= st->outer_dims[m];
      st->total_slabs   = total;
      st->slab_n        = st->slab_elements;
      st->slabs_emitted = 0;
      st->chunk_size    = st->slab_n;

      if ( st->outer_ndim > 0 ) {
        st->outer_idx = ALLOC_N(ca_size_t, st->outer_ndim);
        for ( int8_t m = 0; m < st->outer_ndim; m++ ) st->outer_idx[m] = 0;
      } else {
        st->outer_idx = NULL;
      }

      /* Attach parent for alias path. */
      CArray *parent = CAVIEW(src)->parent;
      ca_attach(parent);
      st->root       = parent;
      st->alias_mode = CA_ITER_ALIAS_STRIDED;
      st->alias_ptr  = (char *) parent->ptr;

      /* Mask gather (= view row-major boolean8_t). */
      if ( ca_has_mask(src) ) {
        ca_size_t mcap = src->elements > 0 ? src->elements : 1;
        st->scratch_mask = (boolean8_t *) xmalloc(mcap);
        if ( src->elements > 0 ) {
          ca_copy_data(src->mask, (char *) st->scratch_mask);
        }
        st->alias_mask = st->scratch_mask;
      }
      return CA_ITER_OK;
    }
    if ( src_kind == CA_ITER_SRC_ATTACH ) {
      /* Phase B.5: CA_SLAB_AXES + SRC_ATTACH (= CAFake / CAByteSwap /
         CABitfield / CABitarray / CAReduce).  These overlay views
         materialise via their own ca_attach (= no descriptor framework
         path), so we let ca_attach(src) populate src->ptr in view
         row-major layout and walk it with Phase A-style K-D strides.

         The most common entry path here is wrap_readonly(int_src,
         CA_FLOAT64) → CAFake, enabling sum_ki etc. to accept any
         numeric data_type source via auto-cast (= D2.2 confirmed in
         rev2 sparring). */
      if ( axes == NULL || naxes <= 0 || naxes > src->ndim ) {
        return CA_ITER_ERR_POLICY;
      }
      int8_t in_slab[CA_RANK_MAX];
      int8_t k;
      for ( k = 0; k < CA_RANK_MAX; k++ ) in_slab[k] = 0;
      for ( k = 0; k < naxes; k++ ) {
        int8_t ax = axes[k];
        if ( ax < 0 || ax >= src->ndim ) return CA_ITER_ERR_POLICY;
        if ( in_slab[ax] )               return CA_ITER_ERR_POLICY;
        in_slab[ax] = 1;
      }

      memset(st, 0, sizeof(*st));
      st->src      = src;
      st->src_kind = CA_ITER_SRC_ATTACH;
      st->level    = 2;
      st->policy   = policy;
      st->ndim     = src->ndim;
      st->flags    = flags;
      st->bytes    = src->bytes;
      st->axes     = axes;
      st->naxes    = naxes;

      /* Row-major byte / element strides on the attached view buffer.
         Computed first so the F.6.1 predicate can inspect fiber-axis
         effective stride before deciding whether to materialise. */
      ca_size_t row_byte_strides[CA_RANK_MAX];
      ca_size_t row_elem_strides[CA_RANK_MAX];
      {
        ca_size_t b = src->bytes, e = 1;
        for ( k = src->ndim - 1; k >= 0; k-- ) {
          row_byte_strides[k] = b;
          row_elem_strides[k] = e;
          b *= src->dim[k];
          e *= src->dim[k];
        }
      }

      /* PROPOSAL_CASTACK_LOOP_INTERCHANGE Vector A rev4 (direct per-
         parent ptr access path + tile cache).  Engages when:
           - source.attach is ca_stack_func.attach (= CAStack identity)
           - no mask (= horizontal mask propagation per-slab gather is
             out of scope; falls back to SRC_ATTACH whole-view path)
           - naxes == 1 && axes[0] == k_axis (= K-axis-only slab, the
             demand-driving case = reduce along the stacked axis like
             view.mean(axis: k_axis))
         init attaches K parents up front (O(1) per entity parent),
         caches parent->ptr aliases + uniform parent-native byte strides,
         allocates a slab-sized scratch (= K * bytes) plus a tile cache
         sized to fit the L1d budget.  next_slab_axes refills TILE fibers
         per K contig parent reads (rev4 2026-06-19) and serves the next
         TILE-1 calls from the L1d-resident cache, beating SRC_ATTACH
         across all measured sizes.  No size-threshold gate: rev3's gate
         was a perf trade-off justification that the tile cache erased.

         K.3 (PROPOSAL_CASTACK_K_AXIS, 2026-06-20): engage predicate
         generalised from `axes[0] == 0` to `axes[0] == k_axis`.  The
         tile cache mechanism + outer_idx -> parent axis mapping are
         already k_axis-agnostic: outer_idx[m] maps to parent axis m
         regardless of k_axis position (= for k_axis = 0 outer is stack
         axes 1..N-1 = parent axes 0..N-2; for k_axis > 0 outer is stack
         axes [0..k_axis-1, k_axis+1..N-1] = parent axes [0..k_axis-1,
         k_axis..N-2]; either way outer_idx[m] = parent axis m). */
      if ( ca_func[src->obj_type].attach == ca_stack_func.attach
           && !ca_has_mask(src)
           && naxes == 1 && axes[0] == ((CAStack *) src)->k_axis ) {
        CAStack *stack = (CAStack *) src;
        int8_t   parent_ndim = src->ndim - 1;
        int8_t   sp = 0, op = 0;

        st->slab_elements = 1;
        for ( k = 0; k < src->ndim; k++ ) {
          if ( in_slab[k] ) {
            st->slab_axes_buf[sp]      = k;
            st->slab_dims[sp]          = src->dim[k];
            st->slab_elements         *= src->dim[k];
            sp++;
          } else {
            st->outer_axes[op]         = k;
            st->outer_dims[op]         = src->dim[k];
            st->outer_strides[op]      = row_byte_strides[k];     /* unused on STACK path */
            st->outer_mask_strides[op] = row_elem_strides[k];     /* unused on STACK path */
            op++;
          }
        }
        st->slab_ndim     = sp;
        st->outer_ndim    = op;
        st->composed_base = 0;
        st->desc_ndim     = 0;
        /* slab_strides on STACK path: slab_axes == [0], scratch is
           packed contig over K elements (= K * bytes), so single-axis
           slab walk uses bytes stride. */
        st->slab_strides[0]      = src->bytes;
        st->slab_mask_strides[0] = 1;   /* harmless on no-mask path */

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

        /* Attach K parents and cache their ptr aliases.  CAStack
           guarantees uniform shape (MEMO §3.2) so one set of parent
           native byte strides covers all K (= parents[0]->dim is
           canonical). */
        st->stack_n_parents = stack->n_parents;
        st->stack_parent_ptrs =
            (char **) xmalloc(stack->n_parents * sizeof(char *));
        for ( int32_t kk = 0; kk < stack->n_parents; kk++ ) {
          ca_attach(stack->parents[kk]);
          st->stack_parent_ptrs[kk] = (char *) stack->parents[kk]->ptr;
        }
        {
          ca_size_t s = src->bytes;
          for ( int8_t kk = parent_ndim - 1; kk >= 0; kk-- ) {
            st->stack_parent_strides[kk] = s;
            s *= stack->parents[0]->dim[kk];
          }
        }

        /* Slab-sized scratch (= K * bytes for slab_axes == [0]). */
        st->scratch_cap = (ca_size_t) st->slab_elements * src->bytes;
        st->scratch_ptr = (char *) xmalloc(st->scratch_cap > 0 ? st->scratch_cap : 1);

        /* Tile cache (pilot/castack-axis0-loop-interchange): refill TILE
           fibers per K parent reads, serve next TILE-1 fibers from L1d.
           TILE budget = ~32 KB (half of M2 L1d).  Empirically tested
           values; clamped to [8, 64] to keep the refill loop tight. */
        {
          ca_size_t K = (ca_size_t) stack->n_parents;
          ca_size_t bytes = (ca_size_t) src->bytes;
          ca_size_t tile = K > 0 ? (32 * 1024) / (K * bytes) : 0;
          if ( tile < 8 )  tile = 8;
          if ( tile > 64 ) tile = 64;
          st->stack_tile_cap   = tile;
          st->stack_tile_pos   = 0;
          st->stack_tile_have  = 0;     /* force refill on first call */
          st->stack_tile_cache = (char *) xmalloc(K * tile * bytes);
        }

        st->alias_mode  = CA_ITER_ALIAS_STACK;
        st->alias_ptr   = NULL;   /* no whole-view buffer */
        st->alias_mask  = NULL;
        return CA_ITER_OK;
      }

      /* PROPOSAL_CASTACK_XFER_OPT_LAYERING P.2 Case A (2026-06-18):
         CAStack source + slab_axes excludes axis 0 (= K-axis stays in
         outer iter, e.g. view.mean(axis: 1), view.mean(axis: 2),
         view.mean(axis: 1, 2)).  Each slab corresponds to a region
         inside ONE parent selected by outer_idx[K_outer_pos].  Engine
         pre-attaches K parents (+ K parent masks if mask present),
         caches their ptrs, and next_slab_axes aliases parents[k]->ptr +
         parent_off directly -- no scratch, no materialise, parent
         entity case = eager-equivalent memory bandwidth.

         Layering: engine detects CAStack identity by function-pointer
         comparison and accesses parents[] / mask via ca_func[STACK]
         operation table where possible.  CAStack downcast occurs only
         for the n_parents / parents[] read in init_l2 (= same scope as
         rev3 STACK; AC3 forbids parents[] walk in next_slab_axes only).
         Q1 disposition: option (i) minimal-diff inline in SLAB_AXES
         branch -- evaluated as smallest diff with acceptable layering
         (proposal §3.1). */
      /* STACK_OUTER_K: K-axis stays in outer iter (slab carved out of
         one parent at a time).  K.3 (2026-06-20): engage predicate +
         stack-axis -> parent-axis mapping generalised for arbitrary
         k_axis.  stack axis s maps to parent axis (s if s < k_axis else
         s - 1); only the K stack axis (s == k_axis) has no parent
         counterpart. */
      if ( ca_func[src->obj_type].attach == ca_stack_func.attach
           && naxes >= 1 && !in_slab[((CAStack *) src)->k_axis] ) {
        CAStack *stack = (CAStack *) src;
        int8_t   k_axis = stack->k_axis;
        int8_t   parent_ndim = src->ndim - 1;
        int8_t   sp = 0, op = 0;

        st->slab_elements = 1;
        for ( k = 0; k < src->ndim; k++ ) {
          if ( in_slab[k] ) {
            st->slab_axes_buf[sp]      = k;
            st->slab_dims[sp]          = src->dim[k];
            st->slab_elements         *= src->dim[k];
            /* slab_strides[sp] = parent native byte stride at parent
               axis (k if k < k_axis else k - 1).  k == k_axis cannot
               appear here -- the engage predicate above excludes it. */
            sp++;
          } else {
            st->outer_axes[op]         = k;
            st->outer_dims[op]         = src->dim[k];
            st->outer_strides[op]      = row_byte_strides[k];
            st->outer_mask_strides[op] = row_elem_strides[k];
            op++;
          }
        }
        st->slab_ndim     = sp;
        st->outer_ndim    = op;
        st->composed_base = 0;
        st->desc_ndim     = 0;

        /* Locate the K-axis (= stack axis k_axis) within outer_axes. */
        st->stack_k_outer_pos = -1;
        for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
          if ( st->outer_axes[m] == k_axis ) {
            st->stack_k_outer_pos = m;
            break;
          }
        }

        /* Uniform parent native byte strides + parent element strides
           for mask (= MEMO §3.2 uniform shape across parents,
           parents[0]->dim is canonical).  Mask strides cached so
           next_slab_axes can compute mask_off without downcasting
           (= AC3 layering goal). */
        {
          ca_size_t sb = src->bytes;
          ca_size_t se = 1;
          for ( int8_t kk = parent_ndim - 1; kk >= 0; kk-- ) {
            st->stack_parent_strides[kk]      = sb;
            st->stack_parent_mask_strides[kk] = se;
            sb *= stack->parents[0]->dim[kk];
            se *= stack->parents[0]->dim[kk];
          }
        }

        /* Fill slab_strides + slab_mask_strides for slab axes (all of
           which are parent inner axes since K is in outer).  stack ax
           -> parent ax: s if s < k_axis else s - 1. */
        for ( int8_t s_i = 0; s_i < st->slab_ndim; s_i++ ) {
          int8_t  stack_ax  = st->slab_axes_buf[s_i];
          int8_t  parent_ax = (stack_ax < k_axis) ? stack_ax : (stack_ax - 1);
          st->slab_strides[s_i]      = st->stack_parent_strides[parent_ax];
          st->slab_mask_strides[s_i] = st->stack_parent_mask_strides[parent_ax];
        }

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

        /* Attach K parents + cache ptr aliases.  Symmetric with rev3
           Case B; for entity parents attach is O(1). */
        st->stack_n_parents = stack->n_parents;
        st->stack_parent_ptrs =
            (char **) xmalloc(stack->n_parents * sizeof(char *));
        for ( int32_t kk = 0; kk < stack->n_parents; kk++ ) {
          ca_attach(stack->parents[kk]);
          st->stack_parent_ptrs[kk] = (char *) stack->parents[kk]->ptr;
        }

        /* If CAStack carries mask (= horizontal propagation already
           applied at create_mask), attach K parent masks + cache ptr
           aliases.  next_slab_axes aliases parent->mask[k]->ptr +
           mask_off for the same slab. */
        if ( ca_has_mask(src) ) {
          st->stack_parent_mask_ptrs =
              (boolean8_t **) xmalloc(stack->n_parents * sizeof(boolean8_t *));
          for ( int32_t kk = 0; kk < stack->n_parents; kk++ ) {
            ca_attach(stack->parents[kk]->mask);
            st->stack_parent_mask_ptrs[kk] =
                (boolean8_t *) stack->parents[kk]->mask->ptr;
          }
        } else {
          st->stack_parent_mask_ptrs = NULL;
        }

        st->scratch_ptr = NULL;   /* no scratch: aliasing parent->ptr */
        st->scratch_cap = 0;
        st->alias_mode  = CA_ITER_ALIAS_STACK_OUTER_K;
        st->alias_ptr   = NULL;
        st->alias_mask  = NULL;
        return CA_ITER_OK;
      }

      /* PROPOSAL_FIBER_PER_SOURCE_PATH F.6.1 hook: try per-fiber fused
         dispatch before whole-view materialise.  When predicate fires,
         skip scratch alloc + xfer_all GET (= per-fiber ca_xfer_stride
         is called on demand in next_slab_axes).  Predicate is stubbed
         in F.6.1 (returns 0); F.6.2+ enables specific source kinds. */
      int per_fiber_fused = 0;
      if ( (flags & CA_KERNEL_FIBER_CONTIG) && naxes == 1 ) {
        int8_t    fiber_ax        = axes[0];
        ca_size_t fiber_ax_stride = row_byte_strides[fiber_ax];
        if ( ca_iter_should_per_fiber_fused(src, src_kind, fiber_ax,
                                            fiber_ax_stride, flags) ) {
          per_fiber_fused = 1;
          st->alias_mode = CA_ITER_ALIAS_PER_FIBER_FUSED;
          st->alias_ptr  = NULL;      /* no whole-view buffer */
          st->fiber_axis = fiber_ax;
          for ( int8_t kk = 0; kk < src->ndim; kk++ ) {
            st->fiber_native_strides[kk] = row_byte_strides[kk];
          }
        }
      }

      if ( !per_fiber_fused ) {
        /* 2026-05-31 refactor: iter-owns scratch via ca_xfer_all (was
           ca_attach(src) + alias src->ptr). */
        st->scratch_cap = (ca_size_t) src->elements * src->bytes;
        st->scratch_ptr = (char *) xmalloc(st->scratch_cap > 0 ? st->scratch_cap : 1);
        if ( src->elements > 0 ) {
          ca_xfer_all(src, st->scratch_ptr, CA_XFER_GET);
        }
        st->alias_mode = CA_ITER_ALIAS_NONE;
        st->alias_ptr  = st->scratch_ptr;
      }

      int8_t sp = 0, op = 0;
      st->slab_elements = 1;
      for ( k = 0; k < src->ndim; k++ ) {
        if ( in_slab[k] ) {
          st->slab_axes_buf[sp]      = k;
          st->slab_dims[sp]          = src->dim[k];
          st->slab_strides[sp]       = row_byte_strides[k];
          st->slab_mask_strides[sp]  = row_elem_strides[k];
          st->slab_elements         *= src->dim[k];
          sp++;
        } else {
          st->outer_axes[op]         = k;
          st->outer_dims[op]         = src->dim[k];
          st->outer_strides[op]      = row_byte_strides[k];
          st->outer_mask_strides[op] = row_elem_strides[k];
          op++;
        }
      }
      st->slab_ndim     = sp;
      st->outer_ndim    = op;
      st->composed_base = 0;
      st->desc_ndim     = 0;  /* row-major STRIDE everywhere */

      ca_size_t total = 1;
      for ( int8_t m = 0; m < st->outer_ndim; m++ ) total *= st->outer_dims[m];
      st->total_slabs   = total;
      st->slab_n        = st->slab_elements;
      st->slabs_emitted = 0;
      st->chunk_size    = st->slab_n;

      if ( st->outer_ndim > 0 ) {
        st->outer_idx = ALLOC_N(ca_size_t, st->outer_ndim);
        for ( int8_t m = 0; m < st->outer_ndim; m++ ) st->outer_idx[m] = 0;
      } else {
        st->outer_idx = NULL;
      }

      if ( ca_has_mask(src) ) {
        if ( per_fiber_fused ) {
          /* F.6.1 rev2 §3.3: mask travels with data per-fiber.  Mask
             buffer is delivered through fiber_mask_scratch by
             next_slab_axes; no whole-view materialise. */
          st->alias_mask = NULL;
        } else {
          ca_size_t mcap = src->elements > 0 ? src->elements : 1;
          st->scratch_mask = (boolean8_t *) xmalloc(mcap);
          if ( src->elements > 0 ) {
            ca_copy_data(src->mask, (char *) st->scratch_mask);
          }
          st->alias_mask = st->scratch_mask;
        }
      }
      return CA_ITER_OK;
    }
    if ( src_kind != CA_ITER_SRC_CASTRIDE ) {
      /* Any other unclassified kind. */
      return CA_ITER_ERR_POLICY;
    }
  }

  /* F-2 minimal scope: SHIFT outer axes need OOB fill-slab support which
     is not yet implemented; downgrade to materialise (= existing
     SRC_DESCRIPTOR path) when present.  Future work: allocate a 1-slab
     fill scratch and yield it on OOB iterations (see rev6 §3.5 deferred). */
  if ( src_kind == CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE
       && ca_axis_dispatch_outer_has_shift(raw_descs, raw_ndim) ) {
    src_kind = CA_ITER_SRC_DESCRIPTOR;
  }

  /* Step 9 + 2026-05-31 refactor: L2 dispatch over SRC_ATTACH sources
     (CAFake / CAByteSwap / CABitfield / CABitarray / CAReduce / CAObject
     / CATile / CARoll).  Same shape as L1 SRC_ATTACH: iterator-owns
     scratch + xfer_all GET/PUT.  Yield as one 1-D strided slab. */
  if ( src_kind == CA_ITER_SRC_ATTACH ) {
    memset(st, 0, sizeof(*st));
    st->src      = src;
    st->src_kind = CA_ITER_SRC_ATTACH;
    st->level    = 2;
    st->policy   = policy;
    st->ndim     = 1;            /* logical 1-D L2 layout */
    st->flags    = flags;
    st->bytes    = src->bytes;
    st->axes     = axes;
    st->naxes    = naxes;

    st->scratch_cap = (ca_size_t) src->elements * src->bytes;
    st->scratch_ptr = (char *) xmalloc(st->scratch_cap > 0 ? st->scratch_cap : 1);
    if ( src->elements > 0 ) {
      ca_xfer_all(src, st->scratch_ptr, CA_XFER_GET);
    }
    st->alias_mode          = CA_ITER_ALIAS_NONE;
    st->alias_ptr           = st->scratch_ptr;
    st->composed_strides[0] = src->bytes;
    st->composed_base       = 0;
    st->slab_n              = src->elements;
    st->total_slabs         = 1;
    st->slabs_emitted       = 0;
    st->chunk_size          = st->slab_n;
    st->outer_idx           = NULL;

    if ( ca_has_mask(src) ) {
      ca_size_t mcap = src->elements > 0 ? src->elements : 1;
      st->scratch_mask = (boolean8_t *) xmalloc(mcap);
      if ( src->elements > 0 ) {
        ca_xfer_all(src->mask, (char *) st->scratch_mask, CA_XFER_GET);
      }
      st->alias_mask = st->scratch_mask;
    }
    return CA_ITER_OK;
  }

  /* F-2 (rev6, PROPOSAL_F2_KERNEL_ITERATOR_ALIAS): descriptor L2 alias
     path.  Eligibility (route_source verdict): innermost descriptor axis
     is STRIDE kind, no outer SHIFT axis (downgraded above when present).
     Setup: ca_attach(parent), alias_ptr = parent->ptr, no scratch alloc.
     Each outer-prefix iteration yields a strided slab
       slab_ptr    = parent->ptr + inner_byte_start + outer_prefix_offset
       slab_n      = descs[ndim-1].count
       slab_stride = descs[ndim-1].step * pstrides[ndim-1]
     where outer_prefix_offset is computed via ca_axis_dispatch_prefix_offset
     on the pre-classified prefix[].  next_slab_strided branches on
     src_kind to dispatch to this offset formula. */
  if ( src_kind == CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE ) {
    int8_t  nd = raw_ndim;
    int8_t  k;

    memset(st, 0, sizeof(*st));
    st->src      = src;
    st->src_kind = CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE;
    st->level    = 2;
    st->policy   = policy;
    st->ndim     = nd;
    st->flags    = flags;
    st->bytes    = src->bytes;
    st->axes     = axes;
    st->naxes    = naxes;

    /* Persist descs / parent_axis_dims in state; build parent row-major
       pstrides so prefix_offset / inner offset share the same byte space. */
    memcpy(st->descs, raw_descs, nd * sizeof(ca_axis_desc_t));
    memcpy(st->parent_axis_dims, raw_pdims, nd * sizeof(ca_size_t));
    st->desc_ndim = nd;
    {
      ca_size_t s = src->bytes;
      for ( k = nd - 1; k >= 0; k-- ) {
        st->pstrides[k] = s;
        s *= raw_pdims[k];
      }
    }

    /* Inner slab parameters from innermost STRIDE descriptor axis. */
    ca_size_t inner_start  = raw_descs[nd - 1].start * st->pstrides[nd - 1];
    ca_size_t inner_stride = raw_descs[nd - 1].step  * st->pstrides[nd - 1];
    ca_size_t inner_n      = raw_descs[nd - 1].count;

    /* Outer prefix classify (skipped for 1-D source since no outer). */
    if ( nd > 1 ) {
      ca_axis_dispatch_classify_prefix(st->descs, st->pstrides, nd - 1, st->prefix);
    }

    /* Total slabs = Π descs[0..nd-2].count (= src->elements / inner_n). */
    ca_size_t outer_total = 1;
    for ( k = 0; k < nd - 1; k++ ) outer_total *= raw_descs[k].count;
    st->total_slabs    = outer_total;
    st->slab_n         = inner_n;
    st->slabs_emitted  = 0;
    st->chunk_size     = inner_n;
    st->total_elements = src->elements;

    /* composed_base holds inner_byte_start; composed_strides[nd-1] holds
       inner stride so next_slab_strided's existing inner_st extraction
       (= composed_strides[nd-1]) works without per-iter recomputation.
       Outer slots of composed_strides are unused by the descriptor
       branch in next_slab_strided (= prefix[] drives the offset). */
    st->composed_base            = inner_start;
    st->composed_strides[nd - 1] = inner_stride;

    if ( nd > 1 ) {
      CA_ASSUME(nd <= CA_RANK_MAX);   /* with nd > 1: nd-1 in [1, CA_RANK_MAX-1] */
      st->outer_idx = ALLOC_N(ca_size_t, nd - 1);
      for ( k = 0; k < nd - 1; k++ ) st->outer_idx[k] = 0;
    } else {
      st->outer_idx = NULL;
    }

    CArray *parent = CAVIEW(src)->parent;
    ca_attach(parent);
    st->root       = parent;
    st->alias_mode = CA_ITER_ALIAS_STRIDED;
    st->alias_ptr  = (char *) parent->ptr;

    /* Mask: gather into scratch_mask (same as SRC_DESCRIPTOR path).
       Data alias + mask materialise is per rev6 §4.4 deferred to F-4.c. */
    if ( ca_has_mask(src) ) {
      ca_size_t mcap = src->elements > 0 ? src->elements : 1;
      st->scratch_mask = (boolean8_t *) xmalloc(mcap);
      if ( src->elements > 0 ) {
        ca_copy_data(src->mask, (char *) st->scratch_mask);
      }
      st->alias_mask = st->scratch_mask;
    }
    return CA_ITER_OK;
  }

  /* Sub-step 5.3: L2 dispatch over descriptor sources.  The view-family
     surface prioritises delivering the cells over avoiding a copy: always
     materialise into a
     scratch buffer via ca_axis_dispatch_attach and yield a single
     strided slab (stride = bytes).  CASelect/CAMapping always reach
     here, CSA/CAGrid/CAWindow/CAShift when INDEX/SHIFT axes are
     present.  F-2 (rev6) routes innermost-STRIDE descriptor cases to
     the L2 alias path above; this block now handles remaining mixed
     cases (innermost INDEX, outer SHIFT temporarily, etc.). */
  if ( src_kind == CA_ITER_SRC_DESCRIPTOR ) {
    /* raw_descs / raw_pdims / raw_ndim were populated by route_source
       above so we skip the local describe_axes call.  Kept locals
       named raw_* to match the original code. */
    memset(st, 0, sizeof(*st));
    st->src      = src;
    st->src_kind = CA_ITER_SRC_DESCRIPTOR;
    st->level    = 2;
    st->policy   = policy;
    st->ndim     = src->ndim;
    st->flags    = flags;
    st->bytes    = src->bytes;
    st->axes     = axes;
    st->naxes    = naxes;

    memcpy(st->parent_axis_dims, raw_pdims, raw_ndim * sizeof(ca_size_t));
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

    /* Materialise via the engine into a scratch buffer (contig
       layout = single strided run, stride = bytes). */
    CArray *parent = CAVIEW(src)->parent;
    ca_attach(parent);
    st->root        = parent;
    st->scratch_cap = src->elements * src->bytes;
    const void *bound_fill = NULL;
    if ( ca_func[src->obj_type].attach == ca_window_func.attach ) {
      bound_fill = ((CAWindow *) src)->fill;
    }
    st->scratch_ptr = ca_axis_dispatch_attach(parent,
                                              st->parent_axis_dims,
                                              raw_descs, raw_ndim,
                                              src->bytes,
                                              st->total_elements,
                                              bound_fill);

    /* Lay out as a single 1-D L2 strided slab: ptr = scratch,
       n = total_elements, stride = bytes.  next_slab_strided reads
       inner_stride from composed_strides[ndim - 1] and skips the
       outer loop when outer_idx == NULL, so a 1-D logical layout
       (st->ndim = 1, composed_strides[0] = bytes) yields exactly one
       contig run.  Note st->ndim diverges from src->ndim here — the
       iterator's logical ndim is 1, but the view itself can be N-D
       (the materialised buffer is flat). */
    st->ndim                = 1;
    st->alias_mode          = CA_ITER_ALIAS_NONE;
    st->alias_ptr           = st->scratch_ptr;
    st->composed_strides[0] = src->bytes;
    st->composed_base       = 0;
    st->slab_n              = src->elements;
    st->total_slabs         = 1;
    st->slabs_emitted       = 0;
    st->chunk_size          = st->slab_n;
    st->outer_idx           = NULL;

    /* Step 6: mask gather, same as L1 descriptor branch. */
    if ( ca_has_mask(src) ) {
      ca_size_t mcap = src->elements > 0 ? src->elements : 1;
      st->scratch_mask = (boolean8_t *) xmalloc(mcap);
      if ( src->elements > 0 ) {
        ca_copy_data(src->mask, (char *) st->scratch_mask);
      }
      st->alias_mask = st->scratch_mask;
    }
    return CA_ITER_OK;
  }

  /* === CAStride / entity L2 path === */
  memset(st, 0, sizeof(*st));
  st->src      = src;
  st->src_kind = CA_ITER_SRC_CASTRIDE;
  st->level    = 2;
  st->policy = policy;
  st->ndim   = src->ndim;
  st->flags  = flags;
  st->bytes  = src->bytes;
  st->axes   = axes;
  st->naxes  = naxes;

  /* Compute composed strides + base.  For entity / CAStride contig we
     synthesise row-major byte strides so next_slab_strided's offset
     math is uniform across alias modes; for CAStride non-contig we
     compose leaf strides up to the root entity via the substrate. */
  int8_t nd = src->ndim;
  int    use_strided     = 0;
  int    use_view_scratch = 0;
  CArray *root = NULL;

  if ( ca_iter_can_alias(src, 1) ) {
    /* Entity or CAStride contig: stride = row-major bytes, base = 0. */
    ca_iter_build_rowmajor_strides(st->composed_strides,
                                   src->dim, nd, src->bytes);
    st->composed_base = 0;
  } else {
    /* CAStride non-contig: leaf->root compose. */
    ca_size_t cs[CA_RANK_MAX];
    ca_size_t base;
    ca_stride_compose_to_root((CAStride *) src, &root, cs, &base);
    if ( !ca_root_lends_no_memory(root) ) {
      memcpy(st->composed_strides, cs, nd * sizeof(ca_size_t));
      st->composed_base = base;
      use_strided = 1;
    } else {
      /* Root holds nothing to read through: reaching root->ptr costs one
         whole-root materialise no matter how few cells the view touches —
         the same cliff the xfer path avoids by asking for a region.  Take
         the view's own region protocol instead: ca_copy_data walks the
         leaf's request up the chain, so a 1000x1000 slice of a 2014x3040
         CAObject asks for exactly that block.  The gathered buffer is view
         row-major, so the slab arithmetic below is the contig-alias case
         unchanged. */
      root = NULL;
      ca_iter_build_rowmajor_strides(st->composed_strides,
                                     src->dim, nd, src->bytes);
      st->composed_base = 0;
      use_view_scratch  = 1;
    }
  }

  /* Phase A: CA_SLAB_AXES branch.  Partition axes into slab vs outer,
     populate per-axis dims / strides (both data byte strides from
     composed_strides[] and mask element strides from view row-major
     dim products), allocate outer_idx if outer_ndim > 0, attach data
     buffer (alias or strided), gather mask if present.

     Layout invariant: slab_axes_buf and outer_axes are both stored
     sort-ascending (in source-axis order), so multi-axis CA_SLAB_AXES
     is canonical regardless of the user's input order. */
  if ( policy == CA_SLAB_AXES ) {
    /* Validate axes input. */
    if ( axes == NULL || naxes <= 0 || naxes > nd ) {
      return CA_ITER_ERR_POLICY;
    }
    int8_t in_slab[CA_RANK_MAX];
    int8_t k;
    for ( k = 0; k < CA_RANK_MAX; k++ ) in_slab[k] = 0;
    for ( k = 0; k < naxes; k++ ) {
      int8_t ax = axes[k];
      if ( ax < 0 || ax >= nd ) return CA_ITER_ERR_POLICY;
      if ( in_slab[ax] )        return CA_ITER_ERR_POLICY;  /* duplicate */
      in_slab[ax] = 1;
    }

    /* View row-major element strides (= mask scratch layout strides). */
    ca_size_t row_elem_strides[CA_RANK_MAX];
    {
      ca_size_t s = 1;
      for ( k = nd - 1; k >= 0; k-- ) {
        row_elem_strides[k] = s;
        s *= src->dim[k];
      }
    }

    /* Partition axes (ascending order). */
    int8_t sp = 0, op = 0;
    st->slab_elements = 1;
    for ( k = 0; k < nd; k++ ) {
      if ( in_slab[k] ) {
        st->slab_axes_buf[sp]    = k;
        st->slab_dims[sp]        = src->dim[k];
        st->slab_strides[sp]     = st->composed_strides[k];
        st->slab_mask_strides[sp] = row_elem_strides[k];
        st->slab_elements       *= src->dim[k];
        sp++;
      } else {
        st->outer_axes[op]        = k;
        st->outer_dims[op]        = src->dim[k];
        st->outer_strides[op]     = st->composed_strides[k];
        st->outer_mask_strides[op] = row_elem_strides[k];
        op++;
      }
    }
    st->slab_ndim  = sp;
    st->outer_ndim = op;

    /* total_slabs = Π outer_dims.  Empty product (all-axes case) = 1
       → single slab = whole array (D1.4 WHOLE-equivalent). */
    ca_size_t total = 1;
    for ( int8_t m = 0; m < st->outer_ndim; m++ ) total *= st->outer_dims[m];
    st->total_slabs   = total;
    st->slab_n        = st->slab_elements;    /* mirror to legacy field */
    st->slabs_emitted = 0;
    st->chunk_size    = st->slab_n;

    if ( st->outer_ndim > 0 ) {
      st->outer_idx = ALLOC_N(ca_size_t, st->outer_ndim);
      for ( int8_t m = 0; m < st->outer_ndim; m++ ) st->outer_idx[m] = 0;
    } else {
      st->outer_idx = NULL;
    }

    if ( use_strided ) {
      st->root       = root;
      ca_attach(root);
      st->alias_mode = CA_ITER_ALIAS_STRIDED;
      st->alias_ptr  = (char *) root->ptr;
    } else if ( use_view_scratch ) {
      st->root        = NULL;
      st->scratch_cap = (ca_size_t) src->elements * src->bytes;
      st->scratch_ptr = (char *) xmalloc(st->scratch_cap > 0
                                         ? st->scratch_cap : 1);
      if ( src->elements > 0 ) {
        ca_copy_data(src, st->scratch_ptr);
      }
      st->alias_mode = CA_ITER_ALIAS_NONE;
      st->alias_ptr  = st->scratch_ptr;
    } else {
      st->root       = NULL;
      ca_attach(src);
      st->alias_mode = CA_ITER_ALIAS_CONTIG;
      st->alias_ptr  = (char *) src->ptr;
    }

    /* Mask: gather to scratch_mask in view row-major order (= same as
       L1 path).  The mask layout matches view->dim row-major, which is
       what slab_mask_strides / outer_mask_strides walk. */
    if ( ca_has_mask(src) ) {
      ca_size_t mcap = src->elements > 0 ? src->elements : 1;
      st->scratch_mask = (boolean8_t *) xmalloc(mcap);
      if ( src->elements > 0 ) {
        ca_copy_data(src->mask, (char *) st->scratch_mask);
      }
      st->alias_mask = st->scratch_mask;
    }
    return CA_ITER_OK;
  }

  /* Outer prefix axes [0..ndim-2] drive total_slabs; innermost axis is
     the slab.  0-d / 1-d sources collapse to a single yield. */
  if ( nd <= 1 ) {
    st->total_slabs = 1;
    st->slab_n      = src->elements;
    st->outer_idx   = NULL;
  } else {
    ca_size_t total = 1;
    int8_t k;
    for ( k = 0; k < nd - 1; k++ ) total *= src->dim[k];
    st->total_slabs = total;
    st->slab_n      = src->dim[nd - 1];
    st->outer_idx   = ALLOC_N(ca_size_t, nd - 1);
    for ( k = 0; k < nd - 1; k++ ) st->outer_idx[k] = 0;
  }
  st->slabs_emitted = 0;
  st->chunk_size    = st->slab_n;

  if ( use_strided ) {
    st->root = root;
    ca_attach(root);
    st->alias_mode = CA_ITER_ALIAS_STRIDED;
    st->alias_ptr  = (char *) root->ptr;
  } else if ( use_view_scratch ) {
    st->root        = NULL;
    st->scratch_cap = (ca_size_t) src->elements * src->bytes;
    st->scratch_ptr = (char *) xmalloc(st->scratch_cap > 0
                                       ? st->scratch_cap : 1);
    if ( src->elements > 0 ) {
      ca_copy_data(src, st->scratch_ptr);
    }
    st->alias_mode = CA_ITER_ALIAS_NONE;
    st->alias_ptr  = st->scratch_ptr;
  } else {
    st->root = NULL;
    ca_attach(src);
    st->alias_mode = CA_ITER_ALIAS_CONTIG;
    st->alias_ptr  = (char *) src->ptr;
  }
  return CA_ITER_OK;
}

int
ca_iter_state_next_slab (ca_iter_state *st,
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

int
ca_iter_state_next_slab_strided (ca_iter_state *st,
                                 char         **out_ptr,
                                 boolean8_t   **out_mask,
                                 ca_size_t     *out_n,
                                 ca_size_t     *out_stride_bytes)
{
  if ( st == NULL || st->level != 2
       || st->slabs_emitted >= st->total_slabs ) {
    if ( out_ptr          ) *out_ptr          = NULL;
    if ( out_mask         ) *out_mask         = NULL;
    if ( out_n            ) *out_n            = 0;
    if ( out_stride_bytes ) *out_stride_bytes = 0;
    return 0;
  }

  int8_t    nd       = st->ndim;
  ca_size_t inner_st = (nd > 0)
                       ? st->composed_strides[nd - 1]
                       : st->bytes;
  ca_size_t off      = st->composed_base;
  int8_t    k;

  /* Sum outer prefix offset. For F-2 descriptor L2 alias the prefix can
     contain INDEX axes (and, once OOB fill_slab lands, SHIFT axes), so
     we delegate to the pre-classified prefix[] engine.  Otherwise (=
     CAStride / entity outer = STRIDE-only by construction) use the
     direct sum that has been the L2 inner loop since step 3.  For
     0-d / 1-d sources, the loop / call is a no-op and off stays at
     composed_base. */
  if ( st->outer_idx != NULL ) {
    if ( st->src_kind == CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE ) {
      int oob = 0;
      off += ca_axis_dispatch_prefix_offset(st->prefix, st->outer_idx,
                                            nd - 1, &oob);
      /* oob unreachable: outer SHIFT was downgraded in init_l2. */
    } else {
      for ( k = 0; k < nd - 1; k++ ) {
        off += st->outer_idx[k] * st->composed_strides[k];
      }
    }
  }

  if ( out_ptr          ) *out_ptr          = st->alias_ptr + off;
  /* mask layout mirrors value layout, but mask is contig boolean8_t
     when alias_mask is a scratch buffer (step 6 baseline = always
     gather mask into scratch_mask for uniformity).  Per-slab mask
     offset = i in the outer cursor (= slabs_emitted at this point). */
  if ( out_mask         ) {
    *out_mask = st->alias_mask
                ? st->alias_mask + st->slabs_emitted * st->slab_n
                : NULL;
  }
  if ( out_n            ) *out_n            = st->slab_n;
  if ( out_stride_bytes ) *out_stride_bytes = inner_st;

  st->slabs_emitted += 1;

  /* Advance outer_idx row-major (least-significant axis innermost,
     so we tick outer_idx[ndim-2] first). */
  if ( st->outer_idx != NULL ) {
    for ( k = nd - 2; k >= 0; k-- ) {
      if ( ++st->outer_idx[k] < st->src->dim[k] ) break;
      st->outer_idx[k] = 0;
    }
  }
  return 1;
}

int
ca_iter_state_next_slab_axes (ca_iter_state *st,
                              char         **out_ptr,
                              boolean8_t   **out_mask)
{
  if ( st == NULL || st->policy != CA_SLAB_AXES || st->level != 2
       || st->slabs_emitted >= st->total_slabs ) {
    if ( out_ptr  ) *out_ptr  = NULL;
    if ( out_mask ) *out_mask = NULL;
    return 0;
  }

  /* Phase C T3 specialised path (B-1b, C.1b, 2026-05-27): innermost
     slab axis is STRIDE, no SHIFT axes anywhere.  Hoist outer + non-
     innermost-slab axes (= per-cell switch evaluated once per slab row),
     inner = pure STRIDE linear memcpy (= SIMD-friendly contig run, no
     engine per-cell dispatch).  Target: 1.5-1.8x win for INDEX slab
     with innermost STRIDE (= grid / select sparse projection use cases). */
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
    if ( out_mask ) *out_mask = st->scratch_mask ? st->scratch_mask + mask_off : NULL;

    st->slabs_emitted += 1;
    for ( int8_t m = st->outer_ndim - 1; m >= 0; m-- ) {
      if ( ++st->outer_idx[m] < st->outer_dims[m] ) break;
      st->outer_idx[m] = 0;
    }
    return 1;
  }

  /* PROPOSAL_CASTACK_XFER_OPT_LAYERING P.2 Case A (2026-06-18): CAStack
     source + K-axis (k_axis) in outer iter.  Each slab aliases a region
     inside parents[k]->ptr where k = outer_idx[K_outer_pos].  Parent
     inner byte offset = Σ outer_idx[m] * stack_parent_strides[parent_ax]
     over all outer axes except the K-axis itself.  Mask: parallel alias
     into parents[k]->mask->ptr + mask_off.  Zero copy / zero scratch /
     parent entity bandwidth.

     K.3 (2026-06-20): parent_ax derivation generalised for arbitrary
     k_axis -- stack axis s != k_axis maps to parent axis s if
     s < k_axis else s - 1. */
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

    if ( out_ptr  ) *out_ptr  = st->stack_parent_ptrs[k] + parent_off;
    if ( out_mask ) {
      *out_mask = st->stack_parent_mask_ptrs
                ? st->stack_parent_mask_ptrs[k] + mask_off
                : NULL;
    }

    st->slabs_emitted += 1;
    for ( int8_t m = st->outer_ndim - 1; m >= 0; m-- ) {
      if ( ++st->outer_idx[m] < st->outer_dims[m] ) break;
      st->outer_idx[m] = 0;
    }
    return 1;
  }

  /* PROPOSAL_CASTACK_LOOP_INTERCHANGE Vector A rev2: CAStack direct
     per-parent ptr access path.  For each outer iter, compute the
     parent inner byte offset (= same across all K parents, uniform
     shape), then K-fold direct memcpy gather from cached parent ptrs
     into scratch.  No ca_xfer_stride dispatch; per-cell cost = pointer
     arith + memcpy(bytes).  For f64 the memcpy(8) compiles to a single
     mov, so the inner loop is tight.

     Note: scope-narrowed to slab_axes == [0] at init, so outer_axes are
     stack axes 1..N-1 = parent axes 0..parent_ndim-1.  outer_idx[m]
     maps directly to parent axis (m) (since the m-th outer axis is
     stack axis m+1 = parent axis m). */
  if ( st->alias_mode == CA_ITER_ALIAS_STACK ) {
    /* pilot/castack-axis0-loop-interchange: tile cache.  Outer iter
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

  /* Phase C T3 fallback (C.1, 2026-05-27): per-slab materialise via
     ca_axis_dispatch_gather with a subset descriptor built by pinning
     outer axes at the current outer_idx position (D1.2 (A): caller-side
     subset construction, engine API unchanged).  scratch_ptr is sized
     for one max slab and reused across iters (D1.1 (B)). */
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

    /* CAWindow fill value capture (= same lookup as B.1.5 init). */
    const void *bound_fill = NULL;
    if ( ca_func[st->src->obj_type].attach == ca_window_func.attach ) {
      bound_fill = ((CAWindow *) st->src)->fill;
    }

    ca_axis_dispatch_gather(st->root, st->parent_axis_dims, subset_descs,
                            st->ndim, st->bytes, st->slab_elements,
                            bound_fill, st->scratch_ptr);

    /* Mask offset into whole-view scratch_mask (T3 path keeps mask
       layout view-row-major to match slab_mask_strides). */
    ca_size_t mask_off = 0;
    for ( int8_t m = 0; m < st->outer_ndim; m++ ) {
      mask_off += st->outer_idx[m] * st->outer_mask_strides[m];
    }

    if ( out_ptr  ) *out_ptr  = st->scratch_ptr;
    if ( out_mask ) *out_mask = st->scratch_mask ? st->scratch_mask + mask_off : NULL;

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

     STRIDE outer axes (Phase A SRC_CASTRIDE, and Phase B
     SRC_DESCRIPTOR STRIDE-kind axes) use outer_idx[m] directly as the
     multiplier.  INDEX outer axes (Phase B SRC_DESCRIPTOR INDEX-kind)
     need an indices[] lookup: multiplier = descs[axis].indices[outer_idx[m]].
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

  /* PROPOSAL_FIBER_PER_SOURCE_PATH F.6.1: per-fiber fused dispatch.
     When init_l2 selected CA_ITER_ALIAS_PER_FIBER_FUSED, there is no
     whole-view buffer to alias from.  Build the fiber region from
     outer_idx + fiber_axis and call ca_xfer_stride(src, ..., GET)
     directly into fiber_data_scratch.  For fused-aware views (X.1
     OOB-fused / X.4 transform-fused) this routes to a 1-pass per-
     region path.

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
      if ( st->fiber_data_scratch ) xfree(st->fiber_data_scratch);
      st->fiber_data_scratch     = (char *) xmalloc(need > 0 ? need : 1);
      st->fiber_data_scratch_cap = need;
    }

    /* Build fiber region: fiber_axis spans the full fiber, all other
       axes pinned to outer_idx position (count=1).  Cache starts[] in
       state so sync_slab can rebuild the same region for WRITE PUT
       (= captured BEFORE outer_idx advance below, same hazard pattern
       as F.1a last_data_off). */
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

  /* PROPOSAL_FIBER_DELIVERY F.1a: per-axis fiber contig delivery.
     For naxes==1 (= single slab axis = fiber) the catalog contract
     CA_FOR_EACH_FIBER promises contig data delivery.  When the fiber
     is not innermost-contig (= slab_strides[0] != bytes), the engine
     gathers the fiber into fiber_data_scratch before yielding so the
     author can write p[i] without stride math.

     Capture last_data_off BEFORE the outer_idx advance below; sync_slab
     consumes it for WRITE scatter.  See header field doc + PROPOSAL
     §4.3.2 hazard comment in sync_slab. */
  char *yield_ptr;
  if ( (st->flags & CA_KERNEL_FIBER_CONTIG)
       && st->naxes == 1 && st->slab_ndim == 1 ) {
    ca_size_t n         = st->slab_dims[0];
    ca_size_t data_step = st->slab_strides[0];
    ca_size_t bytes     = st->bytes;
    char     *src_data  = st->alias_ptr + data_off;

    st->last_data_off = data_off;

    if ( data_step == (ca_size_t) bytes ) {
      /* Fast path: fiber is already contig (= innermost-axis or stride
         coincidentally == bytes).  No gather needed. */
      yield_ptr = src_data;
    } else {
      /* Per-fiber gather via the typed-store inline helper
         (ca_iter_substrate.h).  For bytes in {1,2,4,8} this uses a
         compiler-vectorize-friendly `*dp++ = v; sp += step` loop;
         other sizes fall back to per-element memcpy.  Lazy-alloc
         scratch sized to max fiber bytes (slab_dims[0] constant per
         walk → single alloc in practice). */
      ca_size_t need = n * bytes;
      if ( st->fiber_data_scratch_cap < need ) {
        if ( st->fiber_data_scratch ) xfree(st->fiber_data_scratch);
        st->fiber_data_scratch     = (char *) xmalloc(need);
        st->fiber_data_scratch_cap = need;
      }
      ca_stride_gather_run(st->fiber_data_scratch, src_data,
                           bytes, n, data_step);
      yield_ptr = st->fiber_data_scratch;
    }
  } else {
    yield_ptr = st->alias_ptr + data_off;
  }

  /* PROPOSAL_FIBER_DELIVERY F.1b: per-fiber contig mask delivery.
     Symmetric to F.1a data path above.  When the source has a mask
     (= alias_mask != NULL) and the fiber's mask is not innermost-contig
     (= slab_mask_strides[0] != 1), gather it into fiber_mask_scratch
     so the author can write m[i] without stride math.  Mask is
     read-only here (= L2 WRITE never propagates to mask state), so no
     scatter is needed in sync_slab. */
  boolean8_t *yield_mask;
  if ( (st->flags & CA_KERNEL_FIBER_CONTIG)
       && st->naxes == 1 && st->slab_ndim == 1
       && st->alias_mask != NULL ) {
    ca_size_t   n         = st->slab_dims[0];
    ca_size_t   mask_step = st->slab_mask_strides[0];
    boolean8_t *src_mask  = st->alias_mask + mask_off;

    if ( mask_step == 1 ) {
      yield_mask = src_mask;
    } else {
      if ( st->fiber_mask_scratch_cap < (ca_size_t) n ) {
        if ( st->fiber_mask_scratch ) xfree(st->fiber_mask_scratch);
        st->fiber_mask_scratch     = (boolean8_t *) xmalloc(n);
        st->fiber_mask_scratch_cap = n;
      }
      for ( ca_size_t i = 0; i < n; i++ ) {
        st->fiber_mask_scratch[i] = src_mask[i * mask_step];
      }
      yield_mask = st->fiber_mask_scratch;
    }
  } else {
    yield_mask = st->alias_mask ? st->alias_mask + mask_off : NULL;
  }

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

void
ca_iter_state_sync_slab (ca_iter_state *st)
{
  /* READ walk: nothing to sync. */
  if ( st == NULL || !(st->flags & CA_KERNEL_WRITE) ) return;

  /* PROPOSAL_CASTACK_LOOP_INTERCHANGE Vector A rev2: STACK path is
     READ-only in initial scope.  Kernel writes into scratch would not
     be valid to scatter back via xfer_all PUT (= scratch is slab-sized
     not whole-view), so the SRC_ATTACH PUT below would be a semantic
     mismatch.  Per-slab scatter via direct per-parent memcpy is a
     future extension once a WRITE-using kernel materialises. */
  if ( st->alias_mode == CA_ITER_ALIAS_STACK
       || st->alias_mode == CA_ITER_ALIAS_STACK_OUTER_K ) {
    /* STACK_OUTER_K (P.2 Case A) is READ-only scope: slabs are direct
       aliases into parents[k]->ptr, kernel WRITE would scatter into
       parent memory which is out of scope (see proposal R1).  Skip
       sync. */
    st->write_dirty = 0;
    return;
  }

  /* SRC_ATTACH path (step 9 + 2026-05-31 refactor): kernel wrote into
     iterator-owned scratch (= scratch_ptr).  Push back via xfer_all PUT
     which routes through the view's xfer_all slot -- handles CAFake
     (cast back), CAByteSwap (swap back), CABitfield/CABitarray (bit
     pack back), CAReduce (broadcast across reduce window).  Inherits
     transform-fused / partial materialise / etc. automatically. */
  if ( st->src_kind == CA_ITER_SRC_ATTACH ) {
    if ( st->src->elements > 0 ) {
      ca_xfer_all(st->src, st->scratch_ptr, CA_XFER_PUT);
    }
    st->write_dirty = 0;
    return;
  }

  /* ======================================================================
   *           !!! CORRECTNESS HAZARD - DO NOT MOVE !!!
   *
   * (PROPOSAL_FIBER_DELIVERY F.1a)
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

  /* PROPOSAL_FIBER_PER_SOURCE_PATH F.6.1: per-fiber fused WRITE PUT.
     When alias_mode == CA_ITER_ALIAS_PER_FIBER_FUSED, the author
     wrote into fiber_data_scratch and there is no whole-view buffer
     to xfer_all PUT.  Rebuild the same fiber region from cached
     fiber_region_starts[] (= captured pre-advance in next_slab_axes,
     same hazard pattern as F.1a last_data_off) and call
     ca_xfer_stride(src, ..., PUT) which routes through the view's
     fused PUT path (X.1 / X.4) for 1-pass scatter back. */
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

  /* Per-fiber gather path scatter (PROPOSAL_FIBER_DELIVERY F.1a).
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
    /* Fall through to any subsequent src_kind scatter (= harmless: for
       the alias paths reached here, scratch_ptr is NULL and the switch
       below early-returns).  But for SRC_DESCRIPTOR / SRC_ATTACH that
       use the per-slab materialise path, fiber_data_scratch stays NULL
       (those paths use scratch_ptr and the PER_SLAB(_HOIST) yield), so
       this block does not fire. */
  }

  /* alias path: kernel wrote through alias_ptr into parent directly
     (case A semantics, PROPOSAL_T1_WRITE_SEMANTICS.md §(a)).  No
     scatter needed.  Applies to all CAStride alias and to
     STRIDE-only descriptor alias (= descriptor L2 alias future
     optimisation, not yet enabled — but if it lands, scratch_ptr
     stays NULL and we no-op correctly). */
  if ( st->scratch_ptr == NULL ) return;

  /* scratch path: scatter back the materialised buffer into the
     source view.  src_kind chooses the engine: */
  switch ( st->src_kind ) {
    case CA_ITER_SRC_CASTRIDE:
      /* Two producers of CAStride + scratch: L1 non-contig, and the L2
         non-entity-root path (init_l2's use_view_scratch).  Both gathered
         with ca_copy_data into a view row-major buffer, so both scatter
         back the same way — ca_sync_data routes through the view's
         xfer_all(PUT), which asks the root for the region it owns rather
         than writing a whole-root materialise back. */
      ca_sync_data(st->src, st->scratch_ptr);
      break;

    case CA_ITER_SRC_DESCRIPTOR: {
      /* Sub-step 5.4: descriptor framework scatter back.
         ca_axis_dispatch_scatter is the P3-landed engine entry that
         handles per-axis kind (STRIDE / INDEX / SHIFT) gather direction
         in reverse — INDEX duplicates yield last-write-wins (R5 spec),
         SHIFT OOB cells in CAWindow FILL policy are skipped (no parent
         destination), CAShift WRAP/REFLECT bounds map back to interior
         and are written normally.  Iteration order is engine-defined;
         user kernels must not rely on it.

         scatter wants the pre-merge raw descriptors (the engine re-runs
         _prepare internally with whatever we give it).  init cached
         the post-merge axes in st->descs for next_slab_strided's
         offset math; we re-call describe_axes here for the scatter
         call rather than caching a second copy in the state struct. */
      ca_axis_desc_t raw_descs[CA_RANK_MAX];
      ca_size_t      raw_pdims[CA_RANK_MAX];
      int8_t         raw_ndim = 0;
      ca_iter_describe_axes(st->src, raw_descs, raw_pdims, &raw_ndim);
      ca_axis_dispatch_scatter(st->root /* parent */,
                               raw_pdims,
                               raw_descs, raw_ndim,
                               st->bytes, st->total_elements,
                               st->scratch_ptr);
      break;
    }
  }
  st->write_dirty = 0;
}

void
ca_iter_state_finish (ca_iter_state *st)
{
  if ( st == NULL || st->src == NULL ) {
    return;
  }
  /* composed_strides is inline — no free needed.  outer_idx is heap
     for L2 multi-d sources (NULL on L1 paths and on L2 0/1-d). */
  if ( st->outer_idx ) {
    xfree(st->outer_idx);
    st->outer_idx = NULL;
  }
  /* Lifecycle cleanup — orders matter slightly (free scratch before
     detaching parent so the kernel iterator's resources are released
     symmetrically with init):
       - scratch_ptr: owned by iter (CAStride non-contig L1, or
         descriptor materialise via ca_axis_dispatch_attach). xfree.
       - root: descriptor parent attached at init (sub-step 5.1+) or
         CAStride L2 compose-fold root attached at init (step 3).
         ca_detach.
       - else (alias paths): src was attached at init, detach. */
  if ( st->scratch_ptr ) {
    xfree(st->scratch_ptr);
    st->scratch_ptr = NULL;
    st->scratch_cap = 0;
  }
  if ( st->scratch_mask ) {
    xfree(st->scratch_mask);
    st->scratch_mask = NULL;
  }
  /* PROPOSAL_FIBER_DELIVERY F.1a/F.1b: per-fiber scratch lifecycle. */
  if ( st->fiber_data_scratch ) {
    xfree(st->fiber_data_scratch);
    st->fiber_data_scratch     = NULL;
    st->fiber_data_scratch_cap = 0;
  }
  if ( st->fiber_mask_scratch ) {
    xfree(st->fiber_mask_scratch);
    st->fiber_mask_scratch     = NULL;
    st->fiber_mask_scratch_cap = 0;
  }
  /* PROPOSAL_CASTACK_LOOP_INTERCHANGE Vector A rev2 + P.2 Case A: detach
     K parents (+ K parent masks if cached) and free the cached ptr
     arrays.  Symmetric with init_l2 per-parent ca_attach loop. */
  if ( st->stack_parent_ptrs ) {
    CAStack *stack = (CAStack *) st->src;
    for ( int32_t kk = 0; kk < st->stack_n_parents; kk++ ) {
      ca_detach(stack->parents[kk]);
    }
    xfree(st->stack_parent_ptrs);
    st->stack_parent_ptrs = NULL;
  }
  /* pilot/castack-axis0-loop-interchange: free tile cache. */
  if ( st->stack_tile_cache ) {
    xfree(st->stack_tile_cache);
    st->stack_tile_cache = NULL;
    st->stack_tile_cap   = 0;
    st->stack_tile_pos   = 0;
    st->stack_tile_have  = 0;
  }
  if ( st->stack_parent_mask_ptrs ) {
    CAStack *stack = (CAStack *) st->src;
    for ( int32_t kk = 0; kk < st->stack_n_parents; kk++ ) {
      ca_detach(stack->parents[kk]->mask);
    }
    xfree(st->stack_parent_mask_ptrs);
    st->stack_parent_mask_ptrs = NULL;
  }
  st->stack_n_parents = 0;
  if ( st->root ) {
    ca_detach(st->root);
    st->root = NULL;
  } else if ( st->alias_mode == CA_ITER_ALIAS_CONTIG
              || st->alias_mode == CA_ITER_ALIAS_STRIDED ) {
    /* alias path (CONTIG/STRIDED for CAStride family): we attached
       src directly at init, so detach it here.
       Note: SRC_ATTACH used to be in this list (ALIAS_ATTACH); after
       the 2026-05-31 refactor it owns its own scratch (alias_mode =
       NONE, scratch_ptr xfree'd above), so no src.detach needed. */
    ca_detach(st->src);
  }
  st->src       = NULL;
  st->alias_ptr = NULL;
}

#ifdef CARRAY_DEV_BUILD
/* ============================================================
 * smoke surface (dev-only, stripped in release)
 *
 * Gated by CARRAY_DEV_BUILD (enabled via `extconf.rb --enable-dev-build`
 * or `CARRAY_DEV=1 rake build_ext`).  These helpers expose internal
 * engine state to Ruby for spec_ai regression pins.  Do not consume
 * from user code.
 *
 * See devel/PROPOSAL_SMOKE_DEV_BUILD_GATE.md
 * ============================================================ */

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

/* L2 smoke (step 3): CArray.t1_smoke_strided(ca) -> Hash with
     rc            => Integer
     slabs         => Integer (= total_slabs)
     total_elems   => Integer
     alias_mode    => Integer
     data          => String — slab bytes reconstructed via the
                     reported (ptr, n, stride_bytes) tuples, in
                     iteration order; should equal view.to_ca.dump_binary
     strides       => Array<Integer> — stride_bytes per yielded slab
                     (constant across yields under WHOLE policy in
                     step 3; surfaced for inspection)
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

  rc = ca_iter_state_init_l2(&st, src, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc == CA_ITER_OK ) {
    while ( ca_iter_state_next_slab_strided(&st, &p, NULL, &n, &stride_bytes) ) {
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

  rc = ca_iter_state_init_l2(&st, src, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "ca_iter_state_init L2 failed (rc=%d)", rc);
  }

  while ( ca_iter_state_next_slab_strided(&st, &p, NULL, &n, &stride_bytes) ) {
    /* Step 8.1: macro picks contig fast path when stride == sizeof(double),
       falls back to strided loop otherwise.  Removes the SIMD inhibition
       observed in step 5.5 §10.4.5 on descriptor materialise paths. */
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

/* WRITE smoke: in-place fill via L2 strided dispatch.  Used by the
   step 5.5 aggregate bench to round out the matrix (L1 WRITE was
   already in t1_smoke_write_fill_f64).  Kernel walks the strided
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

  rc = ca_iter_state_init_l2(&st, src, CA_SLAB_WHOLE, NULL, 0,
                             CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) return INT2NUM(rc);

  while ( ca_iter_state_next_slab_strided(&st, &p, NULL, &n, &stride) ) {
    /* Step 8.1: contig fast path via macro (stride == sizeof(double)
       on materialise scratch, which is the descriptor L2 path that
       hit +18-22% in step 5.5 — macro removes that overhead). */
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
   order.  Uses next_slab_strided so each row is a strided slab; the
   kernel materialises into a tight contig scratch, qsorts, then
   writes back via the same stride.  This exercises L2 WRITE
   mechanics (multi-slab walk, per-slab fill of strided cells)
   without over-engineering a strided qsort itself — that would be a
   Pattern H specialised op, out of step 4 scope (reviewer advice #3).
*/
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

  rc = ca_iter_state_init_l2(&st, src, CA_SLAB_WHOLE, NULL, 0,
                             CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) return INT2NUM(rc);

  while ( ca_iter_state_next_slab_strided(&st, &p, NULL, &n, &stride_bytes) ) {
    if ( n > (ca_size_t) (sizeof(scratch) / sizeof(double)) ) {
      ca_iter_state_finish(&st);
      rb_raise(rb_eRuntimeError, "row too large for smoke scratch");
    }
    /* strided -> contig scratch.  Step 8.1: macro handles the
       stride == bytes contig fast path automatically. */
    ca_size_t _sc_i = 0;
    CA_L2_FOR_EACH(double, p, n, stride_bytes, dp, {
      scratch[_sc_i++] = *dp;
    });
    /* in-place qsort on the contig scratch */
    qsort(scratch, n, sizeof(double), cmp_double);
    /* contig scratch -> strided (writes back to parent via alias_ptr,
       case A direct write).  Step 8.1: macro contig fast path. */
    ca_size_t _wb_i = 0;
    CA_L2_FOR_EACH(double, p, n, stride_bytes, dp, {
      *dp = scratch[_wb_i++];
    });
    ca_iter_state_sync_slab(&st);   /* no-op for L2 alias, by invariant */
  }
  ca_iter_state_finish(&st);
  return INT2NUM(CA_ITER_OK);
}

/* Step 6 smoke: L1 walk that exposes BOTH the value slab and the
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

/* L2 bench-grade smoke (sub-step 5.3+).  Same shape as t1_smoke_attach
   but uses init_l2 / next_slab_strided so descriptor sources can be
   exercised through the L2 path. */
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
  rc = ca_iter_state_init_l2(&st, src, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc != CA_ITER_OK ) return INT2NUM(rc);

  while ( ca_iter_state_next_slab_strided(&st, &p, NULL, &n, &stride) ) {
    if ( p != NULL && n > 0 ) sink ^= p[0];
    total += n;
  }
  (void) sink;
  ca_iter_state_finish(&st);
  return SIZE2NUM(total);
}

/* step 7: minimal smoke that exposes the `flags` argument to Ruby
   tests.  Just runs init_l1 with the requested flags and returns
   the rc — used to verify NO_MASK enforcement (and any future
   flag-gated rejection paths) without needing a full kernel walk. */
static VALUE
rb_t1_smoke_init_rc (VALUE klass, VALUE vsrc, VALUE vflags)
{
  CArray         *src;
  ca_iter_state   st;
  int             rc;
  uint32_t        flags = (uint32_t) NUM2UINT(vflags);

  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  rc = ca_iter_state_init_l1(&st, src, CA_SLAB_WHOLE, NULL, 0, flags);
  if ( rc == CA_ITER_OK ) ca_iter_state_finish(&st);
  return INT2NUM(rc);
}

/* ---- Phase A capstone: CA_SLAB_AXES smoke -------------------------
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

/* ---- Phase B.3 helper smoke: rb_ca_parse_reduce_axes ---------------
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

/* ---- API harmonisation A.1 smoke: rb_ca_parse_reduce_axes_kw -------
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

/* ---- Phase A.3 helper smoke: rb_ca_new_reduced ---------------------
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
  /* PROPOSAL_DTYPE_SYMBOL_FLIP: accept Symbol / Integer / Class / String
     uniformly via rb_ca_guess_type so post-flip CA_* (Symbol) callers
     and legacy Integer-code callers both work. */
  data_type = (int32_t) rb_ca_guess_type(argv[1]);
  naxes = (int8_t) (argc - 2);
  if ( naxes > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "too many axes");
  }
  for ( int i = 0; i < naxes; i++ ) {
    axes[i] = (int8_t) NUM2INT(argv[2 + i]);
  }
  return rb_ca_new_reduced(argv[0], axes, naxes, data_type, 0);
}

/* ---- step 9.3: CAReduce-specific smoke -----------------------------
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
   `val` (boolean / 0 or 1) and lets sync_slab → ca_sync run the
   broadcast scatter back to parent.  After the call parent's
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
    ca_iter_state_sync_slab(&st);  /* triggers ca_sync → broadcast */
  }
  ca_iter_state_finish(&st);
  ca_free(reduce);
  return INT2NUM(CA_ITER_OK);
}

/* ---- M.6: CARemap kernel_iterator smoke helpers --------------------
   CARemap has no public Ruby ctor (internal-only per §2.2), so we
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

  rc = ca_iter_state_init_l2(&st, view, CA_SLAB_WHOLE, NULL, 0, 0);
  if ( rc == CA_ITER_OK ) {
    ca_size_t stride;
    while ( ca_iter_state_next_slab_strided(&st, &p, NULL, &n, &stride) ) {
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
   sync_slab → ca_sync run the scatter back to ref via xfer_all PUT. */
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

/* ---- Phase C C.3: CA_FOR_EACH_SLAB macro smoke surfaces -------------
   Smoke kernels that exercise the block macros end-to-end.  Used by
   spec_ai/test_ca_for_each_slab_macros.rb to pin behavioural
   correctness of the macro expansion (= same byte-parity result as
   the raw API equivalent). */

/* sum reduction using CA_FOR_EACH_SLAB.  innermost slab axis only,
   float64 source, accumulator = scalar (single full-reduction slab
   when naxes == src->ndim, otherwise per-outer-slab accumulator
   written to a row-major output buffer).  Mirrors carray_kernel_sum
   structurally but uses the macro for lifecycle. */
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
   always the innermost (= argv[1] is unused for simplicity, axis
   fixed to ca->ndim - 1).  Demonstrates the 2-iter pattern. */
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

/* ---- PROPOSAL_FIBER_DELIVERY F.2: catalog macro smokes -------------
   Exercise each of the 4 catalog forms end-to-end with float64 fibers,
   verifying contig delivery for both innermost (= stride==bytes) and
   non-innermost (= stride>bytes, gather path) axis positions.  Used by
   spec_ai/test_fiber_delivery.rb (= F.3). */

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
   Catalog: CA_FOR_EACH_FIBER_INOUT.  Sorts each fiber for non-trivial
   gather/scatter behavior. */
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

/* F.5 bench helper: sort_copy via CA_FOR_EACH_FIBER_INOUT.
   Functional equivalent of ext/carray_order.c::rb_ca_sort_copy_axis_*
   (= hand-rolled gather/scatter with explicit slab_strides[0] loops).
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

/* F.5 bench helper variant: sort_copy via SLAB macro + manual
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

  ca_size_t fiber_n = src->dim[axis];
  ca_size_t bytes   = sizeof(double);
  char *buf = (char *) xmalloc(fiber_n * bytes);

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
  xfree(buf);
  return vout;
}

/* F.5 follow-up bench: per-fiber fused xfer_stride direct into a contig
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
  char *buf = (char *) xmalloc(fiber_n * src->bytes);

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

  xfree(buf);
  return rb_float_new(total);
}

#endif /* CARRAY_DEV_BUILD — end smoke surface fence */

void
Init_ca_kernel_iterator (void)
{
#ifdef CARRAY_DEV_BUILD
  /* ==== smoke surface registrations (dev-only, stripped in release) ====
   * See PROPOSAL_SMOKE_DEV_BUILD_GATE.md.  All `t1_smoke_*`, `caf_smoke_*`,
   * `caf_fiber_smoke_*`, `caf_*_bench_*`, helper smokes, and `T1_*` test
   * constants are gated here together — none of them are consumed by
   * production code (lib/ / other ext/), only by spec_ai regression pins. */
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
  /* Phase A capstone: CA_SLAB_AXES smoke (variadic axes) */
  rb_define_singleton_method(rb_cCArray, "t1_smoke_sum_axes_f64",
                             rb_t1_smoke_sum_axes_f64, -1);
  /* Phase A.3: rb_ca_new_reduced helper smoke */
  rb_define_singleton_method(rb_cCArray, "t1_test_new_reduced",
                             rb_t1_test_new_reduced, -1);
  /* Phase B.3: rb_ca_parse_reduce_axes helper smoke */
  rb_define_singleton_method(rb_cCArray, "t1_test_parse_reduce_axes",
                             rb_t1_test_parse_reduce_axes, -1);

  /* API harmonisation A.1: rb_ca_parse_reduce_axes_kw helper smoke */
  rb_define_singleton_method(rb_cCArray, "test_parse_reduce_axes_kw",
                             rb_test_parse_reduce_axes_kw, -1);
  /* CAReduce-specific (step 9.3): no public Ruby API */
  rb_define_singleton_method(rb_cCArray, "t1_make_reduce",
                             rb_t1_make_reduce, 3);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_reduce_read",
                             rb_t1_smoke_reduce_read, 3);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_reduce_write_broadcast",
                             rb_t1_smoke_reduce_write_broadcast, 4);

  /* M.6 CARemap kernel_iterator smokes (test-only). */
  rb_define_singleton_method(rb_cCArray, "t1_smoke_remap_read",
                             rb_t1_smoke_remap_read, 2);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_remap_read_strided",
                             rb_t1_smoke_remap_read_strided, 2);
  rb_define_singleton_method(rb_cCArray, "t1_smoke_remap_write_fill_f64",
                             rb_t1_smoke_remap_write_fill_f64, 3);
  /* Phase C C.3 (2026-05-27): block macro smokes */
  rb_define_singleton_method(rb_cCArray, "caf_smoke_sum_f64",
                             rb_caf_smoke_sum_f64, -1);
  rb_define_singleton_method(rb_cCArray, "caf_smoke_double_f64",
                             rb_caf_smoke_double_f64, 1);
  /* PROPOSAL_FIBER_DELIVERY F.2: catalog macro smokes */
  rb_define_singleton_method(rb_cCArray, "caf_fiber_smoke_sum_f64",
                             rb_caf_fiber_smoke_sum_f64, 2);
  rb_define_singleton_method(rb_cCArray, "caf_fiber_smoke_double_f64",
                             rb_caf_fiber_smoke_double_f64, 2);
  rb_define_singleton_method(rb_cCArray, "caf_fiber_smoke_unmasked_sum_f64",
                             rb_caf_fiber_smoke_unmasked_sum_f64, 2);
  rb_define_singleton_method(rb_cCArray, "caf_fiber_smoke_zero_masked_f64",
                             rb_caf_fiber_smoke_zero_masked_f64, 2);
  /* F.5 bench helper */
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
  rb_define_const(rb_cCArray, "T1_ITER_ERR_UNBOUND_SHAPE", INT2NUM(CA_ITER_ERR_UNBOUND_SHAPE));
#endif /* CARRAY_DEV_BUILD */
}
