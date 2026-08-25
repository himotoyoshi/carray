/* ---------------------------------------------------------------------------

  ca_obj_timedelta.c

  CATimedelta — semantic mask (Face) over int64 storage; sibling of
  CATime.  A time duration represented as an int64 count in a
  chosen `unit`.

  Structurally identical to CATime (= only the semantic identifier
  differs); storage ops go via ca_face_* thin-forwards (ca_obj_face.h).
  The Ruby-side Comparable / to_s / <=> surface lives in
  lib/carray/time.rb.

--------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"

/* The unit enum is shared with CATime (= same unit system).
   No CA_TIMEDELTA_UNIT_* aliases; use the same values as CATime. */
extern int8_t ca_time_unit_value (VALUE sym);
extern VALUE  ca_time_unit_to_symbol (int8_t unit);
extern VALUE  ca_time_resolution (int64_t count, int8_t unit);
extern void   ca_time_extract_unit (VALUE unit, int8_t *base, int64_t *count);

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
} CATimedelta;

static size_t
ca_timedelta_dsize (const void *ap)
{
  const CATimedelta *ca = (const CATimedelta *) ap;
  return sizeof(CATimedelta) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool buffer. */
static size_t
ca_timedelta_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_timedelta_pool_init (void *ap, int8_t ndim)
{
  CATimedelta *ca = (CATimedelta *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t catimedelta_data_type = {
    .parent = &caface_data_type,
    .wrap_struct_name = "CATimedelta",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_timedelta_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_TIMEDELTA;
static VALUE rb_cCATimedelta;
static VALUE rb_cCATimedeltaElement;

/* CATimedelta::Element as a C TypedData struct (= same shape as
   CATimeElement).  Storing value + unit in the struct lets
   Scalar.new / value / unit skip Ruby method dispatch. */
typedef struct {
  int64_t value;
  int8_t  unit;
  int64_t count;
} CATimedeltaElement;

static size_t
ca_timedelta_element_dsize (const void *ap)
{
  (void) ap;
  return sizeof(CATimedeltaElement);
}

static void
ca_timedelta_element_free (void *ap)
{
  if (ap) xfree(ap);
}

const rb_data_type_t catimedelta_element_data_type = {
  .wrap_struct_name = "CATimedelta::Element",
  .function = {
    .dmark = NULL,
    .dfree = ca_timedelta_element_free,
    .dsize = ca_timedelta_element_dsize,
  },
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
rb_ca_timedelta_element_s_allocate (VALUE klass)
{
  CATimedeltaElement *s;
  return TypedData_Make_Struct(klass, CATimedeltaElement,
                               &catimedelta_element_data_type, s);
}

static VALUE
rb_ca_timedelta_element_initialize (VALUE self, VALUE value, VALUE unit)
{
  CATimedeltaElement *s;
  TypedData_Get_Struct(self, CATimedeltaElement,
                       &catimedelta_element_data_type, s);
  s->value = NUM2LL(value);
  ca_time_extract_unit(unit, &s->unit, &s->count);
  return self;
}

static VALUE
rb_ca_timedelta_element_value (VALUE self)
{
  CATimedeltaElement *s;
  TypedData_Get_Struct(self, CATimedeltaElement,
                       &catimedelta_element_data_type, s);
  return LL2NUM(s->value);
}

/* unit → CATime::Resolution(count, base) */
static VALUE
rb_ca_timedelta_element_unit (VALUE self)
{
  CATimedeltaElement *s;
  TypedData_Get_Struct(self, CATimedeltaElement,
                       &catimedelta_element_data_type, s);
  return ca_time_resolution(s->count, s->unit);
}

/* ------------------------------------------------------------------- */

int
ca_timedelta_setup (CATimedelta *ca, CArray *parent, int8_t unit, int64_t count)
{
  if ( parent->data_type != CA_INT64 ) {
    rb_raise(rb_eTypeError,
             "CATimedelta requires int64 storage (parent.data_type != CA_INT64)");
  }

  ca->obj_type  = CA_OBJ_TIMEDELTA;
  /* NonNumeric surface (the FIXLEN gate), like CATime: the storage is a
     count of `count x unit` ticks, and letting the numeric kernels read it
     means sqrt / exp / sin / variance of a duration, and an `abs` that drops
     the Face.  Arithmetic and reductions that *are* meaningful on a duration
     are Ruby overrides in lib/carray/time.rb, so they do not depend on the
     numeric dispatch.  Turning a duration into a number is #to_numeric. */
  ca->data_type = CA_FIXLEN;
  /* ORDERABLE: int64 storage order == timedelta <=> order, so sort family may
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

CATimedelta *
ca_timedelta_new (CArray *parent, int8_t unit, int64_t count)
{
  CATimedelta *ca = (CATimedelta *) ca_array_alloc(CA_OBJ_TIMEDELTA, parent->ndim);
  ca_timedelta_setup(ca, parent, unit, count);
  return ca;
}

static void
free_ca_timedelta (void *ap)
{
  CATimedelta *ca = (CATimedelta *) ap;
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
ca_timedelta_func_clone (void *ap)
{
  CATimedelta *ca = (CATimedelta *) ap;
  return ca_timedelta_new(ca->parent, ca->unit, ca->count);
}

static void
ca_timedelta_func_allocate (void *ap)
{
  CATimedelta *ca = (CATimedelta *) ap;
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr;
}

static void
ca_timedelta_func_create_mask (void *ap)
{
  CATimedelta *ca = (CATimedelta *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_refer_new(ca->parent->mask,
                                      CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_timedelta_func = {
  -1, /* CA_OBJ_TIMEDELTA — filled by ca_install_obj_type */
  CA_VIEW_ARRAY,
  free_ca_timedelta,
  ca_timedelta_func_clone,
  ca_timedelta_func_allocate,
  ca_face_attach,
  ca_face_sync,
  ca_face_detach,
  ca_face_fill_data,
  ca_timedelta_func_create_mask,
  ca_face_xfer_index,
  ca_face_xfer_addrs,
  NULL,                              /* fold_stride */
  ca_face_xfer_stride,
  ca_face_xfer_all
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_timedelta_wrap (VALUE parent_val, int8_t unit, int64_t count)
{
  volatile VALUE obj;
  CArray *parent;
  CATimedelta *ca;

  rb_check_carray_object(parent_val);
  TypedData_Get_Struct(parent_val, CArray, &carray_data_type, parent);

  ca  = ca_timedelta_new(parent, unit, count);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, parent_val);
  return obj;
}

/* __wrap__(raw, unit_spec) — primitive; unit_spec is Symbol / String /
   Resolution / nil (normalized here). */
static VALUE
rb_ca_timedelta_wrap_method (VALUE klass, VALUE raw, VALUE unit_spec)
{
  int8_t  base;
  int64_t count;
  (void) klass;
  ca_time_extract_unit(unit_spec, &base, &count);
  return rb_ca_timedelta_wrap(raw, base, count);
}

/* CATimedelta#unit → CATime::Resolution(count, base) */
static VALUE
rb_ca_timedelta_unit (VALUE self)
{
  CATimedelta *ca;
  TypedData_Get_Struct(self, CATimedelta, &catimedelta_data_type, ca);
  return ca_time_resolution(ca->count, ca->unit);
}

static VALUE
rb_ca_timedelta_s_allocate (VALUE klass)
{
  CATimedelta *ca;
  return TypedData_Make_Struct(klass, CATimedelta,
                                &catimedelta_data_type, ca);
}

static VALUE
rb_ca_timedelta_initialize_copy (VALUE self, VALUE other)
{
  CATimedelta *ca, *cs;
  TypedData_Get_Struct(self,  CATimedelta, &catimedelta_data_type, ca);
  TypedData_Get_Struct(other, CATimedelta, &catimedelta_data_type, cs);
  if ( ca_func[CA_OBJ_TIMEDELTA].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_TIMEDELTA, cs->parent->ndim);
  }
  ca_timedelta_setup(ca, cs->parent, cs->unit, cs->count);
  return self;
}

/* storage_to_scalar implemented in C to avoid per-cell Ruby method dispatch
   on the fetch hot path.  Accepts either an Integer (INT64 surface fetch)
   or an 8-byte String (FIXLEN surface fetch); decodes the parent int64
   and constructs CATimedelta::Element(value, unit). */
static VALUE
rb_ca_timedelta_storage_to_scalar (VALUE self, VALUE raw)
{
  CATimedelta *ca;
  CATimedeltaElement *s;
  VALUE scalar_obj;
  int64_t value;

  TypedData_Get_Struct(self, CATimedelta, &catimedelta_data_type, ca);

  if ( TYPE(raw) == T_STRING ) {
    if ( RSTRING_LEN(raw) != (long) sizeof(int64_t) ) {
      rb_raise(rb_eArgError,
               "CATimedelta#storage_to_scalar: expected %lu bytes, got %ld",
               (unsigned long) sizeof(int64_t), RSTRING_LEN(raw));
    }
    memcpy(&value, RSTRING_PTR(raw), sizeof(int64_t));
  }
  else {
    value = NUM2LL(raw);
  }

  /* Direct alloc + struct field write — no LL2NUM, no rb_class_new_instance,
     no Ruby initialize dispatch (= mirror CATime fast path). */
  scalar_obj = TypedData_Make_Struct(rb_cCATimedeltaElement,
                                     CATimedeltaElement,
                                     &catimedelta_element_data_type, s);
  s->value = value;
  s->unit  = ca->unit;
  s->count = ca->count;
  return scalar_obj;
}

/* Face state homogeneity check — two CATimedelta instances are
   compatible iff their resolution (base + count) matches. */
static int
ca_timedelta_state_compatible (CArray *a, CArray *b)
{
  CATimedelta *da = (CATimedelta *) a;
  CATimedelta *db = (CATimedelta *) b;
  return ( da->unit == db->unit && da->count == db->count ) ? 1 : 0;
}

void
Init_ca_obj_timedelta (void)
{
  rb_cCATimedelta = rb_define_class("CATimedelta", rb_cCAFace);

  ca_timedelta_func.struct_size = sizeof(CATimedelta);
  ca_timedelta_func.pool_bytes  = ca_timedelta_pool_bytes;
  ca_timedelta_func.pool_init   = ca_timedelta_pool_init;

  CA_OBJ_TIMEDELTA = ca_install_obj_type(rb_cCATimedelta,
                                          &catimedelta_data_type,
                                          rb_cCArrayMask,
                                          &carray_mask_data_type,
                                          &ca_timedelta_func, sizeof(ca_timedelta_func));
  rb_define_const(rb_cObject, "CA_OBJ_TIMEDELTA", INT2NUM(CA_OBJ_TIMEDELTA));

  rb_define_alloc_func(rb_cCATimedelta, rb_ca_timedelta_s_allocate);
  rb_define_method(rb_cCATimedelta, "initialize_copy",
                                    rb_ca_timedelta_initialize_copy, 1);

  rb_define_singleton_method(rb_cCATimedelta, "__wrap__",
                                    rb_ca_timedelta_wrap_method, 2);
  rb_define_method(rb_cCATimedelta, "unit", rb_ca_timedelta_unit, 0);
  rb_define_method(rb_cCATimedelta, "storage_to_scalar",
                                    rb_ca_timedelta_storage_to_scalar, 1);
  /* Registers the state-compatibility predicate so CA_FACE_STORAGE_TO_SCALAR_IF_FACE
     can skip rb_funcall on the hot path. */
  ca_face_register_state_compatible(CA_OBJ_TIMEDELTA,
                                    ca_timedelta_state_compatible);
  /* unit is pure metadata, no per-parent buffer; multi-parent Face lift
     is safe (portable = 1). */
  ca_face_register_state_portable(CA_OBJ_TIMEDELTA, 1);
  ca_face_register_storage_to_scalar(CA_OBJ_TIMEDELTA,
                                     rb_ca_timedelta_storage_to_scalar);

  /* CATimedelta::Element as a C-backed TypedData class.  The Ruby-side
     definition in lib/carray/time.rb keeps Comparable + to_seconds /
     to_s / inspect / <=> / == ; the C side owns the storage (int64 value
     + int8 unit) and the allocator + initialize + value + unit accessors. */
  rb_cCATimedeltaElement = rb_define_class_under(rb_cCATimedelta,
                                                "Element", rb_cObject);
  rb_define_alloc_func(rb_cCATimedeltaElement,
                       rb_ca_timedelta_element_s_allocate);
  rb_define_method(rb_cCATimedeltaElement, "initialize",
                   rb_ca_timedelta_element_initialize, 2);
  rb_define_method(rb_cCATimedeltaElement, "value",
                   rb_ca_timedelta_element_value, 0);
  rb_define_method(rb_cCATimedeltaElement, "unit",
                   rb_ca_timedelta_element_unit, 0);
}
