/* ---------------------------------------------------------------------------

  ca_obj_string.c

  CAString — a String-array Face over CA_OBJECT storage.  Storage already
  holds Ruby String VALUEs, so this Face performs no reinterpretation: it
  is an identity Face whose only job is to carry the CAString class across
  the view chain (via the ca_face_* lift substrate) and to organise the
  String-specific method surface onto a dedicated class, keeping str_*
  operations off numeric / plain-object CArrays.

  Surface data_type is CA_OBJECT (== storage): unlike the NonNumeric Faces
  (CATime etc.) there is no CA_FIXLEN gate.  Per-cell fetch returns
  the stored String VALUE directly (no storage_to_element decode).  Numeric
  dispatch lands on the :object kernels, so String-meaningful ops (+, sort
  via <=>) work and nonsensical ones raise at the Ruby method call.

  Storage ops thin-forward to the parent via ca_face_* (ca_obj_face.h).

--------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"
#include "ca_obj_face.h"

typedef struct {
  /* === CAView prefix === */
  int16_t    obj_type;
  int8_t     data_type;        /* CA_OBJECT (== storage, no gate) */
  int8_t     ndim;
  int32_t    flags;            /* CA_FLAG_IS_FACE set */
  ca_size_t  bytes;            /* sizeof(VALUE) */
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  char      *_pool;            /* framework-managed pool buffer */
  CArray    *parent;
  uint32_t   attach;
  uint8_t    nosync;
  /* === Face tail === (none: CAString carries no per-instance state) */
} CAString;

static size_t
ca_string_dsize (const void *ap)
{
  const CAString *ca = (const CAString *) ap;
  return sizeof(CAString) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: CAString owns a single ndim-sized tail (dim). */
static size_t
ca_string_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_string_pool_init (void *ap, int8_t ndim)
{
  CAString *ca = (CAString *) ap;
  (void) ndim;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t castring_data_type = {
    .parent = &caface_data_type,
    .wrap_struct_name = "CAString",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_string_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

int8_t CA_OBJ_STRING;     /* non-static: read by the store path in carray_access.c */
static VALUE rb_cCAString;

/* ------------------------------------------------------------------- */

int
ca_string_setup (CAString *ca, CArray *parent)
{
  if ( parent->data_type != CA_OBJECT ) {
    rb_raise(rb_eTypeError,
             "CAString requires object storage (parent.data_type != CA_OBJECT)");
  }

  /* ca == NULL asks for the checks above only, so that a constructor can
     run them before it allocates. */
  if ( ca == NULL ) {
    return 0;
  }

  ca->obj_type  = CA_OBJ_STRING;
  ca->data_type = CA_OBJECT;
  /* ORDERABLE + COMPARABLE, and both hold by construction: a storage cell
     IS the Ruby String the surface shows, so storage order is surface
     order and an external String compares against storage directly, with
     nothing to reconcile.  (A unit-bearing Face like CATime is the case
     that has to stop at ORDERABLE; this one carries no unit.) */
  ca->flags     = CA_FLAG_IS_FACE
                | CA_FLAG_FACE_ORDERABLE_STORAGE
                | CA_FLAG_FACE_COMPARABLE_STORAGE;
  ca->ndim      = parent->ndim;
  ca->bytes     = sizeof(VALUE);
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


  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  if ( ca_test_flag(parent, CA_FLAG_READ_ONLY) ) {
    ca_set_flag(ca, CA_FLAG_READ_ONLY);
  }

  return 0;
}

CAString *
ca_string_new (CArray *parent)
{
  CAString *ca;
  ca_string_setup(NULL, parent);
  ca = (CAString *) ca_array_alloc(CA_OBJ_STRING, parent->ndim);
  ca_string_setup(ca, parent);
  ca_fill_or_free((CArray *) ca, ca_view_inherit_mask, (VALUE) ca);
  return ca;
}

static void
free_ca_string (void *ap)
{
  CAString *ca = (CAString *) ap;
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
ca_string_func_clone (void *ap)
{
  CAString *ca = (CAString *) ap;
  return ca_string_new(ca->parent);
}

static void
ca_string_func_allocate (void *ap)
{
  CAString *ca = (CAString *) ap;
  /* alias: parent attach + alias parent->ptr (Face has identical data) */
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr;
}

ca_operation_function_t ca_string_func = {
  -1, /* CA_OBJ_STRING — filled by ca_install_obj_type */
  CA_VIEW_ARRAY,
  free_ca_string,
  ca_string_func_clone,
  ca_string_func_allocate,
  ca_face_attach,
  ca_face_sync,
  ca_face_detach,
  ca_face_fill_data,
  ca_view_func_create_mask,
  ca_face_xfer_index,
  ca_face_xfer_addrs,
  NULL,                              /* fold_stride: identity Face is not foldable */
  ca_face_xfer_stride,
  ca_face_xfer_all,
  .fill_addrs  = ca_face_fill_addrs,
  .fill_stride = ca_face_fill_stride,
};

/* ------------------------------------------------------------------- */

/* A CAString cell is a String; UNDEF (a masked cell) is no value.  Refuse
   anything else, naming what it is, so a cell of a CAString always answers
   the String operations. */
NORETURN(static void ca_string_refuse_cell (VALUE v, const char *where));

static void
ca_string_refuse_cell (VALUE v, const char *where)
{
  if ( NIL_P(v) ) {
    rb_raise(rb_eTypeError,
             "%s is nil, not a String (a CAString holds Strings; "
             "UNDEF masks a cell)", where);
  }
  rb_raise(rb_eTypeError,
           "%s is of class %s, not a String (a CAString holds Strings; "
           "UNDEF masks a cell)", where, rb_obj_classname(v));
}

/* Every cell of `parent` that is not masked is a String.  Under a masked
   cell of an entity that can be written, a value that is not a String (the
   0 an object array starts with) becomes an empty String, so that the cell
   is still a String once it is unmasked. */
static void
ca_string_check_cells (VALUE parent_val, CArray *parent)
{
  ca_size_t i;
  char where[64];
  if ( ca_is_entity(parent) && parent->ptr ) {
    VALUE *p = (VALUE *) parent->ptr;
    boolean8_t *m = ( parent->mask && parent->mask->ptr )
                    ? (boolean8_t *) parent->mask->ptr : NULL;
    int writable = ! ca_is_readonly(parent);
    for (i = 0; i < parent->elements; i++) {
      if ( m && m[i] ) {
        if ( writable && ! RB_TYPE_P(p[i], T_STRING) ) {
          p[i] = rb_utf8_str_new("", 0);
        }
        continue;
      }
      if ( ! RB_TYPE_P(p[i], T_STRING) ) {
        snprintf(where, sizeof(where), "cell %" PRId64, (int64_t) i);
        ca_string_refuse_cell(p[i], where);
      }
    }
  }
  else {
    volatile VALUE list =
      rb_funcall(rb_funcall(parent_val, rb_intern("flatten"), 0),
                 rb_intern("to_a"), 0);
    long n = RARRAY_LEN(list), j;
    for (j = 0; j < n; j++) {
      VALUE v = rb_ary_entry(list, j);
      if ( v == CA_UNDEF ) continue;
      if ( ! RB_TYPE_P(v, T_STRING) ) {
        snprintf(where, sizeof(where), "cell %ld", j);
        ca_string_refuse_cell(v, where);
      }
    }
  }
}

/* The write hook: a value stored into a CAString is a String. */
static VALUE
ca_string_element_to_storage (VALUE self, VALUE v)
{
  (void) self;
  if ( ! RB_TYPE_P(v, T_STRING) ) {
    ca_string_refuse_cell(v, "a value stored into a CAString");
  }
  return v;
}

/* CAString.wrap(object_array) — zero-copy Face wrap of a CA_OBJECT array */
VALUE
rb_ca_string_wrap (VALUE parent_val)
{
  volatile VALUE obj;
  CArray *parent;
  CAString *ca;

  rb_check_carray_object(parent_val);
  TypedData_Get_Struct(parent_val, CArray, &carray_data_type, parent);

  ca_string_setup(NULL, parent);
  ca_string_check_cells(parent_val, parent);
  ca  = ca_string_new(parent);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, parent_val);
  return obj;
}

static VALUE
rb_ca_string_wrap_method (VALUE klass, VALUE raw)
{
  (void) klass;
  return rb_ca_string_wrap(raw);
}

static VALUE
rb_ca_string_s_allocate (VALUE klass)
{
  CAString *ca;
  return TypedData_Make_Struct(klass, CAString, &castring_data_type, ca);
}

static VALUE
rb_ca_string_initialize_copy (VALUE self, VALUE other)
{
  CAString *ca, *cs;
  TypedData_Get_Struct(self,  CAString, &castring_data_type, ca);
  ca_check_uninitialized(ca);
  TypedData_Get_Struct(other, CAString, &castring_data_type, cs);
  if ( ca_func[CA_OBJ_STRING].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_STRING, cs->parent->ndim);
  }
  ca_string_setup(ca, cs->parent);
  ca_view_inherit_mask((VALUE) ca);
  return self;
}

void
Init_ca_obj_string (void)
{
  rb_cCAString = rb_define_class("CAString", rb_cCAFace);

  ca_string_func.struct_size = sizeof(CAString);
  ca_string_func.pool_bytes  = ca_string_pool_bytes;
  ca_string_func.pool_init   = ca_string_pool_init;

  CA_OBJ_STRING = ca_install_obj_type(rb_cCAString,
                                      &castring_data_type,
                                      rb_cCArrayMask,
                                      &carray_mask_data_type,
                                      &ca_string_func, sizeof(ca_string_func));
  rb_define_const(rb_cObject, "CA_OBJ_STRING", INT2NUM(CA_OBJ_STRING));

  rb_define_alloc_func(rb_cCAString, rb_ca_string_s_allocate);
  rb_define_method(rb_cCAString, "initialize_copy",
                                 rb_ca_string_initialize_copy, 1);
  rb_define_singleton_method(rb_cCAString, "wrap", rb_ca_string_wrap_method, 1);

  ca_face_register_element_to_storage(CA_OBJ_STRING,
                                      ca_string_element_to_storage);

  /* A cell is the String itself, so the Face is the same over any parent:
     CAStack / CAMeld / concatenate can carry it (unlike CAConstString, whose
     cells point into one parent's buffer). */
  ca_face_register_state_portable(CA_OBJ_STRING, 1);
}
