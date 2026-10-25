/* Test borrower extension for CArray's MemoryView protocol support.
   Calls rb_memory_view_get on a CArray and returns the view's data,
   shape, strides, byte_size, format, item_size, readonly, ndim as a
   Ruby hash for assertion. */

#include "ruby.h"
#include "ruby/memory_view.h"
#include <string.h>

/* PEP 3118 byte_size is product(shape) * item_size and does NOT cover the
   addressable span of a strided view.  Consumers that need to copy/bound
   the full strided range compute it themselves as
       Σ_k (shape[k]-1)*|strides[k]| + item_size
   when ndim >= 1, or item_size when ndim == 0. */
static ssize_t
mv_strided_span (const rb_memory_view_t *view)
{
  ssize_t span = view->item_size;
  ssize_t i;
  if (view->ndim == 0) {
    return span;
  }
  for (i = 0; i < view->ndim; i++) {
    ssize_t s = view->strides[i];
    if (s < 0) s = -s;
    if (view->shape[i] > 0) {
      span += (view->shape[i] - 1) * s;
    }
  }
  return span;
}

static VALUE
mv_inspect (VALUE self, VALUE obj, VALUE flags_v)
{
  rb_memory_view_t view;
  int flags = NUM2INT(flags_v);
  VALUE result;
  VALUE shape_a, strides_a, data_s;
  ssize_t i;

  if (! rb_memory_view_get(obj, &view, flags)) {
    return Qnil;
  }

  shape_a = rb_ary_new();
  strides_a = rb_ary_new();
  for (i = 0; i < view.ndim; i++) {
    rb_ary_push(shape_a,   LL2NUM((long long) view.shape[i]));
    rb_ary_push(strides_a, LL2NUM((long long) view.strides[i]));
  }

  /* Copy bytes into a String for safe transport to Ruby.  For strided
     views the visible data is spread over the full span, not just
     byte_size, so copy the span instead. */
  data_s = rb_str_new((const char *) view.data, mv_strided_span(&view));

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("data")),       data_s);
  rb_hash_aset(result, ID2SYM(rb_intern("byte_size")),  LL2NUM((long long) view.byte_size));
  rb_hash_aset(result, ID2SYM(rb_intern("ndim")),       LL2NUM((long long) view.ndim));
  rb_hash_aset(result, ID2SYM(rb_intern("item_size")),  LL2NUM((long long) view.item_size));
  rb_hash_aset(result, ID2SYM(rb_intern("format")),
               view.format ? rb_str_new_cstr(view.format) : Qnil);
  rb_hash_aset(result, ID2SYM(rb_intern("readonly")),   view.readonly ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("shape")),      shape_a);
  rb_hash_aset(result, ID2SYM(rb_intern("strides")),    strides_a);
  rb_hash_aset(result, ID2SYM(rb_intern("row_major")),
               rb_memory_view_is_row_major_contiguous(&view) ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("col_major")),
               rb_memory_view_is_column_major_contiguous(&view) ? Qtrue : Qfalse);

  rb_memory_view_release(&view);
  return result;
}

/* Write a single int32 value at byte offset, then release.  Returns true if
   the get succeeded and the write was performed. */
static VALUE
mv_write_int32 (VALUE self, VALUE obj, VALUE offset_v, VALUE value_v)
{
  rb_memory_view_t view;
  ssize_t off = (ssize_t) NUM2LL(offset_v);
  int32_t v   = (int32_t) NUM2INT(value_v);

  if (! rb_memory_view_get(obj, &view,
                           RUBY_MEMORY_VIEW_STRIDES | RUBY_MEMORY_VIEW_WRITABLE)) {
    return Qfalse;
  }
  if (off < 0 || off + (ssize_t) sizeof(int32_t) > mv_strided_span(&view)) {
    rb_memory_view_release(&view);
    return Qfalse;
  }
  memcpy((char *) view.data + off, &v, sizeof(int32_t));
  rb_memory_view_release(&view);
  return Qtrue;
}

/* Like write_int32 but lets the caller choose the flags.  Useful for
   testing the SIMPLE-fallback path on virtual destinations. */
static VALUE
mv_write_int32_flags (VALUE self, VALUE obj, VALUE offset_v, VALUE value_v,
                      VALUE flags_v)
{
  rb_memory_view_t view;
  ssize_t off = (ssize_t) NUM2LL(offset_v);
  int32_t v   = (int32_t) NUM2INT(value_v);
  int flags   = NUM2INT(flags_v) | RUBY_MEMORY_VIEW_WRITABLE;

  if (! rb_memory_view_get(obj, &view, flags)) {
    return Qfalse;
  }
  if (off < 0 || off + (ssize_t) sizeof(int32_t) > mv_strided_span(&view)) {
    rb_memory_view_release(&view);
    return Qfalse;
  }
  memcpy((char *) view.data + off, &v, sizeof(int32_t));
  rb_memory_view_release(&view);
  return Qtrue;
}

/* ------------------------------------------------------------------
   MVBorrower::Producer -- a minimal MemoryView *producer* mock.

   Ruby's MemoryView is experimental and ships no producer for tests, so
   exercising the consumer side (e.g. CArray.result_type reading an MV
   operand's format) otherwise needs an external gem (red-arrow).  This mock backs a 1-D contiguous view with an arbitrary format
   string, so tests can craft the exact PEP 3118 format they want to probe
   (including cross-endian and typeless format == NULL).

   Two opt-in quirks reproduce producer behaviour the consumer must tolerate:

     shape_null      the view advertises a format and ndim == 1 but leaves
                     shape/strides NULL (PEP 3118 SIMPLE form for a
                     contiguous 1-D buffer).  Length is then recoverable
                     only as byte_size / item_size.

     sloppy_release  get() writes just the fields it owns instead of
                     zero-filling the struct, and release() frees
                     item_desc.components unconditionally.  A consumer that
                     does not zero-init the rb_memory_view_t before get()
                     hands stack garbage to xfree().
   ------------------------------------------------------------------ */

typedef struct {
  VALUE   src;          /* backing String (GC-marked; view->data aliases it) */
  int     has_format;
  char    format[16];
  ssize_t item_size;
  ssize_t shape[1];
  ssize_t strides[1];
  int     shape_null;
  int     sloppy_release;
} mv_producer_t;

static void
mv_producer_mark (void *p)
{
  rb_gc_mark(((mv_producer_t *) p)->src);
}

static void
mv_producer_free (void *p)
{
  xfree(p);
}

static size_t
mv_producer_size (const void *p)
{
  (void) p;
  return sizeof(mv_producer_t);
}

static const rb_data_type_t mv_producer_type = {
  "MVBorrower::Producer",
  { mv_producer_mark, mv_producer_free, mv_producer_size, },
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY,
};

static bool
mv_producer_get (VALUE obj, rb_memory_view_t *view, int flags)
{
  mv_producer_t *p;
  TypedData_Get_Struct(obj, mv_producer_t, &mv_producer_type, p);
  /* readonly mock: refuse writable requests. */
  if (flags & RUBY_MEMORY_VIEW_WRITABLE) return false;

  if (! p->sloppy_release) {
    memset(view, 0, sizeof(*view));   /* zero item_desc / sub_offsets / private */
  }
  view->obj       = obj;
  view->data      = RSTRING_PTR(p->src);
  view->byte_size = (ssize_t) RSTRING_LEN(p->src);
  view->readonly  = true;
  view->format    = p->has_format ? p->format : NULL;
  view->item_size = p->item_size;
  view->ndim      = 1;
  view->shape     = p->shape_null ? NULL : p->shape;
  view->strides   = p->shape_null ? NULL : p->strides;
  return true;
}

static bool
mv_producer_release (VALUE obj, rb_memory_view_t *view)
{
  mv_producer_t *p;
  TypedData_Get_Struct(obj, mv_producer_t, &mv_producer_type, p);
  /* shape/strides live in the struct; nothing of ours to free. */
  if (p->sloppy_release && view->item_desc.components) {
    xfree((void *) view->item_desc.components);
    view->item_desc.components = NULL;
  }
  return true;
}

static bool
mv_producer_available_p (VALUE obj)
{
  (void) obj;
  return true;
}

static const rb_memory_view_entry_t mv_producer_entry = {
  mv_producer_get,
  mv_producer_release,
  mv_producer_available_p,
};

static VALUE
mv_producer_alloc (VALUE klass)
{
  mv_producer_t *p;
  VALUE obj = TypedData_Make_Struct(klass, mv_producer_t, &mv_producer_type, p);
  p->src = Qnil;
  return obj;
}

/* Producer.new(bytes, format_or_nil, item_size, shape_null = false,
                 sloppy_release = false) */
static VALUE
mv_producer_init (int argc, VALUE *argv, VALUE self)
{
  VALUE str, fmt, isize, shape_null, sloppy;
  mv_producer_t *p;
  ssize_t n;

  rb_scan_args(argc, argv, "32", &str, &fmt, &isize, &shape_null, &sloppy);
  Check_Type(str, T_STRING);
  TypedData_Get_Struct(self, mv_producer_t, &mv_producer_type, p);

  p->src            = str;
  p->item_size      = (ssize_t) NUM2LL(isize);
  p->shape_null     = RTEST(shape_null);
  p->sloppy_release = RTEST(sloppy);
  if (NIL_P(fmt)) {
    p->has_format = 0;
  }
  else {
    Check_Type(fmt, T_STRING);
    strncpy(p->format, RSTRING_PTR(fmt), sizeof(p->format) - 1);
    p->format[sizeof(p->format) - 1] = '\0';
    p->has_format = 1;
  }
  n = (p->item_size > 0) ? (ssize_t) RSTRING_LEN(str) / p->item_size : 0;
  p->shape[0]   = n;
  p->strides[0] = p->item_size;
  return self;
}

/* ------------------------------------------------------------------
   MVBorrower::Crafted -- a producer whose every field (shape, strides,
   offset, byte_size, readonly, get failing or raising) is chosen by the
   test, for probing the consumer side against producers that misstate
   their geometry.  Nothing is validated here on purpose.  gets / releases
   count the protocol calls.
   ------------------------------------------------------------------ */

#define CRAFTED_MAXD 8

typedef struct {
  VALUE   src;            /* backing String, marked */
  long    offset;         /* view->data = RSTRING_PTR(src) + offset */
  long    byte_size;      /* -1 = len - offset */
  int     has_format;
  char    format[64];
  long    item_size;
  int     ndim;
  ssize_t shape[CRAFTED_MAXD];
  ssize_t strides[CRAFTED_MAXD];
  int     shape_null, strides_null;
  int     readonly;       /* view->readonly */
  int     refuse_writable;/* get() returns false on WRITABLE */
  int     fail_get;       /* get() returns false always */
  int     raise_in_get;   /* get() raises */
  int     available;
  long    gets, releases;
} crafted_t;

static void crafted_mark (void *p) { rb_gc_mark(((crafted_t *) p)->src); }
static void crafted_free (void *p) { xfree(p); }
static size_t crafted_size (const void *p) { (void) p; return sizeof(crafted_t); }
static const rb_data_type_t crafted_type = {
  "MVBorrower::Crafted", { crafted_mark, crafted_free, crafted_size, }, 0, 0,
  RUBY_TYPED_FREE_IMMEDIATELY,
};

static crafted_t *crafted_get_struct (VALUE obj)
{
  crafted_t *p;
  TypedData_Get_Struct(obj, crafted_t, &crafted_type, p);
  return p;
}

static bool
crafted_get (VALUE obj, rb_memory_view_t *view, int flags)
{
  crafted_t *p = crafted_get_struct(obj);
  if (p->raise_in_get) rb_raise(rb_eRuntimeError, "CraftedMV: get raised");
  if (p->fail_get) return false;
  if ((flags & RUBY_MEMORY_VIEW_WRITABLE) && p->refuse_writable) return false;
  memset(view, 0, sizeof(*view));
  view->obj       = obj;
  view->data      = RSTRING_PTR(p->src) + p->offset;
  view->byte_size = p->byte_size >= 0 ? p->byte_size
                                      : (ssize_t) RSTRING_LEN(p->src) - p->offset;
  view->readonly  = p->readonly ? true : false;
  view->format    = p->has_format ? p->format : NULL;
  view->item_size = p->item_size;
  view->ndim      = p->ndim;
  view->shape     = p->shape_null ? NULL : p->shape;
  view->strides   = p->strides_null ? NULL : p->strides;
  p->gets++;
  return true;
}

static bool
crafted_release (VALUE obj, rb_memory_view_t *view)
{
  (void) view;
  /* A consumer freed at exit may release after this object is gone, and
     raising here is fatal during GC, so check without raising. */
  if (rb_typeddata_is_kind_of(obj, &crafted_type)) {
    ((crafted_t *) RTYPEDDATA_DATA(obj))->releases++;
  }
  return true;
}

static bool crafted_available_p (VALUE obj) { return crafted_get_struct(obj)->available; }

static const rb_memory_view_entry_t crafted_entry = { crafted_get, crafted_release, crafted_available_p };

static VALUE
crafted_alloc (VALUE klass)
{
  crafted_t *p;
  VALUE obj = TypedData_Make_Struct(klass, crafted_t, &crafted_type, p);
  p->src = Qnil;
  return obj;
}

static VALUE opt (VALUE h, const char *k) { return rb_hash_lookup(h, ID2SYM(rb_intern(k))); }
static int flag (VALUE h, const char *k) { return RTEST(opt(h, k)); }

/* Producer.new(bytes, format:, item_size:, shape:, strides: nil (=C order),
                offset: 0, byte_size: nil, readonly: true, refuse_writable: false,
                shape_null: false, strides_null: false, fail_get: false,
                raise_in_get: false, available: true) */
static VALUE
crafted_init (int argc, VALUE *argv, VALUE self)
{
  crafted_t *p = crafted_get_struct(self);
  VALUE bytes, h, v;
  int k;
  rb_scan_args(argc, argv, "1:", &bytes, &h);
  if (NIL_P(h)) h = rb_hash_new();
  StringValue(bytes);
  p->src = rb_str_new(RSTRING_PTR(bytes), RSTRING_LEN(bytes));
  v = opt(h, "format");
  if (NIL_P(v)) { p->has_format = 0; }
  else {
    StringValue(v);
    if (RSTRING_LEN(v) >= (long) sizeof(p->format)) rb_raise(rb_eArgError, "format too long");
    p->has_format = 1;
    memcpy(p->format, RSTRING_PTR(v), RSTRING_LEN(v));
    p->format[RSTRING_LEN(v)] = '\0';
  }
  v = opt(h, "item_size"); p->item_size = NIL_P(v) ? 1 : NUM2LONG(v);
  v = opt(h, "shape");
  if (NIL_P(v)) { p->ndim = 1; p->shape[0] = RSTRING_LEN(bytes) / p->item_size; }
  else {
    Check_Type(v, T_ARRAY);
    p->ndim = (int) RARRAY_LEN(v);
    if (p->ndim > CRAFTED_MAXD) rb_raise(rb_eArgError, "ndim > %d", CRAFTED_MAXD);
    for (k = 0; k < p->ndim; k++) p->shape[k] = NUM2LONG(rb_ary_entry(v, k));
  }
  v = opt(h, "strides");
  if (NIL_P(v)) {
    ssize_t s = p->item_size;
    for (k = p->ndim - 1; k >= 0; k--) { p->strides[k] = s; s *= p->shape[k]; }
  }
  else {
    Check_Type(v, T_ARRAY);
    if (RARRAY_LEN(v) != p->ndim) rb_raise(rb_eArgError, "strides length != ndim");
    for (k = 0; k < p->ndim; k++) p->strides[k] = NUM2LONG(rb_ary_entry(v, k));
  }
  v = opt(h, "offset");    p->offset = NIL_P(v) ? 0 : NUM2LONG(v);
  v = opt(h, "byte_size"); p->byte_size = NIL_P(v) ? -1 : NUM2LONG(v);
  v = opt(h, "readonly");  p->readonly = NIL_P(v) ? 1 : RTEST(v);
  v = opt(h, "available"); p->available = NIL_P(v) ? 1 : RTEST(v);
  p->refuse_writable = flag(h, "refuse_writable");
  p->shape_null      = flag(h, "shape_null");
  p->strides_null    = flag(h, "strides_null");
  p->fail_get        = flag(h, "fail_get");
  p->raise_in_get    = flag(h, "raise_in_get");
  return self;
}

static VALUE crafted_bytes (VALUE self) { crafted_t *p = crafted_get_struct(self); return rb_str_new(RSTRING_PTR(p->src), RSTRING_LEN(p->src)); }
static VALUE crafted_gets (VALUE self) { return LONG2NUM(crafted_get_struct(self)->gets); }
static VALUE crafted_releases (VALUE self) { return LONG2NUM(crafted_get_struct(self)->releases); }
static VALUE crafted_poke (VALUE self, VALUE off, VALUE byte)
{
  crafted_t *p = crafted_get_struct(self);
  long o = NUM2LONG(off);
  if (o < 0 || o >= RSTRING_LEN(p->src)) rb_raise(rb_eIndexError, "poke out of range");
  RSTRING_PTR(p->src)[o] = (char) NUM2INT(byte);
  return self;
}
/* Mutate a producer field after construction (e.g. make get() fail on the
   second call): set(:fail_get, true) etc. */
static VALUE crafted_set (VALUE self, VALUE key, VALUE val)
{
  crafted_t *p = crafted_get_struct(self);
  ID id = SYM2ID(key);
  if (id == rb_intern("fail_get")) p->fail_get = RTEST(val);
  else if (id == rb_intern("raise_in_get")) p->raise_in_get = RTEST(val);
  else if (id == rb_intern("available")) p->available = RTEST(val);
  else if (id == rb_intern("readonly")) p->readonly = RTEST(val);
  else if (id == rb_intern("refuse_writable")) p->refuse_writable = RTEST(val);
  else rb_raise(rb_eArgError, "unknown key");
  return self;
}

void
Init_mv_borrower (void)
{
  VALUE mod = rb_define_module("MVBorrower");
  rb_define_module_function(mod, "inspect_view",      mv_inspect, 2);
  rb_define_module_function(mod, "write_int32",       mv_write_int32, 3);
  rb_define_module_function(mod, "write_int32_flags", mv_write_int32_flags, 4);

  VALUE cProducer = rb_define_class_under(mod, "Producer", rb_cObject);
  rb_define_alloc_func(cProducer, mv_producer_alloc);
  rb_define_method(cProducer, "initialize", mv_producer_init, -1);
  rb_memory_view_register(cProducer, &mv_producer_entry);

  VALUE cCrafted = rb_define_class_under(mod, "Crafted", rb_cObject);
  rb_define_alloc_func(cCrafted, crafted_alloc);
  rb_define_method(cCrafted, "initialize", crafted_init, -1);
  rb_define_method(cCrafted, "bytes", crafted_bytes, 0);
  rb_define_method(cCrafted, "gets", crafted_gets, 0);
  rb_define_method(cCrafted, "releases", crafted_releases, 0);
  rb_define_method(cCrafted, "poke", crafted_poke, 2);
  rb_define_method(cCrafted, "set", crafted_set, 2);
  rb_memory_view_register(cCrafted, &crafted_entry);

  /* Re-export the flag constants for Ruby tests. */
  rb_define_const(mod, "SIMPLE",            INT2NUM(RUBY_MEMORY_VIEW_SIMPLE));
  rb_define_const(mod, "WRITABLE",          INT2NUM(RUBY_MEMORY_VIEW_WRITABLE));
  rb_define_const(mod, "FORMAT",            INT2NUM(RUBY_MEMORY_VIEW_FORMAT));
  rb_define_const(mod, "MULTI_DIMENSIONAL", INT2NUM(RUBY_MEMORY_VIEW_MULTI_DIMENSIONAL));
  rb_define_const(mod, "STRIDES",           INT2NUM(RUBY_MEMORY_VIEW_STRIDES));
  rb_define_const(mod, "ROW_MAJOR",         INT2NUM(RUBY_MEMORY_VIEW_ROW_MAJOR));
  rb_define_const(mod, "COLUMN_MAJOR",      INT2NUM(RUBY_MEMORY_VIEW_COLUMN_MAJOR));
}
