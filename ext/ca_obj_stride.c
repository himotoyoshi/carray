/* ---------------------------------------------------------------------------

  CAStride: generic strided view array.  Holds byte-unit strides
  (negative allowed) and a byte-unit base_offset relative to parent->ptr.
  Two-mode operation:

    detached (ptr == NULL): each element access computes
        parent->ptr + base_offset + sum_k(idx[k] * strides[k])

    attached (ptr != NULL): own contiguous row-major buffer, populated
        by gather copy on attach, scattered back on sync, freed on
        final detach.

  This is the whole strided-view family: CARefer and CABlock carry a tail
  of their own on top of this prefix, CATranspose / CAFarray / CARepeat /
  CAField are plain typedefs of it.  All of them inherit the operation
  table below unchanged, so a fast path added here reaches every one.
  devel/CAStride.md is the reference for writing a subclass.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_iter_substrate.h"
#include "ca_obj_face.h"  /* ca_is_face, used by the compose-fold walk */

static size_t
ca_stride_dsize (const void *ap)
{
  const CAStride *ca = (const CAStride *) ap;
  /* dim and strides are each ALLOC_N(ndim) (legacy) or wired into the
     framework-managed _pool buffer (pool path).  Either way the live byte
     accounting is the struct plus 2*ndim ca_size_t cells. */
  return sizeof(CAStride) + 2 * ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks.
   When ca_func[obj_type].pool_init runs against the buffer allocated by
   ca_array_pool_alloc, dim and strides are wired into a single contiguous
   region instead of taking two separate ALLOC_N calls.  The legacy
   ALLOC_N path stays available for any obj_type that has not registered
   these hooks yet (= ca->_pool stays NULL through setup). */
static size_t
ca_stride_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return 2 * (size_t) n * sizeof(ca_size_t);
}

static void
ca_stride_pool_init (void *ap, int8_t ndim)
{
  CAStride *ca   = (CAStride *) ap;
  ca_size_t  n   = (ndim > 0) ? ndim : 1;
  ca_size_t *base = (ca_size_t *) ca->_pool;
  ca->dim     = base + 0 * n;
  ca->strides = base + 1 * n;
}

const rb_data_type_t castride_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAStride",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_stride_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t castride_mask_data_type = {
    .parent = &castride_data_type,
    .wrap_struct_name = "CAStrideMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_stride_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

VALUE rb_cCAStride;
VALUE rb_cCAStrideMask;
int8_t CA_OBJ_STRIDE;       /* assigned at Init time via ca_install_obj_type */

/* ------------------------------------------------------------------- */

/* `obj_type` is the dispatch tag stored in ca->obj_type.  Pass
   CA_OBJ_STRIDE when constructing a plain CAStride; pass the
   subclass's own obj_type (e.g. CA_OBJ_TRANSPOSE) when used from a
   subclass setup -- this avoids the "stamp it again after setup"
   override pattern and makes the C-level dispatch wire up correctly
   on the first try. */
int
ca_stride_setup (CAStride *ca, int8_t obj_type, CArray *parent,
                 int8_t data_type, ca_size_t bytes,
                 int8_t ndim, ca_size_t *dim,
                 ca_size_t *strides, ca_size_t base_offset)
{
  ca_size_t elements;
  int  i;

  if (ndim < 0 || ndim > CA_RANK_MAX) {
    rb_raise(rb_eArgError, "invalid ndim %d", (int) ndim);
  }
  elements = 1;
  for (i = 0; i < ndim; i++) {
    if (dim[i] < 0) {
      rb_raise(rb_eIndexError,
               "invalid size for %i-th dimension (negative)", i);
    }
    elements *= dim[i];
  }

  ca->obj_type     = obj_type;
  ca->data_type    = data_type;
  ca->flags        = 0;
  ca->ndim         = ndim;
  ca->bytes        = bytes;
  ca->elements     = elements;
  ca->ptr          = NULL;
  ca->mask         = NULL;
  ca->parent       = parent;
  ca->attach       = 0;
  ca->nosync       = 0;
  if ( ! ca->_pool ) {
    /* Legacy path: caller used ALLOC(CAStride) without ca_array_alloc,
       so dim/strides need their own backing.  Pool path callers have
       these already wired by ca_stride_pool_init. */
    ca->dim     = ALLOC_N(ca_size_t, ndim > 0 ? ndim : 1);
    ca->strides = ALLOC_N(ca_size_t, ndim > 0 ? ndim : 1);
  }
  ca->base_offset  = base_offset;

  for (i = 0; i < ndim; i++) {
    ca->dim[i]     = dim[i];
    ca->strides[i] = strides[i];
  }

  if (parent && ca_has_mask(parent)) {
    ca_create_mask(ca);
  }

  return 0;
}

CAStride *
ca_stride_new (int8_t obj_type, CArray *parent,
               int8_t data_type, ca_size_t bytes,
               int8_t ndim, ca_size_t *dim,
               ca_size_t *strides, ca_size_t base_offset)
{
  CAStride *ca = (CAStride *) ca_array_alloc(obj_type, ndim);
  ca_stride_setup(ca, obj_type, parent,
                  data_type, bytes, ndim, dim, strides, base_offset);
  return ca;
}

static void
free_ca_stride (void *ap)
{
  CAStride *ca = (CAStride *) ap;
  if (ca == NULL) return;
  ca_free(ca->mask);
  if (ca->_pool) {
    /* Pool path: one xfree covers dim/strides via the pool buffer,
       another covers the struct. */
    ca_array_free(ca);
  } else {
    /* Legacy path: free dim/strides individually. */
    xfree(ca->dim);
    xfree(ca->strides);
    xfree(ca);
  }
}

static int  ca_layout_is_contiguous (int8_t ndim, const ca_size_t *dim,
                                     const ca_size_t *strides, ca_size_t bytes);
/* ca_stride_xfer_with_layout / ca_stride_merge_axes are declared in
   ca_iter_substrate.h — the kernel iterator drives them too. */

/* Forward decl: ca_stride_func defined later in the file. */
extern ca_operation_function_t ca_stride_func;

/* Shared cache-tiled transpose helper, defined in carray_core.c.  Called by
   three paths: the central dispatcher's ptr path, our root-direct memcpy
   path, and ca_stride_xfer_with_layout's tile branch.  Takes a raw src base
   ptr and bytes so all three callers can pass whatever ptr + bytes pair they
   already hold. */
void ca_xfer_stride_tiled_transpose_2d (char *src_base, ca_size_t bytes,
                                         ca_size_t *counts, ca_size_t *strides,
                                         char *data, int dir);

/* Compose `leaf->strides` and `leaf->base_offset` (which live in `parent`'s
   own logical row-major contig byte space) into `out_strides` and
   `out_base` expressed in `parent->parent`'s byte space.
   Both `leaf` and `parent` are CAStride views; `leaf->parent == parent`.
   Returns 1 on clean decomposition, 0 on failure (a stride that does not
   align with parent's logical layout -- e.g. a synthetic stride that
   crosses parent dim boundaries non-aligned).  On 0, caller falls back to
   materialise-parent path. */
int
ca_stride_compose_through (CAStride *leaf, CAStride *parent,
                           ca_size_t *out_strides, ca_size_t *out_base)
{
  ca_size_t prod[CA_RANK_MAX + 1];
  ca_size_t base_idx[CA_RANK_MAX];  /* base position in each parent dim */
  int8_t k, m;

  /* prod[k] = product of parent->dim[k..ndim-1] (in elements) */
  prod[parent->ndim] = 1;
  for (k = parent->ndim - 1; k >= 0; k--)
    prod[k] = prod[k + 1] * parent->dim[k];

  /* Compose base offset first.  We need the per-dim base position
     to validate stride composition against parent dim bounds (a small
     forward stride starting near the end of a parent dim wraps into
     the next dim with the wrong stride; the bounds check below needs
     to know where in the dim we start).

     Sub-element offset (= leaf->base_offset % parent->bytes != 0) is
     captured into `sub_byte` and folded into out_base at the end,
     rather than rejected.  This handles CAField over CAStride family
     (= second-or-later field of a multi-field record) and CARefer
     byte-reinterpret + offset patterns.  Per-cell memcpy in the hot
     path uses LEAF's bytes (= field width), so a non-parent-aligned
     base is correct. */
  ca_size_t flat     = leaf->base_offset / parent->bytes;
  ca_size_t sub_byte = leaf->base_offset % parent->bytes;
  ca_size_t base     = parent->base_offset;
  for (m = 0; m < parent->ndim; m++) {
    base_idx[m] = flat / prod[m + 1];
    flat -= base_idx[m] * prod[m + 1];
    if (base_idx[m] >= parent->dim[m]) return 0;
    base += base_idx[m] * parent->strides[m];
  }
  if (flat != 0) return 0;
  *out_base = base + sub_byte;

  /* Compose each leaf dim's stride.
     Validity rule: leaf dim k must advance exactly one parent dim
     (not cross multiple parent dims) AND stay within that parent
     dim's bounds across leaf's full extent *given the base position*.
     Otherwise the leaf's traversal would wrap across parent dim
     boundaries, which is a non-strided access pattern that cannot
     be folded. */
  for (k = 0; k < leaf->ndim; k++) {
    if (leaf->strides[k] % parent->bytes != 0) return 0;
    ca_size_t advance = leaf->strides[k] / parent->bytes;
    ca_size_t composed = 0;
    int nonzero_count = 0;
    int nonzero_dim = -1;
    ca_size_t nonzero_step = 0;
    for (m = 0; m < parent->ndim; m++) {
      ca_size_t step = advance / prod[m + 1];
      advance -= step * prod[m + 1];
      composed += step * parent->strides[m];
      if (step != 0) {
        nonzero_count++;
        nonzero_dim = m;
        nonzero_step = step;
      }
    }
    if (advance != 0) return 0;
    if (nonzero_count > 1) return 0;   /* crosses parent dims */
    if (nonzero_count == 1) {
      /* Final position in parent dim after the full leaf extent.
         For a forward step it must stay strictly below dim; for a
         backward step it must stay at or above 0. */
      ca_size_t final_pos =
        base_idx[nonzero_dim] + (leaf->dim[k] - 1) * nonzero_step;
      if (nonzero_step > 0) {
        if (final_pos >= parent->dim[nonzero_dim]) return 0;
      } else {
        if (final_pos < 0) return 0;
      }
    }
    out_strides[k] = composed;
  }

  return 1;
}

/* Walk up the CAStride chain composing strides and base_offset until we
   reach a non-CAStride parent (entity or non-stride view like CAReduce).
   `out_strides` and `out_base` describe the leaf's element layout in
   *out_root's ptr-byte space.
   On any composition failure (non-aligned stride), returns the deepest
   successfully-composed root (which may be the immediate parent or an
   intermediate).  The chain is always foldable for at least one step in
   theory; the conservative return is the parent itself.
   Caller must ca_attach(*out_root) if !ca_is_attached(*out_root) before
   reading from (*out_root)->ptr + *out_base.  Composition writes into
   the provided ndim-sized out_strides buffer. */
/* CAWindow operation table, read by the fill_data wasted-gather gate below
   to recognise a CAWindow root.  Compose-fold itself does not special-case
   CAWindow: that lives in CAWindow's own fold_stride slot. */
extern ca_operation_function_t ca_window_func;

/* Hybrid compose-fold walk.  Two kinds of participant fold a leaf's stride coordinates one hop closer to the root:

     - CAStride family: recognised open-inline by func-pointer comparison
       (ca_func[obj_type].attach == ca_stride_func.attach), composed via
       ca_stride_compose_through (stride machinery's own self-knowledge).
     - sometimes-fold participants (CAWindow now; CAGrid/CSA/CATile later):
       dispatched through the fold_stride operation slot, which composes the
       fold state into the next parent's space or declines (-> boundary).

   No view names beyond the CAStride family appear here; new participants
   join by implementing fold_stride (open/closed principle on the foreign
   axis).  No new flags: the CAStride family is detected by attach-pointer
   identity, fold participation by fold_stride != NULL. */
void
ca_stride_compose_to_root (CAStride *leaf,
                           CArray **out_root,
                           ca_size_t *out_strides,
                           ca_size_t *out_base)
{
  ca_fold_t f;
  CArray   *cur = leaf->parent;
  int8_t    k;

  f.ndim = leaf->ndim;
  f.base = leaf->base_offset;
  for (k = 0; k < leaf->ndim; k++) {
    f.strides[k] = leaf->strides[k];
    f.counts[k]  = leaf->dim[k];   /* extent, used by compose-through bounds */
  }

  while (1) {
    if (ca_func[cur->obj_type].attach == ca_stride_func.attach) {
      /* OPEN: CAStride family.  Compose f (leaf-in-cur-space) through the
         CAStride parent into cur->parent's space. */
      CAStride *p = (CAStride *) cur;
      CAStride  tmp;
      ca_size_t next_strides[CA_RANK_MAX];
      ca_size_t next_base;
      tmp.ndim = f.ndim;
      tmp.bytes = leaf->bytes;
      tmp.dim = f.counts;          /* extent in cur space */
      tmp.strides = f.strides;
      tmp.base_offset = f.base;
      if (!ca_stride_compose_through(&tmp, p, next_strides, &next_base)) {
        break;
      }
      for (k = 0; k < f.ndim; k++) f.strides[k] = next_strides[k];
      f.base = next_base;
      cur = p->parent;
    }
    else if (ca_func[cur->obj_type].fold_stride) {
      /* DUCK: sometimes-fold participant.  It composes f and advances, or
         declines (-> cur is the fold boundary). */
      void *next;
      if (!ca_func[cur->obj_type].fold_stride(cur, &f, &next)) {
        break;
      }
      cur = (CArray *) next;
    }
    else if (ca_is_face(cur)) {
      /* Face is layout-identity over its parent (= byte-for-byte alias via
         ca_face_attach, same data_type / bytes / strides).  Walk through
         as an identity step so the composed (strides, base) carry into
         parent's space unchanged.  Without this, compose stops at Face
         and partial materialise / Face xfer_stride delegate paths re-
         enter the dispatcher with the ROOT's bytes interpretation
         (= entity FIXLEN bytes) instead of the LEAF's bytes (= e.g. f64
         field width), causing a heap buffer overflow + wrong-value bulk
         gather (= reporter's bug: CARecord chain + CAField bulk path). */
      cur = ((CAView *) cur)->parent;
    }
    else {
      break;   /* boundary: cur is the root we expose */
    }
  }

  *out_root = cur;
  *out_base = f.base;
  for (k = 0; k < leaf->ndim; k++) out_strides[k] = f.strides[k];
}

/* Resolves a candidate parent through identity CAStride compose-fold to find
   an attached root.
   Returns the resolved CArray (or the original `cand` if cand already has
   ptr, isn't CAStride family, or doesn't identity-compose to a ptr-bearing
   root).  Used by view xfer_addrs slots (CSA / CAGrid / CASelect) to lift
   the parent->ptr gate through view CAStride layers when the compose
   is element-mapping identity (= simple reshape / alias).

   "Identity compose-fold" semantics:
     - cand->bytes == root->bytes      (no byte reinterpret)
     - composed_base == 0
     - composed_strides[k] match row-major over cand->dim with cand->bytes

   When true, the cand's flat byte addressing equals root->ptr's flat byte
   addressing for the first `cand->elements * cand->bytes` bytes.  The
   axis_dispatch engine can then use root->ptr as parent->ptr directly
   (with cand's logical shape passed via parent_axis_dims unchanged).

   This unblocks the chain pattern a.flatten[idx].reshape(*idx.shape) where
   intermediate CARefer layers are view (no explicit attach) but
   element-identity-aliased to the leaf entity.  */
CArray *
ca_resolve_attached_root_via_identity (CArray *cand)
{
  CAStride *cs;
  CArray   *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;
  ca_size_t s;
  int8_t    k;

  if ( cand->ptr ) return cand;
  if ( ca_func[cand->obj_type].attach != ca_stride_func.attach ) return cand;

  cs = (CAStride *) cand;
  ca_stride_compose_to_root(cs, &root, composed_strides, &composed_base);
  if ( !root->ptr ) return cand;
  if ( cs->bytes != root->bytes ) return cand;
  if ( composed_base != 0 ) return cand;

  s = root->bytes;
  for ( k = cs->ndim - 1; k >= 0; k-- ) {
    if ( composed_strides[k] != s ) return cand;
    s *= cs->dim[k];
  }
  return root;
}

/* ------------------------------------------------------------------- */

static void *
ca_stride_func_clone (void *ap)
{
  CAStride *ca = (CAStride *) ap;
  /* Preserve the subclass identity (CATranspose, etc.) by reusing
     the source's obj_type rather than hardcoding CA_OBJ_STRIDE. */
  return ca_stride_new(ca->obj_type, ca->parent, ca->data_type, ca->bytes,
                       ca->ndim, ca->dim, ca->strides, ca->base_offset);
}

/* CAREFUL: per-cell access paths must not call ca_attach on any ancestor.
   When ca->ptr is NULL the cell is delegated one hop to the parent instead;
   attaching would materialise the whole parent to read one cell (ruinous for
   a non-trivial chain) and would hand back a dangling pointer after the
   matching ca_detach.  The delegation recurses and bottoms out at an entity,
   whose ptr is always live.

   Byte-offset arithmetic: leaf's strides are in bytes relative to
   parent's ptr space.  off = base_offset + Σ idx[k]*strides[k] is the
   byte offset into parent.  Split into (addr, sub) = (off / parent.bytes,
   off % parent.bytes); parent.ptr_at_addr(addr) returns the pointer to
   parent's cell, and sub handles the byte-mismatched reinterpret case
   (= CAField .real / .imag over complex). */

/* Direction-unified per-cell transfer.  Shares the offset computation; the alias / attached-parent cases differ only
   by memcpy direction, the non-attached delegate path branches GET/PUT. */
static void
ca_stride_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAStride *ca = (CAStride *) ap;
  ca_size_t off;
  int8_t k;

  if (ca->ptr) {
    /* Attached: row-major direct address (ca_index2addr inlined into the
       loop below for symmetry with the un-attached branches). */
    ca_size_t addr = ca_index2addr((CArray *) ca, idx);
    char *p = ca->ptr + ca->bytes * addr;
    if (dir == CA_XFER_GET) memcpy(data, p, ca->bytes);
    else                    memcpy(p, data, ca->bytes);
    return;
  }

  off = ca->base_offset;
  for (k = 0; k < ca->ndim; k++) {
    off += idx[k] * ca->strides[k];
  }

  if (ca_is_attached(ca->parent)) {
    char *p = ca->parent->ptr + off;
    if (dir == CA_XFER_GET) memcpy(data, p, ca->bytes);
    else                    memcpy(p, data, ca->bytes);
    return;
  }

  /* Parent not attached: delegate via the public addr dispatchers (no attach).
     Handles per-view transforms and byte-mismatched reinterpret (CAField). */
  {
    ca_size_t pbytes = ca->parent->bytes;
    if (ca->bytes == pbytes && off % pbytes == 0) {
      /* Aligned single-cell delegate: use the parent's INDEX path, not the
         addr path.  ca_fetch_addr/ca_store_addr route through ca_xfer_addrs,
         which for a multi-region parent (CAStack) does an O(K) bucket scan +
         per-call ALLOCV -- an O(K)-per-cell catastrophe for per-cell access
         over CAStride-over-CAStack.  addr2index + xfer_index is O(ndim). */
      ca_size_t pidx[CA_RANK_MAX];
      ca_addr2index(ca->parent, off / pbytes, pidx);
      ca_xfer_index(ca->parent, pidx, data, dir);
    }
    else {
      char buf[64];  /* parent cell width <= 16 in practice */
      char *scratch = (pbytes <= (ca_size_t) sizeof(buf)) ? buf : xmalloc(pbytes);
      if (dir == CA_XFER_GET) {
        ca_fetch_addr(ca->parent, off / pbytes, scratch);
        memcpy(data, scratch + (off % pbytes), ca->bytes);
      }
      else {
        /* read-modify-write the parent cell for sub-byte reinterpret */
        ca_fetch_addr(ca->parent, off / pbytes, scratch);
        memcpy(scratch + (off % pbytes), data, ca->bytes);
        ca_store_addr(ca->parent, off / pbytes, scratch);
      }
      if (scratch != buf) xfree(scratch);
    }
  }
}

/* Batched address gather/scatter.

   Reached only when ca->ptr == NULL (the central dispatcher handles the
   alias / attached / entity case with a direct memcpy fast path).  Compose
   the whole CAStride chain to its root ONCE, translate every addr to the
   root's flat element address with affine arithmetic, then hand the whole
   list to the root in a SINGLE ca_xfer_addrs call -- no whole-view attach,
   no per-cell view dispatch through the intermediate views.

   The root may itself be a non-foldable view (e.g. CASelect, CAFake); the
   recursive ca_xfer_addrs call lets that view translate one more hop.  The
   recursion bottoms at an entity whose ptr is live.

   Byte-mismatched reinterpret (CAField .real/.imag over complex, where
   ca->bytes != root->bytes or the byte offset is not a multiple of the
   root cell) cannot be expressed as a flat root address, so those cells
   fall back to the per-cell xfer_index delegate (which also avoids attach). */
static void
ca_stride_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                           void *data, int dir)
{
  CAStride *ca = (CAStride *) ap;
  CArray   *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;
  ca_size_t rbytes;
  ca_size_t *paddrs;
  ca_size_t  i, base;
  int8_t     k;
  int        all_aligned = 1;
  volatile VALUE holder;
  char      *d = (char *) data;

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);
  rbytes = root->bytes;

  /* Fast path: identity transform detection -- when the addr remap composed_base +
     Σ idx[k]*composed_strides[k] reduces to an identity mapping over the
     root's flat byte space (= simple reshape, same bytes, row-major
     composed_strides), forward addrs as-is to root without the ALLOCV +
     per-cell remap loop.  Cascades through chain a[idx_2d] (= outer
     reshape -> CAGrid -> inner reshape -> entity): outer CARefer is a
     simple reshape so addrs pass through, then CAGrid Y.1.b fast path
     triggers on the recursive call, then inner CARefer simple reshape
     pass-through to entity.  Detection is O(ndim) + O(n).  */
  if ( n == ca->elements
       && ca->bytes == rbytes && composed_base == 0
       && ca_xfer_addrs_is_sequential_run(n, addrs, &base) && base == 0 ) {
    ca_size_t s = rbytes;
    int is_identity = 1;
    for ( k = ca->ndim - 1; k >= 0; k-- ) {
      if ( composed_strides[k] != s ) { is_identity = 0; break; }
      s *= ca->dim[k];
    }
    if ( is_identity ) {
      ca_xfer_addrs(root, n, addrs, data, dir);
      return;
    }
  }

  paddrs = ALLOCV_N(ca_size_t, holder, n);
  for ( i = 0; i < n; i++ ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_size_t off = composed_base;
    ca_addr2index((CArray *) ca, addrs[i], idx);
    for ( k = 0; k < ca->ndim; k++ ) {
      off += idx[k] * composed_strides[k];
    }
    if ( ca->bytes == rbytes && off % rbytes == 0 ) {
      paddrs[i] = off / rbytes;
    }
    else {
      all_aligned = 0;
      break;
    }
  }

  if ( all_aligned ) {
    ca_xfer_addrs(root, n, paddrs, data, dir);
  }
  else {
    /* byte-mismatched reinterpret: deliver cell by cell via xfer_index
       (still no whole-view attach -- delegates one cell at a time). */
    for ( i = 0; i < n; i++ ) {
      ca_size_t idx[CA_RANK_MAX];
      ca_addr2index((CArray *) ca, addrs[i], idx);
      ca_stride_func_xfer_index(ca, idx, d + i * ca->bytes, dir);
    }
  }
  ALLOCV_END(holder);
}

/* Optimised region delivery.  Reached when ca->ptr == NULL (the central dispatcher handles the alias / attached case).
   A transform parent (CAFake/CAByteSwap) recursing parent.xfer_stride lands
   here; without this the request would fall to the dispatcher's per-cell path
   (which re-composes each cell).  Instead compose the chain to its root ONCE
   and translate the request's strided access into the root's byte space, then
   hand the whole region to the root in a SINGLE ca_xfer_stride (entity -> ptr
   memcpy; boundary view -> one recursion).

   CAREFUL: the request is given over this view's linear ADDRESSES (carray.h
   xfer_stride contract), so request axis k does NOT have to be view axis k.
   A caller is free to hand over a transposed region -- counts/strides in one
   order, the packed destination in another -- which is exactly what a
   column-major backend (carray-linalg's Fortran-LAPACK gather) does.  Matching
   request axis k to view axis k by dividing strides[k] by the axis-k native
   step looks right and is wrong: an (n, 1) view has the same native step on
   both axes, so a transposed request divides cleanly and then composes the
   n-cell walk onto the length-1 axis, whose parent stride is 0 -- delivering
   the first cell n times, with no error anywhere.  Ask ca_stride_region_axes
   which view axis each request axis really moves (the same question
   fill_stride asks), and fall back to the per-cell walk when the region is
   not a box over our axes.

   Byte-matching requests only; the byte-mismatch reinterpret (CAField
   .real/.imag) and non-box access fall back to per-cell xfer_index (which
   handles the sub-byte case). */

static int ca_stride_region_axes (CAStride *ca, ca_size_t base, int8_t ndim,
                                  ca_size_t *counts, ca_size_t *steps,
                                  ca_size_t *base_idx, int8_t *axis_of,
                                  ca_size_t *mult);

static void
ca_stride_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                            ca_size_t *strides, void *data, int dir)
{
  CAStride *ca = (CAStride *) ap;
  CArray   *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;
  ca_size_t view_native[CA_RANK_MAX];
  ca_size_t root_stride[CA_RANK_MAX];
  ca_size_t steps[CA_RANK_MAX];
  ca_size_t base_idx[CA_RANK_MAX];
  ca_size_t mult[CA_RANK_MAX];
  int8_t    axis_of[CA_RANK_MAX];
  ca_size_t root_base;
  ca_size_t base_addr = 0;
  ca_size_t s;
  int8_t    ndim = ca->ndim, k;
  int       aligned = 1;
  char     *d = (char *) data;

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);

  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { view_native[k] = s; s *= ca->dim[k]; }
  for (k = 0; k < ndim; k++) base_addr += starts[k] * view_native[k];

  if (ca->bytes != root->bytes) {
    aligned = 0;
  }
  else {
    for (k = 0; k < ndim; k++) {
      if ( strides[k] % ca->bytes != 0 ) { aligned = 0; break; }
      steps[k] = strides[k] / ca->bytes;
    }
    if ( aligned ) {
      aligned = ca_stride_region_axes(ca, base_addr / ca->bytes, ndim,
                                      counts, steps, base_idx, axis_of, mult);
    }
  }

  if ( aligned ) {
    /* Each request axis now names the view axis it moves (axis_of) and by how
       many of that axis' cells (mult); a count-1 axis moves nothing and gets
       stride 0, which the walk never follows. */
    root_base = composed_base;
    for (k = 0; k < ca->ndim; k++) {
      root_base += base_idx[k] * composed_strides[k];
    }
    for (k = 0; k < ndim; k++) {
      root_stride[k] = ( axis_of[k] >= 0 )
                     ? mult[k] * composed_strides[axis_of[k]]
                     : 0;
    }
  }

  /* Cold root that answers regions: compose the request into its addresses
     and hand it over whole, exactly as xfer_all does for the whole view.  A
     root with no memory to lend (a lazy transform, a CAObject over a file)
     has no ptr to walk, but it can still produce a region on request -- and
     asking it once beats asking it once per cell, which is what the per-cell
     descent below would do.  Chunked consumers (the binop / sweep drivers'
     per-chunk gather) arrive here, so the difference is the whole cost of
     the transfer, not a constant factor.

     The gate is xfer_all's: the root must have the slot, share this view's
     cell width (else the composed offsets are not whole root elements), and
     carry the same ndim (else its index space cannot hold this request's
     axes).  Anything narrower keeps the per-cell descent, which is correct
     for all of them.  Direction is not part of the gate: a root that refuses
     writes refuses them per cell as well. */
  if (aligned && !root->ptr && ca_func[root->obj_type].xfer_stride
       && ca->bytes == root->bytes && ndim == root->ndim) {
    ca_size_t rstarts[CA_RANK_MAX];
    if ( root_base % root->bytes == 0 ) {
      ca_size_t raddr = root_base / root->bytes;
      if ( raddr >= 0 && raddr < root->elements ) {
        ca_addr2index(root, raddr, rstarts);
        ca_xfer_stride(root, rstarts, counts, root_stride, d, dir);
        return;
      }
    }
  }

  /* Per-cell fallback (correct, no whole-view attach): byte-mismatch
     reinterpret (CAField), a region that is not a box over our axes (a
     transposed request onto a degenerate axis, a flat index over several
     axes), or a cold non-entity root the branch above could not hand a
     region to (its ndim differs from the view's -- e.g. a reshape over a
     boundary -- or it has no region slot).  ca_stride_func_xfer_index
     composes one hop and delegates to the parent. */
  if (!aligned || !root->ptr) {
    ca_size_t idx[CA_RANK_MAX], doff = 0;
    for (k = 0; k < ndim; k++) idx[k] = 0;
    while (1) {
      ca_size_t off = base_addr, vmidx[CA_RANK_MAX];
      for (k = 0; k < ndim; k++) off += idx[k] * strides[k];
      ca_addr2index((CArray *) ca, off / ca->bytes, vmidx);
      ca_stride_func_xfer_index(ca, vmidx, d + doff, dir);
      doff += ca->bytes;
      k = ndim - 1;
      while (k >= 0) { if (++idx[k] < counts[k]) break; idx[k] = 0; k--; }
      if (k < 0) break;
    }
    return;
  }

  /* Structural: root has a live ptr (entity / attached).  The request is
     already in root's BYTE space (root_base / root_stride above), so the walk
     runs in the VIEW's ndim -- independent of root's own ndim, which is what
     lets a reshape view over a 1-D entity through.  compose happened once.
     Slab-merge, tile-block and the general driver all live in the shared
     walker, which the central dispatcher's structural path also uses. */
  ca_xfer_strided_walk(root->ptr + root_base, ca->bytes, ndim,
                       counts, root_stride, d, dir);
}

/* Match a region given over this view's addresses to this view's own axes.

   The region can only be handed on if it is a box here: each of its axes has
   to advance exactly one of ours and stay inside it for the whole traversal.
   That is the same rule ca_stride_compose_through applies to a leaf against
   its parent, asked here about a request instead -- and for the same reason,
   since a request that carries from the end of one axis into the start of the
   next has no per-axis step to carry down.  A flat index over a multi-axis
   view is exactly that shape and belongs on the per-cell walk.

   Fills axis_of[k] with the view axis request axis k moves, and mult[k] with
   how far.  Returns 0 if the region is not a box.  An axis of count 1 never
   moves and is left unassigned (axis_of[k] = -1). */

static int
ca_stride_region_axes (CAStride *ca, ca_size_t base, int8_t ndim,
                       ca_size_t *counts, ca_size_t *steps,
                       ca_size_t *base_idx, int8_t *axis_of, ca_size_t *mult)
{
  ca_size_t native[CA_RANK_MAX];
  int       used[CA_RANK_MAX];
  ca_size_t s = 1;
  int8_t    j, k;

  for (j = ca->ndim - 1; j >= 0; j--) { native[j] = s; s *= ca->dim[j]; }
  for (j = 0; j < ca->ndim; j++) used[j] = 0;

  if ( base < 0 || base >= ca->elements ) return 0;
  ca_addr2index((CArray *) ca, base, base_idx);

  for (k = 0; k < ndim; k++) {
    int8_t    found = -1;
    ca_size_t q = 0;

    if ( counts[k] <= 1 ) { axis_of[k] = -1; mult[k] = 0; continue; }
    if ( steps[k] <= 0 ) return 0;

    for (j = 0; j < ca->ndim; j++) {
      ca_size_t qq;
      if ( used[j] || ca->dim[j] <= 1 ) continue;
      if ( steps[k] % native[j] != 0 ) continue;
      qq = steps[k] / native[j];
      if ( qq < 1 || qq >= ca->dim[j] ) continue;
      if ( base_idx[j] + (counts[k] - 1) * qq >= ca->dim[j] ) continue;
      if ( found >= 0 ) return 0;      /* ambiguous: refuse rather than guess */
      found = j;
      q = qq;
    }
    if ( found < 0 ) return 0;
    used[found] = 1;
    axis_of[k]  = found;
    mult[k]     = q;
  }
  return 1;
}

/* Compose the region into root's addresses and hand it on -- one value, one
   hop, no attach.  compose carries this view's axes into root's byte space,
   so once each request axis is matched to one of ours the rest is a multiply.
   root's ndim never enters into it, which is what lets a view that drops or
   reorders axes hand its region down.

   The byte-per-cell check is the same one xfer_stride makes: a view that
   reinterprets width (CAField over a complex entity for .real) addresses
   root in units root does not share, so there is no address to hand over
   and the per-cell descent stands in. */

static void
ca_stride_func_fill_stride (void *ap, ca_size_t base, int8_t ndim,
                            ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CAStride *ca = (CAStride *) ap;
  CArray   *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;
  ca_size_t root_steps[CA_RANK_MAX];
  ca_size_t base_idx[CA_RANK_MAX];
  ca_size_t mult[CA_RANK_MAX];
  int8_t    axis_of[CA_RANK_MAX];
  ca_size_t root_base;
  int8_t    k;

  if ( ! ca_stride_region_axes(ca, base, ndim, counts, steps,
                               base_idx, axis_of, mult) ) {
    ca_fill_stride_default(ca, base, ndim, counts, steps, ptr);
    return;
  }

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);

  if ( ca->bytes != root->bytes ) {
    ca_fill_stride_default(ca, base, ndim, counts, steps, ptr);
    return;
  }

  root_base = composed_base;
  for (k = 0; k < ca->ndim; k++) {
    root_base += base_idx[k] * composed_strides[k];
  }
  if ( root_base % root->bytes != 0 ) {
    ca_fill_stride_default(ca, base, ndim, counts, steps, ptr);
    return;
  }

  for (k = 0; k < ndim; k++) {
    ca_size_t st = ( axis_of[k] >= 0 )
                 ? mult[k] * composed_strides[axis_of[k]]
                 : 0;
    if ( st % root->bytes != 0 ) {
      ca_fill_stride_default(ca, base, ndim, counts, steps, ptr);
      return;
    }
    root_steps[k] = st / root->bytes;
  }

  ca_fill_stride(root, root_base / root->bytes, ndim, counts,
                 root_steps, ptr);
}

extern int ca_stride_is_contiguous (CAStride *ca);   /* defined below; non-static for Tier A */

/* Alias fast path:
   When the view's strides describe a contiguous row-major run, the
   view's logical memory is identical to a slice of the parent's
   memory.  We can skip allocating an own buffer and just point
   ca->ptr into the parent.  This makes attach O(1) for the common
   "reshape / row-block / fully-covered slice" cases.

   - attach / allocate: if contig, alias; otherwise allocate + (for
     attach) gather.
   - sync: if contig, the writes already landed in parent's memory,
     so just propagate sync upward.  Otherwise scatter.
   - detach: if contig, ca->ptr was a borrow into parent and must
     not be freed.  Otherwise xfree.

   ca_stride_is_contiguous is stable across the attach/detach
   lifecycle of a view (its inputs -- strides[], dim[], bytes -- are
   immutable), so checking it again at detach/sync time is safe.

   Note: this preserves the byte semantics for byte-reinterpret views
   (different bytes/data_type from parent) too -- aliasing the parent
   pointer is exactly what byte-reinterpret needs. */

/* Fold-in-attach: instead of attaching the immediate parent and using
   ca->parent->ptr + ca->base_offset, we walk up the CAStride chain
   composing strides into the root entity's byte space, and attach
   only the root.

   Always pair ca_attach(root) with ca_detach(root) (regardless of
   root's prior attach state); this preserves attach-count symmetry
   even when root is the entity (which is "always attached" but the
   counter still tracks borrowers).  Compose is deterministic
   (strides/base_offset are immutable), so sync/detach re-run the
   walk and reach the same root and composed layout.

   ... except when the root is not an entity.  Then it has no memory of
   its own to borrow, and ca_attach(root) means "produce all of yourself
   into a buffer" -- O(root) however few cells this view covers, which for
   the lazy backings CAObject exists to serve (a file, a DB, a paged fetch)
   is not slow but fatal.  Such a root is asked for regions instead: this
   view owns a buffer, ca_copy_data / ca_sync_data fill and drain it
   through xfer_all, and the root is never attached.

   The branch must be re-derivable at sync and detach time from the same
   inputs, or detach frees a pointer it does not own.  So it asks what the
   root IS (entity? region-capable?), both immutable, and never whether the
   root happens to be attached right now, which is not. */

/* Does this composed root have no memory to lend -- so that borrowing a
   pointer from it means producing all of it first?  See the note above.
   Also consulted by the kernel iterator, which faces the same choice when it
   composes a source down to its root.

   Entities hold their own buffer.  A CAStride-family root is one the fold
   declined to walk through (a byte reinterpret, say); its own attach folds
   onward as it always has, so leave that chain alone.  What is left is the
   boundary views that compute or fetch their contents -- CAObject, the lazy
   per-element transforms, whatever a companion gem installed -- and of those,
   only the ones with an xfer_stride slot can answer a region request at all.
   The rest have nothing better than materialising, so they keep doing it once
   under attach rather than once per transfer. */
int
ca_root_lends_no_memory (void *ap)
{
  CArray *root = (CArray *) ap;

  if ( ca_is_entity(root) ) return 0;
  if ( ca_func[root->obj_type].attach == ca_stride_func.attach ) return 0;
  return ca_func[root->obj_type].xfer_stride != NULL;
}

/* ca_attach_is_alias asks the same question from carray_core.c: a view whose
   attach owns its buffer does not alias its parent, so writes through
   ca->ptr need a ca_sync and callers must not assume otherwise. */
int
ca_stride_attach_aliases_root (CAStride *ca)
{
  CArray   *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;

  /* Already holding a ptr: ca_attach only bumps the counter and hands that
     ptr back, so what the root would have done does not arise.  The slab
     iterator relies on this -- it lends its view a buffer per iteration and
     leaves base_offset meaningless, so re-deriving the data from the root
     would read the wrong cells. */
  if ( ca->ptr != NULL ) {
    return 1;
  }
  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);
  return !ca_root_lends_no_memory(root);
}

static void
ca_stride_func_allocate (void *ap)
{
  CAStride *ca = (CAStride *) ap;
  CArray *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);
  if (ca_root_lends_no_memory(root)) {
    ca->ptr = xmalloc(ca_length(ca));
    return;
  }
  ca_attach(root);
  if (ca_layout_is_contiguous(ca->ndim, ca->dim, composed_strides, ca->bytes)) {
    ca->ptr = root->ptr + composed_base;
  } else {
    ca->ptr = xmalloc(ca_length(ca));
  }
}

static void
ca_stride_func_attach (void *ap)
{
  CAStride *ca = (CAStride *) ap;
  CArray *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);
  if (ca_root_lends_no_memory(root)) {
    /* Gather into a local buffer and publish it only once it is filled, so
       ca->ptr stays NULL for the duration of the request -- a half-attached
       view with a live ptr is what makes the per-cell dispatchers bypass the
       transfer slots. */
    char *buf = xmalloc(ca_length(ca));
    ca_copy_data(ca, buf);       /* region request, root stays cold */
    ca->ptr = buf;
    return;
  }
  ca_attach(root);
  if (ca_layout_is_contiguous(ca->ndim, ca->dim, composed_strides, ca->bytes)) {
    ca->ptr = root->ptr + composed_base;
  } else {
    ca->ptr = xmalloc(ca_length(ca));
    ca_stride_xfer_with_layout(ca, 0, root->ptr + composed_base, composed_strides);
  }
}

static void
ca_stride_func_sync (void *ap)
{
  CAStride *ca = (CAStride *) ap;
  CArray *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);
  if (ca_root_lends_no_memory(root)) {
    /* xfer_all PUT writes through to the entity, recursing a hop per view,
       so there is no ca_sync(root) to follow it with. */
    ca_sync_data(ca, ca->ptr);
    return;
  }
  if (!ca_layout_is_contiguous(ca->ndim, ca->dim, composed_strides, ca->bytes)) {
    ca_stride_xfer_with_layout(ca, 1, root->ptr + composed_base, composed_strides);
  }
  ca_sync(root);
}

static void
ca_stride_func_detach (void *ap)
{
  CAStride *ca = (CAStride *) ap;
  CArray *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);
  if (ca_root_lends_no_memory(root)) {
    xfree(ca->ptr);              /* always our own; root was never attached */
    ca->ptr = NULL;
    return;
  }
  if (!ca_layout_is_contiguous(ca->ndim, ca->dim, composed_strides, ca->bytes)) {
    xfree(ca->ptr);
  }
  ca->ptr = NULL;
  ca_detach(root);
}

/* Bridges a leaf whose ndim is smaller than the resolved root's -- an axis was dropped by integer
   indexing (e.g. s[100,nil,nil] over a (K,180,360) CAStack) -- so the natural
   partial-materialise xfer_stride path can still run.  Reinsert each dropped
   root axis as a degenerate count=1 axis, producing a full root-ndim region
   request; the root's xfer_stride then delivers only the requested region
   (CAStack slices just the touched parents, etc.) instead of the consumer
   materialising the whole root.

   Succeeds only for a pure axis drop with no transpose / reshape / strided
   sub-block / byte reinterpret on the surviving axes: ca->bytes == root->bytes,
   and the leaf's composed strides form a strictly forward subsequence of the
   root's row-major native strides.  When it returns 0 (reshape / axis-merge /
   permute / step>1 slice) the caller keeps the 2-pass fallback, so correctness
   is never at risk -- only the partial-cost win is forgone.

   Note: the count=1 axes are never iterated by the root's xfer_stride, so the
   destination buffer (row-major over the leaf's surviving dims) is laid out
   identically whether the degenerate axes are present or not. */
static int
ca_stride_bridge_dropped_axes (CAStride *ca, CArray *root,
                               ca_size_t *composed_strides,
                               ca_size_t composed_base,
                               ca_size_t *r_starts, ca_size_t *r_counts,
                               ca_size_t *r_strides)
{
  ca_size_t native[CA_RANK_MAX];
  ca_size_t s;
  int8_t i, j;

  if ( ca->bytes != root->bytes ) return 0;   /* byte reinterpret */
  if ( ca->ndim >= root->ndim )   return 0;   /* not an axis drop */

  s = root->bytes;
  for ( i = root->ndim - 1; i >= 0; i-- ) { native[i] = s; s *= root->dim[i]; }

  /* per-axis root indices recovered from the composed byte base (this also
     carries the dropped axes' selected positions, e.g. lat=5). */
  ca_addr2index(root, composed_base / root->bytes, r_starts);

  j = 0;
  for ( i = 0; i < ca->ndim; i++ ) {
    while ( j < root->ndim && native[j] != composed_strides[i] ) {
      r_counts[j]  = 1;            /* dropped axis -> degenerate */
      r_strides[j] = native[j];
      j++;
    }
    if ( j >= root->ndim ) return 0;   /* stride not a forward native match */
    /* The surviving region must fit within the matched root axis.  A stride
       match alone is not enough: a flatten/axis-merge reshape (e.g. a 2x2
       CAGrid viewed as 1-D length 4) matches the innermost native stride but
       its extent overflows the axis (4 > 2), which would scatter out of
       bounds.  Reject -> 2-pass fallback keeps such reshapes correct. */
    if ( r_starts[j] + ca->dim[i] > root->dim[j] ) return 0;
    r_counts[j]  = ca->dim[i];         /* surviving axis -> leaf extent */
    r_strides[j] = composed_strides[i];
    j++;
  }
  while ( j < root->ndim ) {           /* trailing dropped axes */
    r_counts[j]  = 1;
    r_strides[j] = native[j];
    j++;
  }
  return 1;
}

static void
ca_stride_func_xfer_all (void *ap, void *data, int dir)
{
  /* Whole-view transfer (step 4): direction-unified merge of copy_data /
     sync_data.  Compose leaf strides up through the CAStride parent chain and
     gather/scatter directly from/to the resolved root (entity or first
     non-CAStride ancestor), skipping materialisation of intermediate CAStride
     views. */
  CAStride *ca = (CAStride *) ap;
  CArray *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;
  char *ptr0 = ca->ptr;
  char *ptr = (char *) data;

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);

  /* Partial materialise: when the fold stops at a cold boundary view that knows how to deliver a region (has an
     xfer_stride slot), request only this view's composed region instead of
     attaching (materialising) the whole boundary.  ca_is_attached(root) is the
     direct gate: entity / already-attached roots have a live ptr and take the
     bulk path below; only a cold boundary view reaches here.  xfer_stride PUT
     writes through to the entity (recursing each hop), so no separate
     ca_sync(root) is needed.  Un-slotted boundaries stay on the bulk path
     (no per-cell regression).

     The region is stated in the root's own address space, so it can only be
     handed over when this view addresses the root in units the root shares:
     the same cell width, and a base that lands on a root element.  A byte
     reinterpret (CARefer to a narrower data_type over a cold view) has
     neither -- the counts passed below are this view's cells, which the root
     reads as its own and answers with root->bytes apiece, overrunning the
     caller's buffer.  Those requests fall through to the whole-root
     materialise, which addresses the root in bytes and needs no such
     agreement.  Same rule xfer_stride and fill_stride already apply. */
  if ( !ca_is_attached(root) && ca_func[root->obj_type].xfer_stride
       && ca->bytes == root->bytes && composed_base % root->bytes == 0 ) {
    ca_size_t starts[CA_RANK_MAX];
    if ( ca->ndim == root->ndim ) {
      ca_addr2index(root, composed_base / root->bytes, starts);
      ca_xfer_stride(root, starts, ca->dim, composed_strides, ptr, dir);
      return;
    }
    else {
      /* Leaf dropped an axis (ndim < root->ndim).  Reinsert the dropped
         axes as degenerate count=1 axes so the region request matches the
         root's ndim, then run the same partial-materialise path.  Falls
         through to the 2-pass fallback when the chain isn't a pure drop. */
      ca_size_t r_counts[CA_RANK_MAX], r_strides[CA_RANK_MAX];
      if ( ca_stride_bridge_dropped_axes(ca, root, composed_strides,
                                         composed_base, starts,
                                         r_counts, r_strides) ) {
        ca_xfer_stride(root, starts, r_counts, r_strides, ptr, dir);
        return;
      }

      /* Reshape / transpose that ADDS axes over a 1-D cold boundary root
         (ndim > root->ndim), e.g. big.swap_bytes[[pos, n*2]].reshape(n, 2)
         whose root is a CAMonOp / CAFake / CABinOp per-element transform.
         The view's shape can't be expressed in the root's single axis, but
         the root bytes it touches form a bounded flat span.  Materialise
         ONLY that span (not the whole root) via one contiguous region
         request, then run the strided gather/scatter against it.  Without
         this the code drops to the whole-root 2-pass fallback below, making
         a small per-record view over a large lazy root cost O(root) each --
         quadratic across a per-record loop.

         Gated to root->ndim == 1 (a flat span is exactly one strided box, so
         the request is exact) and ca->bytes == root->bytes (no byte
         reinterpret, so the span endpoints are whole root elements).  A wider
         lazy root has no single strided box to ask for, so it takes the
         whole-root fallback below -- correct, just not partial. */
      if ( root->ndim == 1 && ca->bytes == root->bytes ) {
        ca_size_t span_lo = composed_base;
        ca_size_t span_hi = composed_base + ca->bytes;
        int8_t k;
        for ( k = 0; k < ca->ndim; k++ ) {
          ca_size_t ext = (ca->dim[k] - 1) * composed_strides[k];
          if ( composed_strides[k] >= 0 ) span_hi += ext;
          else                            span_lo += ext;
        }
        {
          volatile VALUE holder;
          ca_size_t rlo    = span_lo / root->bytes;
          ca_size_t rcount = (span_hi - span_lo) / root->bytes;
          ca_size_t rstep  = root->bytes;
          char     *scratch = ALLOCV_N(char, holder, rcount * root->bytes);
          ca_xfer_stride(root, &rlo, &rcount, &rstep, scratch, CA_XFER_GET);
          ca->ptr = ptr;
          ca_stride_xfer_with_layout(ca, (dir == CA_XFER_PUT) ? 1 : 0,
                                     scratch + (composed_base - span_lo),
                                     composed_strides);
          ca->ptr = ptr0;
          if ( dir == CA_XFER_PUT ) {
            ca_xfer_stride(root, &rlo, &rcount, &rstep, scratch, CA_XFER_PUT);
          }
          ALLOCV_END(holder);
        }
        return;
      }
    }
  }

  if ( ca_is_attached(root) ) {
    /* Hot path: root has live ptr (entity / pre-attached).  Direct
       strided gather/scatter through composed strides, no attach. */
    ca->ptr = ptr;
    ca_stride_xfer_with_layout(ca, (dir == CA_XFER_PUT) ? 1 : 0,
                               root->ptr + composed_base, composed_strides);
    ca->ptr = ptr0;
    if ( dir == CA_XFER_PUT ) {
      ca_sync(root); /* propagate scatter up to root's storage */
    }
    return;
  }

  /* Cold root without an xfer_stride slot, or an ndim mismatch the bridges
     above could not express: materialise the root into scratch via
     ca_xfer_all and run the direct strided gather/scatter against that.
     CAREFUL: do not "simplify" this to ca_attach(root) -- a transfer slot
     that attaches its parent materialises it behind the caller's back, and
     the per-cell xfer_addrs alternative explodes in cost once the parent is
     itself a view chain. */
  {
    volatile VALUE holder;
    ca_size_t      rlen = root->elements * root->bytes;
    char          *root_scratch = ALLOCV_N(char, holder, rlen);
    char          *root_ptr_saved = root->ptr;
    ca_xfer_all(root, root_scratch, CA_XFER_GET);
    root->ptr = root_scratch;
    ca->ptr = ptr;
    ca_stride_xfer_with_layout(ca, (dir == CA_XFER_PUT) ? 1 : 0,
                               root->ptr + composed_base, composed_strides);
    ca->ptr = ptr0;
    if ( dir == CA_XFER_PUT ) {
      /* Push back scratch (modified by scatter) to root. */
      ca_xfer_all(root, root_scratch, CA_XFER_PUT);
    }
    root->ptr = root_ptr_saved;
    ALLOCV_END(holder);
  }
}

static void
ca_stride_func_fill_data (void *ap, void *ptr)
{
  /* Write `*ptr` to every element at the strided positions covered
     by this view, composing through the CAStride chain to write
     directly into the resolved root.  Skips materialising any
     intermediate CAStride view.

     Axis-merge is applied to the composed strides before the inner write
     loop.  When merge collapses to a contig
     run on the innermost axis (mstrides[mndim-1] == bytes), fill that
     run with a tight memcpy-pattern loop instead of per-element memcpy.
     This converts e.g. mid_axis_3d's per-element 8-byte writes into
     200 iterations of "fill 80KB" each. */
  CAStride *ca = (CAStride *) ap;
  CArray *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;
  ca_size_t mdim[CA_RANK_MAX];
  ca_size_t mstrides[CA_RANK_MAX];
  int8_t mndim;
  ca_size_t idx[CA_RANK_MAX];
  int8_t k;
  ca_size_t n;
  ca_size_t bytes = ca->bytes;

  if (ca->elements == 0) return;

  ca_stride_compose_to_root(ca, &root, composed_strides, &composed_base);

  /* If compose stopped at a non-foldable parent (= neither CAStride family nor interior-only
     CAWindow), the upcoming ca_attach(root) would gather root's data
     into scratch only to overwrite every byte with *ptr -- wasted
     work.  Delegate to root.fill_data instead.
     Safety gates:
       (1) elements match -- our view covers every root cell;
       (2) bytes match -- our cell width equals root's cell width.
     Without (2), a type-reinterpreting CAStride (CAField over a
     complex entity for `.real`/`.imag`) would corrupt root: root
     would read more bytes than ptr points to, overwriting cells the
     view did not intend to touch.
     Mask is independent of broadcast scalar fill (CArray semantics:
     fill writes data only, mask state preserved), so delegate path
     and existing path are mask-equivalent. */
  if ( ca_func[root->obj_type].attach != ca_stride_func.attach &&
       ca_func[root->obj_type].attach != ca_window_func.attach &&
       ca->elements == root->elements &&
       ca->bytes    == root->bytes ) {
    ca_func[root->obj_type].fill_data(root, ptr);
    return;
  }

  /* The gate above only covers the half where the view spans all of root;
     "fill everything I cover" is a correct request to pass on only then.
     For anything short of that the old path attached root, and if that
     attach is a gather rather than an alias it pulls in the whole root and
     syncs it all back -- cells the caller never addressed make the round
     trip, and through a lossy transform layer they come back changed.  Hand
     root the region instead.

     What falls through is root already holding its data: an entity, whose
     ptr is live at rest, or a view someone outside is holding attached.
     Either way the strided write below lands in memory that is already
     there, so composing into it directly is both cheaper than a region
     hand-off and the reason the loop is written this way. */
  if ( !ca_is_attached(root) ) {
    ca_fill_stride_whole(ca, ptr);
    return;
  }

  /* Local copies + merge */
  mndim = ca->ndim;
  for (k = 0; k < mndim; k++) {
    mdim[k]     = ca->dim[k];
    mstrides[k] = composed_strides[k];
  }
  ca_stride_merge_axes(mstrides, mdim, &mndim);

  /* Iterate prefix axes; fill inner run per iteration. */
  ca_size_t inner_count  = mdim[mndim - 1];
  ca_size_t inner_stride = mstrides[mndim - 1];
  ca_size_t outer_total  = ca->elements / inner_count;

  for (k = 0; k < mndim; k++) idx[k] = 0;

  for (n = 0; n < outer_total; n++) {
    ca_size_t off = composed_base;
    for (k = 0; k < mndim - 1; k++) off += idx[k] * mstrides[k];

    /* Inner fill: if inner_stride == bytes, the inner run is contig
       and can be filled in a tight typed loop / memset-style.  Otherwise
       per-element memcpy at stride. */
    char *dst = root->ptr + off;
    if (inner_stride == bytes) {
      /* Tight contig fill: repeat the bytes-wide value inner_count times. */
      ca_size_t i;
      switch (bytes) {
      case 1: {
        int8_t v;
        memcpy(&v, ptr, 1);
        memset(dst, v, inner_count);
        break;
      }
      case 2: {
        int16_t v; memcpy(&v, ptr, 2);
        int16_t *d = (int16_t *) dst;
        for (i = 0; i < inner_count; i++) d[i] = v;
        break;
      }
      case 4: {
        int32_t v; memcpy(&v, ptr, 4);
        int32_t *d = (int32_t *) dst;
        for (i = 0; i < inner_count; i++) d[i] = v;
        break;
      }
      case 8: {
        int64_t v; memcpy(&v, ptr, 8);
        int64_t *d = (int64_t *) dst;
        for (i = 0; i < inner_count; i++) d[i] = v;
        break;
      }
      default:
        for (i = 0; i < inner_count; i++) memcpy(dst + i * bytes, ptr, bytes);
        break;
      }
    } else {
      /* Strided inner: per-element memcpy at byte stride. */
      ca_size_t i;
      for (i = 0; i < inner_count; i++) {
        memcpy(dst + i * inner_stride, ptr, bytes);
      }
    }

    for (k = mndim - 2; k >= 0; k--) {
      if (++idx[k] < mdim[k]) break;
      idx[k] = 0;
    }
  }

  /* The write went into root's own buffer; if that buffer is a view's
     scratch, only a sync puts it back.  Nothing to detach: this path is
     reached only when root was already attached, so the attach is not
     ours to close. */
  ca_sync(root);
}

static void
ca_stride_func_create_mask (void *ap)
{
  CAStride *ca = (CAStride *) ap;
  ca_create_mask(ca->parent);
  /* The mask for a CAStride is itself a CAStride over the parent's
     mask, with the same shape, strides, and base_offset.  Mask bytes
     are 1 byte each (boolean8_t), so we need to scale strides by
     parent->mask->bytes / parent->bytes -- but for the typical case
     mask->bytes == 1 and parent->bytes is the parent's item width.
     Strides in CAStride are byte-units already, so we need to convert
     to mask-byte-units.

     Element layout: walking idx by [1,0,...] in parent advances
     parent->ptr by strides[k] bytes (= strides[k]/parent->bytes
     elements).  The mask's same advance is in mask->bytes per element,
     so mask_strides[k] = (strides[k]/parent->bytes) * mask->bytes. */
  ca_size_t mask_strides[CA_RANK_MAX];
  ca_size_t mask_offset;
  int8_t k;
  ca_size_t parent_bytes = ca->parent->bytes;
  ca_size_t mask_bytes   = ca->parent->mask->bytes;
  for (k = 0; k < ca->ndim; k++) {
    mask_strides[k] = (ca->strides[k] / parent_bytes) * mask_bytes;
  }
  mask_offset = (ca->base_offset / parent_bytes) * mask_bytes;
  /* The mask of a subclassed CAStride (e.g. CATranspose) is the same
     subclass.  Pass ca->obj_type through so the Ruby mask wrapper
     picks up rb_cCATransMask / rb_cCAStrideMask correctly. */
  ca->mask =
    (CArray *) ca_stride_new(ca->obj_type, ca->parent->mask,
                             ca->parent->mask->data_type,
                             ca->parent->mask->bytes,
                             ca->ndim, ca->dim,
                             mask_strides, mask_offset);
}

ca_operation_function_t ca_stride_func = {
  -1,                       /* CA_OBJ_STRIDE: assigned at Init time */
  CA_VIEW_ARRAY,
  free_ca_stride,
  ca_stride_func_clone,
  ca_stride_func_allocate,
  ca_stride_func_attach,
  ca_stride_func_sync,
  ca_stride_func_detach,
  ca_stride_func_fill_data,
  ca_stride_func_create_mask,
  ca_stride_func_xfer_index,
  ca_stride_func_xfer_addrs,
  NULL,                       /* fold_stride: CAStride family is open-inline */
  ca_stride_func_xfer_stride,
  ca_stride_func_xfer_all,
  sizeof(CAStride),           /* struct_size: pool framework */
  ca_stride_pool_bytes,       /* pool_bytes  */
  ca_stride_pool_init,        /* pool_init   */
  .fill_stride  = ca_stride_func_fill_stride,
};

/* ------------------------------------------------------------------- */
/*  gather / scatter loops                                             */
/*                                                                     */
/*  Three fast paths followed by a correctness-first naive fallback.   */
/*  Roughly in order of preference per call:                           */
/*                                                                     */
/*    P1 -- whole view is a single contiguous row-major run            */
/*          (all strides match the natural product chain)              */
/*          --> one memcpy for the entire elements * bytes.            */
/*                                                                     */
/*    P2 -- innermost dim is contiguous (strides[ndim-1] == bytes)     */
/*          --> outer loop with carried offset, each row copied with   */
/*              memcpy. Handles the col-slice / strided-rows pattern   */
/*              produced by CABlock-style views and by negative        */
/*              outer-stride views (e.g. as_strided yrev).             */
/*                                                                     */
/*    P3 -- innermost stride is a positive multiple of bytes           */
/*          --> mcopy_step with element-stride.                        */
/*                                                                     */
/*    naive fallback -- per-element memcpy over a flat index walk.     */
/*          Used for negative innermost stride, byte-misaligned        */
/*          strides, and other shapes the fast paths can't express.    */
/* ------------------------------------------------------------------- */

/* True if `ca`'s strides describe a single row-major contiguous run.
   For each k: strides[k] == bytes * Product(dim[k+1:]) (innermost
   stride == bytes). dim[k] == 1 axes contribute no displacement, so
   their stride value is treated as a don't-care. */
/* Non-static: `ca_attach_is_alias` (carray_core.c) calls it to decide whether
   a CAStride-family parent is alias-attachable, i.e. whether ca_attach is
   O(1).  That predicate feeds the kernel iterator's alias decision. */
int
ca_stride_is_contiguous (CAStride *ca)
{
  ca_size_t expected = ca->bytes;
  int8_t k;
  for (k = ca->ndim - 1; k >= 0; k--) {
    if (ca->dim[k] != 1 && ca->strides[k] != expected) {
      return 0;
    }
    expected *= ca->dim[k];
  }
  return 1;
}

/* [MOVED] ca_stride_gather_run / ca_stride_scatter_run -> ca_iter_substrate.h
   as `static inline`.  The general driver below depends on them inlining, and
   ca_transform_common.c needs the same definition; a static inline in the
   header gives both call sites the inlinable typed loops. */

/* Test if `strides[]` describe a row-major contiguous run over `dim[]`
   with element size `bytes`.  Mirrors ca_stride_is_contiguous but
   takes an explicit strides array so the composed-fold path can re-test
   after composition. */
static int
ca_layout_is_contiguous (int8_t ndim, const ca_size_t *dim,
                         const ca_size_t *strides, ca_size_t bytes)
{
  ca_size_t expected = bytes;
  int8_t k;
  for (k = ndim - 1; k >= 0; k--) {
    if (dim[k] != 1 && strides[k] != expected) return 0;
    expected *= dim[k];
  }
  return 1;
}

/* Merges contig-mergeable adjacent axes in-place.
   Given (strides[], dim[], ndim_inout), fold adjacent axes k, k+1 when
   they describe a single contiguous run on the strided side:
       strides[k+1] != 0 && strides[k] == strides[k+1] * dim[k+1]
   stride==0 axes (CARepeat fences) and dim==1 axes are special-cased:
   dim==1 axes are squashed first (no displacement), stride==0 axes
   are not merged with their neighbours.

   Sign-agnostic: the condition uses signed equality so negative strides
   merge correctly as long as both adjacent strides agree in sign.

   No mutation when the input is already "merged" (idempotent). */
void
ca_stride_merge_axes (ca_size_t *strides,
                      ca_size_t *dim,
                      int8_t    *ndim_inout)
{
  int8_t ndim = *ndim_inout;
  int8_t i, w;

  if (ndim < 1) return;

  /* Pass 1: squash dim==1 axes (they carry no displacement; their
     stride is a don't-care for the gather loop). */
  w = 0;
  for (i = 0; i < ndim; i++) {
    if (dim[i] == 1) continue;
    if (i != w) {
      strides[w] = strides[i];
      dim[w] = dim[i];
    }
    w++;
  }
  ndim = w;
  if (ndim < 1) {
    /* All-dim-1: keep one trivial axis for the gather loop. */
    dim[0] = 1;
    strides[0] = 0;
    ndim = 1;
    *ndim_inout = ndim;
    return;
  }

  /* Pass 2: merge adjacent contig-mergeable pairs.  Loop with explicit
     index because merges shift trailing axes inward. */
  i = 0;
  while (i + 1 < ndim) {
    if (strides[i + 1] != 0
        && strides[i] == strides[i + 1] * dim[i + 1]) {
      /* Merge axis i with axis i+1: new axis at i has the inner stride
         and the combined count.  Shift the tail leftward. */
      dim[i]     = dim[i] * dim[i + 1];
      strides[i] = strides[i + 1];
      for (w = i + 1; w + 1 < ndim; w++) {
        strides[w] = strides[w + 1];
        dim[w]     = dim[w + 1];
      }
      ndim--;
      /* Stay at i; the new neighbour at i+1 might also merge. */
    } else {
      i++;
    }
  }

  *ndim_inout = ndim;
}

/* Generalised xfer: copy between ca->ptr (row-major contig) and the
   strided region at `base` with per-dim byte strides `strides[]`.
   `scatter == 0` gathers (strided -> contig), 1 scatters.
   Used both by the legacy ca_stride_gather/scatter wrappers (pass
   ca->strides and ca->parent->ptr + ca->base_offset) and by the
   composed-fold copy_data/sync_data (pass composed strides and a
   root-level base). */
void
ca_stride_xfer_with_layout (CAStride *ca, int scatter, char *base,
                            const ca_size_t *strides)
{
  ca_size_t bytes = ca->bytes;
  char *buf  = ca->ptr;                              /* row-major side */

  if (ca->elements == 0) return;

  /* Copy shape + strides locally and apply axis-merge before driving the
     fast paths.  Existing fast paths
     (P1 / P1.5 / general) consume the merged shape transparently:
     a fully-mergeable layout collapses to ndim=1 and lands on P1's
     whole-contig memcpy; a partially-mergeable one collapses outer
     iterations and feeds the general driver larger inner_count runs. */
  ca_size_t mdim[CA_RANK_MAX];
  ca_size_t mstrides[CA_RANK_MAX];
  int8_t mndim = ca->ndim;
  {
    int8_t i;
    for (i = 0; i < mndim; i++) {
      mdim[i]     = ca->dim[i];
      mstrides[i] = strides[i];
    }
    ca_stride_merge_axes(mstrides, mdim, &mndim);
  }

  /* P1: whole-view contiguous (in the strided side's layout) */
  if (ca_layout_is_contiguous(mndim, mdim, mstrides, bytes)) {
    if (scatter) memcpy(base, buf, ca->elements * bytes);
    else         memcpy(buf, base, ca->elements * bytes);
    return;
  }

  /* P1.5: 2D specialised fast paths for common element widths.  Strides
     are byte-valued; the inner loops advance source/destination pointers
     by raw byte counts and use constant-size memcpy for the unaligned
     load/store (single-instruction on x86/arm64). */
#define CA_STRIDE_2D_TYPED(T)                                         \
  do {                                                                \
    ca_size_t n0 = mdim[0];                                           \
    ca_size_t n1 = mdim[1];                                           \
    ca_size_t s0 = mstrides[0];                                       \
    ca_size_t s1 = mstrides[1];                                       \
    T *bp = (T *) buf;                                                \
    ca_size_t i, j;                                                   \
    if (scatter) {                                                    \
      for (i = 0; i < n0; i++) {                                      \
        char *dp = base + i * s0;                                     \
        for (j = 0; j < n1; j++) {                                    \
          T v = *bp++;                                                \
          memcpy(dp, &v, sizeof(T));                                  \
          dp += s1;                                                   \
        }                                                             \
      }                                                               \
    } else {                                                          \
      for (i = 0; i < n0; i++) {                                      \
        const char *sp = base + i * s0;                               \
        for (j = 0; j < n1; j++) {                                    \
          T v;                                                        \
          memcpy(&v, sp, sizeof(T));                                  \
          *bp++ = v;                                                  \
          sp += s1;                                                   \
        }                                                             \
      }                                                               \
    }                                                                 \
  } while (0)

  if (mndim == 2 && mstrides[1] != bytes) {
    switch (bytes) {
    case 1: CA_STRIDE_2D_TYPED(int8_t);  return;
    case 2: CA_STRIDE_2D_TYPED(int16_t); return;
    case 4: CA_STRIDE_2D_TYPED(int32_t); return;
    case 8: CA_STRIDE_2D_TYPED(int64_t); return;
    default: break;
    }
  }
#undef CA_STRIDE_2D_TYPED

  /* EXPLORED AND REJECTED: a cache-tiled tile-block branch here (mirroring
     the dispatcher / root-direct ndim>=2 branch) measured as a net loss for
     the `a.transpose.to_ca` family at typical sizes -- roughly 1.6-1.9x
     slower for ndim=3 [2,500,500] and ndim=4 [4,8,100,100].  The general
     driver below already cache-streams the innermost axis through
     ca_stride_gather_run's typed memcpy, and the per-tile L1 staging cost
     dominates the small inner-pair blocks these shapes produce.  Do not
     reattempt without first showing a regime where tiling wins. */

  /* General driver. */
  ca_size_t inner_count  = mdim[mndim - 1];
  ca_size_t inner_stride = mstrides[mndim - 1];
  ca_size_t outer_total  = ca->elements / inner_count;
  ca_size_t idx[CA_RANK_MAX];
  int8_t k;

  for (k = 0; k < mndim; k++) idx[k] = 0;

  ca_size_t n;
  for (n = 0; n < outer_total; n++) {
    ca_size_t off = 0;
    for (k = 0; k < mndim - 1; k++) off += idx[k] * mstrides[k];

    if (scatter) {
      ca_stride_scatter_run(base + off, buf, bytes, inner_count, inner_stride);
    } else {
      ca_stride_gather_run(buf, base + off, bytes, inner_count, inner_stride);
    }
    buf += inner_count * bytes;

    for (k = mndim - 2; k >= 0; k--) {
      if (++idx[k] < mdim[k]) break;
      idx[k] = 0;
    }
  }
}

/* ------------------------------------------------------------------- */
/*  Ruby-level construction and attribute readers                      */
/* ------------------------------------------------------------------- */

VALUE
rb_ca_stride_new (VALUE cary,
                  int8_t data_type, ca_size_t bytes,
                  int8_t ndim, ca_size_t *dim,
                  ca_size_t *strides, ca_size_t base_offset)
{
  volatile VALUE obj;
  CArray *parent;
  CAStride *ca;

  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca = ca_stride_new(CA_OBJ_STRIDE, parent,
                     data_type, bytes, ndim, dim, strides, base_offset);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

static VALUE
rb_cs_s_allocate (VALUE klass)
{
  CAStride *ca;
  return TypedData_Make_Struct(klass, CAStride, &castride_data_type, ca);
}

static VALUE
rb_cs_initialize_copy (VALUE self, VALUE other)
{
  CAStride *ca, *cs;
  TypedData_Get_Struct(self,  CAStride, &castride_data_type, ca);
  TypedData_Get_Struct(other, CAStride, &castride_data_type, cs);
  /* Pool framework: self was created by rb_cs_s_allocate (= TypedData_Make_Struct),
     so ca->_pool is NULL.  Wire up the pool before ca_stride_setup so the
     pool branch installs dim/strides. */
  if ( ca_func[CA_OBJ_STRIDE].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_STRIDE, cs->ndim);
  }
  ca_stride_setup(ca, cs->obj_type, cs->parent, cs->data_type, cs->bytes,
                  cs->ndim, cs->dim, cs->strides, cs->base_offset);
  rb_ca_set_parent(self, rb_ca_parent(other));
  return self;
}

/* Returns the byte strides as an Array of integers. */
static VALUE
rb_cs_strides (VALUE self)
{
  CAStride *cs;
  volatile VALUE ary;
  int8_t i;
  TypedData_Get_Struct(self, CAStride, &castride_data_type, cs);
  ary = rb_ary_new2(cs->ndim);
  for (i = 0; i < cs->ndim; i++) {
    rb_ary_store(ary, i, LL2NUM((long long) cs->strides[i]));
  }
  return ary;
}

/* Returns the byte offset from parent->ptr to the [0,...,0] element. */
static VALUE
rb_cs_byte_offset (VALUE self)
{
  CAStride *cs;
  TypedData_Get_Struct(self, CAStride, &castride_data_type, cs);
  return LL2NUM((long long) cs->base_offset);
}

/* as_strided(shape:, strides:, offset: 0) -- builds a CAStride view of the
   receiver from raw byte strides.  Inherits the receiver's data_type and
   bytes.

   CAREFUL: the strides / offset are NOT bounds-checked against the
   receiver's memory.  Every other view constructor derives strides that are
   known to stay inside the parent; here the caller supplies them, so an
   out-of-range combination reads or writes past the buffer. */
static VALUE
rb_ca_as_strided (int argc, VALUE *argv, VALUE self)
{
  CArray *parent;
  volatile VALUE ropt = Qnil, rshape = Qnil, rstrides = Qnil, roffset = Qnil;
  ca_size_t shape[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t base_offset = 0;
  int8_t ndim;
  long len, i;

  rb_check_carray_object(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);

  rb_scan_args(argc, argv, "0:", (VALUE *) &ropt);
  if (NIL_P(ropt)) {
    rb_raise(rb_eArgError,
             "as_strided requires keyword arguments: shape:, strides:");
  }
  rb_scan_options(ropt, "shape,strides,offset",
                  &rshape, &rstrides, &roffset);
  if (NIL_P(rshape) || NIL_P(rstrides)) {
    rb_raise(rb_eArgError,
             "as_strided requires both shape: and strides: keywords");
  }
  Check_Type(rshape,   T_ARRAY);
  Check_Type(rstrides, T_ARRAY);
  len = RARRAY_LEN(rshape);
  if (RARRAY_LEN(rstrides) != len) {
    rb_raise(rb_eArgError,
             "shape (%ld) and strides (%ld) length mismatch",
             len, RARRAY_LEN(rstrides));
  }
  if (len <= 0 || len > CA_RANK_MAX) {
    rb_raise(rb_eArgError, "invalid ndim %ld", len);
  }
  ndim = (int8_t) len;
  for (i = 0; i < len; i++) {
    shape[i]   = NUM2SIZE(RARRAY_AREF(rshape,   i));
    strides[i] = NUM2SIZE(RARRAY_AREF(rstrides, i));
  }
  if (! NIL_P(roffset)) {
    base_offset = NUM2SIZE(roffset);
  }

  return rb_ca_stride_new(self, parent->data_type, parent->bytes,
                          ndim, shape, strides, base_offset);
}

/* sliding_windows(*window, step: nil) -- overlapping-window view over every
   axis.  Parent [d0..dN-1] becomes [(di-wi)/si+1 ..., w0..wN-1]; result rank
   is 2*ndim, so the parent's ndim must not exceed CA_RANK_MAX / 2.  Truncate
   mode: no padding.  Windows overlap, so the view aliases each parent cell
   from several positions. */
static VALUE
rb_ca_sliding_windows (int argc, VALUE *argv, VALUE self)
{
  CArray *parent;
  volatile VALUE rposary = Qnil, ropt = Qnil, rstep = Qnil;
  ca_size_t window[CA_RANK_MAX];
  ca_size_t step[CA_RANK_MAX];
  ca_size_t outdim[CA_RANK_MAX];
  ca_size_t outstrides[CA_RANK_MAX];
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  int8_t i, ndim;
  long nargs;

  rb_check_carray_object(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);

  ndim = parent->ndim;
  if (2 * (int) ndim > CA_RANK_MAX) {
    rb_raise(rb_eArgError,
             "sliding_windows: result rank %d exceeds CA_RANK_MAX (%d)",
             2 * (int) ndim, CA_RANK_MAX);
  }

  rb_scan_args(argc, argv, "*:", (VALUE *) &rposary, (VALUE *) &ropt);
  if (! NIL_P(ropt)) {
    rb_scan_options(ropt, "step", &rstep);
  }
  nargs = RARRAY_LEN(rposary);

  if (nargs == 1 && TYPE(RARRAY_AREF(rposary, 0)) == T_ARRAY) {
    volatile VALUE wary = RARRAY_AREF(rposary, 0);
    if (RARRAY_LEN(wary) != ndim) {
      rb_raise(rb_eArgError,
               "sliding_windows: window length (%ld) must equal ndim (%d)",
               RARRAY_LEN(wary), (int) ndim);
    }
    for (i = 0; i < ndim; i++) {
      window[i] = NUM2SIZE(RARRAY_AREF(wary, i));
    }
  }
  else if (nargs == ndim) {
    for (i = 0; i < ndim; i++) {
      window[i] = NUM2SIZE(RARRAY_AREF(rposary, i));
    }
  }
  else {
    rb_raise(rb_eArgError,
             "sliding_windows: expected %d window sizes (or one Array), got %ld",
             (int) ndim, nargs);
  }

  if (NIL_P(rstep)) {
    for (i = 0; i < ndim; i++) step[i] = 1;
  }
  else if (TYPE(rstep) == T_ARRAY) {
    if (RARRAY_LEN(rstep) != ndim) {
      rb_raise(rb_eArgError,
               "sliding_windows: step length (%ld) must equal ndim (%d)",
               RARRAY_LEN(rstep), (int) ndim);
    }
    for (i = 0; i < ndim; i++) {
      step[i] = NUM2SIZE(RARRAY_AREF(rstep, i));
    }
  }
  else {
    ca_size_t s = NUM2SIZE(rstep);
    for (i = 0; i < ndim; i++) step[i] = s;
  }

  for (i = 0; i < ndim; i++) {
    if (window[i] < 1) {
      rb_raise(rb_eArgError,
               "sliding_windows: window[%d]=%lld must be >= 1",
               (int) i, (long long) window[i]);
    }
    if (window[i] > parent->dim[i]) {
      rb_raise(rb_eArgError,
               "sliding_windows: window[%d]=%lld larger than parent dim[%d]=%lld",
               (int) i, (long long) window[i],
               (int) i, (long long) parent->dim[i]);
    }
    if (step[i] < 1) {
      rb_raise(rb_eArgError,
               "sliding_windows: step[%d]=%lld must be >= 1",
               (int) i, (long long) step[i]);
    }
  }

  {
    ca_size_t s = parent->bytes;
    for (i = ndim - 1; i >= 0; i--) {
      parent_byte_stride[i] = s;
      s *= parent->dim[i];
    }
  }

  for (i = 0; i < ndim; i++) {
    outdim[i] = (parent->dim[i] - window[i]) / step[i] + 1;
    outdim[ndim + i] = window[i];
    outstrides[i] = parent_byte_stride[i] * step[i];
    outstrides[ndim + i] = parent_byte_stride[i];
  }

  return rb_ca_stride_new(self, parent->data_type, parent->bytes,
                          (int8_t)(2 * ndim), outdim, outstrides, 0);
}

/* unfold(*window, step: nil) -- sliding_windows over the leading `S` axes
   only, with the remaining `ndim - S` trailing axes riding along at their
   original strides.  The window axes are inserted before the trailing ones,
   so the result rank is ndim + S.  With S == ndim this is exactly
   sliding_windows. */
static VALUE
rb_ca_unfold (int argc, VALUE *argv, VALUE self)
{
  CArray *parent;
  volatile VALUE rposary = Qnil, ropt = Qnil, rstep = Qnil;
  ca_size_t window[CA_RANK_MAX];
  ca_size_t step[CA_RANK_MAX];
  ca_size_t outdim[CA_RANK_MAX];
  ca_size_t outstrides[CA_RANK_MAX];
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  int8_t i, ndim, nspatial, ntrail;
  int outrank;
  long nargs;

  rb_check_carray_object(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);

  ndim = parent->ndim;

  rb_scan_args(argc, argv, "*:", (VALUE *) &rposary, (VALUE *) &ropt);
  if (! NIL_P(ropt)) {
    rb_scan_options(ropt, "step", &rstep);
  }
  nargs = RARRAY_LEN(rposary);

  if (nargs == 1 && TYPE(RARRAY_AREF(rposary, 0)) == T_ARRAY) {
    volatile VALUE wary = RARRAY_AREF(rposary, 0);
    if (RARRAY_LEN(wary) < 1 || RARRAY_LEN(wary) > ndim) {
      rb_raise(rb_eArgError,
               "unfold: window length (%ld) must be between 1 and ndim (%d)",
               RARRAY_LEN(wary), (int) ndim);
    }
    nspatial = (int8_t) RARRAY_LEN(wary);
    for (i = 0; i < nspatial; i++) {
      window[i] = NUM2SIZE(RARRAY_AREF(wary, i));
    }
  }
  else if (nargs >= 1 && nargs <= ndim) {
    nspatial = (int8_t) nargs;
    for (i = 0; i < nspatial; i++) {
      window[i] = NUM2SIZE(RARRAY_AREF(rposary, i));
    }
  }
  else {
    rb_raise(rb_eArgError,
             "unfold: expected 1..%d window sizes (or one Array), got %ld",
             (int) ndim, nargs);
  }

  ntrail = ndim - nspatial;
  outrank = (int) ndim + (int) nspatial;
  if (outrank > CA_RANK_MAX) {
    rb_raise(rb_eArgError,
             "unfold: result rank %d exceeds CA_RANK_MAX (%d)",
             outrank, CA_RANK_MAX);
  }

  if (NIL_P(rstep)) {
    for (i = 0; i < nspatial; i++) step[i] = 1;
  }
  else if (TYPE(rstep) == T_ARRAY) {
    if (RARRAY_LEN(rstep) != nspatial) {
      rb_raise(rb_eArgError,
               "unfold: step length (%ld) must equal window length (%d)",
               RARRAY_LEN(rstep), (int) nspatial);
    }
    for (i = 0; i < nspatial; i++) {
      step[i] = NUM2SIZE(RARRAY_AREF(rstep, i));
    }
  }
  else {
    ca_size_t s = NUM2SIZE(rstep);
    for (i = 0; i < nspatial; i++) step[i] = s;
  }

  for (i = 0; i < nspatial; i++) {
    if (window[i] < 1) {
      rb_raise(rb_eArgError,
               "unfold: window[%d]=%lld must be >= 1",
               (int) i, (long long) window[i]);
    }
    if (window[i] > parent->dim[i]) {
      rb_raise(rb_eArgError,
               "unfold: window[%d]=%lld larger than parent dim[%d]=%lld",
               (int) i, (long long) window[i],
               (int) i, (long long) parent->dim[i]);
    }
    if (step[i] < 1) {
      rb_raise(rb_eArgError,
               "unfold: step[%d]=%lld must be >= 1",
               (int) i, (long long) step[i]);
    }
  }

  {
    ca_size_t s = parent->bytes;
    for (i = ndim - 1; i >= 0; i--) {
      parent_byte_stride[i] = s;
      s *= parent->dim[i];
    }
  }

  for (i = 0; i < nspatial; i++) {
    outdim[i] = (parent->dim[i] - window[i]) / step[i] + 1;
    outdim[nspatial + i] = window[i];
    outstrides[i] = parent_byte_stride[i] * step[i];
    outstrides[nspatial + i] = parent_byte_stride[i];
  }
  for (i = 0; i < ntrail; i++) {
    outdim[2 * nspatial + i] = parent->dim[nspatial + i];
    outstrides[2 * nspatial + i] = parent_byte_stride[nspatial + i];
  }

  return rb_ca_stride_new(self, parent->data_type, parent->bytes,
                          (int8_t) outrank, outdim, outstrides, 0);
}

/* block_view(*block) -- non-overlapping tile view.  Parent [d0..dN-1]
   becomes [d0/b0 ..., b0..bN-1]; result rank is 2*ndim.  Unlike
   sliding_windows each parent dim must divide evenly, so no cell is dropped
   and none is aliased twice. */
static VALUE
rb_ca_block_view (int argc, VALUE *argv, VALUE self)
{
  CArray *parent;
  volatile VALUE rposary = Qnil, ropt = Qnil;
  ca_size_t block[CA_RANK_MAX];
  ca_size_t outdim[CA_RANK_MAX];
  ca_size_t outstrides[CA_RANK_MAX];
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  int8_t i, ndim;
  long nargs;

  rb_check_carray_object(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);

  ndim = parent->ndim;
  if (2 * (int) ndim > CA_RANK_MAX) {
    rb_raise(rb_eArgError,
             "block_view: result rank %d exceeds CA_RANK_MAX (%d)",
             2 * (int) ndim, CA_RANK_MAX);
  }

  rb_scan_args(argc, argv, "*:", (VALUE *) &rposary, (VALUE *) &ropt);
  rb_reject_options(ropt);
  nargs = RARRAY_LEN(rposary);

  if (nargs == 1 && TYPE(RARRAY_AREF(rposary, 0)) == T_ARRAY) {
    volatile VALUE bary = RARRAY_AREF(rposary, 0);
    if (RARRAY_LEN(bary) != ndim) {
      rb_raise(rb_eArgError,
               "block_view: block length (%ld) must equal ndim (%d)",
               RARRAY_LEN(bary), (int) ndim);
    }
    for (i = 0; i < ndim; i++) {
      block[i] = NUM2SIZE(RARRAY_AREF(bary, i));
    }
  }
  else if (nargs == ndim) {
    for (i = 0; i < ndim; i++) {
      block[i] = NUM2SIZE(RARRAY_AREF(rposary, i));
    }
  }
  else {
    rb_raise(rb_eArgError,
             "block_view: expected %d block sizes (or one Array), got %ld",
             (int) ndim, nargs);
  }

  for (i = 0; i < ndim; i++) {
    if (block[i] < 1) {
      rb_raise(rb_eArgError,
               "block_view: block[%d]=%lld must be >= 1",
               (int) i, (long long) block[i]);
    }
    if (parent->dim[i] % block[i] != 0) {
      rb_raise(rb_eArgError,
               "block_view: parent dim[%d]=%lld is not divisible by block[%d]=%lld",
               (int) i, (long long) parent->dim[i],
               (int) i, (long long) block[i]);
    }
  }

  {
    ca_size_t s = parent->bytes;
    for (i = ndim - 1; i >= 0; i--) {
      parent_byte_stride[i] = s;
      s *= parent->dim[i];
    }
  }

  for (i = 0; i < ndim; i++) {
    outdim[i] = parent->dim[i] / block[i];
    outdim[ndim + i] = block[i];
    outstrides[i] = parent_byte_stride[i] * block[i];
    outstrides[ndim + i] = parent_byte_stride[i];
  }

  return rb_ca_stride_new(self, parent->data_type, parent->bytes,
                          (int8_t)(2 * ndim), outdim, outstrides, 0);
}

/* defined in ca_obj_transpose.c */
extern VALUE rb_ca_trans_new (VALUE cary, ca_size_t *imap);

/* dim_view(*axes) -- moves the given axes to the front, keeping the rest in
   order.  A thin alias over `transposed` that names the intent, so it returns
   a CATranspose and inherits its alias path and mask propagation. */
static VALUE
rb_ca_dim_view (int argc, VALUE *argv, VALUE self)
{
  CArray *parent;
  volatile VALUE rposary = Qnil, ropt = Qnil;
  ca_size_t iter_axes[CA_RANK_MAX];
  ca_size_t imap[CA_RANK_MAX];
  int8_t seen[CA_RANK_MAX];
  int8_t ndim, n_iter, i, k;
  long nargs;

  rb_check_carray_object(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);
  ndim = parent->ndim;

  rb_scan_args(argc, argv, "*:", (VALUE *) &rposary, (VALUE *) &ropt);
  rb_reject_options(ropt);
  nargs = RARRAY_LEN(rposary);

  /* Accept either a single Array of axes or variadic Integers. */
  if (nargs == 1 && TYPE(RARRAY_AREF(rposary, 0)) == T_ARRAY) {
    volatile VALUE aary = RARRAY_AREF(rposary, 0);
    n_iter = (int8_t) RARRAY_LEN(aary);
    if (n_iter < 1) {
      rb_raise(rb_eArgError, "dim_view: at least one iteration axis required");
    }
    if (n_iter > ndim) {
      rb_raise(rb_eArgError,
               "dim_view: too many iteration axes (%d) for ndim (%d)",
               (int) n_iter, (int) ndim);
    }
    for (i = 0; i < n_iter; i++) {
      iter_axes[i] = NUM2SIZE(RARRAY_AREF(aary, i));
    }
  }
  else if (nargs >= 1) {
    if (nargs > ndim) {
      rb_raise(rb_eArgError,
               "dim_view: too many iteration axes (%ld) for ndim (%d)",
               nargs, (int) ndim);
    }
    n_iter = (int8_t) nargs;
    for (i = 0; i < n_iter; i++) {
      iter_axes[i] = NUM2SIZE(RARRAY_AREF(rposary, i));
    }
  }
  else {
    rb_raise(rb_eArgError,
             "dim_view: at least one iteration axis required");
  }

  /* Normalize negative indices and validate range / distinctness. */
  for (i = 0; i < ndim; i++) seen[i] = 0;
  for (i = 0; i < n_iter; i++) {
    ca_size_t a = iter_axes[i];
    if (a < 0) a += ndim;
    if (a < 0 || a >= ndim) {
      rb_raise(rb_eArgError,
               "dim_view: axis %lld out of range for ndim %d",
               (long long) iter_axes[i], (int) ndim);
    }
    if (seen[a]) {
      rb_raise(rb_eArgError,
               "dim_view: duplicate iteration axis %lld",
               (long long) a);
    }
    seen[a] = 1;
    iter_axes[i] = a;
  }

  /* imap: iter axes first (in given order), then remaining axes
     (in original order). */
  for (i = 0; i < n_iter; i++) {
    imap[i] = iter_axes[i];
  }
  k = n_iter;
  for (i = 0; i < ndim; i++) {
    if (! seen[i]) imap[k++] = i;
  }

  return rb_ca_trans_new(self, imap);
}

/* flip(*axes) -- reverses the listed axes by negating their strides; with no
   argument every axis is flipped.  The named counterpart of the indexer form
   ca[-1..0, nil, -1..0]: both give a true negative-stride view, zero copy and
   write-through. */
/* Build the flipped CAStride view from a per-axis flip[] flag array.
 * Shared by rb_ca_flip (Ruby entry) and rb_ca_flip_axis (C-callable entry).
 * Each flip[i] == 1 reverses axis i; 0 leaves it as-is. */
static VALUE
rb_ca_flip_build_view (VALUE self, CArray *parent, const int8_t *flip)
{
  int8_t ndim = parent->ndim;
  int8_t i;
  ca_size_t outdim[CA_RANK_MAX];
  ca_size_t outstrides[CA_RANK_MAX];
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  ca_size_t base_offset = 0;

  /* parent row-major byte strides */
  {
    ca_size_t s = parent->bytes;
    for (i = ndim - 1; i >= 0; i--) {
      parent_byte_stride[i] = s;
      s *= parent->dim[i];
    }
  }

  /* Build flipped strides and the corresponding base_offset.
     A flipped axis i contributes (dim[i]-1)*parent_byte_stride[i]
     to base_offset and has its stride sign inverted. */
  for (i = 0; i < ndim; i++) {
    outdim[i] = parent->dim[i];
    if (flip[i]) {
      outstrides[i] = -parent_byte_stride[i];
      base_offset += (parent->dim[i] - 1) * parent_byte_stride[i];
    }
    else {
      outstrides[i] = parent_byte_stride[i];
    }
  }

  VALUE obj = rb_ca_stride_new(self, parent->data_type, parent->bytes,
                               ndim, outdim, outstrides, base_offset);
  CA_WRAPPER_LIFT(obj, self, parent);
  return obj;
}

/* C-callable entry: flip a single axis (= the common case).
 * No rb_scan_args, safe to call directly from C.  axis is normalized
 * here (Python-style negative allowed).  For ext authors. */
VALUE
rb_ca_flip_axis (VALUE self, long axis)
{
  CArray *parent;
  rb_check_carray_object(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);
  int8_t ndim = parent->ndim;
  long a = (axis < 0) ? (axis + ndim) : axis;
  if (a < 0 || a >= ndim) {
    rb_raise(rb_eArgError,
             "flip_axis: axis %ld out of range for ndim %d",
             axis, (int) ndim);
  }
  int8_t flip[CA_RANK_MAX] = {0};
  flip[a] = 1;
  return rb_ca_flip_build_view(self, parent, flip);
}

/* Ruby binding entry: parses *args (axes) -> builds flip[] -> forwards. */
static VALUE
rb_ca_flip (int argc, VALUE *argv, VALUE self)
{
  CArray *parent;
  volatile VALUE rposary = Qnil, ropt = Qnil;
  ca_size_t axes[CA_RANK_MAX];
  int8_t flip[CA_RANK_MAX];
  int8_t ndim, n_axes, i;
  long nargs;

  rb_check_carray_object(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);
  ndim = parent->ndim;

  rb_scan_args(argc, argv, "*:", (VALUE *) &rposary, (VALUE *) &ropt);
  rb_reject_options(ropt);
  nargs = RARRAY_LEN(rposary);

  for (i = 0; i < ndim; i++) flip[i] = 0;

  if (nargs == 0) {
    /* No args: flip every axis. */
    for (i = 0; i < ndim; i++) flip[i] = 1;
    n_axes = ndim;
  }
  else {
    if (nargs == 1 && TYPE(RARRAY_AREF(rposary, 0)) == T_ARRAY) {
      volatile VALUE aary = RARRAY_AREF(rposary, 0);
      n_axes = (int8_t) RARRAY_LEN(aary);
      if (n_axes > ndim) {
        rb_raise(rb_eArgError,
                 "flip: too many axes (%d) for ndim (%d)",
                 (int) n_axes, (int) ndim);
      }
      for (i = 0; i < n_axes; i++) {
        axes[i] = NUM2SIZE(RARRAY_AREF(aary, i));
      }
    }
    else {
      if (nargs > ndim) {
        rb_raise(rb_eArgError,
                 "flip: too many axes (%ld) for ndim (%d)",
                 nargs, (int) ndim);
      }
      n_axes = (int8_t) nargs;
      for (i = 0; i < n_axes; i++) {
        axes[i] = NUM2SIZE(RARRAY_AREF(rposary, i));
      }
    }

    for (i = 0; i < n_axes; i++) {
      ca_size_t a = axes[i];
      if (a < 0) a += ndim;
      if (a < 0 || a >= ndim) {
        rb_raise(rb_eArgError,
                 "flip: axis %lld out of range for ndim %d",
                 (long long) axes[i], (int) ndim);
      }
      if (flip[a]) {
        rb_raise(rb_eArgError,
                 "flip: duplicate axis %lld",
                 (long long) a);
      }
      flip[a] = 1;
    }
  }

  (void) n_axes;  /* unused after validation */
  return rb_ca_flip_build_view(self, parent, flip);
}

/* diagonal(offset = 0, axis: [0, 1]) -- view of one diagonal of the parent.
   The two designated axes collapse into a single diagonal axis appended at
   the END of the result; the remaining axes keep their order in front.
   `offset` shifts off the main diagonal (positive = super, negative = sub);
   an offset past the relevant axis yields an empty view. */
static VALUE
rb_ca_diagonal (int argc, VALUE *argv, VALUE self)
{
  CArray *parent;
  volatile VALUE rposary = Qnil, ropt = Qnil;
  volatile VALUE raxis = Qnil, roffset = Qnil;
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  ca_size_t outdim[CA_RANK_MAX];
  ca_size_t outstrides[CA_RANK_MAX];
  ca_size_t offset = 0;
  ca_size_t base_offset = 0;
  ca_size_t diag_len;
  ca_size_t ai, aj;     /* normalized axis indices */
  int8_t ndim, out_k, i;
  long nargs;

  rb_check_carray_object(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);
  ndim = parent->ndim;

  if (ndim < 2) {
    rb_raise(rb_eArgError, "diagonal: requires ndim >= 2 (got %d)", (int) ndim);
  }

  rb_scan_args(argc, argv, "*:", (VALUE *) &rposary, (VALUE *) &ropt);
  if (! NIL_P(ropt)) {
    rb_scan_options(ropt, "axis,offset", &raxis, &roffset);
  }
  nargs = RARRAY_LEN(rposary);

  /* offset from positional or keyword (not both) */
  if (nargs == 0) {
    if (! NIL_P(roffset)) offset = NUM2SIZE(roffset);
  }
  else if (nargs == 1) {
    if (! NIL_P(roffset)) {
      rb_raise(rb_eArgError,
               "diagonal: give offset positionally OR as keyword, not both");
    }
    offset = NUM2SIZE(RARRAY_AREF(rposary, 0));
  }
  else {
    rb_raise(rb_eArgError,
             "diagonal: too many positional args (got %ld, expected 0 or 1)",
             nargs);
  }

  /* axes: keyword, default [0, 1] */
  ai = 0;
  aj = 1;
  if (! NIL_P(raxis)) {
    if (TYPE(raxis) != T_ARRAY || RARRAY_LEN(raxis) != 2) {
      rb_raise(rb_eArgError,
               "diagonal: axis: must be an Array of 2 integers");
    }
    ai = NUM2SIZE(RARRAY_AREF(raxis, 0));
    aj = NUM2SIZE(RARRAY_AREF(raxis, 1));
    if (ai < 0) ai += ndim;
    if (aj < 0) aj += ndim;
    if (ai < 0 || ai >= ndim) {
      rb_raise(rb_eArgError, "diagonal: axis[0] out of range for ndim %d",
               (int) ndim);
    }
    if (aj < 0 || aj >= ndim) {
      rb_raise(rb_eArgError, "diagonal: axis[1] out of range for ndim %d",
               (int) ndim);
    }
    if (ai == aj) {
      rb_raise(rb_eArgError, "diagonal: axis[0] and axis[1] must be distinct");
    }
  }

  /* parent row-major byte strides */
  {
    ca_size_t s = parent->bytes;
    for (i = ndim - 1; i >= 0; i--) {
      parent_byte_stride[i] = s;
      s *= parent->dim[i];
    }
  }

  /* compute diagonal length and base_offset */
  if (offset >= 0) {
    if (offset >= parent->dim[aj]) {
      diag_len = 0;
    }
    else {
      ca_size_t a = parent->dim[ai];
      ca_size_t b = parent->dim[aj] - offset;
      diag_len = (a < b) ? a : b;
    }
    base_offset = offset * parent_byte_stride[aj];
  }
  else {
    ca_size_t neg = -offset;
    if (neg >= parent->dim[ai]) {
      diag_len = 0;
    }
    else {
      ca_size_t a = parent->dim[ai] - neg;
      ca_size_t b = parent->dim[aj];
      diag_len = (a < b) ? a : b;
    }
    base_offset = neg * parent_byte_stride[ai];
  }

  /* build output: kept axes (in original order), then diagonal axis */
  out_k = 0;
  for (i = 0; i < ndim; i++) {
    if (i == (int8_t) ai || i == (int8_t) aj) continue;
    outdim[out_k] = parent->dim[i];
    outstrides[out_k] = parent_byte_stride[i];
    out_k++;
  }
  outdim[out_k] = diag_len;
  outstrides[out_k] = parent_byte_stride[ai] + parent_byte_stride[aj];
  out_k++;

  {
    VALUE obj = rb_ca_stride_new(self, parent->data_type, parent->bytes,
                                 out_k, outdim, outstrides, base_offset);
    CA_WRAPPER_LIFT(obj, self, parent);
    return obj;
  }
}

void
Init_ca_obj_stride (void)
{
  /* rb_cCAStride and rb_cCAStrideMask are defined upfront in
     ruby_carray.c, so subclasses (CARepeat, CATranspose, CAFarray)
     can be defined before this Init runs. */

  CA_OBJ_STRIDE = ca_install_obj_type(rb_cCAStride,
                                      &castride_data_type,
                                      rb_cCAStrideMask,
                                      &castride_mask_data_type,
                                      &ca_stride_func, sizeof(ca_stride_func));
  rb_define_const(rb_cObject, "CA_OBJ_STRIDE", INT2NUM(CA_OBJ_STRIDE));

  rb_define_alloc_func(rb_cCAStride, rb_cs_s_allocate);
  rb_define_method(rb_cCAStride, "initialize_copy", rb_cs_initialize_copy, 1);

  rb_define_method(rb_cCAStride, "strides",     rb_cs_strides, 0);
  rb_define_method(rb_cCAStride, "byte_offset", rb_cs_byte_offset, 0);

  rb_define_method(rb_cCArray,   "as_strided",  rb_ca_as_strided, -1);
  rb_define_method(rb_cCArray,   "sliding_windows",
                                                rb_ca_sliding_windows, -1);
  rb_define_method(rb_cCArray,   "unfold",      rb_ca_unfold, -1);
  rb_define_method(rb_cCArray,   "block_view",  rb_ca_block_view, -1);
  rb_define_method(rb_cCArray,   "dim_view",    rb_ca_dim_view, -1);
  rb_define_method(rb_cCArray,   "flip",   rb_ca_flip, -1);
  /* `reverse` = `flip` no-arg form (= all-axis reversed view).  Direct CAStride
     construction with negative strides, no indexer / attach detour. */
  rb_define_alias(rb_cCArray,    "reverse", "flip");
  rb_define_method(rb_cCArray,   "diagonal", rb_ca_diagonal, -1);
}
