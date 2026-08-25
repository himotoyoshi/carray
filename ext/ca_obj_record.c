/* ---------------------------------------------------------------------------

  CARecord — composite Face for CAStruct-backed arrays.  Face wrap for
  arrays whose element type is a CAStruct subclass; data_class is
  attached only to CARecord (not to bare CArray).

  Storage layout matches the CAStruct backing (CA_FIXLEN bytes blob,
  unchanged).  Storage ops thin-forward to the parent via `ca_face_*`;
  the tail holds `VALUE data_class`, pinned by a custom dmark.

  Also housed here: data_class identity predicates
  (`rb_obj_is_data_class` / `ca_check_data_class` /
  `CArray.data_class?`) since data_class is a CARecord concern.

  Sibling pattern references (VALUE tail + custom dmark):
    ca_obj_time.c    numeric Face
    ca_obj_byte_swap.c     endian Face

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"

typedef struct {
  /* === CAView prefix === */
  int16_t    obj_type;
  int8_t     data_type;        /* fixed to CA_FIXLEN */
  int8_t     ndim;
  int32_t    flags;            /* CA_FLAG_IS_FACE set */
  ca_size_t  bytes;            /* = data_class::DATA_SIZE */
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray    *parent;
  uint32_t   attach;
  uint8_t    nosync;
  /* === Face tail === */
  VALUE      data_class;       /* CAStruct subclass (marked by custom dmark) */
} CARecord;

static size_t
ca_record_dsize (const void *ap)
{
  const CARecord *ca = (const CARecord *) ap;
  return sizeof(CARecord) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer, uniform with the rest of the pool-migrated views. */
static size_t
ca_record_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_record_pool_init (void *ap, int8_t ndim)
{
  CARecord *ca = (CARecord *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

/* Custom dmark: ca_mark handles the standard prefix; the data_class
   tail VALUE must be marked explicitly (CAFace itself carries none). */
static void
ca_record_mark (void *ap)
{
  CARecord *ca = (CARecord *) ap;
  ca_mark(ca);
  rb_gc_mark(ca->data_class);
}

const rb_data_type_t carecord_data_type = {
    .parent = &caface_data_type,
    .wrap_struct_name = "CARecord",
    .function = {
        .dmark = ca_record_mark,
        .dfree = ca_free,
        .dsize = ca_record_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

int8_t CA_OBJ_RECORD;     /* non-static: read by rb_ca_data_class in carray_attribute.c */
VALUE  rb_cCARecord;      /* non-static: exported for cross-file use */

/* ------------------------------------------------------------------- */

int
ca_record_setup (CARecord *ca, CArray *parent, VALUE data_class)
{
  if ( parent->data_type != CA_FIXLEN ) {
    rb_raise(rb_eTypeError,
             "CARecord requires a CA_FIXLEN parent (got data_type=%d)",
             parent->data_type);
  }

  ca->obj_type   = CA_OBJ_RECORD;
  ca->data_type  = CA_FIXLEN;
  ca->flags      = CA_FLAG_IS_FACE;
  ca->ndim       = parent->ndim;
  ca->bytes      = parent->bytes;
  ca->elements   = parent->elements;
  ca->ptr        = NULL;
  ca->mask       = NULL;
  if ( ! ca->_pool ) {
    ca->dim      = ALLOC_N(ca_size_t, parent->ndim);
  }
  memcpy(ca->dim, parent->dim, sizeof(ca_size_t) * parent->ndim);

  ca->parent     = parent;
  ca->attach     = 0;
  ca->nosync     = 0;

  ca->data_class = data_class;

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

CARecord *
ca_record_new (CArray *parent, VALUE data_class)
{
  CARecord *ca = (CARecord *) ca_array_alloc(CA_OBJ_RECORD, parent->ndim);
  ca_record_setup(ca, parent, data_class);
  return ca;
}

static void
free_ca_record (void *ap)
{
  CARecord *ca = (CARecord *) ap;
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
ca_record_func_clone (void *ap)
{
  CARecord *ca = (CARecord *) ap;
  return ca_record_new(ca->parent, ca->data_class);
}

static void
ca_record_func_allocate (void *ap)
{
  CARecord *ca = (CARecord *) ap;
  /* alias: parent attach + alias parent->ptr (Face has identical data layout) */
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr;
}

static void
ca_record_func_create_mask (void *ap)
{
  CARecord *ca = (CARecord *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_refer_new(ca->parent->mask,
                                      CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_record_func = {
  -1, /* CA_OBJ_RECORD — filled by ca_install_obj_type */
  CA_VIEW_ARRAY,
  free_ca_record,
  ca_record_func_clone,
  ca_record_func_allocate,
  ca_face_attach,
  ca_face_sync,
  ca_face_detach,
  ca_face_fill_data,
  ca_record_func_create_mask,
  ca_face_xfer_index,
  ca_face_xfer_addrs,
  NULL,                              /* fold_stride: identity Face is not foldable */
  ca_face_xfer_stride,
  ca_face_xfer_all
};

/* ------------------------------------------------------------------- */

/* Internal C builder — shared by .new (self-allocated parent) and
   .wrap (user-supplied parent) paths.  Pins parent_val via
   rb_ca_set_parent for GC + lifecycle protection, and preallocates
   the `member` ivar Hash used by rb_ca_face_field as a field-view
   memoisation cache. */
static VALUE
ca_record_build (VALUE klass, VALUE data_class, VALUE parent_val)
{
  CArray   *parent_ca;
  CARecord *ca;
  VALUE     obj;

  if ( ! RTEST(rb_obj_is_data_class(data_class)) ) {
    rb_raise(rb_eTypeError, "data_class must be a CAStruct subclass");
  }
  TypedData_Get_Struct(parent_val, CArray, &carray_data_type, parent_ca);
  if ( parent_ca->data_type != CA_FIXLEN ) {
    rb_raise(rb_eTypeError,
             "CARecord requires a CA_FIXLEN parent (got data_type=%d)",
             parent_ca->data_type);
  }
  ca  = ca_record_new(parent_ca, data_class);
  obj = TypedData_Wrap_Struct(klass, &carecord_data_type, ca);
  rb_ca_set_parent(obj, parent_val);
  rb_ivar_set(obj, rb_intern("member"), rb_hash_new());
  return obj;
}

/* CARecord.new(data_class, *shape) or Sub.new(*shape) — atomic path:
   allocate a fresh CA_FIXLEN entity and wrap it.  Base class takes
   `data_class` explicitly; a subclass that pinned its type via the
   `data_class GeoCoord` DSL accepts only shape args. */
static VALUE
rb_ca_record_s_new (int argc, VALUE *argv, VALUE klass)
{
  VALUE data_class, klass_dc, parent_val;
  ca_size_t bytes;
  ca_size_t dim[CA_RANK_MAX];
  int ndim, shape_offset, i;

  klass_dc = rb_iv_get(klass, "@data_class");
  if ( ! NIL_P(klass_dc) ) {
    /* subclass with DSL fix: shape args only */
    data_class   = klass_dc;
    shape_offset = 0;
    if ( argc > 0 && RTEST(rb_obj_is_data_class(argv[0])) ) {
      rb_raise(rb_eArgError,
               "subclass has fixed data_class via DSL; don't pass it again");
    }
  }
  else {
    /* base direct: first arg = data_class */
    if ( argc < 1 ) {
      rb_raise(rb_eArgError, "data_class required as first argument");
    }
    data_class   = argv[0];
    shape_offset = 1;
  }
  ndim = argc - shape_offset;
  if ( ndim < 0 || ndim > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "invalid number of shape arguments (%d)", ndim);
  }
  for ( i = 0; i < ndim; i++ ) {
    dim[i] = NUM2SIZE(argv[shape_offset + i]);
  }

  if ( ! RTEST(rb_obj_is_data_class(data_class)) ) {
    rb_raise(rb_eTypeError, "data_class must be a CAStruct subclass");
  }
  bytes = NUM2SIZE(rb_const_get(data_class, rb_intern("DATA_SIZE")));

  parent_val = rb_carray_new(CA_FIXLEN, ndim, dim, bytes, NULL);
  return ca_record_build(klass, data_class, parent_val);
}

/* CARecord.wrap(entity, data_class) or Sub.wrap(entity) — zero-copy
   Face wrap of an existing CA_FIXLEN entity.  Sibling of
   CATime.wrap. */
static VALUE
rb_ca_record_s_wrap (int argc, VALUE *argv, VALUE klass)
{
  VALUE entity_val, data_class, klass_dc;

  klass_dc = rb_iv_get(klass, "@data_class");
  if ( ! NIL_P(klass_dc) ) {
    rb_scan_args(argc, argv, "1", &entity_val);
    data_class = klass_dc;
  }
  else {
    rb_scan_args(argc, argv, "2", &entity_val, &data_class);
  }
  rb_check_carray_object(entity_val);
  return ca_record_build(klass, data_class, entity_val);
}

/* Direct C accessor for the CARecord tail data_class.  Called by
   rb_ca_data_class in carray_attribute.c, dispatched on obj_type so
   there is no Ruby roundtrip. */
VALUE
rb_ca_record_get_data_class (CArray *ca)
{
  return ((CARecord *) ca)->data_class;
}

/* Subclass DSL: `data_class Foo` inside `class Sub < CARecord`.
   Set once and then immutable (reassignment raises).  A zero-arg call
   acts as a getter.  The class ivar is what `.new` / `.wrap` read via
   `rb_iv_get(klass, "@data_class")` to omit the explicit arg. */
static VALUE
rb_ca_record_s_data_class_dsl (int argc, VALUE *argv, VALUE klass)
{
  VALUE current, given;

  current = rb_iv_get(klass, "@data_class");
  if ( argc == 0 ) {
    return NIL_P(current) ? Qnil : current;
  }
  rb_scan_args(argc, argv, "1", &given);
  if ( ! NIL_P(current) ) {
    rb_raise(rb_eRuntimeError,
             "data_class already fixed to %"PRIsVALUE
             "; CARecord subclass data_class is immutable once set",
             current);
  }
  if ( ! RTEST(rb_obj_is_data_class(given)) ) {
    rb_raise(rb_eTypeError, "data_class must be a CAStruct subclass");
  }
  rb_iv_set(klass, "@data_class", given);
  return given;
}

static VALUE
rb_ca_record_s_allocate (VALUE klass)
{
  CARecord *ca;
  return TypedData_Make_Struct(klass, CARecord, &carecord_data_type, ca);
}

static VALUE
rb_ca_record_initialize_copy (VALUE self, VALUE other)
{
  CARecord *ca, *cs;
  TypedData_Get_Struct(self,  CARecord, &carecord_data_type, ca);
  TypedData_Get_Struct(other, CARecord, &carecord_data_type, cs);
  if ( ca_func[CA_OBJ_RECORD].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_RECORD, cs->parent->ndim);
  }
  ca_record_setup(ca, cs->parent, cs->data_class);
  return self;
}

/* ---------------------------------------------------------------------------
   data_class identity predicates.  A Ruby class that can serve as the
   element type of a CARecord (i.e. the inner struct definition such as
   GeoCoord / Pixel, not the CARecord subclass CAGeoCoord) must provide
   the constants + methods checked below.  `CArray.struct {...}` /
   `CArray.union {...}` generate them automatically.

     rb_obj_is_data_class(klass)   duck-type predicate, Qtrue/Qfalse
     ca_check_data_class(klass)    same, raises on failure
     CArray.data_class?(klass)     Ruby surface for the predicate

   Signatures stay in carray.h for cross-file extern use.
   ------------------------------------------------------------------------- */

VALUE
rb_obj_is_data_class (VALUE rtype)
{
  VALUE has_data_size, has_member_names, has_member_table;
  VALUE has_encode, has_decode;
  if ( TYPE(rtype) == T_CLASS ) {
    has_data_size    =
      rb_funcall(rtype, rb_intern("const_defined?"), 1, rb_str_new2("DATA_SIZE"));
    has_member_names =
      rb_funcall(rtype, rb_intern("const_defined?"), 1, rb_str_new2("MEMBERS"));
    has_member_table =
      rb_funcall(rtype, rb_intern("const_defined?"), 1, rb_str_new2("MEMBER_TABLE"));
    has_encode       =
      rb_funcall(rtype, rb_intern("method_defined?"), 1, rb_str_new2("encode"));
    has_decode       = rb_respond_to(rtype, rb_intern("decode"));
    return ( RTEST(has_data_size)    &&
             RTEST(has_member_table) && RTEST(has_member_names) &&
             RTEST(has_encode)       && RTEST(has_decode)        ) ? Qtrue : Qfalse;
  }
  return Qfalse;
}

void
ca_check_data_class (VALUE rtype)
{
  if ( ! rb_obj_is_data_class(rtype) ) {
    VALUE inspect = rb_inspect(rtype);
    rb_raise(rb_eRuntimeError,
             "<%s> is not a data_class, which should has the features\n" \
             " * constant data_class::DATA_SIZE    -> integer\n" \
             " * constant data_class::MEMBERS      -> array of string\n" \
             " * constant data_class::MEMBER_TABLE -> hash\n" \
             " * method   data_class.decode(str)   -> data_class object\n" \
             " * method   data_class#encode()      -> string", StringValuePtr(inspect));
  }
}

static VALUE
rb_ca_s_is_data_class (VALUE self, VALUE rklass)
{
  return rb_obj_is_data_class(rklass);
}

/* Face-state homogeneity callback for promote_list / CAStack.  Two
   CARecord instances are compatible iff their data_class is identical;
   without this, multi-parent constructions would silently mix records
   with different DATA_SIZE or field schema. */
static int
ca_record_state_compatible (CArray *a, CArray *b)
{
  CARecord *ra = (CARecord *) a;
  CARecord *rb = (CARecord *) b;
  return (ra->data_class == rb->data_class) ? 1 : 0;
}

/* ------------------------------------------------------------------------- */

void
Init_ca_obj_record (void)
{
  rb_cCARecord = rb_define_class("CARecord", rb_cCAFace);

  ca_record_func.struct_size = sizeof(CARecord);
  ca_record_func.pool_bytes  = ca_record_pool_bytes;
  ca_record_func.pool_init   = ca_record_pool_init;

  CA_OBJ_RECORD = ca_install_obj_type(rb_cCARecord,
                                       &carecord_data_type,
                                       rb_cCArrayMask,
                                       &carray_mask_data_type,
                                       &ca_record_func, sizeof(ca_record_func));
  rb_define_const(rb_cObject, "CA_OBJ_RECORD", INT2NUM(CA_OBJ_RECORD));

  /* Homogeneity gate for promote_list / CAStack.  The Ruby class is
     always CARecord, so the default class-equality check cannot tell
     GeoCoord apart from Pixel; the callback compares data_class per
     instance. */
  ca_face_register_state_compatible(CA_OBJ_RECORD,
                                    ca_record_state_compatible);

  rb_define_alloc_func(rb_cCARecord, rb_ca_record_s_allocate);
  rb_define_method(rb_cCARecord, "initialize_copy",
                                  rb_ca_record_initialize_copy, 1);

  rb_define_singleton_method(rb_cCARecord, "new",  rb_ca_record_s_new,  -1);
  rb_define_singleton_method(rb_cCARecord, "wrap", rb_ca_record_s_wrap, -1);
  rb_define_singleton_method(rb_cCARecord, "data_class",
                              rb_ca_record_s_data_class_dsl, -1);

  /* #data_class is inherited from CArray via the universal Face
     dispatch (rb_ca_data_class reads the tail through obj_type). */

  rb_define_singleton_method(rb_cCArray, "data_class?", rb_ca_s_is_data_class, 1);
}
