/* ---------------------------------------------------------------------------

  Ruby MemoryView protocol adapter for CArray.

  Exporter (zero-copy, alias-only producer):
  - entity arrays (CArray, CScalar, CAWrap): direct, contiguous
  - CARefer / CABlock / CAFarray / CATranspose / CAField / plain
    CAStride: zero-copy strided (composed to the root entity)
  - CARepeat: zero-copy via stride=0 on repeated axes
  - non-alias views (CASelect, CAGrid, CAShift, CAWindow, CAFake,
    CAReduce, CABitarray, CABitfield, CAObject): rejected by the
    producer; use CArray.from_memory_view for a snapshot copy

  Importer:
  - CArray.from_memory_view (copy; accepts strided)
  - CArray.wrap_memory_view (zero-copy; contiguous only)

  Format-string contract:
  - Producer emits Ruby's vocabulary (ruby/memory_view.h), records
    included; only the types Ruby cannot spell ('?', 'Zf' / 'Zd', "Ns")
    stay PEP 3118.  The consumer is Postel-permissive (accepts synonyms
    other producers emit).  A record's member names, which Ruby's format
    cannot carry, are CARecord#memory_view_field_names.
  - See docs/interop/MemoryViewFormat.md for the format-string contract.
  - See devel/DESIGN_MemoryView.md for the design rationale.
  - See docs/interop/MemoryView.md for the user-facing MV API.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"   /* ca_strip_face for Face producers */
#include "carray_internal.h"
#include "ruby/memory_view.h"
#include "ruby/st.h"
#include "ruby/thread_native.h"
#include <ctype.h>
#include <string.h>

/* private_data holds the view's own copy of a record format (see ca_mv_get)
   and is NULL otherwise; ca_mv_release frees it.  No other per-view state:
   ca_mv_get is alias-only. */

/* ---------------- forward declarations for non-public structs ----------------
   CABlock, CARefer, CARepeat are declared in carray.h.  CAFarray
   and CATranspose are CAStride subclasses -- this file reads
   CAStride's strides[]/base_offset directly for them. */

/* ---------------- runtime-assigned obj_type ids ---------------- */

#define CA_MV_NUM_RUNTIME_OBJ_TYPES 11

typedef struct {
  const char *class_name;
  const char *const_name;
  int         id;          /* -1 until resolved at Init */
  VALUE       klass;       /* Qnil until resolved at Init */
  int         strategy;    /* one of ca_mv_strategy_t (filled in lookup table) */
} ca_mv_runtime_type_t;

/* Set strategy via numeric constants below; ca_mv_strategy_t enum is
   forward-declared.  We can't put a forward-declared enum into a static
   initialiser, so use a parallel integer table. */

/* ---------------- obj_type strategy ---------------- */

/* Strategy = label only.  The export is alias-only and is decided by
   ca_mv_compose_to_entity alone; the labels say which classes get a
   MemoryView registration and keep ca_mv_runtime_types[] readable.
   Every class labelled CA_MV_ATTACH is refused by that resolver. */
typedef enum {
  CA_MV_REJECT,
  CA_MV_DIRECT,   /* entity / wrap / scalar; ca->ptr valid as-is */
  CA_MV_REFER,    /* CARefer; alias via compose-to-root */
  CA_MV_BLOCK,    /* CABlock; alias with strides via compose-to-root */
  CA_MV_FARRAY,   /* CAFarray; alias with column-major strides */
  CA_MV_TRANS,    /* CATranspose; alias with permuted strides */
  CA_MV_REPEAT,   /* CARepeat; alias with stride=0 on repeated dims */
  CA_MV_ATTACH,   /* unreachable: rejected by alias-chain check */
} ca_mv_strategy_t;

/* Resolved at Init_carray_memory_view.  Runtime obj_type ids are stored
   here so ca_mv_reject_reason_for can name the class it refuses. */
static ca_mv_runtime_type_t ca_mv_runtime_types[CA_MV_NUM_RUNTIME_OBJ_TYPES] = {
  { "CAFarray",    "CA_OBJ_FARRAY",    -1, Qnil, /* CA_MV_FARRAY  */ 4 },
  { "CATranspose", "CA_OBJ_TRANSPOSE", -1, Qnil, /* CA_MV_TRANS   */ 5 },
  { "CAGrid",      "CA_OBJ_GRID",      -1, Qnil, /* CA_MV_ATTACH  */ 7 },
  { "CAShift",     "CA_OBJ_SHIFT",     -1, Qnil, /* CA_MV_ATTACH  */ 7 },
  { "CAWindow",    "CA_OBJ_WINDOW",    -1, Qnil, /* CA_MV_ATTACH  */ 7 },
  { "CAFake",      "CA_OBJ_FAKE",      -1, Qnil, /* CA_MV_ATTACH  */ 7 },
  /* CAField is a CAStride subclass: zero-copy strided export via
     parent->ptr + base_offset, no materialise. */
  { "CAField",     "CA_OBJ_FIELD",     -1, Qnil, /* CA_MV_BLOCK   */ 3 },
  { "CAReduce",    "CA_OBJ_REDUCE",    -1, Qnil, /* CA_MV_ATTACH  */ 7 },
  { "CABitarray",  "CA_OBJ_BITARRAY",  -1, Qnil, /* CA_MV_REJECT  */ 0 },
  { "CABitfield",  "CA_OBJ_BITFIELD",  -1, Qnil, /* CA_MV_REJECT  */ 0 },
  /* CARecord: composite Face wrapping a CA_FIXLEN entity 1:1
     (ca->ptr aliases parent->ptr). ATTACH strategy
     is the conservative choice — same as CAFake; storage layout is
     identical to parent so direct export would also work in principle. */
  { "CARecord",    "CA_OBJ_RECORD",    -1, Qnil, /* CA_MV_ATTACH  */ 7 },
};

/* ---------------- format / data_type mapping ----------------
   Bidirectional table.  Outbound table (ca_mv_format_for) picks the
   specifier each CArray data_type publishes at the top level of a
   MemoryView.  Inbound table (ca_mv_data_type_from_format) is Postel:
   it accepts a wider set of synonyms that other producers emit (they
   describe int32 differently).

   The outbound spellings follow ruby/memory_view.h, which documents
   `format` as a sequence of pack-derived specifiers and expects
   item_size to equal rb_memory_view_item_size_from_format(format).
   PEP 3118 reuses several of those letters for other types, so the two
   vocabularies agree on `i` / `I` / `q` / `Q` / `f` / `d` and disagree
   below 32 bits: what PEP calls `b` / `B` / `h` / `H`, Ruby calls
   `c` / `C` / `s` / `S`.  Emitting Ruby's spelling is what lets a
   generic Ruby consumer -- Fiddle::MemoryView, say -- read elements out
   of a CArray at all; PEP-speaking consumers are reached across the
   language boundary, where pycall-memoryview translates.

   Three types have no Ruby spelling at all: boolean and the two
   complex widths.  They keep their PEP form, which Ruby's parser
   rejects, because the alternative ("C" for a boolean, "dd" for a
   complex) would misdescribe the data rather than merely fail to
   describe it. */

static const char *
ca_mv_format_for (int8_t data_type)
{
  switch (data_type) {
  case CA_BOOLEAN: return "?";   /* no Ruby spelling */
  case CA_INT8:    return "c";
  case CA_UINT8:   return "C";
  case CA_INT16:   return "s";
  case CA_UINT16:  return "S";
  case CA_INT32:   return "i";
  case CA_UINT32:  return "I";
  case CA_INT64:   return "q";
  case CA_UINT64:  return "Q";
  case CA_FLOAT32: return "f";
  case CA_FLOAT64: return "d";
  case CA_CMPLX64:  return "Zf";   /* no Ruby spelling */
  case CA_CMPLX128: return "Zd";   /* no Ruby spelling */
  default:
    return NULL;
  }
}

/* The Ruby MemoryView specifier for one record member, written into `out`
   with its byte order as ruby/memory_view.h writes it: a suffix ('<' / '>')
   on an integer, its own letter on a float ('e' / 'E' little, 'g' / 'G'
   big).  A member without a declared byte order is in the machine's.
   Returns 0 for a member the format has no item for: a nested struct, an
   array member, :fixlen, :object, a bit member, or a complex member with a
   declared byte order (Ruby has no complex specifier to suffix). */
static int
ca_mv_record_member_spec (VALUE info, char *out, size_t outlen,
                          ca_size_t *bytes_out)
{
  VALUE type = rb_ary_entry(info, 1);
  VALUE opts = rb_ary_entry(info, 2);
  VALUE endian = Qnil;
  const char *base;
  int8_t dt;
  if (!SYMBOL_P(type)) return 0;
  ID type_id = SYM2ID(type);
  if (type_id == rb_intern("bitfield") ||
      type_id == rb_intern("fixlen")   ||
      type_id == rb_intern("object")) {
    return 0;
  }
  dt = rb_ca_guess_type(rb_sym2str(type));
  base = ca_mv_format_for(dt);
  if (!base) return 0;
  if (RB_TYPE_P(opts, T_HASH)) {
    endian = rb_hash_aref(opts, ID2SYM(rb_intern("endian")));
  }
  if ( SYMBOL_P(endian) && ( SYM2ID(endian) == rb_intern("big")
                             || SYM2ID(endian) == rb_intern("little") ) ) {
    int big = ( SYM2ID(endian) == rb_intern("big") );
    switch (dt) {
    case CA_FLOAT32: base = big ? "g" : "e"; break;
    case CA_FLOAT64: base = big ? "G" : "E"; break;
    case CA_CMPLX64: case CA_CMPLX128: return 0;
    case CA_BOOLEAN: case CA_INT8: case CA_UINT8: break;   /* one byte */
    default:
      snprintf(out, outlen, "%s%s", base, big ? ">" : "<");
      *bytes_out = (ca_size_t) ca_sizeof[dt];
      return 1;
    }
  }
  snprintf(out, outlen, "%s", base);
  *bytes_out = (ca_size_t) ca_sizeof[dt];
  return 1;
}

/* Build (or fetch from cache) the Ruby MemoryView format of a record: the
   members' specifiers in their byte order in the record, with "x<N>" for
   the padding between them and after the last.  Ruby's format has no
   member names; the record array gives them as #memory_view_field_names,
   one per specifier.  Returns Qnil for a record the format cannot describe:
   a member it has no item for (see above), or members that overlap or come
   out of offset order (a union).

   The result is frozen and cached on the data_class.  It is an ordinary
   String that compaction can move, so a view takes a copy of its bytes
   rather than its pointer (ca_mv_get). */
static VALUE
ca_mv_struct_format_for_data_class (VALUE data_class)
{
  ID iv = rb_intern("@__mv_record_format__");
  if (rb_ivar_defined(data_class, iv)) {
    VALUE cached = rb_ivar_get(data_class, iv);
    /* Qfalse is a sentinel meaning "tried, found unsupported". */
    return (cached == Qfalse) ? Qnil : cached;
  }

  VALUE members = rb_const_get(data_class, rb_intern("MEMBERS"));
  VALUE table   = rb_const_get(data_class, rb_intern("MEMBER_TABLE"));
  long  n       = RARRAY_LEN(members);
  long  i;
  VALUE buf     = rb_str_buf_new(4 * n + 8);
  ca_size_t cursor = 0;
  ca_size_t data_size = NUM2SIZE(rb_const_get(data_class, rb_intern("DATA_SIZE")));
  char spec[16], pad[32];

  for (i = 0; i < n; i++) {
    VALUE info = rb_hash_aref(table, rb_ary_entry(members, i));
    ca_size_t offset, mb;
    if (NIL_P(info)) goto unsupported;
    offset = NUM2SIZE(rb_ary_entry(info, 0));
    if (offset < cursor) goto unsupported;
    if (!ca_mv_record_member_spec(info, spec, sizeof(spec), &mb)) goto unsupported;
    if (offset > cursor) {
      snprintf(pad, sizeof(pad), "x%lld", (long long) (offset - cursor));
      rb_str_buf_cat_ascii(buf, pad);
    }
    rb_str_buf_cat_ascii(buf, spec);
    cursor = offset + mb;
  }
  if (cursor > data_size) goto unsupported;
  if (cursor < data_size) {
    snprintf(pad, sizeof(pad), "x%lld", (long long) (data_size - cursor));
    rb_str_buf_cat_ascii(buf, pad);
  }

  rb_obj_freeze(buf);
  rb_ivar_set(data_class, iv, buf);
  return buf;

unsupported:
  rb_ivar_set(data_class, iv, Qfalse);
  return Qnil;
}

static int
ca_mv_data_type_exportable (int8_t data_type)
{
  return ca_mv_format_for(data_type) != NULL;
}

/* Same as ca_mv_data_type_exportable, but also accepts CA_FIXLEN:
   - with a data_class -> emit the record's Ruby format (members in order)
   - without a data_class -> emit PEP 3118 "Ns" fixed-bytes format */
static int
ca_mv_ca_exportable (CArray *ca, VALUE obj)
{
  if (ca_mv_data_type_exportable(ca->data_type)) return 1;
  if (ca->data_type == CA_FIXLEN) {
    if (RTEST(rb_ca_has_data_class(obj))) {
      VALUE klass = rb_ca_data_class(obj);
      if (NIL_P(klass)) return 0;
      VALUE fmt = ca_mv_struct_format_for_data_class(klass);
      return NIL_P(fmt) ? 0 : 1;
    }
    /* Plain CA_FIXLEN (bytes > 0) exports as "Ns". */
    return (ca->bytes > 0) ? 1 : 0;
  }
  return 0;
}

/* Reverse mapping for the importer (Postel consumer; see
   docs/interop/MemoryViewFormat.md for the contract).  Both vocabularies
   are read: Ruby's (byte order as a suffix, "i<", "s!>"; '_' for '!';
   'e' 'E' 'g' 'G' 'n' 'N' 'v' 'V' carrying their own order; 'j' 'J' for
   intptr) and PEP 3118's (order as a prefix '<' '>' '!' '=' '@'; 'b' 'B'
   'h' 'H' '?'; 'Zf' 'Zd').  The alignment modifier '|' is skipped.
   - CArray stores host order, so an order that disagrees with the host
     is refused.  A one-byte type has no order, so any is accepted.
   - Dispatch on the (type, item_size) tuple.
   - Synonyms accepted but not emitted: 'C'/1 maps to UINT8 (so other
     producers' bool buffers are received as UINT8); 'ff' / 'dd' map to
     complex64/128 (producers that split complex into two floats). */

/* Byte order named in a format: 0 none, 1 little, 2 big. */
#define CA_MV_ORDER_NONE   0
#define CA_MV_ORDER_LITTLE 1
#define CA_MV_ORDER_BIG    2

static int
ca_mv_order_merge (int a, int b)
{
  if ( a == CA_MV_ORDER_NONE ) return b;
  if ( b == CA_MV_ORDER_NONE ) return a;
  return ( a == b ) ? a : -1;
}

static int8_t
ca_mv_data_type_from_format (const char *format, ssize_t item_size)
{
  const int host = (ca_endian == CA_LITTLE_ENDIAN) ? CA_MV_ORDER_LITTLE
                                                   : CA_MV_ORDER_BIG;
  const char *fmt = format ? format : "";
  char buf[16];
  size_t len;
  int order = CA_MV_ORDER_NONE;
  int one_byte;

  if (*fmt == '|') fmt++;
  switch (*fmt) {
  case '<':                     order = CA_MV_ORDER_LITTLE; fmt++; break;
  case '>': case '!':           order = CA_MV_ORDER_BIG;    fmt++; break;
  case '=': case '@':           order = host;               fmt++; break;
  }
  len = strlen(fmt);
  if ( len == 0 || len >= sizeof(buf) ) return -1;
  memcpy(buf, fmt, len + 1);

  /* Ruby's suffix form on a single type: "i<", "s!>", "q_<". */
  if ( len >= 2 && len <= 3 && isalpha((unsigned char) buf[0]) &&
       ( buf[len - 1] == '<' || buf[len - 1] == '>' ) ) {
    order = ca_mv_order_merge(order, buf[len - 1] == '<' ? CA_MV_ORDER_LITTLE
                                                         : CA_MV_ORDER_BIG);
    if ( order < 0 ) return -1;
    buf[--len] = '\0';
  }
  /* '_' is Ruby's spelling of the native-size modifier '!'. */
  if ( len == 2 && buf[1] == '_' ) {
    buf[1] = '!';
  }
  /* Types that carry their own byte order. */
  if ( len == 1 ) {
    int own = CA_MV_ORDER_NONE;
    switch (buf[0]) {
    case 'e': case 'E': case 'v': case 'V': own = CA_MV_ORDER_LITTLE; break;
    case 'g': case 'G': case 'n': case 'N': own = CA_MV_ORDER_BIG;    break;
    }
    order = ca_mv_order_merge(order, own);
    if ( order < 0 ) return -1;
  }

  one_byte = ( len == 1 && strchr("cCbB?", buf[0]) != NULL );
  if ( order != CA_MV_ORDER_NONE && order != host && ! one_byte ) {
    return -1;
  }
  fmt = buf;

  /* single-byte formats */
  if (strcmp(fmt, "c")  == 0 && item_size == 1) return CA_INT8;
  if (strcmp(fmt, "C")  == 0 && item_size == 1) return CA_UINT8;
  if (strcmp(fmt, "b")  == 0 && item_size == 1) return CA_INT8;
  if (strcmp(fmt, "B")  == 0 && item_size == 1) return CA_UINT8;
  if (strcmp(fmt, "?")  == 0 && item_size == 1) return CA_BOOLEAN;

  /* 16-bit */
  if ((strcmp(fmt, "s")  == 0 || strcmp(fmt, "s!") == 0 ||
       strcmp(fmt, "h")  == 0) && item_size == 2) return CA_INT16;
  if ((strcmp(fmt, "S")  == 0 || strcmp(fmt, "S!") == 0 ||
       strcmp(fmt, "H")  == 0 || strcmp(fmt, "v")  == 0 ||
       strcmp(fmt, "n")  == 0) && item_size == 2) return CA_UINT16;

  /* 32-bit */
  if ((strcmp(fmt, "l")  == 0 || strcmp(fmt, "i")  == 0 ||
       strcmp(fmt, "i!") == 0 || strcmp(fmt, "l!") == 0 ||
       strcmp(fmt, "j")  == 0) && item_size == 4) return CA_INT32;
  if ((strcmp(fmt, "L")  == 0 || strcmp(fmt, "I")  == 0 ||
       strcmp(fmt, "I!") == 0 || strcmp(fmt, "L!") == 0 ||
       strcmp(fmt, "J")  == 0 || strcmp(fmt, "V")  == 0 ||
       strcmp(fmt, "N")  == 0) && item_size == 4) return CA_UINT32;

  /* 64-bit.  `l`/`L` at item_size 8 accepted as LP64 native long
     (numpy default for `np.array([1,2,3]).dtype == int64`). */
  if ((strcmp(fmt, "q")  == 0 || strcmp(fmt, "q!") == 0 ||
       strcmp(fmt, "l!") == 0 || strcmp(fmt, "l")  == 0 ||
       strcmp(fmt, "j")  == 0) && item_size == 8) return CA_INT64;
  if ((strcmp(fmt, "Q")  == 0 || strcmp(fmt, "Q!") == 0 ||
       strcmp(fmt, "L!") == 0 || strcmp(fmt, "L")  == 0 ||
       strcmp(fmt, "J")  == 0) && item_size == 8) return CA_UINT64;

  /* floats */
  if ((strcmp(fmt, "f")  == 0 || strcmp(fmt, "e")  == 0 ||
       strcmp(fmt, "g")  == 0) && item_size == 4) return CA_FLOAT32;
  if ((strcmp(fmt, "d")  == 0 || strcmp(fmt, "E")  == 0 ||
       strcmp(fmt, "G")  == 0) && item_size == 8) return CA_FLOAT64;

  /* complex: PEP 3118 'Zf' / 'Zd' canonical. */
  if (strcmp(fmt, "Zf") == 0 && item_size == 8)  return CA_CMPLX64;
  if (strcmp(fmt, "Zd") == 0 && item_size == 16) return CA_CMPLX128;
  /* Consumer synonyms — accepted but not emitted. */
  if (strcmp(fmt, "ff") == 0 && item_size == 8)  return CA_CMPLX64;
  if (strcmp(fmt, "dd") == 0 && item_size == 16) return CA_CMPLX128;

  /* Fixed-length bytes: PEP 3118 "Ns" (e.g. "8s") -> CA_FIXLEN, bytes = N.
     N must match item_size exactly; mismatch is rejected the same way the
     numeric branches reject a width disagreement.  N must be positive
     (rejects "0s" — CA_FIXLEN's bytes > 0 invariant). */
  {
    size_t len = strlen(fmt);
    if (len >= 2 && fmt[len - 1] == 's') {
      char *endp = NULL;
      long n = strtol(fmt, &endp, 10);
      if (endp == fmt + len - 1 && n > 0 && n == (long) item_size) {
        return CA_FIXLEN;
      }
    }
  }

  return -1;
}

/* Derive the data_type a MemoryView producer would import as, by parsing its
   format — without importing the data.  This is the canonical "what data type is
   this MV" question, decoupled from the import strategy (copy via
   from_memory_view vs zero-copy via wrap_memory_view).  Used by
   ca_arg_to_data_type so CArray.result_type / promote_list can treat an MV
   producer as an operand.  Returns -1 (so the caller falls back to value
   inference) when obj is not an MV producer, is typeless (format == NULL), or
   carries a format carray cannot represent host-endian. */
int8_t
ca_mv_probe_data_type (VALUE obj)
{
  rb_memory_view_t view;
  int8_t data_type;
  if ( ! rb_memory_view_available_p(obj) ) {
    return -1;
  }
  /* Zero-init before get: release() unconditionally frees item_desc.components
     even on producers that leave it uninitialized (see ca_mv_acquire_and_validate). */
  memset(&view, 0, sizeof(view));
  if ( ! rb_memory_view_get(obj, &view, RUBY_MEMORY_VIEW_STRIDES) ) {
    if ( ! rb_memory_view_get(obj, &view, RUBY_MEMORY_VIEW_SIMPLE) ) {
      return -1;
    }
  }
  data_type = ca_mv_data_type_from_format(view.format, view.item_size);
  rb_memory_view_release(&view);
  return data_type;
}

/* Per-element byte width for consumer-side wrap/from CArray allocation.
   For numeric types it is `ca_sizeof[data_type]`; for CA_FIXLEN it is the
   MemoryView item_size, since fixlen has no compile-time element width. */
static inline ca_size_t
ca_mv_carray_bytes_for (int8_t data_type, ssize_t item_size)
{
  return (data_type == CA_FIXLEN) ? (ca_size_t) item_size
                                  : (ca_size_t) ca_sizeof[data_type];
}

/* ---------------- helpers ---------------- */

static int
ca_mv_extract (VALUE obj, CArray **out)
{
  if (! rb_typeddata_is_kind_of(obj, &carray_data_type)) {
    return 0;
  }
  *out = (CArray *) DATA_PTR(obj);
  return 1;
}

static ssize_t *
ca_mv_alloc_shape (CArray *ca)
{
  ssize_t *shape;
  int i;
  if (ca->ndim <= 0) return NULL;
  shape = (ssize_t *) xmalloc(sizeof(ssize_t) * ca->ndim);
  for (i = 0; i < ca->ndim; i++) {
    shape[i] = (ssize_t) ca->dim[i];
  }
  return shape;
}

static ssize_t *
ca_mv_alloc_strides_contiguous (CArray *ca, ssize_t *shape, bool row_major)
{
  ssize_t *strides;
  if (ca->ndim <= 0) return NULL;
  strides = (ssize_t *) xmalloc(sizeof(ssize_t) * ca->ndim);
  rb_memory_view_fill_contiguous_strides(
      (ssize_t) ca->ndim, (ssize_t) ca->bytes, shape, row_major, strides);
  return strides;
}

/* Byte strides for the CAStride family come from
   ca_stride_compose_to_root, which produces them directly from the
   CAStride prefix (composing through any CAStride parent chain to
   entity); no per-view stride helpers live here. */

/* ---------------- alias-chain wrap predicate ----------------
   wrap_memory_view exports zero-copy.  A view is wrappable iff its
   parent chain bottoms out at an entity through links that all
   alias (contig CAStride family).  Other ancestors (CASelect,
   CAFake, non-contig CAStride, etc.) would require materialising a
   snapshot, which has incorrect view semantics for MV consumers
   (deferred sync on release, stale reads, no explicit-sync API).
   Consumers that want a snapshot should use CArray.from_memory_view. */

typedef struct {
  int          depth;        /* 0 = the view itself, 1 = parent, 2 = grand-, ... */
  const char  *class_name;   /* class name of the offending link */
  const char  *reason;       /* short explanation */
  int          face;         /* refused because it is a Face: a copy is
                                refused too, so no copy is suggested */
} ca_mv_reject_t;

static bool ca_mv_stride_is_contig (CAStride *ca);   /* defined below */

/* True iff `ca`'s obj_type uses ca_stride_func's attach routine -- i.e.
   it is CAStride or a subclass that inherits CAStride semantics. */
static inline bool
ca_mv_is_castride_family (CArray *ca)
{
  extern ca_operation_function_t ca_stride_func;
  return ca_func[ca->obj_type].attach == ca_stride_func.attach;
}

static const char *
ca_mv_class_name_of (CArray *ca)
{
  VALUE klass = ca_class[ca->obj_type];
  return NIL_P(klass) ? "(unknown)" : rb_class2name(klass);
}

static const char *
ca_mv_reject_reason_for (CArray *ca)
{
  /* Compile-time obj_types we know about */
  if (ca->obj_type == CA_OBJ_SELECT)          return "boolean-mask selection (positions not expressible as strides)";
  if (ca->obj_type == CA_OBJ_OBJECT)          return "stores Ruby VALUEs, not raw bytes";
  /* Runtime-assigned obj_types: look up by name in the strategy table */
  for (int i = 0; i < CA_MV_NUM_RUNTIME_OBJ_TYPES; i++) {
    if (ca_mv_runtime_types[i].id == ca->obj_type) {
      const char *n = ca_mv_runtime_types[i].class_name;
      if (!strcmp(n, "CAGrid"))     return "grid selection (positions not expressible as strides)";
      if (!strcmp(n, "CAShift"))    return "shifted view with bounds-fill (no in-place inverse)";
      if (!strcmp(n, "CAWindow"))   return "windowed view with bounds-fill (no in-place inverse)";
      if (!strcmp(n, "CAFake"))     return "lazy type conversion (values differ from underlying bytes)";
      /* CAField exports as a zero-copy CAStride and never hits this
         diagnostic. */
      if (!strcmp(n, "CAReduce"))   return "OR-reduce (no in-place inverse)";
      if (!strcmp(n, "CABitarray")) return "sub-byte (bit) addressing";
      if (!strcmp(n, "CABitfield")) return "sub-byte (bitfield) addressing";
    }
  }
  return "this kind of view is not alias-capable";
}

/* The entities whose bytes the producer exports: CArray, CAWrap and
   CScalar.  An entity installed from outside the core (ca_install_obj_type,
   e.g. a CASource subclass) may hold its bytes elsewhere (cold at rest),
   so neither it nor a view onto it is exported. */
static inline bool
ca_mv_is_core_entity (CArray *ca)
{
  return ca->obj_type == CA_OBJ_ARRAY ||
         ca->obj_type == CA_OBJ_ARRAY_WRAP ||
         ca->obj_type == CA_OBJ_SCALAR;
}

/* Resolve ca to an (entity, composed_strides, composed_base) triple
   suitable for zero-copy strided export.  Uses ca_stride_compose_to_root
   to fold the CAStride parent chain (alias-eligible OR not, as long
   as strides decompose cleanly into single parent-dim advances).

   Succeeds when the resolved root is an entity (CArray/CAWrap/CScalar).
   On failure (leaf is not CAStride family, or compose stops before
   entity), fills *rej.

   `out_strides` and `out_base` are filled only when ca is a CAStride
   leaf (i.e. compose was performed).  For entity-class ca, callers
   compute contig row-major strides themselves. */
static bool
ca_mv_compose_to_entity (CArray *ca, ca_mv_reject_t *rej,
                         CArray **out_entity,
                         ca_size_t *out_strides,
                         ca_size_t *out_base)
{
  rej->face = 0;
  /* A Face is a 1:1 alias of its storage, so it is exported as that
     storage -- but only a Face that registered its bytes as carrying its
     values (ca_face_register_memory_view).  The format comes from the Face
     (data_class for a CARecord); the layout from the storage below. */
  if (ca_is_face(ca)) {
    if (! ca_face_memory_view_exportable(ca)) {
      rej->depth = 0;
      rej->class_name = ca_mv_class_name_of(ca);
      rej->reason = "a Face whose storage bytes do not carry its values "
                    "without the Face; export its storage instead "
                    "(e.g. .ticks, .codes)";
      rej->face = 1;
      return false;
    }
    ca = ca_strip_face(ca);
  }
  if (ca_is_entity(ca)) {
    if (! ca_mv_is_core_entity(ca)) {
      rej->depth = 0;
      rej->class_name = ca_mv_class_name_of(ca);
      rej->reason = "installed outside the core; its bytes are not "
                    "exported";
      return false;
    }
    *out_entity = ca;
    *out_base = 0;
    return true;
  }
  if (!ca_mv_is_castride_family(ca)) {
    rej->depth = 0;
    rej->class_name = ca_mv_class_name_of(ca);
    rej->reason = ca_mv_reject_reason_for(ca);
    return false;
  }
  CArray *root;
  ca_stride_compose_to_root((CAStride *) ca, &root, out_strides, out_base);
  if (!ca_is_entity(root)) {
    rej->depth = -1;
    rej->class_name = ca_mv_class_name_of(root);
    if (ca_mv_is_castride_family(root)) {
      rej->reason = "CAStride chain stride pattern does not compose "
                    "linearly into entity (e.g. reshape across non-contig)";
    } else {
      rej->reason = ca_mv_reject_reason_for(root);
    }
    return false;
  }
  if (! ca_mv_is_core_entity(root)) {
    rej->depth = -1;
    rej->class_name = ca_mv_class_name_of(root);
    rej->reason = "installed outside the core; its bytes are not exported";
    return false;
  }
  *out_entity = root;
  return true;
}

/* Predicate wrapper for available_p / reject_reason: discards the
   resolved (entity, strides, base). */
static bool
ca_mv_check_alias_chain (CArray *ca, ca_mv_reject_t *rej)
{
  CArray *entity;
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t base;
  return ca_mv_compose_to_entity(ca, rej, &entity, strides, &base);
}

/* Local copy of ca_obj_stride.c's contiguity check (that one is
   static).  Returns true iff strides match a row-major contig
   layout over the view's own dim. */
static bool
ca_mv_stride_is_contig (CAStride *ca)
{
  ca_size_t expected = ca->bytes;
  int8_t k;
  for (k = ca->ndim - 1; k >= 0; k--) {
    if (ca->dim[k] != 1 && ca->strides[k] != expected) return false;
    expected *= ca->dim[k];
  }
  return true;
}

/* ---------------- get / release / available_p ---------------- */

static bool
ca_mv_available_p (VALUE obj)
{
  CArray *ca;
  ca_mv_reject_t rej;
  if (! ca_mv_extract(obj, &ca)) return false;
  if (! ca_mv_ca_exportable(ca, obj)) return false;
  if (ca_has_mask(ca)) return false;
  /* The same resolver decides the export in ca_mv_get, so what this
     says is what the export does.  Wrap-via-MV exports are zero-copy:
     require an alias chain to a core entity.  Non-alias views (CASelect, CAFake, etc.) and CAStride
     chains broken by a non-contig link cannot be wrapped without a
     snapshot, which has wrong semantics for MV consumers. */
  return ca_mv_check_alias_chain(ca, &rej);
}

/* "Ns" format for a plain CA_FIXLEN of N bytes.  The C strings are kept
   in a table keyed by N for the life of the process, so the pointer stays
   valid for any view, and a frozen array (which cannot take an ivar) is
   exported like any other.  The table is shared by every Ractor, hence
   the lock. */
static st_table              *ca_mv_fixlen_formats = NULL;
static rb_nativethread_lock_t ca_mv_fixlen_formats_lock;

static const char *
ca_mv_fixlen_format (ca_size_t bytes)
{
  st_data_t found;
  char     *fmt;
  rb_nativethread_lock_lock(&ca_mv_fixlen_formats_lock);
  if ( st_lookup(ca_mv_fixlen_formats, (st_data_t) bytes, &found) ) {
    rb_nativethread_lock_unlock(&ca_mv_fixlen_formats_lock);
    return (const char *) found;
  }
  rb_nativethread_lock_unlock(&ca_mv_fixlen_formats_lock);
  fmt = ALLOC_N(char, 24);
  snprintf(fmt, 24, "%llds", (long long) bytes);
  rb_nativethread_lock_lock(&ca_mv_fixlen_formats_lock);
  if ( st_lookup(ca_mv_fixlen_formats, (st_data_t) bytes, &found) ) {
    xfree(fmt);
    fmt = (char *) found;
  }
  else {
    st_insert(ca_mv_fixlen_formats, (st_data_t) bytes, (st_data_t) fmt);
  }
  rb_nativethread_lock_unlock(&ca_mv_fixlen_formats_lock);
  return fmt;
}

static bool
ca_mv_get (VALUE obj, rb_memory_view_t *view, int flags)
{
  CArray *ca;
  CArray *storage;
  ssize_t *shape = NULL;
  ssize_t *strides = NULL;
  void *data_ptr = NULL;
  const char *format;
  char *record_format = NULL;
  int writable_request;

  if (! ca_mv_extract(obj, &ca)) return false;
  if (! ca_mv_ca_exportable(ca, obj)) return false;
  if (ca_has_mask(ca)) return false;

  writable_request = (flags & RUBY_MEMORY_VIEW_WRITABLE) ? 1 : 0;
  if (writable_request && ca_is_readonly(ca)) return false;
  /* Defense in depth: reject WRITABLE requests on Ruby-level frozen objects
     even if CA_FLAG_READ_ONLY wasn't set (e.g., freeze bypassed via
     Object#freeze on a subclass). */
  if (writable_request && OBJ_FROZEN(obj)) return false;

  /* Resolve the chain to (entity, composed_strides, composed_base) with
     the resolver available_p uses, so the two cannot disagree.  The
     layout is the storage's: a Face that got through is a 1:1 alias of
     it. */
  CArray *resolved_entity = NULL;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base = 0;
  {
    ca_mv_reject_t rej;
    if (! ca_mv_compose_to_entity(ca, &rej, &resolved_entity,
                                  composed_strides, &composed_base)) {
      return false;
    }
  }
  storage = ca_is_face(ca) ? ca_strip_face(ca) : ca;

  /* SIMPLE consumer on non-contig view would need a snapshot -- not
     offered (consumers wanting a snapshot use from_memory_view). */
  {
    int wants_strides_early = (flags & RUBY_MEMORY_VIEW_STRIDES) ? 1 : 0;
    if (!wants_strides_early &&
        ca_mv_is_castride_family(storage) &&
        !ca_mv_stride_is_contig((CAStride *) storage)) {
      return false;
    }
  }

  /* Format string, resolved before shape / strides are allocated since
     building it can raise.  Primitive types use the top-level table;
     CA_FIXLEN + data_class emits the record's format, cached on the class
     as a String.  The String can move, so the view carries its own copy in
     private_data, freed by ca_mv_release. */
  if (ca->data_type == CA_FIXLEN && RTEST(rb_ca_has_data_class(obj))) {
    VALUE klass = rb_ca_data_class(obj);
    VALUE fmt   = ca_mv_struct_format_for_data_class(klass);
    long  len   = RSTRING_LEN(fmt);
    record_format = ALLOC_N(char, len + 1);
    memcpy(record_format, RSTRING_PTR(fmt), len);
    record_format[len] = '\0';
    RB_GC_GUARD(fmt);
    format = record_format;
  }
  else if (ca->data_type == CA_FIXLEN) {
    /* Plain CA_FIXLEN (no data_class): PEP 3118 "Ns" fixed-bytes. */
    format = ca_mv_fixlen_format(ca->bytes);
  }
  else {
    format = ca_mv_format_for(ca->data_type);
  }

  if (ca_is_entity(storage)) {
    /* Entity / wrap / scalar: its own buffer, always valid.  No attach
       needed.  A CScalar is exported with ndim 0 and no shape, so none is
       taken: release frees only what the view carries. */
    data_ptr = storage->ptr;
    if (ca->ndim >= 1 && storage->obj_type != CA_OBJ_SCALAR) {
      shape = ca_mv_alloc_shape(ca);
      strides = ca_mv_alloc_strides_contiguous(ca, shape, true);
    }
  }
  else {
    /* A CAStride-family view (CARefer / CABlock / CAFarray / CATranspose
       / CARepeat / CAField / plain CAStride) composed to an entity.
       Expose `entity->ptr + composed_base` as data_ptr and
       composed_strides as strides, both in entity byte space.  The entity
       owns its bytes (always valid via view->obj's parent chain while the
       consumer holds the view).

       CAREFUL: do not ca_attach the view here (nor ca_sync / ca_detach at
       release).  Exposure is alias-only: the consumer writes directly into
       root bytes, so a sync would scatter bytes back to root as a no-op
       chain -- and that chain triggers ca_update_mask / ca_sync(mask)
       recursion that can raise on an invariant violation.  Raising from a
       release callback is fatal during GC sweep (newobj_of during sweep ->
       BUG). */
    int8_t k;
    shape = ca_mv_alloc_shape(ca);
    strides = (ssize_t *) xmalloc(sizeof(ssize_t) * ca->ndim);
    for (k = 0; k < ca->ndim; k++) strides[k] = (ssize_t) composed_strides[k];
    data_ptr = resolved_entity->ptr + composed_base;
  }

  view->obj = obj;
  view->data = data_ptr;
  /* PEP 3118 convention: byte_size is product(shape) * item_size for
     every layout (contiguous or strided).  NumPy, Numo, and Arrow all
     follow this; consumers that need the addressable span for strided
     views compute Σ (shape[k]-1)*|strides[k]| + item_size themselves. */
  view->byte_size = (ssize_t) ca_length(ca);
  view->readonly = ca_is_readonly(ca) ? true : false;
  view->format = format;
  view->item_size = (ssize_t) ca->bytes;
  view->item_desc.components = NULL;
  view->item_desc.length = 0;
  view->ndim = (storage->obj_type == CA_OBJ_SCALAR) ? 0 : (ssize_t) ca->ndim;
  view->shape = (view->ndim == 0) ? NULL : shape;
  view->strides = (view->ndim == 0) ? NULL : strides;
  view->sub_offsets = NULL;
  view->private_data = record_format;

  /* Enforce caller's layout request. */
  {
    int wants_strides = (flags & RUBY_MEMORY_VIEW_STRIDES) ? 1 : 0;
    int wants_row     = (flags & RUBY_MEMORY_VIEW_ROW_MAJOR)    == RUBY_MEMORY_VIEW_ROW_MAJOR;
    int wants_col     = (flags & RUBY_MEMORY_VIEW_COLUMN_MAJOR) == RUBY_MEMORY_VIEW_COLUMN_MAJOR;
    bool row_ok = (view->ndim == 0) ? true : rb_memory_view_is_row_major_contiguous(view);
    bool col_ok = (view->ndim == 0) ? true : rb_memory_view_is_column_major_contiguous(view);
    if (wants_row && !row_ok) goto reject;
    if (wants_col && !col_ok) goto reject;
    if (!wants_strides && !row_ok) goto reject;
  }

  return true;

reject:
  /* Layout-mismatch reject: caller wanted SIMPLE/contig but we built a
     strided view, or vice versa.  ca_mv_get is alias-only and does not
     attach anything, so just free the helper shape/strides buffers and
     return false; there is no attach state to unwind. */
  if (shape)   { xfree(shape);   view->shape   = NULL; }
  if (strides) { xfree(strides); view->strides = NULL; }
  if (record_format) {
    xfree(record_format);
    view->format = NULL;
    view->private_data = NULL;
  }
  return false;
}

static bool
ca_mv_release (VALUE obj, rb_memory_view_t *view)
{
  (void) obj;
  if (view->shape) {
    xfree((void *) view->shape);
    view->shape = NULL;
  }
  if (view->strides) {
    xfree((void *) view->strides);
    view->strides = NULL;
  }
  /* CAREFUL: no attach/sync/detach here.  ca_mv_get is alias-only -- the
     consumer wrote directly into root bytes, so a ca_sync would scatter
     back as a no-op chain that can trigger ca_update_mask /
     ca_sync(ca->mask) recursion and raise; raising from a release
     callback is fatal during GC sweep.  See ca_mv_get's CAStride-family
     case comment for the full rationale. */
  if (view->private_data) {
    xfree(view->private_data);
    view->private_data = NULL;
  }
  return true;
}

/* ---------------- importer ----------------
   Two-tier API mirroring numo-narray-memoryview:

     CArray.from_memory_view(obj)  -> CArray  (copy, independent buffer)
     CArray.wrap_memory_view(obj)  -> CAWrap  (zero-copy, shared memory)

   from_memory_view: borrow a SIMPLE view, copy bytes into a freshly
   owned CArray, release the view immediately.  The result is detached
   from the source.

   wrap_memory_view: borrow a SIMPLE view and keep it alive for the
   lifetime of a CAWrap.  The source object stays anchored via an ivar;
   a TypedData holder (also stored as an ivar) releases the view in its
   dfree callback when the CAWrap is collected. */

/* One borrowed view and the geometry read from it.  The geometry is
   copied out and normalised once (a 0-d view as one element, omitted
   shape or strides filled in as row-major), so nothing below reads the
   producer's shape or strides arrays again.

   The holder is a Ruby object from before the view is taken, so a raise
   at any later point loses nothing: the importers release it at once
   (rb_protect / rb_ensure), and the holder's dfree releases it in any
   case.  `lo` / `hi` bound the bytes the elements reach, relative to
   view.data. */
typedef struct {
  rb_memory_view_t view;
  bool valid;
  int8_t ndim;
  ca_size_t dim[CA_RANK_MAX];
  ssize_t strides[CA_RANK_MAX];
  ca_size_t elements;
  bool contiguous;
  ssize_t lo, hi;
} ca_mv_imported_holder_t;

static void
ca_mv_imported_holder_free (void *p)
{
  ca_mv_imported_holder_t *h = (ca_mv_imported_holder_t *) p;
  if (h->valid) {
    h->valid = false;
    /* While a view is exported Ruby keeps the producer alive, so in an
       ordinary sweep it is still here.  At exit, though, the objects
       left are freed in heap order and the producer may have gone first
       (its slot is T_NONE with the class still set).  Its release
       callback would then get a dead object, and one that checks the
       type raises, which is fatal during GC.  Skip the release there:
       the process is ending, so only the components are freed. */
    if (! RB_SPECIAL_CONST_P(h->view.obj) &&
        RB_BUILTIN_TYPE(h->view.obj) == RUBY_T_NONE) {
      xfree((void *) h->view.item_desc.components);
    }
    else {
      rb_memory_view_release(&h->view);
    }
  }
  xfree(h);
}

static size_t
ca_mv_imported_holder_size (const void *p)
{
  return sizeof(ca_mv_imported_holder_t);
}

static const rb_data_type_t ca_mv_imported_holder_data_type = {
  .wrap_struct_name = "CArrayImportedMemoryViewHolder",
  .function = {
    .dmark = NULL,        /* source_obj is anchored via ivar on the wrapper */
    .dfree = ca_mv_imported_holder_free,
    .dsize = ca_mv_imported_holder_size,
    .dcompact = NULL
  },
  .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE
ca_mv_holder_new (ca_mv_imported_holder_t **out)
{
  /* Zero-filled: valid is false and the view's item_desc.components is
     NULL, which release frees unconditionally (red-arrow 24.0.0 leaves
     that field unwritten, apache/arrow#45187). */
  return TypedData_Make_Struct(rb_cObject, ca_mv_imported_holder_t,
                               &ca_mv_imported_holder_data_type, *out);
}

static void
ca_mv_holder_release (ca_mv_imported_holder_t *h)
{
  if (h != NULL && h->valid) {
    h->valid = false;
    rb_memory_view_release(&h->view);
  }
}

/* Take a view from src: STRIDES first, SIMPLE for producers that offer
   only a contiguous buffer.  `writable` asks the producer for a writable
   view; a producer that refuses that but gives a read-only one is a
   read-only source. */
static void
ca_mv_holder_acquire (ca_mv_imported_holder_t *h, VALUE src, int writable,
                      const char *who)
{
  int extra = writable ? RUBY_MEMORY_VIEW_WRITABLE : 0;
  memset(&h->view, 0, sizeof(h->view));
  if ( ! rb_memory_view_get(src, &h->view, RUBY_MEMORY_VIEW_STRIDES | extra) ) {
    memset(&h->view, 0, sizeof(h->view));
    if ( ! rb_memory_view_get(src, &h->view, RUBY_MEMORY_VIEW_SIMPLE | extra) ) {
      if ( writable ) {
        memset(&h->view, 0, sizeof(h->view));
        if ( rb_memory_view_get(src, &h->view, RUBY_MEMORY_VIEW_STRIDES) ||
             rb_memory_view_get(src, &h->view, RUBY_MEMORY_VIEW_SIMPLE) ) {
          h->valid = true;
          rb_raise(rb_eRuntimeError,
                   "MemoryView source is read-only; can't wrap as writable");
        }
      }
      rb_raise(rb_eArgError, "%sobject does not support MemoryView", who);
    }
  }
  h->valid = true;
  if ( writable && h->view.readonly ) {
    rb_raise(rb_eRuntimeError,
             "MemoryView source is read-only; can't wrap as writable");
  }
}

/* Read the view's geometry for elements of `item_size` bytes, and check
   it against the buffer.  The buffer is [data, data + byte_size).  For a
   strided view byte_size is the element count times item_size (the
   convention CArray's own producer, NumPy and Arrow follow), which does
   not bound where the strides reach, so only that count is checked; for
   a contiguous view the shape is checked against the bytes. */
static void
ca_mv_holder_read_geometry (ca_mv_imported_holder_t *h, ssize_t item_size,
                            const char *who)
{
  const rb_memory_view_t *v = &h->view;
  ssize_t expect, need;
  int8_t k;

  /* rank-check: a producer's rank, named by which MemoryView it is */
  if ( v->ndim < 0 || v->ndim > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "%sMemoryView ndim (%ld) exceeds CArray CA_RANK_MAX (%d)",
             who, (long) v->ndim, CA_RANK_MAX);
  }
  if ( v->ndim == 0 ) {
    h->ndim = 1;
    h->dim[0] = 1;
  }
  else if ( v->shape == NULL ) {
    /* Only 1-D is readable without a shape: length = byte_size / item_size. */
    if ( v->ndim > 1 ) {
      rb_raise(rb_eArgError,
               "%sMemoryView reports ndim %ld but provides no shape array",
               who, (long) v->ndim);
    }
    h->ndim = 1;
    h->dim[0] = (ca_size_t) (item_size > 0 ? v->byte_size / item_size : 0);
  }
  else {
    h->ndim = (int8_t) v->ndim;
    for (k = 0; k < h->ndim; k++) {
      if ( v->shape[k] < 0 ) {
        rb_raise(rb_eArgError, "%sMemoryView shape[%d] is negative (%ld)",
                 who, (int) k, (long) v->shape[k]);
      }
      h->dim[k] = (ca_size_t) v->shape[k];
    }
  }
  h->elements = ca_shape_elements(h->ndim, h->dim, (ca_size_t) item_size);

  if ( v->ndim >= 1 && v->shape != NULL && v->strides != NULL ) {
    for (k = 0; k < h->ndim; k++) {
      h->strides[k] = v->strides[k];
    }
  }
  else {
    expect = item_size;
    for (k = h->ndim - 1; k >= 0; k--) {
      h->strides[k] = expect;
      expect *= (ssize_t) h->dim[k];
    }
  }

  h->contiguous = true;
  expect = item_size;
  for (k = h->ndim - 1; k >= 0; k--) {
    if ( h->dim[k] > 1 && h->strides[k] != expect ) {
      h->contiguous = false;
    }
    expect *= (ssize_t) h->dim[k];
  }

  h->lo = h->hi = 0;
  if ( h->elements > 0 ) {
    h->hi = item_size;
    for (k = 0; k < h->ndim; k++) {
      ssize_t reach;
      if ( __builtin_mul_overflow((ssize_t) h->dim[k] - 1, h->strides[k], &reach) ||
           ( reach < 0 ? __builtin_add_overflow(h->lo, reach, &h->lo)
                       : __builtin_add_overflow(h->hi, reach, &h->hi) ) ) {
        rb_raise(rb_eArgError, "%sMemoryView strides reach too far", who);
      }
    }
  }

  need = (ssize_t) h->elements * item_size;
  if ( v->byte_size < need ) {
    rb_raise(rb_eArgError,
             "%sMemoryView reports %ld bytes, but its shape needs %ld",
             who, (long) v->byte_size, (long) need);
  }
}

/* Take the data side's view and resolve its data_type.
   `explicit_data_type` (the data_type: keyword) must agree with a typed
   producer's format and names the type of a typeless one.
   `typeless_data_type` names the type only when the producer is typeless
   (wrap_readonly / wrap_writable, which adapt a typed producer
   afterwards).  A typeless producer's bytes are read as one 1-D run, so
   one whose own geometry is strided is refused. */
static int8_t
ca_mv_holder_take_data (ca_mv_imported_holder_t *h, VALUE src,
                        int8_t explicit_data_type, int8_t typeless_data_type,
                        int writable)
{
  rb_memory_view_t *v = &h->view;
  int8_t data_type;

  ca_mv_holder_acquire(h, src, writable, "");

  if ( v->format == NULL ) {
    ssize_t target;
    data_type = ( explicit_data_type >= 0 ) ? explicit_data_type : typeless_data_type;
    if ( data_type < 0 ) {
      rb_raise(rb_eArgError,
               "typeless MemoryView (format=NULL, %ld bytes); "
               "specify the target data_type via data_type: kwarg or use a "
               "concrete CArray::<Dtype> factory class",
               (long) v->byte_size);
    }
    if ( ca_mv_format_for(data_type) == NULL ) {
      rb_raise(rb_eArgError,
               "target data_type is not representable via MemoryView");
    }
    ca_mv_holder_read_geometry(h, v->item_size > 0 ? v->item_size : 1, "");
    if ( ! h->contiguous ) {
      rb_raise(rb_eArgError,
               "typeless MemoryView is strided; its bytes cannot be read as "
               "one run of %s", ca_type_name[data_type]);
    }
    target = (ssize_t) ca_sizeof[data_type];
    if ( v->byte_size % target != 0 ) {
      rb_raise(rb_eArgError,
               "byte_size %ld is not a multiple of target item_size %ld",
               (long) v->byte_size, (long) target);
    }
    h->ndim       = 1;
    h->dim[0]     = (ca_size_t) (v->byte_size / target);
    h->strides[0] = target;
    h->elements   = h->dim[0];
    h->contiguous = true;
    h->lo = 0;
    h->hi = v->byte_size;
    return data_type;
  }

  data_type = ca_mv_data_type_from_format(v->format, v->item_size);
  if ( data_type < 0 ) {
    rb_raise(rb_eArgError, "unsupported MemoryView format: %s (item_size=%ld)",
             v->format, (long) v->item_size);
  }
  if ( explicit_data_type >= 0 && explicit_data_type != data_type ) {
    rb_raise(rb_eArgError,
             "explicit data_type does not match producer format "
             "(producer: %s, requested data_type %s)",
             v->format, ca_type_name[explicit_data_type]);
  }
  ca_mv_holder_read_geometry(h, v->item_size, "");
  return data_type;
}

/* Take the mask's view: one byte per element (bool / uint8 / int8),
   contiguous, of the data side's shape. */
static void
ca_mv_holder_take_mask (ca_mv_imported_holder_t *m, VALUE src,
                        const ca_mv_imported_holder_t *d)
{
  rb_memory_view_t *v = &m->view;
  int8_t k;

  ca_mv_holder_acquire(m, src, 0, "mask: ");
  if ( v->format != NULL ) {
    int8_t dt = ca_mv_data_type_from_format(v->format, v->item_size);
    if ( dt != CA_BOOLEAN && dt != CA_UINT8 && dt != CA_INT8 ) {
      rb_raise(rb_eArgError, "mask: format must be bool/uint8/int8 (got %s)",
               v->format);
    }
  }
  if ( v->item_size != 1 ) {
    rb_raise(rb_eArgError, "mask: item_size must be 1 (got %ld)",
             (long) v->item_size);
  }
  ca_mv_holder_read_geometry(m, 1, "mask: ");
  if ( m->ndim != d->ndim ) {
    rb_raise(rb_eArgError, "mask: ndim (%d) does not match data ndim (%d)",
             (int) m->ndim, (int) d->ndim);
  }
  for (k = 0; k < d->ndim; k++) {
    if ( m->dim[k] != d->dim[k] ) {
      rb_raise(rb_eArgError, "mask: shape[%d] (%ld) does not match data shape (%ld)",
               (int) k, (long) m->dim[k], (long) d->dim[k]);
    }
  }
  if ( ! m->contiguous ) {
    rb_raise(rb_eArgError,
             "mask: strided masks are not supported in this release; "
             "pass a row-major contiguous mask buffer");
  }
}

/* Walk the elements of a view in row-major order, calling `fn` with each
   element's address.  Returns false as soon as fn does. */
static bool
ca_mv_holder_each (const ca_mv_imported_holder_t *h,
                   bool (*fn)(const char *elem, void *arg), void *arg)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t n;
  int8_t k;
  const char *base = (const char *) h->view.data;

  for (k = 0; k < h->ndim; k++) idx[k] = 0;
  for (n = 0; n < h->elements; n++) {
    ssize_t off = 0;
    for (k = 0; k < h->ndim; k++) {
      off += (ssize_t) idx[k] * h->strides[k];
    }
    if ( ! fn(base + off, arg) ) {
      return false;
    }
    for (k = h->ndim - 1; k >= 0; k--) {
      if ( ++idx[k] < h->dim[k] ) break;
      idx[k] = 0;
    }
  }
  return true;
}

static bool
ca_mv_byte_is_bit (const char *elem, void *arg)
{
  (void) arg;
  return *(const uint8_t *) elem <= 1;
}

typedef struct {
  char  *dst;
  size_t item_size;
} ca_mv_gather_t;

static bool
ca_mv_gather_one (const char *elem, void *arg)
{
  ca_mv_gather_t *g = (ca_mv_gather_t *) arg;
  memcpy(g->dst, elem, g->item_size);
  g->dst += g->item_size;
  return true;
}

/* A boolean CArray holds 0 or 1 in each byte.  A copy can normalise other
   bytes; a wrap shares them, so it refuses a buffer that holds any. */
static void
ca_mv_check_bits (const ca_mv_imported_holder_t *h, const char *who)
{
  if ( ! ca_mv_holder_each(h, ca_mv_byte_is_bit, NULL) ) {
    rb_raise(rb_eArgError,
             "%sboolean MemoryView holds bytes other than 0 and 1; "
             "a wrap cannot normalise them (CArray.from_memory_view can)", who);
  }
}

/* Extract the optional data_type: and mask: keywords from argv.
   Returns the resolved data_type (-1 if not specified) and fills
   *out_obj / *out_mask.  data_type: accepts symbols (:int32), integer
   constants (CA_INT32), and data_type marker classes (CArray::Int32
   etc.); marker classes are resolved via their `DataType` constant (set
   up by lib/carray/construct.rb), since rb_ca_guess_type does not
   natively recognise them. */
static int8_t
ca_mv_extract_type_and_mask_kwargs (int argc, VALUE *argv,
                                    VALUE *out_obj, VALUE *out_mask)
{
  volatile VALUE robj = Qnil, ropt = Qnil, rtype = Qnil, rmask = Qnil;
  int8_t data_type = -1;
  ca_size_t bytes;
  rb_scan_args(argc, argv, "1:", (VALUE *) &robj, (VALUE *) &ropt);
  if (! NIL_P(ropt)) {
    rb_scan_options(ropt, "data_type,mask", &rtype, &rmask);
  }
  *out_obj = robj;
  *out_mask = rmask;
  if (! NIL_P(rtype)) {
    if (RB_TYPE_P(rtype, T_CLASS) &&
        rb_const_defined(rtype, rb_intern("DataType"))) {
      rtype = rb_const_get(rtype, rb_intern("DataType"));
    }
    rb_ca_guess_type_and_bytes(rtype, INT2NUM(0), &data_type, &bytes);
  }
  return data_type;
}

typedef struct {
  VALUE  obj, mask_obj, target_class;
  int8_t explicit_data_type, typeless_data_type;
  int    writable;
  ca_mv_imported_holder_t *data, *mask;
  VALUE  data_holder_obj, mask_holder_obj;
} ca_mv_import_args_t;

/* The body of wrap_memory_view.  Runs under rb_protect; the caller
   releases both views if it raises. */
static VALUE
ca_mv_wrap_body (VALUE arg)
{
  ca_mv_import_args_t *a = (ca_mv_import_args_t *) arg;
  ca_mv_imported_holder_t *d = a->data, *m = a->mask;
  rb_memory_view_t *v = &d->view;
  ca_size_t bytes;
  int8_t data_type;
  volatile VALUE wrap;
  CArray *ca;

  data_type = ca_mv_holder_take_data(d, a->obj, a->explicit_data_type,
                                     a->typeless_data_type, a->writable);
  bytes = ca_mv_carray_bytes_for(data_type, v->item_size);

  /* A strided producer comes back as a CAStride, so a caller who asked
     for a class would get something that is not it. */
  if ( a->target_class != rb_cCAWrap && ! d->contiguous ) {
    rb_raise(rb_eArgError,
             "%s was requested, but this producer is strided, so the result "
             "would be a CAStride; pass a row-major contiguous producer, or "
             "use CArray.from_memory_view for a copy",
             rb_class2name(a->target_class));
  }

  if ( m != NULL ) {
    ca_mv_holder_take_mask(m, a->mask_obj, d);
    if ( ! d->contiguous ) {
      rb_raise(rb_eArgError,
               "mask: combining mask: with a strided data source is not "
               "supported in this release; pass a row-major contiguous "
               "data source");
    }
    /* A mask that shares bytes with the values would take every write
       to a value as a write to the mask. */
    if ( d->elements > 0 ) {
      const char *dlo = (const char *) v->data + d->lo;
      const char *dhi = (const char *) v->data + d->hi;
      const char *mlo = (const char *) m->view.data;
      const char *mhi = mlo + m->elements;
      if ( mlo < dhi && dlo < mhi ) {
        rb_raise(rb_eArgError, "mask: the mask buffer overlaps the data buffer");
      }
    }
    ca_mv_check_bits(m, "mask: ");
  }
  if ( data_type == CA_BOOLEAN ) {
    ca_mv_check_bits(d, "");
  }

  if ( ! d->contiguous ) {
    /* The foreign bytes the elements reach, [data + lo, data + hi), as a
       byte array, with the user's CAStride over it.  The parent covers
       every byte a stride can land on, so a mask made for the view (one
       mask byte per parent byte) has a place for every element whatever
       the strides are. */
    ca_size_t span = (ca_size_t) (d->hi - d->lo);
    ca_size_t strides_arr[CA_RANK_MAX];
    volatile VALUE inner_wrap;
    CArray *iw;
    int8_t k;

    inner_wrap = rb_ca_wrap_new(CA_UINT8, 1, &span, 1, NULL,
                                (char *) v->data + d->lo);
    rb_ivar_set(inner_wrap, rb_intern("memory_view_source"), a->obj);
    rb_ivar_set(inner_wrap, rb_intern("memory_view_holder"), a->data_holder_obj);
    if ( v->readonly && ca_mv_extract(inner_wrap, &iw) ) {
      ca_set_flag(iw, CA_FLAG_READ_ONLY);
    }
    for (k = 0; k < d->ndim; k++) {
      strides_arr[k] = (ca_size_t) d->strides[k];
    }
    wrap = rb_ca_stride_new(inner_wrap, data_type, bytes, d->ndim, d->dim,
                            strides_arr, (ca_size_t) -d->lo);
    if ( v->readonly && ca_mv_extract(wrap, &ca) ) {
      ca_set_flag(ca, CA_FLAG_READ_ONLY);
    }
    return wrap;
  }

  /* Same struct rb_ca_wrap_new would build, wrapped in the class the
     receiver asked for. */
  wrap = ca_wrap_struct_as(ca_wrap_new(data_type, d->ndim, d->dim, bytes,
                                       NULL, (char *) v->data),
                           a->target_class);
  rb_ivar_set(wrap, rb_intern("memory_view_source"), a->obj);
  rb_ivar_set(wrap, rb_intern("memory_view_holder"), a->data_holder_obj);
  ca_mv_extract(wrap, &ca);
  if ( v->readonly ) {
    ca_set_flag(ca, CA_FLAG_READ_ONLY);
  }

  /* Borrowed mask: a CAWrap over the mask bytes, anchored on the same
     wrap so its lifetime is the data side's.  A store writes the mask
     cell of every element it stores, so a read-only mask makes the whole
     array read-only. */
  if ( m != NULL ) {
    CArray *mask_ca = (CArray *) ca_wrap_new(CA_BOOLEAN, d->ndim, d->dim, 1,
                                             NULL, (char *) m->view.data);
    ca_set_flag(mask_ca, CA_FLAG_MASK_ARRAY);
    if ( m->view.readonly ) {
      ca_set_flag(mask_ca, CA_FLAG_READ_ONLY);
      ca_set_flag(ca, CA_FLAG_READ_ONLY);
    }
    ca->mask = mask_ca;
    rb_ivar_set(wrap, rb_intern("mask_memory_view_source"), a->mask_obj);
    rb_ivar_set(wrap, rb_intern("mask_memory_view_holder"), a->mask_holder_obj);
  }
  return wrap;
}

static void
ca_mv_import_args_init (ca_mv_import_args_t *a, VALUE obj, VALUE mask_obj)
{
  a->obj = obj;
  a->mask_obj = mask_obj;
  a->data_holder_obj = ca_mv_holder_new(&a->data);
  a->mask = NULL;
  a->mask_holder_obj = Qnil;
  if ( ! NIL_P(mask_obj) ) {
    a->mask_holder_obj = ca_mv_holder_new(&a->mask);
  }
}

/* Wrap obj's MemoryView without copying.  `explicit_data_type` and
   `typeless_data_type` are as for ca_mv_holder_take_data; `writable`
   asks the producer for a writable view (wrap_writable).  Every view
   taken is released before a raise leaves. */
VALUE
ca_mv_wrap (VALUE obj, VALUE mask_obj, VALUE target_class,
            int8_t explicit_data_type, int8_t typeless_data_type, int writable)
{
  ca_mv_import_args_t a;
  volatile VALUE result;
  int tag = 0;

  ca_mv_import_args_init(&a, obj, mask_obj);
  a.target_class = target_class;
  a.explicit_data_type = explicit_data_type;
  a.typeless_data_type = typeless_data_type;
  a.writable = writable;
  /* protect: the views are released at once rather than when the holders are collected */
  result = rb_protect(ca_mv_wrap_body, (VALUE) &a, &tag);
  if ( tag ) {
    ca_mv_holder_release(a.mask);
    ca_mv_holder_release(a.data);
    rb_jump_tag(tag);
  }
  RB_GC_GUARD(a.data_holder_obj);
  RB_GC_GUARD(a.mask_holder_obj);
  return result;
}

/* CArray.wrap_memory_view(obj, data_type: nil, mask: nil) -- zero-copy.
   A row-major contiguous producer comes back as a CAWrap; a strided one
   as a CAStride over the foreign bytes, its strides (negative ones
   included) kept.

   When the producer is typeless (format=NULL), `data_type:` must be
   supplied; the byte buffer is reinterpreted as that data_type, ndim=1.

   The receiver picks the class of the result.  Called on CArray itself
   it builds a CAWrap; called on a subclass of CAWrap it builds that
   subclass, so a gem bridging a foreign buffer can name where the array
   came from without writing a C extension of its own.  The class marks
   the provenance of this object only -- a view derived from it is a
   CABlock or a CAStride like any other. */
static VALUE
rb_ca_s_wrap_memory_view (int argc, VALUE *argv, VALUE klass)
{
  VALUE obj, mask_obj, target_class;
  int8_t explicit_data_type =
    ca_mv_extract_type_and_mask_kwargs(argc, argv,
                                        (VALUE *) &obj, (VALUE *) &mask_obj);

  target_class = ( klass == rb_cCArray ) ? rb_cCAWrap : klass;
  if ( ! RTEST(rb_class_inherited_p(target_class, rb_cCAWrap)) ) {
    rb_raise(rb_eTypeError,
             "wrap_memory_view builds a CAWrap; %s is not a subclass of it",
             rb_class2name(target_class));
  }
  return ca_mv_wrap(obj, mask_obj, target_class, explicit_data_type, -1, 0);
}

/* The body of from_memory_view.  Runs under rb_ensure, which releases
   both views however it leaves. */
static VALUE
ca_mv_from_body (VALUE arg)
{
  ca_mv_import_args_t *a = (ca_mv_import_args_t *) arg;
  ca_mv_imported_holder_t *d = a->data, *m = a->mask;
  rb_memory_view_t *v = &d->view;
  int8_t data_type;
  volatile VALUE result;
  CArray *ca;
  ca_size_t i;

  data_type = ca_mv_holder_take_data(d, a->obj, a->explicit_data_type, -1, 0);
  if ( m != NULL ) {
    ca_mv_holder_take_mask(m, a->mask_obj, d);
  }

  result = rb_carray_new(data_type, d->ndim, d->dim,
                         ca_mv_carray_bytes_for(data_type, v->item_size), NULL);
  ca_mv_extract(result, &ca);

  if ( d->contiguous ) {
    memcpy(ca->ptr, v->data, (size_t) ca_length(ca));
  }
  else {
    ca_mv_gather_t g;
    g.dst = ca->ptr;
    g.item_size = (size_t) v->item_size;
    ca_mv_holder_each(d, ca_mv_gather_one, &g);
  }
  if ( data_type == CA_BOOLEAN ) {
    ca_boolean_normalize_bytes(ca->ptr, ca->elements);
  }

  /* Mask bytes: any non-zero byte means masked. */
  if ( m != NULL ) {
    const uint8_t *src = (const uint8_t *) m->view.data;
    boolean8_t *dst;
    ca_create_mask(ca);
    dst = (boolean8_t *) ca->mask->ptr;
    for (i = 0; i < ca->elements; i++) {
      dst[i] = ( src[i] != 0 ) ? 1 : 0;
    }
  }
  return result;
}

static VALUE
ca_mv_from_release (VALUE arg)
{
  ca_mv_import_args_t *a = (ca_mv_import_args_t *) arg;
  ca_mv_holder_release(a->mask);
  ca_mv_holder_release(a->data);
  return Qnil;
}

/* CArray.from_memory_view(obj, data_type: nil, mask: nil) -- copy into an
   independent CArray.  Accepts strided typed sources (gather copy) and
   typeless sources (bytes reinterpreted as `data_type:`).  The result is
   a plain CArray whatever the receiver: a copy no longer borrows anything
   for a class to name.  A receiver that is not CArray or a CAWrap could
   not be returned, so it is refused. */
static VALUE
rb_ca_s_from_memory_view (int argc, VALUE *argv, VALUE klass)
{
  ca_mv_import_args_t a;
  VALUE obj, mask_obj;
  volatile VALUE result;
  int8_t explicit_data_type =
    ca_mv_extract_type_and_mask_kwargs(argc, argv,
                                        (VALUE *) &obj, (VALUE *) &mask_obj);

  if ( klass != rb_cCArray &&
       ! RTEST(rb_class_inherited_p(klass, rb_cCAWrap)) ) {
    rb_raise(rb_eTypeError,
             "from_memory_view builds a CArray; %s cannot be returned from it",
             rb_class2name(klass));
  }
  ca_mv_import_args_init(&a, obj, mask_obj);
  a.explicit_data_type = explicit_data_type;
  result = rb_ensure(ca_mv_from_body, (VALUE) &a, ca_mv_from_release, (VALUE) &a);
  RB_GC_GUARD(a.data_holder_obj);
  RB_GC_GUARD(a.mask_holder_obj);
  return result;
}

/* ---------------- Ruby method ---------------- */

static VALUE
rb_ca_s_memory_view_available_p (VALUE klass, VALUE obj)
{
  return rb_memory_view_available_p(obj) ? Qtrue : Qfalse;
}

/* Diagnostic: if memory_view_available? returns false on a CArray,
   why?  Returns nil (no problem detected) or a String explaining
   the offending link in the parent chain.  Useful for users hitting
   the alias-chain reject who can't tell from the generic
   "memory view not available" error what specifically went wrong. */
static VALUE
rb_ca_s_memory_view_reject_reason (VALUE klass, VALUE obj)
{
  CArray *ca;
  ca_mv_reject_t rej;
  if (! ca_mv_extract(obj, &ca)) {
    return Qnil;
  }
  if (! ca_mv_ca_exportable(ca, obj)) {
    if (ca->data_type == CA_FIXLEN && RTEST(rb_ca_has_data_class(obj))) {
      return rb_str_new_cstr("struct data_class contains a member type the MV "
                             "producer cannot express yet (nested struct, "
                             "CArray template, :fixlen, or :object)");
    }
    return rb_sprintf("element data_type (%d) is not exportable via memory_view "
                      "(CA_FIXLEN without data_class / CA_OBJECT)",
                      ca->data_type);
  }
  if (ca_has_mask(ca)) {
    return rb_str_new_cstr("array has a mask; use arr.value (mask-ignoring CARefer) "
                           "or arr.strip_mask(fill) first");
  }
  if (! ca_mv_check_alias_chain(ca, &rej)) {
    const char *where;
    if      (rej.depth <  0) where = "the root";
    else if (rej.depth == 0) where = "this view";
    else if (rej.depth == 1) where = "parent";
    else                     where = NULL;   /* ancestor[N] */
    if (where) {
      return rb_sprintf("%s is %s (%s); zero-copy wrap not possible.%s",
                        where, rej.class_name, rej.reason,
                        rej.face ? "" : " Export arr.copy for a snapshot.");
    } else {
      return rb_sprintf("ancestor[%d] is %s (%s); zero-copy wrap not possible.%s",
                        rej.depth - 1, rej.class_name, rej.reason,
                        rej.face ? "" : " Export arr.copy for a snapshot.");
    }
  }
  return Qnil;
}

/* Test hook: expose the format-string parser directly so the consumer
   table (see docs/interop/MemoryViewFormat.md) can be exercised without needing
   a producer that emits every synonym.  Returns the CArray data_type
   integer on accept, or nil on reject. */
static VALUE
rb_ca_s_parse_memory_view_format (VALUE klass, VALUE fmt_v, VALUE item_size_v)
{
  const char *fmt = NIL_P(fmt_v) ? NULL : StringValueCStr(fmt_v);
  ssize_t item_size = (ssize_t) NUM2LL(item_size_v);
  int8_t dt;
  if (item_size <= 0) return Qnil;
  dt = ca_mv_data_type_from_format(fmt, item_size);
  if (dt < 0) return Qnil;
  /* Return Symbol so the test hook output compares directly against
     CA_* (Symbol) constants. */
  return rb_ca_data_type_to_sym(dt);
}

/* Test hook: return the MV format string the producer would emit
   for `obj`, without actually building the rb_memory_view_t.  Used
   by spec_ai to verify the record format emitted for CAStruct arrays.
   Returns nil if obj isn't exportable. */
static VALUE
rb_ca_s_memory_view_format (VALUE klass, VALUE obj)
{
  CArray *ca;
  if (! ca_mv_extract(obj, &ca)) return Qnil;
  if (! ca_mv_ca_exportable(ca, obj)) return Qnil;
  if (ca->data_type == CA_FIXLEN && RTEST(rb_ca_has_data_class(obj))) {
    return ca_mv_struct_format_for_data_class(rb_ca_data_class(obj));
  }
  if (ca->data_type == CA_FIXLEN) {
    /* Plain CA_FIXLEN: the same "Ns" String the producer (ca_mv_get)
       hands out via view->format. */
    return rb_obj_freeze(rb_str_new_cstr(ca_mv_fixlen_format(ca->bytes)));
  }
  const char *fmt = ca_mv_format_for(ca->data_type);
  return fmt ? rb_str_new_cstr(fmt) : Qnil;
}

/* CARecord#memory_view_field_names: the names of the record's members,
   one per specifier of the record's MemoryView format, in that order.
   Ruby's format has no place for them, so a bridge that writes a format
   which does (PEP 3118 "T{...}") asks the exporting object for them under
   this name.  nil when the record has no MemoryView format. */
static VALUE
rb_ca_record_memory_view_field_names (VALUE self)
{
  VALUE data_class = rb_ca_data_class(self);
  if ( NIL_P(data_class)
       || NIL_P(ca_mv_struct_format_for_data_class(data_class)) ) {
    return Qnil;
  }
  return rb_ary_dup(rb_const_get(data_class, rb_intern("MEMBERS")));
}

/* ---------------- Init ---------------- */

static const rb_memory_view_entry_t ca_memory_view_entry = {
  .get_func         = ca_mv_get,
  .release_func     = ca_mv_release,
  .available_p_func = ca_mv_available_p,
};

void
Init_carray_memory_view (void)
{
  ca_mv_fixlen_formats = st_init_numtable();
  rb_nativethread_lock_initialize(&ca_mv_fixlen_formats_lock);
  /* Statically known classes. */
  rb_memory_view_register(rb_cCArray,   &ca_memory_view_entry);
  rb_memory_view_register(rb_cCAWrap,   &ca_memory_view_entry);
  rb_memory_view_register(rb_cCScalar,  &ca_memory_view_entry);
  rb_memory_view_register(rb_cCARefer,  &ca_memory_view_entry);
  rb_memory_view_register(rb_cCABlock,  &ca_memory_view_entry);
  rb_memory_view_register(rb_cCASelect, &ca_memory_view_entry);
  rb_memory_view_register(rb_cCARepeat, &ca_memory_view_entry);

  /* Runtime-assigned classes: resolve via Ruby constants. */
  for (int i = 0; i < CA_MV_NUM_RUNTIME_OBJ_TYPES; i++) {
    ca_mv_runtime_type_t *rt = &ca_mv_runtime_types[i];
    ID class_id = rb_intern(rt->class_name);
    ID const_id = rb_intern(rt->const_name);
    if (rb_const_defined(rb_cObject, class_id)) {
      rt->klass = rb_const_get(rb_cObject, class_id);
      if (rt->strategy != CA_MV_REJECT) {
        rb_memory_view_register(rt->klass, &ca_memory_view_entry);
      }
    }
    if (rb_const_defined(rb_cObject, const_id)) {
      rt->id = NUM2INT(rb_const_get(rb_cObject, const_id));
    }
  }

  rb_define_singleton_method(rb_cCArray, "memory_view_available?",
                             rb_ca_s_memory_view_available_p, 1);
  rb_define_singleton_method(rb_cCArray, "memory_view_reject_reason",
                             rb_ca_s_memory_view_reject_reason, 1);
  rb_define_singleton_method(rb_cCArray, "from_memory_view",
                             rb_ca_s_from_memory_view, -1);
  rb_define_singleton_method(rb_cCArray, "wrap_memory_view",
                             rb_ca_s_wrap_memory_view, -1);
  /* The format parser and the format an array exports, for the specs
     (test_format_parser.rb, test_mv_struct_format.rb).  Private. */
  rb_define_private_method(rb_singleton_class(rb_cCArray),
                           "parse_memory_view_format",
                           rb_ca_s_parse_memory_view_format, 2);
  rb_define_private_method(rb_singleton_class(rb_cCArray),
                           "memory_view_format_of",
                           rb_ca_s_memory_view_format, 1);
  rb_define_method(rb_const_get(rb_cObject, rb_intern("CARecord")),
                   "memory_view_field_names",
                   rb_ca_record_memory_view_field_names, 0);
}
