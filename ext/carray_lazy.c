/* ---------------------------------------------------------------------------

  CALazyMarker view + the shared lazy arena.

  CALazyMarker is a zero-cost marker that holds a CArray entity and
  causes `.sqrt` / `.sin` / etc. on it to build a lazy CAMonOp tree
  instead of evaluating eagerly.  A consumer op walks marker->parent
  to drop the marker from the tree, so the marker itself is transient
  — Ruby may keep a reference and re-consume (`m = a.lazy; m.sqrt +
  m.sin`); the marker never mutates during consumption.  Otherwise it
  is a pure pass-through: every CArray operation delegates to the
  parent.  Detection happens via ca_is_lazy_view().

  ca_lazy_arena is the shared slot-pool arena that CAMonOp / CABinOp
  / CAMonCmp / CABinCmp use for scratch during to_ca; slot buffers
  stay alive across calls to amortise mmap into steady-state reuse.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_*, ca_is_lazy_view */

int8_t CA_OBJ_LAZY_MARKER;
VALUE rb_cCALazyMarker;

typedef struct CALazyMarker {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;
  int32_t   flags;
  ca_size_t bytes;
  ca_size_t elements;
  ca_size_t *dim;
  char     *ptr;
  CArray   *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
} CALazyMarker;

static size_t
ca_lazy_marker_dsize (const void *ap)
{
  const CALazyMarker *ca = (const CALazyMarker *) ap;
  return sizeof(CALazyMarker) + ca->ndim * sizeof(ca_size_t);
}

const rb_data_type_t calazy_marker_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CALazyMarker",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_lazy_marker_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */

static int
ca_lazy_marker_setup (CALazyMarker *ca, CArray *parent)
{
  ca->obj_type  = CA_OBJ_LAZY_MARKER;
  ca->data_type = parent->data_type;
  ca->flags     = 0;
  ca->ndim      = parent->ndim;
  ca->bytes     = parent->bytes;
  ca->elements  = parent->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(ca_size_t, parent->ndim);
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  memcpy(ca->dim, parent->dim, parent->ndim * sizeof(ca_size_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  /* CAREFUL: the marker must be read-only.  CArray.fuse depends on
     destructive ops being rejected against a marker, and lazy views
     as a family carry CA_FLAG_READ_ONLY (same shape as CAFake).
     Without this flag, `m[i] = x` would silently write through to
     the parent and violate the shadow semantics. */
  ca_set_flag(ca, CA_FLAG_READ_ONLY);

  /* Storage-identical wrapper: the kernel_iterator entry strip and the
     view-creation lift both ask for this. */
  ca_set_flag(ca, CA_FLAG_IS_LAZY_MARKER);

  return 0;
}

CALazyMarker *
ca_lazy_marker_new (CArray *parent)
{
  CALazyMarker *ca = ALLOC(CALazyMarker);
  ca_lazy_marker_setup(ca, parent);
  return ca;
}

static void
free_ca_lazy_marker (void *ap)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */
/* Pass-through operations: everything delegates to parent.            */
/* ------------------------------------------------------------------- */

static void *
ca_lazy_marker_func_clone (void *ap)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  return ca_lazy_marker_new(ca->parent);
}

static void
ca_lazy_marker_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  if ( dir == CA_XFER_GET ) {
    ca_fetch_index(ca->parent, idx, data);
  } else {
    ca_store_index(ca->parent, idx, data);
  }
}

static void
ca_lazy_marker_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                                void *data, int dir)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  ca_xfer_addrs(ca->parent, n, addrs, data, dir);
}

static void
ca_lazy_marker_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                                 ca_size_t *strides, void *data, int dir)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  ca_xfer_stride(ca->parent, starts, counts, strides, data, dir);
}

static void
ca_lazy_marker_func_xfer_all (void *ap, void *data, int dir)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  ca_xfer_all(ca->parent, data, dir);
}

static void
ca_lazy_marker_func_attach (void *ap)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr;     /* alias */
}

static void
ca_lazy_marker_func_sync (void *ap)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  ca_sync(ca->parent);
}

static void
ca_lazy_marker_func_detach (void *ap)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_lazy_marker_func_allocate (void *ap)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  ca_allocate(ca->parent);
  ca->ptr = ca->parent->ptr;     /* alias */
}

static void
ca_lazy_marker_func_fill_data (void *ap, void *ptr)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  ca_fill(ca->parent, ptr);
}

static void
ca_lazy_marker_func_create_mask (void *ap)
{
  CALazyMarker *ca = (CALazyMarker *) ap;
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask =
    (CArray *) ca_refer_new(ca->parent->mask,
                            CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_lazy_marker_func = {
  -1, /* CA_OBJ_LAZY_MARKER, set at install time */
  CA_VIEW_ARRAY,
  free_ca_lazy_marker,
  ca_lazy_marker_func_clone,
  ca_lazy_marker_func_allocate,
  ca_lazy_marker_func_attach,
  ca_lazy_marker_func_sync,
  ca_lazy_marker_func_detach,
  ca_lazy_marker_func_fill_data,
  ca_lazy_marker_func_create_mask,
  ca_lazy_marker_func_xfer_index,
  ca_lazy_marker_func_xfer_addrs,
  NULL,                       /* fold_stride: not implemented */
  ca_lazy_marker_func_xfer_stride,
  ca_lazy_marker_func_xfer_all,
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_lazy_marker_new (VALUE cary)
{
  volatile VALUE obj;
  CArray *parent;
  CALazyMarker *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca  = ca_lazy_marker_new(parent);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* CArray#lazy — return a zero-cost CALazyMarker wrapping self.  Subsequent
 * element-wise ops (.sqrt / .sin / .+ / ...) build a lazy CAMonOp / CABinOp
 * tree instead of evaluating eagerly; `.to_ca` materialises. */
VALUE
rb_ca_lazy (VALUE self)
{
  return rb_ca_lazy_marker_new(self);
}

/* ------------------------------------------------------------------- */
/* ca_lazy_arena                                                        */
/* ------------------------------------------------------------------- */

/* Slot-pool arena.  Each slot is an independent xmalloc'd buffer that
   stays alive across to_ca calls; acquire / release toggles the
   in_use flag, not the buffer itself, so simultaneous nested acquires
   (deep CABinOp chain) hold stable pointers.  A single-cursor + LIFO
   stack design would force realloc when an outer acquire grew the
   stack while an inner acquire still held the previous base — the
   slot pool sidesteps that by design.

   Steady state:
     first to_ca call    xmalloc N slots
     subsequent calls    reuse warm slots
     best-fit allocation keeps small requests (mask scratch) out of
                         large data slots

   Footprint: 32 slots × max observed size (up to 32 × max_slab_bytes;
   e.g. N=1M f64, depth-8 chain = 8 × 8MB = 64MB kept resident).  When
   the slot pool is exhausted the acquire raises: this signals a
   programming error or a pathological chain rather than a graceful
   fallback.

   CAREFUL: single-thread only -- thread-safety across concurrent access
   is not a goal (see guides/devel/04_attach_lifecycle.md).  The arena is
   process-global static state. */

#define CA_LAZY_ARENA_SLOTS 32

typedef struct ca_lazy_arena_slot {
  void     *ptr;     /* xmalloc'd buffer, NULL = unused-and-unallocated */
  ca_size_t bytes;   /* allocated size of ptr (= capacity of this slot) */
  int       in_use;  /* 1 = currently acquired, 0 = available */
} ca_lazy_arena_slot_t;

typedef struct ca_lazy_arena {
  ca_lazy_arena_slot_t slots[CA_LAZY_ARENA_SLOTS];
  int depth;                              /* enter/exit nest count */
  ca_size_t debug_acquire_count;          /* test instrumentation */
  ca_size_t debug_xmalloc_count;          /* test: how many xmallocs total */
  ca_size_t debug_reuse_count;            /* test: how many acquire = reuse */
} ca_lazy_arena_t;

static ca_lazy_arena_t ca_lazy_arena = {0};

void
ca_lazy_arena_enter (void)
{
  if ( ca_lazy_arena.depth == 0 ) {
    /* Top-level reset to recover from a prior exception that left
       slots in_use without a matching release.  Safe because
       depth==0 means no nested caller is mid-acquire. */
    int i;
    for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
      ca_lazy_arena.slots[i].in_use = 0;
    }
  }
  ca_lazy_arena.depth++;
}

void
ca_lazy_arena_exit (void)
{
  if ( ca_lazy_arena.depth > 0 ) {
    ca_lazy_arena.depth--;
  }
  /* Keep all slot buffers; they amortise into subsequent calls. */
}

void *
ca_lazy_arena_acquire (ca_size_t bytes)
{
  int i, best, empty;
  ca_size_t best_bytes;

  if ( bytes <= 0 ) bytes = 1;

  ca_lazy_arena.debug_acquire_count++;

  /* Pass 1: best-fit among unused warm slots (smallest >= bytes).
     CAREFUL: ca_size_t is signed int64_t, so the "no match yet"
     sentinel must be CA_LENGTH_MAX — NOT -1, which would compare
     less than any real capacity. */
  best = -1;
  best_bytes = CA_LENGTH_MAX;
  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    ca_lazy_arena_slot_t *s = &ca_lazy_arena.slots[i];
    if ( s->in_use ) continue;
    if ( s->ptr == NULL ) continue;
    if ( s->bytes < bytes ) continue;
    if ( s->bytes < best_bytes ) {
      best = i;
      best_bytes = s->bytes;
    }
  }
  if ( best >= 0 ) {
    ca_lazy_arena.slots[best].in_use = 1;
    ca_lazy_arena.debug_reuse_count++;
    return ca_lazy_arena.slots[best].ptr;
  }


  /* Pass 2: empty slot — xmalloc a fresh buffer.  */
  empty = -1;
  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    if ( ca_lazy_arena.slots[i].ptr == NULL ) {
      empty = i;
      break;
    }
  }
  if ( empty >= 0 ) {
    ca_lazy_arena.slots[empty].ptr    = xmalloc(bytes);
    ca_lazy_arena.slots[empty].bytes  = bytes;
    ca_lazy_arena.slots[empty].in_use = 1;
    ca_lazy_arena.debug_xmalloc_count++;
    return ca_lazy_arena.slots[empty].ptr;
  }

  /* Pass 3: all slots have ptrs.  Find a non-in-use slot and grow it
     (= xfree + xmalloc).  This pays a mmap roundtrip but only on
     slot pool exhaustion (= unusual size request).  */
  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    if ( ! ca_lazy_arena.slots[i].in_use ) {
      xfree(ca_lazy_arena.slots[i].ptr);
      ca_lazy_arena.slots[i].ptr    = xmalloc(bytes);
      ca_lazy_arena.slots[i].bytes  = bytes;
      ca_lazy_arena.slots[i].in_use = 1;
      ca_lazy_arena.debug_xmalloc_count++;
      return ca_lazy_arena.slots[i].ptr;
    }
  }

  /* Pass 4: all CA_LAZY_ARENA_SLOTS in use simultaneously.  This is
     a programming error or a pathological chain.  Raise.            */
  rb_raise(rb_eRuntimeError,
           "ca_lazy_arena_acquire: all %d slots in use simultaneously "
           "(chain depth exceeds arena capacity)",
           CA_LAZY_ARENA_SLOTS);
  return NULL;  /* unreachable */
}

void
ca_lazy_arena_release (void *ptr)
{
  int i;
  if ( ptr == NULL ) return;
  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    if ( ca_lazy_arena.slots[i].ptr == ptr ) {
      ca_lazy_arena.slots[i].in_use = 0;
      return;
    }
  }
  /* Unknown ptr — could indicate caller mixed arena release with a
     non-arena pointer.  Be lenient (= no raise) to avoid masking
     genuine bugs at unrelated callsites.  */
}

/* Test instrumentation — exposed to Ruby for the arena smoke and
   regression assertions.  Not user-facing API. */
static VALUE
rb_ca_lazy_arena_s_reset_counters (VALUE klass)
{
  ca_lazy_arena.debug_acquire_count = 0;
  ca_lazy_arena.debug_xmalloc_count = 0;
  ca_lazy_arena.debug_reuse_count   = 0;
  return Qnil;
}

static VALUE
rb_ca_lazy_arena_s_acquire_count (VALUE klass)
{
  return SIZE2NUM(ca_lazy_arena.debug_acquire_count);
}

static VALUE
rb_ca_lazy_arena_s_xmalloc_count (VALUE klass)
{
  return SIZE2NUM(ca_lazy_arena.debug_xmalloc_count);
}

static VALUE
rb_ca_lazy_arena_s_reuse_count (VALUE klass)
{
  return SIZE2NUM(ca_lazy_arena.debug_reuse_count);
}

static VALUE
rb_ca_lazy_arena_s_depth (VALUE klass)
{
  return INT2NUM(ca_lazy_arena.depth);
}

static VALUE
rb_ca_lazy_arena_s_slot_in_use_count (VALUE klass)
{
  int i, n = 0;
  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    if ( ca_lazy_arena.slots[i].in_use ) n++;
  }
  return INT2NUM(n);
}

/* Per-slot capacity sweep for observability tests.  Returns an
   Array of Integer bytes for every populated slot, so a test can
   assert that mixed boolean (1 byte/cell) and f64 (8 byte/cell)
   acquires develop distinct size classes under best-fit — otherwise
   boolean acquires would sit in oversized f64 slots and force fresh
   xmalloc for subsequent f64 acquires. */
static VALUE
rb_ca_lazy_arena_s_slot_capacities (VALUE klass)
{
  int i;
  VALUE arr = rb_ary_new();
  (void) klass;
  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    if ( ca_lazy_arena.slots[i].ptr != NULL ) {
      rb_ary_push(arr, SIZE2NUM(ca_lazy_arena.slots[i].bytes));
    }
  }
  return arr;
}

/* ------------------------------------------------------------------- */

/* ca_lazy_wrap_scalar(other, self_ca) — wrap a non-CArray Ruby value
 * as a 1-element CScalar whose data_type follows the array's family,
 * mirroring the array+scalar branch of rb_ca_cast_self_or_other.  The
 * scalar takes on self's data_type so binops preserve self's
 * precision (`f32_array + 2.5` stays f32).
 *
 * CA_OBJECT self    -> CA_OBJECT
 * CA_BOOLEAN self   -> derive from other's Ruby type via
 *                       ca_value_to_data_type (bool arithmetic is a
 *                       corner case; eager widens the array, so we
 *                       just let the scalar choose)
 * numeric self      -> self_ca->data_type
 *
 * Callers broadcast against the array via stride 0 in xfer_stride. */
VALUE
ca_lazy_wrap_scalar (VALUE other, CArray *self_ca)
{
  int8_t dt;

  if ( ca_is_object_type(self_ca) ) {
    dt = CA_OBJECT;
  }
  else if ( self_ca->data_type == CA_BOOLEAN ) {
    dt = ca_value_to_data_type(other);
  }
  else {
    dt = self_ca->data_type;
  }

  return rb_cscalar_new_with_value(dt, 0, other);
}

static VALUE
rb_ca_lazy_marker_s_allocate (VALUE klass)
{
  CALazyMarker *ca;
  return TypedData_Make_Struct(klass, CALazyMarker,
                               &calazy_marker_data_type, ca);
}

static VALUE
rb_ca_lazy_marker_initialize_copy (VALUE self, VALUE other)
{
  CALazyMarker *ca, *cs;
  TypedData_Get_Struct(self,  CALazyMarker, &calazy_marker_data_type, ca);
  TypedData_Get_Struct(other, CALazyMarker, &calazy_marker_data_type, cs);
  ca_lazy_marker_setup(ca, cs->parent);
  return self;
}

void
Init_carray_lazy (void)
{
  rb_cCALazyMarker = rb_define_class("CALazyMarker", rb_cCAView);

  CA_OBJ_LAZY_MARKER = ca_install_obj_type(rb_cCALazyMarker,
                                           &calazy_marker_data_type,
                                           rb_cCArrayMask,
                                           &carray_mask_data_type,
                                           &ca_lazy_marker_func, sizeof(ca_lazy_marker_func));
  rb_define_const(rb_cObject, "CA_OBJ_LAZY_MARKER",
                  INT2NUM(CA_OBJ_LAZY_MARKER));

  rb_define_method(rb_cCArray, "lazy", rb_ca_lazy, 0);

  rb_define_alloc_func(rb_cCALazyMarker, rb_ca_lazy_marker_s_allocate);
  rb_define_method(rb_cCALazyMarker, "initialize_copy",
                                      rb_ca_lazy_marker_initialize_copy, 1);

  /* Arena test instrumentation (not user-facing).  Bound on CArray
     for symmetry with CAMonOp / CABinOp counters, but the arena is
     a singleton process-wide state. */
  rb_define_singleton_method(rb_cCArray, "__lazy_arena_reset_counters__",
                             rb_ca_lazy_arena_s_reset_counters, 0);
  rb_define_singleton_method(rb_cCArray, "__lazy_arena_acquire_count__",
                             rb_ca_lazy_arena_s_acquire_count, 0);
  rb_define_singleton_method(rb_cCArray, "__lazy_arena_xmalloc_count__",
                             rb_ca_lazy_arena_s_xmalloc_count, 0);
  rb_define_singleton_method(rb_cCArray, "__lazy_arena_reuse_count__",
                             rb_ca_lazy_arena_s_reuse_count, 0);
  rb_define_singleton_method(rb_cCArray, "__lazy_arena_depth__",
                             rb_ca_lazy_arena_s_depth, 0);
  rb_define_singleton_method(rb_cCArray, "__lazy_arena_slot_in_use_count__",
                             rb_ca_lazy_arena_s_slot_in_use_count, 0);
  rb_define_singleton_method(rb_cCArray, "__lazy_arena_slot_capacities__",
                             rb_ca_lazy_arena_s_slot_capacities, 0);
}
