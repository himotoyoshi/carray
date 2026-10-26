/* ---------------------------------------------------------------------------

  Mask machinery shared by every CArray subtype: has_mask / any-masked /
  all-masked scans, mask creation and propagation across the view chain,
  the mask SET family (mask_eq / mask_invalid / mask_where / strip_mask),
  count_masked, and the word-bulk boolean bit-op fast paths.

---------------------------------------------------------------------------- */

#include <stdarg.h>
#include <stdint.h>
#include "ruby.h"
#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_* */
#include "ca_obj_face.h"  /* CA_FACE_LIFT_IF_FACE for the mask-lift path */
#include <ruby/ractor.h>

/* ============================================================================
 *  Word-bulk mask substrate helpers.
 *
 *  CAREFUL: every helper here relies on the invariant that a mask / bool
 *  byte is in {0, 1} throughout all production code paths (OBJ2BOOL strict,
 *  integer->bool cast raises on out-of-range, comparison output is
 *  C-semantic 0/1, the mask combiner forces *ma=1, and an external mask via
 *  ca_wrap_readonly normalises).  Breaking it corrupts the word-level ops.
 *
 *  Word loop: uint64_t (8 byte/op) + tail byte fallback (n % 8).
 *  NOT uses an LSB XOR pattern (w ^ 0x0101...01ULL) to preserve the
 *  invariant (byte ~ would produce 0xFE, violating {0,1}).
 *
 *  Helpers are static inline (file-local), inlinable into callers within
 *  this translation unit (overlay_n, is_any_masked, is_all_masked, etc.).
 *  extern + header extraction can wait until a cross-file need arises.
 *  Placed at the top of the TU so the inline body is visible at every call
 *  site.
 * ============================================================================ */

#define CA_MASK_WORD_BYTES 8
#define CA_MASK_WORD_LSB   0x0101010101010101ULL

/* A mask may start at any byte (a window or a block view offsets it), so a
   word is read and written through memcpy, never through a uint64_t
   pointer; the compiler still lowers each to a single load or store.  */
static inline uint64_t
ca_mask_word_load (const boolean8_t *p)
{
  uint64_t w;
  memcpy(&w, p, sizeof(w));
  return w;
}

static inline void
ca_mask_word_store (boolean8_t *p, uint64_t w)
{
  memcpy(p, &w, sizeof(w));
}

/* ma[i] |= ms[i] for i in [0, n)  -- used by ca_copy_mask_overlay_n */
static inline void
ca_mask_word_or (boolean8_t *ma, const boolean8_t *ms, ca_size_t n)
{
  ca_size_t       nw = n / CA_MASK_WORD_BYTES;
  ca_size_t       i;
  for (i = 0; i < nw; i++) {
    ca_mask_word_store(ma + i*CA_MASK_WORD_BYTES,
                       ca_mask_word_load(ma + i*CA_MASK_WORD_BYTES) | ca_mask_word_load(ms + i*CA_MASK_WORD_BYTES));
  }
  for (i = nw * CA_MASK_WORD_BYTES; i < n; i++) {
    ma[i] |= ms[i];
  }
}

/* md[i] = ma[i] & mb[i] for i in [0, n) */
static inline void
ca_mask_word_and (boolean8_t       *md,
                  const boolean8_t *ma,
                  const boolean8_t *mb,
                  ca_size_t         n)
{
  ca_size_t       nw = n / CA_MASK_WORD_BYTES;
  ca_size_t       i;
  for (i = 0; i < nw; i++) {
    ca_mask_word_store(md + i*CA_MASK_WORD_BYTES,
                       ca_mask_word_load(ma + i*CA_MASK_WORD_BYTES) & ca_mask_word_load(mb + i*CA_MASK_WORD_BYTES));
  }
  for (i = nw * CA_MASK_WORD_BYTES; i < n; i++) {
    md[i] = ma[i] & mb[i];
  }
}

/* md[i] = ma[i] ^ mb[i] for i in [0, n) */
static inline void
ca_mask_word_xor (boolean8_t       *md,
                  const boolean8_t *ma,
                  const boolean8_t *mb,
                  ca_size_t         n)
{
  ca_size_t       nw = n / CA_MASK_WORD_BYTES;
  ca_size_t       i;
  for (i = 0; i < nw; i++) {
    ca_mask_word_store(md + i*CA_MASK_WORD_BYTES,
                       ca_mask_word_load(ma + i*CA_MASK_WORD_BYTES) ^ ca_mask_word_load(mb + i*CA_MASK_WORD_BYTES));
  }
  for (i = nw * CA_MASK_WORD_BYTES; i < n; i++) {
    md[i] = ma[i] ^ mb[i];
  }
}

/* md[i] = 1 - ms[i] (LSB XOR pattern; preserves byte ∈ {0,1} invariant) */
static inline void
ca_mask_word_not (boolean8_t *md, const boolean8_t *ms, ca_size_t n)
{
  ca_size_t       nw = n / CA_MASK_WORD_BYTES;
  ca_size_t       i;
  for (i = 0; i < nw; i++) {
    ca_mask_word_store(md + i*CA_MASK_WORD_BYTES, ca_mask_word_load(ms + i*CA_MASK_WORD_BYTES) ^ CA_MASK_WORD_LSB);
  }
  for (i = nw * CA_MASK_WORD_BYTES; i < n; i++) {
    md[i] = ms[i] ^ (boolean8_t) 1;
  }
}

/* 1 if any byte in [0, n) is non-zero, 0 otherwise (with early exit).
   Consumer: ca_is_any_masked / any_masked? scan. */
static inline int
ca_mask_word_any (const boolean8_t *m, ca_size_t n)
{
  ca_size_t       nw = n / CA_MASK_WORD_BYTES;
  ca_size_t       i;
  for (i = 0; i < nw; i++) {
    if ( ca_mask_word_load(m + i*CA_MASK_WORD_BYTES) != 0 ) return 1;
  }
  for (i = nw * CA_MASK_WORD_BYTES; i < n; i++) {
    if ( m[i] ) return 1;
  }
  return 0;
}

/* 1 if every byte in [0, n) is non-zero, 0 otherwise (with early exit).
   The {0,1} invariant makes a word check (w == LSB pattern) sufficient.
   Consumer: ca_is_all_masked / all_masked? scan. */
static inline int
ca_mask_word_all_set (const boolean8_t *m, ca_size_t n)
{
  ca_size_t       nw = n / CA_MASK_WORD_BYTES;
  ca_size_t       i;
  for (i = 0; i < nw; i++) {
    if ( ca_mask_word_load(m + i*CA_MASK_WORD_BYTES) != CA_MASK_WORD_LSB ) return 0;
  }
  for (i = nw * CA_MASK_WORD_BYTES; i < n; i++) {
    if ( ! m[i] ) return 0;
  }
  return 1;
}

/* Count of set bytes in [0, n).  Under the {0,1} invariant, a plain accumulate of
   uint8 lanes (no popcount needed); compilers lower this to a horizontal
   byte-sum (psadbw / uaddlv).  Consumer: ca_count_masked.  */
static inline ca_size_t
ca_mask_word_count (const boolean8_t *m, ca_size_t n)
{
  ca_size_t i, count = 0;
  for (i = 0; i < n; i++) {
    count += m[i];
  }
  return count;
}

/* ============================================================================
 *  (End of the word-bulk helpers.  Smoke surface for these helpers is at
 *   the bottom of this file, just before Init_carray_mask.)
 * ============================================================================ */

/* ----------------------------------------------------------------------------
 *  Virtual-mask block scan (non-materialise reduction)
 *
 *  When a mask is a virtual view (e.g. CAStackMask composed by
 *  ca_stack_func_create_mask), ca_attach
 *  materialises the WHOLE composed mask before the word scan — which defeats
 *  the early-exit of any/all and forces peak O(n) memory.  Instead, drive
 *  ca_xfer_stride over the mask in row-slab blocks pulled into one arena
 *  scratch (the same mechanism CAMonOp uses to consume a virtual source
 *  without materialising it).  Peak memory = one block; ANY/ALL short-circuit
 *  on the first decisive block (a masked cell in block 0 of a K-deep CAStack
 *  returns after pulling 1/K of the data, never touching the rest).
 *
 *  Only used for NON-alias masks (cheap/entity masks keep the O(1)-alias
 *  attach + direct word scan above).  Blocking is along axis 0; for arrays
 *  with a very wide inner product (> CA_MASK_BLOCK_BYTES) the block degrades
 *  to a single row, which is still O(row) peak rather than O(n).
 * ---------------------------------------------------------------------------- */

#define CA_MASK_BLOCK_BYTES (32 * 1024)   /* L1-resident scratch budget */

enum { CA_MASK_SCAN_ANY, CA_MASK_SCAN_ALL, CA_MASK_SCAN_COUNT };

/* The block walk runs under ca_lazy_arena_protect: the transfer from a
   virtual mask can raise, and the arena must be left however it ends. */
typedef struct {
  boolean8_t *scratch;     /* first: released by ca_lazy_arena_release_held */
  CArray     *mask;
  int         op;
  ca_size_t   rows;
  ca_size_t   inner;
  ca_size_t  *native;
  ca_size_t   result;
} ca_mask_scan_t;

static VALUE
ca_mask_scan_virtual_body (VALUE arg)
{
  ca_mask_scan_t *sc   = (ca_mask_scan_t *) arg;
  CArray         *mask = sc->mask;
  int8_t          ndim = mask->ndim;
  ca_size_t       outer = mask->dim[0];
  ca_size_t       off;
  int8_t          k;

  sc->scratch = (boolean8_t *) ca_lazy_arena_acquire(sc->rows * sc->inner);

  for (off = 0; off < outer; off += sc->rows) {
    ca_size_t nrow = (outer - off < sc->rows) ? (outer - off) : sc->rows;
    ca_size_t n    = nrow * sc->inner;
    ca_size_t starts[CA_RANK_MAX] = {0};
    ca_size_t counts[CA_RANK_MAX];

    starts[0] = off;
    counts[0] = nrow;
    for (k = 1; k < ndim; k++) {
      counts[k] = mask->dim[k];
    }

    ca_xfer_stride(mask, starts, counts, sc->native, sc->scratch, CA_XFER_GET);

    if ( sc->op == CA_MASK_SCAN_ANY ) {
      if ( ca_mask_word_any(sc->scratch, n) )     { sc->result = 1; break; }
    }
    else if ( sc->op == CA_MASK_SCAN_ALL ) {
      if ( ! ca_mask_word_all_set(sc->scratch, n) ) { sc->result = 0; break; }
    }
    else {  /* CA_MASK_SCAN_COUNT — no early exit */
      sc->result += ca_mask_word_count(sc->scratch, n);
    }
  }
  return Qnil;
}

static ca_size_t
ca_mask_scan_virtual (CArray *mask, int op)
{
  int8_t         ndim  = mask->ndim;
  ca_size_t      outer = mask->dim[0];
  ca_size_t      inner = 1;
  ca_size_t      native[CA_RANK_MAX];
  ca_size_t      rows;
  ca_mask_scan_t sc;
  int8_t         k;

  for (k = 1; k < ndim; k++) {
    inner *= mask->dim[k];
  }

  /* compact row-major byte strides (boolean = 1 byte/cell); native[0] == inner
     so passing these as the destination layout writes each block contiguously
     into scratch as [nrow * inner] cells.  */
  {
    ca_size_t s = 1;
    for (k = ndim - 1; k >= 0; k--) { native[k] = s; s *= mask->dim[k]; }
  }

  rows = (inner > 0) ? (CA_MASK_BLOCK_BYTES / inner) : CA_MASK_BLOCK_BYTES;
  if ( rows < 1 )     rows = 1;
  if ( rows > outer ) rows = outer;

  sc.scratch = NULL;
  sc.mask    = mask;
  sc.op      = op;
  sc.rows    = rows;
  sc.inner   = inner;
  sc.native  = native;
  /* ALL is vacuously all-set until a non-set cell is found */
  sc.result  = ( op == CA_MASK_SCAN_ALL ) ? 1 : 0;

  ca_lazy_arena_protect(ca_mask_scan_virtual_body, ca_lazy_arena_release_held,
                        (VALUE) &sc);
  return sc.result;
}

boolean8_t *
ca_mask_ptr (void *ap)
{
  CArray *ca = (CArray*) ap;
  ca_update_mask(ca);
  return ( ca->mask ) ? (boolean8_t *) ca->mask->ptr : NULL;
}

int
ca_has_mask (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ca->mask ) {                /* mask array already created */
    return 1;
  }
  else if ( ca_test_flag(ca, CA_FLAG_VALUE_ARRAY) ) {
    /* Only this array's own mark, not ca_is_value_array, which walks to
       the root and would make every level of a view pay again for the
       levels above it.  A view below a value array still answers 0: it
       asks its parent, and the question reaches the marked array.  No
       level in between has a mask, since ca_create_mask refuses one for
       anything below a value array. */
    return 0;                     /* array itself is returned by CArray#value */
  }
  else if ( ca_is_entity(ca) ) {   /* entity array */
    return ( ca->mask != NULL ) ? 1 : 0;
  }
  else if ( ca_is_caobject(ca) ) { /* CAObject */
    CAObject *co = (CAObject *) ca;
    if ( ca_is_face(ca) ) {        /* Face: the mask follows the parent */
      if ( co->parent && ca_has_mask(co->parent) ) {
        ca_create_mask(ca);
        return 1;
      }
      return 0;
    }
    /* The one level that answers without asking its parent: a value
       array above it has to be looked for here. */
    if ( ca_is_value_array(ca) ) {
      return 0;
    }
    if ( rb_obj_respond_to(co->self, rb_intern("mask_created?"), Qtrue) ) {
      return RTEST(rb_funcall(co->self, rb_intern("mask_created?"), 0));
    }
    return ( ca->mask != NULL ) ? 1 : 0;
  }
  else if ( ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
    /* multi-parent view: masked iff ANY parent is (union of masked cells). */
    CAMultiParent *mp = (CAMultiParent *) ca;
    int32_t k;
    for ( k = 0; k < mp->n_parents; k++ ) {
      if ( ca_has_mask(mp->parents[k]) ) {
        ca_create_mask(ca);
        return 1;
      }
    }
    return 0;
  }
  else {
    CAView *cr = (CAView *) ca; /* view array, check parent array */
    if ( ca_has_mask(cr->parent) ) {
      ca_create_mask(ca);
      return 1;
    }
    else {
      return 0;
    }
  }
}

int
ca_is_any_masked (void *ap)
{
  CArray *ca = (CArray *) ap;
  int flag = 0;

  ca_update_mask(ca);
  if ( ca->mask ) {
    if ( ca_attach_is_alias(ca->mask) ) {
      /* cheap (entity / contiguous-alias) mask: O(1) alias attach +
         word-level any with early exit.  A sparse mask returns on the first
         non-zero word (the typical "all zero, no mask actually set" hot
         pattern).  An O(n) scan cache is not viable here: the mask is
         dynamic and a view chain can introduce a mask mid-chain. */
      ca_attach(ca->mask);   /* window: nothing raises inside */
      flag = ca_mask_word_any((boolean8_t *) ca->mask->ptr, ca->elements);
      ca_detach(ca->mask);
    }
    else {
      /* virtual mask (e.g. CAStackMask): block-loop the composed mask so it
         is never materialised whole, and short-circuit on the first masked
         block.  See ca_mask_scan_virtual. */
      flag = (int) ca_mask_scan_virtual(ca->mask, CA_MASK_SCAN_ANY);
    }
  }

  return flag;
}

int
ca_is_all_masked (void *ap)
{
  CArray *ca = (CArray *) ap;
  int flag = 0;

  ca_update_mask(ca);
  if ( ca->mask ) {
    if ( ca_attach_is_alias(ca->mask) ) {
      /* cheap mask: O(1) alias attach + word-level all_set with early exit.
         The word check uses (w == 0x0101...01ULL) under the {0,1}
         invariant; returns on the first non-fully-set word. */
      ca_attach(ca->mask);   /* window: nothing raises inside */
      flag = ca_mask_word_all_set((boolean8_t *) ca->mask->ptr, ca->elements);
      ca_detach(ca->mask);
    }
    else {
      /* virtual mask: block-loop + short-circuit on first non-fully-set block. */
      flag = (int) ca_mask_scan_virtual(ca->mask, CA_MASK_SCAN_ALL);
    }
  }

  return flag;
}

/* The create_mask slot of a view whose cells map one-to-one onto its
   parent's in address order (a cast, a byte swap, a Face over its storage):
   the mask is the parent's mask seen in the view's shape. */

void
ca_view_func_create_mask (void *ap)
{
  CAView *ca = (CAView *) ap;
  ca_create_mask(ca->parent);
  ca->mask = (CArray *) ca_refer_new(ca->parent->mask,
                                     CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

/* create mask array if array has mask but has not mask array */

void
ca_update_mask (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ( ! ca->mask ) && ca_has_mask(ca) ) {
    ca_create_mask(ca);
  }
}

static VALUE
ca_create_mask_attach (VALUE arg)
{
  ca_attach((CArray *) arg);   /* window: released by the view's detach */
  return Qnil;
}

CArray *
ca_mask_standin_new (CArray *parent)
{
  CArray *z = carray_new(CA_BOOLEAN, parent->ndim, parent->dim, 0, NULL);
  MEMZERO(z->ptr, boolean8_t, z->elements);
  if ( ca_is_readonly(parent) ) {
    ca_set_flag(z, CA_FLAG_READ_ONLY);
  }
  return z;
}

/* A value array or a mask array: a parent that can never be given a mask,
   whose stand-in therefore stays in place for good. */
static int
ca_mask_standin_parent_unmaskable (CArray *parent)
{
  return ca_is_value_array(parent) || ca_is_mask_array(parent);
}

CArray *
ca_mask_standin_current (CArray *mask_view, CArray *reading, CArray *parent,
                         CArray *standin)
{
  if ( standin == NULL || reading != standin
       || ca_mask_standin_parent_unmaskable(parent) ) {
    return reading;
  }
  /* Not inside an attach window whose buffer is out: that buffer and the
     detach to come are those of the stand-in.  The attach and allocate
     slots run before the buffer is published, and may still give way. */
  if ( CAVIEW(mask_view)->attach > 0 && mask_view->ptr != NULL ) {
    return reading;
  }
  /* A read-only parent (a lazy expression, a broadcast) is never given a
     mask by a write, but can still have one later through its operand or
     root. */
  if ( ! ca_has_mask(parent) ) {
    return reading;
  }
  ca_create_mask(parent);
  return ( parent->mask != NULL ) ? parent->mask : reading;
}

void
ca_mask_standin_settle (CArray *parent, CArray *standin)
{
  volatile VALUE holder = 0;
  boolean8_t    *z, one = 1;
  ca_size_t     *addrs;
  ca_size_t      i, m = 0, n;

  if ( standin == NULL || ca_test_flag(standin, CA_FLAG_READ_ONLY) ) {
    return;
  }
  z = (boolean8_t *) standin->ptr;
  n = standin->elements;
  for ( i = 0; i < n && ! z[i]; i++ ) ;
  if ( i == n ) {
    return;
  }
  if ( ca_mask_standin_parent_unmaskable(parent) ) {
    MEMZERO(z, boolean8_t, n);
    rb_raise(rb_eTypeError, "can not create mask array for the %s array",
             ca_is_value_array(parent) ? "value" : "mask");
  }
  /* The trues are added to the parent's mask, not copied over it: the
     parent may have come to have masked cells of its own meanwhile.  The
     stand-in is cleared before the parent is asked for a mask, so a
     parent that refuses one leaves it all false, as its readers take it
     to be at rest. */
  addrs = ALLOCV_N(ca_size_t, holder, n);
  for ( ; i < n; i++ ) {
    if ( z[i] ) {
      addrs[m++] = i;
    }
  }
  MEMZERO(z, boolean8_t, n);
  ca_create_mask(parent);
  ca_fill_addrs(parent->mask, m, addrs, &one);
  ALLOCV_END(holder);
}

CArray *
ca_multi_parent_mask (CArray *p, CArray **standin)
{
  *standin = NULL;
  if ( ! ca_has_mask(p) ) {
    *standin = ca_mask_standin_new(p);
    return *standin;
  }
  ca_create_mask(p);
  return p->mask;
}

void
ca_multi_parent_mask_refresh (CArray *mask, CArray **parents,
                              CArray **standins, int32_t n)
{
  CAMultiParent *mp = (CAMultiParent *) mask;
  int32_t k;
  if ( standins == NULL ) {
    return;
  }
  /* A replaced stand-in stays allocated until the view is freed: a copy
     of the mask (dup) may still point at it. */
  for ( k = 0; k < n; k++ ) {
    mp->parents[k] = ca_mask_standin_current(mask, mp->parents[k], parents[k],
                                             standins[k]);
  }
  CAVIEW(mask)->parent = mp->parents[0];
}

/* ---- A mask write through a view, checked as one write ----

   A view may hand one write to the mask of a stack or meld in several
   pieces (a grid, one call per index; a stack, one call per part).  The
   stack or meld checks a piece against blank masks before writing it, so a
   piece refused late would leave the pieces before it written.  The write
   is therefore checked once, where it enters at the outermost mask: it runs
   against blank masks in place of every real mask it can reach, and is
   refused if it put a true into the part of a stack or meld that can have
   no mask.  Writes nested inside a checked write are not checked again
   (the depth below). */

static rb_ractor_local_key_t ca_mask_write_depth_key;

static long
ca_mask_write_depth (void)
{
  VALUE v;
  if ( ca_mask_write_depth_key
       && rb_ractor_local_storage_value_lookup(ca_mask_write_depth_key, &v) ) {
    return FIX2LONG(v);
  }
  return 0;
}

static void
ca_mask_write_depth_add (long d)
{
  rb_ractor_local_storage_value_set(ca_mask_write_depth_key,
                                    LONG2FIX(ca_mask_write_depth() + d));
}

static int
ca_mask_parts (CArray *m, CArray ***parents, CArray ***standins, int32_t *n)
{
  return ca_stack_mask_parts(m, parents, standins, n)
      || ca_meld_mask_parts(m, parents, standins, n);
}

static int ca_mask_refusal_below (CArray *ca, int depth);

/* For a stack or meld holding data: its parents and their number. */
static int
ca_data_parts (CArray *ca, CArray ***parents, int32_t *n)
{
  return ca_stack_data_parts(ca, parents, n)
      || ca_meld_data_parts(ca, parents, n);
}

static CArray *
ca_data_like (CArray *like, CArray **parents)
{
  CArray **p;
  int32_t  n;
  return ca_stack_data_parts(like, &p, &n) ? ca_stack_like(like, parents)
                                           : ca_meld_like(like, parents);
}

/* True if a true written into the mask `ca` does not have yet, as its
   stand-in, can be refused: `ca` is a stack or meld with a part that can
   have no mask, there or further down. */
static int
ca_data_can_refuse (CArray *ca, int depth)
{
  CArray **parts;
  int32_t  n, k;
  if ( depth > 64 || ! ca_data_parts(ca, &parts, &n) ) {
    return 0;
  }
  for ( k = 0; k < n; k++ ) {
    CArray *q = parts[k];
    if ( ca_mask_standin_parent_unmaskable(q) ) {
      return 1;
    }
    if ( ca_has_mask(q) ) {
      if ( q->mask != NULL && ca_mask_refusal_below(q->mask, depth + 1) ) {
        return 1;
      }
    }
    else if ( ca_data_can_refuse(q, depth + 1) ) {
      return 1;
    }
  }
  return 0;
}

/* True if a write to `ca` can reach the part of a stack or meld mask that
   reads the stand-in of a parent which can have no mask, or of a stack or
   meld that can refuse one. */
static int
ca_mask_refusal_below (CArray *ca, int depth)
{
  CArray **parents, **standins;
  int32_t n, k;
  if ( ca == NULL || depth > 64 || ! ca_is_view(ca) ) {
    return 0;
  }
  if ( ca_mask_parts(ca, &parents, &standins, &n) ) {
    CAMultiParent *mp = (CAMultiParent *) ca;
    for ( k = 0; standins != NULL && k < n; k++ ) {
      if ( standins[k] != NULL && mp->parents[k] == standins[k]
           && ( ca_mask_standin_parent_unmaskable(parents[k])
                || ca_data_can_refuse(parents[k], depth + 1) ) ) {
        return 1;
      }
    }
    for ( k = 0; k < n; k++ ) {
      if ( ca_mask_refusal_below(mp->parents[k], depth + 1) ) {
        return 1;
      }
    }
    return 0;
  }
  if ( ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
    return 0;
  }
  return ca_mask_refusal_below(CAVIEW(ca)->parent, depth + 1);
}

int
ca_mask_write_needs_check (CArray *ca)
{
  return ca_mask_write_depth_key != 0
      && ca_is_view(ca)
      && ca_mask_write_depth() == 0
      && ca_is_mask_array(ca)
      && ca_mask_refusal_below(ca, 0);
}

/* What the trial put in place: part k of the stack or meld mask `mask`
   replaced (saved, to put back), and an array the trial made (owned, to
   free) -- a blank, or a stack or meld over blanks standing for a mask
   not made yet. */
typedef struct {
  CArray  *mask;
  int32_t  k;
  CArray  *saved;
  CArray  *owned;
  int      refusing;  /* owned is a blank, and a true in it refuses the write */
  int      value;     /* the refusing parent is a value array */
} ca_mask_trial_part_t;

typedef struct {
  CArray   *mask;
  ca_mask_trial_part_t *parts;
  int32_t   n, cap;
  VALUE   (*body)(VALUE);
  VALUE     arg;
} ca_mask_trial_t;

static ca_mask_trial_part_t *
ca_mask_trial_add (ca_mask_trial_t *t)
{
  ca_mask_trial_part_t *e;
  if ( t->n == t->cap ) {
    t->cap = t->cap ? 2 * t->cap : 8;
    REALLOC_N(t->parts, ca_mask_trial_part_t, t->cap);
  }
  e = &t->parts[t->n++];
  e->mask     = NULL;
  e->k        = 0;
  e->saved    = NULL;
  e->owned    = NULL;
  e->refusing = 0;
  e->value    = 0;
  return e;
}

/* An all-false boolean array shaped as `like`, owned by the trial. */
static CArray *
ca_mask_trial_blank (ca_mask_trial_t *t, CArray *like, int refusing)
{
  ca_mask_trial_part_t *e = ca_mask_trial_add(t);
  CArray *z;
  e->refusing = refusing;
  e->value    = ca_is_value_array(like);
  z = carray_new(CA_BOOLEAN, like->ndim, like->dim, 0, NULL);
  MEMZERO(z->ptr, boolean8_t, z->elements);
  t->parts[t->n - 1].owned = z;
  return z;
}

static void ca_mask_trial_put_aside (ca_mask_trial_t *t, CArray *ca, int depth);

/* For a stack or meld `ca` with no mask yet: what its mask would be, built
   over blanks (and over the parts' own masks, themselves put aside), so a
   true written into it lands in the part it would reach. */
static CArray *
ca_mask_trial_shadow (ca_mask_trial_t *t, CArray *ca, int depth)
{
  volatile VALUE holder = 0;
  CArray **parts, **shadows, *like;
  int32_t  n, k;
  ca_data_parts(ca, &parts, &n);
  shadows = ALLOCV_N(CArray *, holder, n);
  for ( k = 0; k < n; k++ ) {
    CArray *q = parts[k];
    if ( ca_mask_standin_parent_unmaskable(q) ) {
      shadows[k] = ca_mask_trial_blank(t, q, 1);
    }
    else if ( ca_has_mask(q) ) {
      ca_create_mask(q);
      if ( ca_mask_refusal_below(q->mask, depth + 1) ) {
        ca_mask_trial_put_aside(t, q->mask, depth + 1);
        shadows[k] = q->mask;
      }
      else {
        shadows[k] = ca_mask_trial_blank(t, q, 0);
      }
    }
    else if ( ca_data_can_refuse(q, depth + 1) ) {
      shadows[k] = ca_mask_trial_shadow(t, q, depth + 1);
    }
    else {
      shadows[k] = ca_mask_trial_blank(t, q, 0);
    }
  }
  like = ca_data_like(ca, shadows);
  ca_mask_trial_add(t)->owned = like;
  ALLOCV_END(holder);
  return like;
}

static void
ca_mask_trial_swap (ca_mask_trial_t *t, CArray *mask, int32_t k, CArray *with)
{
  CAMultiParent *mp = (CAMultiParent *) mask;
  ca_mask_trial_part_t *e = ca_mask_trial_add(t);
  e->mask  = mask;
  e->k     = k;
  e->saved = mp->parents[k];
  mp->parents[k] = with;
  if ( k == 0 ) {
    CAVIEW(mask)->parent = with;
  }
}

static void
ca_mask_trial_put_aside (ca_mask_trial_t *t, CArray *ca, int depth)
{
  CArray **parents, **standins;
  int32_t n, k;
  if ( ca == NULL || depth > 64 || ! ca_is_view(ca) ) {
    return;
  }
  if ( ca_mask_parts(ca, &parents, &standins, &n) ) {
    CAMultiParent *mp = (CAMultiParent *) ca;
    for ( k = 0; k < n; k++ ) {
      CArray *p = mp->parents[k];
      int standing_in = ( standins != NULL && standins[k] != NULL
                          && p == standins[k] );
      if ( ! standing_in ) {
        if ( ca_mask_refusal_below(p, depth + 1) ) {
          ca_mask_trial_put_aside(t, p, depth + 1);
        }
        else {
          ca_mask_trial_swap(t, ca, k, ca_mask_trial_blank(t, p, 0));
        }
      }
      else if ( ca_mask_standin_parent_unmaskable(parents[k]) ) {
        ca_mask_trial_swap(t, ca, k, ca_mask_trial_blank(t, p, 1));
      }
      else if ( ca_data_can_refuse(parents[k], depth + 1) ) {
        ca_mask_trial_swap(t, ca, k,
                           ca_mask_trial_shadow(t, parents[k], depth + 1));
      }
      else {
        ca_mask_trial_swap(t, ca, k, ca_mask_trial_blank(t, p, 0));
      }
    }
    return;
  }
  if ( ! ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
    ca_mask_trial_put_aside(t, CAVIEW(ca)->parent, depth + 1);
  }
}

static VALUE
ca_mask_trial_run (VALUE p)
{
  ca_mask_trial_t *t = (ca_mask_trial_t *) p;
  ca_mask_trial_put_aside(t, t->mask, 0);
  t->body(t->arg);
  return Qnil;
}

/* Put every part back, last first. */
static VALUE
ca_mask_trial_restore (VALUE p)
{
  ca_mask_trial_t *t = (ca_mask_trial_t *) p;
  int32_t i;
  for ( i = t->n - 1; i >= 0; i-- ) {
    ca_mask_trial_part_t *e = &t->parts[i];
    if ( e->mask == NULL ) {
      continue;
    }
    ((CAMultiParent *) e->mask)->parents[e->k] = e->saved;
    if ( e->k == 0 ) {
      CAVIEW(e->mask)->parent = e->saved;
    }
  }
  return Qnil;
}

static void
ca_mask_trial_free (ca_mask_trial_t *t)
{
  int32_t i;
  for ( i = t->n - 1; i >= 0; i-- ) {
    if ( t->parts[i].owned ) {
      ca_free(t->parts[i].owned);
    }
  }
  xfree(t->parts);
  t->parts = NULL;
}

static VALUE
ca_mask_write_trial_and_run (VALUE p)
{
  ca_mask_trial_t *t = (ca_mask_trial_t *) p;
  int32_t i;
  ca_size_t j;
  int refused = -1;
  rb_ensure(ca_mask_trial_run, p, ca_mask_trial_restore, p);
  for ( i = 0; i < t->n && refused < 0; i++ ) {
    CArray *z = t->parts[i].owned;
    if ( ! t->parts[i].refusing ) {
      continue;
    }
    for ( j = 0; j < z->elements && ! ((boolean8_t *) z->ptr)[j]; j++ ) ;
    if ( j < z->elements ) {
      refused = i;
    }
  }
  if ( refused >= 0 ) {
    rb_raise(rb_eTypeError, "%s: can not create mask array for the %s array",
             ca_calling_method_name(), t->parts[refused].value ? "value" : "mask");
  }
  t->body(t->arg);
  return Qnil;
}

static VALUE
ca_mask_write_check_done (VALUE p)
{
  ca_mask_trial_t *t = (ca_mask_trial_t *) p;
  ca_mask_trial_free(t);
  ca_mask_write_depth_add(-1);
  return Qnil;
}

void
ca_mask_write_checked (CArray *mask, VALUE (*body)(VALUE), VALUE arg)
{
  ca_mask_trial_t t;
  t.mask  = mask;
  t.parts = NULL;
  t.n     = 0;
  t.cap   = 0;
  t.body  = body;
  t.arg   = arg;
  ca_mask_write_depth_add(1);
  rb_ensure(ca_mask_write_trial_and_run, (VALUE) &t,
            ca_mask_write_check_done, (VALUE) &t);
}

typedef struct {
  CArray  *mask;
  CArray **blanks;
  CArray **saved;
  CArray  *saved_parent;
  int32_t  n;
  int      finished;
  VALUE  (*body)(VALUE);
  VALUE    arg;
} ca_mp_trial_t;

static VALUE
ca_mp_trial_body (VALUE p)
{
  ca_mp_trial_t *t = (ca_mp_trial_t *) p;
  t->body(t->arg);
  t->finished = 1;
  return Qnil;
}

static void
ca_mp_trial_free_blanks (ca_mp_trial_t *t)
{
  int32_t k;
  for ( k = 0; k < t->n; k++ ) {
    ca_free(t->blanks[k]);
    t->blanks[k] = NULL;
  }
}

static VALUE
ca_mp_trial_restore (VALUE p)
{
  ca_mp_trial_t *t = (ca_mp_trial_t *) p;
  CAMultiParent *mp = (CAMultiParent *) t->mask;
  int32_t k;
  for ( k = 0; k < t->n; k++ ) {
    mp->parents[k] = t->saved[k];
  }
  CAVIEW(t->mask)->parent = t->saved_parent;
  if ( ! t->finished ) {
    ca_mp_trial_free_blanks(t);
  }
  return Qnil;
}

void
ca_multi_parent_mask_refuse_first (CArray *mask, CArray **parents,
                                   CArray **standins, int32_t n,
                                   VALUE (*body)(VALUE), VALUE arg)
{
  CAMultiParent *mp = (CAMultiParent *) mask;
  volatile VALUE h_blank = 0, h_saved = 0;
  ca_mp_trial_t t;
  int32_t k, refused = -1;
  if ( standins == NULL || ca_mask_write_depth() > 0 ) {
    return;
  }
  for ( k = 0; k < n; k++ ) {
    if ( standins[k] != NULL && mp->parents[k] == standins[k]
         && ca_mask_standin_parent_unmaskable(parents[k]) ) {
      break;
    }
  }
  if ( k == n ) {
    return;
  }
  t.mask         = mask;
  t.n            = n;
  t.finished     = 0;
  t.body         = body;
  t.arg          = arg;
  t.saved_parent = CAVIEW(mask)->parent;
  t.blanks       = ALLOCV_N(CArray *, h_blank, n);
  t.saved        = ALLOCV_N(CArray *, h_saved, n);
  for ( k = 0; k < n; k++ ) {
    t.blanks[k] = NULL;
  }
  for ( k = 0; k < n; k++ ) {
    CArray *m = mp->parents[k];
    t.saved[k]  = m;
    t.blanks[k] = carray_new(CA_BOOLEAN, m->ndim, m->dim, 0, NULL);
    MEMZERO(t.blanks[k]->ptr, boolean8_t, t.blanks[k]->elements);
  }
  for ( k = 0; k < n; k++ ) {
    mp->parents[k] = t.blanks[k];
  }
  CAVIEW(mask)->parent = t.blanks[0];
  rb_ensure(ca_mp_trial_body, (VALUE) &t, ca_mp_trial_restore, (VALUE) &t);
  for ( k = 0; k < n && refused < 0; k++ ) {
    CArray    *z = t.blanks[k];
    ca_size_t  i;
    if ( standins[k] == NULL || t.saved[k] != standins[k]
         || ! ca_mask_standin_parent_unmaskable(parents[k]) ) {
      continue;
    }
    for ( i = 0; i < z->elements && ! ((boolean8_t *) z->ptr)[i]; i++ ) ;
    if ( i < z->elements ) {
      refused = k;
    }
  }
  ca_mp_trial_free_blanks(&t);
  ALLOCV_END(h_blank);
  ALLOCV_END(h_saved);
  if ( refused >= 0 ) {
    rb_raise(rb_eTypeError, "can not create mask array for the %s array",
             ca_is_value_array(parents[refused]) ? "value" : "mask");
  }
}

void
ca_multi_parent_mask_settle (CArray *mask, CArray **parents,
                             CArray **standins, int32_t n)
{
  CAMultiParent *mp = (CAMultiParent *) mask;
  int32_t k, pass;
  if ( standins == NULL ) {
    return;
  }
  /* The parts that can have no mask first, so that a refused true leaves
     the other parts as they were. */
  for ( pass = 0; pass < 2; pass++ ) {
    for ( k = 0; k < n; k++ ) {
      if ( standins[k] == NULL || mp->parents[k] != standins[k]
           || ca_mask_standin_parent_unmaskable(parents[k]) != ( pass == 0 ) ) {
        continue;
      }
      ca_mask_standin_settle(parents[k], standins[k]);
    }
  }
}

void
ca_create_mask (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ca->mask ) {
    return;
  }

  if ( ca_is_value_array(ca) ) {
    rb_raise(rb_eTypeError,
             "can not create mask array for the value array");
  }

  if ( ca_is_mask_array(ca) ) {
    rb_raise(rb_eTypeError,
             "can not create mask array for the mask array");
  }

  ca_func[ca->obj_type].create_mask(ca);
  if ( ! ca->mask ) {
    /* a lazy expression with no masked operand has no mask to make */
    return;
  }
  ca_set_flag(ca->mask, CA_FLAG_MASK_ARRAY); /* set array as mask array */
  if ( ca_is_view(ca) ) {
    if ( CAVIEW(ca)->attach ) {
      /* The new mask joins its view's level.  Its attach reads the
         parent's mask, which can raise (a Ruby-backed parent); the mask
         then comes off again, since the view's sync and detach would
         find it attached to nothing. */
      int tag = 0;
      /* protect: the mask comes off its view before it is freed */
      rb_protect(ca_create_mask_attach, (VALUE) ca->mask, &tag);
      if ( tag ) {
        CArray *mask = ca->mask;
        ca->mask = NULL;
        ca_free(mask);
        rb_jump_tag(tag);
      }
      if ( ca_is_view(ca->mask) ) {
        CAVIEW(ca->mask)->attach = CAVIEW(ca)->attach;
      }
    }
  }
}

void
ca_clear_mask (void *ap)
{
  CArray *ca = (CArray *) ap;

  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }
}

typedef struct {
  CArray *ca;
  CArray *mask;
} ca_setup_mask_t;

/* Pushing the cells into ca's mask can raise (a CAObject's mask hooks). */
static VALUE
ca_setup_mask_body (VALUE arg)
{
  ca_setup_mask_t *c = (ca_setup_mask_t *) arg;
  ca_sync_data(c->ca->mask, c->mask->ptr);
  return Qnil;
}

void
ca_setup_mask (void *ap, CArray *mask)
{
  CArray *ca = (CArray *) ap;

  if ( mask ) {
    if ( ! ca_is_boolean_type(mask) ) {
      rb_raise(rb_eCADataTypeError, "a mask is a boolean array");
    }
    ca_check_same_elements(ca, mask);
  }

  ca_update_mask(ca);

  if ( mask ) {
    ca_setup_mask_t c;
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    c.ca   = ca;
    c.mask = mask;
    ca_attach_window(1, &c.mask, "r", ca_setup_mask_body, (VALUE) &c);
  }
  else if ( ca->mask ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }
}

/*
  ca_copy_mask_overlay_n (void *ap, ca_size_t elements, int n, CArray **slist)

  + slist[i] can be NULL (simply skipped)

 */

/* The overlay reads each source's mask into the destination's.  A
   source's mask can be made or read by calling Ruby (a CAObject's mask
   hooks) and raise, so every mask is made first and the lot are read
   inside one attach window.

   A source whose cells live in the destination's root has its mask read
   into a snapshot before the destination's mask is made, cleared or
   written: the destination's mask may be that same memory, and the word
   OR would otherwise read bytes it has already set. */
typedef struct {
  CArray     **list;      /* [0] the destination mask, then the attached sources' */
  boolean8_t **snap;      /* per source: its mask read in advance, or NULL */
  CArray     **att;       /* per source: its attached mask when not snapped */
  char        *scalar;    /* per source: the source is a scalar */
  int          k;         /* entries in list */
  int          ns;        /* sources */
  ca_size_t    elements;
} ca_mask_overlay_t;

static VALUE
ca_mask_overlay_body (VALUE arg)
{
  ca_mask_overlay_t *o = (ca_mask_overlay_t *) arg;
  boolean8_t *ma = (boolean8_t *) o->list[0]->ptr;
  int i;
  for (i=0; i<o->ns; i++) {
    boolean8_t *ms = o->snap[i] ? o->snap[i] : (boolean8_t *) o->att[i]->ptr;
    /* scalar masked source -> broadcast to all (memset); array source
       -> pure word OR (ca_mask_word_or).  A defensive `if (*ms)` is
       unnecessary: under the {0,1} invariant, `*ma |= *ms` equals
       `if (*ms) *ma = 1`.  Post-condition: the mask byte stays in {0,1}. */
    if ( o->scalar[i] ) {
      if ( *ms ) {
        memset(ma, 1, o->elements);
      }
    }
    else {
      ca_mask_word_or(ma, ms, o->elements);
    }
  }
  return Qnil;
}

/* overwrite: the destination's mask is cleared before the sources are
   OR'd in (and left alone when it has none and no source has a mask). */
static void
ca_copy_mask_overlay_core (CArray *ca, ca_size_t elements, int n,
                           CArray **slist, int overwrite)
{
  CArray *cs;
  ca_mask_overlay_t o;
  volatile VALUE *holders;
  char *modes;
  int i, some_has_mask = 0;

  if ( elements > ca->elements ) {
    elements = ca->elements;
  }

  /* An array source is read cell by cell over the destination's cells;
     a scalar source's one cell applies to all of them. */
  for (i=0; i<n; i++) {
    cs = slist[i];
    if ( cs && ! ca_is_scalar(cs) && cs->elements < elements ) {
      rb_raise(rb_eArgError,
               "mask source has %lld elements, fewer than the %lld of the destination",
               (long long) cs->elements, (long long) elements);
    }
  }

  for (i=0; i<n; i++) {
    if ( slist[i] && ca_has_mask(slist[i]) ) {
      some_has_mask = 1;
      break;
    }
  }

  if ( ! some_has_mask ) {
    if ( overwrite ) {
      ca_update_mask(ca);
      if ( ca->mask ) {
        boolean8_t zero = 0;
        ca_fill(ca->mask, &zero);
      }
    }
    return;
  }

  o.list     = ALLOCA_N(CArray *, n + 1);
  o.snap     = ALLOCA_N(boolean8_t *, n);
  o.att      = ALLOCA_N(CArray *, n);
  o.scalar   = ALLOCA_N(char, n);
  holders    = ALLOCA_N(VALUE, n);
  modes      = ALLOCA_N(char, n + 2);
  o.elements = elements;
  o.ns       = 0;
  for (i=0; i<n; i++) {
    holders[i] = 0;
  }
  ca_update_mask(ca);

  /* Every source mask is made, and those in the destination's root are
     read, before the destination's mask is touched. */
  for (i=0; i<n; i++) {
    cs = slist[i];
    if ( ! cs ) {
      continue;
    }
    ca_update_mask(cs);
    if ( ! cs->mask ) {
      continue;
    }
    o.scalar[o.ns] = (char) ca_is_scalar(cs);
    o.att[o.ns]    = NULL;
    o.snap[o.ns]   = NULL;
    if ( ca_shares_root(cs, ca) || ca_shares_root(cs->mask, ca) ||
         ( ca->mask && ca_shares_root(cs->mask, ca->mask) ) ) {
      o.snap[o.ns] = ALLOCV_N(boolean8_t, holders[o.ns], cs->mask->elements);
      ca_xfer_all(cs->mask, (char *) o.snap[o.ns], CA_XFER_GET);
    }
    else {
      o.att[o.ns] = cs->mask;
    }
    o.ns++;
  }

  ca_create_mask(ca);
  if ( overwrite ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }

  o.k = 0;
  o.list[o.k]  = ca->mask;
  modes[o.k++] = 'w';
  for (i=0; i<o.ns; i++) {
    if ( o.att[i] ) {
      o.list[o.k]  = o.att[i];
      modes[o.k++] = 'r';
    }
  }
  modes[o.k] = '\0';
  ca_attach_window(o.k, o.list, modes, ca_mask_overlay_body, (VALUE) &o);

  for (i=0; i<n; i++) {
    if ( holders[i] ) {
      ALLOCV_END(holders[i]);
    }
  }
}

void
ca_copy_mask_overlay_n (void *ap, ca_size_t elements, int n, CArray **slist)
{
  ca_copy_mask_overlay_core((CArray *) ap, elements, n, slist, 0);
}

void
ca_copy_mask_overlay (void *ap, ca_size_t elements, int n, ...)
{
  CArray *ca = (CArray *) ap;
  CArray **slist;
  volatile VALUE holder;
  va_list args;
  int i;

  slist = ALLOCV_N(CArray *, holder, n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray *);
  }
  va_end(args);

  ca_copy_mask_overlay_core(ca, elements, n, slist, 0);

  ALLOCV_END(holder);
}

void
ca_copy_mask_overwrite_n (void *ap, ca_size_t elements, int n, CArray **slist)
{
  ca_copy_mask_overlay_core((CArray *) ap, elements, n, slist, 1);
}

void
ca_copy_mask_overwrite (void *ap, ca_size_t elements, int n, ...)
{
  CArray *ca = (CArray *) ap;
  CArray **slist;
  volatile VALUE holder;
  va_list args;
  int i;

  slist = ALLOCV_N(CArray *, holder, n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray*);
  }
  va_end(args);

  ca_copy_mask_overlay_core(ca, elements, n, slist, 1);

  ALLOCV_END(holder);
}

void
ca_copy_mask (void *ap, void *ao)
{
  CArray *ca = (CArray *) ap;
  CArray *co = (CArray *) ao;
  ca_check_same_elements(ca, co);
  ca_copy_mask_overlay(ca, ca->elements, 1, co);
}

ca_size_t
ca_count_masked (void *ap)
{
  CArray *ca = (CArray *) ap;
  boolean8_t *m;
  ca_size_t count = 0;

  ca_update_mask(ca);

  if ( ca->mask ) {
    if ( ca_attach_is_alias(ca->mask) ) {
      /* cheap mask: O(1) alias attach + word-bulk count. */
      ca_attach(ca->mask);   /* window: nothing raises inside */
      m = (boolean8_t *) ca->mask->ptr;
      count = ca_mask_word_count(m, ca->elements);
      ca_detach(ca->mask);
    }
    else {
      /* virtual mask: block-loop the composed mask (peak O(block), no full
         materialise).  COUNT has no early exit but still avoids O(n) peak. */
      count = ca_mask_scan_virtual(ca->mask, CA_MASK_SCAN_COUNT);
    }
  }

  return count;
}

ca_size_t
ca_count_not_masked (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ca->elements - ca_count_masked(ca);
}

/* Scalar-fill every masked cell with fill_value, then clear its mask bit.
   This depends only on the cell BYTE WIDTH, not the data type (the work is
   a width-sized copy), so a single width switch covers every numeric /
   complex / object data type; the default arm handles fixlen and any other
   width via memcpy.  The typed arms let the compiler emit a plain store.  */
#define proc_fill_bang_width(T)                 \
  {                                             \
    ca_size_t i;                                \
    T *p = (T *)ca->ptr;                        \
    T  v = *(T *)fill_value;                    \
    boolean8_t *m = (boolean8_t *) ca->mask->ptr; \
    for (i=0; i<ca->elements; i++) {            \
      if ( *m ) { *p = v; *m = 0; }             \
      m++; p++;                                 \
    }                                           \
  }

#define proc_fill_bang_bytes()                  \
  {                                             \
    ca_size_t i;                                \
    char *p = ca->ptr;                          \
    boolean8_t *m = (boolean8_t *) ca->mask->ptr; \
    for (i=0; i<ca->elements; i++) {            \
      if ( *m ) { memcpy(p, fill_value, ca->bytes); *m = 0; } \
      m++; p+=ca->bytes;                        \
    }                                           \
  }

void
ca_unmask (void *ap, char *fill_value)
{
  CArray *ca = (CArray *) ap;

  if ( ca_is_readonly(ca) ) {
    ca_refuse_read_only();
  }

  ca_update_mask(ca);
  if ( ca->mask ) {
    if ( ! fill_value ) {
      boolean8_t zero = 0;
      ca_fill(ca->mask, &zero);
    }
    else {
      ca_attach(ca);   /* window: nothing raises inside */

      switch ( ca->bytes ) {
      case 1:  proc_fill_bang_width(uint8_t);  break;
      case 2:  proc_fill_bang_width(uint16_t); break;
      case 4:  proc_fill_bang_width(uint32_t); break;
      case 8:  proc_fill_bang_width(uint64_t); break;
      default: proc_fill_bang_bytes();         break;  /* cmplx128 (16) + fixlen */
      }

      ca_sync_detach(ca);
    }
  }
}

typedef struct {
  CArray *ca;
  CArray *co;
  char   *fill_value;
} ca_unmask_copy_args_t;

static VALUE
ca_unmask_copy_fill (VALUE arg)
{
  ca_unmask_copy_args_t *a = (ca_unmask_copy_args_t *) arg;
  CArray *ca = a->ca, *co = a->co;
  char *q;
  boolean8_t *m;
  ca_size_t i;

  ca_copy_data(ca, co->ptr);

  /* Only the mask is needed now that the values are in co, so read the
     mask alone rather than producing the view's cells a second time. */
  if ( a->fill_value && ca_has_mask(ca) ) {
    volatile VALUE holder = 0;
    ca_update_mask(ca);
    m = ALLOCV_N(boolean8_t, holder, ca->elements);
    ca_copy_data(ca->mask, (char *) m);
    q = co->ptr;
    for (i=0; i<ca->elements; i++) {
      if ( m[i] ) {
        memcpy(q, a->fill_value, ca->bytes);
      }
      q+=co->bytes;
    }
    ALLOCV_END(holder);
  }
  return Qnil;
}

CArray *
ca_unmask_copy (void *ap, char *fill_value)
{
  ca_unmask_copy_args_t a;
  a.ca         = (CArray *) ap;
  a.co         = ca_template(a.ca);
  a.fill_value = fill_value;
  ca_fill_or_free(a.co, ca_unmask_copy_fill, (VALUE) &a);
  return a.co;
}

void
ca_invert_mask (void *ap)
{
  CArray *ca = (CArray *) ap;
  boolean8_t *m;

  ca_create_mask(ca);

  ca_attach(ca->mask);   /* window: nothing raises inside */
  m = (boolean8_t *) ca->mask->ptr;
  ca_mask_word_not(m, m, ca->elements);   /* in-place 1 - m, LSB-XOR word loop */
  ca_sync_detach(ca->mask);

  return;
}

boolean8_t *
ca_allocate_mask_iterator_n (int n, CArray **slist)
{
  boolean8_t *m, *mp, *ms;
  CArray *cs, **masks;
  char *scalar;
  ca_size_t j, elements = -1;
  int i, k = 0, some_has_mask = 0;

  for (i=0; i<n; i++) {
    if ( slist[i] ) {
      if ( ca_has_mask(slist[i]) ) {
        some_has_mask = 1;
      }

      if ( elements >= 0 ) {
        if ( elements != slist[i]->elements ) {
          if ( elements == 1 ) {
            elements = slist[i]->elements;
          }
          else if ( ! ca_is_scalar(slist[i]) ) {
            rb_raise(rb_eArgError,
                     "# of elements is different among the given arrays");
          }
        }
      }
      else {
        elements = slist[i]->elements;
      }
    }
  }

  /* elements stays at its -1 sentinel only when no non-NULL array was given
     (degenerate call); guard so the alloc/memset never see a negative size
     (which would wrap to a huge bound).  Also silences GCC's VRP warnings. */
  if ( elements < 0 ) elements = 0;

  if ( ! some_has_mask ) {
    m = xmalloc(sizeof(boolean8_t)*elements);
    memset(m, 0, elements);
    return m;
  }

  /* The sources' masks, made and attached before the result is allocated:
     making or reading one can call Ruby (a CAObject's mask hooks) and
     raise, and then nothing is left attached or allocated. */
  masks  = ALLOCA_N(CArray *, n);
  scalar = ALLOCA_N(char, n);
  for (i=0; i<n; i++) {
    cs = slist[i];
    if ( ! cs ) {
      continue;
    }
    ca_update_mask(cs);
    if ( ! cs->mask ) {
      continue;
    }
    masks[k]    = cs->mask;
    scalar[k++] = (char) ca_is_scalar(cs);
  }
  ca_attach_all(masks, k);   /* window: nothing raises inside */

  m = xmalloc(sizeof(boolean8_t)*elements);
  memset(m, 0, elements);
  for (i=0; i<k; i++) {
    ms = (boolean8_t *) masks[i]->ptr;
    mp = m;
    if ( scalar[i] ) {
      if ( *ms ) {
        for (j=0; j<elements; j++) {
          *mp = 1;
          mp++;
        }
      }
    }
    else {
      ca_mask_word_or(mp, ms, elements);   /* m[j] |= ms[j], word-bulk OR */
    }
  }
  while ( k > 0 ) {
    ca_detach(masks[--k]);
  }
  return m;
}

boolean8_t *
ca_allocate_mask_iterator (int n, ...)
{
  boolean8_t *m;
  CArray **slist;
  volatile VALUE holder;
  va_list args;
  int i;

  slist = ALLOCV_N(CArray *, holder, n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray *);
  }
  va_end(args);

  m = ca_allocate_mask_iterator_n(n, slist);

  ALLOCV_END(holder);

  return m;
}

/* ------------------------------------------------------------------- */

/* @overload has_mask?

(Masking, Inquiry) 
Returns true if self has the mask array.
*/

VALUE
rb_ca_has_mask (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_has_mask(ca) ) ? Qtrue : Qfalse;
}

/* @overload any_masked?

(Masking, Inquiry) 
Returns true if self has at least one masked element.
*/

VALUE
rb_ca_is_any_masked (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_any_masked(ca) ) ? Qtrue : Qfalse;
}

/* @overload all_masked?

(Masking, Inquiry) 
Returns true if all elements of self are masked.
*/

VALUE
rb_ca_is_all_masked (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_all_masked(ca) ) ? Qtrue : Qfalse;
}

/* @overload create_mask

(Masking) 
Creates mask array internally (private method)
*/

static VALUE
rb_ca_create_mask (VALUE self)
{
  CArray *ca;
  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_create_mask(ca);
  return Qnil;
}

/* @overload update_mask

(Masking) 
Update mask array internally (private method)
*/

/*
static VALUE
rb_ca_update_mask (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_update_mask(ca);
  return Qnil;
}
*/

/* @overload value

(Masking, Inquiry) 
Returns new array which refers the data of <code>self</code>.
The data of masked elements of <code>self</code> can be accessed
via the returned array. The value array can't be set mask.
*/

VALUE
rb_ca_value_array (VALUE self)
{
  VALUE obj;
  CArray *ca, *co;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  obj = rb_ca_refer_new(self, ca->data_type, ca->ndim, ca->dim, ca->bytes, 0);

  TypedData_Get_Struct(obj, CArray, &carray_data_type, co);

  /* Value arrays ignore the mask by definition.  ca_stride_setup
     auto-propagates the parent's mask into newly-built CAStride
     subclasses; strip it here so ca_has_mask(value_array) stays
     false. */
  if (co->mask) {
    ca_free(co->mask);
    co->mask = NULL;
  }
  ca_set_flag(co, CA_FLAG_VALUE_ARRAY);

  /* CAREFUL: when self is a Face, rb_ca_refer_new has already lifted its
     result, so `co` above is the Face wrapper and the refer that actually
     carries the data sits underneath it.  Marking only the wrapper is not
     enough: kernels strip Faces at entry (ca_strip_face) and would go on
     to ask that refer for a mask, which -- having none of its own -- it
     answers from its parent.  The values would read back raw while a
     reduction over them still skipped the masked cells.

     Marking the storage level is enough for anything stacked in between,
     since ca_is_value_array inherits from parent to child. */
  if ( ca_is_face(co) ) {
    CArray *storage = ca_strip_face(co);
    if ( storage ) {
      if ( storage->mask ) {
        ca_free(storage->mask);
        storage->mask = NULL;
      }
      ca_set_flag(storage, CA_FLAG_VALUE_ARRAY);
    }
  }

  CA_FACE_LIFT_IF_FACE(obj, self, ca);
  return obj;
}

/* @overload mask

(Masking, Inquiry) 
Returns new array which refers the mask state of <code>self</code>.
The mask array can't be set mask.
*/

VALUE
rb_ca_mask_array (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  ca_update_mask(ca);
  if ( ca->mask ) {
    /* The mask is reached from its array, not through a parent link, so
       ca_is_readonly on the mask never sees the array's read-only state.
       Pass it on here, where the mask is handed out. */
    if ( ca_is_readonly(ca) ) {
      ca_set_flag(ca->mask, CA_FLAG_READ_ONLY);
    }
    obj = TypedData_Wrap_Struct(ca_mask_class[ca->obj_type],
                                ca_mask_typeddata[ca->obj_type], ca->mask);
    rb_ivar_set(obj, rb_intern("masked_array"), self);
    return obj;
  }
  else {
    return INT2NUM(0);
  }
}

/* dup / clone of a mask.  The mask of a view is a view over its parent's
   mask, and its dup, like the dup of any view, is another view onto the
   same parent mask: it follows later changes and a write to it lands in
   the parent's mask (copy makes a mask of its own).  A mask over a cast, a
   byte swap, a Face or a lazy expression is shown as CArrayMask, whose
   allocator makes an entity, so Object#dup would copy its cells; it is
   rebuilt here from its own view instead.  The mask of an entity is an
   entity and is copied. */
static VALUE
ca_mask_view_dup (VALUE self)
{
  volatile VALUE obj;
  const rb_data_type_t *type;
  CArray *ca, *cp;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  cp = (CArray *) ca_func[ca->obj_type].clone(ca);
  ca_keep_chain_flags(cp, ca);
  type = ca_typeddata[ca->obj_type];
  if ( type->function.dfree != ca_free ) {
    type = &carray_data_type;     /* the copy is this object's to free */
  }
  obj = TypedData_Wrap_Struct(rb_obj_class(self), type, cp);
  rb_ivar_set(obj, rb_intern("masked_array"),
              rb_ivar_get(self, rb_intern("masked_array")));
  return obj;
}

static VALUE
rb_ca_mask_dup (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ! ca_is_view(ca) ) {
    return rb_call_super(0, NULL);
  }
  return ca_mask_view_dup(self);
}

static VALUE
rb_ca_mask_clone (int argc, VALUE *argv, VALUE self)
{
  VALUE opts = Qnil, vfreeze = Qnil;
  volatile VALUE obj;
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ! ca_is_view(ca) ) {
    return rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
  }
  rb_scan_args(argc, argv, "0:", &opts);
  if ( ! NIL_P(opts) ) {
    /* rb_get_kwargs refuses any key but freeze:, as Kernel#clone does. */
    ID kw[1];
    VALUE val[1];
    kw[0] = rb_intern("freeze");
    rb_get_kwargs(opts, kw, 0, 1, val);
    if ( val[0] != Qundef ) {
      vfreeze = val[0];
    }
  }
  obj = ca_mask_view_dup(self);
  if ( RTEST(vfreeze) || ( NIL_P(vfreeze) && OBJ_FROZEN(self) ) ) {
    rb_obj_freeze(obj);
  }
  return obj;
}

/* @overload mask= (new_mask)

(Mask, Modification) 
Asigns <code>new_mask</code> to the mask array of <code>self</code>.
If <code>self</code> doesn't have a mask array, it will be created
before asignment.
*/    

VALUE
rb_ca_set_mask (VALUE self, VALUE rval)
{
  volatile VALUE rmask = rval;
  CArray *ca, *cv;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_value_array(ca) ) {
    rb_raise(rb_eTypeError,
             "can not create mask for the value array");
  }

  if ( ca_is_mask_array(ca) ) {
    rb_raise(rb_eTypeError,
             "can not create mask for the mask array");
  }

  if ( TYPE(rmask) == T_ARRAY ) {
    /* Flattened as a store into a boolean array of this shape flattens
       it, and then taken as a 1-D boolean array (UNDEF becomes a masked
       cell, as in any boolean array made from it). */
    CArray shape = *ca;
    shape.data_type = CA_BOOLEAN;
    shape.bytes     = ca_sizeof[CA_BOOLEAN];
    rmask = rb_ary_flatten_for_elements(rmask, ca->elements, &shape);
    if ( NIL_P(rmask) ) {
      rb_raise(rb_eArgError, "failed to guess data size of given array");
    }
    rmask = rb_ca_wrap_readonly(rmask, INT2NUM(CA_BOOLEAN));
  }

  if ( rb_obj_is_carray(rmask) ) {
    /* The array owns the shape, as in a store: the new mask agrees with
       it, is 1-D or squeezes to it, or broadcasts along size-1 axes.
       Checked before the mask exists, so a refused one leaves none. */
    ca_broadcast_to_destination(self, &rmask);
    TypedData_Get_Struct(rmask, CArray, &carray_data_type, cv);
    /* A new mask taken from self's own root, or from self's mask, is
       read from a copy: making and writing self's mask would change it
       before it is read. */
    ca_update_mask(ca);
    if ( ca_shares_root(cv, ca) ||
         ( ca->mask && ca_shares_root(cv, ca->mask) ) ) {
      rmask = rb_ca_copy(rmask);
      TypedData_Get_Struct(rmask, CArray, &carray_data_type, cv);
    }
    if ( ! ca_is_boolean_type(cv) ) {
      cv = ca_wrap_readonly(rmask, CA_BOOLEAN);
    }
    ca_create_mask(ca);
    ca_setup_mask(ca, cv);
    ca_copy_mask_overlay(ca, ca->elements, 1, cv);
    return rval;
  }
  else {
    ca_create_mask(ca);
    return rb_ca_store_all(rb_ca_mask_array(self), rmask);
  }
}

/* @overload is_masked

(Masking, Element-Wise Inquiry) 
Returns new boolean type array of same shape 
with <code>self</code>. The returned array has 1 for the masked elements and
0 for not-masked elements.
*/

VALUE
rb_ca_is_masked (VALUE self)
{
  volatile VALUE out;
  CArray *ca, *co;
  boolean8_t zero = 0;
  boolean8_t *p;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_scalar(ca) ) {
    co = (CArray *)cscalar_new(CA_BOOLEAN, ca->bytes, NULL);
  }
  else {
    co = carray_new(CA_BOOLEAN, ca->ndim, ca->dim, ca->bytes, NULL);
  }
  out = ca_wrap_struct(co);   /* owned by Ruby before anything can raise */

  ca_update_mask(ca);
  if ( ! ca->mask ) {
    ca_fill(co, &zero);
  }
  else {
    /* Copied straight into the result, then normalised in place. */
    ca_copy_data(ca->mask, co->ptr);
    p = (boolean8_t *) co->ptr;
    for (i=0; i<ca->elements; i++) {
      p[i] = ( p[i] ) ? 1 : 0;
    }
  }

  return out;
}

/* @overload is_not_masked

(Masking, Element-Wise Inquiry) 
Returns new boolean type array of same shape with <code>self</code>.
The returned array has 0 for the masked elements and
1 for not-masked elements.
*/

VALUE
rb_ca_is_not_masked (VALUE self)
{
  volatile VALUE out;
  CArray *ca, *co;
  boolean8_t one = 1;
  boolean8_t *p;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_scalar(ca) ) {
    co = (CArray *)cscalar_new(CA_BOOLEAN, ca->bytes, NULL);
  }
  else {
    co = carray_new(CA_BOOLEAN, ca->ndim, ca->dim, ca->bytes, NULL);
  }
  out = ca_wrap_struct(co);   /* owned by Ruby before anything can raise */

  ca_update_mask(ca);
  if ( ! ca->mask ) {
    ca_fill(co, &one);
  }
  else {
    /* Copied straight into the result, then normalised in place. */
    ca_copy_data(ca->mask, co->ptr);
    p = (boolean8_t *) co->ptr;
    for (i=0; i<ca->elements; i++) {
      p[i] = ( p[i] ) ? 0 : 1;
    }
  }

  return out;
}

VALUE
rb_ca_scan_mask_count (VALUE self, VALUE axis)
{
  VALUE present = rb_funcall(self, rb_intern("is_not_masked"), 0);
  VALUE count;
  if ( NIL_P(axis) ) {
    count = rb_funcall(present, rb_intern("cumsum"), 0);
  }
  else {
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(rb_intern("axis")), axis);
    count = rb_funcallv_kw(present, rb_intern("cumsum"), 1, &kw, RB_PASS_KEYWORDS);
  }
  return rb_funcall(count, rb_intern("to_type"), 1, INT2NUM(CA_INT64));
}

/* @overload unmask (fill_value = nil)

(Masking, Destructive)
Unmask all elements of the object.
If the optional argument <code>fill_value</code> is given,
the masked elements are filled by <code>fill_value</code>.
The returned array doesn't have the mask array.
*/

static VALUE
rb_ca_unmask_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rfval = CA_UNSPECIFIED, rcs;
  CArray *ca;
  CScalar *cv;
  char *fval = NULL;

  rb_ca_modify(self);

  if ( argc >= 1 ) {
    rfval = argv[0];
  }

  /* Filling with UNDEF leaves the cells undefined, as storing UNDEF does. */
  if ( rfval == CA_UNDEF ) {
    return self;
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( rfval != CA_UNSPECIFIED ) {
    /* The fill is a value of the array (a struct, an instant for a Face):
       rb_ca_obj2ptr writes it as one cell of the storage. */
    rcs = rb_cscalar_new(ca_strip_face(ca)->data_type, ca->bytes, NULL);
    TypedData_Get_Struct(rcs, CScalar, &cscalar_data_type, cv);
    fval = cv->ptr;
    rb_ca_obj2ptr(self, rfval, fval);
  }

  ca_unmask(ca, fval);

  return self;
}

/* api: rb_ca_unmask */

VALUE
rb_ca_unmask (VALUE self)
{
  return rb_ca_unmask_method(0, NULL, self);
}

/* api: rb_ca_mask_fill */

VALUE
rb_ca_mask_fill (VALUE self, VALUE fval)
{
  return rb_ca_unmask_method(1, &fval, self);
}

/* A copy without the mask: with a fill value, the masked cells hold it.
   Behind rb_ca_unmask_copy / rb_ca_mask_fill_copy (C only; the Ruby
   surface is strip_mask). */

static VALUE
rb_ca_unmask_copy_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rfval = CA_UNSPECIFIED, rcs;
  CArray *ca, *co;
  CScalar *cv;
  char *fval = NULL;

  if ( argc >= 1 ) {
    rfval = argv[0];
  }

  /* Filling with UNDEF leaves the cells undefined, as storing UNDEF does:
     the copy keeps the mask. */
  if ( rfval == CA_UNDEF ) {
    return rb_ca_copy(self);
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( rfval != CA_UNSPECIFIED ) {
    /* The fill is a value of the array (a struct, an instant for a Face):
       rb_ca_obj2ptr writes it as one cell of the storage. */
    rcs = rb_cscalar_new(ca_strip_face(ca)->data_type, ca->bytes, NULL);
    TypedData_Get_Struct(rcs, CScalar, &cscalar_data_type, cv);
    fval = cv->ptr;
    rb_ca_obj2ptr(self, rfval, fval);
  }

  co = ca_unmask_copy(ca, fval);
  obj = ca_wrap_struct(co);
  CA_FACE_LIFT_IF_FACE(obj, self, ca);
  return obj;
}

/* api: rb_ca_unmask_copy */

VALUE
rb_ca_unmask_copy (VALUE self)
{
  return rb_ca_unmask_copy_method(0, NULL, self);
}

/* api: rb_ca_mask_fill_copy */

VALUE
rb_ca_mask_fill_copy (VALUE self, VALUE fval)
{
  return rb_ca_unmask_copy_method(1, &fval, self);
}

/* @overload invert_mask

(Masking, Destructive)
Inverts mask state.
*/

VALUE
rb_ca_invert_mask (VALUE self)
{
  CArray *ca;
  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_invert_mask(ca);
  return self;
}

/* guard_undef(*values, fill_value: UNDEF, &block) — class method.
   Returns fill_value if any of values is UNDEF, otherwise yields values
   to the block and returns its result.
   See lib/carray/mask.rb (removed in CIFY). */
static VALUE
rb_ca_s_guard_undef(int argc, VALUE *argv, VALUE klass)
{
  VALUE values, opts;
  VALUE fill_value = CA_UNDEF;
  long i, n;

  rb_scan_args(argc, argv, "*:", &values, &opts);
  rb_scan_options(opts, "fill_value", &fill_value);

  n = RARRAY_LEN(values);
  for (i = 0; i < n; i++) {
    if (RARRAY_AREF(values, i) == CA_UNDEF) {
      return fill_value;
    }
  }

  return rb_yield_splat(values);
}

/* mask_eq(v) — return form of "mask cells equal to v".
   Equivalent to: obj = copy; obj[:eq, v] = UNDEF; obj */
/* Masks a copy of self at the cells the store key `argv` selects.  A
   read-only Face (CAConstString, CACategorical) copies read-only, so the
   mask goes on a copy of its storage and the Face is put back; a predicate
   key (`:eq, v`) is evaluated on the Face, where it compares values rather
   than storage. */
static VALUE
ca_mask_copy_where (VALUE self, int argc, VALUE *argv)
{
  CArray *ca;
  volatile VALUE obj;
  VALUE *all_args = ALLOCA_N(VALUE, argc + 1);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ca_is_face(ca) && ca_is_readonly(ca) ) {
    obj = rb_ca_copy(rb_ca_strip_face_value(self));
    if ( argc >= 1 && SYMBOL_P(argv[0]) ) {
      all_args[0] = rb_funcallv(self, SYM2ID(argv[0]), argc - 1, argv + 1);
      all_args[1] = CA_UNDEF;
      rb_funcallv(obj, rb_intern("[]="), 2, all_args);
    }
    else {
      memcpy(all_args, argv, argc * sizeof(VALUE));
      all_args[argc] = CA_UNDEF;
      rb_funcallv(obj, rb_intern("[]="), argc + 1, all_args);
    }
    return rb_funcall(obj, rb_intern("face_lift"), 1, self);
  }
  obj = rb_ca_copy(self);
  memcpy(all_args, argv, argc * sizeof(VALUE));
  all_args[argc] = CA_UNDEF;
  rb_funcallv(obj, rb_intern("[]="), argc + 1, all_args);
  return obj;
}

static VALUE
rb_ca_mask_eq (VALUE self, VALUE v)
{
  VALUE args[2] = { ID2SYM(rb_intern("eq")), v };
  return ca_mask_copy_where(self, 2, args);
}

/* mask_invalid — return form of "mask NaN/Inf cells".
   Equivalent to: obj = copy; obj[:is_invalid] = UNDEF; obj */
static VALUE
rb_ca_mask_invalid (VALUE self)
{
  VALUE args[1] = { ID2SYM(rb_intern("is_invalid")) };
  return ca_mask_copy_where(self, 1, args);
}

/* mask_where(*args) — generic return form predicate masking.
   Equivalent to: obj = copy; obj[*args] = UNDEF; obj
   Requires at least 1 argument. */
static VALUE
rb_ca_mask_where (int argc, VALUE *argv, VALUE self)
{
  if (argc == 0) {
    rb_raise(rb_eArgError, "mask_where requires at least 1 argument");
  }
  return ca_mask_copy_where(self, argc, argv);
}

/* inherit_mask's sources are read cell by cell over self, so an array
   source has self's number of cells (a scalar's one cell applies to all). */
static void
ca_inherit_mask_check_source (CArray *ca, CArray *cs)
{
  if ( ! ca_is_scalar(cs) && cs->elements != ca->elements ) {
    rb_raise(rb_eArgError,
             "%s: mask source has %lld elements, the receiver %lld",
             ca_calling_method_name(),
             (long long) cs->elements, (long long) ca->elements);
  }
}

/* @overload inherit_mask (*others):

(Masking, Destructive)
Sets the mask array of <code>self</code> by the logical sum of
the mask states of <code>self</code> and arrays given in arguments.
*/

static VALUE
rb_ca_inherit_mask_method (int argc, VALUE *argv, VALUE self)
{
  CArray **slist;
  volatile VALUE holder;
  CArray *ca, *cs;
  int i;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  slist = ALLOCV_N(CArray *, holder, argc);
  for (i=0; i<argc; i++) {
    if ( rb_obj_is_carray(argv[i]) ) {
      TypedData_Get_Struct(argv[i], CArray, &carray_data_type, cs);
      ca_inherit_mask_check_source(ca, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  ca_copy_mask_overlay_n(ca, ca->elements, argc, slist);

  ALLOCV_END(holder);

  return self;
}

/* api: rb_ca_inherit_mask_n */

VALUE
rb_ca_inherit_mask_n (VALUE self, int n, VALUE *rothers)
{
  return rb_ca_inherit_mask_method(n, rothers, self);
}

/* api: rb_ca_inherit_mask */

VALUE
rb_ca_inherit_mask (VALUE self, int n, ...)
{
  VALUE other;
  CArray **slist;
  volatile VALUE holder;
  CArray *ca, *cs;
  int i;
  va_list rothers;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  va_start(rothers, n);
  slist = ALLOCV_N(CArray *, holder, n);
  for (i=0; i<n; i++) {
    other = va_arg(rothers, VALUE);
    if ( rb_obj_is_carray(other) ) {
      TypedData_Get_Struct(other, CArray, &carray_data_type, cs);
      ca_inherit_mask_check_source(ca, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  va_end(rothers);

  ca_copy_mask_overlay_n(ca, ca->elements, n, slist);

  ALLOCV_END(holder);

  return self;
}

/* @overload inherit_mask_replace (*others)
Sets the mask array of <code>self</code> by the logical sum of
the mask states of arrays given in arguments.
This method does not inherit the mask states of itself (different point 
from `CArray#inherit_mask`)
*/

static VALUE
rb_ca_inherit_mask_replace_method (int argc, VALUE *argv, VALUE self)
{
  CArray **slist;
  volatile VALUE holder;
  CArray *ca, *cs;
  int i;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  slist = ALLOCV_N(CArray *, holder, argc);
  for (i=0; i<argc; i++) {
    if ( rb_obj_is_carray(argv[i]) ) {
      TypedData_Get_Struct(argv[i], CArray, &carray_data_type, cs);
      ca_inherit_mask_check_source(ca, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  ca_copy_mask_overwrite_n(ca, ca->elements, argc, slist);

  ALLOCV_END(holder);

  return self;
}

/* api: rb_ca_inherit_mask_replace_n */

VALUE
rb_ca_inherit_mask_replace_n (VALUE self, int n, VALUE *rothers)
{
  return rb_ca_inherit_mask_replace_method(n, rothers, self);
}

/* api: rb_ca_inherit_mask_replace */

VALUE
rb_ca_inherit_mask_replace (VALUE self, int n, ...)
{
  VALUE other;
  CArray **slist;
  volatile VALUE holder;
  CArray *ca, *cs;
  int i;
  va_list rothers;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  va_start(rothers, n);
  slist = ALLOCV_N(CArray *, holder, n);
  for (i=0; i<n; i++) {
    other = va_arg(rothers, VALUE);
    if ( rb_obj_is_carray(other) ) {
      TypedData_Get_Struct(other, CArray, &carray_data_type, cs);
      ca_inherit_mask_check_source(ca, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  va_end(rothers);

  ca_copy_mask_overwrite_n(ca, ca->elements, n, slist);

  ALLOCV_END(holder);

  return self;
}

/* The no-mask answer of count_masked / count_not_masked along `axes`:
   every reduced cell holds `fill`.  A reduction over every axis is the
   number itself. */
static VALUE
ca_count_uniform (CArray *ca, const int8_t *axes, int8_t naxes, ca_size_t fill)
{
  ca_size_t dim[CA_RANK_MAX];
  int8_t    ndim = 0;
  int       i, j;
  int64_t   v = (int64_t) fill;
  VALUE     result;
  CArray   *co;

  if ( naxes == ca->ndim ) {
    return SIZE2NUM(fill);
  }
  for (i = 0; i < ca->ndim; i++) {
    int is_axis = 0;
    for (j = 0; j < naxes; j++) {
      if ( axes[j] == i ) { is_axis = 1; break; }
    }
    if (!is_axis) dim[ndim++] = ca->dim[i];
  }
  result = rb_carray_new(CA_INT64, ndim, dim, 0, NULL);
  TypedData_Get_Struct(result, CArray, &carray_data_type, co);
  ca_fill(co, &v);
  return result;
}

/* count_true_ki / count_false_ki -- mkkernel-generated count kernels
   (carray_kernels.c, bind_ruby: false; output CA_INT64).  Used to reduce
   the boolean mask along axes in C for count_masked / count_not_masked,
   so the axis path needs no Ruby accumulate trampoline. */
extern VALUE rb_ca_count_true_ki  (int argc, VALUE *argv, VALUE self);
extern VALUE rb_ca_count_false_ki (int argc, VALUE *argv, VALUE self);

/* count_masked / count_not_masked -- the number of masked (present)
   cells, over every axis (an Integer) or along `axis:` (an int64 CArray).
   The keywords are those of the count kernels (axis:, keep_axis:,
   min_count:, fill_value:), checked by them: the mask is counted with
   count_true_ki / count_false_ki.  Without a mask the answer is known
   from the shape; an axis: alone takes that short cut after the same
   axis check the kernels make, and any other keyword runs the kernel on
   an all-false view that occupies one cell.

   Public (non-static) linkage so rb_ca_count in carray_count.c can forward
   count(UNDEF) here directly without going through Ruby method dispatch. */
static VALUE
ca_count_by_mask (int argc, VALUE *argv, VALUE self, int masked)
{
  CArray *ca;
  VALUE   kw_hash = Qnil, mask_obj;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  rb_scan_args(argc, argv, "0:", &kw_hash);

  if ( ! ca_has_mask(ca) ) {
    VALUE axis_val = Qnil;
    int   only_axis = 1;
    if ( ! NIL_P(kw_hash) ) {
      VALUE given = rb_hash_lookup2(kw_hash, ID2SYM(rb_intern("axis")), Qundef);
      axis_val  = ( given == Qundef ) ? Qnil : given;
      only_axis = ( RHASH_SIZE(kw_hash) == ( given == Qundef ? 0u : 1u ) );
    }
    if ( only_axis ) {
      int8_t    axes[CA_RANK_MAX];
      int8_t    naxes = rb_ca_parse_reduce_axes_kw(axis_val, ca, axes);
      ca_size_t vol = 1;
      int       i;
      for ( i = 0; i < naxes; i++ ) vol *= ca->dim[axes[i]];
      return ca_count_uniform(ca, axes, naxes, masked ? 0 : vol);
    }
    {
      ca_size_t one[CA_RANK_MAX];
      VALUE     shape = rb_ary_new_capa(ca->ndim), cell;
      boolean8_t zero = 0;
      CArray   *cc;
      int       i;
      for ( i = 0; i < ca->ndim; i++ ) {
        one[i] = 1;
        rb_ary_push(shape, SIZE2NUM(ca->dim[i]));
      }
      cell = rb_carray_new(CA_BOOLEAN, ca->ndim, one, 0, NULL);
      TypedData_Get_Struct(cell, CArray, &carray_data_type, cc);
      ca_fill(cc, &zero);
      mask_obj = rb_funcallv(cell, rb_intern("broadcast_to"),
                             (int) RARRAY_LEN(shape), RARRAY_CONST_PTR(shape));
    }
  }
  else {
    mask_obj = rb_ca_mask_array(self);
  }
  if ( NIL_P(kw_hash) ) {
    return masked ? rb_ca_count_true_ki(0, NULL, mask_obj)
                  : rb_ca_count_false_ki(0, NULL, mask_obj);
  }
  {
    VALUE kargv[1] = { kw_hash };
    return masked ? rb_ca_count_true_ki(1, kargv, mask_obj)
                  : rb_ca_count_false_ki(1, kargv, mask_obj);
  }
}

VALUE
rb_ca_count_masked (int argc, VALUE *argv, VALUE self)
{
  return ca_count_by_mask(argc, argv, self, 1);
}

VALUE
rb_ca_count_not_masked (int argc, VALUE *argv, VALUE self)
{
  return ca_count_by_mask(argc, argv, self, 0);
}

/* count_not_masked(axis: axis_val) for C callers. */
VALUE
rb_ca_count_not_masked_c (VALUE self, VALUE axis_val)
{
  VALUE kw;
  if ( NIL_P(axis_val) ) {
    return ca_count_by_mask(0, NULL, self, 0);
  }
  kw = rb_hash_new();
  rb_hash_aset(kw, ID2SYM(rb_intern("axis")), axis_val);
  return rb_funcall_with_block_kw(self, rb_intern("count_not_masked"), 1, &kw, Qnil, RB_PASS_KEYWORDS);
}

/* ============================================================================
 *  boolean8_t bit-op fast paths (table slot patching)
 *
 *  Strategy: ext/carray_math.c is GENERATED (= .gitignored, regen'd from
 *  ext/carray_math.rb).  Hand-editing the generated functions would be
 *  overwritten by `ruby carray_math.rb`.  Instead we:
 *
 *    1. Define standalone boolean8_t-only fast functions here in
 *       carray_mask.c (= hand-written, regen-safe).
 *    2. Patch the generated dispatch tables at Init time:
 *         ca_binop_bit_and_i[CA_BOOLEAN] = ca_binop_bit_and_i_boolean8_fast;
 *         (and similarly for _or_i, _xor_i, and ca_monop_bit_neg)
 *    3. Init_carray_mask_fast_paths() is called AFTER Init_carray_math()
 *       from ruby_carray.c so the patch sticks.
 *
 *  Each fast function handles BOTH paths internally:
 *    fast: m == NULL && i1 == i2 == i3 == 1 (contig + no mask)
 *      → word loop on uint64_t + tail byte fallback
 *    slow: anything else (mask present, or non-contig view, etc.)
 *      → duplicate of the original generated byte loop
 *
 *  The slow path is bit-identical to the generated function's body so
 *  hooking is transparent — no semantic change, only fast-path addition.
 * ============================================================================ */

/* Generated tables to be patched (defined non-static in carray_math.c). */
extern ca_binop_func_t ca_binop_bit_and_i[];
extern ca_binop_func_t ca_binop_bit_or_i[];
extern ca_binop_func_t ca_binop_bit_xor_i[];
extern ca_monop_func_t ca_monop_bit_neg[];
/* Note: Ruby `~` is registered as an alias of `bit_neg` (carray_math.c:
   rb_define_alias(rb_cCArray, "~", "bit_neg")); the table is
   ca_monop_bit_neg. */

/* ----- bit_and_i (boolean8_t fast) ----- */
static void
ca_binop_bit_and_i_boolean8_fast (ca_size_t n, boolean8_t *m,
                                  char *ptr1, ca_size_t i1,
                                  char *ptr2, ca_size_t i2,
                                  char *ptr3, ca_size_t i3)
{
  boolean8_t *q1 = (boolean8_t *) ptr1;
  boolean8_t *q2 = (boolean8_t *) ptr2;
  boolean8_t *q3 = (boolean8_t *) ptr3;
  boolean8_t *p1, *p2, *p3;
  ca_size_t   k;

  if ( m ) {
    /* mask path: existing byte loop (skip masked positions) */
    boolean8_t *pm;
    for (k = 0; k < n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        p3 = q3 + k*i3;
        (*p3) = (*p1) & (*p2);
      }
    }
  }
  else if ( i1 == 1 && i2 == 1 && i3 == 1 ) {
    /* fast path: word-bulk AND */
    ca_mask_word_and(q3, q1, q2, n);
  }
  else {
    /* non-contig view: existing byte loop */
    for (k = 0; k < n; k++) {
      p1 = q1 + k*i1;
      p2 = q2 + k*i2;
      p3 = q3 + k*i3;
      (*p3) = (*p1) & (*p2);
    }
  }
}

/* ----- bit_or_i (boolean8_t fast) ----- */
static void
ca_binop_bit_or_i_boolean8_fast (ca_size_t n, boolean8_t *m,
                                 char *ptr1, ca_size_t i1,
                                 char *ptr2, ca_size_t i2,
                                 char *ptr3, ca_size_t i3)
{
  boolean8_t *q1 = (boolean8_t *) ptr1;
  boolean8_t *q2 = (boolean8_t *) ptr2;
  boolean8_t *q3 = (boolean8_t *) ptr3;
  boolean8_t *p1, *p2, *p3;
  ca_size_t   k;

  if ( m ) {
    boolean8_t *pm;
    for (k = 0; k < n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        p3 = q3 + k*i3;
        (*p3) = (*p1) | (*p2);
      }
    }
  }
  else if ( i1 == 1 && i2 == 1 && i3 == 1 ) {
    /* fast path: inline 3-way word OR (ca_mask_word_or is 2-arg
       accumulating; here we need 3-arg). */
    ca_size_t       nw = n / CA_MASK_WORD_BYTES;
    ca_size_t       j;
    for (j = 0; j < nw; j++) {
      ca_mask_word_store(q3 + j*CA_MASK_WORD_BYTES,
                         ca_mask_word_load(q1 + j*CA_MASK_WORD_BYTES) | ca_mask_word_load(q2 + j*CA_MASK_WORD_BYTES));
    }
    for (j = nw * CA_MASK_WORD_BYTES; j < n; j++) {
      q3[j] = q1[j] | q2[j];
    }
  }
  else {
    for (k = 0; k < n; k++) {
      p1 = q1 + k*i1;
      p2 = q2 + k*i2;
      p3 = q3 + k*i3;
      (*p3) = (*p1) | (*p2);
    }
  }
}

/* ----- bit_xor_i (boolean8_t fast) -----
   Original generated form for boolean8_t uses `(*p3) = ((*p1) != (*p2)) ? 1 : 0`
   (logical XOR for {0,1}).  Word XOR is equivalent under invariant {0,1}:
   bytewise XOR of {0,1} stays in {0,1}. */
static void
ca_binop_bit_xor_i_boolean8_fast (ca_size_t n, boolean8_t *m,
                                  char *ptr1, ca_size_t i1,
                                  char *ptr2, ca_size_t i2,
                                  char *ptr3, ca_size_t i3)
{
  boolean8_t *q1 = (boolean8_t *) ptr1;
  boolean8_t *q2 = (boolean8_t *) ptr2;
  boolean8_t *q3 = (boolean8_t *) ptr3;
  boolean8_t *p1, *p2, *p3;
  ca_size_t   k;

  if ( m ) {
    boolean8_t *pm;
    for (k = 0; k < n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        p3 = q3 + k*i3;
        (*p3) = ((*p1) != (*p2)) ? 1 : 0;
      }
    }
  }
  else if ( i1 == 1 && i2 == 1 && i3 == 1 ) {
    /* fast path: word XOR */
    ca_mask_word_xor(q3, q1, q2, n);
  }
  else {
    for (k = 0; k < n; k++) {
      p1 = q1 + k*i1;
      p2 = q2 + k*i2;
      p3 = q3 + k*i3;
      (*p3) = ((*p1) != (*p2)) ? 1 : 0;
    }
  }
}

/* ----- bit_neg (= Ruby `~`, monop) (boolean8_t fast) -----
   The generated boolean8_t variant uses `(*p2) = (*p1) ? 0 : 1` (logical
   inversion via ternary), NOT bitwise `~`.  No caller expects byte `~`
   semantics for a boolean array, and the LSB XOR pattern
   (= ca_mask_word_not) is fully equivalent while preserving {0,1}. */
static void
ca_monop_bit_neg_boolean8_fast (ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2)
{
  boolean8_t *q1 = (boolean8_t *) ptr1;
  boolean8_t *q2 = (boolean8_t *) ptr2;
  boolean8_t *p1, *p2;
  ca_size_t   k;

  if ( m ) {
    boolean8_t *pm;
    for (k = 0; k < n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        (*p2) = (*p1) ? 0 : 1;
      }
    }
  }
  else if ( i1 == 1 && i2 == 1 ) {
    /* fast path: word NOT (LSB XOR) */
    ca_mask_word_not(q2, q1, n);
  }
  else {
    for (k = 0; k < n; k++) {
      p1 = q1 + k*i1;
      p2 = q2 + k*i2;
      (*p2) = (*p1) ? 0 : 1;
    }
  }
}

/* Init_carray_mask_fast_paths — patch generated dispatch tables.
   Must be called AFTER Init_carray_math (table is set up there).
   Wired in ruby_carray.c. */
void
Init_carray_mask_fast_paths (void)
{
  ca_binop_bit_and_i[CA_BOOLEAN] = ca_binop_bit_and_i_boolean8_fast;
  ca_binop_bit_or_i [CA_BOOLEAN] = ca_binop_bit_or_i_boolean8_fast;
  ca_binop_bit_xor_i[CA_BOOLEAN] = ca_binop_bit_xor_i_boolean8_fast;
  ca_monop_bit_neg  [CA_BOOLEAN] = ca_monop_bit_neg_boolean8_fast;
}


/* The Ruby forms of inherit_mask take CArray arguments only: refuse a
   keyword and any argument that is not a CArray, which the C API would
   pass over as maskless.  Returns the arguments without the keyword Hash. */
static VALUE
ca_inherit_mask_check_args (int argc, VALUE *argv, const char *name)
{
  VALUE rest, ropt;
  long i;
  rb_scan_args(argc, argv, "*:", &rest, &ropt);
  rb_reject_options(ropt);
  for (i=0; i<RARRAY_LEN(rest); i++) {
    VALUE v = RARRAY_AREF(rest, i);
    if ( ! rb_obj_is_carray(v) ) {
      rb_raise(rb_eTypeError, "%s: argument %ld must be a CArray (got %s)",
               name, i, rb_obj_classname(v));
    }
  }
  return rest;
}

static VALUE
rb_ca_inherit_mask_ruby (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rest = ca_inherit_mask_check_args(argc, argv, "inherit_mask");
  return rb_ca_inherit_mask_method((int) RARRAY_LEN(rest),
                                   (VALUE *) RARRAY_CONST_PTR(rest), self);
}

static VALUE
rb_ca_inherit_mask_replace_ruby (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rest = ca_inherit_mask_check_args(argc, argv,
                                                   "inherit_mask_replace");
  return rb_ca_inherit_mask_replace_method((int) RARRAY_LEN(rest),
                                           (VALUE *) RARRAY_CONST_PTR(rest), self);
}

void
Init_carray_mask (void)
{
  ca_mask_write_depth_key = rb_ractor_local_storage_value_newkey();

  rb_define_private_method(rb_cCArray, "add_mask", rb_ca_create_mask, 0);
  /*
  rb_define_private_method(rb_cCArray, "__update_mask__", rb_ca_update_mask, 0);
  */

  rb_define_method(rb_cCArray, "has_mask?",     rb_ca_has_mask, 0);
  rb_define_method(rb_cCArray, "any_masked?",   rb_ca_is_any_masked, 0);
  rb_define_method(rb_cCArray, "all_masked?",   rb_ca_is_all_masked, 0);

  rb_define_method(rb_cCArray, "value",         rb_ca_value_array, 0);
  rb_define_method(rb_cCArray, "mask",          rb_ca_mask_array, 0);
  rb_define_method(rb_cCArrayMask, "dup",   rb_ca_mask_dup,    0);
  rb_define_method(rb_cCArrayMask, "clone", rb_ca_mask_clone, -1);
  rb_define_method(rb_cCArray, "mask=",         rb_ca_set_mask, 1);
  rb_define_method(rb_cCArray, "is_masked",     rb_ca_is_masked, 0);
  rb_define_method(rb_cCArray, "is_not_masked", rb_ca_is_not_masked, 0);
  rb_define_method(rb_cCArray, "unmask",        rb_ca_unmask_method, -1);

  /* unmask_copy is not offered (removed in 3.0), no alias.  Migration:
       ca.unmask_copy()     -> ca.value.to_ca   (mask structure dissociated)
       ca.unmask_copy(fill) -> ca.strip_mask(fill)
     The internal C function ca_unmask_copy / rb_ca_mask_fill_copy stays
     since strip_mask wraps it. */

  /* strip_mask(fill) is the return form of "produce a mask-free copy
     filled with fill at previously-masked positions".  Fill is mandatory
     (arity 1, no default), matching the "all arguments mandatory"
     regularity of the mask SET family. */
  rb_define_method(rb_cCArray, "strip_mask",    rb_ca_mask_fill_copy, 1);
  rb_define_method(rb_cCArray, "invert_mask",  rb_ca_invert_mask, 0);
  rb_define_singleton_method(rb_cCArray, "guard_undef", rb_ca_s_guard_undef, -1);
  rb_define_method(rb_cCArray, "mask_eq",      rb_ca_mask_eq,      1);
  rb_define_method(rb_cCArray, "mask_invalid", rb_ca_mask_invalid, 0);
  rb_define_method(rb_cCArray, "mask_where",   rb_ca_mask_where,  -1);

  rb_define_method(rb_cCArray, "inherit_mask",  rb_ca_inherit_mask_ruby, -1);
  rb_define_method(rb_cCArray, "inherit_mask_replace",
                                       rb_ca_inherit_mask_replace_ruby, -1);

  rb_define_method(rb_cCArray, "count_masked",     rb_ca_count_masked, -1);
  rb_define_method(rb_cCArray, "count_not_masked", rb_ca_count_not_masked, -1);
}

