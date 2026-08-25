/* ---------------------------------------------------------------------------

  ca_kernel_iterator.h

  T1 kernel_iterator — C extension author surface.

  Status: TWO-TIER FREEZE CONTRACT (3.0 onward).  The surface is split
  so the engine can be re-implemented across 3.x (the surface stays fixed)
  without breaking ext-gem kernels.  See docs/authoring/HOW_TO_WRITE_KERNEL.md
  §0/§13 for the prose contract; utils/check_kernel_surface_freeze.rb
  (rake kernel_surface_check) is the mechanical pin.

    FROZEN (do NOT rename / re-arity / change semantics; additions only):
      - the author macros (CA_FOR_EACH_SLAB / _FIBER families,
        CA_SLAB_REDUCE_* / _MAP_* / _SCAN_* suites, CA_L2_FOR_EACH,
        CA_*_UNMASKED helpers)
      - the raw-API entry points the macros expand to: ca_iter_state_
        init_l2 / next_slab_axes / sync_slab / finish
      - the enum/status tokens authors write literally: CA_SLAB_AXES,
        CA_KERNEL_WRITE, CA_KERNEL_NO_MASK, CA_ITER_OK, CA_ITER_ERR_*
      - the slab-delivery representation = the ca_iter_state fields a
        kernel reads (marked "FROZEN author contract" at the struct):
        slab_ndim / slab_dims / slab_strides / slab_mask_strides /
        slab_elements / outer_ndim / outer_axes / outer_dims
      - the identifiers injected into REDUCE / MAP / STEP expressions:
        v, r, w, acc, idx, first

    INTERNAL (free to refactor across 3.x — engine implementation):
      - the state-machine functions' bodies + init_l1 / next_slab /
        next_slab_strided / ca_iter_can_alias
      - alias_mode / src_kind routing (CA_ITER_ALIAS_* / CA_ITER_SRC_* /
        CA_KERNEL_FIBER_CONTIG / CA_SLAB_FREE / CA_SLAB_WHOLE)
      - every ca_iter_state field NOT marked frozen (scratch / stack /
        fiber / composed / descriptor bookkeeping) + physical layout

  Adding new author surface is fine and expected (new flag bit, new
  _EX macro variant + thin wrapper, new catalog macro) — that is how
  the surface evolves within 3.x.  Changing or removing a FROZEN name
  is a 3.x breaking change: update the doc contract AND the guard in
  the same commit.  (PROPOSAL_T1_KERNEL_ITERATOR.md;
  devel/MEMO_KERNEL_ITERATOR_OOP_PATH.vev4.md for the planned engine
  overhaul this contract insulates against.)

  Step 1 scope (this commit):
    - struct definition (subset used by step 1; chunk_pos / scratch /
      descs / outer_idx fields are present but unused, reserved for
      later steps per proposal §3.1)
    - CA_SLAB_WHOLE policy only (single slab = whole array)
    - alias path only: ca_attach_is_alias(src) must hold, else init
      returns CA_ITER_ERR_NOT_CHEAP (renamed from ca_attach_is_cheap
      in T1 step 9.4a)
    - READ-only, no mask handling, no WRITE sync

  Later steps will fill in scratch materialize (step 2), L2 strided
  (step 3), WRITE + sync_slab (step 4), descriptor 6-view connection
  via P3 ca_axis_dispatch_for_each_slab (step 5), mask + macros
  (step 6), NO_MASK enforcement (step 7).

  --------------------------------------------------------------------------- */

#ifndef CA_KERNEL_ITERATOR_H
#define CA_KERNEL_ITERATOR_H 1

#include "carray.h"
#include "ca_iter_substrate.h"   /* ca_axis_desc_t, ca_op_prefix_axis_t */

/* ---- slab policy (proposal §2.2) ------------------------------------- */
typedef enum {
  CA_SLAB_FREE  = 0,    /* engine-chosen chunk (S1 max merge). step 2+. */
  CA_SLAB_AXES  = 1,    /* user-pinned axes inside the slab. step 5+.  */
  CA_SLAB_WHOLE = 2     /* whole array in one slab. step 1 default.    */
} ca_slab_policy_t;

/* ---- kernel flags (proposal §2.2) ------------------------------------ */
#define CA_KERNEL_READ        0x0
#define CA_KERNEL_WRITE       0x1    /* step 4+ */
#define CA_KERNEL_NO_MASK     0x2    /* step 7  */
#define CA_KERNEL_CHUNK_HINT  0x4    /* T2 reserve, never set in MVP */
#define CA_KERNEL_FIBER_CONTIG 0x8   /* PROPOSAL_FIBER_DELIVERY F.1a:
                                        when set with policy=CA_SLAB_AXES
                                        and naxes==1, next_slab_axes
                                        guarantees contig data delivery
                                        (= gathers strided fibers into
                                        fiber_data_scratch).  Set by the
                                        CA_FOR_EACH_FIBER macro family
                                        (F.2).  Direct callers that want
                                        the original L2 strided semantic
                                        (= *out_ptr is alias_ptr + offset,
                                        caller walks via slab_strides[0])
                                        leave this bit clear. */

/* ---- alias mode (proposal §3.1) -------------------------------------- */
#define CA_ITER_ALIAS_NONE     0     /* scratch materialize. step 2+.   */
#define CA_ITER_ALIAS_CONTIG   1     /* parent.ptr+offset direct slab.   */
#define CA_ITER_ALIAS_STRIDED  2     /* L2 stride-aware. step 3+.        */
#define CA_ITER_ALIAS_ATTACH   3     /* SRC_ATTACH path: view's own
                                        ca_attach materialised src->ptr,
                                        sync via ca_sync(src). step 9+.  */
#define CA_ITER_ALIAS_PER_SLAB 4     /* Phase C T3 fallback: per-slab
                                        materialise via ca_axis_dispatch_gather
                                        with subset descriptor (= caller-built
                                        outer-pinned). scratch_ptr reused
                                        across outer iters (D1.1 (B): max slab
                                        size, refilled in next_slab_axes).
                                        READ-only in C.1 (WRITE = future).  */
#define CA_ITER_ALIAS_PER_FIBER_FUSED 6 /* PROPOSAL_FIBER_PER_SOURCE_PATH
                                          F.6.1: per-fiber fused xfer
                                          dispatch.  Engine skips
                                          whole-view materialise and
                                          calls ca_xfer_stride GET/PUT
                                          per fiber, routing into the
                                          view's fused fast path (X.1
                                          OOB-fused, X.4 transform-
                                          fused).  Selected by
                                          ca_iter_should_per_fiber_fused
                                          (= hybrid src_kind + view func
                                          probe + fiber axis effective
                                          stride predicate).  Yields
                                          from fiber_data_scratch with
                                          mask in fiber_mask_scratch
                                          (= rev2 §3.3, (data,mask)
                                          pair). */
#define CA_ITER_ALIAS_STACK_OUTER_K 8 /* PROPOSAL_CASTACK_XFER_OPT_LAYERING
                                        P.2 Case A (2026-06-18): CAStack
                                        source + CA_SLAB_AXES with axis 0
                                        NOT in slab (= K-axis in outer
                                        iter, e.g. view.mean(axis: 1) /
                                        view.mean(axis: 2)).  Each slab
                                        corresponds to a region inside
                                        ONE parent selected by
                                        outer_idx[K_outer_pos].  init_l2
                                        attaches K parents (+ K parent
                                        masks if present) and caches
                                        their ptrs + uniform parent
                                        native byte strides; next_slab_
                                        axes aliases parents[k]->ptr +
                                        parent_off directly (= zero
                                        copy, zero scratch).  parent
                                        entity case = eager-equivalent
                                        memory bandwidth.  Mask aliases
                                        parent->mask similarly.  Scoped
                                        to slab_axes that exclude axis 0
                                        (= axis 0 must be an outer iter
                                        axis). */
#define CA_ITER_ALIAS_STACK    7     /* PROPOSAL_CASTACK_LOOP_INTERCHANGE
                                        Vector A rev2 (direct per-parent
                                        ptr access): CAStack source +
                                        CA_SLAB_AXES with slab_axes ==
                                        [0] (= K-axis-only slab, e.g.
                                        view.mean(axis: 0) / sum(axis: 0)).
                                        init_l2 attaches K parents up
                                        front (= O(1) per entity parent),
                                        caches parent->ptr aliases +
                                        uniform parent-native byte
                                        strides.  next_slab_axes does
                                        K-fold direct memcpy gather from
                                        parents[k]->ptr + parent_off
                                        into a slab-sized scratch,
                                        bypassing ca_xfer_stride
                                        entirely (= no per-call dispatch
                                        / cyclic_check / strided_walk
                                        function-boundary overhead).
                                        Peak buffer = K * bytes
                                        (= slab footprint), not
                                        K * parent.elements * bytes.
                                        Scope-narrow to slab_axes == [0]:
                                        arbitrary slab shapes require
                                        per-cell index decode which
                                        loses the inner contig fast
                                        path; covers the demand-driving
                                        case (= reduce along the stacked
                                        K-axis).  Mask-bearing CAStack
                                        falls back to SRC_ATTACH whole-
                                        view path (per-slab mask gather
                                        = future extension).  Rev1
                                        explored xfer_stride-based
                                        delivery (see PROPOSAL
                                        rev2 §11) and was rejected for
                                        ~16x wall-clock regression. */
#define CA_ITER_ALIAS_PER_SLAB_HOIST 5 /* Phase C T3 specialised (B-1b,
                                          C.1b): innermost slab axis is
                                          STRIDE and no SHIFT axes
                                          anywhere.  Manual gather:
                                          outer + non-innermost-slab axes
                                          hoisted (computed once per slab
                                          row), inner = pure STRIDE
                                          linear memcpy (= no engine
                                          per-cell switch, SIMD-friendly
                                          contig run).  Target: 1.5-1.8x
                                          win vs (A) fallback for INDEX
                                          slab with innermost STRIDE. */

/* ---- error codes ----------------------------------------------------- */
#define CA_ITER_OK              0
#define CA_ITER_ERR_NOT_CHEAP   1    /* src needs materialize, step 2+   */
#define CA_ITER_ERR_POLICY      2    /* policy not implemented yet       */
#define CA_ITER_ERR_FLAGS       3    /* flag combination unsupported     */
#define CA_ITER_ERR_READONLY    4    /* WRITE on readonly view (CARepeat etc.) */
#define CA_ITER_ERR_MASK        5    /* masked source — step 4-5 only, lifted in step 6 */
#define CA_ITER_ERR_MASK_NOT_ALLOWED 6  /* NO_MASK flag set on a masked source (step 7) */
#define CA_ITER_ERR_UNBOUND_SHAPE 7  /* CAUnboundRepeat passed before bind() — reserved for
                                        sub-step 9.3 (= used iff unbound CAUbrep smoke shows
                                        unsafe behavior on the existing SRC_CASTRIDE path) */

/* ---- source kind (step 5+, internal routing) ------------------------- */
#define CA_ITER_SRC_NONE       0
#define CA_ITER_SRC_CASTRIDE   1     /* entity / CAStride family (step 1-4).
                                        CAUnboundRepeat is also classified
                                        here via ca_ubrep_func = ca_stride_func. */
#define CA_ITER_SRC_DESCRIPTOR 2     /* CSA / CAGrid / CASelect / CAMapping / CAWindow / CAShift (step 5+) */
#define CA_ITER_SRC_ATTACH     3     /* CAFake / CAByteSwap / CABitfield /
                                        CABitarray / CAReduce — view's own
                                        ca_attach materialises (step 9+).  */
#define CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE 4
                                     /* F-2 (PROPOSAL_F2_KERNEL_ITERATOR_ALIAS
                                        rev6): descriptor view whose innermost
                                        axis is STRIDE kind.  init_l2 takes the
                                        alias path (= no scratch alloc, parent.ptr
                                        + outer-prefix-offset + inner-byte-start
                                        is yielded with inner_byte_stride). Only
                                        emitted by ca_iter_route_source after
                                        describe_axes inspection. */

/* ---- source-kind registration for externally installed obj_types -----

   The classifier recognises the core's own view classes by comparing
   their operation table against a list compiled into the engine.  A view
   class installed by a companion gem through ca_install_obj_type matches
   nothing on that list, so without this hook it classifies as
   CA_ITER_SRC_NONE and every kernel that goes through the iterator
   refuses the array with CA_ITER_ERR_NOT_CHEAP.  An external author
   declares the routing here instead, once, in the class's Init:

     ca_iter_register_source_kind(CA_OBJ_MY_VIEW, CA_ITER_SRC_ATTACH);

   CA_ITER_SRC_ATTACH is the only kind that may be registered.  It is the
   one whose contract an external class can meet on its own: func_attach
   materialises (or aliases) src->ptr and func_sync scatters back — the
   CAFake contract, which every view already implements to be attachable
   at all.  The other kinds are not open to registration: SRC_CASTRIDE
   asserts the struct *is* a CAStride (the engine reads its strides
   directly, and a class that really is one is already classified by its
   inherited operation table), and SRC_DESCRIPTOR requires a
   describe_axes function the engine looks up in its own table, which an
   external type has no way to supply.  Passing anything else raises
   rather than accepting a routing the iterator cannot honour.

   Registering is additive and does not override the two structural
   cases: the classifier still decides entity and CAStride-family sources
   first (both are read directly and would only be made slower by a
   materialising path), and consults this table before the built-in list.  */
void ca_iter_register_source_kind (int obj_type, uint8_t kind);

/* ---- iter state (proposal §3.1, step 1 subset) ----------------------- */
/* Fields marked "[step N+]" are present for forward layout compat but
   are zero-initialised and unused in step 1.  Adding them now avoids a
   struct-layout churn when later steps fill them in. */
typedef struct {
  /* --- inputs (fixed at init) --- */
  struct _CArray   *src;
  uint8_t           src_kind;          /* CA_ITER_SRC_* (step 5+) */
  int8_t            level;             /* 1=L1 contig, 2=L2 strided (step 3+) */
  ca_slab_policy_t  policy;
  int8_t            ndim;
  int8_t            naxes;             /* [step 5+] AXES policy axis count */
  int8_t           *axes;              /* [step 5+] [naxes]                */
  uint32_t          flags;
  ca_size_t         bytes;             /* element size                     */

  /* --- CAStride compose-fold cache (step 3+, L2 alias path) ---
     For CAStride-family sources at L2, init_l2 runs
     ca_stride_compose_to_root once to get the root entity + per-axis
     byte strides + base offset.  Cached here so next_slab_strided's
     per-iter offset calc is just Σ outer_idx[k] * composed_strides[k].
     Inline CA_RANK_MAX array (no heap alloc) since CA_DIM_MAX=16 keeps
     the footprint at 128 bytes per state. root is NULL on L1 paths
     and on L2 with an entity / contig source (use src as the base). */
  struct _CArray   *root;              /* root entity, attached at init    */
  ca_size_t         composed_strides[CA_RANK_MAX]; /* byte units           */
  ca_size_t         composed_base;     /* byte offset from root->ptr       */

  /* --- descriptor framework cache (step 5+, descriptor sources) ---
     For CSA / CAGrid / CASelect / CAMapping / CAWindow / CAShift,
     init_l1_descriptor runs the view's *_describe_axes once then
     reuses the P3 substrate (ca_axis_dispatch_prepare / _layout /
     _classify_prefix) to derive the slab layout.  Cached inline so
     next_slab walks the prefix axes without re-doing the analysis. */
  ca_axis_desc_t      descs[CA_RANK_MAX];          /* post-merge axes */
  ca_size_t           pstrides[CA_RANK_MAX];       /* parent byte strides */
  ca_size_t           mdim[CA_RANK_MAX];           /* effective parent dims */
  ca_op_prefix_axis_t prefix[CA_RANK_MAX];         /* pre-classified prefix */
  ca_size_t           parent_axis_dims[CA_RANK_MAX]; /* from describe_axes */
  int8_t              desc_ndim;
  int8_t              slab_start;                  /* prefix axes [0..slab_start) */
  ca_size_t           slab_base;                   /* slab base byte offset */
  ca_size_t           slab_bytes_desc;             /* descriptor slab span */
  ca_size_t           total_elements;              /* view.elements snapshot */

  /* --- iteration cursor --- */
  ca_size_t        *outer_idx;         /* [step 3+] [outer_axes_n]         */
  ca_size_t         slab_n;            /* current slab element count       */
  ca_size_t         total_slabs;
  ca_size_t         slabs_emitted;

  /* --- chunk position (T2 forward compat, proposal §8) --- */
  ca_size_t         chunk_pos;
  ca_size_t         chunk_size;

  /* --- scratch buffer [step 2+] --- */
  char             *scratch_ptr;
  boolean8_t       *scratch_mask;
  ca_size_t         scratch_cap;

  /* --- alias path --- */
  uint8_t           alias_mode;        /* CA_ITER_ALIAS_*                  */
  char             *alias_ptr;         /* slab ptr when alias_mode != NONE */
  boolean8_t       *alias_mask;        /* [step 6+]                        */
  ca_size_t         alias_stride;      /* [step 3+]                        */

  /* --- WRITE-path sync timing [step 4+] --- */
  uint8_t           write_dirty;

  /* --- CA_SLAB_AXES policy fields (Phase A capstone, T1) ---
     Populated when init_l2 is called with policy = CA_SLAB_AXES against
     a SRC_CASTRIDE source.  The kernel reads slab metadata directly
     from these fields (= per-walk metadata, unchanged across slabs).
     outer_axes / outer_dims / outer_strides drive the prefix walk;
     slab_axes_buf / slab_dims / slab_strides describe the K-D slab
     handed to the kernel.  All strides are byte units.  Zero-init for
     other policies (CA_SLAB_WHOLE / FREE).

     "slab_axes_buf" rather than "slab_axes" to avoid colliding with
     the existing `int8_t *axes` user-input pointer field above.

     >>> FROZEN author contract (see banner, two-tier freeze): the
     slab-delivery representation a kernel reads is exactly
       slab_ndim, slab_dims[], slab_strides[], slab_mask_strides[],
       slab_elements, outer_ndim, outer_axes[], outer_dims[].
     Do NOT rename / repurpose these — hand-written kernels and the
     mkkernel-generated bodies read them by name.  The other fields in
     this block (slab_axes_buf, outer_strides, outer_mask_strides) are
     INTERNAL bookkeeping and may be refactored.  <<< */
  int8_t            slab_ndim;
  int8_t            slab_axes_buf[CA_RANK_MAX];   /* user axes (copied, sort-ascending) */
  ca_size_t         slab_dims[CA_RANK_MAX];       /* per-slab-axis dim */
  ca_size_t         slab_strides[CA_RANK_MAX];    /* per-slab-axis data byte stride */
  ca_size_t         slab_mask_strides[CA_RANK_MAX]; /* per-slab-axis mask element stride */
  ca_size_t         slab_elements;                /* Π slab_dims */
  int8_t            outer_ndim;                   /* = src->ndim - slab_ndim */
  int8_t            outer_axes[CA_RANK_MAX];      /* complement of slab_axes_buf */
  ca_size_t         outer_dims[CA_RANK_MAX];      /* per-outer-axis dim */
  ca_size_t         outer_strides[CA_RANK_MAX];   /* per-outer-axis data byte stride */
  ca_size_t         outer_mask_strides[CA_RANK_MAX]; /* per-outer-axis mask element stride */

  /* --- Per-fiber contig scratch (PROPOSAL_FIBER_DELIVERY F.1a) ---
     For naxes==1 (= per-axis fiber, the catalog CA_FOR_EACH_FIBER target)
     in the default fall-through path of next_slab_axes (= Phase A/B alias
     + SRC_ATTACH + Phase B.1.5), when slab_strides[0] != bytes the fiber
     is yielded strided.  To honor the catalog contract "data contig
     delivery", next_slab_axes lazily allocates this scratch on first
     gather and gathers each fiber here before yielding.  Reused across
     fibers; size grows to max slab_dims[0] * bytes.

     last_data_off is captured by next_slab_axes(k) BEFORE the outer_idx
     advance, then consumed by sync_slab(k) to compute the dst base for
     WRITE scatter (= rebuilding from outer_idx in sync would duplicate
     next_slab_axes logic; see PROPOSAL §4.3.2 hazard comment).

     Phase C T3 paths (CA_ITER_ALIAS_PER_SLAB / _HOIST) yield from
     scratch_ptr (= already contig per-slab materialise) and do NOT
     touch these fields. */
  char             *fiber_data_scratch;
  ca_size_t         fiber_data_scratch_cap;
  ca_size_t         last_data_off;

  /* PROPOSAL_FIBER_DELIVERY F.1b: per-fiber contig mask scratch.
     Symmetric to fiber_data_scratch.  When the source carries a mask
     (= alias_mask != NULL) and slab_mask_strides[0] != 1, the engine
     gathers the fiber's mask into contig boolean8_t order here so the
     author can do `m[i]` without indirection.  Read-only from kernel
     POV (= L2 WRITE semantic does not propagate to mask state), so no
     scatter is needed.  See header field doc for sibling field
     fiber_data_scratch. */
  boolean8_t       *fiber_mask_scratch;
  ca_size_t         fiber_mask_scratch_cap;

  /* --- PROPOSAL_FIBER_PER_SOURCE_PATH F.6.1 substrate ---
     When alias_mode == CA_ITER_ALIAS_PER_FIBER_FUSED, next_slab_axes
     builds a fiber region from outer_idx + fiber_axis and calls
     ca_xfer_stride(src, ..., GET) into fiber_data_scratch instead of
     reading from a whole-view scratch buffer.  fiber_axis is the
     source-axis index (= same axis-space as src->dim[]) of the user-
     passed slab axis.  fiber_native_strides are row-major byte strides
     over src->dim used in ca_xfer_stride strides[] argument. */
  int8_t            fiber_axis;
  ca_size_t         fiber_native_strides[CA_RANK_MAX];
  /* fiber_region_starts[] cached by next_slab_axes BEFORE outer_idx
     advance so sync_slab can reconstruct the same ca_xfer_stride
     region for WRITE PUT.  Same hazard pattern as last_data_off
     (= F.1a). */
  ca_size_t         fiber_region_starts[CA_RANK_MAX];

  /* --- PROPOSAL_CASTACK_LOOP_INTERCHANGE Vector A rev2 (direct per-
     parent ptr access) --- */
  /* When alias_mode == CA_ITER_ALIAS_STACK, init_l2 attaches all K
     parents (= O(1) per entity parent) and caches their ptr aliases
     here so next_slab_axes can do K-fold direct memcpy gather without
     going through ca_xfer_stride.  Owned by iter (xfree in finish).
     stack_parent_strides[] are the uniform parent-native byte strides
     (= all CAStack parents are uniform shape per MEMO §3.2). */
  char            **stack_parent_ptrs;             /* [n_parents] */
  int32_t           stack_n_parents;               /* = ((CAStack *)src)->n_parents */
  ca_size_t         stack_parent_strides[CA_RANK_MAX]; /* parent-space byte strides */
  /* Parent-space element strides (= 1 byte per cell) for parent mask
     addressing; only filled when stack_parent_mask_ptrs != NULL.  Caching
     here lets next_slab_axes compute mask_off without downcasting to
     CAStack (= AC3 layering goal). */
  ca_size_t         stack_parent_mask_strides[CA_RANK_MAX];
  /* --- PROPOSAL_CASTACK_XFER_OPT_LAYERING P.2 Case A (2026-06-18) --- */
  /* When alias_mode == CA_ITER_ALIAS_STACK_OUTER_K and the CAStack
     source carries a mask, init_l2 attaches K parent masks and caches
     their ptrs here for parent->mask alias delivery alongside
     parents[k]->ptr.  NULL when source has no mask.  Owned by iter
     (xfree in finish). */
  boolean8_t      **stack_parent_mask_ptrs;        /* [n_parents] or NULL */
  /* K axis position within the outer iter axis list.  Set by init_l2
     when alias_mode == CA_ITER_ALIAS_STACK_OUTER_K; next_slab_axes uses
     outer_idx[stack_k_outer_pos] to pick the active parent. */
  int8_t            stack_k_outer_pos;
  /* --- pilot/castack-axis0-loop-interchange (2026-06-19) --- */
  /* CA_ITER_ALIAS_STACK tile cache.  Refills TILE fibers (= K cells each)
     at once via K contig parent reads, then serves the next TILE next_slab
     calls from L1d-resident buffer.  Layout: cache[t][k] so a fiber at
     tile_pos = cache + tile_pos * K * bytes (matches slab_strides[0] =
     bytes).  Tile capacity sized to fit ~32 KB L1d budget; current refill
     length clamped to remaining slabs.  Owned by iter (xfree in finish). */
  char             *stack_tile_cache;     /* K * stack_tile_cap * bytes */
  ca_size_t         stack_tile_cap;       /* TILE = fibers per refill (0 = disabled) */
  ca_size_t         stack_tile_pos;       /* 0..stack_tile_have-1 (= ready); ==have triggers refill */
  ca_size_t         stack_tile_have;      /* fibers actually present in current tile */
} ca_iter_state;

/* ---- alias eligibility predicate (proposal §11.3) ------------------- */

/* Generalises ca_attach_is_alias (carray_core.c:410, renamed from
   ca_attach_is_cheap in T1 step 9.4a) so the alias decision can be
   made level-aware.  Level is the dispatch level the caller intends
   to use:

     level == 1  (L1, contig kernel)
       Alias iff parent->ptr can be handed to the kernel as one contig
       run with stride implicit = bytes.  True for entity arrays and
       CAStride-family views whose composed strides are row-major
       contiguous — exactly ca_attach_is_alias's domain.

     level == 2  (L2, strided kernel)
       Alias iff the engine can yield per-outer-axis slabs as
       parent->ptr + offset with a native stride_bytes argument, with
       no scratch allocation.  Broader than L1: any CAStride-family
       view qualifies (the innermost run, even a stride-of-1 of count 1,
       defines a valid strided slab).  Entity arrays also qualify
       trivially.  Pathological all-strided-no-contig sources still
       qualify here — the engine yields slab_n=1 with the native step;
       L1 fallback is an engine-policy choice, not an eligibility one.

     level == 3  (L3, multi-d kernel)
       Not implemented in Phase 1 — falls back to L1 semantics so the predicate
       stays well-defined for callers that probe ahead.

   Descriptor framework views (CAGrid / CASelect / CAMapping / CAWindow /
   CAShift / CSA) and overlay views (CAFake / CAByteSwap / CABitfield /
   CABitarray) return 0 at every level; their alias story lands in
   step 5 (descriptor connection via ca_axis_dispatch_for_each_slab).

   ca_attach_is_alias is retained as the level=1 oracle for the Tier A
   (PROPOSAL_DELEGATE_COPY_DATA) defer site; callers that already use
   it keep working unchanged.  New code in the kernel_iterator path
   should call ca_iter_can_alias with an explicit level. */
int  ca_iter_can_alias (void *ap, int level);

/* ---- state machine (proposal §3.2) ---------------------------------- */

/* Initialise `st` for an **L1 (contig kernel)** walk of `src`.

   Source routing:
     - entity / CAStride contig: alias path (single slab, alias_ptr =
       src->ptr, stride implicit = bytes)
     - CAStride family non-contig: scratch path (ca_copy_data
       compose-fold gather into a malloc'd buffer)
     - other sources: CA_ITER_ERR_NOT_CHEAP

   policy: only CA_SLAB_WHOLE accepted in step 1-3.
   flags:  must be 0 (READ) until step 4 / 7.

   On success returns CA_ITER_OK; on error returns CA_ITER_ERR_*
   without claiming resources (finish need not be called).

   Pair with ca_iter_state_next_slab.  Step 3 split init into
   level-specific entry points so each setup path stays focused
   (proposal §3.2 rev: original single-init was relaxed when L2 setup
   diverged enough to warrant its own state initialiser; see
   ROADMAP/CHANGELOG rev). */
int  ca_iter_state_init_l1 (ca_iter_state    *st,
                            struct _CArray   *src,
                            ca_slab_policy_t  policy,
                            int8_t           *axes,
                            int8_t            naxes,
                            uint32_t          flags);

/* Initialise `st` for an **L2 (strided kernel)** walk of `src`.

   Source routing:
     - entity / CAStride contig: alias_mode = CONTIG, single slab,
       stride = bytes (kernel still receives the explicit stride arg)
     - CAStride non-contig: alias_mode = STRIDED, multi-slab walk over
       prefix axes, each yield carries native inner stride_bytes. No
       scratch.
     - other sources: CA_ITER_ERR_NOT_CHEAP

   Other args match init_l1.  Pair with ca_iter_state_next_slab_strided. */
int  ca_iter_state_init_l2 (ca_iter_state    *st,
                            struct _CArray   *src,
                            ca_slab_policy_t  policy,
                            int8_t           *axes,
                            int8_t            naxes,
                            uint32_t          flags);

/* Pull the next L1 slab.  Returns 1 and writes *out_ptr / *out_mask /
   *out_n when a slab is yielded; returns 0 when the walk is complete.
   After a 0 return, subsequent calls also return 0.  Only valid when
   init_l1 was used.

   *out_mask is set to the per-slab boolean8_t mask pointer when the
   source carries a mask (= ca_has_mask(src)), or NULL otherwise.
   The mask layout matches the value layout (= same iteration order
   and same n).  Step 6+: kernels use the CA_FOR_EACH_UNMASKED macro
   family (carray.h) to skip masked cells. */
int  ca_iter_state_next_slab (ca_iter_state *st,
                              char         **out_ptr,
                              boolean8_t   **out_mask,
                              ca_size_t     *out_n);

/* Pull the next L2 strided slab.  Returns 1 with *out_ptr /
   *out_mask / *out_n / *out_stride_bytes when a slab is yielded;
   returns 0 when the walk is complete.  The kernel walks `*out_n`
   elements by stepping `*out_stride_bytes` between consecutive
   elements starting at `*out_ptr`; the mask uses the **same stride
   semantics** when non-NULL (= each mask byte at offset i * stride is
   conceptually paired with the value at ptr + i * stride_bytes, but
   since mask is boolean8_t == 1 byte, mask stride is 1 byte when the
   value stride is bytes, and proportional otherwise).  Only valid
   when init_l2 was used. */
int  ca_iter_state_next_slab_strided (ca_iter_state *st,
                                      char         **out_ptr,
                                      boolean8_t   **out_mask,
                                      ca_size_t     *out_n,
                                      ca_size_t     *out_stride_bytes);

/* Pull the next CA_SLAB_AXES slab (K-D block).  Returns 1 with *out_ptr
   / *out_mask set to the slab base when a slab is yielded; returns 0
   when the walk is complete.  Only valid when init_l2 was called with
   policy = CA_SLAB_AXES.

   Slab shape and strides are constant across the walk (per-walk
   metadata) — the kernel reads them directly from the state struct:
     st->slab_ndim              (number of slab axes)
     st->slab_dims[k]           (size along slab axis k, k in [0..slab_ndim))
     st->slab_strides[k]        (data byte stride along slab axis k)
     st->slab_mask_strides[k]   (mask element stride along slab axis k)
     st->slab_elements          (Π slab_dims, total cells per slab)

   *out_mask is the per-slab mask base when ca_has_mask(src), NULL
   otherwise.  Mask uses 1-byte boolean8_t per element.  Data and mask
   strides are independent so kernels can handle masked CAStride
   non-contig sources correctly (= mask scratch is gathered in view
   row-major order via ca_copy_data, whereas data strides may walk the
   parent entity through a non-row-major composed path).

   The slab walk pattern in kernel code (= roadmap §1.1 idealized form):
     while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
       acc_t acc = 0;
       // K-D walk: for each (s0..s_{K-1}) in slab_dims:
       //   data_off = Σ s_k * slab_strides[k]
       //   mask_off = Σ s_k * slab_mask_strides[k]
       //   if (m == NULL || !m[mask_off]) acc += *(T *)(p + data_off)
       op[out_i++] = acc;
     } */
int  ca_iter_state_next_slab_axes (ca_iter_state *st,
                                   char         **out_ptr,
                                   boolean8_t   **out_mask);

/* Sync the just-yielded slab back to parent (WRITE path; READ no-op).

   Caller calls this **unconditionally** after each next_slab /
   next_slab_strided + kernel invocation; the alias_mode branch lives
   inside the state machine so the caller never has to inspect it.

   Behaviour (proposal PROPOSAL_T1_WRITE_SEMANTICS.md §(b)):
     - !(flags & CA_KERNEL_WRITE): no-op (READ walk)
     - alias path (scratch_ptr == NULL): no-op — kernel wrote to
       parent directly through alias_ptr (case A semantics)
     - scratch path (L1 only by step-4 invariant): scatter back via
       ca_sync_data(src, scratch). L2 scratch is structurally
       unreachable in step 4 (CAStride only) and is guarded by an
       assert; step 5 re-evaluation noted in the proposal. */
void ca_iter_state_sync_slab (ca_iter_state *st);

/* Release any resources held by `st` and detach parent.  Safe to call
   exactly once after a successful init (either level). */
void ca_iter_state_finish (ca_iter_state *st);

/* ---- Phase C C.3: kernel author block macros ------------------------
   (PROPOSAL_CAPSTONE_PHASE_C.md D3.1 (A) do/while/for + D3.2 (C) 2 kinds)

   Wrap init_l2 / next_slab_axes / [sync_slab] / finish in a single
   block scope so kernel authors don't write lifecycle plumbing.

   --- Constraints ---

   - Author must pre-declare `char *p` and `boolean8_t *m` (or names of
     their choice).  C99 doesn't permit two different-typed declarations
     in a `for` init clause, so the slab/mask cursors live in the
     surrounding scope.
   - `flags` arg propagates to init_l2 (= CA_KERNEL_WRITE supported).
     `sync_slab` is called automatically after each iteration; it's a
     no-op when WRITE flag is absent.
   - Init failure (ca_iter_state_init_l2 returns CA_ITER_ERR_*) is
     silently discarded: the body runs zero times and finish is still
     called.  Production kernels that need explicit error messages
     (e.g., sum_ki's rc=%d raise) should drop down to the raw API
     instead of using this macro.
   - `break;` from inside the body exits the loop AND triggers finish
     correctly (= outer for's "increment" clause runs once on natural
     exit; `break` from the inner while breaks both).  `return` inside
     the body LEAKS resources (scratch_ptr, parent attach) — drop to
     raw API if early return is needed.
   - Macros are not statement-equivalent (= they expand to nested for
     constructs).  Don't follow them with `else` etc. */

/* ---- T1 kernel_iterator mask helper macros (step 6+) ---------------------
   These macros let kernel_iterator kernels handle masked sources
   uniformly: pass NULL for `mask` if the source has no mask (= treat
   all cells as unmasked), or a `boolean8_t *` of length n where
   non-zero entries indicate masked (= "skip this cell").

   PROPOSAL_T1_KERNEL_ITERATOR.md §2.4.  GCC statement-expression for
   CA_COUNT_UNMASKED is GCC/Clang only (MSVC not in scope).
   --------------------------------------------------------------------- */

#define CA_FOR_EACH_UNMASKED(p, mask, n, body) do { \
    ca_size_t _ca_i; \
    if (mask) { \
        for (_ca_i = 0; _ca_i < (n); _ca_i++) if (!(mask)[_ca_i]) { body } \
    } else { \
        for (_ca_i = 0; _ca_i < (n); _ca_i++) { body } \
    } \
} while (0)

#define CA_FOR_EACH_INDEX_UNMASKED(p, mask, n, i, body) do { \
    if (mask) { \
        for (ca_size_t i = 0; i < (n); i++) if (!(mask)[i]) { body } \
    } else { \
        for (ca_size_t i = 0; i < (n); i++) { body } \
    } \
} while (0)

#define CA_COUNT_UNMASKED(mask, n) ({ \
    ca_size_t _ca_cnt = 0; \
    ca_size_t _ca_n   = (n); \
    if (mask) { \
        for (ca_size_t _ca_i = 0; _ca_i < _ca_n; _ca_i++) \
            if (!(mask)[_ca_i]) _ca_cnt++; \
    } else { \
        _ca_cnt = _ca_n; \
    } \
    _ca_cnt; \
})

#define CA_MASK_GET(mask, i) ((mask) ? (mask)[i] : 0)

/* ---- L2 inner-loop macros (step 8+) -----------------------------------
   `CA_L2_FOR_EACH(T, ptr, n, stride, p, body)` and its unmasked sibling
   wrap the strided callback signature `(ptr, n, stride_bytes)` with a
   `stride == sizeof(T)` fast-path branch.  When the runtime stride
   matches the element size, `body` runs against a `T *p` that the
   compiler can autovectorise; when it doesn't, `p` is recomputed per
   iteration with the runtime stride.

   The split is intentional: L2 strided callbacks are deliberately
   universal — they accept arbitrary stride and so the compiler cannot
   prove contig on the kernel-side loop.  When the iterator hands a
   contig scratch (= descriptor materialise path, stride == bytes), the
   universal-dispatch cost (step 5.5 §10.4.5) shows up as an 18-22%
   SIMD inhibition on the kernel.  These macros let kernel authors recover
   the contig autovectorisation without giving up the L2 surface.

   This is the standard pattern for L2 kernels: write the body once,
   the macro picks the right loop shape.  Step 8 verifies the speed-up
   empirically; the framing (universal dispatch is the abstraction,
   kernel-side macros are the speed knob) is `PROPOSAL_T1_KERNEL_
   ITERATOR.md` §13.1.

   Usage:
     CA_L2_FOR_EACH(double, ptr, n, stride, p, {
         *p = value;          // p is `double *`
     });

   GCC / Clang only (block expressions and per-iteration variable
   declarations inside a macro). */

#define CA_L2_FOR_EACH(T, ptr, n, stride, p, body) do { \
    ca_size_t   _l2_n = (n); \
    ca_size_t   _l2_s = (stride); \
    char       *_l2_b = (char *)(ptr); \
    if (_l2_s == sizeof(T)) { \
        T *p = (T *)_l2_b; \
        for (ca_size_t _l2_i = 0; _l2_i < _l2_n; _l2_i++) { \
            body \
            p++; \
        } \
    } else { \
        for (ca_size_t _l2_i = 0; _l2_i < _l2_n; _l2_i++) { \
            T *p = (T *)(_l2_b + _l2_i * _l2_s); \
            body \
        } \
    } \
} while (0)

#define CA_L2_FOR_EACH_UNMASKED(T, ptr, mask, n, stride, p, body) do { \
    ca_size_t   _l2_n = (n); \
    ca_size_t   _l2_s = (stride); \
    char       *_l2_b = (char *)(ptr); \
    boolean8_t *_l2_m = (mask); \
    if (_l2_s == sizeof(T)) { \
        T *p = (T *)_l2_b; \
        if (_l2_m) { \
            for (ca_size_t _l2_i = 0; _l2_i < _l2_n; _l2_i++) { \
                if (!_l2_m[_l2_i]) { body } \
                p++; \
            } \
        } else { \
            for (ca_size_t _l2_i = 0; _l2_i < _l2_n; _l2_i++) { \
                body \
                p++; \
            } \
        } \
    } else { \
        if (_l2_m) { \
            for (ca_size_t _l2_i = 0; _l2_i < _l2_n; _l2_i++) { \
                T *p = (T *)(_l2_b + _l2_i * _l2_s); \
                if (!_l2_m[_l2_i]) { body } \
            } \
        } else { \
            for (ca_size_t _l2_i = 0; _l2_i < _l2_n; _l2_i++) { \
                T *p = (T *)(_l2_b + _l2_i * _l2_s); \
                body \
            } \
        } \
    } \
} while (0)

/* The slab policy is fixed to CA_SLAB_AXES (the only policy compatible
   with next_slab_axes); it is hardcoded inside the macro rather than
   taken as an argument, so block-macro authors never type the policy
   enum (symmetry with the CA_FOR_EACH_FIBER family, and one less
   always-constant argument).  CA_SLAB_AXES is still FROZEN, because
   raw-API kernels pass it to ca_iter_state_init_l2 directly. */
#define CA_FOR_EACH_SLAB(st, ca, axes, naxes, flags, p, m)                    \
  for ( int __caf_init = (ca_iter_state_init_l2(&(st), (ca), CA_SLAB_AXES,    \
                                                (axes), (naxes), (flags)),    \
                          1);                                                 \
        __caf_init;                                                           \
        __caf_init = 0, ca_iter_state_finish(&(st)) )                         \
    for ( ; ca_iter_state_next_slab_axes(&(st), &(p), &(m));                  \
            ca_iter_state_sync_slab(&(st)) )

/* CA_FOR_EACH_SLAB_INOUT: parallel iter for map kernels (= input view
   + same-shape output view).  Author pre-declares two state structs,
   two slab cursors, two mask cursors.  Input iter runs READ-only,
   output iter runs WRITE; sync_slab is called on output after each
   body iteration.

   Shape mismatch between ca_in / ca_out is NOT validated by the macro
   — caller responsibility (= typically output is `rb_ca_template_with_type`
   of input, guaranteeing same shape).  Init failure on either iter
   silently skips the body. */
/* Policy fixed to CA_SLAB_AXES internally — see CA_FOR_EACH_SLAB above. */
#define CA_FOR_EACH_SLAB_INOUT(st_in, st_out, ca_in, ca_out,                  \
                               axes, naxes,                                   \
                               p_in, p_out, m_in, m_out)                      \
  for ( int __cafi_init = (                                                   \
            ca_iter_state_init_l2(&(st_in),  (ca_in),  CA_SLAB_AXES,          \
                                  (axes), (naxes), 0),                        \
            ca_iter_state_init_l2(&(st_out), (ca_out), CA_SLAB_AXES,          \
                                  (axes), (naxes), CA_KERNEL_WRITE),          \
            1);                                                               \
        __cafi_init;                                                          \
        __cafi_init = 0,                                                      \
          ca_iter_state_finish(&(st_in)),                                     \
          ca_iter_state_finish(&(st_out)) )                                   \
    for ( ; ca_iter_state_next_slab_axes(&(st_in),  &(p_in),  &(m_in)) &&     \
            ca_iter_state_next_slab_axes(&(st_out), &(p_out), &(m_out));      \
            ca_iter_state_sync_slab(&(st_out)) )

/* ---- PROPOSAL_FIBER_DELIVERY F.2: per-axis fiber catalog macros ----
   (rev4 §3 catalog contract)

   Author-facing surface for "deliver one contig fiber along `axis` to
   the kernel".  Contig delivery is contract:
     - data: contig (= author writes p[i] / p_out[i] without stride math)
     - mask (MASKED forms): contig (= author writes m[i]; m is NULL for
       no-mask source, author NULL-checks before access)
     - output (INOUT forms): contig same as data; CA_KERNEL_WRITE auto-set

   The CA_KERNEL_FIBER_CONTIG flag is auto-set; engine gathers strided
   fibers into per-state scratch when slab_strides[0] != bytes (= F.1a/b).

   `axis` is evaluated ONCE into a stack-local int8 buffer of static
   storage scope; `ca`/`ca_in`/`ca_out` are evaluated ONCE in init.
   `n` is set to the fiber length (= slab_dims[0], constant per walk).

   Same constraints as CA_FOR_EACH_SLAB family:
     - `break;` from body exits cleanly (finish runs).
     - `return;` from body LEAKS scratch / parent attach -- use raw API.
     - Macros are NOT statement-equivalent (nested for); no trailing else.

   INOUT forms (form 2 / 4) require STRICT FULL SHAPE EQUALITY of
   `ca_in` and `ca_out` (= ndim + every dim[k] match).  Mismatch is a
   silent-corruption seam (= short-circuit fiber-count drop, k-th
   pairing corruption); init_l2 does not validate it itself, so the
   macros runtime-assert shape equality and skip body on mismatch.
   Authors that need broadcasting must drop to raw API. */

#define CA_FOR_EACH_FIBER(st, ca, axis, flags, p, n)                          \
  for ( int __cff_init = (                                                    \
            ca_iter_state_init_l2(&(st), (ca), CA_SLAB_AXES,                  \
                                  (int8_t[]){(int8_t)(axis)}, 1,              \
                                  (flags) | CA_KERNEL_FIBER_CONTIG),          \
            (n) = (st).slab_dims[0],                                          \
            1);                                                               \
        __cff_init;                                                           \
        __cff_init = 0, ca_iter_state_finish(&(st)) )                         \
    for ( ; ca_iter_state_next_slab_axes(&(st), &(p), NULL);                  \
            ca_iter_state_sync_slab(&(st)) )

#define CA_FOR_EACH_FIBER_MASKED(st, ca, axis, flags, p, n, m)                \
  for ( int __cffm_init = (                                                   \
            ca_iter_state_init_l2(&(st), (ca), CA_SLAB_AXES,                  \
                                  (int8_t[]){(int8_t)(axis)}, 1,              \
                                  (flags) | CA_KERNEL_FIBER_CONTIG),          \
            (n) = (st).slab_dims[0],                                          \
            1);                                                               \
        __cffm_init;                                                          \
        __cffm_init = 0, ca_iter_state_finish(&(st)) )                        \
    for ( ; ca_iter_state_next_slab_axes(&(st), &(p), &(m));                  \
            ca_iter_state_sync_slab(&(st)) )

/* INOUT form 2 (NO_MASK).  Output gets CA_KERNEL_WRITE auto-set.

   STRICT FULL SHAPE EQUALITY (rev4 §2.3): the inner for-condition
   re-evaluates ca_in->ndim == ca_out->ndim and dim[axis] equality (=
   minimal seam coverage given the macro can't loop over k).  Full
   per-axis equality lives one level up in the init-time short-circuit
   below: we compare elements + ndim + axis dim, which catches the
   common silent-corruption seam (= e.g. (3,5) vs (4,5) axis=1 with
   matching fiber length but different fiber count).  Comprehensive
   per-dim check is the caller's responsibility for now (= simpler than
   building a per-dim k loop into a macro; ext authors can drop to raw
   API for arbitrary broadcasting designs). */
#define CA_FOR_EACH_FIBER_INOUT(st_in, st_out, ca_in, ca_out, axis,           \
                                flags, p_in, p_out, n)                        \
  for ( int __cffi_init = (                                                   \
            ca_iter_state_init_l2(&(st_in),  (ca_in),  CA_SLAB_AXES,          \
                                  (int8_t[]){(int8_t)(axis)}, 1,              \
                                  (flags) | CA_KERNEL_FIBER_CONTIG),          \
            ca_iter_state_init_l2(&(st_out), (ca_out), CA_SLAB_AXES,          \
                                  (int8_t[]){(int8_t)(axis)}, 1,              \
                                  ((flags) | CA_KERNEL_FIBER_CONTIG           \
                                           | CA_KERNEL_WRITE)),               \
            (n) = (st_in).slab_dims[0],                                       \
            1);                                                               \
        __cffi_init;                                                          \
        __cffi_init = 0,                                                      \
          ca_iter_state_finish(&(st_in)),                                     \
          ca_iter_state_finish(&(st_out)) )                                   \
    for ( ; (st_in).src->ndim == (st_out).src->ndim                           \
         && (st_in).src->elements == (st_out).src->elements                   \
         && (st_in).slab_dims[0] == (st_out).slab_dims[0]                     \
         && ca_iter_state_next_slab_axes(&(st_in),  &(p_in),  NULL)           \
         && ca_iter_state_next_slab_axes(&(st_out), &(p_out), NULL);          \
            ca_iter_state_sync_slab(&(st_in)),                                \
            ca_iter_state_sync_slab(&(st_out)) )

#define CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, ca_in, ca_out, axis,    \
                                       flags, p_in, p_out, n, m)              \
  for ( int __cffim_init = (                                                  \
            ca_iter_state_init_l2(&(st_in),  (ca_in),  CA_SLAB_AXES,          \
                                  (int8_t[]){(int8_t)(axis)}, 1,              \
                                  (flags) | CA_KERNEL_FIBER_CONTIG),          \
            ca_iter_state_init_l2(&(st_out), (ca_out), CA_SLAB_AXES,          \
                                  (int8_t[]){(int8_t)(axis)}, 1,              \
                                  ((flags) | CA_KERNEL_FIBER_CONTIG           \
                                           | CA_KERNEL_WRITE)),               \
            (n) = (st_in).slab_dims[0],                                       \
            1);                                                               \
        __cffim_init;                                                         \
        __cffim_init = 0,                                                     \
          ca_iter_state_finish(&(st_in)),                                     \
          ca_iter_state_finish(&(st_out)) )                                   \
    for ( ; (st_in).src->ndim == (st_out).src->ndim                           \
         && (st_in).src->elements == (st_out).src->elements                   \
         && (st_in).slab_dims[0] == (st_out).slab_dims[0]                     \
         && ca_iter_state_next_slab_axes(&(st_in),  &(p_in),  &(m))           \
         && ca_iter_state_next_slab_axes(&(st_out), &(p_out), NULL);          \
            ca_iter_state_sync_slab(&(st_in)),                                \
            ca_iter_state_sync_slab(&(st_out)) )

/* ---- Phase D: per-data_type reduction macro suite ----------------------- */

/* CA_SLAB_REDUCE_T(T, ...): generic per-data_type slab reduction.  T is the
   element load type (`double`, `float`, `int32_t`, `int64_t`, ...).
   The accumulator `acc` is supplied by the caller and may be a wider
   type — the macro binds `v` as T and lets REDUCE handle implicit
   widening (e.g., int32 source → int64 acc via `acc += v`).

   Canonical inner walk: outer K-1 carry + innermost SIMD-friendly
   inner loop, with mask + contig-stride dispatch hoisted out of the
   inner iteration.

   Author-supplied:
     - T:          element C type (load type).  `sizeof(T)` is used
                   for the contig-stride check.
     - acc:        lvalue (any numeric type) — receives the result;
                   initialised to (INIT) at macro entry.
     - INIT:       initial value expression (e.g., 0, 0.0, -INFINITY).
     - REDUCE:     statement folding `v` (the current element, type T)
                   into `acc`.  Example: `acc += v` for sum,
                   `if (v > acc) acc = v` for max.

   Engine-supplied (from CA_FOR_EACH_SLAB / ca_iter_state_next_slab_axes):
     - st:         ca_iter_state, already positioned on the current slab.
     - p:          slab data pointer (char *).
     - m:          slab mask pointer (boolean8_t *, may be NULL).

   Convenience aliases (defined below): CA_SLAB_REDUCE_F64, _F32, _I32,
   _I64.  Use those when the load type is one of the standard four
   numerics; use CA_SLAB_REDUCE_T directly for less common types
   (boolean8_t, int8_t, uint16_t, ...).

   Mask semantics: when m != NULL, masked cells are skipped (REDUCE is
   not invoked).  When m == NULL, every cell contributes.

   For slab_ndim == 1 this collapses to a single inner loop.  For
   slab_ndim >= 2 the outer K-1 axes carry-walk row-major and the
   innermost axis stays the SIMD leaf.

   `idx` (ca_size_t) is exposed to the REDUCE expression as the
   flat slab-row-major index of the current cell (0 .. slab_elements-1).
   It increments per cell regardless of mask state, so REDUCE can use
   it for position-sensitive reductions like argmin / argmax even when
   some cells are masked out.  Kernels that don't reference `idx` get
   it dead-code-eliminated; the trailing `(void) idx;` silences any
   set-but-not-used warnings. */
#define CA_SLAB_REDUCE_T_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    /* Slab-collapse: when the whole K-D slab is row-major contiguous       \
       (data, and mask if present), fold all slab axes into one flat        \
       inner loop.  Removes the per-outer multi-index offset recompute +    \
       carry that otherwise dominates when the innermost slab axis is       \
       small (full reduction of [N,1] / [N,small] entity, or trailing-      \
       contig multi-axis reduce).  Platform-general: structural, not SIMD.  \
       No-op for 1-D slabs (__srOuterK == 0 leaves __srOC == 1). */         \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    ca_size_t idx         = 0;                                               \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              T v = __srSrc[__sj];                                           \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const T *)(__srQ + __sj * __srInnerS);                 \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
    (void) idx;                                                              \
  } while (0)

/* Backward-compatible wrapper that hides masked_cnt from kernels that
   don't need it.  Existing kernels (sum / mean / min / argmin / ...)
   continue to use CA_SLAB_REDUCE_T unchanged; only mask-policy-aware
   kernels reach for CA_SLAB_REDUCE_T_EX. */
#define CA_SLAB_REDUCE_T(T, st, p, m, acc, INIT, REDUCE) do {                \
    ca_size_t __sr_throwaway_mc = 0;                                         \
    CA_SLAB_REDUCE_T_EX(T, st, p, m, acc, INIT, REDUCE, __sr_throwaway_mc);  \
    (void) __sr_throwaway_mc;                                                \
  } while (0)

/* ----------------------------------------------------------------------
 * SIMD-licensed reduction variants (SL.1.0 stubs)
 *
 * The PLUS/MIN/MAX/STAR/VAR _EX variants below are the SIMD-license
 * vehicle introduced by PROPOSAL_REDUCTION_SIMD_LICENSE.  In Phase
 * SL.1.0 they are wired-but-inert: each variant currently forwards to
 * CA_SLAB_REDUCE_T_EX so DSL plumbing (mkkernel reduction_kind:) can
 * be exercised without any kernel behavior change.
 *
 * Subsequent sub-steps (SL.1.1+) will replace each forward with a
 * contig-branch body carrying `#pragma omp simd reduction(<kind>:acc)`
 * (and per-acc pragmas for VAR).  The pragma is emitted via the
 * _Pragma + _CA_XSTR substitution helpers below so the acc lvalue
 * can be parameterised.
 *
 * The pragma is a no-op on compilers that don't support `-fopenmp-simd`
 * (extconf.rb probe — graceful degradation, code stays correct).
 *
 * Q1-Q6 closure (sparring round 1 2026-06-12): see proposal §5.
 * --------------------------------------------------------------------*/

#define _CA_STR(x)        #x
#define _CA_XSTR(x)       _CA_STR(x)
#define _CA_SIMD_PLUS(var)  _Pragma(_CA_XSTR(omp simd reduction(+:var)))
#define _CA_SIMD_MIN(var)   _Pragma(_CA_XSTR(omp simd reduction(min:var)))
#define _CA_SIMD_MAX(var)   _Pragma(_CA_XSTR(omp simd reduction(max:var)))
#define _CA_SIMD_STAR(var)  _Pragma(_CA_XSTR(omp simd reduction(*:var)))

/* CA_SLAB_REDUCE_T_PLUS_EX (SL.1.1):
 *   Same structure as CA_SLAB_REDUCE_T_EX, but the **no-mask + contig**
 *   inner loop carries `#pragma omp simd reduction(+:acc)` so clang/gcc
 *   are licensed to reassoc the accumulator and emit SIMD reduction
 *   sequences.  All other branches (masked-contig, non-contig, masked-
 *   non-contig) are byte-identical to _EX — proposal §2.2 defers
 *   strided/masked SIMD to Phase 2 (output-buffered loop interchange).
 *
 *   PoC (2026-06-12): N=1M f64 sum 906 us -> 116 us (= 7.8x, 68.8 GB/s).
 *   Parity: ε-close (relative error < 2e-16 for f64 sum), bit-exact
 *   not guaranteed (= reassoc license, documented in CLAUDE.md
 *   ε-close policy section, SL.1.5).
 *
 *   Other state vars referenced inside REDUCE (induction counters
 *   like `cnt`, position counters like `idx`) are auto-vectorised
 *   by the compiler when their update is a simple ++ pattern.
 */
#define CA_SLAB_REDUCE_T_PLUS_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    /* Slab-collapse: when the whole K-D slab is row-major contiguous       \
       (data, and mask if present), fold all slab axes into one flat        \
       inner loop.  Removes the per-outer multi-index offset recompute +    \
       carry that otherwise dominates when the innermost slab axis is       \
       small (full reduction of [N,1] / [N,small] entity, or trailing-      \
       contig multi-axis reduce).  Platform-general: structural, not SIMD.  \
       No-op for 1-D slabs (__srOuterK == 0 leaves __srOC == 1). */         \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    ca_size_t idx         = 0;                                               \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          _CA_SIMD_PLUS(acc)                                                 \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              T v = __srSrc[__sj];                                           \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const T *)(__srQ + __sj * __srInnerS);                 \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
    (void) idx;                                                              \
  } while (0)

/* CA_SLAB_REDUCE_SUM8_EX (variance/stddev regression fix, 2026-07-18):
 *   8-way manual accumulator split for the no-mask + contig inner loop.
 *
 *   Why: GCC 11.5 with -march=native (FMA) does NOT split the pragma-simd
 *   reduction of the centred Pass 2 (M2 += (v-mean)^2) into multiple
 *   accumulators -- it fuses mul+add into a single `vfmadd231sd` whose
 *   result feeds the next iteration, a single dependency chain that is
 *   latency-bound (~1 elem per FMA latency, 4-6 cycles).  perf on
 *   i7-14700K measured variance_flatten 100% scalar in both SSE2 and AVX2
 *   builds, with the AVX2 FMA form 2.8x slower on Pass 2 -> 1.76x overall
 *   regression vs SSE2 (mul+add, whose add-only recurrence overlaps
 *   better).  Writing 8 explicit accumulators gives the compiler 8
 *   independent chains, hiding the latency on any FADD/FMA-latency arch
 *   (Golden Cove / Zen4 FMA latency 4, headroom for 6).
 *
 *   EXPR(x) is a function-like macro producing the per-element contribution
 *   (Pass 1: (double)(x); Pass 2: ((double)(x)-mean)*((double)(x)-mean)).
 *   Reassoc across the 8 lanes is the same ε-close license as _PLUS_EX
 *   (bit-exact not guaranteed; CLAUDE.md ε-close policy, SL.1.5).
 *
 *   Only the no-mask + contig branch is 8-way; masked / non-contig
 *   branches stay single-accumulator (not the hot path).  Position
 *   counter `idx` is not tracked (variance REDUCE never uses it).  ACC_T
 *   is the accumulator C type (double for Pass 1 sum on numeric/bool and
 *   Pass 2 M2; complex Pass 1 passes its complex type).  Used only by the
 *   two_pass_centred emitter in mkkernel.rb.
 */
#define CA_SLAB_REDUCE_SUM8_EX(T, ACC_T, st, p, m, acc, INIT, EXPR, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          ACC_T __a0=(ACC_T)0,__a1=(ACC_T)0,__a2=(ACC_T)0,__a3=(ACC_T)0;     \
          ACC_T __a4=(ACC_T)0,__a5=(ACC_T)0,__a6=(ACC_T)0,__a7=(ACC_T)0;     \
          ca_size_t __sj = 0, __sN = __srInnerN;                             \
          for ( ; __sj + 8 <= __sN; __sj += 8 ) {                           \
            __a0 += EXPR(__srSrc[__sj + 0]);                                 \
            __a1 += EXPR(__srSrc[__sj + 1]);                                 \
            __a2 += EXPR(__srSrc[__sj + 2]);                                 \
            __a3 += EXPR(__srSrc[__sj + 3]);                                 \
            __a4 += EXPR(__srSrc[__sj + 4]);                                 \
            __a5 += EXPR(__srSrc[__sj + 5]);                                 \
            __a6 += EXPR(__srSrc[__sj + 6]);                                 \
            __a7 += EXPR(__srSrc[__sj + 7]);                                 \
          }                                                                  \
          for ( ; __sj < __sN; __sj++ ) __a0 += EXPR(__srSrc[__sj]);         \
          (acc) += ((__a0 + __a1) + (__a2 + __a3))                           \
                 + ((__a4 + __a5) + (__a6 + __a7));                          \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const T *)(__srQ + __sj * __srInnerS);                   \
            (acc) += EXPR(v);                                                \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) { T v = __srSrc[__sj]; (acc) += EXPR(v); } \
            else { (masked_cnt)++; }                                         \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const T *)(__srQ + __sj * __srInnerS);                 \
              (acc) += EXPR(v);                                              \
            } else { (masked_cnt)++; }                                       \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
  } while (0)

/* CA_SLAB_REDUCE_MIN8_EX / _MAX8_EX / _STAR8_EX
 * (horizontal extension of the SUM8_EX pattern to standard reducers,
 *  2026-07-19):
 *
 * Same rationale as SUM8_EX — GCC does not split single-accumulator pragma
 * reductions into multiple independent chains on FMA/FADD-latency-bound
 * paths, so we write 8 explicit accumulators in source.  On i7-14700K
 * the standalone sum kernel was measured at ~15.9 GB/s (scalar with
 * compiler-auto-unroll) while variance per-pass reached ~58.9 GB/s after
 * its SUM8_EX fix — the standalone reducers had the same headroom
 * available.  Applying SUM8/MIN8/MAX8/STAR8 to sum/mean/min/max/prod
 * closes the gap.  Only the no-mask+contig branch is 8-way; masked /
 * non-contig / object stay single-accumulator (not the hot path).
 *
 * Interface parallels SUM8_EX: EXPR(x) is a function-like macro
 * producing the value to reduce (typically `((ACC_T)(x))`), so the
 * caller controls the per-src cast without embedding it in a REDUCE
 * statement.  Reassoc across the 8 lanes is the same ε-close license
 * as _MIN_EX / _MAX_EX / _STAR_EX (bit-exact not guaranteed; min/max
 * are strictly associative + commutative so the 8-way tree gives the
 * same result modulo NaN handling which stays identical to the
 * single-accumulator case).
 */
#define CA_SLAB_REDUCE_MIN8_EX(T, ACC_T, st, p, m, acc, INIT, EXPR, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          ACC_T __a0=(acc),__a1=(acc),__a2=(acc),__a3=(acc);                 \
          ACC_T __a4=(acc),__a5=(acc),__a6=(acc),__a7=(acc);                 \
          ca_size_t __sj = 0, __sN = __srInnerN;                             \
          for ( ; __sj + 8 <= __sN; __sj += 8 ) {                           \
            ACC_T __v0 = EXPR(__srSrc[__sj + 0]); __a0 = (__v0 < __a0) ? __v0 : __a0; \
            ACC_T __v1 = EXPR(__srSrc[__sj + 1]); __a1 = (__v1 < __a1) ? __v1 : __a1; \
            ACC_T __v2 = EXPR(__srSrc[__sj + 2]); __a2 = (__v2 < __a2) ? __v2 : __a2; \
            ACC_T __v3 = EXPR(__srSrc[__sj + 3]); __a3 = (__v3 < __a3) ? __v3 : __a3; \
            ACC_T __v4 = EXPR(__srSrc[__sj + 4]); __a4 = (__v4 < __a4) ? __v4 : __a4; \
            ACC_T __v5 = EXPR(__srSrc[__sj + 5]); __a5 = (__v5 < __a5) ? __v5 : __a5; \
            ACC_T __v6 = EXPR(__srSrc[__sj + 6]); __a6 = (__v6 < __a6) ? __v6 : __a6; \
            ACC_T __v7 = EXPR(__srSrc[__sj + 7]); __a7 = (__v7 < __a7) ? __v7 : __a7; \
          }                                                                  \
          for ( ; __sj < __sN; __sj++ ) {                                    \
            ACC_T __v = EXPR(__srSrc[__sj]); __a0 = (__v < __a0) ? __v : __a0; \
          }                                                                  \
          ACC_T __b0 = (__a0 < __a1) ? __a0 : __a1;                          \
          ACC_T __b1 = (__a2 < __a3) ? __a2 : __a3;                          \
          ACC_T __b2 = (__a4 < __a5) ? __a4 : __a5;                          \
          ACC_T __b3 = (__a6 < __a7) ? __a6 : __a7;                          \
          ACC_T __c0 = (__b0 < __b1) ? __b0 : __b1;                          \
          ACC_T __c1 = (__b2 < __b3) ? __b2 : __b3;                          \
          (acc) = (__c0 < __c1) ? __c0 : __c1;                               \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            ACC_T __v = EXPR(*(const T *)(__srQ + __sj * __srInnerS));       \
            if (__v < (acc)) (acc) = __v;                                    \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              ACC_T __v = EXPR(__srSrc[__sj]);                               \
              if (__v < (acc)) (acc) = __v;                                  \
            } else { (masked_cnt)++; }                                       \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              ACC_T __v = EXPR(*(const T *)(__srQ + __sj * __srInnerS));     \
              if (__v < (acc)) (acc) = __v;                                  \
            } else { (masked_cnt)++; }                                       \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
  } while (0)

#define CA_SLAB_REDUCE_MAX8_EX(T, ACC_T, st, p, m, acc, INIT, EXPR, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          ACC_T __a0=(acc),__a1=(acc),__a2=(acc),__a3=(acc);                 \
          ACC_T __a4=(acc),__a5=(acc),__a6=(acc),__a7=(acc);                 \
          ca_size_t __sj = 0, __sN = __srInnerN;                             \
          for ( ; __sj + 8 <= __sN; __sj += 8 ) {                           \
            ACC_T __v0 = EXPR(__srSrc[__sj + 0]); __a0 = (__v0 > __a0) ? __v0 : __a0; \
            ACC_T __v1 = EXPR(__srSrc[__sj + 1]); __a1 = (__v1 > __a1) ? __v1 : __a1; \
            ACC_T __v2 = EXPR(__srSrc[__sj + 2]); __a2 = (__v2 > __a2) ? __v2 : __a2; \
            ACC_T __v3 = EXPR(__srSrc[__sj + 3]); __a3 = (__v3 > __a3) ? __v3 : __a3; \
            ACC_T __v4 = EXPR(__srSrc[__sj + 4]); __a4 = (__v4 > __a4) ? __v4 : __a4; \
            ACC_T __v5 = EXPR(__srSrc[__sj + 5]); __a5 = (__v5 > __a5) ? __v5 : __a5; \
            ACC_T __v6 = EXPR(__srSrc[__sj + 6]); __a6 = (__v6 > __a6) ? __v6 : __a6; \
            ACC_T __v7 = EXPR(__srSrc[__sj + 7]); __a7 = (__v7 > __a7) ? __v7 : __a7; \
          }                                                                  \
          for ( ; __sj < __sN; __sj++ ) {                                    \
            ACC_T __v = EXPR(__srSrc[__sj]); __a0 = (__v > __a0) ? __v : __a0; \
          }                                                                  \
          ACC_T __b0 = (__a0 > __a1) ? __a0 : __a1;                          \
          ACC_T __b1 = (__a2 > __a3) ? __a2 : __a3;                          \
          ACC_T __b2 = (__a4 > __a5) ? __a4 : __a5;                          \
          ACC_T __b3 = (__a6 > __a7) ? __a6 : __a7;                          \
          ACC_T __c0 = (__b0 > __b1) ? __b0 : __b1;                          \
          ACC_T __c1 = (__b2 > __b3) ? __b2 : __b3;                          \
          (acc) = (__c0 > __c1) ? __c0 : __c1;                               \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            ACC_T __v = EXPR(*(const T *)(__srQ + __sj * __srInnerS));       \
            if (__v > (acc)) (acc) = __v;                                    \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              ACC_T __v = EXPR(__srSrc[__sj]);                               \
              if (__v > (acc)) (acc) = __v;                                  \
            } else { (masked_cnt)++; }                                       \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              ACC_T __v = EXPR(*(const T *)(__srQ + __sj * __srInnerS));     \
              if (__v > (acc)) (acc) = __v;                                  \
            } else { (masked_cnt)++; }                                       \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
  } while (0)

#define CA_SLAB_REDUCE_STAR8_EX(T, ACC_T, st, p, m, acc, INIT, EXPR, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          ACC_T __a0=(ACC_T)1,__a1=(ACC_T)1,__a2=(ACC_T)1,__a3=(ACC_T)1;     \
          ACC_T __a4=(ACC_T)1,__a5=(ACC_T)1,__a6=(ACC_T)1,__a7=(ACC_T)1;     \
          ca_size_t __sj = 0, __sN = __srInnerN;                             \
          for ( ; __sj + 8 <= __sN; __sj += 8 ) {                           \
            __a0 *= EXPR(__srSrc[__sj + 0]);                                 \
            __a1 *= EXPR(__srSrc[__sj + 1]);                                 \
            __a2 *= EXPR(__srSrc[__sj + 2]);                                 \
            __a3 *= EXPR(__srSrc[__sj + 3]);                                 \
            __a4 *= EXPR(__srSrc[__sj + 4]);                                 \
            __a5 *= EXPR(__srSrc[__sj + 5]);                                 \
            __a6 *= EXPR(__srSrc[__sj + 6]);                                 \
            __a7 *= EXPR(__srSrc[__sj + 7]);                                 \
          }                                                                  \
          for ( ; __sj < __sN; __sj++ ) __a0 *= EXPR(__srSrc[__sj]);         \
          (acc) *= ((__a0 * __a1) * (__a2 * __a3))                           \
                 * ((__a4 * __a5) * (__a6 * __a7));                          \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const T *)(__srQ + __sj * __srInnerS);                   \
            (acc) *= EXPR(v);                                                \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) { T v = __srSrc[__sj]; (acc) *= EXPR(v); } \
            else { (masked_cnt)++; }                                         \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const T *)(__srQ + __sj * __srInnerS);                 \
              (acc) *= EXPR(v);                                              \
            } else { (masked_cnt)++; }                                       \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
  } while (0)

/* CA_SLAB_REDUCE_T_MIN_EX (SL.1.2):
 *   Same structure as PLUS_EX; no-mask + contig inner loop carries
 *   `#pragma omp simd reduction(min:acc)`.  Author REDUCE expression
 *   is `if (v < acc) acc = v` (see :min kernel in mkkernel.rb) which
 *   matches OpenMP `min:` reduction semantics exactly — bit-exact
 *   parity preserved (no reassoc license needed; min/max are
 *   associative + commutative under `<` / `>`).
 *
 *   NaN behaviour: `(NaN < x)` is false in C, so NaN never wins
 *   the comparison.  Final acc for all-NaN slab stays at INIT
 *   (T_LIMIT_HI), matching the pre-SIMD path byte-identically.
 */
#define CA_SLAB_REDUCE_T_MIN_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    /* Slab-collapse: when the whole K-D slab is row-major contiguous       \
       (data, and mask if present), fold all slab axes into one flat        \
       inner loop.  Removes the per-outer multi-index offset recompute +    \
       carry that otherwise dominates when the innermost slab axis is       \
       small (full reduction of [N,1] / [N,small] entity, or trailing-      \
       contig multi-axis reduce).  Platform-general: structural, not SIMD.  \
       No-op for 1-D slabs (__srOuterK == 0 leaves __srOC == 1). */         \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    ca_size_t idx         = 0;                                               \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          _CA_SIMD_MIN(acc)                                                  \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              T v = __srSrc[__sj];                                           \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const T *)(__srQ + __sj * __srInnerS);                 \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
    (void) idx;                                                              \
  } while (0)

/* CA_SLAB_REDUCE_T_MAX_EX (SL.1.2): same as MIN_EX with `_CA_SIMD_MAX`. */
#define CA_SLAB_REDUCE_T_MAX_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    /* Slab-collapse: when the whole K-D slab is row-major contiguous       \
       (data, and mask if present), fold all slab axes into one flat        \
       inner loop.  Removes the per-outer multi-index offset recompute +    \
       carry that otherwise dominates when the innermost slab axis is       \
       small (full reduction of [N,1] / [N,small] entity, or trailing-      \
       contig multi-axis reduce).  Platform-general: structural, not SIMD.  \
       No-op for 1-D slabs (__srOuterK == 0 leaves __srOC == 1). */         \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    ca_size_t idx         = 0;                                               \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          _CA_SIMD_MAX(acc)                                                  \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              T v = __srSrc[__sj];                                           \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const T *)(__srQ + __sj * __srInnerS);                 \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
    (void) idx;                                                              \
  } while (0)

/* CA_SLAB_REDUCE_T_STAR_EX (SL.1.4):
 *   Same structure as PLUS_EX; no-mask + contig inner loop carries
 *   `#pragma omp simd reduction(*:acc)`.  Used by :prod kernel
 *   (acc *= v).  f64 / f32 multiplication parity is ε-close (same
 *   reassoc license as PLUS_EX); integer multiplication is bit-exact
 *   under reassoc (associative + commutative on bounded-precision
 *   integers).
 */
#define CA_SLAB_REDUCE_T_STAR_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __srK       = (st).slab_ndim;                                  \
    int8_t    __srOuterK  = __srK - 1;                                       \
    ca_size_t __srInnerN  = (st).slab_dims[__srK - 1];                       \
    ca_size_t __srInnerS  = (st).slab_strides[__srK - 1];                    \
    ca_size_t __srInnerMS = (st).slab_mask_strides[__srK - 1];               \
    int       __srContig  = (__srInnerS == (ca_size_t) sizeof(T));           \
    int       __srMaskU   = (__srInnerMS == 1);                              \
    ca_size_t __srOC      = 1;                                               \
    for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ )                       \
      __srOC *= (st).slab_dims[__sk];                                        \
    /* Slab-collapse: when the whole K-D slab is row-major contiguous       \
       (data, and mask if present), fold all slab axes into one flat        \
       inner loop.  Removes the per-outer multi-index offset recompute +    \
       carry that otherwise dominates when the innermost slab axis is       \
       small (full reduction of [N,1] / [N,small] entity, or trailing-      \
       contig multi-axis reduce).  Platform-general: structural, not SIMD.  \
       No-op for 1-D slabs (__srOuterK == 0 leaves __srOC == 1). */         \
    {                                                                        \
      int __srFlat = __srContig;                                            \
      for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
        if ( (st).slab_strides[__sk] !=                                      \
             (st).slab_dims[__sk + 1] * (st).slab_strides[__sk + 1] )        \
          __srFlat = 0;                                                      \
      if ( __srFlat && (m) != NULL ) {                                       \
        if ( ! __srMaskU ) __srFlat = 0;                                     \
        for ( int8_t __sk = (int8_t)(__srK - 2); __sk >= 0 && __srFlat; __sk-- ) \
          if ( (st).slab_mask_strides[__sk] !=                              \
               (st).slab_dims[__sk + 1] * (st).slab_mask_strides[__sk + 1] ) \
            __srFlat = 0;                                                    \
      }                                                                      \
      if ( __srFlat ) { __srInnerN = (st).slab_elements; __srOC = 1; }       \
    }                                                                        \
    ca_size_t __srIdx[CA_RANK_MAX] = { 0 };                                  \
    ca_size_t idx         = 0;                                               \
    for ( ca_size_t __so = 0; __so < __srOC; __so++ ) {                      \
      ca_size_t __srDoff = 0, __srMoff = 0;                                  \
      for ( int8_t __sk = 0; __sk < __srOuterK; __sk++ ) {                   \
        __srDoff += __srIdx[__sk] * (st).slab_strides[__sk];                 \
        __srMoff += __srIdx[__sk] * (st).slab_mask_strides[__sk];            \
      }                                                                      \
      const char *__srQ = (const char *)(p) + __srDoff;                      \
      if ( (m) == NULL ) {                                                   \
        if ( __srContig ) {                                                  \
          const T *__srSrc = (const T *) __srQ;                              \
          _CA_SIMD_STAR(acc)                                                 \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const T *__srSrc = (const T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              T v = __srSrc[__sj];                                           \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const T *)(__srQ + __sj * __srInnerS);                 \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sk = __srOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__srIdx[__sk] < (st).slab_dims[__sk] ) break;                  \
        __srIdx[__sk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
    (void) idx;                                                              \
  } while (0)

/* No-mask wrappers (hide masked_cnt) — parallel to CA_SLAB_REDUCE_T. */
#define CA_SLAB_REDUCE_T_PLUS(T, st, p, m, acc, INIT, REDUCE) do {            \
    ca_size_t __sr_throwaway_mc = 0;                                         \
    CA_SLAB_REDUCE_T_PLUS_EX(T, st, p, m, acc, INIT, REDUCE,                 \
                             __sr_throwaway_mc);                             \
    (void) __sr_throwaway_mc;                                                \
  } while (0)
#define CA_SLAB_REDUCE_T_MIN(T, st, p, m, acc, INIT, REDUCE) do {             \
    ca_size_t __sr_throwaway_mc = 0;                                         \
    CA_SLAB_REDUCE_T_MIN_EX(T, st, p, m, acc, INIT, REDUCE,                  \
                            __sr_throwaway_mc);                              \
    (void) __sr_throwaway_mc;                                                \
  } while (0)
#define CA_SLAB_REDUCE_T_MAX(T, st, p, m, acc, INIT, REDUCE) do {             \
    ca_size_t __sr_throwaway_mc = 0;                                         \
    CA_SLAB_REDUCE_T_MAX_EX(T, st, p, m, acc, INIT, REDUCE,                  \
                            __sr_throwaway_mc);                              \
    (void) __sr_throwaway_mc;                                                \
  } while (0)
#define CA_SLAB_REDUCE_T_STAR(T, st, p, m, acc, INIT, REDUCE) do {            \
    ca_size_t __sr_throwaway_mc = 0;                                         \
    CA_SLAB_REDUCE_T_STAR_EX(T, st, p, m, acc, INIT, REDUCE,                 \
                             __sr_throwaway_mc);                             \
    (void) __sr_throwaway_mc;                                                \
  } while (0)

/* Multi-acc variant for variance/stddev (sum + sumsq + cnt).
 *
 * SL.1.3 measurement (2026-06-12) showed VAR_EX is **NOT NEEDED** for
 * variance/stddev: a single `#pragma omp simd reduction(+:acc)` on
 * the primary accumulator (via PLUS_EX dispatch) is sufficient — clang
 * extends SIMD treatment to the dependent `sumsq` updates via idiom
 * recognition (the secondary accumulator is recognised as a derived
 * reduction over `v*v`).  variance entity 1-D f64 reached 53.4 GB/s
 * (gate > 40 PASS, 8.2x speedup vs 6.5 baseline) using PLUS_EX.
 *
 * VAR_EX is **retained as a stub** here for future SL.2.x output-
 * buffered work or other multi-acc reductions that don't share the
 * variance pattern (= primary + derived sumsq).  The stub forwards
 * to PLUS_EX on acc1; acc2 is zero-initialised but otherwise left
 * to the enclosing REDUCE expression.  This is safe because no
 * kernel currently dispatches to VAR_EX (= reduce_macro_suffix never
 * returns "_VAR"; SL.1.0/1.1 reduce DSL has no :var value).
 *
 * Removal candidate if no caller materialises by SL.2 close.
 */
#define CA_SLAB_REDUCE_T_VAR_EX(T, st, p, m, acc1, acc2,                     \
                                INIT1, INIT2, REDUCE, masked_cnt) do {       \
    (acc2) = (INIT2);                                                        \
    CA_SLAB_REDUCE_T_PLUS_EX(T, st, p, m, acc1, INIT1, REDUCE, masked_cnt);  \
  } while (0)

/* CA_SLAB_REDUCE_ARRAY_T_EX(T, T_W, ...): reduction with a parallel
   second-array operand (the "weights" or "right-hand operand").  Used by
   weighted reduction kernels (wsum, wmean, future wvariance/wstddev) that
   take a same-shape second CArray argument.

   The two operands are driven by **two parallel kernel_iterator state
   machines** (= st_src and st_w), each initialised on the same slab_axes.
   They yield slab pointers in lockstep — same logical slab, possibly
   different physical layout (e.g. self is a transpose view and weights
   is a fresh entity).  Each side carries its own slab_strides /
   slab_dims; only slab_dims need to match (= same shape invariant
   enforced by ca_check_same_shape at dispatcher).

   Author-supplied (additional to CA_SLAB_REDUCE_T_EX):
     - T_W:        second-operand element C type (load type).  Must match
                   T in the W.1 framework (mkkernel array_arg: data_type:
                   :match_source enforces this).  Kept separate in the
                   macro signature so future heterogeneous-data_type variants
                   can plug in without macro change.
     - st_w:       second-operand ca_iter_state, positioned on the
                   currently-active weights slab (caller iterates st_w
                   alongside st_src — see mkkernel array_arg emit).
     - p_w:        second-operand slab data pointer (char *) yielded by
                   ca_iter_state_next_slab_axes(&st_w, &p_w, NULL).

   REDUCE expression binds BOTH `v` (source cell, type T) AND `w` (weights
   cell, type T_W), in addition to `acc` and `idx` from the base macro.
   The mask `m` applies to the SOURCE only (weights mask is overlaid onto
   source mask at dispatcher time, per Q3 (A) legacy parity). */
#define CA_SLAB_REDUCE_ARRAY_T_EX(T, T_W, st, p, m, st_w, p_w, acc, INIT, REDUCE, masked_cnt) do { \
    (acc) = (INIT);                                                          \
    int8_t    __sraK       = (st).slab_ndim;                                 \
    int8_t    __sraOuterK  = __sraK - 1;                                     \
    ca_size_t __sraInnerN  = (st).slab_dims[__sraK - 1];                     \
    ca_size_t __sraInnerS  = (st).slab_strides[__sraK - 1];                  \
    ca_size_t __sraInnerWS = (st_w).slab_strides[__sraK - 1];                \
    ca_size_t __sraInnerMS = (st).slab_mask_strides[__sraK - 1];             \
    int       __sraContig  = (__sraInnerS  == (ca_size_t) sizeof(T));        \
    int       __sraContigW = (__sraInnerWS == (ca_size_t) sizeof(T_W));      \
    int       __sraMaskU   = (__sraInnerMS == 1);                            \
    ca_size_t __sraOC      = 1;                                              \
    for ( int8_t __sak = 0; __sak < __sraOuterK; __sak++ )                   \
      __sraOC *= (st).slab_dims[__sak];                                      \
    /* Slab-collapse: fold all slab axes into one flat inner loop when the  \
       whole K-D slab is row-major contiguous for BOTH source and weights   \
       (and mask if present).  Same structural win as the unweighted        \
       CA_SLAB_REDUCE_T_*_EX macros: kills the per-outer multi-index offset  \
       recompute + carry that dominates when the innermost slab axis is     \
       small.  No-op for 1-D slabs (__sraOuterK == 0 leaves __sraOC == 1).  \
       Weights share slab_dims with source (shape invariant), so the dim    \
       cascade uses (st).slab_dims for both stride tables. */               \
    {                                                                        \
      int __sraFlat = __sraContig && __sraContigW;                          \
      for ( int8_t __sak = (int8_t)(__sraK - 2); __sak >= 0 && __sraFlat; __sak-- ) { \
        if ( (st).slab_strides[__sak] !=                                     \
             (st).slab_dims[__sak + 1] * (st).slab_strides[__sak + 1] )      \
          __sraFlat = 0;                                                     \
        if ( (st_w).slab_strides[__sak] !=                                   \
             (st).slab_dims[__sak + 1] * (st_w).slab_strides[__sak + 1] )    \
          __sraFlat = 0;                                                     \
      }                                                                      \
      if ( __sraFlat && (m) != NULL ) {                                      \
        if ( ! __sraMaskU ) __sraFlat = 0;                                   \
        for ( int8_t __sak = (int8_t)(__sraK - 2); __sak >= 0 && __sraFlat; __sak-- ) \
          if ( (st).slab_mask_strides[__sak] !=                             \
               (st).slab_dims[__sak + 1] * (st).slab_mask_strides[__sak + 1] ) \
            __sraFlat = 0;                                                   \
      }                                                                      \
      if ( __sraFlat ) { __sraInnerN = (st).slab_elements; __sraOC = 1; }    \
    }                                                                        \
    ca_size_t __sraIdx[CA_RANK_MAX] = { 0 };                                 \
    ca_size_t idx          = 0;                                              \
    for ( ca_size_t __sao = 0; __sao < __sraOC; __sao++ ) {                  \
      ca_size_t __sraDoff = 0, __sraWoff = 0, __sraMoff = 0;                 \
      for ( int8_t __sak = 0; __sak < __sraOuterK; __sak++ ) {               \
        __sraDoff += __sraIdx[__sak] * (st).slab_strides[__sak];             \
        __sraWoff += __sraIdx[__sak] * (st_w).slab_strides[__sak];           \
        __sraMoff += __sraIdx[__sak] * (st).slab_mask_strides[__sak];        \
      }                                                                      \
      const char *__sraQ  = (const char *)(p)   + __sraDoff;                 \
      const char *__sraWQ = (const char *)(p_w) + __sraWoff;                 \
      if ( (m) == NULL ) {                                                   \
        if ( __sraContig && __sraContigW ) {                                 \
          const T   *__sraSrc = (const T   *) __sraQ;                        \
          const T_W *__sraWgt = (const T_W *) __sraWQ;                       \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            T   v = __sraSrc[__saj];                                         \
            T_W w = __sraWgt[__saj];                                         \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            T   v = *(const T   *)(__sraQ  + __saj * __sraInnerS);           \
            T_W w = *(const T_W *)(__sraWQ + __saj * __sraInnerWS);          \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__sraMM = (const boolean8_t *)(m) + __sraMoff;     \
        if ( __sraContig && __sraContigW && __sraMaskU ) {                   \
          const T   *__sraSrc = (const T   *) __sraQ;                        \
          const T_W *__sraWgt = (const T_W *) __sraWQ;                       \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            if ( ! __sraMM[__saj] ) {                                        \
              T   v = __sraSrc[__saj];                                       \
              T_W w = __sraWgt[__saj];                                       \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            if ( ! __sraMM[__saj * __sraInnerMS] ) {                         \
              T   v = *(const T   *)(__sraQ  + __saj * __sraInnerS);         \
              T_W w = *(const T_W *)(__sraWQ + __saj * __sraInnerWS);        \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sak = __sraOuterK - 1; __sak >= 0; __sak-- ) {           \
        if ( ++__sraIdx[__sak] < (st).slab_dims[__sak] ) break;               \
        __sraIdx[__sak] = 0;                                                  \
      }                                                                      \
    }                                                                        \
    (void) idx;                                                              \
  } while (0)

#define CA_SLAB_REDUCE_ARRAY_T(T, T_W, st, p, m, st_w, p_w, acc, INIT, REDUCE) do { \
    ca_size_t __sra_throwaway_mc = 0;                                         \
    CA_SLAB_REDUCE_ARRAY_T_EX(T, T_W, st, p, m, st_w, p_w, acc, INIT, REDUCE, \
                              __sra_throwaway_mc);                            \
    (void) __sra_throwaway_mc;                                                \
  } while (0)

/* CA_SLAB_REDUCE_ARRAY_T_PLUS_EX (SL.1.4b):
 *   Parallel-array PLUS variant of CA_SLAB_REDUCE_ARRAY_T_EX.
 *   no-mask + both-contig inner loop carries `#pragma omp simd
 *   reduction(+:acc)`.  Used by :wsum / :wmean — author REDUCE
 *   expression is `acc += (double) v * (double) w`, which clang +
 *   `-fopenmp-simd` lowers to NEON `fmla.2d` (interleave-4) with
 *   reduction-tree merge.  Other branches (masked, non-contig)
 *   stay identical to _EX.
 *
 *   PoC bench (SL.1.4b, 2026-06-12):
 *     wsum  f64 N=1M: 908 us -> ~150 us   (= the expected 50-60 GB/s)
 *     wmean f64 N=1M: 1212 us -> ~150 us  (same path + 1 extra acc)
 */
#define CA_SLAB_REDUCE_ARRAY_T_PLUS_EX(T, T_W, st, p, m, st_w, p_w, acc,     \
                                       INIT, REDUCE, masked_cnt) do {        \
    (acc) = (INIT);                                                          \
    int8_t    __sraK       = (st).slab_ndim;                                 \
    int8_t    __sraOuterK  = __sraK - 1;                                     \
    ca_size_t __sraInnerN  = (st).slab_dims[__sraK - 1];                     \
    ca_size_t __sraInnerS  = (st).slab_strides[__sraK - 1];                  \
    ca_size_t __sraInnerWS = (st_w).slab_strides[__sraK - 1];                \
    ca_size_t __sraInnerMS = (st).slab_mask_strides[__sraK - 1];             \
    int       __sraContig  = (__sraInnerS  == (ca_size_t) sizeof(T));        \
    int       __sraContigW = (__sraInnerWS == (ca_size_t) sizeof(T_W));      \
    int       __sraMaskU   = (__sraInnerMS == 1);                            \
    ca_size_t __sraOC      = 1;                                              \
    for ( int8_t __sak = 0; __sak < __sraOuterK; __sak++ )                   \
      __sraOC *= (st).slab_dims[__sak];                                      \
    /* Slab-collapse: fold all slab axes into one flat inner loop when the  \
       whole K-D slab is row-major contiguous for BOTH source and weights   \
       (and mask if present).  Same structural win as the unweighted        \
       CA_SLAB_REDUCE_T_*_EX macros: kills the per-outer multi-index offset  \
       recompute + carry that dominates when the innermost slab axis is     \
       small.  No-op for 1-D slabs (__sraOuterK == 0 leaves __sraOC == 1).  \
       Weights share slab_dims with source (shape invariant), so the dim    \
       cascade uses (st).slab_dims for both stride tables. */               \
    {                                                                        \
      int __sraFlat = __sraContig && __sraContigW;                          \
      for ( int8_t __sak = (int8_t)(__sraK - 2); __sak >= 0 && __sraFlat; __sak-- ) { \
        if ( (st).slab_strides[__sak] !=                                     \
             (st).slab_dims[__sak + 1] * (st).slab_strides[__sak + 1] )      \
          __sraFlat = 0;                                                     \
        if ( (st_w).slab_strides[__sak] !=                                   \
             (st).slab_dims[__sak + 1] * (st_w).slab_strides[__sak + 1] )    \
          __sraFlat = 0;                                                     \
      }                                                                      \
      if ( __sraFlat && (m) != NULL ) {                                      \
        if ( ! __sraMaskU ) __sraFlat = 0;                                   \
        for ( int8_t __sak = (int8_t)(__sraK - 2); __sak >= 0 && __sraFlat; __sak-- ) \
          if ( (st).slab_mask_strides[__sak] !=                             \
               (st).slab_dims[__sak + 1] * (st).slab_mask_strides[__sak + 1] ) \
            __sraFlat = 0;                                                   \
      }                                                                      \
      if ( __sraFlat ) { __sraInnerN = (st).slab_elements; __sraOC = 1; }    \
    }                                                                        \
    ca_size_t __sraIdx[CA_RANK_MAX] = { 0 };                                 \
    ca_size_t idx          = 0;                                              \
    for ( ca_size_t __sao = 0; __sao < __sraOC; __sao++ ) {                  \
      ca_size_t __sraDoff = 0, __sraWoff = 0, __sraMoff = 0;                 \
      for ( int8_t __sak = 0; __sak < __sraOuterK; __sak++ ) {               \
        __sraDoff += __sraIdx[__sak] * (st).slab_strides[__sak];             \
        __sraWoff += __sraIdx[__sak] * (st_w).slab_strides[__sak];           \
        __sraMoff += __sraIdx[__sak] * (st).slab_mask_strides[__sak];        \
      }                                                                      \
      const char *__sraQ  = (const char *)(p)   + __sraDoff;                 \
      const char *__sraWQ = (const char *)(p_w) + __sraWoff;                 \
      if ( (m) == NULL ) {                                                   \
        if ( __sraContig && __sraContigW ) {                                 \
          const T   *__sraSrc = (const T   *) __sraQ;                        \
          const T_W *__sraWgt = (const T_W *) __sraWQ;                       \
          _CA_SIMD_PLUS(acc)                                                 \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            T   v = __sraSrc[__saj];                                         \
            T_W w = __sraWgt[__saj];                                         \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            T   v = *(const T   *)(__sraQ  + __saj * __sraInnerS);           \
            T_W w = *(const T_W *)(__sraWQ + __saj * __sraInnerWS);          \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__sraMM = (const boolean8_t *)(m) + __sraMoff;     \
        if ( __sraContig && __sraContigW && __sraMaskU ) {                   \
          const T   *__sraSrc = (const T   *) __sraQ;                        \
          const T_W *__sraWgt = (const T_W *) __sraWQ;                       \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            if ( ! __sraMM[__saj] ) {                                        \
              T   v = __sraSrc[__saj];                                       \
              T_W w = __sraWgt[__saj];                                       \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            if ( ! __sraMM[__saj * __sraInnerMS] ) {                         \
              T   v = *(const T   *)(__sraQ  + __saj * __sraInnerS);         \
              T_W w = *(const T_W *)(__sraWQ + __saj * __sraInnerWS);        \
              REDUCE;                                                        \
            } else {                                                         \
              (masked_cnt)++;                                                \
            }                                                                \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      }                                                                      \
      for ( int8_t __sak = __sraOuterK - 1; __sak >= 0; __sak-- ) {           \
        if ( ++__sraIdx[__sak] < (st).slab_dims[__sak] ) break;               \
        __sraIdx[__sak] = 0;                                                  \
      }                                                                      \
    }                                                                        \
    (void) idx;                                                              \
  } while (0)

#define CA_SLAB_REDUCE_ARRAY_T_PLUS(T, T_W, st, p, m, st_w, p_w, acc,        \
                                     INIT, REDUCE) do {                      \
    ca_size_t __sra_throwaway_mc = 0;                                         \
    CA_SLAB_REDUCE_ARRAY_T_PLUS_EX(T, T_W, st, p, m, st_w, p_w, acc, INIT,   \
                                    REDUCE, __sra_throwaway_mc);              \
    (void) __sra_throwaway_mc;                                                \
  } while (0)

#define CA_SLAB_REDUCE_F64(st, p, m, acc, INIT, REDUCE)                       \
        CA_SLAB_REDUCE_T(double,  st, p, m, acc, INIT, REDUCE)
#define CA_SLAB_REDUCE_F32(st, p, m, acc, INIT, REDUCE)                       \
        CA_SLAB_REDUCE_T(float,   st, p, m, acc, INIT, REDUCE)
#define CA_SLAB_REDUCE_I32(st, p, m, acc, INIT, REDUCE)                       \
        CA_SLAB_REDUCE_T(int32_t, st, p, m, acc, INIT, REDUCE)
#define CA_SLAB_REDUCE_I64(st, p, m, acc, INIT, REDUCE)                       \
        CA_SLAB_REDUCE_T(int64_t, st, p, m, acc, INIT, REDUCE)

/* CA_SLAB_MAP_T(T_IN, T_OUT, ...): generic per-cell transform from
   input slab to output slab, walking both in lockstep.  T_IN is the
   input element load type, T_OUT is the output element store type.
   Same outer K-1 carry + innermost SIMD inner shape as
   CA_SLAB_REDUCE_T, with contig hoist on both sides.

   Author-supplied:
     - T_IN / T_OUT: element C types (load / store).
     - MAP_EXPR:     statement binding `r` (T_OUT, output lvalue)
                     given `v` (T_IN, current input element).
                     Example: `r = sqrt(v)`, `r = (T_OUT)(v * v + 1)`.

   Engine-supplied:
     - st_in / p_in:   input  ca_iter_state + slab data ptr.
     - st_out / p_out: output ca_iter_state + slab data ptr.

   Both states must share slab geometry (= same slab_ndim and slab_dims),
   typically by initialising both with the same policy + axes on
   shape-equal CArrays.  Mask handling is **not** done by this macro —
   if your input is masked, see §6.2 mask propagation discussion in
   docs/authoring/HOW_TO_WRITE_KERNEL.md.  Caller is responsible for invoking
   ca_iter_state_sync_slab on the output state after each slab.

   Convenience aliases below: CA_SLAB_MAP_F64 (T_IN = T_OUT = double). */
#define CA_SLAB_MAP_T(T_IN, T_OUT, st_in, p_in, st_out, p_out, MAP_EXPR) do { \
    int8_t    __mK       = (st_in).slab_ndim;                                \
    int8_t    __mOuterK  = __mK - 1;                                         \
    ca_size_t __mInN     = (st_in).slab_dims[__mK - 1];                      \
    ca_size_t __mInS     = (st_in).slab_strides[__mK - 1];                   \
    ca_size_t __mOutS    = (st_out).slab_strides[__mK - 1];                  \
    int       __mIContig = (__mInS  == (ca_size_t) sizeof(T_IN));            \
    int       __mOContig = (__mOutS == (ca_size_t) sizeof(T_OUT));           \
    ca_size_t __mOC      = 1;                                                \
    for ( int8_t __mk = 0; __mk < __mOuterK; __mk++ )                        \
      __mOC *= (st_in).slab_dims[__mk];                                      \
    ca_size_t __mIdx[CA_RANK_MAX] = { 0 };                                   \
    for ( ca_size_t __mo = 0; __mo < __mOC; __mo++ ) {                       \
      ca_size_t __mIOff = 0, __mOOff = 0;                                    \
      for ( int8_t __mk = 0; __mk < __mOuterK; __mk++ ) {                    \
        __mIOff += __mIdx[__mk] * (st_in).slab_strides[__mk];                \
        __mOOff += __mIdx[__mk] * (st_out).slab_strides[__mk];               \
      }                                                                      \
      const char *__mQi = (const char *)(p_in)  + __mIOff;                   \
      char       *__mQo = (char *)      (p_out) + __mOOff;                   \
      if ( __mIContig && __mOContig ) {                                      \
        const T_IN  *__mSi = (const T_IN  *) __mQi;                          \
        T_OUT       *__mSo = (T_OUT *)       __mQo;                          \
        for ( ca_size_t __mj = 0; __mj < __mInN; __mj++ ) {                  \
          T_IN  v = __mSi[__mj];                                             \
          T_OUT r;                                                           \
          MAP_EXPR;                                                          \
          __mSo[__mj] = r;                                                   \
        }                                                                    \
      } else {                                                               \
        for ( ca_size_t __mj = 0; __mj < __mInN; __mj++ ) {                  \
          T_IN  v = *(const T_IN *)(__mQi + __mj * __mInS);                  \
          T_OUT r;                                                           \
          MAP_EXPR;                                                          \
          *(T_OUT *)(__mQo + __mj * __mOutS) = r;                            \
        }                                                                    \
      }                                                                      \
      for ( int8_t __mk = __mOuterK - 1; __mk >= 0; __mk-- ) {               \
        if ( ++__mIdx[__mk] < (st_in).slab_dims[__mk] ) break;               \
        __mIdx[__mk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
  } while (0)

#define CA_SLAB_MAP_F64(st_in, p_in, st_out, p_out, MAP_EXPR)                 \
        CA_SLAB_MAP_T(double, double, st_in, p_in, st_out, p_out, MAP_EXPR)

/* CA_SLAB_SCAN_T(T_LOAD, T_OUT, ...): cumulative / prefix-scan walk
   that combines a reduction (running accumulator) with a map (per-cell
   output write).  Walks input and output slabs in lockstep; the
   accumulator `acc` is reset to INIT at the start of each macro call
   (= once per outer next_slab_axes iteration, so per "fiber" along the
   scan axis).

   Author-supplied:
     - T_LOAD / T_OUT: input load type / output store type.
     - INIT:           initial value for `acc` (e.g., "0", "1",
                       "T_LIMIT_HI" -- but the latter is resolved by
                       the generator, not the macro itself).
     - STEP:           statement binding `v` (input element, T_LOAD),
                       `r` (output lvalue, T_OUT), and `acc` (running
                       accumulator, T_OUT).  Example:
                         cumsum:  `acc += v; r = acc`
                         cummax:  `if (v > acc) acc = v; r = acc`
                         cumcount: `(void) v; r = ++acc`

   Engine-supplied:
     - st_in / p_in / m_in:   input  ca_iter_state + slab + mask.
     - st_out / p_out:        output ca_iter_state + slab pointer.

   Mask semantics: when m_in != NULL, masked input cells skip the STEP
   (acc preserved) and write the *current* `acc` to the output.  This
   matches legacy cumsum / cumcount: the output at a masked position
   reflects the running aggregate up to (excluding) this cell.  The
   "write acc, not 0" choice keeps the output value continuous for the
   common scan semantics (sum / count / product / max / min) and avoids
   silent breaks of "running aggregate" downstream.  Output mask
   propagation is NOT done here -- if needed, the caller writes to
   op_mask separately (future mask_policy for scan).

   For the common 1-axis scan case (the only one the generator emits),
   slab_ndim is 1 so the macro's outer K-1 carry collapses to a single
   inner walk.  K-D slab support follows the same row-major shape as
   CA_SLAB_REDUCE_T / CA_SLAB_MAP_T. */
#define CA_SLAB_SCAN_T(T_LOAD, T_OUT, st_in, p_in, m_in,                      \
                       st_out, p_out, INIT, STEP) do {                        \
    T_OUT     acc          = (INIT);                                          \
    int8_t    __ssK        = (st_in).slab_ndim;                               \
    int8_t    __ssOuterK   = __ssK - 1;                                       \
    ca_size_t __ssInnerN   = (st_in).slab_dims[__ssK - 1];                    \
    ca_size_t __ssInS      = (st_in).slab_strides[__ssK - 1];                 \
    ca_size_t __ssOutS     = (st_out).slab_strides[__ssK - 1];                \
    ca_size_t __ssInMS     = (st_in).slab_mask_strides[__ssK - 1];            \
    int       __ssIContig  = (__ssInS  == (ca_size_t) sizeof(T_LOAD));        \
    int       __ssOContig  = (__ssOutS == (ca_size_t) sizeof(T_OUT));         \
    int       __ssMaskU    = (__ssInMS == 1);                                 \
    ca_size_t __ssOC       = 1;                                               \
    for ( int8_t __sk = 0; __sk < __ssOuterK; __sk++ )                        \
      __ssOC *= (st_in).slab_dims[__sk];                                      \
    ca_size_t __ssIdx[CA_RANK_MAX] = { 0 };                                   \
    for ( ca_size_t __so = 0; __so < __ssOC; __so++ ) {                       \
      ca_size_t __ssDoff = 0, __ssOOff = 0, __ssMoff = 0;                     \
      for ( int8_t __sk = 0; __sk < __ssOuterK; __sk++ ) {                    \
        __ssDoff += __ssIdx[__sk] * (st_in).slab_strides[__sk];               \
        __ssOOff += __ssIdx[__sk] * (st_out).slab_strides[__sk];              \
        __ssMoff += __ssIdx[__sk] * (st_in).slab_mask_strides[__sk];          \
      }                                                                       \
      const char *__ssQi = (const char *)(p_in)  + __ssDoff;                  \
      char       *__ssQo = (char *)      (p_out) + __ssOOff;                  \
      if ( (m_in) == NULL ) {                                                 \
        if ( __ssIContig && __ssOContig ) {                                   \
          const T_LOAD *__ssSi = (const T_LOAD *) __ssQi;                     \
          T_OUT *__ssSo = (T_OUT *) __ssQo;                                   \
          for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {              \
            T_LOAD v = __ssSi[__sj];                                          \
            T_OUT  r;                                                         \
            STEP;                                                             \
            __ssSo[__sj] = r;                                                 \
          }                                                                   \
        } else {                                                              \
          for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {              \
            T_LOAD v = *(const T_LOAD *)(__ssQi + __sj * __ssInS);            \
            T_OUT  r;                                                         \
            STEP;                                                             \
            *(T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
          }                                                                   \
        }                                                                     \
      } else {                                                                \
        const boolean8_t *__ssMM = (const boolean8_t *)(m_in) + __ssMoff;     \
        for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {                \
          T_OUT r;                                                            \
          if ( ! __ssMM[__ssMaskU ? __sj : __sj * __ssInMS] ) {               \
            T_LOAD v = __ssIContig                                            \
              ? ((const T_LOAD *) __ssQi)[__sj]                               \
              : *(const T_LOAD *)(__ssQi + __sj * __ssInS);                   \
            STEP;                                                             \
          } else {                                                            \
            r = acc;   /* masked: write current running aggregate (legacy parity) */ \
          }                                                                   \
          if ( __ssOContig )                                                  \
            ((T_OUT *) __ssQo)[__sj] = r;                                     \
          else                                                                \
            *(T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
        }                                                                     \
      }                                                                       \
      for ( int8_t __sk = __ssOuterK - 1; __sk >= 0; __sk-- ) {                \
        if ( ++__ssIdx[__sk] < (st_in).slab_dims[__sk] ) break;                \
        __ssIdx[__sk] = 0;                                                    \
      }                                                                       \
    }                                                                         \
  } while (0)

/* CA_SLAB_SCAN_T_GATED(T_LOAD, T_OUT, ...): variant of CA_SLAB_SCAN_T for
   extremum scans (cummax / cummin) whose accumulator has no identity, so
   the running value is undefined until the first present cell of a fiber.
   Adds a per-fiber `int seen` flag and an output-mask base `m_out`.

   Behavior differs from CA_SLAB_SCAN_T only on masked input cells:
     - while !seen (leading masked cells, before any present value): the
       output cell is UNDEF -- the mask bit at m_out is set instead of
       leaking the init sentinel (T_LIMIT_LO / T_LIMIT_HI / Qnil).
     - once a present cell has been processed (seen = 1): a masked cell
       holds the running extremum, unmasked (= identical to the non-gated
       "write acc" legacy parity).
   With no input mask (m_in == NULL) there is no unseen region, so the walk
   is byte-identical to CA_SLAB_SCAN_T and m_out is never touched.

   `seen` tracks the boundary explicitly rather than testing acc against the
   sentinel: a real datum may equal the sentinel, so a value-compare would
   spuriously re-mask a genuine T_LIMIT_LO / T_LIMIT_HI extremum.

   m_out is the output mask base for this fiber, parallel to p_out (= the
   caller passes co->mask->ptr + (p_out - co->ptr) / sizeof(T_OUT)).  It is
   valid only because the scan output is always a fresh contiguous entity
   whose value slab aliases co->ptr (ALIAS_CONTIG); the mask element offset
   parallel to a value byte offset X is X / sizeof(T_OUT).  m_out may be NULL
   (defensive: falls back to holding the sentinel unmasked). */
#define CA_SLAB_SCAN_T_GATED(T_LOAD, T_OUT, st_in, p_in, m_in,                \
                             st_out, p_out, m_out, INIT, STEP) do {           \
    T_OUT     acc          = (INIT);                                          \
    int8_t    __ssK        = (st_in).slab_ndim;                               \
    int8_t    __ssOuterK   = __ssK - 1;                                       \
    ca_size_t __ssInnerN   = (st_in).slab_dims[__ssK - 1];                    \
    ca_size_t __ssInS      = (st_in).slab_strides[__ssK - 1];                 \
    ca_size_t __ssOutS     = (st_out).slab_strides[__ssK - 1];                \
    ca_size_t __ssInMS     = (st_in).slab_mask_strides[__ssK - 1];            \
    int       __ssIContig  = (__ssInS  == (ca_size_t) sizeof(T_LOAD));        \
    int       __ssOContig  = (__ssOutS == (ca_size_t) sizeof(T_OUT));         \
    int       __ssMaskU    = (__ssInMS == 1);                                 \
    ca_size_t __ssMoStep   = __ssOutS / (ca_size_t) sizeof(T_OUT);            \
    ca_size_t __ssOC       = 1;                                               \
    for ( int8_t __sk = 0; __sk < __ssOuterK; __sk++ )                        \
      __ssOC *= (st_in).slab_dims[__sk];                                      \
    ca_size_t __ssIdx[CA_RANK_MAX] = { 0 };                                   \
    for ( ca_size_t __so = 0; __so < __ssOC; __so++ ) {                       \
      ca_size_t __ssDoff = 0, __ssOOff = 0, __ssMoff = 0;                     \
      for ( int8_t __sk = 0; __sk < __ssOuterK; __sk++ ) {                    \
        __ssDoff += __ssIdx[__sk] * (st_in).slab_strides[__sk];               \
        __ssOOff += __ssIdx[__sk] * (st_out).slab_strides[__sk];              \
        __ssMoff += __ssIdx[__sk] * (st_in).slab_mask_strides[__sk];          \
      }                                                                       \
      const char *__ssQi = (const char *)(p_in)  + __ssDoff;                  \
      char       *__ssQo = (char *)      (p_out) + __ssOOff;                  \
      ca_size_t   __ssMoBase = __ssOOff / (ca_size_t) sizeof(T_OUT);          \
      int         __ssSeen   = 0;                                             \
      if ( (m_in) == NULL ) {                                                 \
        if ( __ssIContig && __ssOContig ) {                                   \
          const T_LOAD *__ssSi = (const T_LOAD *) __ssQi;                     \
          T_OUT *__ssSo = (T_OUT *) __ssQo;                                   \
          for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {             \
            T_LOAD v = __ssSi[__sj];                                          \
            T_OUT  r;                                                         \
            STEP;                                                             \
            __ssSo[__sj] = r;                                                 \
          }                                                                   \
        } else {                                                              \
          for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {             \
            T_LOAD v = *(const T_LOAD *)(__ssQi + __sj * __ssInS);            \
            T_OUT  r;                                                         \
            STEP;                                                             \
            *(T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
          }                                                                   \
        }                                                                     \
      } else {                                                                \
        const boolean8_t *__ssMM = (const boolean8_t *)(m_in) + __ssMoff;     \
        for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {               \
          T_OUT r;                                                            \
          if ( ! __ssMM[__ssMaskU ? __sj : __sj * __ssInMS] ) {               \
            T_LOAD v = __ssIContig                                            \
              ? ((const T_LOAD *) __ssQi)[__sj]                               \
              : *(const T_LOAD *)(__ssQi + __sj * __ssInS);                   \
            STEP;                                                             \
            __ssSeen = 1;                                                     \
          } else if ( ! __ssSeen && (m_out) != NULL ) {                       \
            ((boolean8_t *)(m_out))[__ssMoBase + __sj * __ssMoStep] = 1;      \
            r = acc;   /* value slot masked; sentinel held, never read */     \
          } else {                                                            \
            r = acc;   /* masked after first present: hold running extremum */\
          }                                                                   \
          if ( __ssOContig )                                                  \
            ((T_OUT *) __ssQo)[__sj] = r;                                     \
          else                                                                \
            *(T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
        }                                                                     \
      }                                                                       \
      for ( int8_t __sk = __ssOuterK - 1; __sk >= 0; __sk-- ) {               \
        if ( ++__ssIdx[__sk] < (st_in).slab_dims[__sk] ) break;              \
        __ssIdx[__sk] = 0;                                                    \
      }                                                                       \
    }                                                                         \
  } while (0)

/* CA_SLAB_SCAN_TA(T_LOAD, T_OUT, T_ACC, ...): variant of CA_SLAB_SCAN_T
   that decouples the accumulator type T_ACC from the output type T_OUT
   and additionally exposes a `first` flag to STEP marking the first
   live (unmasked) cell of each fiber.

   Use case: "adjacent-compare" scans like uniq_scan, where the
   accumulator holds the last seen INPUT value (T_LOAD) while the output
   is a per-cell boolean flag (T_OUT = boolean8_t).  STEP can branch on
   `first` to special-case the first unmasked cell of each fiber.

   STEP sees: v (T_LOAD, current input), r (T_OUT lvalue, output), acc
   (T_ACC, running accumulator), first (int, 1 if this is the first
   unmasked cell of this fiber else 0).

   Masked input cells skip STEP entirely and write r = 0 to the output
   (a neutral value safe for downstream `mask |= r` scatter).  The
   accumulator is preserved across masked cells so STEP sees a coherent
   "last live value" trail.  */
#define CA_SLAB_SCAN_TA(T_LOAD, T_OUT, T_ACC, st_in, p_in, m_in,              \
                        st_out, p_out, INIT, STEP) do {                       \
    T_ACC     acc          = (INIT);                                          \
    int8_t    __ssK        = (st_in).slab_ndim;                               \
    int8_t    __ssOuterK   = __ssK - 1;                                       \
    ca_size_t __ssInnerN   = (st_in).slab_dims[__ssK - 1];                    \
    ca_size_t __ssInS      = (st_in).slab_strides[__ssK - 1];                 \
    ca_size_t __ssOutS     = (st_out).slab_strides[__ssK - 1];                \
    ca_size_t __ssInMS     = (st_in).slab_mask_strides[__ssK - 1];            \
    int       __ssIContig  = (__ssInS  == (ca_size_t) sizeof(T_LOAD));        \
    int       __ssOContig  = (__ssOutS == (ca_size_t) sizeof(T_OUT));         \
    int       __ssMaskU    = (__ssInMS == 1);                                 \
    ca_size_t __ssOC       = 1;                                               \
    for ( int8_t __sk = 0; __sk < __ssOuterK; __sk++ )                        \
      __ssOC *= (st_in).slab_dims[__sk];                                      \
    ca_size_t __ssIdx[CA_RANK_MAX] = { 0 };                                   \
    for ( ca_size_t __so = 0; __so < __ssOC; __so++ ) {                       \
      ca_size_t __ssDoff = 0, __ssOOff = 0, __ssMoff = 0;                     \
      for ( int8_t __sk = 0; __sk < __ssOuterK; __sk++ ) {                    \
        __ssDoff += __ssIdx[__sk] * (st_in).slab_strides[__sk];               \
        __ssOOff += __ssIdx[__sk] * (st_out).slab_strides[__sk];              \
        __ssMoff += __ssIdx[__sk] * (st_in).slab_mask_strides[__sk];          \
      }                                                                       \
      const char *__ssQi = (const char *)(p_in)  + __ssDoff;                  \
      char       *__ssQo = (char *)      (p_out) + __ssOOff;                  \
      int __ssFirst = 1;                                                      \
      if ( (m_in) == NULL ) {                                                 \
        for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {               \
          T_LOAD v = __ssIContig                                              \
            ? ((const T_LOAD *) __ssQi)[__sj]                                 \
            : *(const T_LOAD *)(__ssQi + __sj * __ssInS);                     \
          T_OUT  r;                                                           \
          int first = __ssFirst;                                              \
          STEP;                                                               \
          __ssFirst = 0;                                                      \
          if ( __ssOContig )                                                  \
            ((T_OUT *) __ssQo)[__sj] = r;                                     \
          else                                                                \
            *(T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
        }                                                                     \
      } else {                                                                \
        const boolean8_t *__ssMM = (const boolean8_t *)(m_in) + __ssMoff;     \
        for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {               \
          T_OUT r;                                                            \
          if ( ! __ssMM[__ssMaskU ? __sj : __sj * __ssInMS] ) {               \
            T_LOAD v = __ssIContig                                            \
              ? ((const T_LOAD *) __ssQi)[__sj]                               \
              : *(const T_LOAD *)(__ssQi + __sj * __ssInS);                   \
            int first = __ssFirst;                                            \
            STEP;                                                             \
            __ssFirst = 0;                                                    \
          } else {                                                            \
            r = (T_OUT) 0;   /* masked: neutral output for downstream OR */   \
          }                                                                   \
          if ( __ssOContig )                                                  \
            ((T_OUT *) __ssQo)[__sj] = r;                                     \
          else                                                                \
            *(T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
        }                                                                     \
      }                                                                       \
      for ( int8_t __sk = __ssOuterK - 1; __sk >= 0; __sk-- ) {                \
        if ( ++__ssIdx[__sk] < (st_in).slab_dims[__sk] ) break;                \
        __ssIdx[__sk] = 0;                                                    \
      }                                                                       \
    }                                                                         \
  } while (0)

/* ---- Ruby surface ---------------------------------------------------- */
/* Called from Init_carray_ext (ruby_carray.c).  Registers the smoke
   test stub (CArray.t1_step1_smoke) used by
   spec_ai/test_t1_kernel_iterator_step1.rb.  This is step-1 scaffolding
   only; later steps may replace or remove it. */
void Init_ca_kernel_iterator (void);

#endif /* CA_KERNEL_ITERATOR_H */
