/* ---------------------------------------------------------------------------

  ca_obj_fixlen_string.c

  CAFixlenString — a String-array Face over CA_FIXLEN storage.

  At the Face layer this is a plain fixlen -> fixlen identity Face: the
  surface data_type equals the storage data_type (CA_FIXLEN), and no
  reinterpretation happens.  It is NOT a CARecord (which interprets the
  fixlen bytes as a struct via the data_class encode/decode hooks); here
  the bytes are the string, fetched and stored by the native fixlen path.

  The Face's only job is to carry the CAFixlenString class across the view
  chain and to organise the String method surface onto a dedicated class.
  Because the storage is CA_FIXLEN (portable), the Face wrap can be carried
  across multi-parent constructions (CAStack / Marshal / MemoryView).

  Storage ops thin-forward to the parent via ca_face_* (ca_obj_face.h).
  This is the sibling of CAString (identity Face over CA_OBJECT storage).

--------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"

typedef struct {
  /* === CAView prefix === */
  int16_t    obj_type;
  int8_t     data_type;        /* CA_FIXLEN (== storage) */
  int8_t     ndim;
  int32_t    flags;            /* CA_FLAG_IS_FACE set */
  ca_size_t  bytes;            /* K = parent->bytes */
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  char      *_pool;            /* framework-managed pool buffer */
  CArray    *parent;
  uint32_t   attach;
  uint8_t    nosync;
  /* === Face tail === (none: CAFixlenString carries no per-instance state) */
} CAFixlenString;

static size_t
ca_fixlen_string_dsize (const void *ap)
{
  const CAFixlenString *ca = (const CAFixlenString *) ap;
  return sizeof(CAFixlenString) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: CAFixlenString owns a single ndim-sized tail (dim). */
static size_t
ca_fixlen_string_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_fixlen_string_pool_init (void *ap, int8_t ndim)
{
  CAFixlenString *ca = (CAFixlenString *) ap;
  (void) ndim;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t cafixlen_string_data_type = {
    .parent = &caface_data_type,
    .wrap_struct_name = "CAFixlenString",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_fixlen_string_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_FIXLEN_STRING;
static VALUE rb_cCAFixlenString;

/* ------------------------------------------------------------------- */

int
ca_fixlen_string_setup (CAFixlenString *ca, CArray *parent)
{
  if ( parent->data_type != CA_FIXLEN ) {
    rb_raise(rb_eTypeError,
             "CAFixlenString requires fixlen storage (parent.data_type != CA_FIXLEN)");
  }

  ca->obj_type  = CA_OBJ_FIXLEN_STRING;
  ca->data_type = CA_FIXLEN;
  /* ORDERABLE + COMPARABLE, and both hold by construction: this Face's surface
     IS its storage, byte for byte (a cell decodes to its own bytes, padding
     included), so the descent is the identity map.  memcmp order is therefore
     String#<=> order for these cells, and byte equality is cell equality --
     which is what the equality families need (docs/topics/CAFace.md §6.3).
     Without the flags the sort family still worked (it exempts CA_FIXLEN
     storage from the gate and orders by memcmp), but the value-hash family
     handed its results back as a plain fixlen array, and search refused a
     String query outright. */
  ca->flags     = CA_FLAG_IS_FACE
                | CA_FLAG_FACE_ORDERABLE_STORAGE
                | CA_FLAG_FACE_COMPARABLE_STORAGE;
  ca->ndim      = parent->ndim;
  ca->bytes     = parent->bytes;
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

CAFixlenString *
ca_fixlen_string_new (CArray *parent)
{
  CAFixlenString *ca =
      (CAFixlenString *) ca_array_alloc(CA_OBJ_FIXLEN_STRING, parent->ndim);
  ca_fixlen_string_setup(ca, parent);
  return ca;
}

static void
free_ca_fixlen_string (void *ap)
{
  CAFixlenString *ca = (CAFixlenString *) ap;
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
ca_fixlen_string_func_clone (void *ap)
{
  CAFixlenString *ca = (CAFixlenString *) ap;
  return ca_fixlen_string_new(ca->parent);
}

static void
ca_fixlen_string_func_allocate (void *ap)
{
  CAFixlenString *ca = (CAFixlenString *) ap;
  /* alias: parent attach + alias parent->ptr (Face has identical data) */
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr;
}

static void
ca_fixlen_string_func_create_mask (void *ap)
{
  CAFixlenString *ca = (CAFixlenString *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_refer_new(ca->parent->mask,
                                      CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_fixlen_string_func = {
  -1, /* CA_OBJ_FIXLEN_STRING — filled by ca_install_obj_type */
  CA_VIEW_ARRAY,
  free_ca_fixlen_string,
  ca_fixlen_string_func_clone,
  ca_fixlen_string_func_allocate,
  ca_face_attach,
  ca_face_sync,
  ca_face_detach,
  ca_face_fill_data,
  ca_fixlen_string_func_create_mask,
  ca_face_xfer_index,
  ca_face_xfer_addrs,
  NULL,                              /* fold_stride: identity Face is not foldable */
  ca_face_xfer_stride,
  ca_face_xfer_all,
  .fill_addrs  = ca_face_fill_addrs,
  .fill_stride = ca_face_fill_stride,
};

/* ------------------------------------------------------------------- */

/* CAFixlenString.wrap(fixlen_array) — zero-copy Face wrap */
VALUE
rb_ca_fixlen_string_wrap (VALUE parent_val)
{
  volatile VALUE obj;
  CArray *parent;
  CAFixlenString *ca;

  rb_check_carray_object(parent_val);
  TypedData_Get_Struct(parent_val, CArray, &carray_data_type, parent);

  ca  = ca_fixlen_string_new(parent);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, parent_val);
  return obj;
}

static VALUE
rb_ca_fixlen_string_wrap_method (VALUE klass, VALUE raw)
{
  (void) klass;
  return rb_ca_fixlen_string_wrap(raw);
}

/* Per-cell scalar decode: strip trailing NUL padding from the raw K-byte
   fetch.  A fixed-width slot pads short strings with NUL, which is padding,
   not content (the same convention NumPy's 'S'/'U' dtypes use on readback).
   Storage is unchanged -- only the surface scalar is stripped -- so sort /
   search / MemoryView still see the raw padded bytes.  Genuine trailing NULs
   cannot survive here; use a raw CA_FIXLEN array for binary blobs. */
static VALUE
rb_ca_fixlen_string_storage_to_scalar (VALUE self, VALUE raw)
{
  (void) self;
  if ( TYPE(raw) == T_STRING ) {
    const char *p = RSTRING_PTR(raw);
    long n = RSTRING_LEN(raw);
    while ( n > 0 && p[n - 1] == '\0' ) {
      n--;
    }
    return rb_str_new(p, n);
  }
  return raw;
}

static VALUE
rb_ca_fixlen_string_s_allocate (VALUE klass)
{
  CAFixlenString *ca;
  return TypedData_Make_Struct(klass, CAFixlenString,
                               &cafixlen_string_data_type, ca);
}

static VALUE
rb_ca_fixlen_string_initialize_copy (VALUE self, VALUE other)
{
  CAFixlenString *ca, *cs;
  TypedData_Get_Struct(self,  CAFixlenString, &cafixlen_string_data_type, ca);
  TypedData_Get_Struct(other, CAFixlenString, &cafixlen_string_data_type, cs);
  if ( ca_func[CA_OBJ_FIXLEN_STRING].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_FIXLEN_STRING, cs->parent->ndim);
  }
  ca_fixlen_string_setup(ca, cs->parent);
  return self;
}

void
Init_ca_obj_fixlen_string (void)
{
  rb_cCAFixlenString = rb_define_class("CAFixlenString", rb_cCAFace);

  ca_fixlen_string_func.struct_size = sizeof(CAFixlenString);
  ca_fixlen_string_func.pool_bytes  = ca_fixlen_string_pool_bytes;
  ca_fixlen_string_func.pool_init   = ca_fixlen_string_pool_init;

  CA_OBJ_FIXLEN_STRING = ca_install_obj_type(rb_cCAFixlenString,
                                             &cafixlen_string_data_type,
                                             rb_cCArrayMask,
                                             &carray_mask_data_type,
                                             &ca_fixlen_string_func, sizeof(ca_fixlen_string_func));
  rb_define_const(rb_cObject, "CA_OBJ_FIXLEN_STRING", INT2NUM(CA_OBJ_FIXLEN_STRING));

  rb_define_alloc_func(rb_cCAFixlenString, rb_ca_fixlen_string_s_allocate);
  rb_define_method(rb_cCAFixlenString, "initialize_copy",
                                       rb_ca_fixlen_string_initialize_copy, 1);
  rb_define_singleton_method(rb_cCAFixlenString, "wrap",
                                       rb_ca_fixlen_string_wrap_method, 1);
  rb_define_method(rb_cCAFixlenString, "storage_to_scalar",
                                       rb_ca_fixlen_string_storage_to_scalar, 1);
  ca_face_register_storage_to_scalar(CA_OBJ_FIXLEN_STRING,
                                     rb_ca_fixlen_string_storage_to_scalar);

  /* CA_FIXLEN is portable storage (fixed-width bytes, no per-process VALUE
     or per-parent buffer), so the Face can be carried across multi-parent
     constructions like CAStack / Marshal / MemoryView. */
  ca_face_register_state_portable(CA_OBJ_FIXLEN_STRING, 1);
}
