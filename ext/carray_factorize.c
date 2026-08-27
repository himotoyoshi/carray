/* ---------------------------------------------------------------------------

  carray_factorize.c — single-pass value seen-set kernels.

  The value-hash discovery family shares one open-addressing hash that maps a
  widened 64-bit key to first-appearance state in a single linear pass, read
  through the kernel_iterator fiber surface (no entry ca_attach). Each kernel
  reads a different answer out of the same intern pass:

    - __factorize_appearance__ (categorize): map each value to a dense code in
      first-appearance order, emitting both the code storage and the level
      vocabulary in one pass.  Replaces categorize's discovery path, which reads
      the levels then assigns codes with one full eq scan per distinct value
      (O(distinct * N)).

    - __mask_duplicates__ (mask_duplicates): mark every cell whose value
      duplicates an earlier-seen one.  The hash's first-seen flag IS the answer
      (dup = not first-seen), so the sort-based mask_dup path collapses to the
      same one pass.

    - __unique_flat__ (unique): emit the distinct values in appearance order
      (the levels alone, codes discarded).

    - __value_counts_flat__ (value_counts): the levels plus a per-code count
      (a count lane beside the level buffer).

    - __nunique__ (nunique): the distinct count per fiber (the intern count is
      the answer; the reduction accumulator is a no-op).

    - __is_mode__ (is_mode): mark every cell holding a modal value (count equal
      to the fiber max) with a per-fiber two-pass frequency table; ties are all
      marked, never broken.

    - __mode_axis__ (mode per-axis): read the distinct modal values out of the
      per-fiber frequency table, ascending, as a ragged Array of reduced
      CArrays (the value-form consumer of the is_mode primitive).

  Peak memory is O(distinct values) for the hash, plus each kernel's own output.
  No sort, no gathered copy.

  The hash carries three key lanes.  Numeric (integer / float) widens the
  element to a lossless 64-bit key; boolean rides the uint8 numeric lane (its
  storage is uint8 0/1, so at most two distinct keys ever intern).  Float
  reproduces `==` with two value-based
  exceptions: all NaN collapse to one distinct value (so the second and later
  NaN are duplicates) and +0.0 / -0.0 compare equal (so -0.0 is normalized to
  +0.0 before the bitwise key).  Object keys on rb_hash with an rb_eql re-check,
  and fixlen on a byte-hash with a memcmp re-check; both reproduce Ruby Hash
  distinctness (`hash` + `eql?`) -- which already folds -0.0 / +0.0 together
  (Float#eql? treats them equal).  The object lane adds one deviation from Ruby
  Hash, aligning it with the numeric lane: every Float NaN collapses to one
  distinct value (a NaN takes a fixed canonical key and matches any stored Float
  NaN), where Ruby Hash would keep distinct NaN objects apart.
  __factorize_appearance__ and the discovery members (unique, value_counts,
  mask_duplicates) all cover the numeric / object / fixlen lanes.

  Private surfaces:
    self.__factorize_appearance__ -> [codes, levels]
      codes  : narrow unsigned CArray (uint8 / uint16 / uint32), the code
               storage; masked source cells store the type-max sentinel
               (from_codes derives the mask from it, matching categorize).
      levels : integer CArray (source data type) of the k distinct values in
               first-appearance order.
    self.__mask_duplicates__(axis) -> boolean CArray of self.shape, true at
      each cell that duplicates an earlier-seen one along axis (per-fiber
      independent seen-set).  Masked cells do not participate and stay false.
    self.__unique_flat__ -> 1-D CArray of the distinct values (appearance order).
    self.__value_counts_flat__ -> [levels, counts] (counts is 1-D CA_INT64).
    self.__nunique__(axis, keep_axis) -> reduced CA_INT64 distinct-count CArray.
    self.__is_mode__(axis) -> boolean CArray of self.shape, true at every modal
      cell (per-fiber max count) along axis; ties all marked.
    self.__mode_axis__(axis) -> Array of K reduced CArrays (self.shape with axis
      dropped), slot j = each fiber's j-th smallest modal value ascending, UNDEF
      where a fiber has fewer than j+1 modes; K = widest fiber's modal count.

--------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"
#include <string.h>
#include <math.h>

/* ---- Face gate (same three moves as the search / sort / count families) ----

   The value hash keys on raw cells, so a Face has to be brought into its
   storage space first and put back afterwards:

     - descend    an ORDERABLE Face to its storage.  ORDERABLE claims that
                  storage order == surface order, which for equality is the
                  part that matters: equal storage <=> equal surface.
     - reconcile  an operand through the reference Face (to_comparable), so a
                  set / membership question compares instants rather than the
                  ticks of whichever unit each side happens to carry.
     - re-lift    an output that carries *values* (unique / value_counts'
                  values / mode / the set operations), so the caller gets its
                  own type back.  Counts, booleans and indices stay plain.

   A Face without ORDERABLE is left exactly as it was: its equality is not its
   storage's, so descending would answer the wrong question.  CAConstString is
   the live example -- a cell is a (start, end) byte range, so two equal strings
   at different offsets have different storage -- and it needs its own
   discovery surface rather than this gate (see
   devel/PROPOSAL_DISCOVERY_FAMILY_FACE_GATE.md §4). */

/* Descend `self` when it is an ORDERABLE Face; *pface keeps the pre-strip Face
   for the re-lift (Qnil when there is nothing to put back). */
static VALUE
fz_face_descend (VALUE self, volatile VALUE *pface)
{
  CArray *ca;
  GetCArray(self, ca);
  if ( ca_is_face(ca) && ca_test_flag(ca, CA_FLAG_FACE_ORDERABLE_STORAGE) ) {
    *pface = self;
    return rb_ca_strip_face_value(self);
  }
  *pface = Qnil;
  return self;
}

/* Bring `operand` into the space of `reference` (the *pre-strip* Face) and
   descend it, so both sides hash in one storage space.

   `to_comparable` exists because a Face can carry a *unit* -- an alternative
   space for the same value -- so a reference that defines it reconciles any
   operand type through it (and refuses what it cannot convert, which is how a
   bare storage number stays out).  A reference with one space only (COMPARABLE,
   or a Face with no unit algebra at all, e.g. CAString) has nothing to
   reconcile between: descending both sides is the whole job. */
static VALUE
fz_face_reconcile (VALUE reference, VALUE operand, const char *name)
{
  CArray *ca;
  if ( NIL_P(reference) ) {
    return operand;
  }
  GetCArray(reference, ca);
  if ( ! ca_test_flag(ca, CA_FLAG_FACE_COMPARABLE_STORAGE)
       && rb_respond_to(reference, rb_intern("to_comparable")) ) {
    return rb_ca_strip_face_value(rb_funcall(reference,
                                             rb_intern("to_comparable"),
                                             1, operand));
  }
  if ( rb_obj_is_carray(operand) ) {
    CArray *op;
    GetCArray(operand, op);
    if ( ca_is_face(op) ) {
      return rb_ca_strip_face_value(operand);
    }
  }
  (void) name;
  return operand;
}

/* Put the Face back on a value-carrying output. */
static VALUE
fz_face_relift (VALUE out, VALUE face)
{
  if ( NIL_P(face) ) {
    return out;
  }
  return ca_face_lift(out, face);
}

/* ---- open-addressing hash: widened 64-bit key -> first-appearance code ---- */

typedef struct {
  uint64_t *key;
  int32_t  *code;
  uint8_t  *used;
  VALUE    *val;    /* object lane only: the interned VALUE, kept for an eql? re-check
                       on a hash collision (NULL in the numeric lane, where the widened
                       key is lossless so a key match already proves value equality).
                       Its VALUEs are always elements of the live receiver, so the GC
                       reaches them through `self`; this array is not separately marked. */
  char     *raw;    /* fixlen lane only: cap*esz bytes, the interned element bytes kept
                       for a memcmp re-check on a hash collision (NULL otherwise). */
  int       esz;    /* fixlen lane: element width in bytes (0 otherwise) */
  ca_size_t cap;    /* power of two */
  ca_size_t n;      /* distinct keys interned so far */
  int       shift;  /* 64 - log2(cap); the home slot is the top log2(cap) bits */
} fz_hash;

/* Multiplicative hashing (Knuth, TAOCP vol. 3 sec. 6.4): multiply by
   2^64 / golden-ratio and take the TOP log2(cap) bits of the product -- the
   high bits are where a multiply mixes best (the low bits carry little
   entropy, which sparse keys such as small-integer float bit patterns expose).
   The constant is a plain mathematical value = floor(2^64 / phi),
   phi = (1 + sqrt 5) / 2. */
#define FZ_GOLDEN 0x9E3779B97F4A7C15ULL
#define FZ_HOME(h, key) ((ca_size_t) (((uint64_t)(key) * FZ_GOLDEN) >> (h)->shift))

static void
fz_hash_init (fz_hash *h)
{
  h->cap   = 1024;
  h->shift = 64 - 10;   /* log2(1024) = 10 */
  h->n     = 0;
  h->key   = ALLOC_N(uint64_t, h->cap);
  h->code  = ALLOC_N(int32_t,  h->cap);
  h->used  = ALLOC_N(uint8_t,  h->cap);
  h->val   = NULL;      /* numeric lane: no VALUE re-check needed */
  h->raw   = NULL;
  h->esz   = 0;
  MEMZERO(h->used, uint8_t, h->cap);
}

/* Object lane: the widened key is `rb_hash` (lossy), so a slot also stores the
   interned VALUE for an `eql?` re-check on collision.  Equality then matches
   Ruby Hash exactly (`hash` + `eql?`), reproducing the object seen-set path. */
static void
fz_hash_init_obj (fz_hash *h)
{
  fz_hash_init(h);
  h->val = ALLOC_N(VALUE, h->cap);
}

/* Fixlen lane: the key is a byte-hash of the esz-wide element (lossy), so a slot
   stores the element bytes for a `memcmp` re-check on collision.  For fixlen
   cells (uniform width, binary encoding) byte equality matches Ruby String
   `eql?`, reproducing the Ruby Hash seen-set the fixlen path used. */
static void
fz_hash_init_mem (fz_hash *h, int esz)
{
  fz_hash_init(h);
  h->esz = esz;
  h->raw = ALLOC_N(char, h->cap * esz);
}

static void
fz_hash_free (fz_hash *h)
{
  if ( h->key )  { xfree(h->key);  h->key  = NULL; }
  if ( h->code ) { xfree(h->code); h->code = NULL; }
  if ( h->used ) { xfree(h->used); h->used = NULL; }
  if ( h->val )  { xfree(h->val);  h->val  = NULL; }
  if ( h->raw )  { xfree(h->raw);  h->raw  = NULL; }
}

/* FNV-1a over esz bytes: a lossy 64-bit key for the fixlen lane. */
static uint64_t
fz_bytehash (const char *b, int esz)
{
  uint64_t x = 14695981039346656037ULL;
  for ( int i = 0; i < esz; i++ ) {
    x = (x ^ (unsigned char) b[i]) * 1099511628211ULL;
  }
  return x;
}

/* Clear all interned keys while keeping the allocated capacity, so a per-fiber
   seen-set can be reused across fibers without reallocating each time. */
static void
fz_hash_reset (fz_hash *h)
{
  h->n = 0;
  MEMZERO(h->used, uint8_t, h->cap);
}

static void
fz_hash_grow (fz_hash *h)
{
  ca_size_t oldcap = h->cap, newcap = oldcap << 1;
  uint64_t *ok = h->key;
  int32_t  *oc = h->code;
  uint8_t  *ou = h->used;
  VALUE    *ov = h->val;
  char     *orw = h->raw;
  int       esz = h->esz;
  h->cap    = newcap;
  h->shift -= 1;                 /* log2(cap) grew by one */
  h->key    = ALLOC_N(uint64_t, newcap);
  h->code   = ALLOC_N(int32_t,  newcap);
  h->used   = ALLOC_N(uint8_t,  newcap);
  if ( ov )  { h->val = ALLOC_N(VALUE, newcap); }
  if ( orw ) { h->raw = ALLOC_N(char, newcap * esz); }
  MEMZERO(h->used, uint8_t, newcap);
  ca_size_t mask = newcap - 1;
  for ( ca_size_t s = 0; s < oldcap; s++ ) {
    if ( ! ou[s] ) { continue; }
    ca_size_t slot = FZ_HOME(h, ok[s]);
    while ( h->used[slot] ) { slot = (slot + 1) & mask; }
    h->used[slot] = 1;
    h->key[slot]  = ok[s];
    h->code[slot] = oc[s];
    if ( ov )  { h->val[slot] = ov[s]; }
    if ( orw ) { memcpy(h->raw + slot * esz, orw + s * esz, esz); }
  }
  xfree(ok); xfree(oc); xfree(ou);
  if ( ov )  { xfree(ov); }
  if ( orw ) { xfree(orw); }
}

/* True when v is a Float holding NaN (any bit pattern). */
static inline int
fz_is_float_nan (VALUE v)
{
  return RB_FLOAT_TYPE_P(v) && isnan(RFLOAT_VALUE(v));
}

/* Object-lane intern: key = rb_hash(v) (lossy), collision re-check via rb_eql.
   Matches Ruby Hash distinctness (`hash` + `eql?`) element for element, with one
   value-based exception aligning with the numeric lane: every Float NaN collapses
   to a single distinct value (Ruby Hash keeps distinct NaN objects apart via
   eql?, but the discovery family unifies them).  A NaN takes a fixed canonical
   key and matches any stored Float NaN, so its second and later occurrences fold
   into the first. */
static int32_t
fz_hash_intern_obj (fz_hash *h, VALUE v, int *is_new)
{
  if ( (h->n + 1) * 10 >= h->cap * 7 ) { fz_hash_grow(h); }   /* load factor 0.7 */
  int v_nan = fz_is_float_nan(v);
  uint64_t key = v_nan ? 0x7ff8000000000000ULL
                       : (uint64_t) NUM2LL(rb_hash(v));
  ca_size_t mask = h->cap - 1;
  ca_size_t slot = FZ_HOME(h, key);
  while ( h->used[slot] ) {
    if ( h->key[slot] == key &&
         ( v_nan ? fz_is_float_nan(h->val[slot]) : rb_eql(h->val[slot], v) ) ) {
      *is_new = 0; return h->code[slot];
    }
    slot = (slot + 1) & mask;
  }
  int32_t code = (int32_t) h->n;
  h->used[slot] = 1;
  h->key[slot]  = key;
  h->val[slot]  = v;
  h->code[slot] = code;
  h->n++;
  *is_new = 1;
  return code;
}

/* Fixlen-lane intern: key = byte-hash of the esz-wide element (lossy), collision
   re-check via memcmp.  Matches Ruby String eql? for uniform-width binary cells. */
static int32_t
fz_hash_intern_mem (fz_hash *h, const char *b, int *is_new)
{
  if ( (h->n + 1) * 10 >= h->cap * 7 ) { fz_hash_grow(h); }   /* load factor 0.7 */
  int esz = h->esz;
  uint64_t key = fz_bytehash(b, esz);
  ca_size_t mask = h->cap - 1;
  ca_size_t slot = FZ_HOME(h, key);
  while ( h->used[slot] ) {
    if ( h->key[slot] == key && memcmp(h->raw + slot * esz, b, esz) == 0 ) {
      *is_new = 0; return h->code[slot];
    }
    slot = (slot + 1) & mask;
  }
  int32_t code = (int32_t) h->n;
  h->used[slot] = 1;
  h->key[slot]  = key;
  memcpy(h->raw + slot * esz, b, esz);
  h->code[slot] = code;
  h->n++;
  *is_new = 1;
  return code;
}

/* Intern `key`; return its code, set *is_new when first seen. */
static int32_t
fz_hash_intern (fz_hash *h, uint64_t key, int *is_new)
{
  if ( (h->n + 1) * 10 >= h->cap * 7 ) { fz_hash_grow(h); }   /* load factor 0.7 */
  ca_size_t mask = h->cap - 1;
  ca_size_t slot = FZ_HOME(h, key);
  while ( h->used[slot] ) {
    if ( h->key[slot] == key ) { *is_new = 0; return h->code[slot]; }
    slot = (slot + 1) & mask;
  }
  int32_t code = (int32_t) h->n;
  h->used[slot] = 1;
  h->key[slot]  = key;
  h->code[slot] = code;
  h->n++;
  *is_new = 1;
  return code;
}

/* ---- lookup-only probes: does the value exist in the seen-set? ------------
   Each mirrors its intern sibling's search loop but never inserts, so a set
   built once (by interning one array) can be probed by the other array's
   elements.  Return 1 when present, 0 when absent.  The three lanes reuse the
   same key derivation and collision re-check as intern, so membership matches
   the discovery family's distinctness exactly.

   code_out (nullable): when non-NULL and the value is present, the interned
   dense code (appearance-order index intern wrote at that slot) is returned
   through it.  is_in passes NULL (membership only); the 3.1 locate / set-op
   members read the code to map a hit to a flat address / distinct push. */

static int
fz_hash_lookup (fz_hash *h, uint64_t key, int32_t *code_out)
{
  ca_size_t mask = h->cap - 1;
  ca_size_t slot = FZ_HOME(h, key);
  while ( h->used[slot] ) {
    if ( h->key[slot] == key ) {
      if ( code_out ) { *code_out = h->code[slot]; }
      return 1;
    }
    slot = (slot + 1) & mask;
  }
  return 0;
}

static int
fz_hash_lookup_obj (fz_hash *h, VALUE v, int32_t *code_out)
{
  int v_nan = fz_is_float_nan(v);
  uint64_t key = v_nan ? 0x7ff8000000000000ULL
                       : (uint64_t) NUM2LL(rb_hash(v));
  ca_size_t mask = h->cap - 1;
  ca_size_t slot = FZ_HOME(h, key);
  while ( h->used[slot] ) {
    if ( h->key[slot] == key &&
         ( v_nan ? fz_is_float_nan(h->val[slot]) : rb_eql(h->val[slot], v) ) ) {
      if ( code_out ) { *code_out = h->code[slot]; }
      return 1;
    }
    slot = (slot + 1) & mask;
  }
  return 0;
}

static int
fz_hash_lookup_mem (fz_hash *h, const char *b, int32_t *code_out)
{
  int esz = h->esz;
  uint64_t key = fz_bytehash(b, esz);
  ca_size_t mask = h->cap - 1;
  ca_size_t slot = FZ_HOME(h, key);
  while ( h->used[slot] ) {
    if ( h->key[slot] == key && memcmp(h->raw + slot * esz, b, esz) == 0 ) {
      if ( code_out ) { *code_out = h->code[slot]; }
      return 1;
    }
    slot = (slot + 1) & mask;
  }
  return 0;
}

/* ---- growable raw-element buffer: the levels in appearance order ---------- */

typedef struct {
  char     *p;
  ca_size_t cap;    /* capacity in elements */
  ca_size_t n;      /* elements stored */
  int       esz;    /* element bytes */
} fz_levels;

static void
fz_levels_init (fz_levels *l, int esz)
{
  l->esz = esz;
  l->cap = 16;
  l->n   = 0;
  l->p   = ALLOC_N(char, l->cap * esz);
}

static void
fz_levels_push (fz_levels *l, const void *e)
{
  if ( l->n == l->cap ) {
    l->cap <<= 1;
    REALLOC_N(l->p, char, l->cap * l->esz);
  }
  memcpy(l->p + l->n * l->esz, e, l->esz);
  l->n++;
}

static void
fz_levels_free (fz_levels *l)
{
  if ( l->p ) { xfree(l->p); l->p = NULL; }
}

/* @overload __factorize_appearance__

   INTERNAL (categorize's discovery pass). Factorize self into dense codes in
   first-appearance order, one linear pass, no sort. Accepts the integer, float,
   object, and fixlen lanes (the numeric lane keys on the widened integer, the
   float lane on the bitwise key with NaN collapsed to one value and -0.0 == +0.0,
   the object lane on rb_hash + rb_eql, the fixlen lane on a byte-hash + memcmp),
   matching the discovery family's lane coverage.

   Returns [codes, levels]:
     codes  = narrow unsigned CArray; masked source cells store the type-max
              sentinel (0xFF / 0xFFFF / 0xFFFFFFFF), so from_codes reconstructs
              the mask exactly as the mask_duplicates path does.
     levels = CArray (source data type) of the k distinct values, in first-appearance
              (row-major flatten) order.
*/
static VALUE
rb_ca_factorize_appearance (VALUE self)
{
  CArray *ca;
  volatile VALUE face;
  self = fz_face_descend(self, &face);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:    case CA_INT16:   case CA_INT32:  case CA_INT64:
  case CA_UINT8:   case CA_UINT16:  case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT:  case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__factorize_appearance__: integer, float, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__factorize_appearance__: need ndim >= 1");
  }

  ca_size_t N = ca->elements;

  /* uint32 code scratch, same shape as self; narrowed once k is known. */
  VALUE vu32 = rb_carray_new(CA_UINT32, ca->ndim, ca->dim, 0, NULL);
  CArray *cu32;
  TypedData_Get_Struct(vu32, CArray, &carray_data_type, cu32);

  fz_hash h;
  fz_levels lv;
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }
  fz_levels_init(&lv, (int) ca->bytes);

  int8_t axis = (int8_t) (ca->ndim - 1);   /* innermost fiber = row-major flatten */

  ca_iter_state st_in, st_out;
  char       *p_in, *p_out;
  boolean8_t *m;
  ca_size_t   n;

  /* Fiber inner loop, monomorphised per data type.  WIDEN sign- or zero-extends the
     element to a 64-bit key; equality within one data type is preserved. */
  #define FZ_LOOP(T, WIDEN)                                                  \
    do {                                                                     \
      const T  *ip = (const T *) p_in;                                       \
      uint32_t *op = (uint32_t *) p_out;                                     \
      for ( ca_size_t i = 0; i < n; i++ ) {                                  \
        if ( m && m[i] ) { op[i] = 0xFFFFFFFFu; continue; }                  \
        uint64_t key = (uint64_t) (WIDEN ip[i]);                            \
        int is_new;                                                          \
        int32_t code = fz_hash_intern(&h, key, &is_new);                     \
        if ( is_new ) { fz_levels_push(&lv, &ip[i]); }                       \
        op[i] = (uint32_t) code;                                             \
      }                                                                      \
    } while (0)

  /* Float lane: reproduce `==` with two value-based exceptions matching the
     discovery family -- all NaN collapse to one canonical key (v != v -> NANKEY),
     and -0.0 == +0.0 (a zero normalizes to +0.0 before the bitwise key).  The
     level pushed is the raw first-seen element (an appearance-first NaN / -0.0 is
     kept as-is), so masked source cells store the sentinel. */
  #define FZ_LOOP_FLOAT(T, UINT, NANKEY)                                     \
    do {                                                                     \
      const T  *ip = (const T *) p_in;                                       \
      uint32_t *op = (uint32_t *) p_out;                                     \
      for ( ca_size_t i = 0; i < n; i++ ) {                                  \
        if ( m && m[i] ) { op[i] = 0xFFFFFFFFu; continue; }                  \
        T v = ip[i];                                                         \
        uint64_t key;                                                        \
        if ( v != v ) { key = (NANKEY); }                                    \
        else {                                                               \
          if ( v == (T) 0 ) { v = (T) 0; }                                   \
          UINT bits;                                                         \
          memcpy(&bits, &v, sizeof(bits));                                   \
          key = (uint64_t) bits;                                             \
        }                                                                    \
        int is_new;                                                          \
        int32_t code = fz_hash_intern(&h, key, &is_new);                     \
        if ( is_new ) { fz_levels_push(&lv, &ip[i]); }                       \
        op[i] = (uint32_t) code;                                             \
      }                                                                      \
    } while (0)

  /* Object lane: intern the raw VALUE (rb_hash + rb_eql); the level pushed is the
     first-seen VALUE, kept alive through self.  Masked cells store the sentinel. */
  #define FZ_LOOP_OBJ                                                        \
    do {                                                                     \
      const VALUE *ip = (const VALUE *) p_in;                                \
      uint32_t    *op = (uint32_t *) p_out;                                  \
      for ( ca_size_t i = 0; i < n; i++ ) {                                  \
        if ( m && m[i] ) { op[i] = 0xFFFFFFFFu; continue; }                  \
        int is_new;                                                          \
        int32_t code = fz_hash_intern_obj(&h, ip[i], &is_new);              \
        if ( is_new ) { fz_levels_push(&lv, &ip[i]); }                       \
        op[i] = (uint32_t) code;                                             \
      }                                                                      \
    } while (0)

  /* Fixlen lane: intern the esz-wide element bytes (byte-hash + memcmp); the
     level pushed is a copy of the first-seen bytes. */
  #define FZ_LOOP_MEM                                                        \
    do {                                                                     \
      int esz = (int) ca->bytes;                                             \
      uint32_t *op = (uint32_t *) p_out;                                     \
      for ( ca_size_t i = 0; i < n; i++ ) {                                  \
        if ( m && m[i] ) { op[i] = 0xFFFFFFFFu; continue; }                  \
        const char *e = p_in + i * esz;                                      \
        int is_new;                                                          \
        int32_t code = fz_hash_intern_mem(&h, e, &is_new);                  \
        if ( is_new ) { fz_levels_push(&lv, e); }                            \
        op[i] = (uint32_t) code;                                             \
      }                                                                      \
    } while (0)

  CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, ca, cu32, axis,
                                 CA_KERNEL_READ, p_in, p_out, n, m) {
    switch ( dt ) {
    case CA_INT8:   FZ_LOOP(int8_t,   (int64_t));  break;
    case CA_INT16:  FZ_LOOP(int16_t,  (int64_t));  break;
    case CA_INT32:  FZ_LOOP(int32_t,  (int64_t));  break;
    case CA_INT64:  FZ_LOOP(int64_t,  (int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  FZ_LOOP(uint8_t,  (uint64_t)); break;
    case CA_UINT16: FZ_LOOP(uint16_t, (uint64_t)); break;
    case CA_UINT32: FZ_LOOP(uint32_t, (uint64_t)); break;
    case CA_UINT64: FZ_LOOP(uint64_t, (uint64_t)); break;
    case CA_FLOAT32: FZ_LOOP_FLOAT(float,  uint32_t, 0x7fc00000ULL);         break;
    case CA_FLOAT64: FZ_LOOP_FLOAT(double, uint64_t, 0x7ff8000000000000ULL); break;
    case CA_OBJECT: FZ_LOOP_OBJ;                   break;
    case CA_FIXLEN: FZ_LOOP_MEM;                   break;
    }
  }
  #undef FZ_LOOP
  #undef FZ_LOOP_FLOAT
  #undef FZ_LOOP_OBJ
  #undef FZ_LOOP_MEM

  ca_size_t k = h.n;
  fz_hash_free(&h);

  /* Narrow the uint32 scratch to the smallest code storage that holds k codes
     plus the type-max sentinel, mirroring categorize's width rule. */
  int8_t code_dt;
  if      ( k <= 0xFF )   { code_dt = CA_UINT8;  }
  else if ( k <= 0xFFFF ) { code_dt = CA_UINT16; }
  else                    { code_dt = CA_UINT32; }

  VALUE vcodes;
  if ( code_dt == CA_UINT32 ) {
    vcodes = vu32;                          /* sentinel already 0xFFFFFFFF */
  }
  else {
    vcodes = rb_carray_new(code_dt, ca->ndim, ca->dim, 0, NULL);
    CArray *cco;
    TypedData_Get_Struct(vcodes, CArray, &carray_data_type, cco);
    const uint32_t *up = (const uint32_t *) cu32->ptr;
    if ( code_dt == CA_UINT8 ) {
      uint8_t *cp = (uint8_t *) cco->ptr;
      for ( ca_size_t i = 0; i < N; i++ ) {
        cp[i] = (up[i] == 0xFFFFFFFFu) ? (uint8_t) 0xFF : (uint8_t) up[i];
      }
    }
    else {
      uint16_t *cp = (uint16_t *) cco->ptr;
      for ( ca_size_t i = 0; i < N; i++ ) {
        cp[i] = (up[i] == 0xFFFFFFFFu) ? (uint16_t) 0xFFFF : (uint16_t) up[i];
      }
    }
  }

  /* Levels: the interned raw values, in source data type.  CA_FIXLEN carries its
     element width; numeric / object use bytes = 0. */
  ca_size_t ldim[1];
  ldim[0] = k;
  VALUE vlev = rb_carray_new(dt, 1, ldim, (dt == CA_FIXLEN) ? ca->bytes : 0, NULL);
  CArray *clev;
  TypedData_Get_Struct(vlev, CArray, &carray_data_type, clev);
  if ( k > 0 ) {
    memcpy(clev->ptr, lv.p, (size_t) k * (size_t) ca->bytes);
  }
  fz_levels_free(&lv);

  /* codes stay plain; levels are *values* and become categorize's labels */
  return rb_ary_new3(2, vcodes, fz_face_relift(vlev, face));
}

/* @overload __mask_duplicates__(axis)

   INTERNAL (mask_duplicates). Mark each cell whose value duplicates an
   earlier-seen one along axis, one linear pass per fiber, no sort.

   Returns a boolean CArray of self.shape: true at every duplicate position
   (the first occurrence of each distinct value stays false). The seen-set is
   per-fiber independent along axis. Masked source cells do not participate in
   duplicate judging and stay false (they remain masked via mask_where
   downstream). Covers numeric / object / fixlen; boolean routes through the
   uint8 numeric lane (storage is uint8 0/1, at most two distinct keys).

   Numeric distinctness follows `==` with two value-based exceptions matching the
   discovery family: all NaN collapse to one distinct value (so the second and
   later NaN along the fiber are duplicates) and -0.0 == +0.0. Object keys on
   rb_hash + rb_eql and fixlen on a byte-hash + memcmp, reproducing Ruby Hash
   distinctness; the object lane additionally collapses every Float NaN to one
   value (so the second and later NaN are duplicates, as in the numeric lane).
*/
static VALUE
rb_ca_mask_duplicates (VALUE self, VALUE vaxis)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__mask_duplicates__: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__mask_duplicates__: need ndim >= 1");
  }

  int axis = NUM2INT(vaxis);
  if ( axis < 0 || axis >= ca->ndim ) {
    rb_raise(rb_eArgError, "__mask_duplicates__: axis %d out of range", axis);
  }

  VALUE vout = rb_carray_new(CA_BOOLEAN, ca->ndim, ca->dim, 0, NULL);
  CArray *cout;
  TypedData_Get_Struct(vout, CArray, &carray_data_type, cout);

  fz_hash h;
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }

  ca_iter_state st_in, st_out;
  char       *p_in, *p_out;
  boolean8_t *m;
  ca_size_t   n;

  /* Fiber inner loop, monomorphised per data type.  WIDEN sign- or zero-extends the
     element to a 64-bit key; equality within one data type is preserved.  The hash
     interns first appearances, so is_new == 0 flags a duplicate. */
  #define MD_LOOP(T, WIDEN)                                                   \
    do {                                                                      \
      const T    *ip = (const T *) p_in;                                      \
      boolean8_t *op = (boolean8_t *) p_out;                                  \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { op[i] = 0; continue; }                            \
        uint64_t key = (uint64_t) (WIDEN ip[i]);                             \
        int is_new;                                                           \
        fz_hash_intern(&h, key, &is_new);                                     \
        op[i] = is_new ? 0 : 1;                                               \
      }                                                                       \
    } while (0)

  /* Float variant: reproduce `==` with two value-based exceptions so the
     distinct-value judgement matches uniq / the discovery family. All NaN
     collapse to one canonical key (v != v -> NANKEY), so the second and later
     NaN in a fiber are duplicates; -0.0 == +0.0, so a zero normalizes to +0.0
     before the bitwise key. */
  #define MD_LOOP_FLOAT(T, UINT, NANKEY)                                      \
    do {                                                                      \
      const T    *ip = (const T *) p_in;                                      \
      boolean8_t *op = (boolean8_t *) p_out;                                  \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { op[i] = 0; continue; }                            \
        T v = ip[i];                                                          \
        uint64_t key;                                                         \
        if ( v != v ) { key = (NANKEY); }                                     \
        else {                                                                \
          if ( v == (T) 0 ) { v = (T) 0; }                                   \
          UINT bits;                                                          \
          memcpy(&bits, &v, sizeof(bits));                                    \
          key = (uint64_t) bits;                                              \
        }                                                                     \
        int is_new;                                                           \
        fz_hash_intern(&h, key, &is_new);                                     \
        op[i] = is_new ? 0 : 1;                                               \
      }                                                                       \
    } while (0)

  /* Object: rb_hash + rb_eql lane, per-fiber seen-set (is_new == 0 -> dup). */
  #define MD_LOOP_OBJ                                                          \
    do {                                                                      \
      const VALUE *ip = (const VALUE *) p_in;                                 \
      boolean8_t  *op = (boolean8_t *) p_out;                                 \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { op[i] = 0; continue; }                            \
        int is_new;                                                           \
        fz_hash_intern_obj(&h, ip[i], &is_new);                              \
        op[i] = is_new ? 0 : 1;                                               \
      }                                                                       \
    } while (0)

  /* Fixlen: byte-hash + memcmp lane, per-fiber seen-set. */
  #define MD_LOOP_MEM                                                          \
    do {                                                                      \
      boolean8_t *op = (boolean8_t *) p_out;                                  \
      int esz = (int) ca->bytes;                                              \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { op[i] = 0; continue; }                            \
        int is_new;                                                           \
        fz_hash_intern_mem(&h, p_in + i * esz, &is_new);                     \
        op[i] = is_new ? 0 : 1;                                               \
      }                                                                       \
    } while (0)

  CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, ca, cout, (int8_t) axis,
                                 CA_KERNEL_READ, p_in, p_out, n, m) {
    fz_hash_reset(&h);   /* independent seen-set per fiber */
    switch ( dt ) {
    case CA_INT8:   MD_LOOP(int8_t,   (int64_t));  break;
    case CA_INT16:  MD_LOOP(int16_t,  (int64_t));  break;
    case CA_INT32:  MD_LOOP(int32_t,  (int64_t));  break;
    case CA_INT64:  MD_LOOP(int64_t,  (int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  MD_LOOP(uint8_t,  (uint64_t)); break;
    case CA_UINT16: MD_LOOP(uint16_t, (uint64_t)); break;
    case CA_UINT32: MD_LOOP(uint32_t, (uint64_t)); break;
    case CA_UINT64: MD_LOOP(uint64_t, (uint64_t)); break;
    case CA_FLOAT32: MD_LOOP_FLOAT(float,  uint32_t, 0x7fc00000ULL);         break;
    case CA_FLOAT64: MD_LOOP_FLOAT(double, uint64_t, 0x7ff8000000000000ULL); break;
    case CA_OBJECT:  MD_LOOP_OBJ;                                            break;
    case CA_FIXLEN:  MD_LOOP_MEM;                                            break;
    }
  }
  #undef MD_LOOP
  #undef MD_LOOP_FLOAT
  #undef MD_LOOP_OBJ
  #undef MD_LOOP_MEM

  fz_hash_free(&h);
  return vout;
}

/* @overload __unique_flat__

   INTERNAL (CArray#unique). Collect the distinct values of self in
   first-appearance (row-major flatten) order, one linear pass, no sort. Returns
   a 1-D CArray of source data type. Masked cells do not participate.

   Numeric (integer / float): distinctness follows `==` except NaN collapses to a
   single distinct value (all NaN patterns map to one canonical hash key) and
   -0.0 == +0.0 (a zero normalizes to +0.0 for the key). The emitted level value
   is the first element seen for each key, so an appearance-first NaN or -0.0 is
   preserved.

   Object (CA_OBJECT): distinctness follows Ruby `hash` + `eql?` (the object lane
   keys on rb_hash and re-checks with rb_eql), which already folds -0.0 / +0.0
   together. It deviates from Ruby Hash in one way, aligning with the numeric
   lane: every Float NaN collapses to one distinct value (a NaN takes a fixed
   canonical key and matches any stored Float NaN), where Ruby Hash would keep
   distinct NaN objects apart.

   Fixlen (CA_FIXLEN): distinctness is byte equality (the fixlen lane keys on a
   byte-hash and re-checks with memcmp), matching Ruby String eql? for the
   uniform-width binary cells the fixlen seen-set used.
*/
static VALUE
rb_ca_unique_flat (VALUE self)
{
  CArray *ca;
  volatile VALUE face;
  self = fz_face_descend(self, &face);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__unique_flat__: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__unique_flat__: need ndim >= 1");
  }

  fz_hash h;
  fz_levels lv;
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }
  fz_levels_init(&lv, (int) ca->bytes);

  int8_t axis = (int8_t) (ca->ndim - 1);   /* innermost fiber; hash not reset =
                                              one seen-set over the whole array */
  ca_iter_state st_in;
  char       *p_in;
  boolean8_t *m;
  ca_size_t   n;

  #define UQ_LOOP(T, WIDEN)                                                   \
    do {                                                                      \
      const T *ip = (const T *) p_in;                                         \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        uint64_t key = (uint64_t) (WIDEN ip[i]);                              \
        int is_new;                                                           \
        fz_hash_intern(&h, key, &is_new);                                     \
        if ( is_new ) { fz_levels_push(&lv, &ip[i]); }                        \
      }                                                                       \
    } while (0)

  /* Float: NaN collapses to one canonical key; -0.0 / +0.0 share a key. The
     pushed level is the raw first-seen element. */
  #define UQ_LOOP_FLOAT(T, UINT, NANKEY)                                      \
    do {                                                                      \
      const T *ip = (const T *) p_in;                                         \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        T v = ip[i];                                                          \
        uint64_t key;                                                         \
        if ( v != v ) { key = (NANKEY); }                                     \
        else {                                                                \
          if ( v == (T) 0 ) { v = (T) 0; }                                    \
          UINT bits;                                                          \
          memcpy(&bits, &v, sizeof(bits));                                    \
          key = (uint64_t) bits;                                              \
        }                                                                     \
        int is_new;                                                           \
        fz_hash_intern(&h, key, &is_new);                                     \
        if ( is_new ) { fz_levels_push(&lv, &ip[i]); }                        \
      }                                                                       \
    } while (0)

  /* Object: intern the raw VALUE via the object lane (rb_hash + rb_eql); the
     pushed level is the first-seen VALUE.  The interned VALUEs stay alive through
     `self` (they are its elements), so no separate GC registration is needed. */
  #define UQ_LOOP_OBJ                                                          \
    do {                                                                       \
      const VALUE *ip = (const VALUE *) p_in;                                  \
      for ( ca_size_t i = 0; i < n; i++ ) {                                    \
        if ( m && m[i] ) { continue; }                                         \
        int is_new;                                                            \
        fz_hash_intern_obj(&h, ip[i], &is_new);                               \
        if ( is_new ) { fz_levels_push(&lv, &ip[i]); }                         \
      }                                                                        \
    } while (0)

  /* Fixlen: intern the esz-wide element bytes via the fixlen lane; the pushed
     level is a copy of the first-seen element bytes. */
  #define UQ_LOOP_MEM                                                          \
    do {                                                                       \
      int esz = (int) ca->bytes;                                               \
      for ( ca_size_t i = 0; i < n; i++ ) {                                    \
        if ( m && m[i] ) { continue; }                                         \
        const char *e = p_in + i * esz;                                        \
        int is_new;                                                            \
        fz_hash_intern_mem(&h, e, &is_new);                                    \
        if ( is_new ) { fz_levels_push(&lv, e); }                              \
      }                                                                        \
    } while (0)

  CA_FOR_EACH_FIBER_MASKED(st_in, ca, axis, CA_KERNEL_READ, p_in, n, m) {
    switch ( dt ) {
    case CA_INT8:   UQ_LOOP(int8_t,   (int64_t));  break;
    case CA_INT16:  UQ_LOOP(int16_t,  (int64_t));  break;
    case CA_INT32:  UQ_LOOP(int32_t,  (int64_t));  break;
    case CA_INT64:  UQ_LOOP(int64_t,  (int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  UQ_LOOP(uint8_t,  (uint64_t)); break;
    case CA_UINT16: UQ_LOOP(uint16_t, (uint64_t)); break;
    case CA_UINT32: UQ_LOOP(uint32_t, (uint64_t)); break;
    case CA_UINT64: UQ_LOOP(uint64_t, (uint64_t)); break;
    case CA_FLOAT32: UQ_LOOP_FLOAT(float,  uint32_t, 0x7fc00000ULL);          break;
    case CA_FLOAT64: UQ_LOOP_FLOAT(double, uint64_t, 0x7ff8000000000000ULL);  break;
    case CA_OBJECT:  UQ_LOOP_OBJ;                                             break;
    case CA_FIXLEN:  UQ_LOOP_MEM;                                             break;
    }
  }
  #undef UQ_LOOP
  #undef UQ_LOOP_FLOAT
  #undef UQ_LOOP_OBJ
  #undef UQ_LOOP_MEM

  ca_size_t k = h.n;
  fz_hash_free(&h);

  ca_size_t ldim[1];
  ldim[0] = k;
  /* CA_FIXLEN carries its element width; numeric / object use bytes = 0. */
  VALUE vlev = rb_carray_new(dt, 1, ldim, (dt == CA_FIXLEN) ? ca->bytes : 0, NULL);
  CArray *clev;
  TypedData_Get_Struct(vlev, CArray, &carray_data_type, clev);
  if ( k > 0 ) {
    memcpy(clev->ptr, lv.p, (size_t) k * (size_t) ca->bytes);
  }
  fz_levels_free(&lv);

  return fz_face_relift(vlev, face);   /* distinct *values*: give the Face back */
}

/* Intern every non-masked cell of cv into h, one seen-set over the whole array
   (the hash is not reset between fibers).  When lv is non-NULL, the first-seen
   raw element of each distinct value is pushed to it (appearance order), so the
   same pass builds both a probe set and the distinct-value list.  Dispatches the
   three key lanes exactly as the discovery family: numeric widen with all NaN
   collapsed and -0.0 == +0.0, object rb_hash + rb_eql with Float NaN collapsed,
   fixlen byte-hash + memcmp.  Used to build the probe set (is_in, set relations)
   and to accumulate distinct values (union). */
static void
fz_intern_all (fz_hash *h, CArray *cv, fz_levels *lv)
{
  int8_t dt = cv->data_type;
  int8_t vaxis = (int8_t) (cv->ndim - 1);
  ca_iter_state st_v;
  char       *p_v;
  boolean8_t *mv;
  ca_size_t   nv;

  #define FZ_IA(T, WIDEN)                                                      \
    do {                                                                       \
      const T *ip = (const T *) p_v;                                           \
      for ( ca_size_t i = 0; i < nv; i++ ) {                                   \
        if ( mv && mv[i] ) { continue; }                                       \
        uint64_t key = (uint64_t) (WIDEN ip[i]);                             \
        int is_new;                                                            \
        fz_hash_intern(h, key, &is_new);                                       \
        if ( is_new && lv ) { fz_levels_push(lv, &ip[i]); }                    \
      }                                                                        \
    } while (0)

  #define FZ_IA_FLOAT(T, UINT, NANKEY)                                         \
    do {                                                                       \
      const T *ip = (const T *) p_v;                                           \
      for ( ca_size_t i = 0; i < nv; i++ ) {                                   \
        if ( mv && mv[i] ) { continue; }                                       \
        T v = ip[i];                                                           \
        uint64_t key;                                                          \
        if ( v != v ) { key = (NANKEY); }                                      \
        else {                                                                 \
          if ( v == (T) 0 ) { v = (T) 0; }                                    \
          UINT bits;                                                           \
          memcpy(&bits, &v, sizeof(bits));                                     \
          key = (uint64_t) bits;                                               \
        }                                                                      \
        int is_new;                                                            \
        fz_hash_intern(h, key, &is_new);                                       \
        if ( is_new && lv ) { fz_levels_push(lv, &ip[i]); }                    \
      }                                                                        \
    } while (0)

  #define FZ_IA_OBJ                                                            \
    do {                                                                       \
      const VALUE *ip = (const VALUE *) p_v;                                   \
      for ( ca_size_t i = 0; i < nv; i++ ) {                                   \
        if ( mv && mv[i] ) { continue; }                                       \
        int is_new;                                                            \
        fz_hash_intern_obj(h, ip[i], &is_new);                                \
        if ( is_new && lv ) { fz_levels_push(lv, &ip[i]); }                    \
      }                                                                        \
    } while (0)

  #define FZ_IA_MEM                                                            \
    do {                                                                       \
      int esz = (int) cv->bytes;                                               \
      for ( ca_size_t i = 0; i < nv; i++ ) {                                   \
        if ( mv && mv[i] ) { continue; }                                       \
        const char *e = p_v + i * esz;                                         \
        int is_new;                                                            \
        fz_hash_intern_mem(h, e, &is_new);                                    \
        if ( is_new && lv ) { fz_levels_push(lv, e); }                         \
      }                                                                        \
    } while (0)

  CA_FOR_EACH_FIBER_MASKED(st_v, cv, vaxis, CA_KERNEL_READ, p_v, nv, mv) {
    switch ( dt ) {
    case CA_INT8:   FZ_IA(int8_t,   (int64_t));  break;
    case CA_INT16:  FZ_IA(int16_t,  (int64_t));  break;
    case CA_INT32:  FZ_IA(int32_t,  (int64_t));  break;
    case CA_INT64:  FZ_IA(int64_t,  (int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  FZ_IA(uint8_t,  (uint64_t)); break;
    case CA_UINT16: FZ_IA(uint16_t, (uint64_t)); break;
    case CA_UINT32: FZ_IA(uint32_t, (uint64_t)); break;
    case CA_UINT64: FZ_IA(uint64_t, (uint64_t)); break;
    case CA_FLOAT32: FZ_IA_FLOAT(float,  uint32_t, 0x7fc00000ULL);         break;
    case CA_FLOAT64: FZ_IA_FLOAT(double, uint64_t, 0x7ff8000000000000ULL); break;
    case CA_OBJECT:  FZ_IA_OBJ;                                            break;
    case CA_FIXLEN:  FZ_IA_MEM;                                            break;
    }
  }
  #undef FZ_IA
  #undef FZ_IA_FLOAT
  #undef FZ_IA_OBJ
  #undef FZ_IA_MEM
}

/* @overload __is_in__(values)

   INTERNAL (CArray#is_in). Return a boolean CArray of self.shape, true at each
   cell whose value appears in the set `values` (any shape; flattened to one
   seen-set).  One pass to build the set from `values`, one pass to probe self;
   no sort, peak memory O(distinct values).

   `values` must be a CArray of the same data type as self (the Ruby surface coerces
   Array / Range / other-type input first).  Masked cells of `values` do not
   enter the set.  Masked cells of self stay masked in the output (membership is
   unknown), reproducing the mask propagation of the retired `contains`
   (self.eq(v)); their boolean payload is false.

   Distinctness follows the discovery family per lane: numeric `==` with all NaN
   collapsed and -0.0 == +0.0; object rb_hash + rb_eql with Float NaN collapsed;
   fixlen byte equality (byte-hash + memcmp).
*/
static VALUE
rb_ca_is_in (VALUE self, VALUE rvalues)
{
  CArray *ca, *cv;
  volatile VALUE face;
  self     = fz_face_descend(self, &face);
  rvalues  = fz_face_reconcile(face, rvalues, "is_in");
  GetCArray(self, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__is_in__: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__is_in__: need ndim >= 1");
  }

  if ( ! RTEST(rb_obj_is_kind_of(rvalues, rb_cCArray)) ) {
    rb_raise(rb_eArgError, "__is_in__: values must be a CArray");
  }
  GetCArray(rvalues, cv);
  if ( cv->data_type != dt || (dt == CA_FIXLEN && cv->bytes != ca->bytes) ) {
    rb_raise(rb_eCADataTypeError,
             "__is_in__: values data type must match self (%d)", dt);
  }
  if ( cv->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__is_in__: values need ndim >= 1");
  }

  fz_hash h;
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }

  /* ---- Phase 1: build the seen-set from every non-masked cell of `values`. */
  fz_intern_all(&h, cv, NULL);

  /* ---- Phase 2: probe every cell of self, writing the boolean membership. */
  VALUE vout = rb_carray_new(CA_BOOLEAN, ca->ndim, ca->dim, 0, NULL);
  CArray *cout;
  GetCArray(vout, cout);
  {
    ca_iter_state st_in, st_out;
    char       *p_in, *p_out;
    boolean8_t *m;
    ca_size_t   n;
    int8_t      axis = (int8_t) (ca->ndim - 1);

    #define IN_PROBE(T, WIDEN)                                                  \
      do {                                                                      \
        const T    *ip = (const T *) p_in;                                      \
        boolean8_t *op = (boolean8_t *) p_out;                                  \
        for ( ca_size_t i = 0; i < n; i++ ) {                                   \
          if ( m && m[i] ) { op[i] = 0; continue; }                            \
          uint64_t key = (uint64_t) (WIDEN ip[i]);                             \
          op[i] = (boolean8_t) fz_hash_lookup(&h, key, NULL);                        \
        }                                                                       \
      } while (0)

    #define IN_PROBE_FLOAT(T, UINT, NANKEY)                                     \
      do {                                                                      \
        const T    *ip = (const T *) p_in;                                      \
        boolean8_t *op = (boolean8_t *) p_out;                                  \
        for ( ca_size_t i = 0; i < n; i++ ) {                                   \
          if ( m && m[i] ) { op[i] = 0; continue; }                            \
          T v = ip[i];                                                          \
          uint64_t key;                                                         \
          if ( v != v ) { key = (NANKEY); }                                     \
          else {                                                                \
            if ( v == (T) 0 ) { v = (T) 0; }                                   \
            UINT bits;                                                          \
            memcpy(&bits, &v, sizeof(bits));                                    \
            key = (uint64_t) bits;                                              \
          }                                                                     \
          op[i] = (boolean8_t) fz_hash_lookup(&h, key, NULL);                        \
        }                                                                       \
      } while (0)

    #define IN_PROBE_OBJ                                                         \
      do {                                                                      \
        const VALUE *ip = (const VALUE *) p_in;                                 \
        boolean8_t  *op = (boolean8_t *) p_out;                                 \
        for ( ca_size_t i = 0; i < n; i++ ) {                                   \
          if ( m && m[i] ) { op[i] = 0; continue; }                            \
          op[i] = (boolean8_t) fz_hash_lookup_obj(&h, ip[i], NULL);                  \
        }                                                                       \
      } while (0)

    #define IN_PROBE_MEM                                                         \
      do {                                                                      \
        boolean8_t *op = (boolean8_t *) p_out;                                  \
        int esz = (int) ca->bytes;                                              \
        for ( ca_size_t i = 0; i < n; i++ ) {                                   \
          if ( m && m[i] ) { op[i] = 0; continue; }                            \
          op[i] = (boolean8_t) fz_hash_lookup_mem(&h, p_in + i * esz, NULL);         \
        }                                                                       \
      } while (0)

    CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, ca, cout, axis,
                                   CA_KERNEL_READ, p_in, p_out, n, m) {
      switch ( dt ) {
      case CA_INT8:   IN_PROBE(int8_t,   (int64_t));  break;
      case CA_INT16:  IN_PROBE(int16_t,  (int64_t));  break;
      case CA_INT32:  IN_PROBE(int32_t,  (int64_t));  break;
      case CA_INT64:  IN_PROBE(int64_t,  (int64_t));  break;
      case CA_BOOLEAN: case CA_UINT8:  IN_PROBE(uint8_t,  (uint64_t)); break;
      case CA_UINT16: IN_PROBE(uint16_t, (uint64_t)); break;
      case CA_UINT32: IN_PROBE(uint32_t, (uint64_t)); break;
      case CA_UINT64: IN_PROBE(uint64_t, (uint64_t)); break;
      case CA_FLOAT32: IN_PROBE_FLOAT(float,  uint32_t, 0x7fc00000ULL);         break;
      case CA_FLOAT64: IN_PROBE_FLOAT(double, uint64_t, 0x7ff8000000000000ULL); break;
      case CA_OBJECT:  IN_PROBE_OBJ;                                            break;
      case CA_FIXLEN:  IN_PROBE_MEM;                                            break;
      }
    }
    #undef IN_PROBE
    #undef IN_PROBE_FLOAT
    #undef IN_PROBE_OBJ
    #undef IN_PROBE_MEM
  }

  fz_hash_free(&h);

  /* Masked self cells stay masked in the output (membership unknown), matching
     the retired contains (self.eq(v)) mask propagation. */
  if ( ca_has_mask(ca) ) { ca_copy_mask(cout, ca); }

  return vout;
}

/* @overload __locate_addr__(ref)

   INTERNAL (CArray#locate_addr, exact hash lane). For each cell of self, the
   row-major flat address into `ref` where that value first occurs, or UNDEF
   where the value is absent from `ref`.  Output is CA_INT64 of self.shape.  One
   pass builds a value -> first-address map from `ref`, one pass probes self; no
   sort, peak memory O(distinct ref values).  Numeric / object / fixlen all work
   through the discovery-family lanes (NaN collapse, rb_hash + rb_eql, byte
   equality).

   `ref` must be a CArray of the same data type as self (the Ruby surface coerces
   first).  Masked cells of `ref` do not enter the map but still occupy their
   flat address (position counts).  Masked cells of self, and cells whose value
   is absent from `ref`, are UNDEF in the output.  "First" occurrence is
   appearance order (matching the discovery family); on a `ref` with duplicate
   values this is the earliest address, which can differ from the bsearch lane. */
static VALUE
rb_ca_locate_addr (VALUE self, VALUE rref)
{
  CArray *ca, *cr;
  /* Here the *reference* is the argument (self is the query being placed on
     rref), so the gate runs the other way round: rref reconciles self.  The
     output is an address, so nothing is lifted back. */
  {
    volatile VALUE ref_face;
    rref = fz_face_descend(rref, &ref_face);
    self = fz_face_reconcile(ref_face, self, "locate_addr");
  }
  GetCArray(self, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__locate_addr__: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__locate_addr__: need ndim >= 1");
  }
  if ( ! RTEST(rb_obj_is_kind_of(rref, rb_cCArray)) ) {
    rb_raise(rb_eArgError, "__locate_addr__: ref must be a CArray");
  }
  GetCArray(rref, cr);
  if ( cr->data_type != dt || (dt == CA_FIXLEN && cr->bytes != ca->bytes) ) {
    rb_raise(rb_eCADataTypeError,
             "__locate_addr__: ref data type must match self (%d)", dt);
  }
  if ( cr->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__locate_addr__: ref need ndim >= 1");
  }

  fz_hash h;
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }

  /* addr.p[code] = flat address of the first (appearance-order) occurrence of
     the ref value carrying dense code `code`.  Codes are assigned 0,1,2,... in
     insertion order, so pushing on is_new fills addr.p in code order. */
  fz_levels addr;
  fz_levels_init(&addr, (int) sizeof(int64_t));

  /* ---- Phase 1: build value -> first-address map from ref (row-major). ----- */
  {
    ca_iter_state st_r;
    char       *p_r;
    boolean8_t *mr;
    ca_size_t   nr;
    int8_t      raxis = (int8_t) (cr->ndim - 1);
    ca_size_t   base  = 0;   /* row-major flat offset of the current fiber */

    #define LOC_BUILD(T, WIDEN)                                                 \
      do {                                                                      \
        const T *ip = (const T *) p_r;                                          \
        for ( ca_size_t i = 0; i < nr; i++ ) {                                  \
          if ( mr && mr[i] ) { continue; }                                     \
          uint64_t key = (uint64_t) (WIDEN ip[i]);                            \
          int is_new;                                                           \
          fz_hash_intern(&h, key, &is_new);                                     \
          if ( is_new ) { int64_t a = (int64_t) (base + i);                     \
                          fz_levels_push(&addr, &a); }                          \
        }                                                                       \
      } while (0)

    #define LOC_BUILD_FLOAT(T, UINT, NANKEY)                                    \
      do {                                                                      \
        const T *ip = (const T *) p_r;                                          \
        for ( ca_size_t i = 0; i < nr; i++ ) {                                  \
          if ( mr && mr[i] ) { continue; }                                     \
          T v = ip[i];                                                          \
          uint64_t key;                                                         \
          if ( v != v ) { key = (NANKEY); }                                     \
          else {                                                                \
            if ( v == (T) 0 ) { v = (T) 0; }                                   \
            UINT bits;                                                          \
            memcpy(&bits, &v, sizeof(bits));                                    \
            key = (uint64_t) bits;                                              \
          }                                                                     \
          int is_new;                                                           \
          fz_hash_intern(&h, key, &is_new);                                     \
          if ( is_new ) { int64_t a = (int64_t) (base + i);                     \
                          fz_levels_push(&addr, &a); }                          \
        }                                                                       \
      } while (0)

    #define LOC_BUILD_OBJ                                                        \
      do {                                                                      \
        const VALUE *ip = (const VALUE *) p_r;                                  \
        for ( ca_size_t i = 0; i < nr; i++ ) {                                  \
          if ( mr && mr[i] ) { continue; }                                     \
          int is_new;                                                           \
          fz_hash_intern_obj(&h, ip[i], &is_new);                              \
          if ( is_new ) { int64_t a = (int64_t) (base + i);                     \
                          fz_levels_push(&addr, &a); }                          \
        }                                                                       \
      } while (0)

    #define LOC_BUILD_MEM                                                        \
      do {                                                                      \
        int esz = (int) cr->bytes;                                              \
        for ( ca_size_t i = 0; i < nr; i++ ) {                                  \
          if ( mr && mr[i] ) { continue; }                                     \
          int is_new;                                                           \
          fz_hash_intern_mem(&h, p_r + i * esz, &is_new);                      \
          if ( is_new ) { int64_t a = (int64_t) (base + i);                     \
                          fz_levels_push(&addr, &a); }                          \
        }                                                                       \
      } while (0)

    CA_FOR_EACH_FIBER_MASKED(st_r, cr, raxis, CA_KERNEL_READ, p_r, nr, mr) {
      switch ( dt ) {
      case CA_INT8:   LOC_BUILD(int8_t,   (int64_t));  break;
      case CA_INT16:  LOC_BUILD(int16_t,  (int64_t));  break;
      case CA_INT32:  LOC_BUILD(int32_t,  (int64_t));  break;
      case CA_INT64:  LOC_BUILD(int64_t,  (int64_t));  break;
      case CA_BOOLEAN: case CA_UINT8:  LOC_BUILD(uint8_t,  (uint64_t)); break;
      case CA_UINT16: LOC_BUILD(uint16_t, (uint64_t)); break;
      case CA_UINT32: LOC_BUILD(uint32_t, (uint64_t)); break;
      case CA_UINT64: LOC_BUILD(uint64_t, (uint64_t)); break;
      case CA_FLOAT32: LOC_BUILD_FLOAT(float,  uint32_t, 0x7fc00000ULL);         break;
      case CA_FLOAT64: LOC_BUILD_FLOAT(double, uint64_t, 0x7ff8000000000000ULL); break;
      case CA_OBJECT:  LOC_BUILD_OBJ;                                            break;
      case CA_FIXLEN:  LOC_BUILD_MEM;                                            break;
      }
      base += nr;
    }
    #undef LOC_BUILD
    #undef LOC_BUILD_FLOAT
    #undef LOC_BUILD_OBJ
    #undef LOC_BUILD_MEM
  }

  /* ---- Phase 2: probe every cell of self, writing the int64 address + UNDEF. */
  VALUE vout = rb_carray_new(CA_INT64, ca->ndim, ca->dim, 0, NULL);
  CArray *cout;
  GetCArray(vout, cout);
  int64_t    *out = (int64_t *) cout->ptr;
  boolean8_t *um  = ALLOC_N(boolean8_t, ca->elements);   /* undef flags scratch */
  ca_size_t   n_undef = 0;
  {
    ca_iter_state st_in;
    char       *p_in;
    boolean8_t *m;
    ca_size_t   n;
    int8_t      axis = (int8_t) (ca->ndim - 1);
    ca_size_t   base = 0;

    #define LOC_PROBE(T, WIDEN)                                                 \
      do {                                                                      \
        const T *ip = (const T *) p_in;                                         \
        const int64_t *ab = (const int64_t *) addr.p;                           \
        for ( ca_size_t i = 0; i < n; i++ ) {                                   \
          ca_size_t o = base + i;                                               \
          if ( m && m[i] ) { out[o] = 0; um[o] = 1; n_undef++; continue; }     \
          uint64_t key = (uint64_t) (WIDEN ip[i]);                            \
          int32_t code;                                                         \
          if ( fz_hash_lookup(&h, key, &code) ) { out[o] = ab[code]; um[o] = 0; } \
          else { out[o] = 0; um[o] = 1; n_undef++; }                            \
        }                                                                       \
      } while (0)

    #define LOC_PROBE_FLOAT(T, UINT, NANKEY)                                    \
      do {                                                                      \
        const T *ip = (const T *) p_in;                                         \
        const int64_t *ab = (const int64_t *) addr.p;                           \
        for ( ca_size_t i = 0; i < n; i++ ) {                                   \
          ca_size_t o = base + i;                                               \
          if ( m && m[i] ) { out[o] = 0; um[o] = 1; n_undef++; continue; }     \
          T v = ip[i];                                                          \
          uint64_t key;                                                         \
          if ( v != v ) { key = (NANKEY); }                                     \
          else {                                                                \
            if ( v == (T) 0 ) { v = (T) 0; }                                   \
            UINT bits;                                                          \
            memcpy(&bits, &v, sizeof(bits));                                    \
            key = (uint64_t) bits;                                              \
          }                                                                     \
          int32_t code;                                                         \
          if ( fz_hash_lookup(&h, key, &code) ) { out[o] = ab[code]; um[o] = 0; } \
          else { out[o] = 0; um[o] = 1; n_undef++; }                            \
        }                                                                       \
      } while (0)

    #define LOC_PROBE_OBJ                                                        \
      do {                                                                      \
        const VALUE *ip = (const VALUE *) p_in;                                 \
        const int64_t *ab = (const int64_t *) addr.p;                           \
        for ( ca_size_t i = 0; i < n; i++ ) {                                   \
          ca_size_t o = base + i;                                               \
          if ( m && m[i] ) { out[o] = 0; um[o] = 1; n_undef++; continue; }     \
          int32_t code;                                                         \
          if ( fz_hash_lookup_obj(&h, ip[i], &code) ) { out[o] = ab[code]; um[o] = 0; } \
          else { out[o] = 0; um[o] = 1; n_undef++; }                            \
        }                                                                       \
      } while (0)

    #define LOC_PROBE_MEM                                                        \
      do {                                                                      \
        const int64_t *ab = (const int64_t *) addr.p;                           \
        int esz = (int) ca->bytes;                                              \
        for ( ca_size_t i = 0; i < n; i++ ) {                                   \
          ca_size_t o = base + i;                                               \
          if ( m && m[i] ) { out[o] = 0; um[o] = 1; n_undef++; continue; }     \
          int32_t code;                                                         \
          if ( fz_hash_lookup_mem(&h, p_in + i * esz, &code) ) { out[o] = ab[code]; um[o] = 0; } \
          else { out[o] = 0; um[o] = 1; n_undef++; }                            \
        }                                                                       \
      } while (0)

    CA_FOR_EACH_FIBER_MASKED(st_in, ca, axis, CA_KERNEL_READ, p_in, n, m) {
      switch ( dt ) {
      case CA_INT8:   LOC_PROBE(int8_t,   (int64_t));  break;
      case CA_INT16:  LOC_PROBE(int16_t,  (int64_t));  break;
      case CA_INT32:  LOC_PROBE(int32_t,  (int64_t));  break;
      case CA_INT64:  LOC_PROBE(int64_t,  (int64_t));  break;
      case CA_BOOLEAN: case CA_UINT8:  LOC_PROBE(uint8_t,  (uint64_t)); break;
      case CA_UINT16: LOC_PROBE(uint16_t, (uint64_t)); break;
      case CA_UINT32: LOC_PROBE(uint32_t, (uint64_t)); break;
      case CA_UINT64: LOC_PROBE(uint64_t, (uint64_t)); break;
      case CA_FLOAT32: LOC_PROBE_FLOAT(float,  uint32_t, 0x7fc00000ULL);         break;
      case CA_FLOAT64: LOC_PROBE_FLOAT(double, uint64_t, 0x7ff8000000000000ULL); break;
      case CA_OBJECT:  LOC_PROBE_OBJ;                                            break;
      case CA_FIXLEN:  LOC_PROBE_MEM;                                            break;
      }
      base += n;
    }
    #undef LOC_PROBE
    #undef LOC_PROBE_FLOAT
    #undef LOC_PROBE_OBJ
    #undef LOC_PROBE_MEM
  }

  fz_hash_free(&h);
  fz_levels_free(&addr);

  /* Attach an output mask only when some cell is UNDEF (miss or masked self), so
     an all-hit locate stays mask-free. */
  if ( n_undef > 0 ) {
    ca_create_mask(cout);
    memcpy(cout->mask->ptr, um, (size_t) ca->elements);
  }
  xfree(um);

  return vout;
}

/* Shared body of __intersection__ (keep_when_hit = 1) and __difference__
   (keep_when_hit = 0): the distinct values of self that are (resp. are not)
   present in `other`, in self's first-appearance order, as a 1-D CArray of
   self's data type.  Two seen-sets: `hoth` built from `other` is the probe set;
   `hself` dedups self so each distinct value is decided once.  Masked cells of
   either array do not participate.  Distinctness is the discovery family's per
   lane (numeric `==` + NaN collapse + -0.0 == +0.0, object hash/eql? + NaN
   collapse, fixlen byte equality). */
static VALUE
fz_set_relation (VALUE self, VALUE rother, int keep_when_hit)
{
  CArray *ca, *co;
  volatile VALUE face;
  self   = fz_face_descend(self, &face);
  rother = fz_face_reconcile(face, rother, "set relation");
  GetCArray(self, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "set relation: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "set relation: need ndim >= 1");
  }
  if ( ! RTEST(rb_obj_is_kind_of(rother, rb_cCArray)) ) {
    rb_raise(rb_eArgError, "set relation: other must be a CArray");
  }
  GetCArray(rother, co);
  if ( co->data_type != dt || (dt == CA_FIXLEN && co->bytes != ca->bytes) ) {
    rb_raise(rb_eCADataTypeError, "set relation: other data type must match self (%d)", dt);
  }
  if ( co->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "set relation: other need ndim >= 1");
  }

  fz_hash hoth, hself;
  if ( dt == CA_OBJECT ) {
    fz_hash_init_obj(&hoth);  fz_hash_init_obj(&hself);
  }
  else if ( dt == CA_FIXLEN ) {
    fz_hash_init_mem(&hoth, (int) ca->bytes);  fz_hash_init_mem(&hself, (int) ca->bytes);
  }
  else {
    fz_hash_init(&hoth);  fz_hash_init(&hself);
  }

  fz_levels lv;
  fz_levels_init(&lv, (int) ca->bytes);

  /* Build the probe set from every non-masked cell of other. */
  fz_intern_all(&hoth, co, NULL);

  /* Walk self: hself dedups, so each distinct self value is decided once; keep
     it when its membership in other equals keep_when_hit. */
  int8_t axis = (int8_t) (ca->ndim - 1);
  ca_iter_state st;
  char       *p;
  boolean8_t *m;
  ca_size_t   n;

  #define SR(T, WIDEN)                                                         \
    do {                                                                       \
      const T *ip = (const T *) p;                                             \
      for ( ca_size_t i = 0; i < n; i++ ) {                                    \
        if ( m && m[i] ) { continue; }                                         \
        uint64_t key = (uint64_t) (WIDEN ip[i]);                             \
        int is_new;                                                            \
        fz_hash_intern(&hself, key, &is_new);                                  \
        if ( is_new && fz_hash_lookup(&hoth, key, NULL) == keep_when_hit ) {   \
          fz_levels_push(&lv, &ip[i]);                                         \
        }                                                                      \
      }                                                                        \
    } while (0)

  #define SR_FLOAT(T, UINT, NANKEY)                                            \
    do {                                                                       \
      const T *ip = (const T *) p;                                             \
      for ( ca_size_t i = 0; i < n; i++ ) {                                    \
        if ( m && m[i] ) { continue; }                                         \
        T v = ip[i];                                                           \
        uint64_t key;                                                          \
        if ( v != v ) { key = (NANKEY); }                                      \
        else {                                                                 \
          if ( v == (T) 0 ) { v = (T) 0; }                                    \
          UINT bits;                                                           \
          memcpy(&bits, &v, sizeof(bits));                                     \
          key = (uint64_t) bits;                                               \
        }                                                                      \
        int is_new;                                                            \
        fz_hash_intern(&hself, key, &is_new);                                  \
        if ( is_new && fz_hash_lookup(&hoth, key, NULL) == keep_when_hit ) {   \
          fz_levels_push(&lv, &ip[i]);                                         \
        }                                                                      \
      }                                                                        \
    } while (0)

  #define SR_OBJ                                                               \
    do {                                                                       \
      const VALUE *ip = (const VALUE *) p;                                     \
      for ( ca_size_t i = 0; i < n; i++ ) {                                    \
        if ( m && m[i] ) { continue; }                                         \
        int is_new;                                                            \
        fz_hash_intern_obj(&hself, ip[i], &is_new);                           \
        if ( is_new && fz_hash_lookup_obj(&hoth, ip[i], NULL) == keep_when_hit ) { \
          fz_levels_push(&lv, &ip[i]);                                         \
        }                                                                      \
      }                                                                        \
    } while (0)

  #define SR_MEM                                                               \
    do {                                                                       \
      int esz = (int) ca->bytes;                                               \
      for ( ca_size_t i = 0; i < n; i++ ) {                                    \
        if ( m && m[i] ) { continue; }                                         \
        const char *e = p + i * esz;                                           \
        int is_new;                                                            \
        fz_hash_intern_mem(&hself, e, &is_new);                               \
        if ( is_new && fz_hash_lookup_mem(&hoth, e, NULL) == keep_when_hit ) { \
          fz_levels_push(&lv, e);                                              \
        }                                                                      \
      }                                                                        \
    } while (0)

  CA_FOR_EACH_FIBER_MASKED(st, ca, axis, CA_KERNEL_READ, p, n, m) {
    switch ( dt ) {
    case CA_INT8:   SR(int8_t,   (int64_t));  break;
    case CA_INT16:  SR(int16_t,  (int64_t));  break;
    case CA_INT32:  SR(int32_t,  (int64_t));  break;
    case CA_INT64:  SR(int64_t,  (int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  SR(uint8_t,  (uint64_t)); break;
    case CA_UINT16: SR(uint16_t, (uint64_t)); break;
    case CA_UINT32: SR(uint32_t, (uint64_t)); break;
    case CA_UINT64: SR(uint64_t, (uint64_t)); break;
    case CA_FLOAT32: SR_FLOAT(float,  uint32_t, 0x7fc00000ULL);         break;
    case CA_FLOAT64: SR_FLOAT(double, uint64_t, 0x7ff8000000000000ULL); break;
    case CA_OBJECT:  SR_OBJ;                                            break;
    case CA_FIXLEN:  SR_MEM;                                            break;
    }
  }
  #undef SR
  #undef SR_FLOAT
  #undef SR_OBJ
  #undef SR_MEM

  ca_size_t k = lv.n;
  fz_hash_free(&hoth);
  fz_hash_free(&hself);

  ca_size_t ldim[1];
  ldim[0] = k;
  VALUE vlev = rb_carray_new(dt, 1, ldim, (dt == CA_FIXLEN) ? ca->bytes : 0, NULL);
  CArray *clev;
  GetCArray(vlev, clev);
  if ( k > 0 ) {
    memcpy(clev->ptr, lv.p, (size_t) k * (size_t) ca->bytes);
  }
  fz_levels_free(&lv);

  return fz_face_relift(vlev, face);   /* set *values*: give the Face back */
}

/* @overload __intersection__(other)
   INTERNAL (CArray#intersection). 1-D CArray of the distinct values present in
   both self and other, in self's first-appearance order. */
static VALUE
rb_ca_intersection (VALUE self, VALUE rother)
{
  return fz_set_relation(self, rother, 1);
}

/* @overload __difference__(other)
   INTERNAL (CArray#difference). 1-D CArray of the distinct values in self that
   are absent from other, in self's first-appearance order. */
static VALUE
rb_ca_difference (VALUE self, VALUE rother)
{
  return fz_set_relation(self, rother, 0);
}

/* @overload __union__(other)
   INTERNAL (CArray#union). 1-D CArray of the distinct values appearing in either
   self or other, in self-then-other first-appearance order.  One seen-set spans
   both arrays; each distinct value is pushed on its first appearance (self's
   distinct values first, then other's not-yet-seen ones).  Masked cells of
   either array do not participate. */
static VALUE
rb_ca_set_union (VALUE self, VALUE rother)
{
  CArray *ca, *co;
  volatile VALUE face;
  self   = fz_face_descend(self, &face);
  rother = fz_face_reconcile(face, rother, "union");
  GetCArray(self, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__union__: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__union__: need ndim >= 1");
  }
  if ( ! RTEST(rb_obj_is_kind_of(rother, rb_cCArray)) ) {
    rb_raise(rb_eArgError, "__union__: other must be a CArray");
  }
  GetCArray(rother, co);
  if ( co->data_type != dt || (dt == CA_FIXLEN && co->bytes != ca->bytes) ) {
    rb_raise(rb_eCADataTypeError, "__union__: other data type must match self (%d)", dt);
  }
  if ( co->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__union__: other need ndim >= 1");
  }

  fz_hash h;
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }

  fz_levels lv;
  fz_levels_init(&lv, (int) ca->bytes);

  fz_intern_all(&h, ca, &lv);   /* self's distinct values, appearance order */
  fz_intern_all(&h, co, &lv);   /* + other's not-yet-seen distinct values   */

  ca_size_t k = lv.n;
  fz_hash_free(&h);

  ca_size_t ldim[1];
  ldim[0] = k;
  VALUE vlev = rb_carray_new(dt, 1, ldim, (dt == CA_FIXLEN) ? ca->bytes : 0, NULL);
  CArray *clev;
  GetCArray(vlev, clev);
  if ( k > 0 ) {
    memcpy(clev->ptr, lv.p, (size_t) k * (size_t) ca->bytes);
  }
  fz_levels_free(&lv);

  return fz_face_relift(vlev, face);   /* set *values*: give the Face back */
}

/* @overload __value_counts_flat__

   INTERNAL (CArray#value_counts). Collect the distinct values of self in
   first-appearance (row-major flatten) order together with the number of times
   each occurs, one linear pass, no sort.
   Returns [levels, counts]:
     levels = 1-D CArray of source data type, the k distinct values in appearance
              order (identical to __unique_flat__).
     counts = 1-D CA_INT64 of length k, counts[i] = occurrences of levels[i].
   Masked cells do not participate (skipped, not counted). Numeric distinctness
   follows the discovery family: all NaN collapse to one distinct value (their
   counts add up) and -0.0 == +0.0. Object keys on rb_hash + rb_eql and fixlen on
   a byte-hash + memcmp, reproducing Ruby Hash distinctness; the object lane also
   collapses every Float NaN to one value (their counts add up, as numeric does).
*/
static VALUE
rb_ca_value_counts_flat (VALUE self)
{
  CArray *ca;
  volatile VALUE face;
  self = fz_face_descend(self, &face);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__value_counts_flat__: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__value_counts_flat__: need ndim >= 1");
  }

  fz_hash h;
  fz_levels lv;   /* distinct values, appearance order */
  fz_levels ct;   /* int64 count per code (code == push index) */
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }
  fz_levels_init(&lv, (int) ca->bytes);
  fz_levels_init(&ct, (int) sizeof(int64_t));

  int8_t axis = (int8_t) (ca->ndim - 1);   /* one seen-set over the whole array */
  ca_iter_state st_in;
  char       *p_in;
  boolean8_t *m;
  ca_size_t   n;

  #define VC_LOOP(T, WIDEN)                                                   \
    do {                                                                      \
      const T *ip = (const T *) p_in;                                         \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        uint64_t key = (uint64_t) (WIDEN ip[i]);                              \
        int is_new;                                                           \
        int32_t code = fz_hash_intern(&h, key, &is_new);                      \
        if ( is_new ) {                                                       \
          int64_t one = 1;                                                    \
          fz_levels_push(&lv, &ip[i]);                                        \
          fz_levels_push(&ct, &one);                                          \
        } else {                                                             \
          ((int64_t *) ct.p)[code]++;                                         \
        }                                                                     \
      }                                                                       \
    } while (0)

  #define VC_LOOP_FLOAT(T, UINT, NANKEY)                                      \
    do {                                                                      \
      const T *ip = (const T *) p_in;                                         \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        T v = ip[i];                                                          \
        uint64_t key;                                                         \
        if ( v != v ) { key = (NANKEY); }                                     \
        else {                                                                \
          if ( v == (T) 0 ) { v = (T) 0; }                                    \
          UINT bits;                                                          \
          memcpy(&bits, &v, sizeof(bits));                                    \
          key = (uint64_t) bits;                                              \
        }                                                                     \
        int is_new;                                                           \
        int32_t code = fz_hash_intern(&h, key, &is_new);                      \
        if ( is_new ) {                                                       \
          int64_t one = 1;                                                    \
          fz_levels_push(&lv, &ip[i]);                                        \
          fz_levels_push(&ct, &one);                                          \
        } else {                                                             \
          ((int64_t *) ct.p)[code]++;                                         \
        }                                                                     \
      }                                                                       \
    } while (0)

  /* Object: rb_hash + rb_eql lane; the level is the first-seen VALUE. */
  #define VC_LOOP_OBJ                                                         \
    do {                                                                      \
      const VALUE *ip = (const VALUE *) p_in;                                 \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        int is_new;                                                           \
        int32_t code = fz_hash_intern_obj(&h, ip[i], &is_new);               \
        if ( is_new ) {                                                       \
          int64_t one = 1;                                                    \
          fz_levels_push(&lv, &ip[i]);                                        \
          fz_levels_push(&ct, &one);                                          \
        } else {                                                             \
          ((int64_t *) ct.p)[code]++;                                         \
        }                                                                     \
      }                                                                       \
    } while (0)

  /* Fixlen: byte-hash + memcmp lane; the level is the first-seen element bytes. */
  #define VC_LOOP_MEM                                                         \
    do {                                                                      \
      int esz = (int) ca->bytes;                                              \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        const char *e = p_in + i * esz;                                       \
        int is_new;                                                           \
        int32_t code = fz_hash_intern_mem(&h, e, &is_new);                    \
        if ( is_new ) {                                                       \
          int64_t one = 1;                                                    \
          fz_levels_push(&lv, e);                                             \
          fz_levels_push(&ct, &one);                                          \
        } else {                                                             \
          ((int64_t *) ct.p)[code]++;                                         \
        }                                                                     \
      }                                                                       \
    } while (0)

  CA_FOR_EACH_FIBER_MASKED(st_in, ca, axis, CA_KERNEL_READ, p_in, n, m) {
    switch ( dt ) {
    case CA_INT8:   VC_LOOP(int8_t,   (int64_t));  break;
    case CA_INT16:  VC_LOOP(int16_t,  (int64_t));  break;
    case CA_INT32:  VC_LOOP(int32_t,  (int64_t));  break;
    case CA_INT64:  VC_LOOP(int64_t,  (int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  VC_LOOP(uint8_t,  (uint64_t)); break;
    case CA_UINT16: VC_LOOP(uint16_t, (uint64_t)); break;
    case CA_UINT32: VC_LOOP(uint32_t, (uint64_t)); break;
    case CA_UINT64: VC_LOOP(uint64_t, (uint64_t)); break;
    case CA_FLOAT32: VC_LOOP_FLOAT(float,  uint32_t, 0x7fc00000ULL);          break;
    case CA_FLOAT64: VC_LOOP_FLOAT(double, uint64_t, 0x7ff8000000000000ULL);  break;
    case CA_OBJECT:  VC_LOOP_OBJ;                                             break;
    case CA_FIXLEN:  VC_LOOP_MEM;                                             break;
    }
  }
  #undef VC_LOOP
  #undef VC_LOOP_FLOAT
  #undef VC_LOOP_OBJ
  #undef VC_LOOP_MEM

  ca_size_t k = h.n;
  fz_hash_free(&h);

  ca_size_t ldim[1];
  ldim[0] = k;
  /* CA_FIXLEN carries its element width; numeric / object use bytes = 0. */
  VALUE vlev = rb_carray_new(dt, 1, ldim, (dt == CA_FIXLEN) ? ca->bytes : 0, NULL);
  CArray *clev;
  TypedData_Get_Struct(vlev, CArray, &carray_data_type, clev);
  VALUE vcnt = rb_carray_new(CA_INT64, 1, ldim, 0, NULL);
  CArray *ccnt;
  TypedData_Get_Struct(vcnt, CArray, &carray_data_type, ccnt);
  if ( k > 0 ) {
    memcpy(clev->ptr, lv.p, (size_t) k * (size_t) ca->bytes);
    memcpy(ccnt->ptr, ct.p, (size_t) k * sizeof(int64_t));
  }
  fz_levels_free(&lv);
  fz_levels_free(&ct);

  /* values carry the Face, counts stay plain int64 */
  return rb_ary_new3(2, fz_face_relift(vlev, face), vcnt);
}

/* @overload __nunique__(axis, keep_axis)

   INTERNAL (CArray#nunique). Count the distinct values along axis, one linear
   pass per fiber with an independent seen-set. Returns a reduced
   CA_INT64 CArray of self.shape with axis removed (or kept as length-1 when
   keep_axis). Masked cells do not participate; an all-masked fiber counts 0
   (an empty set has zero distinct values, not UNDEF -- nunique has identity 0).
   Numeric distinctness collapses all NaN to one value and treats -0.0 == +0.0;
   object keys on rb_hash + rb_eql and fixlen on a byte-hash + memcmp, reproducing
   Ruby Hash distinctness; the object lane also collapses every Float NaN to one.
*/
static VALUE
rb_ca_nunique (VALUE self, VALUE vaxis, VALUE vkeep)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__nunique__: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__nunique__: need ndim >= 1");
  }

  int axis = NUM2INT(vaxis);
  if ( axis < 0 || axis >= ca->ndim ) {
    rb_raise(rb_eArgError, "__nunique__: axis %d out of range", axis);
  }
  int keep_axis = RTEST(vkeep);

  int8_t ax = (int8_t) axis;
  VALUE vout = rb_ca_new_reduced(self, &ax, 1, CA_INT64, keep_axis);
  CArray *cout;
  TypedData_Get_Struct(vout, CArray, &carray_data_type, cout);
  int64_t *op = (int64_t *) cout->ptr;

  fz_hash h;
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }

  ca_iter_state st;
  int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, &ax, 1, 0);
  if ( rc != CA_ITER_OK ) {
    fz_hash_free(&h);
    rb_raise(rb_eRuntimeError, "__nunique__: kernel_iterator init failed rc=%d", rc);
  }

  char       *p;
  boolean8_t *m;
  ca_size_t   out_i = 0;
  ca_size_t   dummy;   /* CA_SLAB_REDUCE_T needs an acc lvalue; unused here */

  /* Intern each element into the per-fiber hash; the accumulator is a no-op.
     WIDEN sign- or zero-extends the integer element; float normalizes NaN and
     -0.0 before the bitwise key. */
  #define NU_INT(WIDEN)                                                       \
    do { int _n; fz_hash_intern(&h, (uint64_t) ((WIDEN) v), &_n); } while (0)
  #define NU_FLOAT(T, UINT, NANKEY)                                           \
    do {                                                                      \
      T _v = v;                                                               \
      uint64_t _key;                                                          \
      if ( _v != _v ) { _key = (NANKEY); }                                    \
      else {                                                                  \
        if ( _v == (T) 0 ) { _v = (T) 0; }                                    \
        UINT _b;                                                              \
        memcpy(&_b, &_v, sizeof(_b));                                         \
        _key = (uint64_t) _b;                                                 \
      }                                                                       \
      int _n; fz_hash_intern(&h, _key, &_n);                                  \
    } while (0)
  /* Object: intern the VALUE via the object lane (v is bound by the macro). */
  #define NU_OBJ                                                              \
    do { int _n; fz_hash_intern_obj(&h, v, &_n); } while (0)

  /* Fixlen has no scalar element type for CA_SLAB_REDUCE_T, so walk the slab by
     multi-index (order-independent -- nunique only counts distinct) and intern
     each esz-wide element via the fixlen lane. */
  #define NU_MEM_WALK                                                         \
    do {                                                                      \
      int8_t K = st.slab_ndim;                                               \
      ca_size_t idx[CA_RANK_MAX] = { 0 };                                    \
      ca_size_t total = st.slab_elements;                                    \
      for ( ca_size_t e = 0; e < total; e++ ) {                             \
        ca_size_t doff = 0, moff = 0;                                        \
        for ( int8_t kk = 0; kk < K; kk++ ) {                               \
          doff += idx[kk] * st.slab_strides[kk];                            \
          moff += idx[kk] * st.slab_mask_strides[kk];                       \
        }                                                                    \
        if ( ! (m && m[moff]) ) {                                           \
          int _n; fz_hash_intern_mem(&h, p + doff, &_n);                    \
        }                                                                    \
        for ( int8_t kk = (int8_t)(K - 1); kk >= 0; kk-- ) {               \
          if ( ++idx[kk] < st.slab_dims[kk] ) break;                        \
          idx[kk] = 0;                                                      \
        }                                                                    \
      }                                                                      \
    } while (0)

  while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
    fz_hash_reset(&h);   /* independent seen-set per fiber */
    switch ( dt ) {
    case CA_INT8:   CA_SLAB_REDUCE_T(int8_t,   st, p, m, dummy, 0, NU_INT(int64_t));  break;
    case CA_INT16:  CA_SLAB_REDUCE_T(int16_t,  st, p, m, dummy, 0, NU_INT(int64_t));  break;
    case CA_INT32:  CA_SLAB_REDUCE_T(int32_t,  st, p, m, dummy, 0, NU_INT(int64_t));  break;
    case CA_INT64:  CA_SLAB_REDUCE_T(int64_t,  st, p, m, dummy, 0, NU_INT(int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  CA_SLAB_REDUCE_T(uint8_t,  st, p, m, dummy, 0, NU_INT(uint64_t)); break;
    case CA_UINT16: CA_SLAB_REDUCE_T(uint16_t, st, p, m, dummy, 0, NU_INT(uint64_t)); break;
    case CA_UINT32: CA_SLAB_REDUCE_T(uint32_t, st, p, m, dummy, 0, NU_INT(uint64_t)); break;
    case CA_UINT64: CA_SLAB_REDUCE_T(uint64_t, st, p, m, dummy, 0, NU_INT(uint64_t)); break;
    case CA_FLOAT32:
      CA_SLAB_REDUCE_T(float,  st, p, m, dummy, 0, NU_FLOAT(float,  uint32_t, 0x7fc00000ULL));
      break;
    case CA_FLOAT64:
      CA_SLAB_REDUCE_T(double, st, p, m, dummy, 0, NU_FLOAT(double, uint64_t, 0x7ff8000000000000ULL));
      break;
    case CA_OBJECT: CA_SLAB_REDUCE_T(VALUE, st, p, m, dummy, 0, NU_OBJ); break;
    case CA_FIXLEN: NU_MEM_WALK;                                          break;
    }
    op[out_i++] = (int64_t) h.n;
  }
  #undef NU_INT
  #undef NU_FLOAT
  #undef NU_OBJ
  #undef NU_MEM_WALK
  (void) dummy;

  ca_iter_state_finish(&st);
  fz_hash_free(&h);
  return vout;
}

/* @overload __is_mode__(axis)

   INTERNAL (CArray#is_mode). Mark each cell that holds a modal value along axis
   -- a value whose per-fiber occurrence count equals the fiber's maximum count.
   Two passes per fiber: pass one builds the frequency table (the fz_hash count
   lane) and finds the max count; pass two marks every cell whose value's count
   equals it, so ties are all marked (no tie-break). Returns a boolean CArray of
   self.shape.

   Masked cells do not participate (excluded from the counts) and are marked
   false. An empty / all-masked fiber has max count 0 and marks every cell false
   (is_mode has no identity; it never raises). Numeric distinctness collapses all
   NaN to one value and treats -0.0 == +0.0, matching the discovery family;
   object keys on rb_hash + rb_eql and fixlen on a byte-hash + memcmp, reproducing
   Ruby Hash distinctness; the object lane also collapses every Float NaN to one.
   Callers pass flat input by flattening first (a single fiber over axis 0).
*/
static VALUE
rb_ca_is_mode (VALUE self, VALUE vaxis)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_OBJECT: case CA_FIXLEN:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__is_mode__: numeric, object, or fixlen data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__is_mode__: need ndim >= 1");
  }
  int axis = NUM2INT(vaxis);
  if ( axis < 0 || axis >= ca->ndim ) {
    rb_raise(rb_eArgError, "__is_mode__: axis %d out of range", axis);
  }

  VALUE vout = rb_carray_new(CA_BOOLEAN, ca->ndim, ca->dim, 0, NULL);
  CArray *cout;
  TypedData_Get_Struct(vout, CArray, &carray_data_type, cout);

  fz_hash h;
  fz_levels ct;   /* int64 count per code (code == push index), reset per fiber */
  if      ( dt == CA_OBJECT ) { fz_hash_init_obj(&h); }
  else if ( dt == CA_FIXLEN ) { fz_hash_init_mem(&h, (int) ca->bytes); }
  else                        { fz_hash_init(&h); }
  fz_levels_init(&ct, (int) sizeof(int64_t));

  ca_iter_state st_in, st_out;
  char       *p_in, *p_out;
  boolean8_t *m;
  ca_size_t   n;

  /* Integer: WIDEN gives the key directly.  Two passes over the fiber. */
  #define IM_BODY(T, WIDEN)                                                   \
    do {                                                                      \
      const T    *ip = (const T *) p_in;                                      \
      boolean8_t *op = (boolean8_t *) p_out;                                  \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        uint64_t key = (uint64_t) (WIDEN ip[i]);                              \
        int is_new;                                                           \
        int32_t code = fz_hash_intern(&h, key, &is_new);                      \
        if ( is_new ) { int64_t one = 1; fz_levels_push(&ct, &one); }         \
        else { ((int64_t *) ct.p)[code]++; }                                  \
      }                                                                       \
      int64_t mx = 0;                                                         \
      for ( ca_size_t c = 0; c < h.n; c++ ) {                                 \
        int64_t cc = ((int64_t *) ct.p)[c];                                   \
        if ( cc > mx ) { mx = cc; }                                           \
      }                                                                       \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { op[i] = 0; continue; }                            \
        uint64_t key = (uint64_t) (WIDEN ip[i]);                              \
        int is_new;                                                           \
        int32_t code = fz_hash_intern(&h, key, &is_new);                      \
        op[i] = (((int64_t *) ct.p)[code] == mx) ? 1 : 0;                     \
      }                                                                       \
    } while (0)

  /* Float: NaN collapses to one canonical key; -0.0 / +0.0 share a key. */
  #define IM_BODY_FLOAT(T, UINT, NANKEY)                                      \
    do {                                                                      \
      const T    *ip = (const T *) p_in;                                      \
      boolean8_t *op = (boolean8_t *) p_out;                                  \
      for ( int pass = 0; pass < 2; pass++ ) {                                \
        int64_t mx = 0;                                                       \
        if ( pass == 1 ) {                                                    \
          for ( ca_size_t c = 0; c < h.n; c++ ) {                             \
            int64_t cc = ((int64_t *) ct.p)[c];                               \
            if ( cc > mx ) { mx = cc; }                                       \
          }                                                                   \
        }                                                                     \
        for ( ca_size_t i = 0; i < n; i++ ) {                                 \
          if ( m && m[i] ) { if ( pass == 1 ) { op[i] = 0; } continue; }      \
          T v = ip[i];                                                        \
          uint64_t key;                                                       \
          if ( v != v ) { key = (NANKEY); }                                   \
          else {                                                              \
            if ( v == (T) 0 ) { v = (T) 0; }                                  \
            UINT bits;                                                        \
            memcpy(&bits, &v, sizeof(bits));                                  \
            key = (uint64_t) bits;                                            \
          }                                                                   \
          int is_new;                                                         \
          int32_t code = fz_hash_intern(&h, key, &is_new);                    \
          if ( pass == 0 ) {                                                  \
            if ( is_new ) { int64_t one = 1; fz_levels_push(&ct, &one); }     \
            else { ((int64_t *) ct.p)[code]++; }                              \
          }                                                                   \
          else { op[i] = (((int64_t *) ct.p)[code] == mx) ? 1 : 0; }          \
        }                                                                     \
      }                                                                       \
    } while (0)

  /* Object: rb_hash + rb_eql lane.  Pass one builds the count lane, pass two
     marks cells whose value's count ties the fiber max (re-intern returns the
     existing code without inserting). */
  #define IM_BODY_OBJ                                                         \
    do {                                                                      \
      const VALUE *ip = (const VALUE *) p_in;                                 \
      boolean8_t  *op = (boolean8_t *) p_out;                                 \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        int is_new;                                                           \
        int32_t code = fz_hash_intern_obj(&h, ip[i], &is_new);               \
        if ( is_new ) { int64_t one = 1; fz_levels_push(&ct, &one); }         \
        else { ((int64_t *) ct.p)[code]++; }                                  \
      }                                                                       \
      int64_t mx = 0;                                                         \
      for ( ca_size_t c = 0; c < h.n; c++ ) {                                 \
        int64_t cc = ((int64_t *) ct.p)[c];                                   \
        if ( cc > mx ) { mx = cc; }                                           \
      }                                                                       \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { op[i] = 0; continue; }                            \
        int is_new;                                                           \
        int32_t code = fz_hash_intern_obj(&h, ip[i], &is_new);               \
        op[i] = (((int64_t *) ct.p)[code] == mx) ? 1 : 0;                     \
      }                                                                       \
    } while (0)

  /* Fixlen: byte-hash + memcmp lane, same two-pass structure. */
  #define IM_BODY_MEM                                                         \
    do {                                                                      \
      boolean8_t *op = (boolean8_t *) p_out;                                  \
      int esz = (int) ca->bytes;                                              \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { continue; }                                        \
        int is_new;                                                           \
        int32_t code = fz_hash_intern_mem(&h, p_in + i * esz, &is_new);       \
        if ( is_new ) { int64_t one = 1; fz_levels_push(&ct, &one); }         \
        else { ((int64_t *) ct.p)[code]++; }                                  \
      }                                                                       \
      int64_t mx = 0;                                                         \
      for ( ca_size_t c = 0; c < h.n; c++ ) {                                 \
        int64_t cc = ((int64_t *) ct.p)[c];                                   \
        if ( cc > mx ) { mx = cc; }                                           \
      }                                                                       \
      for ( ca_size_t i = 0; i < n; i++ ) {                                   \
        if ( m && m[i] ) { op[i] = 0; continue; }                            \
        int is_new;                                                           \
        int32_t code = fz_hash_intern_mem(&h, p_in + i * esz, &is_new);       \
        op[i] = (((int64_t *) ct.p)[code] == mx) ? 1 : 0;                     \
      }                                                                       \
    } while (0)

  CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, ca, cout, (int8_t) axis,
                                 CA_KERNEL_READ, p_in, p_out, n, m) {
    fz_hash_reset(&h);   /* independent frequency table per fiber */
    ct.n = 0;
    switch ( dt ) {
    case CA_INT8:   IM_BODY(int8_t,   (int64_t));  break;
    case CA_INT16:  IM_BODY(int16_t,  (int64_t));  break;
    case CA_INT32:  IM_BODY(int32_t,  (int64_t));  break;
    case CA_INT64:  IM_BODY(int64_t,  (int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  IM_BODY(uint8_t,  (uint64_t)); break;
    case CA_UINT16: IM_BODY(uint16_t, (uint64_t)); break;
    case CA_UINT32: IM_BODY(uint32_t, (uint64_t)); break;
    case CA_UINT64: IM_BODY(uint64_t, (uint64_t)); break;
    case CA_FLOAT32: IM_BODY_FLOAT(float,  uint32_t, 0x7fc00000ULL);          break;
    case CA_FLOAT64: IM_BODY_FLOAT(double, uint64_t, 0x7ff8000000000000ULL);  break;
    case CA_OBJECT:  IM_BODY_OBJ;                                            break;
    case CA_FIXLEN:  IM_BODY_MEM;                                            break;
    }
  }
  #undef IM_BODY
  #undef IM_BODY_FLOAT
  #undef IM_BODY_OBJ
  #undef IM_BODY_MEM

  fz_hash_free(&h);
  fz_levels_free(&ct);
  return vout;
}

/* Ascending comparison for the modal-value sort, NaN ordered last so a
   collapsed NaN key (at most one per fiber) trails the real values, matching
   CArray#sort. */
static int mode_gt_f32 (float  a, float  b) { if ( a != a ) return b == b; if ( b != b ) return 0; return a > b; }
static int mode_gt_f64 (double a, double b) { if ( a != a ) return b == b; if ( b != b ) return 0; return a > b; }
#define MODE_GTI(a, b) ((a) > (b))

/* @overload __mode_axis__(axis)

   INTERNAL (CArray#mode's numeric per-axis path). Emit the distinct modal
   values along axis, per fiber, ascending, as an Array of reduced CArrays --
   the ragged value-form consumer of the per-fiber frequency table (see
   __is_mode__, which marks the modal cells; this reads out the values).

   Two passes over the family substrate per fiber: pass one builds the
   frequency table (fz_hash + count lane + first-seen level buffer) and finds
   the fiber's max count; the modal values are the distinct values whose count
   equals it, sorted ascending. The ragged per-fiber lists are collected into
   one flat buffer, then redistributed into K reduced CArrays where K is the
   widest fiber's modal count: element j holds each fiber's j-th smallest modal
   value, masked (UNDEF) where a fiber has fewer than j+1 modes -- the same
   Array<CArray> shape as per-axis quantile. Stack them along axis to get the
   rectangular mask-padded form.

   The result Array's row-major cell order per reduced CArray matches the fiber
   walk (self.shape with axis removed). An all-masked array (no modes anywhere,
   K == 0) yields an empty Array. Masked cells are excluded from the counts. A
   1-D input reduces to length-1 reduced CArrays; the Ruby surface unwraps them
   to scalars. Float distinctness collapses all NaN to one value (sorted last)
   and treats -0.0 == +0.0 (the first-seen raw value is emitted, so -0.0 keeps
   its sign), matching the discovery family.
*/
static VALUE
rb_ca_mode_axis (VALUE self, VALUE vaxis)
{
  CArray *ca;
  volatile VALUE face;
  self = fz_face_descend(self, &face);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  int8_t dt = ca->data_type;
  switch ( dt ) {
  case CA_INT8:  case CA_INT16:  case CA_INT32:  case CA_INT64:
  case CA_UINT8: case CA_UINT16: case CA_UINT32: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
  case CA_BOOLEAN:
    break;
  default:
    rb_raise(rb_eCADataTypeError,
             "__mode_axis__: numeric data type required (got %d)", dt);
  }
  if ( ca->ndim < 1 ) {
    rb_raise(rb_eRuntimeError, "__mode_axis__: need ndim >= 1");
  }
  int axis = NUM2INT(vaxis);
  if ( axis < 0 || axis >= ca->ndim ) {
    rb_raise(rb_eArgError, "__mode_axis__: axis %d out of range", axis);
  }

  int esz = (int) ca->bytes;

  /* Number of fibers = self.elements with axis dropped = reduced cell count. */
  ca_size_t M = 1;
  for ( int d = 0; d < ca->ndim; d++ ) { if ( d != axis ) M *= ca->dim[d]; }

  fz_hash   h;
  fz_levels lv;     /* first-seen raw values, appearance order (reset per fiber) */
  fz_levels ct;     /* int64 count per code (code == push index, reset per fiber) */
  fz_levels mod;    /* per-fiber modal values, collected then sorted (reset) */
  fz_levels flat;   /* all fibers' modal values concatenated, fiber order */
  fz_hash_init(&h);
  fz_levels_init(&lv,   esz);
  fz_levels_init(&ct,   (int) sizeof(int64_t));
  fz_levels_init(&mod,  esz);
  fz_levels_init(&flat, esz);

  ca_size_t *foff = ALLOC_N(ca_size_t, M + 1);   /* prefix offsets into flat */
  foff[0] = 0;

  int8_t ax = (int8_t) axis;
  ca_iter_state st;
  int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, &ax, 1, 0);
  if ( rc != CA_ITER_OK ) {
    fz_hash_free(&h); fz_levels_free(&lv); fz_levels_free(&ct);
    fz_levels_free(&mod); fz_levels_free(&flat); xfree(foff);
    rb_raise(rb_eRuntimeError, "__mode_axis__: kernel_iterator init failed rc=%d", rc);
  }

  char       *p;
  boolean8_t *m;
  ca_size_t   out_i = 0;
  ca_size_t   Kmax  = 0;
  ca_size_t   dummy;   /* CA_SLAB_REDUCE_T needs an acc lvalue; unused here */

  /* Pass-one body: intern each value, growing the count lane and first-seen
     level buffer (code == push index).  WIDEN keys the integer element; float
     normalizes NaN and -0.0 before the bitwise key but pushes the raw value. */
  #define MB_INT(WIDEN)                                                       \
    do {                                                                      \
      uint64_t key = (uint64_t) ((WIDEN) v);                                  \
      int is_new; int32_t code = fz_hash_intern(&h, key, &is_new);            \
      if ( is_new ) { int64_t one = 1; fz_levels_push(&lv, &v);              \
                      fz_levels_push(&ct, &one); }                           \
      else { ((int64_t *) ct.p)[code]++; }                                    \
    } while (0)
  #define MB_FLOAT(T, UINT, NANKEY)                                           \
    do {                                                                      \
      T vn = v; uint64_t key;                                                 \
      if ( vn != vn ) { key = (NANKEY); }                                     \
      else { if ( vn == (T) 0 ) { vn = (T) 0; }                              \
             UINT bits; memcpy(&bits, &vn, sizeof(bits)); key = (uint64_t) bits; } \
      int is_new; int32_t code = fz_hash_intern(&h, key, &is_new);            \
      if ( is_new ) { int64_t one = 1; fz_levels_push(&lv, &v);              \
                      fz_levels_push(&ct, &one); }                           \
      else { ((int64_t *) ct.p)[code]++; }                                    \
    } while (0)

  /* Collect the distinct values whose count ties the fiber max, insertion-sort
     ascending (NaN last), and append them to the flat buffer. */
  #define MODE_EMIT(T, GT)                                                    \
    do {                                                                      \
      T *lvp = (T *) lv.p; int64_t *ctp = (int64_t *) ct.p;                   \
      for ( ca_size_t c = 0; c < h.n; c++ ) {                                 \
        if ( mx > 0 && ctp[c] == mx ) { fz_levels_push(&mod, &lvp[c]); }      \
      }                                                                       \
      T *dp = (T *) mod.p; ca_size_t cm = mod.n;                              \
      for ( ca_size_t x = 1; x < cm; x++ ) {                                  \
        T kv = dp[x]; ca_size_t y = x;                                        \
        while ( y > 0 && GT(dp[y - 1], kv) ) { dp[y] = dp[y - 1]; y--; }      \
        dp[y] = kv;                                                           \
      }                                                                       \
      for ( ca_size_t x = 0; x < cm; x++ ) { fz_levels_push(&flat, &dp[x]); } \
    } while (0)

  while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
    fz_hash_reset(&h);
    lv.n = 0; ct.n = 0; mod.n = 0;

    switch ( dt ) {
    case CA_INT8:   CA_SLAB_REDUCE_T(int8_t,   st, p, m, dummy, 0, MB_INT(int64_t));  break;
    case CA_INT16:  CA_SLAB_REDUCE_T(int16_t,  st, p, m, dummy, 0, MB_INT(int64_t));  break;
    case CA_INT32:  CA_SLAB_REDUCE_T(int32_t,  st, p, m, dummy, 0, MB_INT(int64_t));  break;
    case CA_INT64:  CA_SLAB_REDUCE_T(int64_t,  st, p, m, dummy, 0, MB_INT(int64_t));  break;
    case CA_BOOLEAN: case CA_UINT8:  CA_SLAB_REDUCE_T(uint8_t,  st, p, m, dummy, 0, MB_INT(uint64_t)); break;
    case CA_UINT16: CA_SLAB_REDUCE_T(uint16_t, st, p, m, dummy, 0, MB_INT(uint64_t)); break;
    case CA_UINT32: CA_SLAB_REDUCE_T(uint32_t, st, p, m, dummy, 0, MB_INT(uint64_t)); break;
    case CA_UINT64: CA_SLAB_REDUCE_T(uint64_t, st, p, m, dummy, 0, MB_INT(uint64_t)); break;
    case CA_FLOAT32:
      CA_SLAB_REDUCE_T(float,  st, p, m, dummy, 0, MB_FLOAT(float,  uint32_t, 0x7fc00000ULL));
      break;
    case CA_FLOAT64:
      CA_SLAB_REDUCE_T(double, st, p, m, dummy, 0, MB_FLOAT(double, uint64_t, 0x7ff8000000000000ULL));
      break;
    }

    int64_t mx = 0;
    for ( ca_size_t c = 0; c < h.n; c++ ) {
      int64_t cc = ((int64_t *) ct.p)[c];
      if ( cc > mx ) { mx = cc; }
    }

    switch ( dt ) {
    case CA_INT8:    MODE_EMIT(int8_t,   MODE_GTI);   break;
    case CA_INT16:   MODE_EMIT(int16_t,  MODE_GTI);   break;
    case CA_INT32:   MODE_EMIT(int32_t,  MODE_GTI);   break;
    case CA_INT64:   MODE_EMIT(int64_t,  MODE_GTI);   break;
    case CA_BOOLEAN: case CA_UINT8:   MODE_EMIT(uint8_t,  MODE_GTI);   break;
    case CA_UINT16:  MODE_EMIT(uint16_t, MODE_GTI);   break;
    case CA_UINT32:  MODE_EMIT(uint32_t, MODE_GTI);   break;
    case CA_UINT64:  MODE_EMIT(uint64_t, MODE_GTI);   break;
    case CA_FLOAT32: MODE_EMIT(float,  mode_gt_f32);  break;
    case CA_FLOAT64: MODE_EMIT(double, mode_gt_f64);  break;
    }

    if ( out_i < M ) { foff[out_i + 1] = foff[out_i] + mod.n; }
    if ( mod.n > Kmax ) { Kmax = mod.n; }
    out_i++;
  }
  #undef MB_INT
  #undef MB_FLOAT
  #undef MODE_EMIT
  (void) dummy;

  ca_iter_state_finish(&st);
  fz_hash_free(&h);
  fz_levels_free(&lv);
  fz_levels_free(&ct);
  fz_levels_free(&mod);

  /* K columns, each a reduced CArray; slot j is fiber r's j-th modal value or
     UNDEF when r has fewer than j+1 modes.  K == 0 -> empty Array. */
  VALUE result = rb_ary_new_capa((long) Kmax);
  for ( ca_size_t j = 0; j < Kmax; j++ ) {
    VALUE col = rb_ca_new_reduced(self, &ax, 1, dt, 0);
    CArray *cc;
    TypedData_Get_Struct(col, CArray, &carray_data_type, cc);
    ca_create_mask(cc);
    boolean8_t *cm = (boolean8_t *) cc->mask->ptr;
    char *dst = cc->ptr;
    for ( ca_size_t r = 0; r < M; r++ ) {
      ca_size_t cnt_r = foff[r + 1] - foff[r];
      if ( j < cnt_r ) {
        memcpy(dst + (size_t) r * esz, flat.p + (size_t) (foff[r] + j) * esz, esz);
        cm[r] = 0;
      }
      else {
        cm[r] = 1;
      }
    }
    rb_ary_push(result, fz_face_relift(col, face));   /* modal *values* */
  }

  fz_levels_free(&flat);
  xfree(foff);
  return result;
}

void
Init_carray_factorize (void)
{
  rb_define_private_method(rb_cCArray, "__factorize_appearance__",
                           rb_ca_factorize_appearance, 0);
  rb_define_private_method(rb_cCArray, "__mask_duplicates__",
                           rb_ca_mask_duplicates, 1);
  rb_define_private_method(rb_cCArray, "__unique_flat__",
                           rb_ca_unique_flat, 0);
  rb_define_private_method(rb_cCArray, "__is_in__",
                           rb_ca_is_in, 1);
  rb_define_private_method(rb_cCArray, "__locate_addr__",
                           rb_ca_locate_addr, 1);
  rb_define_private_method(rb_cCArray, "__intersection__",
                           rb_ca_intersection, 1);
  rb_define_private_method(rb_cCArray, "__difference__",
                           rb_ca_difference, 1);
  rb_define_private_method(rb_cCArray, "__union__",
                           rb_ca_set_union, 1);
  rb_define_private_method(rb_cCArray, "__value_counts_flat__",
                           rb_ca_value_counts_flat, 0);
  rb_define_private_method(rb_cCArray, "__nunique__",
                           rb_ca_nunique, 2);
  rb_define_private_method(rb_cCArray, "__is_mode__",
                           rb_ca_is_mode, 1);
  rb_define_private_method(rb_cCArray, "__mode_axis__",
                           rb_ca_mode_axis, 1);
}
