/* ---------------------------------------------------------------------------

  source_smoke.c

  Test fixture for CASource (devel/PROPOSAL_CASOURCE.md).

  Defines `CASmokeSource < CASource`: an external-bridge source over a
  buffer owned by a foreign object (here a Ruby String standing in for an
  image pixel cache or a cv::Mat).  It is registered from outside the core
  exactly the way a companion gem registers one — ca_install_obj_type()
  plus a complete operation table written here, with nothing inherited
  from CASource itself.

  Shape of the fixture:

    - entity_type = CA_REAL_ARRAY (the buffer is already addressable)
    - the plain CArray prefix, no parent field
    - every slot written locally; no delegation to ca_array_func
    - **cold at rest**: `ptr` is NULL unless somebody is holding the
      array attached, and every data slot re-resolves the address from
      the owner on entry

  Cold at rest is what makes the fixture safe against a backend that
  re-shapes the buffer underneath (an image being resized, a cache being
  re-allocated).  `ca->ptr` is the *bypass* in the core's dispatchers:
  while it is non-NULL, `ca_xfer_stride_dispatch` / `ca_xfer_addrs_dispatch`
  move bytes straight through it and this file's slots — with their
  re-resolution check — are never reached.  Leaving `ptr` published at
  rest therefore turns the guard off for element access and region
  transfer, silently.

  The counting is what keeps that workable:

    - `attach` and `allocate` publish `ptr` and take a hold; `detach`
      releases one and clears `ptr` when the last one goes.  Entities
      have no attach reference count of their own (only CAView does), so
      without this an inner attach/detach pair would clear `ptr` under an
      outer holder and its sync would fail.
    - `allocate` must publish: the core writes through `ca->ptr` after
      `ca_allocate` (`seq!` does), and it must count as a hold, because
      the `detach` that follows it arrives without a matching `attach`.
    - a data slot resolves into a **local** variable and never assigns
      `ca->ptr`; assigning it there leaks a published pointer into the
      next operation, which then bypasses the guard and quietly returns
      a correct-looking answer.

  Usage:
    src = CASmokeSource.new(str, [rows, cols])   # uint8 over str's bytes
    src[0, 1] = 7                                # writes through to str
    src.resolve_count                            # did the guard run?
    src.revoke!                                  # simulate a re-shape

---------------------------------------------------------------------------- */

#include "carray.h"

extern VALUE rb_cCASource;
extern const rb_data_type_t casource_data_type;

static int8_t CA_OBJ_SMOKE_SOURCE;

static VALUE rb_cCASmokeSource;
static VALUE rb_cCASmokeSourceMask;

typedef struct {
  /* CArray prefix — field-for-field identical to struct _CArray */
  int16_t    obj_type;
  int8_t     data_type;
  int8_t     ndim;
  int32_t    flags;
  ca_size_t  bytes;
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  char      *_pool;
  /* tail */
  VALUE      owner;         /* foreign object holding the buffer */
  ca_size_t  owner_bytes;   /* byte length seen at construction */
  long       holds;         /* outstanding attach / allocate holds */
  long       n_resolve;
  long       n_attach;
  long       n_sync;
  long       n_detach;
} CASmokeSource;

/* --- foreign-buffer resolution -------------------------------------- */

/* Re-derive the buffer address from the owner and check that the owner
   still describes the same region.  A real bridge checks whatever its
   backend can change under it (an image's dimensions, its channel
   count); here the owner's byte length plays that role. */
static char *
smoke_resolve (CASmokeSource *ca)
{
  if ( TYPE(ca->owner) != T_STRING ) {
    rb_raise(rb_eRuntimeError, "CASmokeSource: owner is gone");
  }
  if ( (ca_size_t) RSTRING_LEN(ca->owner) != ca->owner_bytes ) {
    rb_raise(rb_eRuntimeError,
             "CASmokeSource: owner buffer was revoked "
             "(%ld bytes now, %ld at creation)",
             (long) RSTRING_LEN(ca->owner), (long) ca->owner_bytes);
  }
  ca->n_resolve++;
  return RSTRING_PTR(ca->owner);
}

/* --- operation table ------------------------------------------------ */

static void
smoke_func_free_object (void *ap)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  if ( ca != NULL ) {
    /* ptr belongs to the owner; only the CArray bookkeeping is ours. */
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
smoke_func_clone (void *ap)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  CArray *co = carray_new(ca->data_type, ca->ndim, ca->dim, ca->bytes,
                          ca->mask);
  memcpy(co->ptr, smoke_resolve(ca), ca_length((CArray *) ca));
  return co;
}

/* Take a hold and publish ptr for its duration.  The core writes through
   ca->ptr after ca_allocate, so allocate must publish too — and it must
   take a hold, because the detach that follows it comes without a
   matching attach. */
static void
smoke_take_hold (CASmokeSource *ca)
{
  char *base = smoke_resolve(ca);   /* validate on every hold */
  if ( ca->holds++ == 0 ) {
    ca->ptr = base;
  }
}

static void
smoke_func_allocate (void *ap)
{
  smoke_take_hold((CASmokeSource *) ap);
}

static void
smoke_func_attach (void *ap)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  ca->n_attach++;
  smoke_take_hold(ca);
}

static void
smoke_func_sync (void *ap)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  ca->n_sync++;
  /* writes land in the owner's buffer directly; nothing to push back. */
}

static void
smoke_func_detach (void *ap)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  ca->n_detach++;
  /* CAREFUL: back to cold once the last holder leaves.  While ptr is
     published the core's dispatchers move bytes through it directly and
     the re-resolution in the slots below never runs — so a published ptr
     is a window with the guard switched off, and it must close. */
  if ( ca->holds > 0 && --ca->holds == 0 ) {
    ca->ptr = NULL;
  }
}

static void
smoke_func_fill_data (void *ap, void *val)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  ca_size_t i;
  char *p = smoke_resolve(ca);
  for (i = ca->elements; i; i--, p += ca->bytes) {
    memcpy(p, val, ca->bytes);
  }
}

static void
smoke_func_create_mask (void *ap)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  ca->mask = carray_new_safe(CA_BOOLEAN, ca->ndim, ca->dim, 0, NULL);
}

static void
smoke_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  ca_size_t n = idx[0];
  int8_t i;
  char *p;
  for (i = 1; i < ca->ndim; i++) {
    n = ca->dim[i] * n + idx[i];
  }
  p = smoke_resolve(ca) + ca->bytes * n;
  if ( dir == CA_XFER_GET ) {
    memcpy(data, p, ca->bytes);
  }
  else {
    memcpy(p, data, ca->bytes);
  }
}

static void
smoke_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                       void *data, int dir)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  char *d = (char *) data;
  char *base = smoke_resolve(ca);
  ca_size_t i;
  for (i = 0; i < n; i++) {
    char *p = base + ca->bytes * addrs[i];
    if ( dir == CA_XFER_GET ) {
      memcpy(d + i * ca->bytes, p, ca->bytes);
    }
    else {
      memcpy(p, d + i * ca->bytes, ca->bytes);
    }
  }
}

static void
smoke_func_xfer_all (void *ap, void *data, int dir)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  char *base = smoke_resolve(ca);
  if ( dir == CA_XFER_GET ) {
    memmove(data, base, ca_length((CArray *) ca));
  }
  else {
    memmove(base, data, ca_length((CArray *) ca));
  }
}

/* Region delivery: the buffer is contiguous, so walk the requested box
   and move one run per innermost line rather than per cell. */
static void
smoke_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                        ca_size_t *strides, void *data, int dir)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  int8_t    ndim = ca->ndim;
  ca_size_t native[CA_RANK_MAX];
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t base = 0;
  ca_size_t s = ca->bytes;
  char     *d = (char *) data;
  char     *base_ptr = smoke_resolve(ca);
  int8_t    k;

  for (k = ndim - 1; k >= 0; k--) { native[k] = s; s *= ca->dim[k]; }
  for (k = 0; k < ndim; k++) { base += starts[k] * native[k]; idx[k] = 0; }

  while ( 1 ) {
    ca_size_t soff = base, doff = 0;
    for (k = 0; k < ndim - 1; k++) {
      soff += idx[k] * native[k];
      doff += idx[k] * strides[k];
    }
    if ( strides[ndim - 1] == ca->bytes ) {   /* contiguous run */
      ca_size_t run = counts[ndim - 1] * ca->bytes;
      if ( dir == CA_XFER_GET ) memcpy(d + doff, base_ptr + soff, run);
      else                      memcpy(base_ptr + soff, d + doff, run);
    }
    else {
      ca_size_t j;
      for (j = 0; j < counts[ndim - 1]; j++) {
        char *p = base_ptr + soff + j * native[ndim - 1];
        char *q = d + doff + j * strides[ndim - 1];
        if ( dir == CA_XFER_GET ) memcpy(q, p, ca->bytes);
        else                      memcpy(p, q, ca->bytes);
      }
    }
    k = ndim - 2;
    while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
    if ( k < 0 ) break;
  }
}

static ca_operation_function_t smoke_func = {
  0,                          /* obj_type, filled in at install time */
  CA_REAL_ARRAY,
  smoke_func_free_object,
  smoke_func_clone,
  smoke_func_allocate,
  smoke_func_attach,
  smoke_func_sync,
  smoke_func_detach,
  smoke_func_fill_data,
  smoke_func_create_mask,
  smoke_func_xfer_index,
  smoke_func_xfer_addrs,
  .fold_stride  = NULL,       /* a source is its own fold boundary */
  .xfer_stride  = smoke_func_xfer_stride,
  .xfer_all     = smoke_func_xfer_all,
};

/* --- TypedData ------------------------------------------------------ */

static void
smoke_mark (void *ap)
{
  CASmokeSource *ca = (CASmokeSource *) ap;
  if ( ca != NULL ) {
    rb_gc_mark(ca->owner);
  }
  ca_mark(ap);
}

static size_t
smoke_dsize (const void *ap)
{
  (void) ap;
  return sizeof(CASmokeSource);
}

static const rb_data_type_t casmokesource_data_type = {
    .wrap_struct_name = "CASmokeSource",
    .parent = &casource_data_type,
    .function = {
        .dmark = smoke_mark,
        .dfree = ca_free,
        .dsize = smoke_dsize,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static const rb_data_type_t casmokesource_mask_data_type = {
    .wrap_struct_name = "CASmokeSourceMask",
    .parent = &casmokesource_data_type,
    .function = {
        .dmark = smoke_mark,
        .dfree = ca_free_nop,
        .dsize = smoke_dsize,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

/* --- constructor ---------------------------------------------------- */

/* CASmokeSource.new(owner_string, shape) — a uint8 array over the
   string's bytes. */
static VALUE
rb_smoke_source_s_new (VALUE klass, VALUE rowner, VALUE rshape)
{
  CASmokeSource *ca;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t elements = 1;
  int8_t    ndim, i;
  VALUE     obj;

  (void) klass;
  Check_Type(rowner, T_STRING);
  Check_Type(rshape, T_ARRAY);
  ndim = (int8_t) RARRAY_LEN(rshape);
  for (i = 0; i < ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rshape, i));
    elements *= dim[i];
  }
  if ( elements != (ca_size_t) RSTRING_LEN(rowner) ) {
    rb_raise(rb_eArgError,
             "shape (%ld cells) does not cover the owner (%ld bytes)",
             (long) elements, (long) RSTRING_LEN(rowner));
  }
  rb_str_modify(rowner);   /* the source writes through to these bytes */

  ca = ALLOC(CASmokeSource);
  ca->_pool = NULL;        /* legacy dim allocation; see CLAUDE.md */
  /* ca_wrap_setup_null fills the CArray prefix without allocating a
     buffer.  It stamps obj_type = CA_OBJ_ARRAY_WRAP, so claim our own
     obj_type back afterwards. */
  ca_wrap_setup_null((CArray *) ca, CA_UINT8, ndim, dim, 0, NULL);
  ca->obj_type    = CA_OBJ_SMOKE_SOURCE;
  ca->owner       = rowner;
  ca->owner_bytes = (ca_size_t) RSTRING_LEN(rowner);
  ca->holds       = 0;
  ca->n_resolve   = 0;
  ca->n_attach    = 0;
  ca->n_sync      = 0;
  ca->n_detach    = 0;
  ca->ptr         = NULL;                /* cold at rest */
  smoke_resolve(ca);                     /* validate the owner now */

  obj = ca_wrap_struct((CArray *) ca);
  rb_ivar_set(obj, rb_intern("@owner"), rowner);
  return obj;
}

/* CASource seals its own allocator, so a subclass that wants dup / clone
   supplies one (plus initialize_copy) exactly as every in-core view class
   does.  The copy shares the owner: it is another view of the same
   foreign buffer, not a snapshot (use #copy for a snapshot). */
static VALUE
rb_smoke_source_s_allocate (VALUE klass)
{
  CASmokeSource *ca;
  return TypedData_Make_Struct(klass, CASmokeSource,
                               &casmokesource_data_type, ca);
}

static VALUE
rb_smoke_source_initialize_copy (VALUE self, VALUE other)
{
  CASmokeSource *ca, *cs;
  TypedData_Get_Struct(self,  CASmokeSource, &casmokesource_data_type, ca);
  TypedData_Get_Struct(other, CASmokeSource, &casmokesource_data_type, cs);
  ca->_pool = NULL;
  ca_wrap_setup_null((CArray *) ca, cs->data_type, cs->ndim, cs->dim,
                     cs->bytes, NULL);
  ca->obj_type    = CA_OBJ_SMOKE_SOURCE;
  ca->owner       = cs->owner;
  ca->owner_bytes = cs->owner_bytes;
  ca->holds       = 0;
  ca->n_resolve   = 0;
  ca->n_attach    = 0;
  ca->n_sync      = 0;
  ca->n_detach    = 0;
  ca->ptr         = NULL;
  rb_ivar_set(self, rb_intern("@owner"), cs->owner);
  return self;
}

#define SMOKE_COUNTER(name, field)                                \
  static VALUE                                                      \
  rb_smoke_source_##name (VALUE self)                               \
  {                                                                 \
    CASmokeSource *ca;                                              \
    TypedData_Get_Struct(self, CASmokeSource,                       \
                         &casmokesource_data_type, ca);             \
    return LONG2NUM(ca->field);                                     \
  }

SMOKE_COUNTER(resolve_count, n_resolve)
SMOKE_COUNTER(hold_count,    holds)
SMOKE_COUNTER(attach_count,  n_attach)
SMOKE_COUNTER(sync_count,   n_sync)
SMOKE_COUNTER(detach_count, n_detach)

static VALUE
rb_smoke_source_reset_counters (VALUE self)
{
  CASmokeSource *ca;
  TypedData_Get_Struct(self, CASmokeSource, &casmokesource_data_type, ca);
  ca->n_resolve = ca->n_attach = ca->n_sync = ca->n_detach = 0;
  return self;
}

/* Simulate the backend re-shaping the buffer under the source: the next
   attach must refuse to hand out a stale pointer. */
static VALUE
rb_smoke_source_revoke_bang (VALUE self)
{
  CASmokeSource *ca;
  TypedData_Get_Struct(self, CASmokeSource, &casmokesource_data_type, ca);
  ca->owner_bytes += 1;
  return self;
}

/* This fixture is built without CARRAY_BUILD, so ca_is_entity resolves to
   the out-of-line form -- the one an external extension gets, and the one
   that keeps the ca_func[] stride out of separately built objects.  Exposed
   so a spec can check it agrees with CArray#entity?, which is answered by
   the in-build macro. */
static VALUE
rb_smoke_source_s_entity_p (VALUE klass, VALUE obj)
{
  CArray *ca;
  TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
  return ca_is_entity(ca) ? Qtrue : Qfalse;
}

/* --- Init ----------------------------------------------------------- */

void
Init_source_smoke (void)
{
  rb_cCASmokeSource     = rb_define_class("CASmokeSource", rb_cCASource);
  rb_cCASmokeSourceMask = rb_define_class("CASmokeSourceMask",
                                          rb_cCASmokeSource);

  CA_OBJ_SMOKE_SOURCE = ca_install_obj_type(rb_cCASmokeSource,
                                            &casmokesource_data_type,
                                            rb_cCASmokeSourceMask,
                                            &casmokesource_mask_data_type,
                                            &smoke_func, sizeof(smoke_func));

  rb_define_alloc_func(rb_cCASmokeSource, rb_smoke_source_s_allocate);
  rb_define_method(rb_cCASmokeSource, "initialize_copy",
                   rb_smoke_source_initialize_copy, 1);
  rb_define_singleton_method(rb_cCASmokeSource, "new",
                             rb_smoke_source_s_new, 2);
  rb_define_method(rb_cCASmokeSource, "resolve_count",
                   rb_smoke_source_resolve_count, 0);
  rb_define_method(rb_cCASmokeSource, "hold_count",
                   rb_smoke_source_hold_count, 0);
  rb_define_method(rb_cCASmokeSource, "attach_count",
                   rb_smoke_source_attach_count, 0);
  rb_define_method(rb_cCASmokeSource, "sync_count",
                   rb_smoke_source_sync_count, 0);
  rb_define_method(rb_cCASmokeSource, "detach_count",
                   rb_smoke_source_detach_count, 0);
  rb_define_method(rb_cCASmokeSource, "reset_counters",
                   rb_smoke_source_reset_counters, 0);
  rb_define_singleton_method(rb_cCASmokeSource, "entity_p",
                             rb_smoke_source_s_entity_p, 1);
  rb_define_method(rb_cCASmokeSource, "revoke!",
                   rb_smoke_source_revoke_bang, 0);
}
