/* ---------------------------------------------------------------------------

  ca_obj_time.c

  CATime — semantic mask (Face) over int64 storage.  Datetime
  values represented as an int64 count in a chosen `unit`.

  A Face is a mask of a semantic type (= same storage type, identifier +
  unit layered on top); sibling to CAFake (= mask of data_type
  conversion).  Storage ops are thin-forwarded to the parent via the
  ca_face_* helpers (ca_obj_face.h).  The Ruby-side Comparable / to_time
  / <=> surface lives in lib/carray/time.rb.

--------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"

/* unit enum (base epoch is 1970-01-01) */
enum {
  CA_DATETIME_UNIT_Y  = 0,
  CA_DATETIME_UNIT_M  = 1,
  CA_DATETIME_UNIT_W  = 2,
  CA_DATETIME_UNIT_D  = 3,
  CA_DATETIME_UNIT_h  = 4,
  CA_DATETIME_UNIT_m  = 5,
  CA_DATETIME_UNIT_s  = 6,
  CA_DATETIME_UNIT_ms = 7,
  CA_DATETIME_UNIT_us = 8,
  CA_DATETIME_UNIT_ns = 9,    /* pandas default */
  CA_DATETIME_UNIT_ps = 10,
  CA_DATETIME_UNIT_fs = 11,
  CA_DATETIME_UNIT_as = 12
};

typedef struct {
  /* === CAView prefix === */
  int16_t    obj_type;
  int8_t     data_type;        /* fixed to CA_INT64 */
  int8_t     ndim;
  int32_t    flags;            /* CA_FLAG_IS_FACE set */
  ca_size_t  bytes;            /* fixed to sizeof(int64_t) */
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray    *parent;
  uint32_t   attach;
  uint8_t    nosync;
  /* === Face tail === */
  int8_t     unit;             /* CA_DATETIME_UNIT_* (the tick base) */
  int64_t    count;            /* tick multiplier N (tick = count * base) */
} CATime;

static size_t
ca_time_dsize (const void *ap)
{
  const CATime *ca = (const CATime *) ap;
  return sizeof(CATime) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks.  CATime owns a single ndim-sized tail
   (dim) in the _pool buffer.  No alloc collapse (1 tail), but routes the
   class onto the uniform pool alloc/free discipline (ca_array_alloc /
   ca_array_free). */
static size_t
ca_time_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_time_pool_init (void *ap, int8_t ndim)
{
  CATime *ca = (CATime *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t catime_data_type = {
    .parent = &caface_data_type,
    .wrap_struct_name = "CATime",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_time_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_TIME;
static VALUE rb_cCATime;
static VALUE rb_cCATimeElement;

/* forward decls (defined later in the file) */
int8_t ca_time_unit_value (VALUE sym);
VALUE  ca_time_unit_to_symbol (int8_t unit);
VALUE  ca_time_resolution (int64_t count, int8_t unit);
void   ca_time_extract_unit (VALUE unit, int8_t *base, int64_t *count);

/* CATime::Element as a C TypedData struct: storing value + unit in
   the struct avoids per-cell Ruby Integer boxing and Ruby `initialize`
   dispatch on the fetch hot path.  value is the raw parent int64 (= the
   tick index under self's resolution); unit is the CA_DATETIME_UNIT_*
   base enum and count is the tick multiplier (tick = count * base). */
typedef struct {
  int64_t value;
  int8_t  unit;
  int64_t count;
} CATimeElement;

static size_t
ca_time_element_dsize (const void *ap)
{
  (void) ap;
  return sizeof(CATimeElement);
}

static void
ca_time_element_free (void *ap)
{
  if (ap) xfree(ap);
}

const rb_data_type_t catime_element_data_type = {
  .wrap_struct_name = "CATime::Element",
  .function = {
    .dmark = NULL,
    .dfree = ca_time_element_free,
    .dsize = ca_time_element_dsize,
  },
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
rb_ca_time_element_s_allocate (VALUE klass)
{
  CATimeElement *s;
  return TypedData_Make_Struct(klass, CATimeElement,
                               &catime_element_data_type, s);
}

static VALUE
rb_ca_time_element_initialize (VALUE self, VALUE value, VALUE unit)
{
  CATimeElement *s;
  TypedData_Get_Struct(self, CATimeElement,
                       &catime_element_data_type, s);
  s->value = NUM2LL(value);
  ca_time_extract_unit(unit, &s->unit, &s->count);
  return self;
}

static VALUE
rb_ca_time_element_value (VALUE self)
{
  CATimeElement *s;
  TypedData_Get_Struct(self, CATimeElement,
                       &catime_element_data_type, s);
  return LL2NUM(s->value);
}

/* unit → CATime::Resolution(count, base) */
static VALUE
rb_ca_time_element_unit (VALUE self)
{
  CATimeElement *s;
  TypedData_Get_Struct(self, CATimeElement,
                       &catime_element_data_type, s);
  return ca_time_resolution(s->count, s->unit);
}

/* ------------------------------------------------------------------- */

int
ca_time_setup (CATime *ca, CArray *parent, int8_t unit, int64_t count)
{
  if ( parent->data_type != CA_INT64 ) {
    rb_raise(rb_eTypeError,
             "CATime requires int64 storage (parent.data_type != CA_INT64)");
  }

  ca->obj_type  = CA_OBJ_TIME;
  /* The surface data_type is CA_FIXLEN, not CA_INT64: this routes
     mkkernel dispatch onto the ca_*_not_implement stubs so numeric
     kernels are gated off automatically.  bytes stays at 8 to match the
     parent int64 storage. */
  ca->data_type = CA_FIXLEN;
  /* ORDERABLE: int64 storage order == datetime <=> order, so sort family may
     descend to storage.  NOT COMPARABLE: an external query may carry a
     different unit, so raw storage compare against a query is unsafe. */
  ca->flags     = CA_FLAG_IS_FACE | CA_FLAG_FACE_ORDERABLE_STORAGE;
  ca->ndim      = parent->ndim;
  ca->bytes     = sizeof(int64_t);
  ca->elements  = parent->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, parent->ndim);
  }
  memcpy(ca->dim, parent->dim, sizeof(ca_size_t) * parent->ndim);

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->unit      = unit;
  ca->count     = count;

  if ( ca_has_mask(parent) ) {
    ca_create_mask((CArray *) ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  if ( ca_test_flag(parent, CA_FLAG_READ_ONLY) ) {
    ca_set_flag(ca, CA_FLAG_READ_ONLY);
  }

  return 0;
}

CATime *
ca_time_new (CArray *parent, int8_t unit, int64_t count)
{
  CATime *ca = (CATime *) ca_array_alloc(CA_OBJ_TIME, parent->ndim);
  ca_time_setup(ca, parent, unit, count);
  return ca;
}

static void
free_ca_time (void *ap)
{
  CATime *ca = (CATime *) ap;
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
ca_time_func_clone (void *ap)
{
  CATime *ca = (CATime *) ap;
  return ca_time_new(ca->parent, ca->unit, ca->count);
}

static void
ca_time_func_allocate (void *ap)
{
  CATime *ca = (CATime *) ap;
  /* alias: parent attach + alias parent->ptr (= no malloc; Face has identical data) */
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr;
}

static void
ca_time_func_create_mask (void *ap)
{
  CATime *ca = (CATime *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_refer_new(ca->parent->mask,
                                      CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_time_func = {
  -1, /* CA_OBJ_TIME — filled by ca_install_obj_type */
  CA_VIEW_ARRAY,
  free_ca_time,
  ca_time_func_clone,
  ca_time_func_allocate,
  ca_face_attach,
  ca_face_sync,
  ca_face_detach,
  ca_face_fill_data,
  ca_time_func_create_mask,
  ca_face_xfer_index,
  ca_face_xfer_addrs,
  NULL,                              /* fold_stride: identity Face is not foldable */
  ca_face_xfer_stride,
  ca_face_xfer_all,
  .fill_addrs  = ca_face_fill_addrs,
  .fill_stride = ca_face_fill_stride,
};

/* ------------------------------------------------------------------- */

/* parse unit symbol → enum (also referenced by CATimedelta) */
int8_t
ca_time_unit_value (VALUE sym)
{
  if ( NIL_P(sym) ) return CA_DATETIME_UNIT_ns;  /* default: pandas-style */
  if ( TYPE(sym) != T_SYMBOL ) {
    rb_raise(rb_eArgError, "unit must be a Symbol (e.g. :ns, :us, :s, :D)");
  }
  ID id = SYM2ID(sym);
  if ( id == rb_intern("Y") )  return CA_DATETIME_UNIT_Y;
  if ( id == rb_intern("M") )  return CA_DATETIME_UNIT_M;
  if ( id == rb_intern("W") )  return CA_DATETIME_UNIT_W;
  if ( id == rb_intern("D") )  return CA_DATETIME_UNIT_D;
  if ( id == rb_intern("h") )  return CA_DATETIME_UNIT_h;
  if ( id == rb_intern("m") )  return CA_DATETIME_UNIT_m;
  if ( id == rb_intern("s") )  return CA_DATETIME_UNIT_s;
  if ( id == rb_intern("ms") ) return CA_DATETIME_UNIT_ms;
  if ( id == rb_intern("us") ) return CA_DATETIME_UNIT_us;
  if ( id == rb_intern("ns") ) return CA_DATETIME_UNIT_ns;
  if ( id == rb_intern("ps") ) return CA_DATETIME_UNIT_ps;
  if ( id == rb_intern("fs") ) return CA_DATETIME_UNIT_fs;
  if ( id == rb_intern("as") ) return CA_DATETIME_UNIT_as;
  rb_raise(rb_eArgError, "unknown datetime unit: %"PRIsVALUE, sym);
  return 0; /* unreachable */
}

VALUE
ca_time_unit_to_symbol (int8_t unit)
{
  switch (unit) {
    case CA_DATETIME_UNIT_Y:  return ID2SYM(rb_intern("Y"));
    case CA_DATETIME_UNIT_M:  return ID2SYM(rb_intern("M"));
    case CA_DATETIME_UNIT_W:  return ID2SYM(rb_intern("W"));
    case CA_DATETIME_UNIT_D:  return ID2SYM(rb_intern("D"));
    case CA_DATETIME_UNIT_h:  return ID2SYM(rb_intern("h"));
    case CA_DATETIME_UNIT_m:  return ID2SYM(rb_intern("m"));
    case CA_DATETIME_UNIT_s:  return ID2SYM(rb_intern("s"));
    case CA_DATETIME_UNIT_ms: return ID2SYM(rb_intern("ms"));
    case CA_DATETIME_UNIT_us: return ID2SYM(rb_intern("us"));
    case CA_DATETIME_UNIT_ns: return ID2SYM(rb_intern("ns"));
    case CA_DATETIME_UNIT_ps: return ID2SYM(rb_intern("ps"));
    case CA_DATETIME_UNIT_fs: return ID2SYM(rb_intern("fs"));
    case CA_DATETIME_UNIT_as: return ID2SYM(rb_intern("as"));
  }
  return Qnil;
}

/* Build a CATime::Resolution(count, base) descriptor.  Shared by
   CATime and CATimedelta (the descriptor type is nested under
   CATime and carries no group-specific state). */
VALUE
ca_time_resolution (int64_t count, int8_t unit)
{
  VALUE rescls = rb_const_get(rb_cCATime, rb_intern("Resolution"));
  return rb_funcall(rescls, rb_intern("new"), 2,
                    LL2NUM(count), ca_time_unit_to_symbol(unit));
}

/* Normalize a unit spec (Symbol / String / Resolution / nil) into a base
   enum + count multiplier.  nil defaults to (1, :ns); a bare Symbol is the
   count-1 shorthand; a String / Resolution routes through Resolution.parse. */
void
ca_time_extract_unit (VALUE unit, int8_t *base, int64_t *count)
{
  if ( NIL_P(unit) ) {
    *base  = CA_DATETIME_UNIT_ns;
    *count = 1;
    return;
  }
  if ( TYPE(unit) == T_SYMBOL ) {
    *base  = ca_time_unit_value(unit);
    *count = 1;
    return;
  }
  VALUE rescls = rb_const_get(rb_cCATime, rb_intern("Resolution"));
  VALUE res = RTEST(rb_obj_is_kind_of(unit, rescls))
              ? unit
              : rb_funcall(rescls, rb_intern("parse"), 1, unit);
  *base  = ca_time_unit_value(rb_funcall(res, rb_intern("base"), 0));
  *count = NUM2LL(rb_funcall(res, rb_intern("count"), 0));
}

/* CATime.wrap(int64_array, base_enum, count) — zero-copy Face wrap.
   The public unit-spec normalization (Symbol / String / Resolution) is done
   on the Ruby side; this primitive takes the resolved base enum + count. */
VALUE
rb_ca_time_wrap (VALUE parent_val, int8_t unit, int64_t count)
{
  volatile VALUE obj;
  CArray *parent;
  CATime *ca;

  rb_check_carray_object(parent_val);
  TypedData_Get_Struct(parent_val, CArray, &carray_data_type, parent);

  ca  = ca_time_new(parent, unit, count);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, parent_val);
  return obj;
}

/* __wrap__(raw, unit_spec) — primitive; unit_spec is Symbol / String /
   Resolution / nil (normalized here). */
static VALUE
rb_ca_time_wrap_method (VALUE klass, VALUE raw, VALUE unit_spec)
{
  int8_t  base;
  int64_t count;
  (void) klass;
  ca_time_extract_unit(unit_spec, &base, &count);
  return rb_ca_time_wrap(raw, base, count);
}

/* CATime#unit → CATime::Resolution(count, base) */
static VALUE
rb_ca_time_unit (VALUE self)
{
  CATime *ca;
  TypedData_Get_Struct(self, CATime, &catime_data_type, ca);
  return ca_time_resolution(ca->count, ca->unit);
}

/* storage_to_scalar implemented in C to avoid per-cell Ruby method dispatch
   on the fetch hot path.  CAREFUL: there must be no Ruby `storage_to_scalar`
   def in lib/carray/time.rb — require order would let a Ruby version
   shadow this C method (the Ruby `scalar_to_storage` write hook is a
   distinct method and does not collide).
   Since the Face surface is CA_FIXLEN, fetch delivers an 8-byte raw
   String.  Decode it as the parent int64 (= storage), then construct
   CATime::Element(epoch, unit). */
static VALUE
rb_ca_time_storage_to_scalar (VALUE self, VALUE raw)
{
  CATime *ca;
  CATimeElement *s;
  VALUE scalar_obj;
  int64_t epoch;

  TypedData_Get_Struct(self, CATime, &catime_data_type, ca);

  if ( TYPE(raw) == T_STRING ) {
    if ( RSTRING_LEN(raw) != (long) sizeof(int64_t) ) {
      rb_raise(rb_eArgError,
               "CATime#storage_to_scalar: expected %lu bytes, got %ld",
               (unsigned long) sizeof(int64_t), RSTRING_LEN(raw));
    }
    memcpy(&epoch, RSTRING_PTR(raw), sizeof(int64_t));
  }
  else {
    epoch = NUM2LL(raw);
  }

  /* Direct alloc + struct field write — no LL2NUM, no rb_class_new_instance,
     no Ruby initialize dispatch. */
  scalar_obj = TypedData_Make_Struct(rb_cCATimeElement,
                                     CATimeElement,
                                     &catime_element_data_type, s);
  s->value = epoch;
  s->unit  = ca->unit;
  s->count = ca->count;
  return scalar_obj;
}

static VALUE
rb_ca_time_s_allocate (VALUE klass)
{
  CATime *ca;
  return TypedData_Make_Struct(klass, CATime,
                                &catime_data_type, ca);
}

static VALUE
rb_ca_time_initialize_copy (VALUE self, VALUE other)
{
  CATime *ca, *cs;
  TypedData_Get_Struct(self,  CATime, &catime_data_type, ca);
  TypedData_Get_Struct(other, CATime, &catime_data_type, cs);
  if ( ca_func[CA_OBJ_TIME].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_TIME, cs->parent->ndim);
  }
  ca_time_setup(ca, cs->parent, cs->unit, cs->count);
  return self;
}

/* Face state homogeneity check — two CATime instances are
   compatible iff their resolution (base + count) matches. */
static int
ca_time_state_compatible (CArray *a, CArray *b)
{
  CATime *da = (CATime *) a;
  CATime *db = (CATime *) b;
  return ( da->unit == db->unit && da->count == db->count ) ? 1 : 0;
}

void
Init_ca_obj_time (void)
{
  rb_cCATime = rb_define_class("CATime", rb_cCAFace);

  ca_time_func.struct_size = sizeof(CATime);
  ca_time_func.pool_bytes  = ca_time_pool_bytes;
  ca_time_func.pool_init   = ca_time_pool_init;

  CA_OBJ_TIME = ca_install_obj_type(rb_cCATime,
                                          &catime_data_type,
                                          rb_cCArrayMask,
                                          &carray_mask_data_type,
                                          &ca_time_func, sizeof(ca_time_func));
  rb_define_const(rb_cObject, "CA_OBJ_TIME", INT2NUM(CA_OBJ_TIME));

  rb_define_alloc_func(rb_cCATime, rb_ca_time_s_allocate);
  rb_define_method(rb_cCATime, "initialize_copy",
                                     rb_ca_time_initialize_copy, 1);

  rb_define_singleton_method(rb_cCATime, "__wrap__",
                                     rb_ca_time_wrap_method, 2);
  rb_define_method(rb_cCATime, "unit", rb_ca_time_unit, 0);
  rb_define_method(rb_cCATime, "storage_to_scalar",
                                     rb_ca_time_storage_to_scalar, 1);
  /* Registers the C-level fast path so CA_FACE_STORAGE_TO_SCALAR_IF_FACE can
     skip rb_funcall on the hot path. */
  ca_face_register_storage_to_scalar(CA_OBJ_TIME,
                                     rb_ca_time_storage_to_scalar);
  ca_face_register_state_compatible(CA_OBJ_TIME,
                                    ca_time_state_compatible);
  /* unit is pure metadata (= no per-parent buffer), so the Face wrap can
     be carried across multi-parent constructions like CAStack
     (portable = 1). */
  ca_face_register_state_portable(CA_OBJ_TIME, 1);

  /* CATime::Element as a C-backed TypedData class.  The Ruby-side
     definition in lib/carray/time.rb keeps the Comparable include +
     to_time / to_s / inspect / <=> / == methods; the C side owns the
     storage (int64 value + int8 unit) and the allocator + initialize +
     value + unit accessors. */
  rb_cCATimeElement = rb_define_class_under(rb_cCATime,
                                                 "Element", rb_cObject);
  rb_define_alloc_func(rb_cCATimeElement,
                       rb_ca_time_element_s_allocate);
  rb_define_method(rb_cCATimeElement, "initialize",
                   rb_ca_time_element_initialize, 2);
  rb_define_method(rb_cCATimeElement, "value",
                   rb_ca_time_element_value, 0);
  rb_define_method(rb_cCATimeElement, "unit",
                   rb_ca_time_element_unit, 0);
}
