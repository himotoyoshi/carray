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

/* ma[i] |= ms[i] for i in [0, n)  -- used by ca_copy_mask_overlay_n */
static inline void
ca_mask_word_or (boolean8_t *ma, const boolean8_t *ms, ca_size_t n)
{
  ca_size_t       nw = n / CA_MASK_WORD_BYTES;
  ca_size_t       i;
  uint64_t       *wa = (uint64_t *)       ma;
  const uint64_t *ws = (const uint64_t *) ms;
  for (i = 0; i < nw; i++) {
    wa[i] |= ws[i];
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
  uint64_t       *wd = (uint64_t *)       md;
  const uint64_t *wa = (const uint64_t *) ma;
  const uint64_t *wb = (const uint64_t *) mb;
  for (i = 0; i < nw; i++) {
    wd[i] = wa[i] & wb[i];
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
  uint64_t       *wd = (uint64_t *)       md;
  const uint64_t *wa = (const uint64_t *) ma;
  const uint64_t *wb = (const uint64_t *) mb;
  for (i = 0; i < nw; i++) {
    wd[i] = wa[i] ^ wb[i];
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
  uint64_t       *wd = (uint64_t *)       md;
  const uint64_t *ws = (const uint64_t *) ms;
  for (i = 0; i < nw; i++) {
    wd[i] = ws[i] ^ CA_MASK_WORD_LSB;
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
  const uint64_t *w  = (const uint64_t *) m;
  for (i = 0; i < nw; i++) {
    if ( w[i] != 0 ) return 1;
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
  const uint64_t *w  = (const uint64_t *) m;
  for (i = 0; i < nw; i++) {
    if ( w[i] != CA_MASK_WORD_LSB ) return 0;
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

static ca_size_t
ca_mask_scan_virtual (CArray *mask, int op)
{
  int8_t      ndim  = mask->ndim;
  ca_size_t   outer = mask->dim[0];
  ca_size_t   inner = 1;
  ca_size_t   native[CA_RANK_MAX];
  ca_size_t   rows, off, result = 0;
  boolean8_t *scratch;
  int8_t      k;

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

  if ( op == CA_MASK_SCAN_ALL ) {
    result = 1;   /* vacuously all-set until a non-set cell is found */
  }

  ca_lazy_arena_enter();
  scratch = (boolean8_t *) ca_lazy_arena_acquire(rows * inner);

  for (off = 0; off < outer; off += rows) {
    ca_size_t nrow = (outer - off < rows) ? (outer - off) : rows;
    ca_size_t n    = nrow * inner;
    ca_size_t starts[CA_RANK_MAX] = {0};
    ca_size_t counts[CA_RANK_MAX];

    starts[0] = off;
    counts[0] = nrow;
    for (k = 1; k < ndim; k++) {
      counts[k] = mask->dim[k];
    }

    ca_xfer_stride(mask, starts, counts, native, scratch, CA_XFER_GET);

    if ( op == CA_MASK_SCAN_ANY ) {
      if ( ca_mask_word_any(scratch, n) )     { result = 1; break; }
    }
    else if ( op == CA_MASK_SCAN_ALL ) {
      if ( ! ca_mask_word_all_set(scratch, n) ) { result = 0; break; }
    }
    else {  /* CA_MASK_SCAN_COUNT — no early exit */
      result += ca_mask_word_count(scratch, n);
    }
  }

  ca_lazy_arena_release(scratch);
  ca_lazy_arena_exit();
  return result;
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
  else if ( ca_is_value_array(ca) ) {
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
      ca_attach(ca->mask);
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
      ca_attach(ca->mask);
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

/* create mask array if array has mask but has not mask array */

void
ca_update_mask (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ( ! ca->mask ) && ca_has_mask(ca) ) {
    ca_create_mask(ca);
  }
}

void
ca_create_mask (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ca_is_value_array(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not create mask array for the value array");
  }

  if ( ca_is_mask_array(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not create mask array for the mask array");
  }

  if ( ! ca->mask ) {
    ca_func[ca->obj_type].create_mask(ca);
    ca_set_flag(ca->mask, CA_FLAG_MASK_ARRAY); /* set array as mask array */
    if ( ca_is_view(ca) ) {
      if ( CAVIEW(ca)->attach ) {
        ca_attach(ca->mask);
        if ( ca_is_view(ca->mask) ) {
          CAVIEW(ca->mask)->attach = CAVIEW(ca)->attach;
        }
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

void
ca_setup_mask (void *ap, CArray *mask)
{
  CArray *ca = (CArray *) ap;

  ca_update_mask(ca);

  if ( mask ) {
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    ca_attach(mask);
    ca_sync_data(ca->mask, mask->ptr);
    ca_detach(mask);
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

void
ca_copy_mask_overlay_n (void *ap, ca_size_t elements, int n, CArray **slist)
{
  CArray *ca = (CArray *) ap;
  CArray *cs;
  boolean8_t *ma, *ms;
  int i, some_has_mask = 0;

  for (i=0; i<n; i++) {
    if ( slist[i] && ca_has_mask(slist[i]) ) {
      some_has_mask = 1;
      break;
    }
  }

  if ( some_has_mask ) {

    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }

    if ( elements > ca->elements ) {
      elements = ca->elements;
    }

    ca_attach(ca->mask);
    for (i=0; i<n; i++) {
      cs = slist[i];
      if ( ! cs ) {
        continue;
      }
      ca_update_mask(cs);
      if ( ! cs->mask ) {
        continue;
      }
      ca_attach(cs->mask);
      ma = (boolean8_t *) ca->mask->ptr;
      ms = (boolean8_t *) cs->mask->ptr;
      /* scalar masked source -> broadcast to all (memset); array source
         -> pure word OR (ca_mask_word_or).  A defensive `if (*ms)` is
         unnecessary: under the {0,1} invariant, `*ma |= *ms` equals
         `if (*ms) *ma = 1`.  Post-condition: the mask byte stays in {0,1}. */
      if ( ca_is_scalar(cs) ) {
        if ( *ms ) {
          memset(ma, 1, elements);
        }
      }
      else {
        ca_mask_word_or(ma, ms, elements);
      }
      ca_detach(cs->mask);
    }
    ca_sync(ca->mask);
    ca_detach(ca->mask);
  }
}

void
ca_copy_mask_overlay (void *ap, ca_size_t elements, int n, ...)
{
  CArray *ca = (CArray *) ap;
  CArray **slist;
  va_list args;
  int i;

  slist = xmalloc(sizeof(CArray *)*n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray *);
  }
  va_end(args);

  ca_copy_mask_overlay_n(ca, elements, n, slist);

  xfree(slist);
}

void
ca_copy_mask_overwrite_n (void *ap, ca_size_t elements, int n, CArray **slist)
{
  CArray *ca = (CArray *) ap;

  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }

  ca_copy_mask_overlay_n(ca, elements, n, slist);
}

void
ca_copy_mask_overwrite (void *ap, ca_size_t elements, int n, ...)
{
  CArray *ca = (CArray *) ap;
  CArray **slist;
  va_list args;
  int i;

  slist = xmalloc(sizeof(CArray*)*n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray*);
  }
  va_end(args);

  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t zero = 0;
    ca_fill(ca->mask, &zero);
  }

  ca_copy_mask_overlay_n(ca, elements, n, slist);

  xfree(slist);
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
      ca_attach(ca->mask);
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

  ca_update_mask(ca);
  if ( ca->mask ) {
    if ( ! fill_value ) {
      boolean8_t zero = 0;
      ca_fill(ca->mask, &zero);
    }
    else {
      ca_attach(ca);

      switch ( ca->bytes ) {
      case 1:  proc_fill_bang_width(uint8_t);  break;
      case 2:  proc_fill_bang_width(uint16_t); break;
      case 4:  proc_fill_bang_width(uint32_t); break;
      case 8:  proc_fill_bang_width(uint64_t); break;
      default: proc_fill_bang_bytes();         break;  /* cmplx128 (16) + fixlen */
      }

      ca_sync(ca);
      ca_detach(ca);
    }
  }
}

CArray *
ca_unmask_copy (void *ap, char *fill_value)
{
  CArray *ca = (CArray *) ap;
  CArray *co;
  char *q;
  boolean8_t *m;
  ca_size_t i;

  co = ca_template(ca);
  ca_copy_data(ca, co->ptr);

  if ( fill_value && ca_has_mask(ca) ) {
    ca_attach(ca);
    q = co->ptr;
    m = (boolean8_t *) ca->mask->ptr;
    for (i=0; i<ca->elements; i++) {
      if ( *m ) {
        memcpy(q, fill_value, ca->bytes);
      }
      m++; q+=co->bytes;
    }
    ca_detach(ca);
  }

  return co;
}

void
ca_invert_mask (void *ap)
{
  CArray *ca = (CArray *) ap;
  boolean8_t *m;

  ca_update_mask(ca);

  if ( ! ca->mask ) {
    ca_create_mask(ca);
  }

  ca_attach(ca->mask);
  m = (boolean8_t *) ca->mask->ptr;
  ca_mask_word_not(m, m, ca->elements);   /* in-place 1 - m, LSB-XOR word loop */
  ca_detach(ca->mask);

  return;
}

boolean8_t *
ca_allocate_mask_iterator_n (int n, CArray **slist)
{
  boolean8_t *m, *mp, *ms;
  CArray *cs;
  ca_size_t j, elements = -1;
  int i, some_has_mask = 0;

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
            rb_raise(rb_eRuntimeError,
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
  m = xmalloc(sizeof(boolean8_t)*elements);
  memset(m, 0, elements);

  if ( ! some_has_mask ) {
    return m;
  }

  for (i=0; i<n; i++) {
    cs = slist[i];
    if ( ! cs ) {
      continue;
    }
    ca_update_mask(cs);
    if ( ! cs->mask ) {
      continue;
    }
    ca_attach(cs->mask);
    ms = (boolean8_t *) cs->mask->ptr;
    mp = m;
    if ( ca_is_scalar(cs) ) {
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
    ca_detach(cs->mask);
  }
  return m;
}

boolean8_t *
ca_allocate_mask_iterator (int n, ...)
{
  boolean8_t *m;
  CArray **slist;
  va_list args;
  int i;

  slist = xmalloc(sizeof(CArray *)*n);
  va_start(args, n);
  for (i=0; i<n; i++) {
    slist[i] = va_arg(args, CArray *);
  }
  va_end(args);

  m = ca_allocate_mask_iterator_n(n, slist);

  xfree(slist);

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
    obj = TypedData_Wrap_Struct(ca_mask_class[ca->obj_type],
                                ca_mask_typeddata[ca->obj_type], ca->mask);	
    rb_ivar_set(obj, rb_intern("masked_array"), self);
    if ( OBJ_FROZEN(self) ) {
      rb_ca_freeze(obj);
    }
    return obj;
  }
  else {
    return INT2NUM(0);
  }
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
    rb_raise(rb_eRuntimeError,
             "can not create mask for the value array");
  }

  if ( ca_is_mask_array(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not create mask for the mask array");
  }

  ca_update_mask(ca);
  if ( ! ca->mask ) {
    ca_create_mask(ca);
  }

  if ( rb_obj_is_carray(rmask) ) {
    TypedData_Get_Struct(rmask, CArray, &carray_data_type, cv);
    if ( ! ca_is_boolean_type(cv) ) {
      cv = ca_wrap_readonly(rval, CA_BOOLEAN);
    }
    ca_setup_mask(ca, cv);
    ca_copy_mask_overlay(ca, ca->elements, 1, cv);
    return rval;
  }
  else {
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
  volatile VALUE mask;
  CArray *ca, *cm, *co;
  boolean8_t zero = 0;
  boolean8_t *m, *p;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_scalar(ca) ) {
    co = (CArray *)cscalar_new(CA_BOOLEAN, ca->bytes, NULL);        
  }
  else {
    co = carray_new(CA_BOOLEAN, ca->ndim, ca->dim, ca->bytes, NULL);    
  }

  ca_update_mask(ca);
  if ( ! ca->mask ) {
    ca_fill(co, &zero);
  }
  else {
    mask = rb_ca_mask_array(self);
    TypedData_Get_Struct(mask, CArray, &carray_data_type, cm);
    ca_attach(cm);
    m = (boolean8_t *) cm->ptr;
    p = (boolean8_t *) co->ptr;
    for (i=0; i<ca->elements; i++) {
      *p = ( *m ) ? 1 : 0;
      m++; p++;
    }
    ca_detach(cm);
  }

  return ca_wrap_struct(co);
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
  volatile VALUE mask;
  CArray *ca, *cm, *co;
  boolean8_t one = 1;
  boolean8_t *m, *p;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_scalar(ca) ) {
    co = (CArray *) cscalar_new(CA_BOOLEAN, ca->bytes, NULL);        
  }
  else {
    co = carray_new(CA_BOOLEAN, ca->ndim, ca->dim, ca->bytes, NULL);    
  }

  ca_update_mask(ca);
  if ( ! ca->mask ) {
    ca_fill(co, &one);
  }
  else {
    mask = rb_ca_mask_array(self);
    TypedData_Get_Struct(mask, CArray, &carray_data_type, cm);
    ca_attach(cm);
    m = (boolean8_t *) cm->ptr;
    p = (boolean8_t *) co->ptr;
    for (i=0; i<ca->elements; i++) {
      *p = ( *m ) ? 0 : 1;
      m++; p++;
    }
    ca_detach(cm);
  }

  return ca_wrap_struct(co);
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
  volatile VALUE rfval = CA_NIL, rcs;
  CArray *ca;
  CScalar *cv;
  char *fval = NULL;

  rb_ca_modify(self);

  if ( argc >= 1 ) {
    rfval = argv[0];
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( rfval != CA_NIL ) {
    /* Face has surface != storage; the fill value is cast in the storage data_type. */
    int8_t conv_type = ca->data_type;
    if ( ca_is_face(ca) ) {
      CArray *root = ca;
      while (root && ca_is_face(root)) root = ((CAView *) root)->parent;
      if (root) conv_type = root->data_type;
    }
    rcs = rb_cscalar_new_with_value(conv_type, ca->bytes, rfval);
    TypedData_Get_Struct(rcs, CScalar, &cscalar_data_type, cv);
    fval = cv->ptr;
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

/* @overload unmask_copy (fill_value = nil)

(Masking, Conversion)
Returns new unmasked array.
If the optional argument <code>fill_value</code> is given,
the masked elements are filled by <code>fill_value</code>.
The returned array doesn't have the mask array.
*/

static VALUE
rb_ca_unmask_copy_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rfval = CA_NIL, rcs;
  CArray *ca, *co;
  CScalar *cv;
  char *fval = NULL;

  if ( argc >= 1 ) {
    rfval = argv[0];
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( rfval != CA_NIL ) {
    /* Face has surface != storage; the fill value is cast in the storage data_type. */
    int8_t conv_type = ca->data_type;
    if ( ca_is_face(ca) ) {
      CArray *root = ca;
      while (root && ca_is_face(root)) root = ((CAView *) root)->parent;
      if (root) conv_type = root->data_type;
    }
    rcs = rb_cscalar_new_with_value(conv_type, ca->bytes, rfval);
    TypedData_Get_Struct(rcs, CScalar, &cscalar_data_type, cv);
    fval = cv->ptr;
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
static VALUE
rb_ca_mask_eq (VALUE self, VALUE v)
{
  volatile VALUE obj = rb_ca_copy(self);
  rb_funcall(obj, rb_intern("[]="), 3,
             ID2SYM(rb_intern("eq")), v, CA_UNDEF);
  return obj;
}

/* mask_invalid — return form of "mask NaN/Inf cells".
   Equivalent to: obj = copy; obj[:is_invalid] = UNDEF; obj */
static VALUE
rb_ca_mask_invalid (VALUE self)
{
  volatile VALUE obj = rb_ca_copy(self);
  rb_funcall(obj, rb_intern("[]="), 2,
             ID2SYM(rb_intern("is_invalid")), CA_UNDEF);
  return obj;
}

/* mask_where(*args) — generic return form predicate masking.
   Equivalent to: obj = copy; obj[*args] = UNDEF; obj
   Requires at least 1 argument. */
static VALUE
rb_ca_mask_where (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  VALUE *all_args;
  if (argc == 0) {
    rb_raise(rb_eArgError, "mask_where requires at least 1 argument");
  }
  obj = rb_ca_copy(self);
  all_args = ALLOCA_N(VALUE, argc + 1);
  memcpy(all_args, argv, argc * sizeof(VALUE));
  all_args[argc] = CA_UNDEF;
  rb_funcallv(obj, rb_intern("[]="), argc + 1, all_args);
  return obj;
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
  CArray *ca, *cs;
  int i;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  slist = xmalloc(sizeof(CArray *)*argc);
  for (i=0; i<argc; i++) {
    if ( rb_obj_is_carray(argv[i]) ) {
      TypedData_Get_Struct(argv[i], CArray, &carray_data_type, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  ca_copy_mask_overlay_n(ca, ca->elements, argc, slist);

  xfree(slist);

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
  CArray *ca, *cs;
  int i;
  va_list rothers;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  va_start(rothers, n);
  slist = xmalloc(sizeof(CArray *)*n);
  for (i=0; i<n; i++) {
    other = va_arg(rothers, VALUE);
    if ( rb_obj_is_carray(other) ) {
      TypedData_Get_Struct(other, CArray, &carray_data_type, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  va_end(rothers);

  ca_copy_mask_overlay_n(ca, ca->elements, n, slist);

  xfree(slist);

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
  CArray *ca, *cs;
  int i;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  slist = xmalloc(sizeof(CArray *)*argc);
  for (i=0; i<argc; i++) {
    if ( rb_obj_is_carray(argv[i]) ) {
      TypedData_Get_Struct(argv[i], CArray, &carray_data_type, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  ca_copy_mask_overwrite_n(ca, ca->elements, argc, slist);

  xfree(slist);

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
  CArray *ca, *cs;
  int i;
  va_list rothers;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  va_start(rothers, n);
  slist = xmalloc(sizeof(CArray *)*n);
  for (i=0; i<n; i++) {
    other = va_arg(rothers, VALUE);
    if ( rb_obj_is_carray(other) ) {
      TypedData_Get_Struct(other, CArray, &carray_data_type, cs);
      slist[i] = cs;
    }
    else {
      slist[i] = NULL;
    }
  }
  va_end(rothers);

  ca_copy_mask_overwrite_n(ca, ca->elements, n, slist);

  xfree(slist);

  return self;
}

/* Helper: build a fill-valued int64 CArray whose shape is ca's shape
   with the listed axes removed.  Used by count_masked/count_not_masked
   when there is no mask. */
static VALUE
ca_make_reduced_int64 (CArray *ca, int argc, VALUE *argv, ca_size_t fill_val)
{
  ca_size_t dim[CA_RANK_MAX];
  int8_t    ndim = 0;
  int       i, j;
  int64_t   v = (int64_t) fill_val;
  VALUE     result;
  CArray   *co;

  for (i = 0; i < ca->ndim; i++) {
    int is_axis = 0;
    for (j = 0; j < argc; j++) {
      int ax = NUM2INT(argv[j]);
      if (ax < 0) ax += ca->ndim;
      if (ax == i) { is_axis = 1; break; }
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

/* count_masked(*axis) -- number of masked elements, optionally reduced
   along axes (no args -> Integer; axis args -> int64 CArray with those
   axes collapsed).

   Public (non-static) linkage so rb_ca_count in carray_count.c can forward
   count(UNDEF) here directly without going through Ruby method dispatch. */
VALUE
rb_ca_count_masked (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Accepts the axis: kwarg only (positional axis is not accepted),
     matching the aggregate _ki family. */
  VALUE kw_hash, axis_val = Qnil;
  rb_scan_args(argc, argv, "0:", &kw_hash);
  rb_scan_options(kw_hash, "axis", &axis_val);

  /* No mask -> nothing is masked.  Short-circuit without materialising a
     zero mask (axis form returns a zero-filled reduced int64 array). */
  if (!ca_has_mask(ca)) {
    if (NIL_P(axis_val)) {
      return SIZE2NUM(0);
    }
    VALUE axis_ary = (TYPE(axis_val) == T_ARRAY) ? axis_val : rb_ary_new3(1, axis_val);
    return ca_make_reduced_int64(ca, (int) RARRAY_LEN(axis_ary),
                                 (VALUE *) RARRAY_CONST_PTR(axis_ary), 0);
  }

  /* Masked count = count of `true` in the mask, routed through the
     count_true_ki kernel for both the flat (no axis -> scalar Integer) and
     per-axis (-> reduced CArray) forms.  The scalar C primitive
     ca_count_masked stays separately for internal C callers (grid /
     median / order) that need a raw ca_size_t without Ruby allocation. */
  VALUE mask_obj = rb_ca_mask_array(self);
  if (NIL_P(axis_val)) {
    return rb_ca_count_true_ki(0, NULL, mask_obj);
  }
  VALUE kw = rb_hash_new();
  rb_hash_aset(kw, ID2SYM(rb_intern("axis")), axis_val);
  VALUE kargv[1] = { kw };
  return rb_ca_count_true_ki(1, kargv, mask_obj);
}

/* @overload count_not_masked(*axis)

(Masking, Statistics)
Returns the number of not-masked elements, optionally reduced along axes.
With no arguments returns an Integer.  With axis arguments returns a
CArray of int64 with the specified axes collapsed.
*/
/* C-callable entry: skip rb_scan_args (call-frame state dependency).
 * axis_val = Qnil       -> scalar Integer count over whole array
 * axis_val = Integer/Array -> reduced CArray int64
 * For ext authors who need to call count_not_masked from C. */
VALUE
rb_ca_count_not_masked_c (VALUE self, VALUE axis_val)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* No mask -> every element is not-masked.  Short-circuit without
     materialising a mask (no axis -> elements; axis form -> reduced int64
     filled with the product of the reduced-axis extents). */
  if (!ca_has_mask(ca)) {
    if (NIL_P(axis_val)) {
      return SIZE2NUM(ca->elements);
    }
    VALUE axis_ary = (TYPE(axis_val) == T_ARRAY) ? axis_val : rb_ary_new3(1, axis_val);
    int n_axes = (int) RARRAY_LEN(axis_ary);
    VALUE *axes_argv = (VALUE *) RARRAY_CONST_PTR(axis_ary);
    ca_size_t axis_vol = 1;
    int j;
    for (j = 0; j < n_axes; j++) {
      int ax = NUM2INT(axes_argv[j]);
      if (ax < 0) ax += ca->ndim;
      axis_vol *= ca->dim[ax];
    }
    return ca_make_reduced_int64(ca, n_axes, axes_argv, axis_vol);
  }

  /* Not-masked count = count of `false` in the mask, routed through the
     count_false_ki kernel for both the flat (no axis -> scalar Integer) and
     per-axis (-> reduced CArray) forms.  The scalar C primitive
     ca_count_not_masked (= elements - ca_count_masked) stays separately for
     internal C callers (median / order) that need a raw ca_size_t. */
  VALUE mask_obj = rb_ca_mask_array(self);
  if (NIL_P(axis_val)) {
    return rb_ca_count_false_ki(0, NULL, mask_obj);
  }
  VALUE kw = rb_hash_new();
  rb_hash_aset(kw, ID2SYM(rb_intern("axis")), axis_val);
  VALUE kargv[1] = { kw };
  return rb_ca_count_false_ki(1, kargv, mask_obj);
}

/* Ruby binding entry: parses (axis: kwarg) -> forwards to _c. */
VALUE
rb_ca_count_not_masked (int argc, VALUE *argv, VALUE self)
{
  /* Accepts the axis: kwarg only. */
  VALUE kw_hash, axis_val = Qnil;
  rb_scan_args(argc, argv, "0:", &kw_hash);
  rb_scan_options(kw_hash, "axis", &axis_val);
  return rb_ca_count_not_masked_c(self, axis_val);
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
    uint64_t       *wd = (uint64_t *)       q3;
    const uint64_t *wa = (const uint64_t *) q1;
    const uint64_t *wb = (const uint64_t *) q2;
    for (j = 0; j < nw; j++) {
      wd[j] = wa[j] | wb[j];
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


void
Init_carray_mask (void)
{
  rb_define_private_method(rb_cCArray, "__create_mask__", rb_ca_create_mask, 0);
  /*
  rb_define_private_method(rb_cCArray, "__update_mask__", rb_ca_update_mask, 0);
  */

  rb_define_method(rb_cCArray, "has_mask?",     rb_ca_has_mask, 0);
  rb_define_method(rb_cCArray, "any_masked?",   rb_ca_is_any_masked, 0);
  rb_define_method(rb_cCArray, "all_masked?",   rb_ca_is_all_masked, 0);

  rb_define_method(rb_cCArray, "value",         rb_ca_value_array, 0);
  rb_define_method(rb_cCArray, "mask",          rb_ca_mask_array, 0);
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

  rb_define_method(rb_cCArray, "inherit_mask",  rb_ca_inherit_mask_method, -1);
  rb_define_method(rb_cCArray, "inherit_mask_replace",
                                       rb_ca_inherit_mask_replace_method, -1);

  rb_define_method(rb_cCArray, "count_masked",     rb_ca_count_masked, -1);
  rb_define_method(rb_cCArray, "count_not_masked", rb_ca_count_not_masked, -1);
}

