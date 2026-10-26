/* ---------------------------------------------------------------------------

  ca_kernel_iterator.h -- the kernel iterator, for C extension authors

  A kernel written against this header receives the cells of any CArray
  -- an entity, a view of a view, a selection, a lazy expression -- one
  slab at a time, with the mask beside them, and on a write the cells it
  changes reach the array.  How the cells are delivered is the engine's
  business (ca_kernel_iterator.c); the kernel only names the axes it
  wants and walks what it is given.

  Where to start:
    - guides/devel/11_kernel_iterator.md: the surface and its contract,
      with worked kernels
    - docs/authoring/HOW_TO_WRITE_KERNEL.md: the reference, and which
      macro to pick for a reduction, a map, a scan or a whole-array walk
    - the block macros below (CA_FOR_EACH_SLAB / _FIBER / _WHOLE) are
      the usual way in; the raw entry points (ca_iter_state_init_l1 /
      init_l2 ...) are for kernels that handle the return codes
      themselves

  Freeze contract (3.0 onward).  The surface is split
  so the engine can be re-implemented across 3.x (the surface stays fixed)
  without breaking ext-gem kernels.  docs/authoring/HOW_TO_WRITE_KERNEL.md
  states the contract in prose; utils/check_kernel_surface_freeze.rb
  (rake kernel_surface_check) is the mechanical pin.

    FROZEN (do NOT rename / re-arity / change semantics; additions only):
      - the author macros: the CA_FOR_EACH_SLAB / _FIBER / _WHOLE
        families (including _FIBER_PAIR / _FIBER_PAIR_MASKED), the
        CA_SLAB_REDUCE_* / _MAP_* / _SCAN_* suites except the generator-
        only macros listed under INTERNAL, CA_L2_FOR_EACH, and the mask
        helper CA_FOR_EACH_UNMASKED
      - the raw-API entry points the macros expand to: ca_iter_state_
        init_l1 / next_slab / init_l2 / init_l2_paired / next_slab_axes /
        sync_slab / finish / close, ca_iter_check_init,
        ca_iter_check_same_shape
      - the author entry points beside them: ca_iter_ensure (a body that
        can raise) and ca_iter_register_source_kind (an externally
        installed view class)
      - the enum/status tokens authors write literally: CA_SLAB_AXES,
        CA_SLAB_WHOLE, CA_KERNEL_WRITE, CA_KERNEL_NO_MASK, CA_ITER_OK,
        CA_ITER_ERR_*
      - the slab-delivery representation = the ca_iter_state fields a
        kernel reads (marked "FROZEN author contract" at the struct):
        slab_ndim / slab_dims / slab_strides / slab_mask_strides /
        slab_elements / outer_ndim / outer_axes / outer_dims
      - the identifiers injected into REDUCE / MAP / STEP expressions:
        v, r, w, acc, idx, first

    INTERNAL (free to refactor across 3.x — engine implementation):
      - the state-machine functions' bodies + init_l1 / next_slab /
        ca_iter_can_alias
      - the macros only the kernel generator (ext/mkkernel.rb) emits:
        CA_SLAB_REDUCE_SUM8_EX / MIN8_EX / MAX8_EX / STAR8_EX (8-way
        accumulator split; they take EXPR(x) rather than exposing v and
        idx), CA_SLAB_REDUCE_T_MIN_EX / _MAX_EX / _STAR_EX (what it emits
        when a :min / :max / :prod kernel does not take the 8-way form),
        CA_SLAB_SCAN_T_GATED, and CA_SLAB_REDUCE_T_VAR_EX (no caller)
      - alias_mode / src_kind routing (CA_ITER_ALIAS_* / CA_ITER_SRC_* /
        CA_KERNEL_FIBER_CONTIG / CA_SLAB_FREE)
      - every ca_iter_state field NOT marked frozen (scratch / stack /
        fiber / composed / descriptor bookkeeping) + physical layout

  Adding new author surface is fine and expected (new flag bit, new
  _EX macro variant + thin wrapper, new catalog macro) — that is how
  the surface evolves within 3.x.  Changing or removing a FROZEN name
  is a 3.x breaking change: update the doc contract AND the guard in
  the same commit.  The engine behind these names may be rewritten
  within 3.x; this contract is what keeps such a rewrite invisible to
  kernel authors.

  --------------------------------------------------------------------------- */

#ifndef CA_KERNEL_ITERATOR_H
#define CA_KERNEL_ITERATOR_H 1

#include "carray.h"
#include "ca_iter_substrate.h"   /* ca_axis_desc_t, ca_op_prefix_axis_t */

/* ---- slab policy ------------------------------------------------------ */
typedef enum {
  CA_SLAB_FREE  = 0,    /* engine-chosen chunk.  Not implemented:
                           init returns CA_ITER_ERR_POLICY.          */
  CA_SLAB_AXES  = 1,    /* user-pinned axes inside the slab (init_l2) */
  CA_SLAB_WHOLE = 2     /* whole array in one slab                    */
} ca_slab_policy_t;

/* ---- kernel flags ------------------------------------------------------ */
#define CA_KERNEL_READ        0x0
#define CA_KERNEL_WRITE       0x1    /* the kernel writes the slab back.
                                        The slab is read first (so a
                                        kernel may change only some cells),
                                        and a view that cannot be read --
                                        CAFake of an object array whose
                                        cells do not convert -- raises
                                        there, even for a kernel that
                                        writes every cell                */
#define CA_KERNEL_NO_MASK     0x2    /* the kernel cannot take a mask:
                                        a masked source is refused     */
#define CA_KERNEL_CHUNK_HINT  0x4    /* reserved: init refuses it
                                        with CA_ITER_ERR_FLAGS          */
#define CA_KERNEL_FIBER_CONTIG 0x8   /* with policy=CA_SLAB_AXES and
                                        naxes==1, next_slab_axes hands
                                        out every fiber contiguous
                                        (gathering a strided one into
                                        fiber_data_scratch).  Set by the
                                        CA_FOR_EACH_FIBER macro family.
                                        Direct callers that walk the
                                        slab with slab_strides[0]
                                        themselves leave it clear. */

/* ---- alias mode: where the slabs are cut from (internal) --------------- */
#define CA_ITER_ALIAS_NONE     0     /* a scratch the walk gathered      */
#define CA_ITER_ALIAS_CONTIG   1     /* the source's own memory          */
#define CA_ITER_ALIAS_STRIDED  2     /* the root's or parent's memory,
                                        through composed strides        */
#define CA_ITER_ALIAS_ATTACH   3     /* Not set by the engine.  A
                                        SRC_ATTACH walk runs with
                                        CA_ITER_ALIAS_NONE over an
                                        iterator-owned scratch, filled with
                                        ca_xfer_all and written back with
                                        ki_scratch_push_changed (only the
                                        changed cells).  */
#define CA_ITER_ALIAS_PER_SLAB 4     /* a descriptor view read one slab at
                                        a time: ca_axis_dispatch_gather
                                        over a subset of the descriptors
                                        with the outer axes pinned, into
                                        one slab-sized scratch refilled
                                        in next_slab_axes.  Read walks
                                        only; a write walk takes the
                                        transfer walk instead.  */
#define CA_ITER_ALIAS_PER_SLAB_HOIST 5 /* PER_SLAB when the innermost slab
                                          axis is STRIDE and no axis is
                                          SHIFT: the outer and
                                          non-innermost slab offsets are
                                          computed once per slab row and
                                          the inner run is a memcpy. */
#define CA_ITER_ALIAS_PER_FIBER_FUSED 6 /* each fiber is fetched with the
                                          view's ca_xfer_stride, without
                                          gathering the whole view: a
                                          read of the innermost fiber of
                                          a conversion view (a write takes
                                          the transfer walk).  Chosen by
                                          ca_iter_should_per_fiber_fused.
                                          The fiber is handed out from
                                          fiber_data_scratch, its mask
                                          from fiber_mask_scratch. */
#define CA_ITER_ALIAS_STACK    7     /* a CAStack read with slab_axes ==
                                        [k_axis] (the stack axis alone,
                                        e.g. view.mean(axis: k_axis)).
                                        init_l2 attaches the K parents
                                        and caches their pointers and
                                        their common native strides;
                                        next_slab_axes hands out each
                                        fiber's K cells from a tile cache
                                        (K * tile * bytes, tile 8..64
                                        fibers) refilled from the parents'
                                        memory, without ca_xfer_stride.
                                        Only for slab_axes == [k_axis]
                                        and an unmasked stack; any other
                                        stack walk takes STACK_OUTER_K or
                                        the transfer walk.  Delivery
                                        through ca_xfer_stride was tried
                                        and measured ~16x slower. */
#define CA_ITER_ALIAS_STACK_OUTER_K 8 /* CAStack source + CA_SLAB_AXES
                                        whose slab leaves out the stack
                                        axis (k_axis), which is then an
                                        outer axis.  Each slab lies inside
                                        ONE parent, selected by
                                        outer_idx[stack_k_outer_pos].
                                        init_l2 attaches the K parents and
                                        caches their ptrs and parent byte
                                        strides; next_slab_axes reads
                                        parents[k]->ptr + parent_off
                                        directly.  The parents' masks are
                                        copied at init and the cursor
                                        points into the copy.  A fiber
                                        that is not contiguous in its
                                        parent is gathered (FIBER_CONTIG).
                                        READ only. */

/* ---- error codes ----------------------------------------------------- */
#define CA_ITER_OK              0
#define CA_ITER_ERR_NOT_CHEAP   1    /* the classifier does not recognise
                                        the source (a view with no attach
                                        slot; any other external obj_type
                                        is delivered by the transfer walk,
                                        through its xfer slots)          */
#define CA_ITER_ERR_POLICY      2    /* policy or axes refused: a policy
                                        not implemented, axes NULL / out
                                        of range / duplicated, AXES at
                                        L1, descriptor rank != view rank */
#define CA_ITER_ERR_FLAGS       3    /* flag combination unsupported;
                                        also returned for a NULL state
                                        or source                       */
#define CA_ITER_ERR_READONLY    4    /* WRITE on readonly view (CARepeat etc.) */
#define CA_ITER_ERR_MASK        5    /* reserved: no entry point returns
                                        it (masked sources are accepted) */
#define CA_ITER_ERR_MASK_NOT_ALLOWED 6  /* NO_MASK flag set on a masked source */
/* ---- source kind (internal routing) ------------------------------------ */
#define CA_ITER_SRC_NONE       0
#define CA_ITER_SRC_CASTRIDE   1     /* entity / CAStride family         */
#define CA_ITER_SRC_DESCRIPTOR 2     /* CASelectAxis / CAGrid / CASelect /
                                        CAWindow / CAShift: per-axis
                                        descriptors (describe_axes)      */
#define CA_ITER_SRC_ATTACH     3     /* every other view the classifier
                                        knows (conversion views, CATile,
                                        CARoll, CAStack, CAMeld, CARemap,
                                        CAReduce, CAObject, the lazy
                                        views) and any
                                        registered external obj_type: the
                                        view's own transfer gathers it */
#define CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE 4
                                     /* a descriptor view whose innermost axis
                                        is STRIDE kind, so an L2 walk can read
                                        the parent's memory in place.  Only
                                        returned by ca_iter_route_source,
                                        after describe_axes. */

/* ---- source-kind registration for externally installed obj_types -----

   The classifier recognises the core's own view classes by comparing
   their operation table against a list compiled into the engine.  A view
   class installed by a companion gem through ca_install_obj_type matches
   nothing on that list; it is delivered as CA_ITER_SRC_ATTACH (gathered
   through the view's own transfer), and so is one that registers here,
   once, in the class's Init:

     ca_iter_register_source_kind(CA_OBJ_MY_VIEW, CA_ITER_SRC_ATTACH);

   Registering states the routing rather than changing it.
   CA_ITER_SRC_ATTACH is the only kind that may be registered.  It is the
   one whose contract an external class can meet on its own: the engine
   reads the cells with ca_xfer_all GET and, on a WRITE walk, sends back
   the changed cells with ca_xfer_addrs (or ca_xfer_all PUT when every
   cell changed), so the view's transfer slots are all it needs -- the
   slots every view already implements.  The view's attach / sync slots
   are not called.  The other kinds are not open to registration: SRC_CASTRIDE
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

/* ---- iter state ------------------------------------------------------- */
/* The state lives on the ext author's stack, so its layout is fixed: a
   field is never removed, and the ones no path uses any more (chunk_pos,
   alias_stride) stay as zero-initialised slots. */
typedef struct {
  /* --- inputs (fixed at init) --- */
  struct _CArray   *src;
  uint8_t           src_kind;          /* CA_ITER_SRC_* */
  int8_t            level;             /* 1=L1 contig, 2=L2 strided */
  ca_slab_policy_t  policy;
  int8_t            ndim;
  int8_t            naxes;             /* AXES policy axis count */
  void             *pair;              /* the other state of a two-state
                                          walk (ca_iter_state_init_l2_paired),
                                          else NULL; finished with this one
                                          when the walk raises */
  uint32_t          flags;
  ca_size_t         bytes;             /* element size                     */

  /* --- CAStride compose-fold cache (L2 alias path) ---
     For CAStride-family sources at L2, init_l2 runs
     ca_stride_compose_to_root once to get the root + per-axis
     byte strides + base offset, kept here for the author to read.  The
     walk itself steps from composed_base by outer_strides (below), which
     init builds from the composed strides.  Inline CA_RANK_MAX array (no
     heap alloc).  root is the array attached at
     init whose memory the walk reads: the compose-fold root of an L2
     CAStride walk (an entity, or a view that lends memory) or the parent
     of a descriptor view.  NULL when the walk reads src itself or a
     scratch of its own. */
  struct _CArray   *root;              /* attached at init, detached (or
                                          synced and detached, on WRITE)
                                          by finish                        */
  ca_size_t         composed_strides[CA_RANK_MAX]; /* byte units           */
  ca_size_t         composed_base;     /* byte offset from root->ptr       */

  /* --- descriptor framework cache (descriptor sources) ---
     For CASelectAxis / CAGrid / CASelect / CAWindow / CAShift, init runs
     the view's *_describe_axes once then
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
  ca_size_t        *outer_idx;         /* [outer_ndim]                     */
  ca_size_t         slab_n;            /* current slab element count       */
  ca_size_t         total_slabs;
  ca_size_t         slabs_emitted;

  /* --- chunk position (chunk_pos is unused, kept for layout) --- */
  ca_size_t         chunk_pos;
  ca_size_t         chunk_size;

  /* --- scratch buffer --- */
  char             *scratch_ptr;
  boolean8_t       *scratch_mask;
  ca_size_t         scratch_cap;

  /* --- alias path --- */
  uint8_t           alias_mode;        /* CA_ITER_ALIAS_*                  */
  char             *alias_ptr;         /* base the slabs are yielded from:
                                          the source or root memory, or the
                                          scratch under ALIAS_NONE; NULL for
                                          STACK / STACK_OUTER_K /
                                          PER_FIBER_FUSED                  */
  boolean8_t       *alias_mask;
  ca_size_t         alias_stride;      /* unused, kept for layout          */

  /* --- WRITE-path sync timing --- */
  uint8_t           write_dirty;

  /* --- CA_SLAB_AXES policy fields ---
     Populated when init_l2 is called with policy = CA_SLAB_AXES, for
     every kind of source.  The kernel reads slab metadata directly
     from these fields (= per-walk metadata, unchanged across slabs).
     outer_axes / outer_dims / outer_strides drive the prefix walk;
     slab_axes_buf / slab_dims / slab_strides describe the K-D slab
     handed to the kernel.  All strides are byte units.  Zero-init for
     other policies (CA_SLAB_WHOLE / FREE).

     The slab axis list is "slab_axes_buf" (an inline array); the axes
     the caller passes to init are not kept in the state.

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

  /* --- Per-fiber contig scratch ---
     For naxes==1 (= per-axis fiber, the catalog CA_FOR_EACH_FIBER target)
     on the paths of next_slab_axes that yield a fiber in place (the
     default fall-through and STACK_OUTER_K; ki_fiber_contig_data), when
     slab_strides[0] != bytes the fiber
     is yielded strided.  To honor the catalog contract "data contig
     delivery", next_slab_axes lazily allocates this scratch on first
     gather and gathers each fiber here before yielding.  Reused across
     fibers; size grows to max slab_dims[0] * bytes.

     last_data_off is the byte offset of the current slab from alias_ptr,
     set by next_slab_axes on its default path BEFORE the outer_idx
     advance.  sync_slab reads it for the fiber it scatters back and for
     the cells of a whole-view scratch it compares; the slab iterator's
     map_slab reads it to mark the output's mask.

     The per-slab paths (CA_ITER_ALIAS_PER_SLAB / _HOIST) and the stack
     paths do not set it. */
  char             *fiber_data_scratch;
  ca_size_t         fiber_data_scratch_cap;
  ca_size_t         last_data_off;

  /* Per-fiber contig mask scratch.
     Symmetric to fiber_data_scratch.  When the source carries a mask
     (= alias_mask != NULL) and slab_mask_strides[0] != 1, the engine
     gathers the fiber's mask into contig boolean8_t order here so the
     author can do `m[i]` without indirection.  Read-only from kernel
     POV (= L2 WRITE semantic does not propagate to mask state), so no
     scatter is needed.  See header field doc for sibling field
     fiber_data_scratch. */
  boolean8_t       *fiber_mask_scratch;
  ca_size_t         fiber_mask_scratch_cap;

  /* --- PER_FIBER_FUSED fields ---
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
     region for WRITE PUT.  The same hazard as last_data_off. */
  ca_size_t         fiber_region_starts[CA_RANK_MAX];

  /* --- CAStack read from its parents (STACK / STACK_OUTER_K) --- */
  /* When alias_mode is CA_ITER_ALIAS_STACK or STACK_OUTER_K, init_l2
     attaches all K parents (= O(1) per entity parent) and caches their
     ptr aliases here so next_slab_axes reads them without going through
     ca_xfer_stride.  Owned by iter (xfree in finish).
     stack_parent_strides[] are the uniform parent-native byte strides
     (all the parents of a CAStack have one shape). */
  char            **stack_parent_ptrs;             /* [n_parents] */
  int32_t           stack_n_parents;               /* = ((CAStack *)src)->n_parents */
  ca_size_t         stack_parent_strides[CA_RANK_MAX]; /* parent-space byte strides */
  /* Parent-space element strides (= 1 byte per cell) for parent mask
     addressing; filled by the STACK_OUTER_K init whether or not the
     stack has a mask.  Caching
     here lets next_slab_axes compute mask_off without downcasting to
     CAStack (= AC3 layering goal). */
  ca_size_t         stack_parent_mask_strides[CA_RANK_MAX];
  /* When alias_mode == CA_ITER_ALIAS_STACK_OUTER_K and the CAStack
     source carries a mask, init_l2 copies the K parent masks here, read
     alongside parents[k]->ptr.  NULL when the source has no mask.  Owned
     by the iterator (xfree in finish). */
  boolean8_t      **stack_parent_mask_ptrs;        /* [n_parents] or NULL */
  /* K axis position within the outer iter axis list.  Set by init_l2
     when alias_mode == CA_ITER_ALIAS_STACK_OUTER_K; next_slab_axes uses
     outer_idx[stack_k_outer_pos] to pick the active parent. */
  int8_t            stack_k_outer_pos;
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

/* ---- alias eligibility predicate ---------------------------------------- */

/* Generalises ca_attach_is_alias (carray_core.c) so the alias decision can be
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
       view qualifies by its strides (init_l2 still gathers into scratch
       when the root it folds to lends no memory, which this predicate
       does not look at) (the innermost run, even a stride-of-1 of count 1,
       defines a valid strided slab).  Entity arrays also qualify
       trivially.  Pathological all-strided-no-contig sources still
       qualify here — the engine yields slab_n=1 with the native step;
       L1 fallback is an engine-policy choice, not an eligibility one.

     level == 3  (L3, multi-d kernel)
       Not implemented — answered as L1 so the predicate stays
       well-defined for callers that probe ahead.

   Descriptor views (CASelectAxis / CAGrid / CASelect / CAWindow /
   CAShift) and conversion views (CAFake / CAByteSwap / CABitfield /
   CABitarray) return 0 at every level.  init_l2 still reads a
   descriptor view in place when its innermost axis is a stride
   (CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE); this predicate does not
   report that case.

   ca_attach_is_alias stays the level=1 answer for its existing callers;
   new code in the kernel iterator path should call ca_iter_can_alias
   with an explicit level. */
int  ca_iter_can_alias (void *ap, int level);

/* ---- state machine ------------------------------------------------------ */

/* Initialise `st` for an **L1 (contig kernel)** walk of `src`.

   Source routing:
     - entity / CAStride contig: alias path (single slab, alias_ptr =
       src->ptr, stride implicit = bytes)
     - CAStride family non-contig: scratch path (ca_copy_data
       compose-fold gather into a malloc'd buffer)
     - descriptor views (CAGrid / CASelect / CAWindow / CAShift /
       CASelectAxis): gathered into a scratch buffer
     - SRC_ATTACH views (overlays, lazy views, CAObject, CAStack, ...,
       and any other view with an attach slot): iterator-owned scratch
       filled through ca_xfer_all
     - a source with no attach slot: CA_ITER_ERR_NOT_CHEAP

   policy: CA_SLAB_WHOLE only (CA_SLAB_AXES and CA_SLAB_FREE return
           CA_ITER_ERR_POLICY).
   flags:  any of CA_KERNEL_WRITE / CA_KERNEL_NO_MASK /
           CA_KERNEL_FIBER_CONTIG; other bits return CA_ITER_ERR_FLAGS.

   On success returns CA_ITER_OK; on error returns CA_ITER_ERR_*
   without claiming resources (finish need not be called).

   Pair with ca_iter_state_next_slab. */
int  ca_iter_state_init_l1 (ca_iter_state    *st,
                            struct _CArray   *src,
                            ca_slab_policy_t  policy,
                            int8_t           *axes,
                            int8_t            naxes,
                            uint32_t          flags);

/* Initialise `st` for an **L2 (strided kernel)** walk of `src`.

   Source routing:
     - entity / CAStride contig: alias_mode = CONTIG, the slab reads
       the source's own memory
     - CAStride non-contig: alias_mode = STRIDED, the slab reads the
       root through the composed strides, without a scratch, when the
       root lends memory; over a root that does not (a conversion view,
       a CAObject, a CAStack, ...) the view is gathered into scratch
     - descriptor views: aliased when the innermost axis is a STRIDE
       axis, otherwise gathered into scratch (per slab when a slab axis
       is an INDEX or SHIFT axis)
     - SRC_ATTACH views: iterator-owned scratch filled through
       ca_xfer_all, written back with ki_scratch_push_changed (only the
       changed cells).  A CAStack may instead be walked through its
       parents, and a single FIBER_CONTIG fiber of a cast / byte-swap
       view through ca_xfer_stride (PER_FIBER_FUSED)
     - a source with no attach slot: CA_ITER_ERR_NOT_CHEAP

   policy: CA_SLAB_AXES only.  CA_SLAB_WHOLE and CA_SLAB_FREE return
           CA_ITER_ERR_POLICY, as do out-of-range or duplicate axes,
           and a descriptor view whose descriptor rank differs from the
           view's rank.  The whole array as one contiguous run is L1
           (init_l1 with CA_SLAB_WHOLE); one strided run per innermost
           row is CA_SLAB_AXES with the last axis.
   flags:  as init_l1.  A CA_KERNEL_WRITE walk over a descriptor view
           whose slab has an INDEX or SHIFT axis goes by the transfer
           walk.

   Pair with ca_iter_state_next_slab_axes. */
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
   and same n).  Kernels use the CA_FOR_EACH_UNMASKED macro family
   (below, in this header) to skip masked cells.

   The mask is an input.  What it points at is a copy -- taken when the
   walk began, or, on the per-fiber fused path, gathered for each fiber
   -- so writing through it changes nothing -- not even under
   CA_KERNEL_WRITE, where the value half of the same yield is often a
   live alias.  It also cannot express the thing an author would most
   want it for: an unmasked source yields NULL, so there is nowhere to
   record that a cell has become undefined.  A kernel authors its
   output mask on its own output array instead:

       if ( op_mask == NULL ) {
         ca_create_mask(co);
         op_mask = (boolean8_t *) co->mask->ptr;
       }
       op_mask[out_i] = 1;

   which is what every kernel in carray does (carray_hold.c, and the
   reduction kernels mkkernel emits). */
int  ca_iter_state_next_slab (ca_iter_state *st,
                              char         **out_ptr,
                              boolean8_t   **out_mask,
                              ca_size_t     *out_n);

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
   next_slab_axes + kernel invocation; the alias_mode branch lives
   inside the state machine so the caller never has to inspect it.

   Behaviour:
     - !(flags & CA_KERNEL_WRITE): no-op (READ walk)
     - per-fiber gather (CA_KERNEL_FIBER_CONTIG on a strided fiber):
       the fiber is scattered back from its scratch first
     - CAStack walked through its parents: READ only, no-op
     - per-fiber fused (CA_ITER_ALIAS_PER_FIBER_FUSED): the fiber is put
       back through the view with ca_xfer_stride
     - alias path (scratch_ptr == NULL): no-op — kernel wrote through
       alias_ptr.  When the alias is into a view root's own buffer, that
       buffer is written back once, by finish (ca_sync_detach)
     - scratch path, at L1 or L2: the cells the kernel changed are sent
       back through the source (ki_scratch_push_changed: ca_xfer_addrs,
       or ca_xfer_all PUT when every cell changed); a write over a
       descriptor view takes this path, opened as a transfer walk

   A view that shows one root cell more than once (a repeated index, a
   tile, a stack or meld holding the same parent twice): which of the
   values written to its positions the root cell ends with is not
   specified.  It depends on the route, and a value equal to the one
   delivered is not sent back.  The same holds for a view that reads
   several root cells as one (the mask of a refer to a wider type, which
   is the OR of the cells under it): a cell written with the value it
   was delivered is not sent back, so what its root cells end with is
   not specified. */
void ca_iter_state_sync_slab (ca_iter_state *st);

/* Release any resources held by `st` and detach parent.  On a WRITE
   walk with a root, the root is synced before it is detached
   (ca_sync_detach); a slab still handed out from scratch is dropped, not
   written back (ca_iter_state_close writes it back first).  Idempotent:
   a second call is a no-op.  Also safe after a failed init, which holds
   nothing to release (the call is then not required). */
void ca_iter_state_finish (ca_iter_state *st);

/* Open `st` as the second state of a walk whose first state is already
   open -- an input and an output walked together.  Takes what
   ca_iter_state_init_l2 takes, plus `first`.

   The two are then finished together when either walk raises (a gather
   or a write-back through a source's slots): each is open in the
   caller's frame, and the raise would jump over the other's finish.  If
   opening `st` raises, or is declined (the code is returned), `first` is
   finished here, so the caller has nothing left to close.

   When `st` writes (CA_KERNEL_WRITE), `first` reads, both walk by
   CA_SLAB_AXES, and their arrays live in the same root, `first` is
   reopened on a copy of its array taken before anything is written, so
   the kernel reads the values the input held when the walk began.  Two
   walks opened separately with ca_iter_state_init_l2 know nothing of
   each other: a read walk over memory a write walk writes into must be
   given a copy by the caller. */
int  ca_iter_state_init_l2_paired (ca_iter_state    *st,
                                   ca_iter_state    *first,
                                   struct _CArray   *src,
                                   ca_slab_policy_t  policy,
                                   int8_t           *axes,
                                   int8_t            naxes,
                                   uint32_t          flags);

/* Finish a walk as the block macros leave it: when the body left a write
   walk with `break`, the slab it was in is written back before the walk is
   finished.  ca_iter_state_finish alone drops such a slab when it sits in
   scratch (writes through an alias are already in place). */
void ca_iter_state_close (ca_iter_state *st);

/* Raise unless rc is CA_ITER_OK.  The block macros call this on the value
   ca_iter_state_init_l2 / _l2_paired returned, so an author who never looks at a
   return code still hears about a request the iterator would not serve.
   Returns rc when there is nothing to report, so it composes inside the
   macros' comma expressions. */
int ca_iter_check_init (int rc);

/* Raise ArgumentError unless the two arrays have the same shape.  The
   INOUT, SLAB_INOUT and PAIR macros call this before opening either
   walk. */
int ca_iter_check_same_shape (struct _CArray *a, struct _CArray *b);

/* Run body(arg) so that the walks in states[0..n) are finished however the
   body leaves: by returning, by `break`, or by raising.

   A walk releases what it holds in ca_iter_state_finish, and a body that
   raises jumps over the finish -- the block macros put it in the `for`
   increment, and a hand-written walk has it after the loop.  A body that
   calls back into Ruby (an object-lane kernel) can raise at any cell, so
   it runs through this function.

   The states belong to the caller's frame, not to the body's: after a
   raise, the body's frame is gone, and the cleanup runs where it was.
   Pass them to the body inside `arg` and open each one there, with
   ca_iter_state_init_* or a block macro (`CA_FOR_EACH_SLAB(c->st, ...)`).
   A state declared inside the body is not covered.

   The states are marked unopened before the body runs, so one the body
   never opens costs nothing, and the body may finish a walk itself:
   finishing is idempotent.  Returns what the body returns; a raise propagates
   after the walks are finished. */
VALUE ca_iter_ensure (int32_t n, ca_iter_state *states,
                      VALUE (*body)(VALUE), VALUE arg);

/* ---- kernel author block macros -----------------------------------------

   Wrap init_l2 / next_slab_axes / [sync_slab] / finish in a single
   block scope so kernel authors don't write lifecycle plumbing.

   For a function in carray that uses each macro, see the catalog in
   docs/authoring/HOW_TO_WRITE_KERNEL.md §0.1.

   --- Constraints ---

   - Author must pre-declare `char *p` and `boolean8_t *m` (or names of
     their choice).  C99 doesn't permit two different-typed declarations
     in a `for` init clause, so the slab/mask cursors live in the
     surrounding scope.
   - `flags` arg propagates to init_l2 (= CA_KERNEL_WRITE supported).
     `sync_slab` is called automatically after each iteration; it's a
     no-op when WRITE flag is absent.  The mask cursor is an input even
     under WRITE -- see ca_iter_state_next_slab above for why, and for
     where an output mask is written instead.
   - Init failure (ca_iter_state_init_l2 returns CA_ITER_ERR_*) raises:
     the macro passes the code to ca_iter_check_init, which reports what
     the iterator declined to do.  The body does not run and finish is
     not reached, which is safe because a failed init allocates nothing.
     Kernels that want to handle a refusal rather than propagate it
     should drop down to the raw API and read the code themselves.
   - `break;` from inside the body exits the loop AND triggers finish
     correctly (= outer for's "increment" clause runs once on natural
     exit; `break` from the inner while breaks both).  In a write walk
     the macros close with ca_iter_state_close, which writes back the
     slab the body was in.  `return` inside
     the body LEAKS resources (scratch_ptr, parent attach) — drop to
     raw API if early return is needed.  A body that raises leaks the
     same way: the engine releases what it holds when the walk itself
     raises (a gather or a write-back through the source's slots), but
     the body runs in the caller's frame, where it has no hold on it.
     A body that can raise -- one that calls back into Ruby, as an
     object-lane kernel does -- runs through ca_iter_ensure, with the
     state in the caller's frame.
   - Macros are not statement-equivalent (= they expand to nested for
     constructs).  Don't follow them with `else` etc. */

/* ---- mask helper macro ---------------------------------------------------
   This macro lets a kernel handle masked sources
   uniformly: pass NULL for `mask` if the source has no mask (= treat
   all cells as unmasked), or a `boolean8_t *` of length n where
   non-zero entries indicate masked (= "skip this cell").
   --------------------------------------------------------------------- */

#define CA_FOR_EACH_UNMASKED(p, mask, n, body) do { \
    ca_size_t _ca_i; \
    if (mask) { \
        for (_ca_i = 0; _ca_i < (n); _ca_i++) if (!(mask)[_ca_i]) { body } \
    } else { \
        for (_ca_i = 0; _ca_i < (n); _ca_i++) { body } \
    } \
} while (0)

/* ---- L2 inner-loop macro ------------------------------------------------
   `CA_L2_FOR_EACH(T, ptr, n, stride, p, body)` wraps the strided
   callback signature `(ptr, n, stride_bytes)` with a
   `stride == sizeof(T)` fast-path branch.  When the runtime stride
   matches the element size, `body` runs against a `T *p` that the
   compiler can autovectorise; when it doesn't, `p` is recomputed per
   iteration with the runtime stride.

   The split is intentional: L2 strided callbacks are deliberately
   universal — they accept arbitrary stride and so the compiler cannot
   prove contig on the kernel-side loop.  When the iterator hands a
   contig scratch (a gathered view, stride == bytes), a loop written for
   any stride was measured 18-22% slower than a contiguous one.  This
   macro lets kernel authors recover the contig autovectorisation
   without giving up the L2 surface.

   This is the standard pattern for L2 kernels: write the body once,
   the macro picks the right loop shape.  The walk stays the same for
   every source; the loop shape is the kernel's knob for speed.

   Usage:
     CA_L2_FOR_EACH(double, ptr, n, stride, p, {
         *p = value;          // p is `double *`
     });

   Plain C99 (a do/while block with for-loop declarations). */

#define CA_L2_FOR_EACH(T, ptr, n, stride, p, body) do { \
    typedef T __ca_u_T CA_UNALIGNED; \
    ca_size_t   _l2_n = (n); \
    ca_size_t   _l2_s = (stride); \
    char       *_l2_b = (char *)(ptr); \
    if (_l2_s == sizeof(T)) { \
        __ca_u_T *p = (__ca_u_T *)_l2_b; \
        for (ca_size_t _l2_i = 0; _l2_i < _l2_n; _l2_i++) { \
            body \
            p++; \
        } \
    } else { \
        for (ca_size_t _l2_i = 0; _l2_i < _l2_n; _l2_i++) { \
            __ca_u_T *p = (__ca_u_T *)(_l2_b + _l2_i * _l2_s); \
            body \
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
  for ( int __caf_init = (ca_iter_check_init(                                 \
                            ca_iter_state_init_l2(&(st), (ca), CA_SLAB_AXES,  \
                                                  (axes), (naxes), (flags))), \
                          1);                                                 \
        __caf_init;                                                           \
        __caf_init = 0, ca_iter_state_close(&(st)) )                          \
    for ( ; ca_iter_state_next_slab_axes(&(st), &(p), &(m));                  \
            ca_iter_state_sync_slab(&(st)) )

/* CA_FOR_EACH_SLAB_INOUT: parallel iter for map kernels (= input view
   + same-shape output view).  Author pre-declares two state structs,
   two slab cursors, two mask cursors.  Input iter runs READ-only,
   output iter runs WRITE; sync_slab is called on output after each
   body iteration.

   ca_in and ca_out must have the same shape (ndim and every dim[k]);
   ca_iter_check_same_shape raises ArgumentError before either walk is
   opened when they do not.  Init failure on either iter raises — see
   CA_FOR_EACH_SLAB above. */
/* Policy fixed to CA_SLAB_AXES internally — see CA_FOR_EACH_SLAB above. */
#define CA_FOR_EACH_SLAB_INOUT(st_in, st_out, ca_in, ca_out,                  \
                               axes, naxes,                                   \
                               p_in, p_out, m_in, m_out)                      \
  for ( int __cafi_init = (                                                   \
            ca_iter_check_same_shape((ca_in), (ca_out)),                      \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2(&(st_in),  (ca_in),  CA_SLAB_AXES,        \
                                    (axes), (naxes), 0)),                     \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2_paired(&(st_out), &(st_in), (ca_out), \
                                    CA_SLAB_AXES,                             \
                                    (axes), (naxes), CA_KERNEL_WRITE)),       \
            1);                                                               \
        __cafi_init;                                                          \
        __cafi_init = 0,                                                      \
          ca_iter_state_close(&(st_in)),                                      \
          ca_iter_state_close(&(st_out)) )                                    \
    for ( ; ca_iter_state_next_slab_axes(&(st_in),  &(p_in),  &(m_in)) &&     \
            ca_iter_state_next_slab_axes(&(st_out), &(p_out), &(m_out));      \
            ca_iter_state_sync_slab(&(st_out)) )

/* ---- per-axis fiber macros ----------------------------------------------

   Author-facing surface for "deliver one contig fiber along `axis` to
   the kernel".  Contig delivery is contract:
     - data: contig (= author writes p[i] / p_out[i] without stride math)
     - mask (MASKED forms): contig (= author writes m[i]; m is NULL for
       no-mask source, author NULL-checks before access)
     - output (INOUT forms): contig same as data; CA_KERNEL_WRITE auto-set

   The CA_KERNEL_FIBER_CONTIG flag is auto-set; engine gathers strided
   fibers into per-state scratch when slab_strides[0] != bytes.

   `axis`, `ca`, `ca_in` and `ca_out` may be evaluated more than once:
   pass variables, not expressions with side effects.  `n` is set to the
   fiber length (= slab_dims[0], constant per walk).

   The forms without MASKED in the name hand out no mask cursor: a masked
   source is walked with its masked cells read as values.  Pass
   CA_KERNEL_NO_MASK to have a masked source refused, or use a MASKED
   form to see the mask.

   Same constraints as CA_FOR_EACH_SLAB family:
     - `break;` from body exits cleanly (finish runs, and a write walk
       writes back the fiber it was in).
     - `return;` from body LEAKS scratch / parent attach -- use raw API.
     - Macros are NOT statement-equivalent (nested for); no trailing else.

   INOUT forms (form 2 / 4) require `ca_in` and `ca_out` to have the same
   shape (ndim and every dim[k]), and raise ArgumentError before opening
   either walk when they do not.  Authors that need broadcasting must
   drop to raw API. */

#define CA_FOR_EACH_FIBER(st, ca, axis, flags, p, n)                          \
  for ( int __cff_init = (                                                    \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2(&(st), (ca), CA_SLAB_AXES,                \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    (flags) | CA_KERNEL_FIBER_CONTIG)),       \
            (n) = (st).slab_dims[0],                                          \
            1);                                                               \
        __cff_init;                                                           \
        __cff_init = 0, ca_iter_state_close(&(st)) )                          \
    for ( ; ca_iter_state_next_slab_axes(&(st), &(p), NULL);                  \
            ca_iter_state_sync_slab(&(st)) )

#define CA_FOR_EACH_FIBER_MASKED(st, ca, axis, flags, p, n, m)                \
  for ( int __cffm_init = (                                                   \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2(&(st), (ca), CA_SLAB_AXES,                \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    (flags) | CA_KERNEL_FIBER_CONTIG)),       \
            (n) = (st).slab_dims[0],                                          \
            1);                                                               \
        __cffm_init;                                                          \
        __cffm_init = 0, ca_iter_state_close(&(st)) )                         \
    for ( ; ca_iter_state_next_slab_axes(&(st), &(p), &(m));                  \
            ca_iter_state_sync_slab(&(st)) )

/* INOUT form 2.  Output gets CA_KERNEL_WRITE auto-set.  The shapes are
   checked first (ca_iter_check_same_shape). */
#define CA_FOR_EACH_FIBER_INOUT(st_in, st_out, ca_in, ca_out, axis,           \
                                flags, p_in, p_out, n)                        \
  for ( int __cffi_init = (                                                   \
            ca_iter_check_same_shape((ca_in), (ca_out)),                      \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2(&(st_in),  (ca_in),  CA_SLAB_AXES,        \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    (flags) | CA_KERNEL_FIBER_CONTIG)),       \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2_paired(&(st_out), &(st_in), (ca_out), \
                                    CA_SLAB_AXES,                             \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    ((flags) | CA_KERNEL_FIBER_CONTIG         \
                                             | CA_KERNEL_WRITE))),            \
            (n) = (st_in).slab_dims[0],                                       \
            1);                                                               \
        __cffi_init;                                                          \
        __cffi_init = 0,                                                      \
          ca_iter_state_close(&(st_in)),                                      \
          ca_iter_state_close(&(st_out)) )                                    \
    for ( ; ca_iter_state_next_slab_axes(&(st_in),  &(p_in),  NULL)           \
         && ca_iter_state_next_slab_axes(&(st_out), &(p_out), NULL);          \
            ca_iter_state_sync_slab(&(st_in)),                                \
            ca_iter_state_sync_slab(&(st_out)) )

#define CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, ca_in, ca_out, axis,    \
                                       flags, p_in, p_out, n, m)              \
  for ( int __cffim_init = (                                                  \
            ca_iter_check_same_shape((ca_in), (ca_out)),                      \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2(&(st_in),  (ca_in),  CA_SLAB_AXES,        \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    (flags) | CA_KERNEL_FIBER_CONTIG)),       \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2_paired(&(st_out), &(st_in), (ca_out), \
                                    CA_SLAB_AXES,                             \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    ((flags) | CA_KERNEL_FIBER_CONTIG         \
                                             | CA_KERNEL_WRITE))),            \
            (n) = (st_in).slab_dims[0],                                       \
            1);                                                               \
        __cffim_init;                                                         \
        __cffim_init = 0,                                                     \
          ca_iter_state_close(&(st_in)),                                      \
          ca_iter_state_close(&(st_out)) )                                    \
    for ( ; ca_iter_state_next_slab_axes(&(st_in),  &(p_in),  &(m))           \
         && ca_iter_state_next_slab_axes(&(st_out), &(p_out), NULL);          \
            ca_iter_state_sync_slab(&(st_in)),                                \
            ca_iter_state_sync_slab(&(st_out)) )

/* PAIR forms: two sources read together along the same axis.

   The INOUT forms cover input + output.  These cover input + input, which
   is what a routine taking two vectors of the same length wants -- a
   correlation, a dot product, a distance.  Neither state gets
   CA_KERNEL_WRITE, and `flags` must not carry it: use the INOUT forms to
   write.

   Both fibers are contig-delivered, so the pair may be handed straight to
   a C routine that walks it itself.  The MASKED form yields BOTH mask
   cursors: which cells a pair of fibers may be used at is a question about
   both of them, and the INOUT forms answer only about the input.

   The two sources must have the same shape, as for the INOUT forms:
   ca_iter_check_same_shape raises ArgumentError before either walk is
   opened.  The two sources may be the same array.  The second state is
   opened paired with the first, so a refusal or a raise on either side
   closes both. */

#define CA_FOR_EACH_FIBER_PAIR(st_a, st_b, ca_a, ca_b, axis,                  \
                               flags, p_a, p_b, n)                            \
  for ( int __cffp_init = (                                                   \
            ca_iter_check_same_shape((ca_a), (ca_b)),                         \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2(&(st_a), (ca_a), CA_SLAB_AXES,            \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    (flags) | CA_KERNEL_FIBER_CONTIG)),       \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2_paired(&(st_b), &(st_a), (ca_b),          \
                                    CA_SLAB_AXES,                             \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    (flags) | CA_KERNEL_FIBER_CONTIG)),       \
            (n) = (st_a).slab_dims[0],                                        \
            1);                                                               \
        __cffp_init;                                                          \
        __cffp_init = 0,                                                      \
          ca_iter_state_close(&(st_a)),                                       \
          ca_iter_state_close(&(st_b)) )                                      \
    for ( ; ca_iter_state_next_slab_axes(&(st_a), &(p_a), NULL)               \
         && ca_iter_state_next_slab_axes(&(st_b), &(p_b), NULL);              \
            ca_iter_state_sync_slab(&(st_a)),                                 \
            ca_iter_state_sync_slab(&(st_b)) )

#define CA_FOR_EACH_FIBER_PAIR_MASKED(st_a, st_b, ca_a, ca_b, axis,           \
                                      flags, p_a, p_b, n, m_a, m_b)           \
  for ( int __cffpm_init = (                                                  \
            ca_iter_check_same_shape((ca_a), (ca_b)),                         \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2(&(st_a), (ca_a), CA_SLAB_AXES,            \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    (flags) | CA_KERNEL_FIBER_CONTIG)),       \
            ca_iter_check_init(                                               \
              ca_iter_state_init_l2_paired(&(st_b), &(st_a), (ca_b),          \
                                    CA_SLAB_AXES,                             \
                                    (int8_t[]){(int8_t)(axis)}, 1,            \
                                    (flags) | CA_KERNEL_FIBER_CONTIG)),       \
            (n) = (st_a).slab_dims[0],                                        \
            1);                                                               \
        __cffpm_init;                                                         \
        __cffpm_init = 0,                                                     \
          ca_iter_state_close(&(st_a)),                                       \
          ca_iter_state_close(&(st_b)) )                                      \
    for ( ; ca_iter_state_next_slab_axes(&(st_a), &(p_a), &(m_a))             \
         && ca_iter_state_next_slab_axes(&(st_b), &(p_b), &(m_b));            \
            ca_iter_state_sync_slab(&(st_a)),                                 \
            ca_iter_state_sync_slab(&(st_b)) )

/* ---- whole-array block macros -------------------------------------------

   Hand the kernel the whole array as one contiguous run of cells in
   row-major order: `p` is the first cell and `n` is the number of cells
   (src->elements).  The body runs once.

     CA_FOR_EACH_WHOLE       (st, ca, flags, p, n)      data only
     CA_FOR_EACH_WHOLE_MASKED(st, ca, flags, p, n, m)   + mask m[0..n-1],
                                                        NULL when the
                                                        source has none

   Use them for a kernel that wants every cell in order and no axes: a
   whole-array scan, a hash of the values, a copy into a library buffer.
   A reduction that also runs per axis is better written once with
   CA_FOR_EACH_SLAB over the chosen axes (every axis for the whole array).

   Contiguity is the promise, and it is kept by copying when it has to be:
   a contiguous array lends its memory, any other source is gathered into
   the walk's scratch first (a transpose, a strided block, a selection, a
   converting view).  A kernel that can take strides and wants to avoid
   that copy uses CA_FOR_EACH_SLAB over every axis instead.

   Same rules as CA_FOR_EACH_SLAB and the CA_FOR_EACH_FIBER family:
     - `p` and the mask cursor are declared by the caller; `n` receives the
       cell count.  `ca` may be evaluated more than once.
     - Init failure raises (ca_iter_check_init); the body does not run.
     - The form without MASKED hands out no mask cursor: masked cells are
       read as values.  Pass CA_KERNEL_NO_MASK to refuse a masked source.
       The mask cursor of the MASKED form is a copy; writing it reaches
       nothing.
     - With CA_KERNEL_WRITE the cells the kernel changed are written back
       when the body ends, including by `break`.
     - `return` from the body leaks what the walk holds.  So does a body
       that raises: one that can raise -- one that calls back into Ruby --
       opens the macro inside ca_iter_ensure, with the state in the
       caller's frame.  A write that raises keeps the cells already
       written where the walk lends the array's memory, and none of them
       where it gathered a copy.
     - Not statement-equivalent (nested `for`); no trailing `else`. */

#define CA_FOR_EACH_WHOLE(st, ca, flags, p, n)                                \
  for ( int __cfw_init = (ca_iter_check_init(                                 \
                            ca_iter_state_init_l1(&(st), (ca), CA_SLAB_WHOLE, \
                                                  NULL, 0, (flags))),         \
                          1);                                                 \
        __cfw_init;                                                           \
        __cfw_init = 0, ca_iter_state_close(&(st)) )                          \
    for ( ; ca_iter_state_next_slab(&(st), &(p), NULL, &(n));                 \
            ca_iter_state_sync_slab(&(st)) )

#define CA_FOR_EACH_WHOLE_MASKED(st, ca, flags, p, n, m)                      \
  for ( int __cfwm_init = (ca_iter_check_init(                                \
                             ca_iter_state_init_l1(&(st), (ca), CA_SLAB_WHOLE,\
                                                   NULL, 0, (flags))),        \
                           1);                                                \
        __cfwm_init;                                                          \
        __cfwm_init = 0, ca_iter_state_close(&(st)) )                         \
    for ( ; ca_iter_state_next_slab(&(st), &(p), &(m), &(n));                 \
            ca_iter_state_sync_slab(&(st)) )

/* ---- per-data_type reduction macro suite ------------------------------- */

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

   T is the load type: double, float, int32_t, int64_t, or any other
   element type (boolean8_t, int8_t, uint16_t, ...).

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
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
              T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                 \
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
   don't need it.  The generated reductions use the _EX forms (or their
   SIMD / 8-way variants); CA_SLAB_REDUCE_T is for hand-written kernels
   that do not need the masked count. */
#define CA_SLAB_REDUCE_T(T, st, p, m, acc, INIT, REDUCE) do {                \
    ca_size_t __sr_throwaway_mc = 0;                                         \
    CA_SLAB_REDUCE_T_EX(T, st, p, m, acc, INIT, REDUCE, __sr_throwaway_mc);  \
    (void) __sr_throwaway_mc;                                                \
  } while (0)

/* ----------------------------------------------------------------------
 * SIMD-licensed reduction variants
 *
 * The PLUS/MIN/MAX/STAR _EX variants below carry, in their contiguous
 * no-mask branch, `#pragma omp simd reduction(<kind>:acc)`, which
 * licenses the compiler to reassociate the reduction (results are
 * epsilon-close, not bit-exact).  VAR_EX forwards to PLUS_EX and has no
 * caller.  The pragma is emitted via the
 * _Pragma + _CA_XSTR substitution helpers below so the acc lvalue
 * can be parameterised.
 *
 * The pragma is a no-op on compilers that don't support `-fopenmp-simd`
 * (extconf.rb probe — graceful degradation, code stays correct).
 * --------------------------------------------------------------------*/

#define _CA_STR(x)        #x
#define _CA_XSTR(x)       _CA_STR(x)
#define _CA_SIMD_PLUS(var)  _Pragma(_CA_XSTR(omp simd reduction(+:var)))
#define _CA_SIMD_MIN(var)   _Pragma(_CA_XSTR(omp simd reduction(min:var)))
#define _CA_SIMD_MAX(var)   _Pragma(_CA_XSTR(omp simd reduction(max:var)))
#define _CA_SIMD_STAR(var)  _Pragma(_CA_XSTR(omp simd reduction(*:var)))

/* CA_SLAB_REDUCE_T_PLUS_EX:
 *   Same structure as CA_SLAB_REDUCE_T_EX, but the **no-mask + contig**
 *   inner loop carries `#pragma omp simd reduction(+:acc)` so clang/gcc
 *   are licensed to reassoc the accumulator and emit SIMD reduction
 *   sequences.  All other branches (masked-contig, non-contig, masked-
 *   non-contig) are byte-identical to _EX: a SIMD reduction there would
 *   need an output-buffered loop interchange.
 *
 *   Measured: N=1M f64 sum 906 us -> 116 us (= 7.8x, 68.8 GB/s).
 *   Parity: ε-close (relative error < 2e-16 for f64 sum), bit-exact
 *   not guaranteed (= the SIMD license; see guides/devel/11_kernel_iterator.md).
 *
 *   Other state vars referenced inside REDUCE (induction counters
 *   like `cnt`, position counters like `idx`) are auto-vectorised
 *   by the compiler when their update is a simple ++ pattern.
 */
#define CA_SLAB_REDUCE_T_PLUS_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          _CA_SIMD_PLUS(acc)                                                 \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
              T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                 \
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

/* CA_SLAB_REDUCE_SUM8_EX:
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
 *   (bit-exact not guaranteed; see guides/devel/11_kernel_iterator.md).
 *
 *   Only the no-mask + contig branch is 8-way; masked / non-contig
 *   branches stay single-accumulator (not the hot path).  Position
 *   counter `idx` is not tracked (variance REDUCE never uses it).  ACC_T
 *   is the accumulator C type (double for Pass 1 sum on numeric/bool and
 *   Pass 2 M2; complex Pass 1 passes its complex type).  mkkernel.rb
 *   emits it for every 8-way-eligible _PLUS reduction (sum, mean, and
 *   both passes of variance / stddev).
 */
#define CA_SLAB_REDUCE_SUM8_EX(T, ACC_T, st, p, m, acc, INIT, EXPR, masked_cnt) do { \
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
            T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                   \
            (acc) += EXPR(v);                                                \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) { T v = __srSrc[__sj]; (acc) += EXPR(v); } \
            else { (masked_cnt)++; }                                         \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                 \
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

/* CA_SLAB_REDUCE_MIN8_EX / _MAX8_EX / _STAR8_EX (the SUM8_EX pattern for
 * the other standard reducers):
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
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
            ACC_T __v = EXPR(*(const __ca_u_T *)(__srQ + __sj * __srInnerS));       \
            if (__v < (acc)) (acc) = __v;                                    \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              ACC_T __v = EXPR(__srSrc[__sj]);                               \
              if (__v < (acc)) (acc) = __v;                                  \
            } else { (masked_cnt)++; }                                       \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              ACC_T __v = EXPR(*(const __ca_u_T *)(__srQ + __sj * __srInnerS));     \
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
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
            ACC_T __v = EXPR(*(const __ca_u_T *)(__srQ + __sj * __srInnerS));       \
            if (__v > (acc)) (acc) = __v;                                    \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) {                                          \
              ACC_T __v = EXPR(__srSrc[__sj]);                               \
              if (__v > (acc)) (acc) = __v;                                  \
            } else { (masked_cnt)++; }                                       \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              ACC_T __v = EXPR(*(const __ca_u_T *)(__srQ + __sj * __srInnerS));     \
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
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
            T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                   \
            (acc) *= EXPR(v);                                                \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj] ) { T v = __srSrc[__sj]; (acc) *= EXPR(v); } \
            else { (masked_cnt)++; }                                         \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            if ( ! __srMM[__sj * __srInnerMS] ) {                            \
              T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                 \
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

/* CA_SLAB_REDUCE_T_MIN_EX (emitted by the kernel generator; not author surface):
 *   Same structure as PLUS_EX; no-mask + contig inner loop carries
 *   `#pragma omp simd reduction(min:acc)`.  The :min kernel in
 *   mkkernel.rb writes REDUCE as `acc = (v < acc) ? v : acc`, which
 *   matches OpenMP `min:` reduction semantics exactly — bit-exact
 *   parity preserved (no reassoc license needed; min/max are
 *   associative + commutative under `<` / `>`).
 *
 *   NaN behaviour: `(NaN < x)` is false in C, so NaN never wins
 *   the comparison.  Final acc for all-NaN slab stays at INIT
 *   (T_LIMIT_HI), matching the pre-SIMD path byte-identically.
 */
#define CA_SLAB_REDUCE_T_MIN_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          _CA_SIMD_MIN(acc)                                                  \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
              T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                 \
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

/* CA_SLAB_REDUCE_T_MAX_EX (generator-only): same as MIN_EX with `_CA_SIMD_MAX`. */
#define CA_SLAB_REDUCE_T_MAX_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          _CA_SIMD_MAX(acc)                                                  \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
              T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                 \
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

/* CA_SLAB_REDUCE_T_STAR_EX (emitted by the kernel generator; not author surface):
 *   Same structure as PLUS_EX; no-mask + contig inner loop carries
 *   `#pragma omp simd reduction(*:acc)`.  Used by :prod kernel
 *   (acc *= v).  f64 / f32 multiplication parity is ε-close (same
 *   reassoc license as PLUS_EX); integer multiplication is bit-exact
 *   under reassoc (associative + commutative on bounded-precision
 *   integers).
 */
#define CA_SLAB_REDUCE_T_STAR_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt) do { \
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
          _CA_SIMD_STAR(acc)                                                 \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = __srSrc[__sj];                                             \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __sj = 0; __sj < __srInnerN; __sj++ ) {            \
            T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                   \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__srMM = (const boolean8_t *)(m) + __srMoff;       \
        if ( __srContig && __srMaskU ) {                                     \
          const __ca_u_T *__srSrc = (const __ca_u_T *) __srQ;                              \
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
              T v = *(const __ca_u_T *)(__srQ + __sj * __srInnerS);                 \
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

/* Multi-acc variant (two accumulators).  No kernel uses it: variance /
 * stddev are computed in two passes (Σx for the mean, then Σ(x-mean)^2),
 * each a single-accumulator reduction through SUM8_EX / PLUS_EX.
 *
 * VAR_EX is kept as a stub for a future multi-accumulator reduction
 * that does not share the variance pattern (primary + derived sumsq).
 * The stub forwards to PLUS_EX on acc1; acc2 is zero-initialised but
 * otherwise left to the enclosing REDUCE expression.  This is safe
 * because no kernel dispatches to VAR_EX (reduce_macro_suffix never
 * returns "_VAR"; the reduce DSL has no :var value).
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
     - T_W:        second-operand element C type (load type).  The
                   production kernels read the weight as double
                   (mkkernel array_arg: data_type: :promote), so T_W need
                   not match T.  Kept separate in the
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
   source mask by the dispatcher). */
#define CA_SLAB_REDUCE_ARRAY_T_EX(T, T_W, st, p, m, st_w, p_w, acc, INIT, REDUCE, masked_cnt) do { \
    typedef T_W __ca_u_T_W CA_UNALIGNED;                                     \
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T   *__sraSrc = (const __ca_u_T *) __sraQ;                        \
          const __ca_u_T_W *__sraWgt = (const __ca_u_T_W *) __sraWQ;                       \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            T   v = __sraSrc[__saj];                                         \
            T_W w = __sraWgt[__saj];                                         \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            T   v = *(const __ca_u_T *)(__sraQ  + __saj * __sraInnerS);           \
            T_W w = *(const __ca_u_T_W *)(__sraWQ + __saj * __sraInnerWS);          \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__sraMM = (const boolean8_t *)(m) + __sraMoff;     \
        if ( __sraContig && __sraContigW && __sraMaskU ) {                   \
          const __ca_u_T   *__sraSrc = (const __ca_u_T *) __sraQ;                        \
          const __ca_u_T_W *__sraWgt = (const __ca_u_T_W *) __sraWQ;                       \
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
              T   v = *(const __ca_u_T *)(__sraQ  + __saj * __sraInnerS);         \
              T_W w = *(const __ca_u_T_W *)(__sraWQ + __saj * __sraInnerWS);        \
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

/* CA_SLAB_REDUCE_ARRAY_T_PLUS_EX:
 *   Parallel-array PLUS variant of CA_SLAB_REDUCE_ARRAY_T_EX.
 *   no-mask + both-contig inner loop carries `#pragma omp simd
 *   reduction(+:acc)`.  Used by :wsum / :wmean — author REDUCE
 *   expression is `acc += (double) v * (double) w`, which clang +
 *   `-fopenmp-simd` lowers to NEON `fmla.2d` (interleave-4) with
 *   reduction-tree merge.  Other branches (masked, non-contig)
 *   stay identical to _EX.
 *
 *   Measured:
 *     wsum  f64 N=1M: 908 us -> ~150 us   (= the expected 50-60 GB/s)
 *     wmean f64 N=1M: 1212 us -> ~150 us  (same path + 1 extra acc)
 */
#define CA_SLAB_REDUCE_ARRAY_T_PLUS_EX(T, T_W, st, p, m, st_w, p_w, acc,     \
                                       INIT, REDUCE, masked_cnt) do {        \
    typedef T_W __ca_u_T_W CA_UNALIGNED;                                     \
    typedef T __ca_u_T CA_UNALIGNED;                                         \
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
          const __ca_u_T   *__sraSrc = (const __ca_u_T *) __sraQ;                        \
          const __ca_u_T_W *__sraWgt = (const __ca_u_T_W *) __sraWQ;                       \
          _CA_SIMD_PLUS(acc)                                                 \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            T   v = __sraSrc[__saj];                                         \
            T_W w = __sraWgt[__saj];                                         \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        } else {                                                             \
          for ( ca_size_t __saj = 0; __saj < __sraInnerN; __saj++ ) {        \
            T   v = *(const __ca_u_T *)(__sraQ  + __saj * __sraInnerS);           \
            T_W w = *(const __ca_u_T_W *)(__sraWQ + __saj * __sraInnerWS);          \
            REDUCE;                                                          \
            idx++;                                                           \
          }                                                                  \
        }                                                                    \
      } else {                                                               \
        const boolean8_t *__sraMM = (const boolean8_t *)(m) + __sraMoff;     \
        if ( __sraContig && __sraContigW && __sraMaskU ) {                   \
          const __ca_u_T   *__sraSrc = (const __ca_u_T *) __sraQ;                        \
          const __ca_u_T_W *__sraWgt = (const __ca_u_T_W *) __sraWQ;                       \
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
              T   v = *(const __ca_u_T *)(__sraQ  + __saj * __sraInnerS);         \
              T_W w = *(const __ca_u_T_W *)(__sraWQ + __saj * __sraInnerWS);        \
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
   if your input is masked, see §8 Mask handling in
   docs/authoring/HOW_TO_WRITE_KERNEL.md.  Caller is responsible for invoking
   ca_iter_state_sync_slab on the output state after each slab. */
#define CA_SLAB_MAP_T(T_IN, T_OUT, st_in, p_in, st_out, p_out, MAP_EXPR) do { \
    typedef T_OUT __ca_u_T_OUT CA_UNALIGNED;                                 \
    typedef T_IN __ca_u_T_IN CA_UNALIGNED;                                   \
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
        const __ca_u_T_IN  *__mSi = (const __ca_u_T_IN *) __mQi;                          \
        __ca_u_T_OUT       *__mSo = (__ca_u_T_OUT *)       __mQo;                          \
        for ( ca_size_t __mj = 0; __mj < __mInN; __mj++ ) {                  \
          T_IN  v = __mSi[__mj];                                             \
          T_OUT r;                                                           \
          MAP_EXPR;                                                          \
          __mSo[__mj] = r;                                                   \
        }                                                                    \
      } else {                                                               \
        for ( ca_size_t __mj = 0; __mj < __mInN; __mj++ ) {                  \
          T_IN  v = *(const __ca_u_T_IN *)(__mQi + __mj * __mInS);                  \
          T_OUT r;                                                           \
          MAP_EXPR;                                                          \
          *(__ca_u_T_OUT *)(__mQo + __mj * __mOutS) = r;                            \
        }                                                                    \
      }                                                                      \
      for ( int8_t __mk = __mOuterK - 1; __mk >= 0; __mk-- ) {               \
        if ( ++__mIdx[__mk] < (st_in).slab_dims[__mk] ) break;               \
        __mIdx[__mk] = 0;                                                    \
      }                                                                      \
    }                                                                        \
  } while (0)

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
    typedef T_LOAD __ca_u_T_LOAD CA_UNALIGNED;                               \
    typedef T_OUT __ca_u_T_OUT CA_UNALIGNED;                                 \
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
          const __ca_u_T_LOAD *__ssSi = (const __ca_u_T_LOAD *) __ssQi;                     \
          __ca_u_T_OUT *__ssSo = (__ca_u_T_OUT *) __ssQo;                                   \
          for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {              \
            T_LOAD v = __ssSi[__sj];                                          \
            T_OUT  r;                                                         \
            STEP;                                                             \
            __ssSo[__sj] = r;                                                 \
          }                                                                   \
        } else {                                                              \
          for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {              \
            T_LOAD v = *(const __ca_u_T_LOAD *)(__ssQi + __sj * __ssInS);            \
            T_OUT  r;                                                         \
            STEP;                                                             \
            *(__ca_u_T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
          }                                                                   \
        }                                                                     \
      } else {                                                                \
        const boolean8_t *__ssMM = (const boolean8_t *)(m_in) + __ssMoff;     \
        for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {                \
          T_OUT r;                                                            \
          if ( ! __ssMM[__ssMaskU ? __sj : __sj * __ssInMS] ) {               \
            T_LOAD v = __ssIContig                                            \
              ? ((const __ca_u_T_LOAD *) __ssQi)[__sj]                               \
              : *(const __ca_u_T_LOAD *)(__ssQi + __sj * __ssInS);                   \
            STEP;                                                             \
          } else {                                                            \
            r = acc;   /* masked: write current running aggregate (legacy parity) */ \
          }                                                                   \
          if ( __ssOContig )                                                  \
            ((__ca_u_T_OUT *) __ssQo)[__sj] = r;                                     \
          else                                                                \
            *(__ca_u_T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
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
    typedef T_LOAD __ca_u_T_LOAD CA_UNALIGNED;                               \
    typedef T_OUT __ca_u_T_OUT CA_UNALIGNED;                                 \
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
          const __ca_u_T_LOAD *__ssSi = (const __ca_u_T_LOAD *) __ssQi;                     \
          __ca_u_T_OUT *__ssSo = (__ca_u_T_OUT *) __ssQo;                                   \
          for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {             \
            T_LOAD v = __ssSi[__sj];                                          \
            T_OUT  r;                                                         \
            STEP;                                                             \
            __ssSo[__sj] = r;                                                 \
          }                                                                   \
        } else {                                                              \
          for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {             \
            T_LOAD v = *(const __ca_u_T_LOAD *)(__ssQi + __sj * __ssInS);            \
            T_OUT  r;                                                         \
            STEP;                                                             \
            *(__ca_u_T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
          }                                                                   \
        }                                                                     \
      } else {                                                                \
        const boolean8_t *__ssMM = (const boolean8_t *)(m_in) + __ssMoff;     \
        for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {               \
          T_OUT r;                                                            \
          if ( ! __ssMM[__ssMaskU ? __sj : __sj * __ssInMS] ) {               \
            T_LOAD v = __ssIContig                                            \
              ? ((const __ca_u_T_LOAD *) __ssQi)[__sj]                               \
              : *(const __ca_u_T_LOAD *)(__ssQi + __sj * __ssInS);                   \
            STEP;                                                             \
            __ssSeen = 1;                                                     \
          } else if ( ! __ssSeen && (m_out) != NULL ) {                       \
            ((boolean8_t *)(m_out))[__ssMoBase + __sj * __ssMoStep] = 1;      \
            r = acc;   /* value slot masked; sentinel held, never read */     \
          } else {                                                            \
            r = acc;   /* masked after first present: hold running extremum */\
          }                                                                   \
          if ( __ssOContig )                                                  \
            ((__ca_u_T_OUT *) __ssQo)[__sj] = r;                                     \
          else                                                                \
            *(__ca_u_T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
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
    typedef T_LOAD __ca_u_T_LOAD CA_UNALIGNED;                               \
    typedef T_OUT __ca_u_T_OUT CA_UNALIGNED;                                 \
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
            ? ((const __ca_u_T_LOAD *) __ssQi)[__sj]                                 \
            : *(const __ca_u_T_LOAD *)(__ssQi + __sj * __ssInS);                     \
          T_OUT  r;                                                           \
          int first = __ssFirst;                                              \
          STEP;                                                               \
          __ssFirst = 0;                                                      \
          if ( __ssOContig )                                                  \
            ((__ca_u_T_OUT *) __ssQo)[__sj] = r;                                     \
          else                                                                \
            *(__ca_u_T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
        }                                                                     \
      } else {                                                                \
        const boolean8_t *__ssMM = (const boolean8_t *)(m_in) + __ssMoff;     \
        for ( ca_size_t __sj = 0; __sj < __ssInnerN; __sj++ ) {               \
          T_OUT r;                                                            \
          if ( ! __ssMM[__ssMaskU ? __sj : __sj * __ssInMS] ) {               \
            T_LOAD v = __ssIContig                                            \
              ? ((const __ca_u_T_LOAD *) __ssQi)[__sj]                               \
              : *(const __ca_u_T_LOAD *)(__ssQi + __sj * __ssInS);                   \
            int first = __ssFirst;                                            \
            STEP;                                                             \
            __ssFirst = 0;                                                    \
          } else {                                                            \
            r = (T_OUT) 0;   /* masked: neutral output for downstream OR */   \
          }                                                                   \
          if ( __ssOContig )                                                  \
            ((__ca_u_T_OUT *) __ssQo)[__sj] = r;                                     \
          else                                                                \
            *(__ca_u_T_OUT *)(__ssQo + __sj * __ssOutS) = r;                         \
        }                                                                     \
      }                                                                       \
      for ( int8_t __sk = __ssOuterK - 1; __sk >= 0; __sk-- ) {                \
        if ( ++__ssIdx[__sk] < (st_in).slab_dims[__sk] ) break;                \
        __ssIdx[__sk] = 0;                                                    \
      }                                                                       \
    }                                                                         \
  } while (0)

/* ---- Ruby surface ---------------------------------------------------- */
/* Called from Init_carray_ext (ruby_carray.c).  Creates the
   Ractor-local key for the kept scratch buffer, and in a development
   build (CARRAY_DEV_BUILD) registers the CArray.t1_* smoke entry points
   the spec_ai kernel iterator tests use. */
void Init_ca_kernel_iterator (void);

#endif /* CA_KERNEL_ITERATOR_H */
