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
   operand's format) otherwise needs an external gem (numo-narray-memoryview,
   red-arrow).  This mock backs a 1-D contiguous view with an arbitrary format
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

  /* Re-export the flag constants for Ruby tests. */
  rb_define_const(mod, "SIMPLE",            INT2NUM(RUBY_MEMORY_VIEW_SIMPLE));
  rb_define_const(mod, "WRITABLE",          INT2NUM(RUBY_MEMORY_VIEW_WRITABLE));
  rb_define_const(mod, "FORMAT",            INT2NUM(RUBY_MEMORY_VIEW_FORMAT));
  rb_define_const(mod, "MULTI_DIMENSIONAL", INT2NUM(RUBY_MEMORY_VIEW_MULTI_DIMENSIONAL));
  rb_define_const(mod, "STRIDES",           INT2NUM(RUBY_MEMORY_VIEW_STRIDES));
  rb_define_const(mod, "ROW_MAJOR",         INT2NUM(RUBY_MEMORY_VIEW_ROW_MAJOR));
  rb_define_const(mod, "COLUMN_MAJOR",      INT2NUM(RUBY_MEMORY_VIEW_COLUMN_MAJOR));
}
