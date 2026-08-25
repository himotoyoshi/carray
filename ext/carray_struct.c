/* ---------------------------------------------------------------------------

  C-native member access for CAStruct subclasses.  The hooked
  methods (`[]`, `[]=`, `initialize`) are installed on a subclass by
  `CArray.__install_castruct_methods__(klass)` — called from the
  bottom of lib/carray/struct.rb once CAStruct is defined, so this
  ext can load before that file.

  Sibling of lib/carray/struct.rb (Ruby-side CAStruct::Builder that
  populates the FAST_PRIMITIVES / DISPATCH_TABLE constants read
  from here).

  Dispatch order for both `[]` and `[]=`:

    FAST_PRIMITIVES hit  -> direct memcpy against @data.ptr + offset
                            (primitive / bitfield / endian-swap)
    DISPATCH_TABLE hit   -> Proc invoked via rb_funcall("call")
                            (nested struct / CArray template / fixlen)
    miss                 -> send(name) / send(name=)

---------------------------------------------------------------------------- */

#include "carray.h"
#include <string.h>

/* ---------------------------------------------------------------------
   FAST_PRIMITIVES entry kind tags.
 *
 * CAREFUL: these constants are kept in sync with the Ruby-side
 * CAStruct::Builder::FAST_KIND_* — an off-by-one drift silently
 * mis-dispatches every access.
   --------------------------------------------------------------------- */

#define FAST_KIND_PRIMITIVE  0
#define FAST_KIND_BITFIELD   1
#define FAST_KIND_ENDIAN     2

/* 16/32/64-bit byte swap via compiler builtins.  Clang and GCC both
   expose __builtin_bswap*, and the project's CFLAGS already require
   a recent toolchain. */
#define CA_BSWAP16(x) ((uint16_t) __builtin_bswap16((uint16_t)(x)))
#define CA_BSWAP32(x) ((uint32_t) __builtin_bswap32((uint32_t)(x)))
#define CA_BSWAP64(x) ((uint64_t) __builtin_bswap64((uint64_t)(x)))

/* ---------------------------------------------------------------------
   Type-coded primitive read / write.  Type codes are the same
   CA_INT8 / CA_UINT8 / ... constants used everywhere else in carray.
   --------------------------------------------------------------------- */

static VALUE
ca_struct_read_primitive_fast (const char *p, int type_code)
{
  switch (type_code) {
  case CA_BOOLEAN: {
    int8_t v;
    memcpy(&v, p, 1);
    return v ? INT2FIX(1) : INT2FIX(0);
  }
  case CA_INT8: {
    int8_t v;
    memcpy(&v, p, 1);
    return INT2FIX(v);
  }
  case CA_UINT8: {
    uint8_t v;
    memcpy(&v, p, 1);
    return INT2FIX(v);
  }
  case CA_INT16: {
    int16_t v;
    memcpy(&v, p, 2);
    return INT2FIX(v);
  }
  case CA_UINT16: {
    uint16_t v;
    memcpy(&v, p, 2);
    return INT2FIX(v);
  }
  case CA_INT32: {
    int32_t v;
    memcpy(&v, p, 4);
    return LONG2NUM(v);
  }
  case CA_UINT32: {
    uint32_t v;
    memcpy(&v, p, 4);
    return ULONG2NUM(v);
  }
  case CA_INT64: {
    int64_t v;
    memcpy(&v, p, 8);
    return LL2NUM(v);
  }
  case CA_UINT64: {
    uint64_t v;
    memcpy(&v, p, 8);
    return ULL2NUM(v);
  }
  case CA_FLOAT32: {
    float v;
    memcpy(&v, p, 4);
    return DBL2NUM((double) v);
  }
  case CA_FLOAT64: {
    double v;
    memcpy(&v, p, 8);
    return DBL2NUM(v);
  }
  default:
    return Qundef;  /* should not happen; FAST_PRIMITIVES filters */
  }
}

static void
ca_struct_write_primitive_fast (char *p, int type_code, VALUE val)
{
  switch (type_code) {
  case CA_BOOLEAN: {
    int8_t v = RTEST(val) && val != INT2FIX(0) ? 1 : 0;
    memcpy(p, &v, 1);
    return;
  }
  case CA_INT8: {
    int8_t v = (int8_t) NUM2INT(val);
    memcpy(p, &v, 1);
    return;
  }
  case CA_UINT8: {
    uint8_t v = (uint8_t) NUM2UINT(val);
    memcpy(p, &v, 1);
    return;
  }
  case CA_INT16: {
    int16_t v = (int16_t) NUM2INT(val);
    memcpy(p, &v, 2);
    return;
  }
  case CA_UINT16: {
    uint16_t v = (uint16_t) NUM2UINT(val);
    memcpy(p, &v, 2);
    return;
  }
  case CA_INT32: {
    int32_t v = (int32_t) NUM2LONG(val);
    memcpy(p, &v, 4);
    return;
  }
  case CA_UINT32: {
    uint32_t v = (uint32_t) NUM2ULONG(val);
    memcpy(p, &v, 4);
    return;
  }
  case CA_INT64: {
    int64_t v = (int64_t) NUM2LL(val);
    memcpy(p, &v, 8);
    return;
  }
  case CA_UINT64: {
    uint64_t v = (uint64_t) NUM2ULL(val);
    memcpy(p, &v, 8);
    return;
  }
  case CA_FLOAT32: {
    float v = (float) NUM2DBL(val);
    memcpy(p, &v, 4);
    return;
  }
  case CA_FLOAT64: {
    double v = NUM2DBL(val);
    memcpy(p, &v, 8);
    return;
  }
  default:
    rb_raise(rb_eRuntimeError,
             "[BUG] ca_struct_write_primitive_fast: unsupported type %d",
             type_code);
  }
}

/* ---------------------------------------------------------------------
   Bit-field read / write.  Mirrors CABitfield: load the spanning
   power-of-2 word (1/2/4/8 bytes) at start_byte, shift right by
   bit_in_word, mask off `bits` bits.  Writes use load-modify-store
   to keep neighbouring bits untouched.
   --------------------------------------------------------------------- */

static VALUE
ca_struct_read_bitfield_fast (const char *p, int view_bytes,
                              int bit_in_word, int bits)
{
  uint64_t word = 0;
  switch (view_bytes) {
  case 1: { uint8_t  v; memcpy(&v, p, 1); word = v; break; }
  case 2: { uint16_t v; memcpy(&v, p, 2); word = v; break; }
  case 4: { uint32_t v; memcpy(&v, p, 4); word = v; break; }
  case 8: { uint64_t v; memcpy(&v, p, 8); word = v; break; }
  default:
    rb_raise(rb_eRuntimeError,
             "[BUG] bitfield view_bytes %d not in {1,2,4,8}", view_bytes);
  }
  uint64_t mask = (bits >= 64) ? ~(uint64_t)0
                               : ((uint64_t)1 << bits) - 1;
  uint64_t val  = (word >> bit_in_word) & mask;
  /* Returned as an unsigned Integer; bit-fields don't carry a sign
     bit in carray's CABitfield convention either. */
  if (bits <= 31) return INT2FIX((long) val);
  if (bits <= 32) return ULONG2NUM((unsigned long) val);
  return ULL2NUM(val);
}

static void
ca_struct_write_bitfield_fast (char *p, int view_bytes,
                               int bit_in_word, int bits, VALUE val)
{
  uint64_t v    = NUM2ULL(val);
  uint64_t mask = (bits >= 64) ? ~(uint64_t)0
                               : ((uint64_t)1 << bits) - 1;
  v &= mask;
  uint64_t shifted_mask = mask << bit_in_word;
  uint64_t shifted_val  = v    << bit_in_word;
  switch (view_bytes) {
  case 1: {
    uint8_t word;
    memcpy(&word, p, 1);
    word = (uint8_t)((word & ~(uint8_t)shifted_mask) | (uint8_t)shifted_val);
    memcpy(p, &word, 1);
    return;
  }
  case 2: {
    uint16_t word;
    memcpy(&word, p, 2);
    word = (uint16_t)((word & ~(uint16_t)shifted_mask) | (uint16_t)shifted_val);
    memcpy(p, &word, 2);
    return;
  }
  case 4: {
    uint32_t word;
    memcpy(&word, p, 4);
    word = (uint32_t)((word & ~(uint32_t)shifted_mask) | (uint32_t)shifted_val);
    memcpy(p, &word, 4);
    return;
  }
  case 8: {
    uint64_t word;
    memcpy(&word, p, 8);
    word = (word & ~shifted_mask) | shifted_val;
    memcpy(p, &word, 8);
    return;
  }
  default:
    rb_raise(rb_eRuntimeError,
             "[BUG] bitfield view_bytes %d not in {1,2,4,8}", view_bytes);
  }
}

/* ---------------------------------------------------------------------
   Endian-swapped primitive read / write.  Only entries whose target
   endian differs from the host land here -- the Ruby Builder folds
   host-matching cases into the plain primitive fast path.  No view
   allocation; one __builtin_bswap per access.
   --------------------------------------------------------------------- */

static VALUE
ca_struct_read_endian_swapped_fast (const char *p, int type_code)
{
  switch (type_code) {
  case CA_INT16: {
    uint16_t v; memcpy(&v, p, 2); v = CA_BSWAP16(v);
    return INT2FIX((int16_t) v);
  }
  case CA_UINT16: {
    uint16_t v; memcpy(&v, p, 2); v = CA_BSWAP16(v);
    return INT2FIX(v);
  }
  case CA_INT32: {
    uint32_t v; memcpy(&v, p, 4); v = CA_BSWAP32(v);
    return LONG2NUM((int32_t) v);
  }
  case CA_UINT32: {
    uint32_t v; memcpy(&v, p, 4); v = CA_BSWAP32(v);
    return ULONG2NUM(v);
  }
  case CA_INT64: {
    uint64_t v; memcpy(&v, p, 8); v = CA_BSWAP64(v);
    return LL2NUM((int64_t) v);
  }
  case CA_UINT64: {
    uint64_t v; memcpy(&v, p, 8); v = CA_BSWAP64(v);
    return ULL2NUM(v);
  }
  case CA_FLOAT32: {
    uint32_t bits; memcpy(&bits, p, 4); bits = CA_BSWAP32(bits);
    float v; memcpy(&v, &bits, 4);
    return DBL2NUM((double) v);
  }
  case CA_FLOAT64: {
    uint64_t bits; memcpy(&bits, p, 8); bits = CA_BSWAP64(bits);
    double v; memcpy(&v, &bits, 8);
    return DBL2NUM(v);
  }
  default:
    rb_raise(rb_eRuntimeError,
             "[BUG] endian-swapped type %d unsupported in fast path",
             type_code);
  }
}

static void
ca_struct_write_endian_swapped_fast (char *p, int type_code, VALUE val)
{
  switch (type_code) {
  case CA_INT16: {
    uint16_t v = (uint16_t) NUM2INT(val);
    v = CA_BSWAP16(v); memcpy(p, &v, 2);
    return;
  }
  case CA_UINT16: {
    uint16_t v = (uint16_t) NUM2UINT(val);
    v = CA_BSWAP16(v); memcpy(p, &v, 2);
    return;
  }
  case CA_INT32: {
    uint32_t v = (uint32_t) NUM2LONG(val);
    v = CA_BSWAP32(v); memcpy(p, &v, 4);
    return;
  }
  case CA_UINT32: {
    uint32_t v = (uint32_t) NUM2ULONG(val);
    v = CA_BSWAP32(v); memcpy(p, &v, 4);
    return;
  }
  case CA_INT64: {
    uint64_t v = (uint64_t) NUM2LL(val);
    v = CA_BSWAP64(v); memcpy(p, &v, 8);
    return;
  }
  case CA_UINT64: {
    uint64_t v = NUM2ULL(val);
    v = CA_BSWAP64(v); memcpy(p, &v, 8);
    return;
  }
  case CA_FLOAT32: {
    float vf = (float) NUM2DBL(val);
    uint32_t bits; memcpy(&bits, &vf, 4);
    bits = CA_BSWAP32(bits); memcpy(p, &bits, 4);
    return;
  }
  case CA_FLOAT64: {
    double vd = NUM2DBL(val);
    uint64_t bits; memcpy(&bits, &vd, 8);
    bits = CA_BSWAP64(bits); memcpy(p, &bits, 8);
    return;
  }
  default:
    rb_raise(rb_eRuntimeError,
             "[BUG] endian-swapped type %d unsupported in fast path",
             type_code);
  }
}

/* ---------------------------------------------------------------------
   Resolve a member name to a Ruby String key matching MEMBER_TABLE /
   DISPATCH_TABLE / FAST_PRIMITIVES.  Integer indices route through
   MEMBERS, mirroring the Ruby implementation.  Returns Qnil if the
   integer is out of range (handled at the call site).
   --------------------------------------------------------------------- */

static VALUE
ca_struct_resolve_name (VALUE klass, VALUE name)
{
  if (RB_TYPE_P(name, T_FIXNUM)) {
    VALUE members = rb_const_get(klass, rb_intern("MEMBERS"));
    name = rb_ary_entry(members, FIX2LONG(name));
    if (NIL_P(name)) return Qnil;
  }
  if (RB_TYPE_P(name, T_STRING)) {
    return name;
  }
  if (RB_TYPE_P(name, T_SYMBOL)) {
    /* rb_sym2str returns the symbol's underlying (frozen, interned)
       String — no allocation, unlike `name.to_s` which copies. */
    return rb_sym2str(name);
  }
  return rb_funcall(name, rb_intern("to_s"), 0);
}

/* ---------------------------------------------------------------------
   Shared write-dispatch helper reused by `[]=` and `initialize`.
   Returns 1 if the member was written, 0 if neither table contained
   the name (caller decides whether to send / raise).
   --------------------------------------------------------------------- */

static int
ca_struct_dispatch_write (VALUE klass, VALUE name_s, VALUE val, VALUE data_val)
{
  if (rb_const_defined(klass, rb_intern("FAST_PRIMITIVES"))) {
    VALUE fast_table = rb_const_get(klass, rb_intern("FAST_PRIMITIVES"));
    VALUE entry = rb_hash_aref(fast_table, name_s);
    if (!NIL_P(entry)) {
      int kind = NUM2INT(rb_ary_entry(entry, 0));
      CArray *ca;
      TypedData_Get_Struct(data_val, CArray, &carray_data_type, ca);
      switch (kind) {
      case FAST_KIND_PRIMITIVE: {
        ca_size_t offset    = NUM2SIZE(rb_ary_entry(entry, 1));
        int  type_code = NUM2INT (rb_ary_entry(entry, 2));
        ca_struct_write_primitive_fast(ca->ptr + offset, type_code, val);
        return 1;
      }
      case FAST_KIND_BITFIELD: {
        ca_size_t start_byte  = NUM2SIZE(rb_ary_entry(entry, 1));
        int  view_bytes  = NUM2INT (rb_ary_entry(entry, 2));
        int  bit_in_word = NUM2INT (rb_ary_entry(entry, 3));
        int  bits        = NUM2INT (rb_ary_entry(entry, 4));
        ca_struct_write_bitfield_fast(ca->ptr + start_byte,
                                      view_bytes, bit_in_word, bits, val);
        return 1;
      }
      case FAST_KIND_ENDIAN: {
        ca_size_t offset    = NUM2SIZE(rb_ary_entry(entry, 1));
        int  type_code = NUM2INT (rb_ary_entry(entry, 2));
        ca_struct_write_endian_swapped_fast(ca->ptr + offset, type_code, val);
        return 1;
      }
      default:
        rb_raise(rb_eRuntimeError,
                 "[BUG] FAST_PRIMITIVES unknown kind %d", kind);
      }
    }
  }
  VALUE dispatch_table = rb_const_get(klass, rb_intern("DISPATCH_TABLE"));
  VALUE pair = rb_hash_aref(dispatch_table, name_s);
  if (!NIL_P(pair)) {
    VALUE writer = rb_ary_entry(pair, 1);
    rb_funcall(writer, rb_intern("call"), 2, data_val, val);
    return 1;
  }
  return 0;
}

/* ---------------------------------------------------------------------
   CAStruct#[] (C-native).
   --------------------------------------------------------------------- */

static VALUE
rb_ca_struct_aref (VALUE self, VALUE name)
{
  VALUE klass = rb_obj_class(self);
  VALUE name_s = ca_struct_resolve_name(klass, name);

  /* Fast path.  FAST_PRIMITIVES may be absent on subclasses built
     outside Builder — fall through to the dispatch table in that
     case.  Entry shape is `[kind, ...args]`; args depend on kind. */
  if (rb_const_defined(klass, rb_intern("FAST_PRIMITIVES"))) {
    VALUE fast_table = rb_const_get(klass, rb_intern("FAST_PRIMITIVES"));
    VALUE entry = rb_hash_aref(fast_table, name_s);
    if (!NIL_P(entry)) {
      int kind = NUM2INT(rb_ary_entry(entry, 0));
      VALUE data_val = rb_ivar_get(self, rb_intern("@data"));
      CArray *ca;
      TypedData_Get_Struct(data_val, CArray, &carray_data_type, ca);
      /* @data is a CScalar entity, so ca->ptr is always valid. */
      switch (kind) {
      case FAST_KIND_PRIMITIVE: {
        /* [kind, offset, type_code] */
        ca_size_t offset    = NUM2SIZE(rb_ary_entry(entry, 1));
        int  type_code = NUM2INT (rb_ary_entry(entry, 2));
        return ca_struct_read_primitive_fast(ca->ptr + offset, type_code);
      }
      case FAST_KIND_BITFIELD: {
        /* [kind, start_byte, view_bytes, bit_in_word, bits] */
        ca_size_t start_byte  = NUM2SIZE(rb_ary_entry(entry, 1));
        int  view_bytes  = NUM2INT (rb_ary_entry(entry, 2));
        int  bit_in_word = NUM2INT (rb_ary_entry(entry, 3));
        int  bits        = NUM2INT (rb_ary_entry(entry, 4));
        return ca_struct_read_bitfield_fast(ca->ptr + start_byte,
                                            view_bytes, bit_in_word, bits);
      }
      case FAST_KIND_ENDIAN: {
        /* [kind, offset, type_code] — only the swap-needed branch;
           same-endian members are folded into FAST_KIND_PRIMITIVE
           at build time. */
        ca_size_t offset    = NUM2SIZE(rb_ary_entry(entry, 1));
        int  type_code = NUM2INT (rb_ary_entry(entry, 2));
        return ca_struct_read_endian_swapped_fast(ca->ptr + offset,
                                                  type_code);
      }
      default:
        rb_raise(rb_eRuntimeError,
                 "[BUG] FAST_PRIMITIVES unknown kind %d", kind);
      }
    }
  }

  /* Dispatch-table path (nested struct / CArray template / fixlen /
     anything Builder didn't fold into FAST_PRIMITIVES) */
  VALUE dispatch_table = rb_const_get(klass, rb_intern("DISPATCH_TABLE"));
  VALUE pair = rb_hash_aref(dispatch_table, name_s);
  if (!NIL_P(pair)) {
    VALUE reader = rb_ary_entry(pair, 0);
    VALUE data_val = rb_ivar_get(self, rb_intern("@data"));
    return rb_funcall(reader, rb_intern("call"), 1, data_val);
  }

  /* Unknown name: fall back to send(name) for computed members. */
  return rb_funcall(self, rb_to_id(name), 0);
}

/* ---------------------------------------------------------------------
   CAStruct#[]= (C-native).
   --------------------------------------------------------------------- */

static VALUE
rb_ca_struct_aset (VALUE self, VALUE name, VALUE val)
{
  VALUE klass = rb_obj_class(self);
  VALUE name_s = ca_struct_resolve_name(klass, name);

  /* Fast path (see rb_ca_struct_aref for the absent-FAST_PRIMITIVES
     rationale and entry-shape contract). */
  if (rb_const_defined(klass, rb_intern("FAST_PRIMITIVES"))) {
    VALUE fast_table = rb_const_get(klass, rb_intern("FAST_PRIMITIVES"));
    VALUE entry = rb_hash_aref(fast_table, name_s);
    if (!NIL_P(entry)) {
      int kind = NUM2INT(rb_ary_entry(entry, 0));
      VALUE data_val = rb_ivar_get(self, rb_intern("@data"));
      CArray *ca;
      TypedData_Get_Struct(data_val, CArray, &carray_data_type, ca);
      switch (kind) {
      case FAST_KIND_PRIMITIVE: {
        ca_size_t offset    = NUM2SIZE(rb_ary_entry(entry, 1));
        int  type_code = NUM2INT (rb_ary_entry(entry, 2));
        ca_struct_write_primitive_fast(ca->ptr + offset, type_code, val);
        return val;
      }
      case FAST_KIND_BITFIELD: {
        ca_size_t start_byte  = NUM2SIZE(rb_ary_entry(entry, 1));
        int  view_bytes  = NUM2INT (rb_ary_entry(entry, 2));
        int  bit_in_word = NUM2INT (rb_ary_entry(entry, 3));
        int  bits        = NUM2INT (rb_ary_entry(entry, 4));
        ca_struct_write_bitfield_fast(ca->ptr + start_byte,
                                      view_bytes, bit_in_word, bits, val);
        return val;
      }
      case FAST_KIND_ENDIAN: {
        ca_size_t offset    = NUM2SIZE(rb_ary_entry(entry, 1));
        int  type_code = NUM2INT (rb_ary_entry(entry, 2));
        ca_struct_write_endian_swapped_fast(ca->ptr + offset, type_code, val);
        return val;
      }
      default:
        rb_raise(rb_eRuntimeError,
                 "[BUG] FAST_PRIMITIVES unknown kind %d", kind);
      }
    }
  }

  /* Dispatch-table path */
  VALUE dispatch_table = rb_const_get(klass, rb_intern("DISPATCH_TABLE"));
  VALUE pair = rb_hash_aref(dispatch_table, name_s);
  if (!NIL_P(pair)) {
    VALUE writer = rb_ary_entry(pair, 1);
    VALUE data_val = rb_ivar_get(self, rb_intern("@data"));
    rb_funcall(writer, rb_intern("call"), 2, data_val, val);
    return val;
  }

  /* Unknown name: fall back to send("name=", val). */
  VALUE setter_name = rb_str_plus(rb_obj_as_string(name), rb_str_new_cstr("="));
  return rb_funcall(self, rb_intern_str(setter_name), 1, val);
}

/* ---------------------------------------------------------------------
   C-native CAStruct#initialize.

   Always creates @data = CScalar.new(klass) as an entity.  Hash init
   walks the Hash once, dispatching each key through
   ca_struct_dispatch_write and accumulating unknown keys into a
   single ArgumentError.  Positional init dispatches argv[i] under
   MEMBERS[i].
   --------------------------------------------------------------------- */

typedef struct {
  VALUE  klass;
  VALUE  data_val;
  VALUE  unknown_keys;   /* lazily-allocated Array; Qnil until needed */
} ca_struct_hash_init_state_t;

/* rb_hash_foreach callback: dispatch one key/val pair via the
   shared write helper, accumulating unknown keys for a single
   ArgumentError after the iteration. */
static int
ca_struct_hash_init_iter (VALUE key, VALUE val, VALUE state_va)
{
  ca_struct_hash_init_state_t *st =
    (ca_struct_hash_init_state_t *) state_va;
  VALUE name_s = ca_struct_resolve_name(st->klass, key);
  if (!ca_struct_dispatch_write(st->klass, name_s, val, st->data_val)) {
    if (NIL_P(st->unknown_keys)) st->unknown_keys = rb_ary_new();
    rb_ary_push(st->unknown_keys, key);
  }
  return ST_CONTINUE;
}

static VALUE
rb_ca_struct_initialize (int argc, VALUE *argv, VALUE self)
{
  VALUE klass = rb_obj_class(self);

  /* @data is a CScalar entity sized to klass::DATA_SIZE.  The
     FAST_PRIMITIVES / dispatcher paths access ca->ptr directly,
     so it must be an entity (a view would not carry a stable ptr
     across the fast path). */
  VALUE data_val = rb_funcall(rb_cCScalar, rb_intern("new"), 1, klass);
  rb_ivar_set(self, rb_intern("@data"), data_val);

  if (argc == 0) return Qnil;

  /* Hash init */
  if (argc == 1 && TYPE(argv[0]) == T_HASH) {
    VALUE hash = argv[0];
    ca_struct_hash_init_state_t state = {
      .klass        = klass,
      .data_val     = data_val,
      .unknown_keys = Qnil,
    };
    /* CAREFUL: pass ca_struct_hash_init_iter without a cast.  Its
       signature already matches rb_hash_foreach's callback shape,
       and the old (int (*)(ANYARGS)) cast collapses to
       (int (*)(void)) under C23 and is rejected by gcc-15 as an
       incompatible pointer type. */
    rb_hash_foreach(hash,
                    ca_struct_hash_init_iter,
                    (VALUE) &state);
    if (!NIL_P(state.unknown_keys)) {
      VALUE members = rb_const_get(klass, rb_intern("MEMBERS"));
      VALUE unknown_inspect = rb_inspect(state.unknown_keys);
      VALUE known_inspect   = rb_inspect(members);
      rb_raise(rb_eArgError,
               "unknown member(s) for %s: %s (known: %s)",
               rb_class2name(klass),
               StringValueCStr(unknown_inspect),
               StringValueCStr(known_inspect));
    }
    return Qnil;
  }

  /* Positional init */
  VALUE members = rb_const_get(klass, rb_intern("MEMBERS"));
  long mems_size = RARRAY_LEN(members);
  if (argc > mems_size) {
    rb_raise(rb_eArgError,
             "too many arguments for %s.new (<%d> for <%ld>)",
             rb_class2name(klass), argc, mems_size);
  }
  for (int i = 0; i < argc; i++) {
    VALUE name_s = rb_ary_entry(members, i);
    if (!ca_struct_dispatch_write(klass, name_s, argv[i], data_val)) {
      /* Unreachable for Builder-constructed subclasses: MEMBERS
         entries are seeded into both FAST_PRIMITIVES and
         DISPATCH_TABLE.  Fall back to send for hand-built
         subclasses that only define writers. */
      VALUE setter_name = rb_str_plus(rb_obj_as_string(name_s),
                                      rb_str_new_cstr("="));
      rb_funcall(self, rb_intern_str(setter_name), 1, argv[i]);
    }
  }
  return Qnil;
}

/* ---------------------------------------------------------------------
   Install the C `[]` / `[]=` / `initialize` on the given class.
   Called from lib/carray/struct.rb once CAStruct is defined.
   --------------------------------------------------------------------- */

static VALUE
rb_carray_install_castruct_methods (VALUE self, VALUE klass)
{
  if (!RB_TYPE_P(klass, T_CLASS)) {
    rb_raise(rb_eTypeError, "expected a Class");
  }
  rb_define_method(klass, "[]",         rb_ca_struct_aref, 1);
  rb_define_method(klass, "[]=",        rb_ca_struct_aset, 2);
  rb_define_method(klass, "initialize", rb_ca_struct_initialize, -1);
  return klass;
}

void
Init_carray_struct (void)
{
  /* Singleton on rb_cCArray so lib/carray/struct.rb can call it as
     `CArray.__install_castruct_methods__(klass)`. */
  rb_define_singleton_method(rb_cCArray, "__install_castruct_methods__",
                             rb_carray_install_castruct_methods, 1);
}
