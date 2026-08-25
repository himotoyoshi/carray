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
  - Producer emits PEP 3118 strict; consumer is Postel-permissive
    (accepts synonyms other producers emit).
  - See docs/interop/MemoryViewFormat.md for the format-string contract.
  - See devel/DESIGN_MemoryView.md for the design rationale.
  - See docs/interop/MemoryView.md for the user-facing MV API.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"   /* ca_strip_face for Face producers */
#include "ruby/memory_view.h"
#include <string.h>

/* private_data is not used: ca_mv_get is alias-only and ca_mv_release
   needs no per-view state.  Kept as a NULL field for API compatibility. */

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

/* Strategy = label only; ca_mv_get is alias-only and all CAStride-family
   strategies share the same code path (compose-to-root + entity->ptr +
   composed_strides).  The labels are kept for ca_mv_runtime_types[]
   readability and reject diagnostics.  CA_MV_ATTACH stays defined but is
   structurally unreachable -- ca_mv_check_alias_chain rejects every
   obj_type that maps to it. */
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

/* Resolved at Init_carray_memory_view.  The order is the same as
   ca_mv_runtime_types[] below.  Runtime obj_type ids are stored here so
   ca_mv_strategy_for can match them with a simple linear scan. */
static ca_mv_runtime_type_t ca_mv_runtime_types[CA_MV_NUM_RUNTIME_OBJ_TYPES] = {
  { "CAFarray",    "CA_OBJ_FARRAY",    -1, Qnil, /* CA_MV_FARRAY  */ 4 },
  { "CATranspose", "CA_OBJ_TRANSPOSE", -1, Qnil, /* CA_MV_TRANS   */ 5 },
  /* CAMapping is retired; a[mapper] now builds a CAGrid/CAStride chain
     whose layers are covered above. */
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
   canonical PEP 3118 specifier for each CArray data_type.  Inbound
   table (ca_mv_data_type_from_format) is Postel: it accepts a wider
   set of synonyms that other producers emit (they describe int32
   differently). */

static const char *
ca_mv_format_for (int8_t data_type)
{
  switch (data_type) {
  case CA_BOOLEAN: return "?";
  case CA_INT8:    return "b";
  case CA_UINT8:   return "B";
  case CA_INT16:   return "h";
  case CA_UINT16:  return "H";
  case CA_INT32:   return "i";
  case CA_UINT32:  return "I";
  case CA_INT64:   return "q";
  case CA_UINT64:  return "Q";
  case CA_FLOAT32: return "f";
  case CA_FLOAT64: return "d";
  case CA_CMPLX64:  return "Zf";
  case CA_CMPLX128: return "Zd";
  default:
    return NULL;
  }
}

/* PEP 3118 single-character specifier for a primitive data_type, for
   use inside a `T{...}` struct format body.  Identical to the top-level
   producer specifier: since the 2026-06-29 PEP 3118 strict flip both the
   top-level and struct-body contexts emit the same chars, so this
   delegates to ca_mv_format_for.  Kept as a distinct entry point so the
   struct-body context can diverge again without touching call sites.

   Returns NULL for non-primitive (CA_FIXLEN / CA_OBJECT) or for the
   retired float128 / cmplx256 enum slots. */
static const char *
ca_mv_pep3118_char (int8_t data_type)
{
  return ca_mv_format_for(data_type);
}

/* Build (or fetch from cache) the PEP 3118 struct format string for
   a data_class.  Walks MEMBER_TABLE in MEMBERS order and emits
   "T{<fmt>:<name>:<fmt>:<name>:}".  Returns Qnil if the class
   contains a member type the producer cannot express (nested
   sub-struct class, CArray template, :fixlen, :object).

   The result is frozen and cached on the data_class via
   @__mv_struct_format__ so successive calls are O(1) and the
   underlying RSTRING_PTR is stable (the cached String is rooted by
   the class, which outlives any MV produced from it). */
/* Helper: resolve a MEMBER_TABLE member-type slot to (fmt, bytes).
   Returns 1 on success, 0 if the type is not expressible in PEP 3118
   struct format (nested class, CArray template, :fixlen, :object,
   :bitfield).  Does NOT raise — :bitfield in particular is checked
   before rb_ca_guess_type so the struct-format walk can give up
   gracefully on bit-bearing structs. */
static int
ca_mv_struct_member_resolve (VALUE info, const char **fmt_out, ca_size_t *bytes_out)
{
  VALUE type = rb_ary_entry(info, 1);
  if (!SYMBOL_P(type)) return 0;
  ID type_id = SYM2ID(type);
  /* Reject explicitly unsupported symbol types up front (so
     rb_ca_guess_type never sees them and never raises). */
  if (type_id == rb_intern("bitfield") ||
      type_id == rb_intern("fixlen")   ||
      type_id == rb_intern("object")) {
    return 0;
  }
  int8_t dt = rb_ca_guess_type(rb_sym2str(type));
  const char *fmt = ca_mv_pep3118_char(dt);
  if (!fmt) return 0;
  *fmt_out   = fmt;
  *bytes_out = (ca_size_t) ca_sizeof[dt];
  return 1;
}

static VALUE
ca_mv_struct_format_for_data_class (VALUE data_class)
{
  ID iv = rb_intern("@__mv_struct_format__");
  if (rb_ivar_defined(data_class, iv)) {
    VALUE cached = rb_ivar_get(data_class, iv);
    /* Qfalse is a sentinel meaning "tried, found unsupported". */
    return (cached == Qfalse) ? Qnil : cached;
  }

  VALUE members = rb_const_get(data_class, rb_intern("MEMBERS"));
  VALUE table   = rb_const_get(data_class, rb_intern("MEMBER_TABLE"));
  long  n       = RARRAY_LEN(members);
  long  i;
  VALUE buf     = rb_str_buf_new(2 + 6 * n);
  ca_size_t cursor = 0;
  ca_size_t data_size = NUM2SIZE(rb_const_get(data_class, rb_intern("DATA_SIZE")));

  rb_str_buf_cat_ascii(buf, "T{");

  for (i = 0; i < n; i++) {
    VALUE name   = rb_ary_entry(members, i);
    VALUE info   = rb_hash_aref(table, name);
    if (NIL_P(info)) goto unsupported;
    ca_size_t offset = NUM2SIZE(rb_ary_entry(info, 0));

    const char *fmt;
    ca_size_t   mb;
    if (!ca_mv_struct_member_resolve(info, &fmt, &mb)) goto unsupported;

    /* If alignment or explicit padding has left a gap before this
       member, emit "<N>x:" to account for it.  PEP 3118 uses 'x'
       as the pad-byte specifier.  The canonical form elides the name
       slot after the pad spec (padding is anonymous by definition);
       consumers MUST accept both elided and named (legacy "<N>x:_:")
       forms. */
    if (offset > cursor) {
      char pad_decl[32];
      snprintf(pad_decl, sizeof(pad_decl), "%lldx:",
               (long long) (offset - cursor));
      rb_str_buf_cat_ascii(buf, pad_decl);
      cursor = offset;
    }

    rb_str_buf_cat_ascii(buf, fmt);
    rb_str_buf_cat_ascii(buf, ":");
    /* MEMBERS entries are strings; emit verbatim. */
    rb_str_buf_append(buf, rb_String(name));
    rb_str_buf_cat_ascii(buf, ":");
    cursor += mb;
  }

  /* Trailing padding (DATA_SIZE > last member's end).  Elided form
     (see the alignment-gap branch above for rationale). */
  if (cursor < data_size) {
    char pad_decl[32];
    snprintf(pad_decl, sizeof(pad_decl), "%lldx:",
             (long long) (data_size - cursor));
    rb_str_buf_cat_ascii(buf, pad_decl);
  }

  rb_str_buf_cat_ascii(buf, "}");
  rb_obj_freeze(buf);
  rb_ivar_set(data_class, iv, buf);
  return buf;

unsupported:
  /* Cache Qfalse to remember "we tried and gave up" — avoids
     re-walking MEMBER_TABLE on every wrap call. */
  rb_ivar_set(data_class, iv, Qfalse);
  return Qnil;
}

static int
ca_mv_data_type_exportable (int8_t data_type)
{
  return ca_mv_format_for(data_type) != NULL;
}

/* Same as ca_mv_data_type_exportable, but also accepts CA_FIXLEN:
   - with a data_class -> emit PEP 3118 "T{...}" struct format
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
   docs/interop/MemoryViewFormat.md for the contract):
   - Strip a leading byte-order prefix ('<', '>', '=') if it matches host
     endian; reject if it disagrees.
   - Strip the alignment modifier '|'.
   - Reject endian-bearing primary specifiers ('e','g','E','G','n','v',
     'N','V'); cross-endian sources are not accepted.
   - Dispatch on the (stripped_format, item_size) tuple.
   - Canonical: '?' for bool, 'Zf' / 'Zd' for complex64/128 (PEP 3118).
   - Synonyms accepted but not emitted: 'C'/1 maps to UINT8 (so other
     producers' bool buffers are received as UINT8); 'ff' / 'dd' map to
     complex64/128 (producers that split complex into two floats). */
static int8_t
ca_mv_data_type_from_format (const char *format, ssize_t item_size)
{
  const char *fmt = format ? format : "";
  /* Strip alignment and host-matching byte-order prefix. */
  if (*fmt == '|') fmt++;
  if (*fmt == '<' || *fmt == '>' || *fmt == '=') {
    /* The carray runtime stores data in host-endian; cross-endian
       sources are rejected. */
    int host_is_le = (ca_endian == CA_LITTLE_ENDIAN);
    int wants_le   = (*fmt == '<') || (*fmt == '=' && host_is_le);
    int wants_be   = (*fmt == '>') || (*fmt == '=' && !host_is_le);
    if ((wants_le && !host_is_le) || (wants_be && host_is_le)) return -1;
    fmt++;
  }
  if (*fmt == '\0') return -1;

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
       strcmp(fmt, "H")  == 0) && item_size == 2) return CA_UINT16;

  /* 32-bit */
  if ((strcmp(fmt, "l")  == 0 || strcmp(fmt, "i")  == 0 ||
       strcmp(fmt, "i!") == 0 || strcmp(fmt, "l!") == 0) && item_size == 4) return CA_INT32;
  if ((strcmp(fmt, "L")  == 0 || strcmp(fmt, "I")  == 0 ||
       strcmp(fmt, "I!") == 0 || strcmp(fmt, "L!") == 0) && item_size == 4) return CA_UINT32;

  /* 64-bit.  `l`/`L` at item_size 8 accepted as LP64 native long
     (numpy default for `np.array([1,2,3]).dtype == int64`). */
  if ((strcmp(fmt, "q")  == 0 || strcmp(fmt, "q!") == 0 ||
       strcmp(fmt, "l!") == 0 || strcmp(fmt, "l")  == 0) && item_size == 8) return CA_INT64;
  if ((strcmp(fmt, "Q")  == 0 || strcmp(fmt, "Q!") == 0 ||
       strcmp(fmt, "L!") == 0 || strcmp(fmt, "L")  == 0) && item_size == 8) return CA_UINT64;

  /* floats: no endian-bearing variants accepted */
  if (strcmp(fmt, "f")  == 0 && item_size == 4) return CA_FLOAT32;
  if (strcmp(fmt, "d")  == 0 && item_size == 8) return CA_FLOAT64;

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
   format — without importing the data.  This is the canonical "what dtype is
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

/* ---------------- strategy lookup ---------------- */

static ca_mv_strategy_t
ca_mv_strategy_for (int16_t obj_type)
{
  /* compile-time enum members */
  if (obj_type == CA_OBJ_ARRAY ||
      obj_type == CA_OBJ_ARRAY_WRAP ||
      obj_type == CA_OBJ_SCALAR) return CA_MV_DIRECT;
  if (obj_type == CA_OBJ_REFER)  return CA_MV_REFER;
  if (obj_type == CA_OBJ_BLOCK)  return CA_MV_BLOCK;
  if (obj_type == CA_OBJ_SELECT) return CA_MV_ATTACH;
  if (obj_type == CA_OBJ_REPEAT) return CA_MV_REPEAT;
  if (obj_type == CA_OBJ_OBJECT) return CA_MV_REJECT;
  if (obj_type == CA_OBJ_UNBOUND_REPEAT) return CA_MV_REJECT;
  /* Plain CAStride (created via #as_strided, or wrap_memory_view from
     a strided producer).  Reuse the CA_MV_TRANS handler since it
     already reads strides[] / base_offset directly from the CAStride
     layout -- no CATranspose-specific code in that path anymore. */
  if (obj_type == CA_OBJ_STRIDE) return CA_MV_TRANS;

  /* runtime-assigned obj_types */
  for (int i = 0; i < CA_MV_NUM_RUNTIME_OBJ_TYPES; i++) {
    if (ca_mv_runtime_types[i].id == obj_type) {
      return (ca_mv_strategy_t) ca_mv_runtime_types[i].strategy;
    }
  }
  return CA_MV_REJECT;
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
  if (ca->obj_type == CA_OBJ_UNBOUND_REPEAT)  return "shape is not bound";
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
  /* Face (= CARecord etc.) is a 1:1 alias of parent->ptr, so
     storage-layer-wise it is identical to the parent's entity / castride
     layer.  Strip Face, descend to parent, and feed the subsequent
     compose.  data_class / format come separately from the Face tail via
     rb_ca_data_class universal dispatch. */
  if (ca_is_face(ca)) {
    ca = ca_strip_face(ca);
  }
  if (ca_is_entity(ca)) {
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
  /* An entity whose obj_type has no strategy of its own is one installed
     from outside the core (ca_install_obj_type).  It reaches this callback
     only because it inherits CArray's MemoryView registration, and
     ca_mv_get would then reject it — say so here rather than advertising
     an export that cannot be produced.  Built-in entities (CArray /
     CAWrap / CScalar) map to DIRECT and are unaffected. */
  if (ca_is_entity(ca) && ca_mv_strategy_for(ca->obj_type) == CA_MV_REJECT) {
    return false;
  }
  /* Wrap-via-MV exports are zero-copy: require an alias chain to
     entity.  Non-alias views (CASelect, CAFake, etc.) and CAStride
     chains broken by a non-contig link cannot be wrapped without a
     snapshot, which has wrong semantics for MV consumers. */
  return ca_mv_check_alias_chain(ca, &rej);
}

static bool
ca_mv_get (VALUE obj, rb_memory_view_t *view, int flags)
{
  CArray *ca;
  ca_mv_strategy_t strategy;
  ssize_t *shape = NULL;
  ssize_t *strides = NULL;
  void *data_ptr = NULL;
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

  /* Resolve the chain to (entity, composed_strides, composed_base).
     If ca isn't a CAStride family member, only entity-class is
     accepted here.  The CAStride-family case below uses composed_strides
     / composed_base directly; the DIRECT case ignores them (entity owns
     ca->ptr already, no compose needed). */
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

  /* SIMPLE consumer on non-contig view would need a snapshot -- not
     offered (consumers wanting a snapshot use from_memory_view). */
  {
    int wants_strides_early = (flags & RUBY_MEMORY_VIEW_STRIDES) ? 1 : 0;
    if (!wants_strides_early &&
        ca_mv_is_castride_family(ca) &&
        !ca_mv_stride_is_contig((CAStride *) ca)) {
      return false;
    }
  }

  strategy = ca_mv_strategy_for(ca->obj_type);

  switch (strategy) {
  case CA_MV_DIRECT:
    /* Entity / wrap / scalar: ca->ptr is the entity's own buffer, always
       valid.  No attach needed. */
    data_ptr = ca->ptr;
    if (ca->ndim >= 1) {
      shape = ca_mv_alloc_shape(ca);
      strides = ca_mv_alloc_strides_contiguous(ca, shape, true);
    }
    break;

  /* All CAStride-family views (CARefer / CABlock / CAFarray / CATranspose
     / CARepeat / plain CAStride) reach this point only after
     ca_mv_compose_to_entity succeeded -- the producer is alias-only by
     ca_mv_available_p contract.  Expose `entity->ptr + composed_base` as
     data_ptr and composed_strides as strides, both in entity byte space.
     The entity owns its bytes (always valid via view->obj's parent chain
     while the consumer holds the view).

     CAREFUL: do not ca_attach the view here (nor ca_sync / ca_detach at
     release).  Exposure is alias-only: the consumer writes directly into
     root bytes, so a sync would scatter bytes back to root as a no-op
     chain -- and that chain triggers ca_update_mask / ca_sync(mask)
     recursion that can raise on an invariant violation.  Raising from a
     release callback is fatal during GC sweep (newobj_of during sweep ->
     BUG). */
  case CA_MV_REFER:
  case CA_MV_BLOCK:
  case CA_MV_FARRAY:
  case CA_MV_TRANS:
  case CA_MV_REPEAT: {
    int8_t k;
    shape = ca_mv_alloc_shape(ca);
    strides = (ssize_t *) xmalloc(sizeof(ssize_t) * ca->ndim);
    for (k = 0; k < ca->ndim; k++) strides[k] = (ssize_t) composed_strides[k];
    data_ptr = resolved_entity->ptr + composed_base;
    break;
  }

  case CA_MV_ATTACH:
    /* Should be unreachable: ca_mv_check_alias_chain rejects every
       obj_type that maps to ATTACH (CASelect / CAMapping / CAGrid /
       CAShift / CAWindow / CAFake / CAReduce).  Materialise is no
       longer offered via wrap_memory_view; from_memory_view gives a
       snapshot copy instead. */
    rb_raise(rb_eRuntimeError,
             "[BUG] ATTACH strategy reached in ca_mv_get for %s; "
             "alias-chain check should have rejected it",
             ca_mv_class_name_of(ca));

  case CA_MV_REJECT:
  default:
    return false;
  }

  view->obj = obj;
  view->data = data_ptr;
  /* PEP 3118 convention: byte_size is product(shape) * item_size for
     every layout (contiguous or strided).  NumPy, Numo, and Arrow all
     follow this; consumers that need the addressable span for strided
     views compute Σ (shape[k]-1)*|strides[k]| + item_size themselves. */
  view->byte_size = (ssize_t) ca_length(ca);
  view->readonly = ca_is_readonly(ca) ? true : false;
  /* Format string: primitive types use the top-level PEP 3118 table;
     CA_FIXLEN + data_class emits a PEP 3118 "T{...}" struct format
     whose lifetime is bound to the class via @__mv_struct_format__,
     so the view->format pointer is stable until the class is GC'd. */
  if (ca->data_type == CA_FIXLEN && RTEST(rb_ca_has_data_class(obj))) {
    VALUE klass = rb_ca_data_class(obj);
    VALUE fmt   = ca_mv_struct_format_for_data_class(klass);
    view->format = RSTRING_PTR(fmt);
  }
  else if (ca->data_type == CA_FIXLEN) {
    /* Plain CA_FIXLEN (no data_class): emit PEP 3118 "Ns" fixed-bytes.
       Cache the format String on the source object so RSTRING_PTR stays
       stable for the view's lifetime; the source object is anchored as
       view->obj. */
    VALUE fmt_str = rb_attr_get(obj, rb_intern("__mv_fixlen_format__"));
    if (NIL_P(fmt_str)) {
      char fmt_buf[32];
      snprintf(fmt_buf, sizeof(fmt_buf), "%lds", (long) ca->bytes);
      fmt_str = rb_str_new_cstr(fmt_buf);
      rb_obj_freeze(fmt_str);
      rb_ivar_set(obj, rb_intern("__mv_fixlen_format__"), fmt_str);
    }
    view->format = RSTRING_PTR(fmt_str);
  }
  else {
    view->format = ca_mv_format_for(ca->data_type);
  }
  view->item_size = (ssize_t) ca->bytes;
  view->item_desc.components = NULL;
  view->item_desc.length = 0;
  view->ndim = (ca->obj_type == CA_OBJ_SCALAR) ? 0 : (ssize_t) ca->ndim;
  view->shape = (view->ndim == 0) ? NULL : shape;
  view->strides = (view->ndim == 0) ? NULL : strides;
  view->sub_offsets = NULL;
  view->private_data = NULL;

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
  view->private_data = NULL;
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

typedef struct {
  rb_memory_view_t view;
  bool valid;
} ca_mv_imported_holder_t;

static void
ca_mv_imported_holder_free (void *p)
{
  ca_mv_imported_holder_t *h = (ca_mv_imported_holder_t *) p;
  if (h->valid) {
    rb_memory_view_release(&h->view);
    h->valid = false;
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

/* Acquire a MemoryView from src and validate/derive data_type, ndim
   and shape.  Tries STRIDES first; falls back to SIMPLE so that
   producers that advertise only contiguous still work.  On any
   failure, releases the view (if acquired) and raises ArgumentError;
   on success, the view is left active and the caller owns the
   responsibility to release it.

   `explicit_data_type` is the caller-supplied target data_type (>= 0) or -1
   if the caller has no preference.  Behaviour:
     - explicit_data_type < 0, format != NULL: derive data_type from format.
     - explicit_data_type < 0, format == NULL: reject (typeless source
       without consumer-supplied type cannot be interpreted).
     - explicit_data_type >= 0, format != NULL: must match the format's
       data_type; mismatch -> reject.
     - explicit_data_type >= 0, format == NULL: use explicit_data_type; the
       byte buffer is reinterpreted as that data_type.  ndim is forced
       to 1 (multi-dim from a typeless source is ambiguous; user
       chains .reshape).
*/
/* Row-major contiguity test that tolerates a NULL shape array.  ndim-0
   scalars and SIMPLE-form producers (which omit the shape array for a
   contiguous 1-D buffer, e.g. red-arrow's primitive arrays) are
   contiguous by construction; rb_memory_view_is_row_major_contiguous
   dereferences view->shape, so it must not be reached with shape NULL. */
static bool
ca_mv_view_is_contiguous (const rb_memory_view_t *view)
{
  if (view->ndim == 0 || view->shape == NULL) {
    return true;
  }
  return rb_memory_view_is_row_major_contiguous(view);
}

static void
ca_mv_acquire_and_validate (VALUE src, rb_memory_view_t *view,
                            int8_t explicit_data_type,
                            int8_t *out_data_type, int8_t *out_ndim,
                            ca_size_t *out_dim)
{
  int8_t data_type;
  int i;

  /* Defensive zero-init: rb_memory_view_release() unconditionally
     xfree()s view->item_desc.components, but not every producer writes
     that field.  red-arrow 24.0.0 leaves it uninitialized, so a view
     acquired from it frees stack garbage on release (abort).  Zeroing
     here makes the field NULL.  Consumer side of apache/arrow#45187
     (fixed in Arrow 25.0.0); harmless once producers initialize it. */
  memset(view, 0, sizeof(*view));

  if (! rb_memory_view_get(src, view, RUBY_MEMORY_VIEW_STRIDES)) {
    if (! rb_memory_view_get(src, view, RUBY_MEMORY_VIEW_SIMPLE)) {
      rb_raise(rb_eArgError,
               "object does not support MemoryView");
    }
  }

  if (view->format == NULL) {
    /* Typeless producer (e.g. mmap-view, IO#read-style byte blob).
       Consumer must supply the target data_type. */
    if (explicit_data_type < 0) {
      ssize_t got = view->byte_size;
      rb_memory_view_release(view);
      rb_raise(rb_eArgError,
               "typeless MemoryView (format=NULL, %ld bytes); "
               "specify the target data_type via data_type: kwarg or use a "
               "concrete CArray::<Dtype> factory class",
               (long) got);
    }
    if (ca_mv_format_for(explicit_data_type) == NULL) {
      rb_memory_view_release(view);
      rb_raise(rb_eArgError,
               "target data_type is not representable via MemoryView");
    }
    ssize_t target_item_size = (ssize_t) ca_sizeof[explicit_data_type];
    if (view->byte_size % target_item_size != 0) {
      ssize_t bs = view->byte_size;
      rb_memory_view_release(view);
      rb_raise(rb_eArgError,
               "byte_size %ld is not a multiple of target item_size %ld",
               (long) bs, (long) target_item_size);
    }
    data_type = explicit_data_type;
    *out_ndim = 1;
    out_dim[0] = (ca_size_t) (view->byte_size / target_item_size);
    *out_data_type = data_type;
    return;
  }

  /* Typed producer: derive data_type from format. */
  data_type = ca_mv_data_type_from_format(view->format, view->item_size);
  if (data_type < 0) {
    char fmt_buf[64];
    snprintf(fmt_buf, sizeof(fmt_buf), "%s", view->format);
    rb_memory_view_release(view);
    rb_raise(rb_eArgError,
             "unsupported MemoryView format: %s (item_size=%ld)",
             fmt_buf, (long) view->item_size);
  }

  /* If the caller specified a data_type too, it must match. */
  if (explicit_data_type >= 0 && explicit_data_type != data_type) {
    rb_memory_view_release(view);
    rb_raise(rb_eArgError,
             "explicit data_type does not match producer format "
             "(producer: %s, requested data_type %d)",
             view->format, (int) explicit_data_type);
  }

  if (view->ndim == 0) {
    *out_ndim = 1;
    out_dim[0] = 1;
  }
  else if (view->ndim > CA_RANK_MAX) {
    long got = (long) view->ndim;
    rb_memory_view_release(view);
    rb_raise(rb_eArgError,
             "MemoryView ndim (%ld) exceeds CArray CA_RANK_MAX (%d)",
             got, CA_RANK_MAX);
  }
  else if (view->shape == NULL) {
    /* SIMPLE form: a typed producer may advertise a format but omit the
       shape array for a contiguous 1-D buffer (red-arrow's primitive
       arrays do this).  Only 1-D is interpretable without a shape --
       length = byte_size / item_size.  A missing shape at ndim > 1 is
       unrecoverable. */
    if (view->ndim > 1) {
      long got = (long) view->ndim;
      rb_memory_view_release(view);
      rb_raise(rb_eArgError,
               "MemoryView reports ndim %ld but provides no shape array",
               got);
    }
    *out_ndim = 1;
    out_dim[0] = (ca_size_t) (view->item_size ? view->byte_size / view->item_size : 0);
  }
  else {
    *out_ndim = (int8_t) view->ndim;
    for (i = 0; i < *out_ndim; i++) {
      out_dim[i] = (ca_size_t) view->shape[i];
    }
  }
  *out_data_type = data_type;
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

/* Acquire and validate a mask MemoryView against the data side's shape.
   Returns an allocated holder (caller owns; release via the imported
   holder TypedData dfree path) with view active on success.

   On validation failure: releases the mask view, frees the mask holder,
   AND ALSO releases the supplied `data_view_to_release_on_fail` + frees
   the supplied `data_holder_to_free_on_fail` before raising.  This
   avoids leaking the caller's already-acquired data side when mask
   validation aborts.  Pass NULL for the data cleanup args if not
   applicable (e.g. mask validated for a stack-allocated data view in
   the copy path). */
static ca_mv_imported_holder_t *
ca_mv_acquire_mask_view (VALUE mask_src, int8_t data_ndim,
                         const ca_size_t *data_dim,
                         ca_mv_imported_holder_t *data_holder_to_free_on_fail,
                         rb_memory_view_t *data_view_to_release_on_fail)
{
  ca_mv_imported_holder_t *holder;
  rb_memory_view_t *mv;
  int i;

# define MV_MASK_CLEANUP_AND_RAISE(msg, ...) do {                          \
    if (holder) {                                                          \
      if (holder->valid) { rb_memory_view_release(&holder->view); }        \
      xfree(holder);                                                       \
    }                                                                      \
    if (data_view_to_release_on_fail) {                                    \
      rb_memory_view_release(data_view_to_release_on_fail);                \
    }                                                                      \
    if (data_holder_to_free_on_fail) {                                     \
      data_holder_to_free_on_fail->valid = false;                          \
      xfree(data_holder_to_free_on_fail);                                  \
    }                                                                      \
    rb_raise(rb_eArgError, msg, ##__VA_ARGS__);                            \
  } while (0)

  holder = ALLOC(ca_mv_imported_holder_t);
  holder->valid = false;

  /* Zero-init before get: same apache/arrow#45187 defense as the data
     path (release frees view->item_desc.components unconditionally). */
  memset(&holder->view, 0, sizeof(holder->view));

  if (! rb_memory_view_get(mask_src, &holder->view, RUBY_MEMORY_VIEW_STRIDES)) {
    if (! rb_memory_view_get(mask_src, &holder->view, RUBY_MEMORY_VIEW_SIMPLE)) {
      MV_MASK_CLEANUP_AND_RAISE("mask: object does not support MemoryView");
    }
  }
  holder->valid = true;
  mv = &holder->view;

  if (mv->format != NULL) {
    char c = mv->format[0];
    /* skip a leading byte-order/native prefix '<>=!@' */
    if (c == '<' || c == '>' || c == '=' || c == '!' || c == '@') {
      c = mv->format[1];
    }
    if (c != '?' && c != 'B' && c != 'b') {
      char fmt_buf[64];
      snprintf(fmt_buf, sizeof(fmt_buf), "%s", mv->format);
      MV_MASK_CLEANUP_AND_RAISE("mask: format must be bool/uint8/int8 (got %s)",
                                fmt_buf);
    }
  }
  if (mv->item_size != 1) {
    ssize_t got = mv->item_size;
    MV_MASK_CLEANUP_AND_RAISE("mask: item_size must be 1 (got %ld)",
                              (long) got);
  }
  if (mv->ndim != data_ndim) {
    int got = (int) mv->ndim;
    MV_MASK_CLEANUP_AND_RAISE("mask: ndim (%d) does not match data ndim (%d)",
                              got, (int) data_ndim);
  }
  if (mv->shape == NULL) {
    /* SIMPLE-form mask (contiguous 1-D, shape omitted).  item_size is 1
       (checked above), so byte_size is the element count. */
    ca_size_t mlen = (ca_size_t) mv->byte_size;
    if (data_ndim != 1 || mlen != data_dim[0]) {
      long ms = (long) mlen, ds = (long) (data_ndim == 1 ? data_dim[0] : -1);
      MV_MASK_CLEANUP_AND_RAISE(
          "mask: length (%ld) does not match data shape (%ld)", ms, ds);
    }
  }
  else {
    for (i = 0; i < data_ndim; i++) {
      if ((ca_size_t) mv->shape[i] != data_dim[i]) {
        long ms = (long) mv->shape[i], ds = (long) data_dim[i];
        MV_MASK_CLEANUP_AND_RAISE(
            "mask: shape[%d] (%ld) does not match data shape (%ld)",
            i, ms, ds);
      }
    }
  }
  if (! ca_mv_view_is_contiguous(mv)) {
    MV_MASK_CLEANUP_AND_RAISE(
        "mask: strided masks are not supported in this release; "
        "pass a row-major contiguous mask buffer");
  }

# undef MV_MASK_CLEANUP_AND_RAISE
  return holder;
}

/* Copy a strided MemoryView into a contiguous row-major destination buffer.
   Walks indices in row-major order and reads from view->data using
   view->strides at each step.  Assumes view->ndim >= 1, view->strides
   non-NULL, dst sized to hold elements * item_size. */
static void
ca_mv_copy_strided_to_contiguous (char *dst, const rb_memory_view_t *view,
                                  ca_size_t elements)
{
  int8_t ndim = (int8_t) view->ndim;
  ssize_t item_size = view->item_size;
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t n;
  int8_t k;

  for (k = 0; k < ndim; k++) idx[k] = 0;

  for (n = 0; n < elements; n++) {
    ssize_t src_off = 0;
    for (k = 0; k < ndim; k++) {
      src_off += (ssize_t) idx[k] * view->strides[k];
    }
    memcpy(dst, (const char *) view->data + src_off, (size_t) item_size);
    dst += item_size;
    /* increment row-major: last dim varies fastest */
    for (k = ndim - 1; k >= 0; k--) {
      idx[k]++;
      if (idx[k] < (ca_size_t) view->shape[k]) break;
      idx[k] = 0;
    }
  }
}

/* CArray.wrap_memory_view(obj, data_type: nil) -- zero-copy CAWrap.
   Rejects non-row-major-contiguous sources with a helpful pointer to
   from_memory_view; the contiguous-only contract keeps the boundary
   between Numo/CArray internal invariants clean (see the design note
   on strided wrap rejection).

   When the producer is typeless (format=NULL), `data_type:` must be
   supplied; the byte buffer is reinterpreted as that data_type, ndim=1.

   The receiver picks the class of the result.  Called on CArray itself
   it builds a CAWrap, as it always has; called on a subclass of CAWrap
   it builds that subclass, so a gem bridging a foreign buffer can name
   where the array came from without writing a C extension of its own.
   The class marks the provenance of this object only -- a view derived
   from it is a CABlock or a CAStride like any other. */
static VALUE
rb_ca_s_wrap_memory_view (int argc, VALUE *argv, VALUE klass)
{
  ca_mv_imported_holder_t *holder;
  ca_mv_imported_holder_t *mask_holder = NULL;
  rb_memory_view_t *v;
  int8_t data_type, ndim;
  ca_size_t dim[CA_RANK_MAX];
  VALUE wrap, holder_obj, obj, mask_obj, target_class;
  int8_t explicit_data_type =
    ca_mv_extract_type_and_mask_kwargs(argc, argv,
                                        (VALUE *) &obj, (VALUE *) &mask_obj);

  /* Resolve the class before anything is acquired, so this rejection
     needs no cleanup.  CArray means CAWrap; any other receiver has to
     be a CAWrap the caller can actually be handed. */
  target_class = ( klass == rb_cCArray ) ? rb_cCAWrap : klass;
  if ( ! RTEST(rb_class_inherited_p(target_class, rb_cCAWrap)) ) {
    rb_raise(rb_eTypeError,
             "wrap_memory_view builds a CAWrap; %s is not a subclass of it",
             rb_class2name(target_class));
  }

  holder = ALLOC(ca_mv_imported_holder_t);
  holder->valid = false;

  ca_mv_acquire_and_validate(obj, &holder->view, explicit_data_type,
                             &data_type, &ndim, dim);
  holder->valid = true;
  v = &holder->view;

  /* Whether the producer is strided is only knowable once the view is
     acquired, and a strided one is returned as a CAStride wrapping an
     inner CAWrap -- so a caller who asked for a class would get back
     something that is not it.  Refuse instead, and release first: this
     runs before the mask is acquired, so the holder is all there is to
     free. */
  if ( target_class != rb_cCAWrap &&
       v->ndim >= 1 && v->format != NULL && ! ca_mv_view_is_contiguous(v) ) {
    rb_memory_view_release(v);
    holder->valid = false;
    xfree(holder);
    rb_raise(rb_eArgError,
             "%s was requested, but this producer is strided, so the result "
             "would be a CAStride; pass a row-major contiguous producer, or "
             "use CArray.from_memory_view for a copy",
             rb_class2name(target_class));
  }

  /* mask: paired buffer.  Acquire + validate now (before building the
     wrap).  On failure the helper releases both the mask view AND the
     already-acquired data view + holder, then raises. */
  if (! NIL_P(mask_obj)) {
    mask_holder = ca_mv_acquire_mask_view(mask_obj, ndim, dim,
                                           holder, &holder->view);
    /* Strided data side combined with mask: is not supported in this
       release.  Catch this AFTER mask acquisition so the cleanup path can release
       both views uniformly. */
    if (v->ndim >= 1 && v->format != NULL &&
        ! ca_mv_view_is_contiguous(v)) {
      rb_memory_view_release(&mask_holder->view);
      mask_holder->valid = false;
      xfree(mask_holder);
      rb_memory_view_release(v);
      holder->valid = false;
      xfree(holder);
      rb_raise(rb_eArgError,
               "mask: combining mask: with a strided data source is not "
               "supported in this release; pass a row-major contiguous "
               "data source");
    }
  }

  /* Strided producer: build a CAStride on top of an inner CAWrap that
     anchors the foreign memory.  The inner CAWrap holds the MemoryView
     lifecycle (memory_view_source + memory_view_holder ivars); the
     outer CAStride is what the user sees, with full strides
     (including negative) preserved. */
  if (v->ndim >= 1 && v->format != NULL &&
      ! ca_mv_view_is_contiguous(v)) {
    ca_size_t inner_dim[1] = { 1 };
    volatile VALUE inner_wrap;
    ca_size_t strides_arr[CA_RANK_MAX];
    int i;

    inner_wrap = rb_ca_wrap_new(data_type, 1, inner_dim,
                                ca_mv_carray_bytes_for(data_type, v->item_size),
                                NULL, (char *) v->data);
    rb_ivar_set(inner_wrap, rb_intern("memory_view_source"), obj);
    holder_obj = TypedData_Wrap_Struct(rb_cObject,
                                       &ca_mv_imported_holder_data_type,
                                       holder);
    rb_ivar_set(inner_wrap, rb_intern("memory_view_holder"), holder_obj);
    if (v->readonly) {
      CArray *iw;
      if (ca_mv_extract(inner_wrap, &iw)) {
        ca_set_flag(iw, CA_FLAG_READ_ONLY);
      }
    }
    for (i = 0; i < ndim; i++) {
      strides_arr[i] = (ca_size_t) v->strides[i];
    }
    {
      VALUE result =
        rb_ca_stride_new(inner_wrap, data_type,
                         ca_mv_carray_bytes_for(data_type, v->item_size),
                         ndim, dim, strides_arr, /* base_offset */ 0);
      if (v->readonly) {
        CArray *rs;
        if (ca_mv_extract(result, &rs)) {
          ca_set_flag(rs, CA_FLAG_READ_ONLY);
        }
      }
      return result;
    }
  }

  /* Same struct rb_ca_wrap_new would build, wrapped in the class the
     receiver asked for.  Everything downstream -- the holder and source
     ivars, the read-only flag, the borrowed mask -- is untouched, which
     is the point: those are what a gem building its own wrap by hand
     has to give up. */
  wrap = ca_wrap_struct_as(
           ca_wrap_new(data_type, ndim, dim,
                       ca_mv_carray_bytes_for(data_type, v->item_size),
                       NULL, (char *) v->data),
           target_class);

  rb_ivar_set(wrap, rb_intern("memory_view_source"), obj);
  holder_obj = TypedData_Wrap_Struct(rb_cObject,
                                     &ca_mv_imported_holder_data_type,
                                     holder);
  rb_ivar_set(wrap, rb_intern("memory_view_holder"), holder_obj);

  if (v->readonly) {
    CArray *ca;
    if (ca_mv_extract(wrap, &ca)) {
      ca_set_flag(ca, CA_FLAG_READ_ONLY);
    }
  }

  /* Attach borrowed mask: build a CAWrap over the mask buffer and assign
     it to wrap->mask.  Anchor the mask MV's source + holder on the same
     wrap object so the lifecycle is co-terminal with the data side.
     When `wrap` is collected: free_ca_wrap recurses into ca->mask (frees
     the mask wrap struct, leaves its borrowed ptr alone); the holder
     ivars become unreachable and are GC'd separately, each holder.dfree
     calling rb_memory_view_release. */
  if (mask_holder != NULL) {
    CArray *data_ca, *mask_ca;
    rb_memory_view_t *mv = &mask_holder->view;
    VALUE mask_holder_obj;
    if (! ca_mv_extract(wrap, &data_ca)) {
      rb_memory_view_release(mv);
      mask_holder->valid = false;
      xfree(mask_holder);
      rb_raise(rb_eRuntimeError,
               "internal: rb_ca_wrap_new did not return a CArray");
    }
    mask_ca = (CArray *) ca_wrap_new(CA_BOOLEAN, ndim, dim, 1, NULL,
                                      (char *) mv->data);
    ca_set_flag(mask_ca, CA_FLAG_MASK_ARRAY);
    if (mv->readonly) {
      ca_set_flag(mask_ca, CA_FLAG_READ_ONLY);
    }
    data_ca->mask = mask_ca;

    rb_ivar_set(wrap, rb_intern("mask_memory_view_source"), mask_obj);
    mask_holder_obj = TypedData_Wrap_Struct(rb_cObject,
                                             &ca_mv_imported_holder_data_type,
                                             mask_holder);
    rb_ivar_set(wrap, rb_intern("mask_memory_view_holder"), mask_holder_obj);
  }

  return wrap;
}

/* CArray.from_memory_view(obj, data_type: nil) -- copy into an independent CArray.
   Accepts strided typed sources (gather copy) and typeless sources
   (must be 1D contiguous; bytes reinterpreted as `data_type:`). */
static VALUE
rb_ca_s_from_memory_view (int argc, VALUE *argv, VALUE klass)
{
  rb_memory_view_t view;
  ca_mv_imported_holder_t *mask_holder = NULL;
  int8_t data_type, ndim;
  ca_size_t dim[CA_RANK_MAX];
  VALUE result, obj, mask_obj;
  CArray *ca;
  bool contig;
  int8_t explicit_data_type =
    ca_mv_extract_type_and_mask_kwargs(argc, argv,
                                        (VALUE *) &obj, (VALUE *) &mask_obj);

  ca_mv_acquire_and_validate(obj, &view, explicit_data_type,
                             &data_type, &ndim, dim);

  /* mask: acquire + validate now so failures clean up the data view too. */
  if (! NIL_P(mask_obj)) {
    mask_holder = ca_mv_acquire_mask_view(mask_obj, ndim, dim,
                                           NULL, &view);
  }

  result = rb_carray_new(data_type, ndim, dim,
                         ca_mv_carray_bytes_for(data_type, view.item_size),
                         NULL);
  if (! ca_mv_extract(result, &ca)) {
    rb_memory_view_release(&view);
    rb_raise(rb_eRuntimeError, "internal: rb_carray_new did not return a CArray");
  }

  /* Typeless producers (format == NULL) and SIMPLE-form producers (shape
     omitted) are 1-D contiguous by construction; ca_mv_view_is_contiguous
     handles the NULL shape that would crash the raw contiguity helper. */
  contig = (view.format == NULL) || ca_mv_view_is_contiguous(&view);

  if (contig) {
    size_t total_bytes = (size_t) ca_length(ca);
    /* For typeless producers byte_size and total_bytes are equal by
       construction; for typed producers we already validated alignment. */
    if (view.byte_size < (ssize_t) total_bytes) {
      rb_memory_view_release(&view);
      if (mask_holder) {
        rb_memory_view_release(&mask_holder->view);
        mask_holder->valid = false;
        xfree(mask_holder);
      }
      rb_raise(rb_eRuntimeError,
               "internal: byte_size mismatch (carray=%lu, view=%ld)",
               (unsigned long) total_bytes, (long) view.byte_size);
    }
    memcpy(ca->ptr, view.data, total_bytes);
  }
  else {
    /* Strided typed source: walk indices in row-major order and gather. */
    ca_mv_copy_strided_to_contiguous(ca->ptr, &view, ca->elements);
  }

  rb_memory_view_release(&view);

  /* mask: materialise the canonical CA_BOOLEAN mask slot via ca_create_mask,
     then memcpy bytes from the (validated row-major contig 1-byte/elem) mask
     buffer.  Source format ? / B / b all use byte values where any non-zero
     means masked; that semantic matches CArray's mask convention directly
     when we coerce non-zero to 1.  */
  if (mask_holder) {
    rb_memory_view_t *mv = &mask_holder->view;
    size_t n = (size_t) ca->elements;
    size_t i;
    const uint8_t *src = (const uint8_t *) mv->data;
    boolean8_t *dst;
    ca_create_mask(ca);
    dst = (boolean8_t *) ca->mask->ptr;
    for (i = 0; i < n; i++) {
      dst[i] = (src[i] != 0) ? 1 : 0;
    }
    rb_memory_view_release(mv);
    mask_holder->valid = false;
    xfree(mask_holder);
  }

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
    return rb_str_new_cstr("not a CArray");
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
    if      (rej.depth == 0) where = "this view";
    else if (rej.depth == 1) where = "parent";
    else                     where = NULL;   /* ancestor[N] */
    if (where) {
      return rb_sprintf("%s is %s (%s); zero-copy wrap not possible. "
                        "Use CArray.from_memory_view(arr) or arr.to_ca for a snapshot.",
                        where, rej.class_name, rej.reason);
    } else {
      return rb_sprintf("ancestor[%d] is %s (%s); zero-copy wrap not possible. "
                        "Use CArray.from_memory_view(arr) or arr.to_ca for a snapshot.",
                        rej.depth - 1, rej.class_name, rej.reason);
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
   by spec_ai to verify PEP 3118 struct format emission for CAStruct
   arrays.  Returns nil if obj isn't exportable. */
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
    /* Plain CA_FIXLEN: emit "Ns" via the same caching scheme used by
       the real producer (ca_mv_get).  Reusing the cache keeps the
       returned String identity-equal to the one the producer hands out
       via view->format, which test code may rely on. */
    VALUE fmt_str = rb_attr_get(obj, rb_intern("__mv_fixlen_format__"));
    if (NIL_P(fmt_str)) {
      char fmt_buf[32];
      snprintf(fmt_buf, sizeof(fmt_buf), "%lds", (long) ca->bytes);
      fmt_str = rb_str_new_cstr(fmt_buf);
      rb_obj_freeze(fmt_str);
      rb_ivar_set(obj, rb_intern("__mv_fixlen_format__"), fmt_str);
    }
    return fmt_str;
  }
  const char *fmt = ca_mv_format_for(ca->data_type);
  return fmt ? rb_str_new_cstr(fmt) : Qnil;
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
  /* Test hooks (used by spec_ai/test_format_parser.rb and
     spec_ai/test_mv_struct_format.rb).  Private API; names start
     with __ to discourage external use. */
  rb_define_singleton_method(rb_cCArray, "__memory_view_parse_format__",
                             rb_ca_s_parse_memory_view_format, 2);
  rb_define_singleton_method(rb_cCArray, "__memory_view_format__",
                             rb_ca_s_memory_view_format, 1);
}
