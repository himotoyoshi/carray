/* ---------------------------------------------------------------------------

  ca_obj_const_string.c

  CAConstString — read-only variable-length UTF-8 string column
  (Arrow string layout via Face).

  A Face whose tail carries the string `buffer` + encoding.  Parent
  (storage) is a fixlen-16 entity holding one `(int64 start, int64 end)`
  pair per element; the buffer is a frozen byte String laid out as a
  pure concatenation of the element bytes (= Arrow values buffer, no
  per-record length prefix).  Decoding element i: read the pair from
  `parent[i]`, then `bytes = buf + start`, `len = end - start`.  Each
  element is self-describing (carries its own byte range), so gather /
  sort / boolean-select views over the pairs decode correctly with no
  buffer copy.

  Surface data_type = CA_FIXLEN (numeric gate): mkkernel dispatch
  routes numeric ops to `ca_*_not_implement` -> raise, preventing a
  silent numeric strip of a CAConstString.  Storage is fixlen-16 so
  the byte size is told truthfully; the FIXLEN surface seals off
  only the numeric meaning.

  High-duplication columns belong in CACategorical (= Arrow
  DictionaryArray), not here: CAConstString stores every element's
  bytes once in logical order, without offset-sharing dedup.

  Sibling of ca_obj_record.c (Face + VALUE tail + custom dmark) and
  ca_obj_time.c (int64 Face + storage_to_scalar fast path).

--------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"
#include <ruby/encoding.h>

/* === struct layout (identical to the CATime prefix + tail) === */
typedef struct {
  /* === CAView prefix === */
  int16_t    obj_type;
  int8_t     data_type;        /* CA_FIXLEN surface (numeric gate); storage is int64 */
  int8_t     ndim;
  int32_t    flags;            /* CA_FLAG_IS_FACE set */
  ca_size_t  bytes;            /* sizeof(int64_t) = 8 (one offset per element) */
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray    *parent;           /* fixlen-16 (start,end) pair entity (offset-source) */
  uint32_t   attach;
  uint8_t    nosync;
  /* === Face tail === */
  VALUE      buffer;           /* frozen byte String (pure concat), marked by custom dmark */
  int        encoding_id;      /* rb_enc_to_index() value */
} CAConstString;

static size_t
ca_const_string_dsize (const void *ap)
{
  const CAConstString *ca = (const CAConstString *) ap;
  return sizeof(CAConstString) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer (uniform alloc / free discipline). */
static size_t
ca_const_string_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_const_string_pool_init (void *ap, int8_t ndim)
{
  CAConstString *ca = (CAConstString *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

/* Custom dmark: ca_mark walks the standard prefix (CA_OBJECT elements, of
   which a CAConstString has none); we additionally mark the buffer tail VALUE.
   parent retention is via rb_ca_set_parent ivar (= not dmark), same as
   CARecord / CATime. */
static void
ca_const_string_mark (void *ap)
{
  CAConstString *ca = (CAConstString *) ap;
  ca_mark(ca);
  rb_gc_mark(ca->buffer);
}

const rb_data_type_t catext_data_type = {
    .parent = &caface_data_type,
    .wrap_struct_name = "CAConstString",
    .function = {
        .dmark = ca_const_string_mark,
        .dfree = ca_free,
        .dsize = ca_const_string_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_CONST_STRING;
static VALUE rb_cCAConstString;

/* yard:
  class CAConstString < CAFace # :nodoc:
  end
*/

/* ------------------------------------------------------------------- */

int
ca_const_string_setup (CAConstString *ca, CArray *parent, VALUE buffer, int encoding_id)
{
  if ( parent->data_type != CA_FIXLEN || parent->bytes != 2 * (ca_size_t) sizeof(int64_t) ) {
    rb_raise(rb_eTypeError,
             "CAConstString requires a fixlen-16 (start,end) pair storage "
             "(parent.data_type must be CA_FIXLEN with bytes == 16)");
  }

  ca->obj_type    = CA_OBJ_CONST_STRING;
  /* FIXLEN surface auto-gates mkkernel numeric dispatch. */
  ca->data_type   = CA_FIXLEN;
  ca->flags       = CA_FLAG_IS_FACE;
  ca->ndim        = parent->ndim;
  ca->bytes       = 2 * sizeof(int64_t);   /* (start,end) pair per element */
  ca->elements    = parent->elements;
  ca->ptr         = NULL;
  ca->mask        = NULL;
  if ( ! ca->_pool ) {
    ca->dim       = ALLOC_N(ca_size_t, parent->ndim);
  }
  memcpy(ca->dim, parent->dim, sizeof(ca_size_t) * parent->ndim);

  ca->parent      = parent;
  ca->attach      = 0;
  ca->nosync      = 0;

  ca->buffer      = buffer;
  ca->encoding_id = encoding_id;

  if ( ca_has_mask(parent) ) {
    ca_create_mask((CArray *) ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  /* CAConstString is always read-only (Invariant 4). */
  ca_set_flag(ca, CA_FLAG_READ_ONLY);

  return 0;
}

CAConstString *
ca_const_string_new (CArray *parent, VALUE buffer, int encoding_id)
{
  CAConstString *ca = (CAConstString *) ca_array_alloc(CA_OBJ_CONST_STRING, parent->ndim);
  ca_const_string_setup(ca, parent, buffer, encoding_id);
  return ca;
}

static void
free_ca_text (void *ap)
{
  CAConstString *ca = (CAConstString *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ca->_pool ) {
      ca_array_free(ca);          /* dim lives in _pool */
    }
    else {
      xfree(ca->dim);
      xfree(ca);
    }
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_const_string_func_clone (void *ap)
{
  CAConstString *ca = (CAConstString *) ap;
  /* buffer is immutable → sharing the same VALUE reference is safe + cheap
     (Invariant 7, MEMO §3). */
  return ca_const_string_new(ca->parent, ca->buffer, ca->encoding_id);
}

static void
ca_const_string_func_allocate (void *ap)
{
  CAConstString *ca = (CAConstString *) ap;
  /* alias: parent attach + alias parent->ptr (Face has identical layout) */
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr;
}

static void
ca_const_string_func_create_mask (void *ap)
{
  CAConstString *ca = (CAConstString *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_refer_new(ca->parent->mask,
                                     CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_const_string_func = {
  -1, /* CA_OBJ_CONST_STRING — filled by ca_install_obj_type */
  CA_VIEW_ARRAY,
  free_ca_text,
  ca_const_string_func_clone,
  ca_const_string_func_allocate,
  ca_face_attach,
  ca_face_sync,
  ca_face_detach,
  ca_face_fill_data,
  ca_const_string_func_create_mask,
  ca_face_xfer_index,
  ca_face_xfer_addrs,
  NULL,                              /* fold_stride: identity Face is not foldable */
  ca_face_xfer_stride,
  ca_face_xfer_all,
  .fill_addrs  = ca_face_fill_addrs,
  .fill_stride = ca_face_fill_stride,
};

/* ------------------------------------------------------------------- */

/* decode one record from the buffer given its [start,end) byte range →
   frozen String.  buffer layout: pure concatenation (Arrow values layout),
   length = end - start.  encoding from ca->encoding_id. */
static VALUE
ca_const_string_decode (CAConstString *ca, int64_t start, int64_t end)
{
  const char *buf = RSTRING_PTR(ca->buffer);
  long buflen = RSTRING_LEN(ca->buffer);
  int64_t len = end - start;
  VALUE s;

  if ( start < 0 || len < 0 || end > (int64_t) buflen ) {
    rb_raise(rb_eIndexError,
             "CAConstString: record [%lld,%lld) out of buffer range (%ld bytes)",
             (long long) start, (long long) end, buflen);
  }
  s = rb_enc_str_new(buf + start, (long) len,
                     rb_enc_from_index(ca->encoding_id));
  return rb_str_freeze(s);
}

/* storage_to_scalar in C (= skip rb_funcall on the per-cell fetch hot
   path).  Since the Face surface is CA_FIXLEN (16 bytes), fetch delivers a
   16-byte raw String = the (start,end) int64 pair.  Decode the buffer slice
   → frozen Ruby String (plain frozen String, no Scalar wrapper). */
static VALUE
rb_ca_const_string_storage_to_scalar (VALUE self, VALUE raw)
{
  CAConstString *ca;
  int64_t pair[2];

  TypedData_Get_Struct(self, CAConstString, &catext_data_type, ca);

  if ( TYPE(raw) != T_STRING || RSTRING_LEN(raw) != (long) sizeof(pair) ) {
    rb_raise(rb_eArgError,
             "CAConstString#storage_to_scalar: expected a %lu-byte (start,end) cell",
             (unsigned long) sizeof(pair));
  }
  memcpy(pair, RSTRING_PTR(raw), sizeof(pair));

  return ca_const_string_decode(ca, pair[0], pair[1]);
}

/* ------------------------------------------------------------------- */

/* CAConstString.wrap(int64_offsets, buffer:, encoding:) — low-level Face wrap of an
   existing fixlen-16 (start,end) pair entity + pure-concatenation buffer. */
static VALUE
rb_ca_const_string_wrap (VALUE parent_val, VALUE buffer, int encoding_id)
{
  CArray *parent;
  CAConstString *ca;
  VALUE obj;

  TypedData_Get_Struct(parent_val, CArray, &carray_data_type, parent);
  if ( parent->data_type != CA_FIXLEN || parent->bytes != 2 * (ca_size_t) sizeof(int64_t) ) {
    rb_raise(rb_eTypeError,
             "CAConstString.wrap requires a fixlen-16 (start,end) pair entity "
             "(got data_type=%d, bytes=%ld)",
             parent->data_type, (long) parent->bytes);
  }
  if ( TYPE(buffer) != T_STRING ) {
    rb_raise(rb_eTypeError, "CAConstString.wrap: buffer: must be a String");
  }

  ca  = ca_const_string_new(parent, rb_str_freeze(buffer), encoding_id);
  obj = TypedData_Wrap_Struct(rb_cCAConstString, &catext_data_type, ca);
  rb_ca_set_parent(obj, parent_val);   /* pin parent VALUE for GC */
  return obj;
}

static VALUE
rb_ca_const_string_wrap_method (int argc, VALUE *argv, VALUE klass)
{
  VALUE parent_val, ropt, rbuffer = Qnil, renc = Qnil;
  int encoding_id;

  rb_scan_args(argc, argv, "1:", &parent_val, &ropt);
  rb_scan_options(ropt, "buffer,encoding", &rbuffer, &renc);
  if ( NIL_P(rbuffer) ) {
    rb_raise(rb_eArgError, "CAConstString.wrap: buffer: keyword is required");
  }
  encoding_id = NIL_P(renc) ? rb_utf8_encindex()
                            : rb_to_encoding_index(renc);

  return rb_ca_const_string_wrap(parent_val, rbuffer, encoding_id);
}

/* Build a CAConstString from a Ruby Array of Strings / nils in a single C
   pass: pure-concatenation buffer (Arrow values layout) + fixlen-16
   (start,end) pair entity, with a mask for nil elements.  Replaces the
   per-element Ruby build loop -- no `String#b` copy, no `pack`, no per-row
   method dispatch.  `renc` is the target Encoding (nil = UTF-8). */
static VALUE
rb_ca_const_string_build (VALUE klass, VALUE values, VALUE renc)
{
  long i, n;
  int encoding_id;
  rb_encoding *enc;
  volatile VALUE buffer, vpair;
  CArray *pe;
  int64_t *pair;
  boolean8_t *mask = NULL;
  ca_size_t dim[1];
  long hint = 0;

  Check_Type(values, T_ARRAY);
  n = RARRAY_LEN(values);
  encoding_id = NIL_P(renc) ? rb_utf8_encindex() : rb_to_encoding_index(renc);
  enc = rb_enc_from_index(encoding_id);

  /* size hint: sum String lengths cheaply (skip non-String coercion here) */
  for ( i = 0; i < n; i++ ) {
    VALUE s = RARRAY_AREF(values, i);
    if ( RB_TYPE_P(s, T_STRING) ) hint += RSTRING_LEN(s);
  }
  buffer = rb_str_buf_new(hint);
  rb_enc_associate_index(buffer, rb_ascii8bit_encindex());

  dim[0] = (ca_size_t) n;
  vpair  = rb_carray_new(CA_FIXLEN, 1, dim, 2 * sizeof(int64_t), NULL);
  TypedData_Get_Struct(vpair, CArray, &carray_data_type, pe);
  pair = (int64_t *) pe->ptr;

  for ( i = 0; i < n; i++ ) {
    VALUE s = RARRAY_AREF(values, i);
    if ( NIL_P(s) ) {
      if ( ! mask ) {
        ca_create_mask(pe);
        mask = (boolean8_t *) pe->mask->ptr;
      }
      mask[i]      = 1;
      pair[2 * i]     = 0;
      pair[2 * i + 1] = 0;
      continue;
    }
    if ( ! RB_TYPE_P(s, T_STRING) ) {
      s = rb_obj_as_string(s);   /* to_s */
    }
    /* encoding gate: match the column encoding, or pure-ASCII passes through */
    if ( rb_enc_get_index(s) != encoding_id && ! rb_enc_str_asciionly_p(s) ) {
      rb_raise(rb_eArgError,
               "CArray.const_string: element encoding %s does not match column "
               "encoding %s (use String#encode to convert explicitly)",
               rb_enc_name(rb_enc_get(s)), rb_enc_name(enc));
    }
    pair[2 * i]     = (int64_t) RSTRING_LEN(buffer);
    rb_str_cat(buffer, RSTRING_PTR(s), RSTRING_LEN(s));
    pair[2 * i + 1] = (int64_t) RSTRING_LEN(buffer);
  }

  return rb_ca_const_string_wrap(vpair, rb_str_freeze(buffer), encoding_id);
}

/* CAConstString#encoding → Encoding */
static VALUE
rb_ca_const_string_encoding (VALUE self)
{
  CAConstString *ca;
  TypedData_Get_Struct(self, CAConstString, &catext_data_type, ca);
  return rb_enc_from_encoding(rb_enc_from_index(ca->encoding_id));
}

/* `CAConstString#buffer` — returns the frozen internal byte buffer
   (length-prefix format).  Exposes the defining tail state for
   introspection and the Arrow-boundary component-buffer export
   path. */
static VALUE
rb_ca_const_string_buffer (VALUE self)
{
  CAConstString *ca;
  TypedData_Get_Struct(self, CAConstString, &catext_data_type, ca);
  return ca->buffer;
}

/* ------------------------------------------------------------------- */

/* copy = compacting deep copy — the only chain-descent point in
   CAConstString.  Produces a standalone CAConstString:
     - a fresh contiguous fixlen-16 (start,end) pair entity
     - a fresh compacted buffer, each element's bytes repacked once in the
       view's logical order (pure concatenation = Arrow values layout)
     - encoding preserved, mask carried
     - fully detached from the original buffer / pair-source
   Cost is O(live bytes); a near-full copy is a near-full rebuild (accepted).
   Done at the byte level (no per-element Ruby String boxing). */
static VALUE
rb_ca_const_string_copy (VALUE self)
{
  volatile VALUE vout, newbuf;
  CAConstString *ca;
  CArray *co;
  ca_size_t i, n;
  int64_t *src_pair, *dst_pair;
  boolean8_t *m = NULL;
  const char *oldbuf;
  long oldbuflen;

  TypedData_Get_Struct(self, CAConstString, &catext_data_type, ca);

  /* materialize logical-order (start,end) pairs + mask */
  ca_attach((CArray *) ca);
  ca_update_mask((CArray *) ca);

  n          = ca->elements;
  src_pair   = (int64_t *) ca->ptr;
  m          = ca->mask ? (boolean8_t *) ca->mask->ptr : NULL;
  oldbuf     = RSTRING_PTR(ca->buffer);
  oldbuflen  = RSTRING_LEN(ca->buffer);

  /* fresh fixlen-16 pair entity, same shape (N-D preserved) */
  vout = rb_carray_new(CA_FIXLEN, ca->ndim, ca->dim, 2 * sizeof(int64_t), NULL);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, co);
  dst_pair = (int64_t *) co->ptr;

  /* growable compacted buffer (BINARY) */
  newbuf = rb_str_buf_new(oldbuflen);
  rb_enc_associate_index(newbuf, rb_ascii8bit_encindex());

  for ( i = 0; i < n; i++ ) {
    int64_t start, end, len;
    if ( m && m[i] ) {
      dst_pair[2 * i] = 0;
      dst_pair[2 * i + 1] = 0;
      continue;
    }
    start = src_pair[2 * i];
    end   = src_pair[2 * i + 1];
    len   = end - start;
    if ( start < 0 || len < 0 || end > (int64_t) oldbuflen ) {
      ca_detach((CArray *) ca);
      rb_raise(rb_eIndexError,
               "CAConstString#copy: record [%lld,%lld) out of buffer range",
               (long long) start, (long long) end);
    }
    dst_pair[2 * i] = (int64_t) RSTRING_LEN(newbuf);
    rb_str_cat(newbuf, oldbuf + start, (long) len);
    dst_pair[2 * i + 1] = (int64_t) RSTRING_LEN(newbuf);
  }

  /* carry mask onto the new pair entity */
  if ( m ) {
    boolean8_t *nm;
    ca_create_mask(co);
    nm = (boolean8_t *) co->mask->ptr;
    for ( i = 0; i < n; i++ ) {
      nm[i] = m[i] ? 1 : 0;
    }
  }

  ca_detach((CArray *) ca);

  return rb_ca_const_string_wrap(vout, rb_str_freeze(newbuf), ca->encoding_id);
}

/* to_ca descends to the same compacting copy.  The result is detached
   from the source buffer by construction, so `writable: true` — a demand
   that writes reach the source — cannot be honoured and is refused. */
static VALUE
rb_ca_const_string_to_ca (int argc, VALUE *argv, VALUE self)
{
  if ( ca_to_ca_writable_arg(argc, argv) ) {
    ca_to_ca_refuse_writable(self);
  }
  return rb_ca_const_string_copy(self);
}

/* ------------------------------------------------------------------- */
/* Native byte ops: compare / scan record bytes straight out of the
   buffer, without materializing a Ruby String per element.  This is
   the layer where CAConstString outperforms `to_object` followed by
   per-cell Ruby String work. */

typedef struct {
  CAConstString     *ca;
  int64_t    *off;
  boolean8_t *m;
  const char *buf;
  long        buflen;
  ca_size_t   n;
} ca_const_string_scan_t;

static void
ca_const_string_scan_begin (VALUE self, ca_const_string_scan_t *s)
{
  TypedData_Get_Struct(self, CAConstString, &catext_data_type, s->ca);
  ca_attach((CArray *) s->ca);
  ca_update_mask((CArray *) s->ca);
  s->off    = (int64_t *) s->ca->ptr;
  s->m      = s->ca->mask ? (boolean8_t *) s->ca->mask->ptr : NULL;
  s->buf    = RSTRING_PTR(s->ca->buffer);
  s->buflen = RSTRING_LEN(s->ca->buffer);
  s->n      = s->ca->elements;
}

static void
ca_const_string_scan_end (ca_const_string_scan_t *s)
{
  ca_detach((CArray *) s->ca);
}

/* Resolve element i to its record bytes; returns 0 if masked.
   Storage is (start,end) int64 pairs: s->off holds 2 int64 per element,
   so element i occupies s->off[2*i] (start) .. s->off[2*i+1] (end).
   The buffer is a pure concatenation; length = end - start. */
static inline int
ca_const_string_record (ca_const_string_scan_t *s, ca_size_t i, const char **pp, int32_t *plen)
{
  int64_t start, end;
  if ( s->m && s->m[i] ) {
    return 0;
  }
  start = s->off[2 * i];
  end   = s->off[2 * i + 1];
  *pp   = s->buf + start;
  *plen = (int32_t) (end - start);
  return 1;
}

/* Allocate a boolean output of the same shape; carry the input mask. */
static VALUE
ca_const_string_bool_out (ca_const_string_scan_t *s, boolean8_t **op)
{
  VALUE vout;
  CArray *co;
  vout = rb_carray_new(CA_BOOLEAN, s->ca->ndim, s->ca->dim, 0, NULL);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, co);
  *op = (boolean8_t *) co->ptr;
  if ( s->m ) {
    ca_size_t i;
    boolean8_t *nm;
    ca_create_mask(co);
    nm = (boolean8_t *) co->mask->ptr;
    for ( i = 0; i < s->n; i++ ) {
      nm[i] = s->m[i] ? 1 : 0;
    }
  }
  return vout;
}

/* memmem fallback (not in all libc). */
static const char *
ca_const_string_memmem (const char *hay, long hlen, const char *need, long nlen)
{
  long i;
  if ( nlen == 0 ) return hay;
  if ( nlen > hlen ) return NULL;
  for ( i = 0; i <= hlen - nlen; i++ ) {
    if ( hay[i] == need[0] && memcmp(hay + i, need, nlen) == 0 ) {
      return hay + i;
    }
  }
  return NULL;
}

/* CAConstString#byte_length → int64 CArray of per-element byte lengths. */
static VALUE
rb_ca_const_string_byte_length (VALUE self)
{
  ca_const_string_scan_t s;
  VALUE vout;
  CArray *co;
  int64_t *op;
  const char *p;
  int32_t len;
  ca_size_t i;

  ca_const_string_scan_begin(self, &s);
  vout = rb_carray_new(CA_INT64, s.ca->ndim, s.ca->dim, 0, NULL);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, co);
  op = (int64_t *) co->ptr;
  for ( i = 0; i < s.n; i++ ) {
    op[i] = ca_const_string_record(&s, i, &p, &len) ? (int64_t) len : 0;
  }
  if ( s.m ) {
    boolean8_t *nm;
    ca_create_mask(co);
    nm = (boolean8_t *) co->mask->ptr;
    for ( i = 0; i < s.n; i++ ) {
      nm[i] = s.m[i] ? 1 : 0;
    }
  }
  ca_const_string_scan_end(&s);
  return vout;
}

/* op codes for the shared predicate scan. */
enum { CA_TEXT_EQ, CA_TEXT_START, CA_TEXT_END, CA_TEXT_INCLUDE };

/* CAConstString#eq / start_with? / end_with? / include? — boolean mask vs a scalar
   String query, byte-native. */
static VALUE
ca_const_string_predicate (VALUE self, VALUE query, int op)
{
  ca_const_string_scan_t s;
  VALUE vout;
  boolean8_t *out;
  const char *qp, *p;
  long qlen;
  int32_t len;
  ca_size_t i;

  if ( TYPE(query) != T_STRING ) {
    query = rb_obj_as_string(query);
  }
  qp   = RSTRING_PTR(query);
  qlen = RSTRING_LEN(query);

  ca_const_string_scan_begin(self, &s);
  vout = ca_const_string_bool_out(&s, &out);

  for ( i = 0; i < s.n; i++ ) {
    boolean8_t r = 0;
    if ( ca_const_string_record(&s, i, &p, &len) ) {
      switch ( op ) {
        case CA_TEXT_EQ:
          r = ( len == qlen && memcmp(p, qp, qlen) == 0 );
          break;
        case CA_TEXT_START:
          r = ( len >= qlen && memcmp(p, qp, qlen) == 0 );
          break;
        case CA_TEXT_END:
          r = ( len >= qlen && memcmp(p + len - qlen, qp, qlen) == 0 );
          break;
        case CA_TEXT_INCLUDE:
          r = ( ca_const_string_memmem(p, len, qp, qlen) != NULL );
          break;
      }
    }
    out[i] = r;
  }
  ca_const_string_scan_end(&s);
  return vout;
}

static VALUE rb_ca_const_string_start_with (VALUE self, VALUE q) { return ca_const_string_predicate(self, q, CA_TEXT_START); }
static VALUE rb_ca_const_string_end_with   (VALUE self, VALUE q) { return ca_const_string_predicate(self, q, CA_TEXT_END); }
static VALUE rb_ca_const_string_include    (VALUE self, VALUE q) { return ca_const_string_predicate(self, q, CA_TEXT_INCLUDE); }

/* CAConstString#eq(value): value is a scalar String (broadcast) or a CAConstString
   (element-wise).  Returns a boolean CArray. */
static VALUE
rb_ca_const_string_eq (VALUE self, VALUE other)
{
  if ( rb_obj_is_kind_of(other, rb_cCAConstString) ) {
    ca_const_string_scan_t a, b;
    VALUE vout;
    boolean8_t *out;
    /* record() leaves these unset for masked cells; short-circuit eval means
       they are read only when both records are valid, but GCC cannot prove
       that -- initialize to keep -Wmaybe-uninitialized quiet and defensive. */
    const char *pa = NULL, *pb = NULL;
    int32_t la = 0, lb = 0;
    ca_size_t i;

    ca_const_string_scan_begin(self, &a);
    ca_const_string_scan_begin(other, &b);
    if ( a.n != b.n ) {
      ca_const_string_scan_end(&a);
      ca_const_string_scan_end(&b);
      rb_raise(rb_eArgError, "CAConstString#eq: element count mismatch (%lld vs %lld)",
               (long long) a.n, (long long) b.n);
    }
    vout = ca_const_string_bool_out(&a, &out);   /* mask carried from self */
    for ( i = 0; i < a.n; i++ ) {
      int va = ca_const_string_record(&a, i, &pa, &la);
      int vb = ca_const_string_record(&b, i, &pb, &lb);
      out[i] = ( va && vb && la == lb && memcmp(pa, pb, la) == 0 );
    }
    ca_const_string_scan_end(&a);
    ca_const_string_scan_end(&b);
    return vout;
  }
  return ca_const_string_predicate(self, other, CA_TEXT_EQ);
}

/* CAConstString#count(value): number of (non-masked) elements byte-equal to value. */
static VALUE
rb_ca_const_string_count (VALUE self, VALUE query)
{
  ca_const_string_scan_t s;
  const char *qp, *p;
  long qlen;
  int32_t len;
  ca_size_t i, c = 0;

  if ( TYPE(query) != T_STRING ) {
    query = rb_obj_as_string(query);
  }
  qp   = RSTRING_PTR(query);
  qlen = RSTRING_LEN(query);

  ca_const_string_scan_begin(self, &s);
  for ( i = 0; i < s.n; i++ ) {
    if ( ca_const_string_record(&s, i, &p, &len) && len == qlen && memcmp(p, qp, qlen) == 0 ) {
      c++;
    }
  }
  ca_const_string_scan_end(&s);
  return SIZET2NUM(c);
}

/* CAConstString#search(query) / #find_value_index(query): flat index of the
   first (non-masked) element byte-equal to query, or nil when none matches.
   The numeric/fixlen search kernels cannot run here (storage is the int64
   offset entity, not the string content), so this is a native memcmp scan --
   the exact-lookup counterpart of the native sort / min / max below. */
static VALUE
rb_ca_const_string_search (VALUE self, VALUE query)
{
  ca_const_string_scan_t s;
  const char *qp, *p;
  long qlen;
  int32_t len;
  ca_size_t i;
  VALUE result = Qnil;

  if ( TYPE(query) != T_STRING ) {
    query = rb_obj_as_string(query);
  }
  qp   = RSTRING_PTR(query);
  qlen = RSTRING_LEN(query);

  ca_const_string_scan_begin(self, &s);
  for ( i = 0; i < s.n; i++ ) {
    if ( ca_const_string_record(&s, i, &p, &len) && len == qlen && memcmp(p, qp, (size_t) qlen) == 0 ) {
      result = SIZET2NUM(i);
      break;
    }
  }
  ca_const_string_scan_end(&s);
  return result;
}

/* ------------------------------------------------------------------- */
/* Native sort / min / max.  Ruby `String#<=>` is a byte comparison
   within the same encoding, so a byte-memcmp comparator is
   byte-for-byte faithful to `to_object.sort` with no collation
   loss. */

/* qsort comparator context — single-threaded under the GVL (thread-safety is
   a non-goal; see project memory), so a file-static context is safe. */
static ca_const_string_scan_t *ca_const_string_sort_ctx;

static int
ca_const_string_byte_cmp (const void *a, const void *b)
{
  ca_size_t ia = *(const ca_size_t *) a;
  ca_size_t ib = *(const ca_size_t *) b;
  /* sort raises on masked input, so record() always sets these here; the
     initializers keep -Wmaybe-uninitialized quiet and stay defensive. */
  const char *pa = NULL, *pb = NULL;
  int32_t la = 0, lb = 0;
  int c;
  ca_const_string_record(ca_const_string_sort_ctx, ia, &pa, &la);
  ca_const_string_record(ca_const_string_sort_ctx, ib, &pb, &lb);
  c = memcmp(pa, pb, (size_t) (la < lb ? la : lb));
  if ( c != 0 ) return c;
  return (la > lb) - (la < lb);
}

/* compute the ascending sort permutation; raises on masked input (matches
   base CArray#sort).  caller xfree()s the returned index array. */
static ca_size_t *
ca_const_string_sort_perm (ca_const_string_scan_t *s)
{
  ca_size_t *idx;
  ca_size_t i;
  if ( s->m ) {
    ca_const_string_scan_end(s);
    rb_raise(rb_eArgError, "CAConstString#sort: cannot sort an array with masked elements");
  }
  idx = ALLOC_N(ca_size_t, s->n);
  for ( i = 0; i < s->n; i++ ) idx[i] = i;
  ca_const_string_sort_ctx = s;
  qsort(idx, (size_t) s->n, sizeof(ca_size_t), ca_const_string_byte_cmp);
  ca_const_string_sort_ctx = NULL;
  return idx;
}

/* CAConstString#sort_index → int64 CArray of the ascending sort permutation. */
static VALUE
rb_ca_const_string_sort_index (VALUE self)
{
  ca_const_string_scan_t s;
  ca_size_t *idx;
  VALUE vout;
  CArray *co;
  int64_t *op;
  ca_size_t i;

  ca_const_string_scan_begin(self, &s);
  idx = ca_const_string_sort_perm(&s);
  vout = rb_carray_new(CA_INT64, s.ca->ndim, s.ca->dim, 0, NULL);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, co);
  op = (int64_t *) co->ptr;
  for ( i = 0; i < s.n; i++ ) op[i] = (int64_t) idx[i];
  xfree(idx);
  ca_const_string_scan_end(&s);
  return vout;
}

/* CAConstString#sort is defined in Ruby (lib/carray/const_string.rb) as `self[sort_index]`,
   i.e. a no-copy view over the offset source (buffer + offsets shared, only
   the gather order changes) — consistent with CArray#sort being a view. */

/* CAConstString#min / #max → the byte-min / byte-max element as a frozen String,
   skipping masked elements; nil if empty or all masked. */
static VALUE
ca_const_string_extremum (VALUE self, int want_max)
{
  ca_const_string_scan_t s;
  const char *p, *bestp = NULL;
  int32_t len, bestlen = 0;
  ca_size_t i;
  int found = 0;

  ca_const_string_scan_begin(self, &s);
  for ( i = 0; i < s.n; i++ ) {
    int c;
    if ( ! ca_const_string_record(&s, i, &p, &len) ) continue;
    if ( ! found ) {
      bestp = p; bestlen = len; found = 1;
      continue;
    }
    c = memcmp(p, bestp, (size_t) (len < bestlen ? len : bestlen));
    if ( c == 0 ) c = (len > bestlen) - (len < bestlen);
    if ( ( want_max && c > 0 ) || ( ! want_max && c < 0 ) ) {
      bestp = p; bestlen = len;
    }
  }
  if ( ! found ) {
    ca_const_string_scan_end(&s);
    return Qnil;
  }
  {
    VALUE str = rb_enc_str_new(bestp, bestlen, rb_enc_from_index(s.ca->encoding_id));
    ca_const_string_scan_end(&s);
    return rb_str_freeze(str);
  }
}

static VALUE rb_ca_const_string_min (VALUE self) { return ca_const_string_extremum(self, 0); }
static VALUE rb_ca_const_string_max (VALUE self) { return ca_const_string_extremum(self, 1); }

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_const_string_s_allocate (VALUE klass)
{
  CAConstString *ca;
  return TypedData_Make_Struct(klass, CAConstString, &catext_data_type, ca);
}

static VALUE
rb_ca_const_string_initialize_copy (VALUE self, VALUE other)
{
  CAConstString *ca, *cs;
  TypedData_Get_Struct(self,  CAConstString, &catext_data_type, ca);
  TypedData_Get_Struct(other, CAConstString, &catext_data_type, cs);
  /* T.0/T.1: shallow re-setup (shares buffer + offset-source).  T.3 will
     replace this with compacting deep copy (rebased offsets + compacted
     buffer + detach). */
  if ( ca_func[CA_OBJ_CONST_STRING].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_CONST_STRING, cs->parent->ndim);
  }
  ca_const_string_setup(ca, cs->parent, cs->buffer, cs->encoding_id);
  return self;
}

void
Init_ca_obj_const_string (void)
{
  rb_cCAConstString = rb_define_class("CAConstString", rb_cCAFace);

  ca_const_string_func.struct_size = sizeof(CAConstString);
  ca_const_string_func.pool_bytes  = ca_const_string_pool_bytes;
  ca_const_string_func.pool_init   = ca_const_string_pool_init;

  CA_OBJ_CONST_STRING = ca_install_obj_type(rb_cCAConstString,
                                    &catext_data_type,
                                    rb_cCArrayMask,
                                    &carray_mask_data_type,
                                    &ca_const_string_func, sizeof(ca_const_string_func));
  rb_define_const(rb_cObject, "CA_OBJ_CONST_STRING", INT2NUM(CA_OBJ_CONST_STRING));

  rb_define_alloc_func(rb_cCAConstString, rb_ca_const_string_s_allocate);
  rb_define_method(rb_cCAConstString, "initialize_copy",
                               rb_ca_const_string_initialize_copy, 1);

  rb_define_singleton_method(rb_cCAConstString, "wrap", rb_ca_const_string_wrap_method, -1);
  rb_define_singleton_method(rb_cCAConstString, "__build__", rb_ca_const_string_build, 2);
  rb_define_method(rb_cCAConstString, "encoding", rb_ca_const_string_encoding, 0);
  rb_define_method(rb_cCAConstString, "buffer",   rb_ca_const_string_buffer, 0);
  rb_define_method(rb_cCAConstString, "storage_to_scalar",
                               rb_ca_const_string_storage_to_scalar, 1);

  /* copy = compacting deep copy; to_ca is the same descent point. */
  rb_define_method(rb_cCAConstString, "copy",  rb_ca_const_string_copy, 0);
  rb_define_method(rb_cCAConstString, "to_ca", rb_ca_const_string_to_ca, -1);

  /* native byte ops (§3.7) */
  rb_define_method(rb_cCAConstString, "byte_length", rb_ca_const_string_byte_length, 0);
  rb_define_method(rb_cCAConstString, "eq",          rb_ca_const_string_eq, 1);
  rb_define_method(rb_cCAConstString, "count",       rb_ca_const_string_count, 1);
  rb_define_method(rb_cCAConstString, "start_with?", rb_ca_const_string_start_with, 1);
  rb_define_method(rb_cCAConstString, "end_with?",   rb_ca_const_string_end_with, 1);
  rb_define_method(rb_cCAConstString, "include?",    rb_ca_const_string_include, 1);

  /* native exact-lookup search: flat index of the first byte-equal element,
     or nil.  `search` is what str_matches consumes; find_value_index is the
     *_index-named surface (both exact, mask-skipping). */
  rb_define_method(rb_cCAConstString, "search",           rb_ca_const_string_search, 1);
  rb_define_method(rb_cCAConstString, "find_value_index",  rb_ca_const_string_search, 1);

  /* native sort_index / min / max (§3.7), byte-memcmp comparator.
     sort / sort_copy are defined in Ruby on top of sort_index. */
  rb_define_method(rb_cCAConstString, "sort_index", rb_ca_const_string_sort_index, 0);
  rb_define_method(rb_cCAConstString, "min",        rb_ca_const_string_min, 0);
  rb_define_method(rb_cCAConstString, "max",        rb_ca_const_string_max, 0);

  /* Y-pilot: Face-local C-level fast path for per-cell scalar fetch. */
  ca_face_register_storage_to_scalar(CA_OBJ_CONST_STRING, rb_ca_const_string_storage_to_scalar);

  /* F.S1: CAConstString's `buffer` field is per-parent (= each CAConstString holds its
     own frozen byte String; cell offsets index into THIS instance's
     buffer).  Multi-parent CAStack lift cannot reuse list[0]'s buffer
     without producing wrong reads for cells from other parents.  Mark
     as not-portable so CAStack rejects multi-parent CAConstString lift. */
  ca_face_register_state_portable(CA_OBJ_CONST_STRING, 0);
}
