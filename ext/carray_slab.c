/* ---------------------------------------------------------------------------

  Slab-iterator engine.

  Public surface (all on rb_cCArray, defined in Init_carray_slab):

    CArray#map_slab    (axis:, data_type: nil) { |slab| ... } -> CArray
    CArray#reduce_slab (axis:, init: <opt>, data_type: nil) { |...| ... } -> CArray
    CArray#each_slab   (axis:) { |slab| ... } -> self
    CArray#each_slab   (axis:)                -> Enumerator

  axis: accepts Integer / Array<Integer> / nil (= full-view slab = all axes).

  Internals:
    - ca_slab_iter_state_t (see carray_slab.h) is the per-call state struct.
    - Each entry point stack-allocates a zeroed state, populates it via
      slab_state_init (= nofail; only validation + scalar field fills),
      then rb_ensure-runs slab_state_run_body (= acquires T1 substrate +
      scratch + output, runs per-form loop) and slab_state_finish (= frees
      T1 state + scratch + nils the VALUE handles).
    - All heap acquisition lives in run_body so init-time rb_raise paths
      cannot leak; rb_ensure guarantees finish on both normal and
      exception exit.
    - Conservative stack scan keeps the state struct's VALUE fields alive
      across rb_yield; no dmark callback is required because the state is
      not Ruby-wrapped.

  --------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_slab.h"

/* Forward declarations: per-form loop bodies are defined later in this
   file and take a state pointer directly. */
static VALUE ca_slab_run_map          (ca_slab_iter_state_t *st);
static VALUE ca_slab_run_reduce_slab  (ca_slab_iter_state_t *st);
static VALUE ca_slab_run_reduce_fiber (ca_slab_iter_state_t *st);
static VALUE ca_slab_run_each         (ca_slab_iter_state_t *st);

/* ------------------------------------------------------------------- */
/* axis parsing helper                                                  */
/* ------------------------------------------------------------------- */

/* Parse `axis_arg` (Integer / Array<Integer> / nil) into slab_axes[] /
   slab_ndim on `st`.  Negative indices are normalised against src_ndim.
   Raises ArgumentError on out-of-range or duplicate axes. */
static void
ca_slab_parse_axes (ca_slab_iter_state_t *st, VALUE axis_arg, int8_t src_ndim)
{
  int i, j, n;
  VALUE arr;

  if ( NIL_P(axis_arg) ) {
    /* axis: nil = full-view slab (= all axes are slab axes) */
    st->slab_ndim = src_ndim;
    for ( i = 0; i < src_ndim; i++ ) st->slab_axes[i] = (int8_t) i;
    return;
  }

  if ( TYPE(axis_arg) == T_ARRAY ) {
    arr = axis_arg;
  }
  else {
    arr = rb_ary_new3(1, axis_arg);
  }

  n = (int) RARRAY_LEN(arr);
  if ( n < 1 || n > CA_RANK_MAX ) {
    rb_raise(rb_eArgError,
             "CArray::SlabIterator: axis count %d out of range [1..%d]",
             n, CA_RANK_MAX);
  }

  for ( i = 0; i < n; i++ ) {
    int k = NUM2INT(rb_ary_entry(arr, i));
    if ( k < 0 ) k += src_ndim;
    if ( k < 0 || k >= src_ndim ) {
      rb_raise(rb_eArgError,
               "CArray::SlabIterator: axis %d out of range for ndim %d",
               NUM2INT(rb_ary_entry(arr, i)), src_ndim);
    }
    for ( j = 0; j < i; j++ ) {
      if ( st->slab_axes[j] == (int8_t) k ) {
        rb_raise(rb_eArgError,
                 "CArray::SlabIterator: duplicate axis %d", k);
      }
    }
    st->slab_axes[i] = (int8_t) k;
  }
  st->slab_ndim = (int8_t) n;
}

/* ------------------------------------------------------------------- */
/* slab_state_init -- nofail population of a stack-allocated state.    */
/* ------------------------------------------------------------------- */

/* Populate `st` (= caller's stack-allocated, zero-initialised state) with
   form / source / axes / data_type / init_val.  Validation that may
   `rb_raise` (= axis range, duplicate axis, bad data_type symbol) runs
   here, BEFORE any heap acquisition — so an init-time raise leaks
   nothing.  All xmalloc / rb_carray_new / ca_iter_state_init_l2 calls
   live downstream in slab_state_run_body / ca_slab_run_*, where
   rb_ensure protects them via slab_state_finish.

     form       : CA_SLAB_FORM_{MAP, REDUCE_FIBER, REDUCE_SLAB, EACH}
     source     : VALUE pointing to the source CArray (or subclass)
     axis_arg   : VALUE — Integer / Array / nil
     data_type  : VALUE — Symbol / Integer / nil (= source.data_type).
                  Ignored when form == EACH.
     init_val   : VALUE — REDUCE_FIBER initial accumulator, or Qundef
                  if not applicable.  Stored as Qnil if Qundef.       */
static void
slab_state_init (ca_slab_iter_state_t *st, VALUE source, int8_t form,
                 VALUE axis_arg, VALUE data_type, VALUE init_val)
{
  CArray *src;

  /* Caller stack-allocates with `{0}` which sets VALUE fields to Qfalse
     (= 0). Body code uses `== Qnil` to distinguish unset slots from
     populated CArray handles, so we must promote them to Qnil here. */
  st->self             = Qnil;
  st->slab_view        = Qnil;
  st->carrier          = Qnil;
  st->mask_carrier     = Qnil;
  st->output           = Qnil;
  st->output_slab_view = Qnil;
  st->init_val         = Qnil;

  rb_check_carray_object(source);
  TypedData_Get_Struct(source, CArray, &carray_data_type, src);

  st->form = form;
  st->self = source;

  ca_slab_parse_axes(st, axis_arg, src->ndim);

  if ( form == CA_SLAB_FORM_MAP ||
       form == CA_SLAB_FORM_REDUCE_FIBER ||
       form == CA_SLAB_FORM_REDUCE_SLAB ) {
    if ( NIL_P(data_type) ) {
      st->out_data_type = src->data_type;
      st->out_bytes     = src->bytes;
    }
    else {
      int8_t dt;
      ca_size_t bytes;
      rb_ca_guess_type_and_bytes(data_type, Qnil, &dt, &bytes);
      st->out_data_type = dt;
      st->out_bytes     = bytes;
    }

    if ( form == CA_SLAB_FORM_REDUCE_FIBER ) {
      st->init_val = (init_val == Qundef) ? Qnil : init_val;
    }
  }
}

/* ------------------------------------------------------------------- */
/* MAP form loop                                                        */
/* ------------------------------------------------------------------- */

/* Slab-view modes:

   ALIAS mode  : slab_view.parent = src,        base_offset mutates per iter
                 (+ ptr mutates for fast path)
   SCRATCH mode: slab_view.parent = carrier,    base_offset = 0 (constant)
                 (carrier = internal CAWrap borrowing T1's scratch buffer;
                  per-iter ptr mutation tracks T1's possibly-realloc'd scratch)

   Both modes use CAStride (not a bare CAWrap) so that:
     - ca_stride_func_xfer_index's ptr fast path hits when ptr is
       non-NULL -- no compose-fold work per cell read.
     - ca_stride_func_clone preserves (parent, base_offset, strides), so
       `row.dup` and other derived views see the CURRENT iter's data:
         * ALIAS  : clone reads src memory directly (base_offset is
                    just-mutated, strides are src-native = correct)
         * SCRATCH: clone reads carrier (= a CAWrap borrowing T1 scratch),
                    base_offset=0, strides=contig — also correct because
                    carrier->ptr was set to the iter's scratch addr.
     - a bare CAWrap-as-slab would be correct in-block but lose the
       parent-slot GC pin in escape scenarios.

   CAREFUL: in ALIAS mode mutate both ptr AND base_offset per iter.
   The ptr fast path alone would suffice for xfer_index, but
   ca_stride_func_clone bypasses ptr and reads (parent, base_offset,
   strides) directly -- a stale base_offset there yields wrong data for
   `slab.dup` etc.  */

/* ------------------------------------------------------------------- */
/* K-D gather/scatter helpers for non-contig multi-axis                 */
/* ------------------------------------------------------------------- */

/* Test whether `strides` describe a row-major contig layout over `dims`
   in `bytes`-element units.  innermost stride must be `bytes` and each
   outer stride must be `bytes * Π later_dims`.  Single-axis collapses
   to `strides[0] == bytes`.                                            */
static int
ca_slab_strides_are_row_major_contig (int8_t ndim, ca_size_t *dims,
                                       ca_size_t *strides, ca_size_t bytes)
{
  ca_size_t expected = bytes;
  int8_t k;
  for ( k = ndim - 1; k >= 0; k-- ) {
    if ( strides[k] != expected ) return 0;
    expected *= dims[k];
  }
  return 1;
}

/* K-D gather: row-major walk over (ndim, dims), copy each cell from
   src_base + Σ idx[k] * src_strides[k]  into  dst + i * bytes.  dst is
   a contig buffer of size (Π dims) * bytes.                            */
static void
ca_slab_gather_k_d (char *dst, char *src_base,
                    int8_t ndim, ca_size_t *dims,
                    ca_size_t *src_strides, ca_size_t bytes)
{
  ca_size_t kidx[CA_RANK_MAX] = { 0 };
  ca_size_t total = 1;
  ca_size_t i;
  int8_t k;
  for ( k = 0; k < ndim; k++ ) total *= dims[k];
  for ( i = 0; i < total; i++ ) {
    ca_size_t off = 0;
    for ( k = 0; k < ndim; k++ ) off += kidx[k] * src_strides[k];
    memcpy(dst + i * bytes, src_base + off, bytes);
    for ( k = ndim - 1; k >= 0; k-- ) {
      if ( ++kidx[k] < dims[k] ) break;
      kidx[k] = 0;
    }
  }
}

/* K-D scatter: row-major walk from contig src to dst_base via dst_strides. */
static void
ca_slab_scatter_k_d (char *dst_base, char *src,
                     int8_t ndim, ca_size_t *dims,
                     ca_size_t *dst_strides, ca_size_t bytes)
{
  ca_size_t kidx[CA_RANK_MAX] = { 0 };
  ca_size_t total = 1;
  ca_size_t i;
  int8_t k;
  for ( k = 0; k < ndim; k++ ) total *= dims[k];
  for ( i = 0; i < total; i++ ) {
    ca_size_t off = 0;
    for ( k = 0; k < ndim; k++ ) off += kidx[k] * dst_strides[k];
    memcpy(dst_base + off, src + i * bytes, bytes);
    for ( k = ndim - 1; k >= 0; k-- ) {
      if ( ++kidx[k] < dims[k] ) break;
      kidx[k] = 0;
    }
  }
}

/* Build a CAStride wrapping `parent_value` (= a CArray VALUE that the
   caller has already created and GC-pinned).  ndim = 1, dim = [fiber_len],
   strides = [stride].  base_offset = 0; the caller mutates it per iter
   in ALIAS mode.  ptr is NULL initially; caller mutates it per iter to
   T1's contig delivery.  attach = 1 forces user-side ca_attach into
   the increment-only path. */
static VALUE
ca_slab_build_slab_view (VALUE parent_value, int8_t data_type,
                         ca_size_t bytes, int8_t ndim,
                         ca_size_t *dim, ca_size_t *strides)
{
  CArray *parent;
  CAStride *cs;
  VALUE obj;
  TypedData_Get_Struct(parent_value, CArray, &carray_data_type, parent);
  cs = ca_stride_new(CA_OBJ_STRIDE, parent, data_type, bytes,
                     ndim, dim, strides, 0);
  cs->attach = 1;
  cs->ptr    = NULL;
  /* Sync mask's view attach counter to match the data side.  Without
     this, a user `slab.to_a` (= ca_attach + ca_detach pair on slab_view)
     stays net-zero on the data side (attach 1->2->1) but over-detaches
     on the mask side (attach 0->1->0 invokes the mask's func.detach,
     NULLing mask->ptr that T1 owns and decrementing root mask attach
     unilaterally). */
  if ( cs->mask != NULL && ca_is_view(cs->mask) ) {
    CAVIEW(cs->mask)->attach = 1;
  }
  obj = ca_wrap_struct(cs);
  rb_ca_set_parent(obj, parent_value);
  return obj;
}

/* Build an internal CAWrap that will borrow T1's scratch buffer in
   SCRATCH mode.  This carrier is the parent slot of slab_view, so
   GC-pinning slab_view (via iter state ivar) keeps the carrier alive
   for the entire walk.  Carrier never escapes to user surface.  T1 owns
   the scratch; the slab view borrows it.  free_ca_wrap leaves ptr
   untouched, so dropping the carrier ivar at finish does NOT xfree T1's
   scratch.

   When `has_mask` is non-zero, the carrier is paired with an internal
   boolean8_t CAWrap mask whose `ptr` will track T1's fiber_mask_scratch
   per iter.  The mask is wired into `carrier->mask` directly (= bypass
   ca_setup_mask, which would try to sync data from a NULL ptr).  The
   carrier owns the mask via free_ca_wrap → ca_free(carrier->mask), so
   we DO NOT also keep the mask as a separate Ruby VALUE (= avoid double
   free via two GC chains).                                              */
static VALUE
ca_slab_build_carrier (int8_t data_type, ca_size_t bytes,
                       ca_size_t fiber_len, int has_mask)
{
  ca_size_t dim[1];
  CAWrap *cw;
  dim[0] = fiber_len;
  cw = ca_wrap_new_null(data_type, 1, dim, bytes, NULL);
  if ( has_mask ) {
    /* Build a mask sibling.  Direct field assignment bypasses
       ca_setup_mask (= which calls ca_sync_data on a NULL ptr and
       crashes).  mask_carrier is owned by carrier via free_ca_wrap chain;
       no separate Ruby pinning needed.                                   */
    CAWrap *mask_cw = ca_wrap_new_null(CA_BOOLEAN, 1, dim, 1, NULL);
    cw->mask = (CArray *) mask_cw;
    ca_set_flag(mask_cw, CA_FLAG_MASK_ARRAY);
  }
  return TypedData_Wrap_Struct(rb_cCAWrap, &cawrap_data_type, cw);
}

/* Build the OUTPUT slab view as a simple CAWrap with mutable ptr.
   Output is internal — user never derives a view from it — so the
   parent-slot GC pin / clone correctness arguments don't apply.

   ndim/dim accept K-D shape so the OUTPUT slab matches the input slab
   for multi-axis map_slab (= the block returns a K-D CArray of the same
   shape as the input slab; ca_xfer_all + p_out works as a contig memcpy
   when the output slab is row-major contig in output memory, which is
   the case for innermost-K axes on a freshly-allocated entity).        */
static VALUE
ca_slab_build_output_view (int8_t data_type, ca_size_t bytes,
                           int8_t ndim, ca_size_t *dim)
{
  CAWrap *cw;
  cw = ca_wrap_new_null(data_type, ndim, dim, bytes, NULL);
  return TypedData_Wrap_Struct(rb_cCAWrap, &cawrap_data_type, cw);
}

/* Common setup of the input slab view for all 4 forms.  Decides ALIAS
   vs SCRATCH from T1's slab_strides[0] vs src->bytes equality, builds
   the slab_view + (when SCRATCH) carrier in place.  The mask travels
   alongside data automatically (= mask has the same shape as the value
   array, so the same ALIAS / SCRATCH dispatch is used; ca_stride_setup
   auto-creates slab_view->mask over parent->mask in both modes).
   Returns 1 if ALIAS mode, 0 if SCRATCH.                              */
static int
ca_slab_setup_input_slab_view (ca_slab_iter_state_t *st, CArray *src,
                               ca_size_t fiber_len)
{
  int8_t   slab_ndim = st->t1->slab_ndim;
  int      is_multi  = (slab_ndim > 1);
  int      has_mask  = ca_has_mask(src);
  int      in_alias;

  if ( is_multi ) {
    /* Multi-axis slab.

       Two paths:
       (a) contig case (= slab_strides row-major over slab_dims): slab
           is naturally contig in src memory, enable ptr fast path with
           parent=src, base_offset mutated per iter.
       (b) non-contig case (= e.g., axis: [0, 2] on a 3-D row-major
           source): build OUR OWN gather scratch carrier (= CAWrap whose
           ptr is an xmalloc'd buffer we own), gather K-D per iter from
           p_in via slab_strides into the scratch, present slab_view as
           a CAStride over the carrier with contig strides.

       Both paths require ALIAS T1 mode (= p_in is in src memory).
       Non-ALIAS multi-axis T1 modes (= PER_SLAB scratch where T1 picks
       its own gather for descriptor-framework sources) remain
       NotImpError until a follow-on substrate phase.                   */
    uint8_t am = st->t1->alias_mode;
    int contig;
    if ( am != CA_ITER_ALIAS_CONTIG &&
         am != CA_ITER_ALIAS_STRIDED &&
         am != CA_ITER_ALIAS_ATTACH ) {
      rb_raise(rb_eNotImpError,
               "multi-axis slab with non-ALIAS T1 mode not implemented yet "
               "(alias_mode = %d)", (int) am);
    }
    contig = ca_slab_strides_are_row_major_contig(slab_ndim,
                                                  st->t1->slab_dims,
                                                  st->t1->slab_strides,
                                                  src->bytes);
    if ( contig ) {
      /* (a) contig multi-axis ALIAS: parent=src, K-D strides match src.  */
      st->slab_view = ca_slab_build_slab_view(st->self, src->data_type,
                                              src->bytes, slab_ndim,
                                              st->t1->slab_dims,
                                              st->t1->slab_strides);
      in_alias = 1;
    } else {
      /* (b) non-contig multi-axis: alloc own scratch + carrier; build
         slab_view atop carrier with row-major contig strides.  Per-iter
         gather lives in ca_slab_advance_slab_view (= K-D walk).        */
      ca_size_t elements = st->t1->slab_elements;
      ca_size_t contig_strides[CA_RANK_MAX];
      ca_size_t exp = src->bytes;
      int8_t k;
      st->own_scratch_elements = elements;
      st->own_data_scratch     = (char *) xmalloc(elements * src->bytes);
      if ( has_mask ) {
        st->own_mask_scratch   = (boolean8_t *) xmalloc(elements);
      }
      /* Carrier wraps our own scratch.  Direct field assignment of
         carrier->ptr (= bypasses ca_setup_mask which would crash on
         NULL mask ptr).  Mask sibling is similarly wired post-build. */
      {
        CAWrap *cw = ca_wrap_new_null(src->data_type, slab_ndim,
                                      st->t1->slab_dims, src->bytes, NULL);
        cw->ptr = st->own_data_scratch;
        if ( has_mask ) {
          CAWrap *mcw = ca_wrap_new_null(CA_BOOLEAN, slab_ndim,
                                         st->t1->slab_dims, 1, NULL);
          mcw->ptr = (char *) st->own_mask_scratch;
          cw->mask = (CArray *) mcw;
          ca_set_flag(mcw, CA_FLAG_MASK_ARRAY);
        }
        st->carrier = TypedData_Wrap_Struct(rb_cCAWrap, &cawrap_data_type, cw);
      }
      /* Build slab_view's strides as row-major contig over slab_dims. */
      for ( k = slab_ndim - 1; k >= 0; k-- ) {
        contig_strides[k] = exp;
        exp *= st->t1->slab_dims[k];
      }
      st->slab_view = ca_slab_build_slab_view(st->carrier, src->data_type,
                                              src->bytes, slab_ndim,
                                              st->t1->slab_dims,
                                              contig_strides);
      in_alias = 0;
    }
    (void) fiber_len;   /* unused for multi-axis */
  }
  else {
    ca_size_t in_stride = st->t1->slab_strides[0];
    ca_size_t dim[1];
    ca_size_t strides[1];
    dim[0]     = fiber_len;
    strides[0] = src->bytes;
    in_alias   = (in_stride == src->bytes);

    if ( in_alias ) {
      /* ALIAS: parent = src.  ca_stride_setup auto-creates slab_view->mask
         as a CAStride over src->mask when src has mask.  Per-iter mutates
         (ptr, base_offset) on both data and mask sides.                   */
      st->slab_view = ca_slab_build_slab_view(st->self, src->data_type,
                                              src->bytes, 1, dim, strides);
    }
    else {
      /* SCRATCH: carrier wraps T1's scratch + (when src has mask) wires
         an internal mask sibling.  slab_view is then auto-created with a
         mask CAStride over carrier->mask = mask sibling.                 */
      st->carrier = ca_slab_build_carrier(src->data_type, src->bytes,
                                          fiber_len, has_mask);
      st->slab_view = ca_slab_build_slab_view(st->carrier, src->data_type,
                                              src->bytes, 1, dim, strides);
    }
  }

  return in_alias;
}

/* Per-iter update of the slab_view + mask pointers.  Called from inside
   the form-specific loop after ca_iter_state_next_slab_axes returns the
   data ptr `p_in` and mask ptr `m_in` (= NULL for unmasked sources).
   For SCRATCH mode the data carrier's ptr is also tracked so the clone
   path (= compose-fold via carrier) reads the current iter buffer.    */
static void
ca_slab_advance_slab_view (ca_slab_iter_state_t *st,
                           CAStride *slab_cs, CAWrap *carrier_cw,
                           CArray *src, char *p_in, boolean8_t *m_in,
                           int in_alias)
{
  if ( in_alias ) {
    /* ALIAS — single-axis OR multi-axis contig.  ptr fast path uses
       ca_index2addr * bytes + ptr (= safe since slab is row-major
       contig in src memory).  base_offset is also updated so clone /
       compose-fold derived views read the same cells via src memory. */
    slab_cs->ptr         = p_in;
    slab_cs->base_offset = (ca_size_t) (p_in - src->ptr);
    if ( slab_cs->mask != NULL ) {
      CAStride *mask_cs = (CAStride *) slab_cs->mask;
      mask_cs->ptr         = (char *) m_in;
      mask_cs->base_offset = (ca_size_t) ((char *) m_in - src->mask->ptr);
    }
  } else if ( st->own_data_scratch != NULL ) {
    /* Non-contig multi-axis: K-D gather from src memory (via
       p_in + slab_strides) into our own contig scratch.  carrier_cw->
       ptr is already pointed at the scratch from setup, no mutation
       needed.  slab_view shares carrier's ptr (= contig).             */
    ca_slab_gather_k_d(st->own_data_scratch, p_in,
                       st->t1->slab_ndim, st->t1->slab_dims,
                       st->t1->slab_strides, src->bytes);
    if ( st->own_mask_scratch != NULL ) {
      ca_slab_gather_k_d((char *) st->own_mask_scratch, (char *) m_in,
                         st->t1->slab_ndim, st->t1->slab_dims,
                         st->t1->slab_mask_strides, 1);
    }
  } else {
    /* SCRATCH (single-axis): T1 owns the contig scratch; we just point
       both slab_view and carrier at the iter's delivered addr.         */
    slab_cs->ptr    = p_in;
    carrier_cw->ptr = p_in;
    if ( slab_cs->mask != NULL ) {
      CAStride *mask_cs = (CAStride *) slab_cs->mask;
      mask_cs->ptr           = (char *) m_in;
      carrier_cw->mask->ptr  = (char *) m_in;
    }
  }
}

/* Convert a Ruby Numeric scalar into bytes of slab_view's data_type and
   fill the entire slab buffer at out_ptr.  Used when the user block
   returns a scalar instead of a CArray (= broadcast over the slab).
   `slab_elements` = Π slab_dims[]  (= total cells, multi-axis K-D).    */
static void
ca_slab_fill_scalar (VALUE source, char *out_ptr, ca_size_t slab_elements,
                     int8_t out_data_type, ca_size_t out_bytes, VALUE val)
{
  char buf[64];
  char *scratch = (out_bytes <= (ca_size_t) sizeof(buf)) ? buf
                                                        : xmalloc(out_bytes);
  ca_size_t i;
  /* Use source's data_type-aware conversion (rb_ca_obj2ptr looks at the
     receiver's data_type).  Build a stand-in scalar buffer via the
     source CArray when out_data_type matches source data_type; otherwise we
     need a CArray of the output data_type to drive the conversion.  We
     accept the source-data_type default plus an explicit data_type kwarg
     that may differ — in either case the easiest path is to pull
     conversion through the actual output entity (= we already have
     `source`-keyed obj2ptr in carray_cast.c).  Here we construct an
     ephemeral CScalar of the output data_type to anchor the cast.        */
  VALUE cs_anchor =
    rb_cscalar_new_with_value((int) out_data_type, (int) out_bytes, val);
  CScalar *anchor_ca;
  (void) source;
  TypedData_Get_Struct(cs_anchor, CScalar, &cscalar_data_type, anchor_ca);
  ca_attach(anchor_ca);
  memcpy(scratch, anchor_ca->ptr, out_bytes);
  ca_detach(anchor_ca);
  for ( i = 0; i < slab_elements; i++ ) {
    memcpy(out_ptr + i * out_bytes, scratch, out_bytes);
  }
  if ( scratch != buf ) xfree(scratch);
}

static VALUE
ca_slab_run_map (ca_slab_iter_state_t *st)
{
  CArray *src;
  CArray *out;
  uint32_t flags_in;
  uint32_t flags_out;
  ca_size_t slab_elements;
  int rc;
  int is_multi = (st->slab_ndim > 1);

  TypedData_Get_Struct(st->self, CArray, &carray_data_type, src);

  /* Mask transparent carry: input mask is exposed via slab_view
     (= user's block can see slab.mask / slab.has_mask?).  Output mask
     is intentionally NOT scattered — block return CArray mask info is
     dropped (= simplest contract).                                     */

  /* Step 1: allocate output entity (same shape as src, data_type from opts). */
  st->output = rb_carray_new(st->out_data_type, src->ndim, src->dim,
                             st->out_bytes, NULL);
  TypedData_Get_Struct(st->output, CArray, &carray_data_type, out);
  ca_allocate(out);   /* entity ptr usable as both read + write target */

  /* Step 2: T1 init on both sides.  FIBER_CONTIG is naxes==1 only;
     multi-axis omits it.  Output side gets CA_KERNEL_WRITE.            */
  st->t1     = (ca_iter_state *) xmalloc(sizeof(ca_iter_state));
  st->t1_out = (ca_iter_state *) xmalloc(sizeof(ca_iter_state));

  flags_in  = is_multi ? 0 : CA_KERNEL_FIBER_CONTIG;
  flags_out = (is_multi ? 0 : CA_KERNEL_FIBER_CONTIG) | CA_KERNEL_WRITE;

  rc = ca_iter_state_init_l2(st->t1, src, CA_SLAB_AXES,
                             st->slab_axes, st->slab_ndim, flags_in);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError,
             "CArray#map_slab: T1 init (READ side) failed rc=%d", rc);
  }
  st->t1_started = 1;

  rc = ca_iter_state_init_l2(st->t1_out, out, CA_SLAB_AXES,
                             st->slab_axes, st->slab_ndim, flags_out);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError,
             "CArray#map_slab: T1 init (WRITE side) failed rc=%d", rc);
  }
  st->t1_out_started = 1;

  slab_elements = st->t1->slab_elements;

  /* Step 3: input slab view + carrier + mask plumbing (= centralises
     ALIAS / SCRATCH dispatch + mask carry + multi-axis contig +
     non-contig paths via own_data_scratch).                           */
  ca_slab_setup_input_slab_view(st, src, st->t1->slab_dims[0]);

  /* Output slab view: K-D CAWrap matching the input slab shape (= same
     slab_dims).  For non-contig multi-axis (= input went through own-
     scratch gather), allocate parallel own_out_scratch so we can scatter
     the block's result back to non-contig output memory via the K-D
     scatter helper.  For the contig case, output_slab_view wraps p_out
     directly each iter (= existing fast path).                         */
  st->output_slab_view = ca_slab_build_output_view(out->data_type,
                                                   out->bytes,
                                                   st->t1->slab_ndim,
                                                   st->t1->slab_dims);
  if ( st->own_data_scratch != NULL ) {
    st->own_out_scratch =
      (char *) xmalloc(st->own_scratch_elements * st->out_bytes);
  }

  /* Step 4: per-slab loop.
     CAREFUL: never call ca_detach(slab_view) here — the T1 buffer is
     borrowed; the slab_view's ptr would otherwise be mis-identified as
     slab_view-owned at finish/dfree and double-freed.  GC reclaims the
     CAStride / CAWrap wrappers via ivar drop in run_ensure (free_ca_stride
     and free_ca_wrap both leave ptr untouched).                       */
  {
    char *p_in, *p_out;
    boolean8_t *m_in, *m_out;
    CAStride *slab_cs;
    CAWrap   *carrier_cw = NULL;
    CAWrap   *out_slab_cw;
    int in_alias = (st->carrier == Qnil);
    TypedData_Get_Struct(st->slab_view, CAStride,
                         &castride_data_type, slab_cs);
    if ( ! in_alias ) {
      TypedData_Get_Struct(st->carrier, CAWrap,
                           &cawrap_data_type, carrier_cw);
    }
    TypedData_Get_Struct(st->output_slab_view, CAWrap,
                         &cawrap_data_type, out_slab_cw);

    while ( ca_iter_state_next_slab_axes(st->t1,     &p_in,  &m_in) &&
            ca_iter_state_next_slab_axes(st->t1_out, &p_out, &m_out) ) {
      VALUE result;

      ca_slab_advance_slab_view(st, slab_cs, carrier_cw,
                                src, p_in, m_in, in_alias);
      /* Output write target per iter:
         - contig case (= no own_out_scratch): write directly into
           p_out (= output memory at this slab's offset)
         - non-contig case (= own_out_scratch alloc'd): write into our
           contig scratch, then K-D scatter back to p_out via t1_out
           slab_strides                                                 */
      {
        char *write_target = (st->own_out_scratch != NULL)
                             ? st->own_out_scratch : p_out;
        out_slab_cw->ptr = write_target;

        result = rb_yield(st->slab_view);

        /* Strict shape check. */
        if ( rb_obj_is_kind_of(result, rb_cCArray) ) {
          CArray *res;
          int shape_ok = 0;
          TypedData_Get_Struct(result, CArray, &carray_data_type, res);
          if ( res->elements == slab_elements ) {
            if ( res->ndim == slab_cs->ndim ) {
              int8_t k;
              shape_ok = 1;
              for ( k = 0; k < res->ndim; k++ ) {
                if ( res->dim[k] != slab_cs->dim[k] ) { shape_ok = 0; break; }
              }
            }
            else if ( ! is_multi && res->ndim == 1 &&
                      res->dim[0] == slab_cs->dim[0] ) {
              shape_ok = 1;
            }
          }
          if ( ! shape_ok ) {
            rb_raise(rb_eArgError,
                     "CArray#map_slab: block result shape mismatch "
                     "(got ndim=%d, elements=%lld; expected %lld elements "
                     "in shape matching the slab, ndim=%d)",
                     (int) res->ndim, (long long) res->elements,
                     (long long) slab_elements, (int) slab_cs->ndim);
          }
          if ( res->data_type == st->out_data_type && res->bytes == st->out_bytes ) {
            ca_attach(res);
            ca_xfer_all(res, write_target, CA_XFER_GET);
            ca_detach(res);
          }
          else {
            /* Cast-on-scatter via per-cell obj2ptr.  Writes to write_target
               (= either p_out direct or own_out_scratch).               */
            char buf[64];
            char *scratch = (st->out_bytes <= (ca_size_t) sizeof(buf))
                            ? buf : xmalloc(st->out_bytes);
            ca_size_t i;
            ca_attach(res);
            for ( i = 0; i < slab_elements; i++ ) {
              VALUE elem;
              ca_size_t idx[CA_RANK_MAX] = { 0 };
              ca_size_t flat = i;
              int8_t k;
              for ( k = res->ndim - 1; k >= 0; k-- ) {
                idx[k] = flat % res->dim[k];
                flat /= res->dim[k];
              }
              elem = rb_ca_fetch_index(result, idx);
              rb_ca_obj2ptr(st->output_slab_view, elem, scratch);
              memcpy(write_target + i * st->out_bytes, scratch, st->out_bytes);
            }
            ca_detach(res);
            if ( scratch != buf ) xfree(scratch);
          }
        }
        else if ( rb_obj_is_kind_of(result, rb_cNumeric) ||
                  result == Qtrue || result == Qfalse ||
                  result == Qnil  || ca_is_object_type(out) ) {
          /* Scalar broadcast fill into write_target. */
          ca_slab_fill_scalar(st->self, write_target, slab_elements,
                              st->out_data_type, st->out_bytes, result);
        }
        else {
          rb_raise(rb_eArgError,
                   "CArray#map_slab: block must return CArray (same shape) "
                   "or Numeric scalar, got %"PRIsVALUE,
                   rb_obj_class(result));
        }

        /* Non-contig multi-axis: K-D scatter from own_out_scratch back to
           output memory at p_out via t1_out's slab_strides.            */
        if ( st->own_out_scratch != NULL ) {
          ca_slab_scatter_k_d(p_out, st->own_out_scratch,
                              st->t1_out->slab_ndim, st->t1_out->slab_dims,
                              st->t1_out->slab_strides, st->out_bytes);
        }
      }

      ca_iter_state_sync_slab(st->t1_out);
    }
  }

  return st->output;
}

/* ------------------------------------------------------------------- */
/* REDUCE forms                                                        */
/* ------------------------------------------------------------------- */

/* Common setup for the two REDUCE forms: validate scope (single-axis,
   no mask), allocate the reduced-shape output entity, init T1 READ
   side, build the input slab view with ALIAS / SCRATCH dispatch.
   Sets st->output / st->t1 / st->slab_view / st->carrier and returns
   the source CArray ptr via *out_src + the fiber length via *out_n.

   REDUCE has no WRITE-side T1; the output is filled cell-by-cell from
   the block return value via rb_ca_obj2ptr.  The output's dim is
   src->dim with the slab axis removed (1-D src reducing axis 0 = scalar
   form (ndim=1, dim=[1])).                                              */
static void
ca_slab_reduce_setup (ca_slab_iter_state_t *st, CArray **out_src,
                      ca_size_t *out_n)
{
  CArray *src;
  CArray *out;
  ca_size_t fiber_len;
  ca_size_t out_dim[CA_RANK_MAX];
  int8_t out_ndim;
  int rc;
  int8_t i;
  int8_t j;
  uint32_t flags;
  int is_multi = (st->slab_ndim > 1);

  TypedData_Get_Struct(st->self, CArray, &carray_data_type, src);

  /* Mask transparent carry: input mask is visible to the user's
     block via slab.mask / slab.has_mask?.  For REDUCE_FIBER form
     (= per-element inject), masked cells are yielded as CA::UNDEF —
     matching CArray's standard per-cell access semantics.  For
     REDUCE_SLAB form, the user-provided block sees the masked slab
     and can call slab.sum, .mean, etc., which honor mask via the
     existing mask-aware reduction kernels.                              */

  /* Compute outer-shape output: drop dim at every slab axis.  Reducing
     all axes (= flatten reduce, K = src->ndim) collapses to 0-D; we
     represent this as ndim=1, dim=[1] (= scalar-like, accessible via
     output[0]).  CScalar is not exposed for this case.                 */
  out_ndim = src->ndim - st->slab_ndim;
  if ( out_ndim == 0 ) {
    out_ndim = 1;
    out_dim[0] = 1;
  }
  else {
    j = 0;
    for ( i = 0; i < src->ndim; i++ ) {
      int8_t k;
      int is_slab_axis = 0;
      for ( k = 0; k < st->slab_ndim; k++ ) {
        if ( st->slab_axes[k] == i ) { is_slab_axis = 1; break; }
      }
      if ( ! is_slab_axis ) out_dim[j++] = src->dim[i];
    }
  }

  st->output = rb_carray_new(st->out_data_type, out_ndim, out_dim,
                             st->out_bytes, NULL);
  TypedData_Get_Struct(st->output, CArray, &carray_data_type, out);
  ca_allocate(out);

  /* FIBER_CONTIG is naxes==1 only (T1 substrate contract).  Multi-axis
     omits the flag and uses bare CA_SLAB_AXES; T1 picks an in-src
     alias_mode for entity / CAStride sources (= the only supported case;
     non-ALIAS modes raise NotImpError in setup_input_slab_view). */
  flags = is_multi ? 0 : CA_KERNEL_FIBER_CONTIG;
  st->t1 = (ca_iter_state *) xmalloc(sizeof(ca_iter_state));
  rc = ca_iter_state_init_l2(st->t1, src, CA_SLAB_AXES,
                             st->slab_axes, st->slab_ndim, flags);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError,
             "CArray#reduce_slab: T1 init failed rc=%d", rc);
  }
  st->t1_started = 1;

  fiber_len = st->t1->slab_elements;

  /* Centralised ALIAS / SCRATCH + multi-axis + mask carry dispatch. */
  ca_slab_setup_input_slab_view(st, src, st->t1->slab_dims[0]);

  *out_src = src;
  *out_n   = fiber_len;
}

/* Per-slab block form: block receives the slab CArray, returns a
   scalar; each scalar is cast into the corresponding output cell.
   (`init:` absent ⇒ this path) */
static VALUE
ca_slab_run_reduce_slab (ca_slab_iter_state_t *st)
{
  CArray *src;
  CArray *out;
  ca_size_t fiber_len;
  char *p_in;
  boolean8_t *m_in;
  CAStride *slab_cs;
  CAWrap   *carrier_cw = NULL;
  int in_alias;
  ca_size_t out_idx = 0;
  char buf[64];
  char *scratch;

  ca_slab_reduce_setup(st, &src, &fiber_len);
  TypedData_Get_Struct(st->output, CArray, &carray_data_type, out);
  TypedData_Get_Struct(st->slab_view, CAStride, &castride_data_type, slab_cs);
  in_alias = (st->carrier == Qnil);
  if ( ! in_alias ) {
    TypedData_Get_Struct(st->carrier, CAWrap, &cawrap_data_type, carrier_cw);
  }

  scratch = (st->out_bytes <= (ca_size_t) sizeof(buf)) ? buf
                                                      : xmalloc(st->out_bytes);

  while ( ca_iter_state_next_slab_axes(st->t1, &p_in, &m_in) ) {
    VALUE result;

    ca_slab_advance_slab_view(st, slab_cs, carrier_cw,
                              src, p_in, m_in, in_alias);

    result = rb_yield(st->slab_view);

    /* Strict scalar contract: block must return a scalar Ruby value
       (Numeric / Object / etc.).  A CArray is a
       contract violation; even a 1-element CArray is rejected, since
       the user almost always means to return the underlying scalar
       value via `slab[0]`.  Better surfaced as an error than silently
       coerced through obj2ptr.                                       */
    if ( rb_obj_is_kind_of(result, rb_cCArray) ) {
      CArray *res;
      TypedData_Get_Struct(result, CArray, &carray_data_type, res);
      if ( scratch != buf ) xfree(scratch);
      rb_raise(rb_eArgError,
               "CArray#reduce_slab: per-slab block must return a scalar "
               "(got CArray with %lld element%s; use `slab[0]` or "
               "`slab.sum` etc. to extract the scalar)",
               (long long) res->elements,
               res->elements == 1 ? "" : "s");
    }

    rb_ca_obj2ptr(st->output, result, scratch);
    memcpy(out->ptr + out_idx * st->out_bytes, scratch, st->out_bytes);
    out_idx++;
  }

  if ( scratch != buf ) xfree(scratch);
  return st->output;
}

/* Per-element fiber form: block receives (acc, x) for each element in
   the slab, returns the new accumulator.  The final accumulator is
   cast into the output cell.  (`init:` given ⇒ this path)             */
static VALUE
ca_slab_run_reduce_fiber (ca_slab_iter_state_t *st)
{
  CArray *src;
  CArray *out;
  ca_size_t fiber_len;
  char *p_in;
  boolean8_t *m_in;
  CAStride *slab_cs;
  CAWrap   *carrier_cw = NULL;
  int in_alias;
  ca_size_t out_idx = 0;
  char buf[64];
  char *scratch;

  ca_slab_reduce_setup(st, &src, &fiber_len);
  TypedData_Get_Struct(st->output, CArray, &carray_data_type, out);
  TypedData_Get_Struct(st->slab_view, CAStride, &castride_data_type, slab_cs);
  in_alias = (st->carrier == Qnil);
  if ( ! in_alias ) {
    TypedData_Get_Struct(st->carrier, CAWrap, &cawrap_data_type, carrier_cw);
  }

  scratch = (st->out_bytes <= (ca_size_t) sizeof(buf)) ? buf
                                                      : xmalloc(st->out_bytes);

  while ( ca_iter_state_next_slab_axes(st->t1, &p_in, &m_in) ) {
    VALUE acc;
    ca_size_t i;

    ca_slab_advance_slab_view(st, slab_cs, carrier_cw,
                              src, p_in, m_in, in_alias);

    acc = st->init_val;
    {
      /* K-D row-major walk over the slab.  For single-axis (slab_ndim=1)
         this collapses to a 1-D fiber loop; for multi-axis it visits
         cells in row-major order over slab_dims.                        */
      int8_t k;
      ca_size_t kidx[CA_RANK_MAX] = { 0 };
      ca_size_t total = st->t1->slab_elements;
      for ( i = 0; i < total; i++ ) {
        VALUE x;
        x = rb_ca_fetch_index(st->slab_view, kidx);
        acc = rb_yield_values(2, acc, x);
        /* Increment kidx[] row-major. */
        for ( k = slab_cs->ndim - 1; k >= 0; k-- ) {
          if ( ++kidx[k] < slab_cs->dim[k] ) break;
          kidx[k] = 0;
        }
      }
      (void) fiber_len;
    }

    rb_ca_obj2ptr(st->output, acc, scratch);
    memcpy(out->ptr + out_idx * st->out_bytes, scratch, st->out_bytes);
    out_idx++;
  }

  if ( scratch != buf ) xfree(scratch);
  return st->output;
}

/* ------------------------------------------------------------------- */
/* EACH form                                                           */
/* ------------------------------------------------------------------- */

/* Side-effect only iteration: yield each slab to the block, discard
   the return value, return self when done.  No output entity, no
   scatter — the simplest of the four forms.

   Slab lifetime: block-only.  If the user captures the slab object
   across iterations (= `vals = []; ca.each_slab(...) { |s| vals << s }`),
   every entry will reflect the LAST iter's data (capture-out is a
   documented contract, no runtime check).

   `break` / `next` / `return` interact with rb_ensure correctly: the
   ensure_fn runs cleanup before the non-local exit propagates.        */
static VALUE
ca_slab_run_each (ca_slab_iter_state_t *st)
{
  CArray *src;
  char *p_in;
  boolean8_t *m_in;
  CAStride *slab_cs;
  CAWrap   *carrier_cw = NULL;
  int in_alias;
  int rc;

  TypedData_Get_Struct(st->self, CArray, &carray_data_type, src);

  /* Mask transparent carry: user's block sees slab.mask /
     slab.has_mask?; the block's return value is discarded by each_slab
     so output mask is irrelevant.                                       */

  /* FIBER_CONTIG is naxes==1 only; multi-axis omits the flag. */
  {
    uint32_t flags = (st->slab_ndim == 1) ? CA_KERNEL_FIBER_CONTIG : 0;
    st->t1 = (ca_iter_state *) xmalloc(sizeof(ca_iter_state));
    rc = ca_iter_state_init_l2(st->t1, src, CA_SLAB_AXES,
                               st->slab_axes, st->slab_ndim, flags);
    if ( rc != CA_ITER_OK ) {
      rb_raise(rb_eRuntimeError,
               "CArray#each_slab: T1 init failed rc=%d", rc);
    }
    st->t1_started = 1;
  }

  in_alias = ca_slab_setup_input_slab_view(st, src, st->t1->slab_dims[0]);

  TypedData_Get_Struct(st->slab_view, CAStride, &castride_data_type, slab_cs);
  if ( ! in_alias ) {
    TypedData_Get_Struct(st->carrier, CAWrap, &cawrap_data_type, carrier_cw);
  }

  while ( ca_iter_state_next_slab_axes(st->t1, &p_in, &m_in) ) {
    ca_slab_advance_slab_view(st, slab_cs, carrier_cw,
                              src, p_in, m_in, in_alias);
    rb_yield(st->slab_view);    /* return value discarded */
  }

  return st->self;
}

/* ------------------------------------------------------------------- */
/* rb_ensure callbacks (= run_body / finish), state-pointer based.      */
/* ------------------------------------------------------------------- */

static VALUE
slab_state_run_body (VALUE arg)
{
  ca_slab_iter_state_t *st = (ca_slab_iter_state_t *)(uintptr_t) arg;
  switch ( st->form ) {
  case CA_SLAB_FORM_MAP:          return ca_slab_run_map(st);
  case CA_SLAB_FORM_REDUCE_SLAB:  return ca_slab_run_reduce_slab(st);
  case CA_SLAB_FORM_REDUCE_FIBER: return ca_slab_run_reduce_fiber(st);
  case CA_SLAB_FORM_EACH:         return ca_slab_run_each(st);
  default:
    rb_raise(rb_eNotImpError, "CArray slab: unknown form %d", (int) st->form);
  }
  return Qnil;
}

static VALUE
slab_state_finish (VALUE arg)
{
  ca_slab_iter_state_t *st = (ca_slab_iter_state_t *)(uintptr_t) arg;

  /* T1 substrate teardown.
     CAREFUL: ca_detach(slab_view) is NEVER called — T1 owns the buffer;
     dropping the VALUE handles lets GC reclaim the CAStride wrappers
     without xfreeing the borrowed ptr. */
  if ( st->t1_started     ) ca_iter_state_finish(st->t1);
  if ( st->t1_out_started ) ca_iter_state_finish(st->t1_out);

  /* Free heap-owned state (each guarded; partial-acquire paths land here
     too, so NULL checks matter). */
  if ( st->t1               ) { xfree(st->t1);               st->t1               = NULL; }
  if ( st->t1_out           ) { xfree(st->t1_out);           st->t1_out           = NULL; }
  if ( st->own_data_scratch ) { xfree(st->own_data_scratch); st->own_data_scratch = NULL; }
  if ( st->own_mask_scratch ) { xfree(st->own_mask_scratch); st->own_mask_scratch = NULL; }
  if ( st->own_out_scratch  ) { xfree(st->own_out_scratch);  st->own_out_scratch  = NULL; }

  /* Drop VALUE handles so the rest of the entry function does not hold
     references to scratch / slab views that GC may now collect. */
  st->slab_view        = Qnil;
  st->carrier          = Qnil;
  st->mask_carrier     = Qnil;
  st->output_slab_view = Qnil;

  return Qnil;
}

/* ------------------------------------------------------------------- */
/* Entry points: CArray#map_slab / #reduce_slab / #each_slab           */
/* ------------------------------------------------------------------- */

/* Shared kwarg parse: returns axis (required) + data_type / init via
   out-params.  init_out is set to Qundef if the `:init` key was absent
   (= caller distinguishes per-slab vs per-element reduce forms).      */
static void
slab_parse_kwargs (VALUE kw, int allow_init, int allow_data_type,
                   const char *method_name,
                   VALUE *axis_out, VALUE *data_type_out, VALUE *init_out)
{
  ID keys[3];
  VALUE vals[3];
  int n_optional = 0;

  keys[0] = rb_intern("axis");
  if ( allow_data_type ) { keys[1 + n_optional] = rb_intern("data_type"); n_optional++; }
  if ( allow_init      ) { keys[1 + n_optional] = rb_intern("init");      n_optional++; }

  if ( NIL_P(kw) ) {
    rb_raise(rb_eArgError, "%s: axis: keyword required", method_name);
  }
  rb_get_kwargs(kw, keys, 1, n_optional, vals);

  *axis_out      = vals[0];
  *data_type_out = (allow_data_type && vals[1] != Qundef) ? vals[1] : Qnil;
  *init_out      = Qundef;
  if ( allow_init ) {
    int init_idx = allow_data_type ? 2 : 1;
    *init_out = vals[init_idx];   /* Qundef if `:init` not given */
  }
}

/* Helper: split argv into kwarg hash (or Qnil).  Entries take only kwargs. */
static VALUE
slab_extract_kwargs (int argc, VALUE *argv, const char *method_name)
{
  VALUE kw = Qnil;
  if ( argc == 1 && RB_TYPE_P(argv[0], T_HASH) ) {
    kw = argv[0];
  }
  else if ( argc != 0 ) {
    rb_raise(rb_eArgError, "%s: expected only keyword arguments", method_name);
  }
  return kw;
}

static VALUE
rb_ca_map_slab (int argc, VALUE *argv, VALUE self)
{
  ca_slab_iter_state_t st = {0};
  VALUE kw, axis, data_type, init_unused;
  VALUE result;

  kw = slab_extract_kwargs(argc, argv, "CArray#map_slab");
  slab_parse_kwargs(kw, /*allow_init=*/0, /*allow_data_type=*/1,
                    "CArray#map_slab",
                    &axis, &data_type, &init_unused);

  if ( ! rb_block_given_p() ) {
    rb_raise(rb_eLocalJumpError, "CArray#map_slab: block required");
  }

  slab_state_init(&st, self, CA_SLAB_FORM_MAP, axis, data_type, Qundef);

  result = rb_ensure(slab_state_run_body, (VALUE)(uintptr_t)&st,
                     slab_state_finish,   (VALUE)(uintptr_t)&st);
  RB_GC_GUARD(self);
  return result;
}

static VALUE
rb_ca_reduce_slab (int argc, VALUE *argv, VALUE self)
{
  ca_slab_iter_state_t st = {0};
  VALUE kw, axis, data_type, init_val;
  VALUE result;
  int8_t form;

  kw = slab_extract_kwargs(argc, argv, "CArray#reduce_slab");
  slab_parse_kwargs(kw, /*allow_init=*/1, /*allow_data_type=*/1,
                    "CArray#reduce_slab",
                    &axis, &data_type, &init_val);

  if ( ! rb_block_given_p() ) {
    rb_raise(rb_eLocalJumpError, "CArray#reduce_slab: block required");
  }

  /* `init:` absent => per-slab block form; present => per-element fiber form. */
  form = (init_val == Qundef) ? CA_SLAB_FORM_REDUCE_SLAB
                              : CA_SLAB_FORM_REDUCE_FIBER;

  slab_state_init(&st, self, form, axis, data_type, init_val);

  result = rb_ensure(slab_state_run_body, (VALUE)(uintptr_t)&st,
                     slab_state_finish,   (VALUE)(uintptr_t)&st);
  RB_GC_GUARD(self);
  return result;
}

static VALUE
rb_ca_each_slab (int argc, VALUE *argv, VALUE self)
{
  ca_slab_iter_state_t st = {0};
  VALUE kw, axis, data_type_unused, init_unused;
  VALUE result;

  kw = slab_extract_kwargs(argc, argv, "CArray#each_slab");
  slab_parse_kwargs(kw, /*allow_init=*/0, /*allow_data_type=*/0,
                    "CArray#each_slab",
                    &axis, &data_type_unused, &init_unused);

  if ( ! rb_block_given_p() ) {
    /* to_enum hop must mark kw as kwargs (Ruby 3 strict separation),
       otherwise the resumed enumerator dispatches each_slab(positional_hash)
       and raises ArgumentError, silently losing `axis:`.               */
    VALUE enum_kw = rb_hash_new();
    VALUE args[2];
    rb_hash_aset(enum_kw, ID2SYM(rb_intern("axis")), axis);
    args[0] = ID2SYM(rb_intern("each_slab"));
    args[1] = enum_kw;
    return rb_funcallv_kw(self, rb_intern("to_enum"),
                          2, args, RB_PASS_KEYWORDS);
  }

  slab_state_init(&st, self, CA_SLAB_FORM_EACH, axis, Qnil, Qundef);

  result = rb_ensure(slab_state_run_body, (VALUE)(uintptr_t)&st,
                     slab_state_finish,   (VALUE)(uintptr_t)&st);
  RB_GC_GUARD(self);
  return result;
}

/* ------------------------------------------------------------------- */
/* Init_carray_slab                                                     */
/* ------------------------------------------------------------------- */

void
Init_carray_slab (void)
{
  rb_define_method(rb_cCArray, "map_slab",    rb_ca_map_slab,    -1);
  rb_define_method(rb_cCArray, "reduce_slab", rb_ca_reduce_slab, -1);
  rb_define_method(rb_cCArray, "each_slab",   rb_ca_each_slab,   -1);
}
