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
#include "ca_kernel_iterator.h" /* ca_iter_register_source_kind */

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
  if ( ca_region_is_empty(((CArray *) ap)->ndim, counts) ) return;
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
  ca_view_func_create_mask(ca);
  ca_set_flag(ca->mask, CA_FLAG_READ_ONLY);
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
 * tree instead of evaluating eagerly; `.to_ca` materialises.
 *
 * A Face returns itself: a lazy tree computes on storage and would lose
 * the Face's meaning (units, labels, string surface), so its operations
 * stay eager. */
VALUE
rb_ca_lazy (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ca_is_face(ca) ) {
    return self;
  }
  return rb_ca_lazy_marker_new(self);
}

/* ------------------------------------------------------------------- */
/* CA_OBJECT GC guard                                                   */
/* ------------------------------------------------------------------- */

/* A CA_OBJECT cell is a VALUE.  While a view materialises into a raw
   buffer -- the destination `copy` will hand out, a view's own attach
   buffer, or an arena scratch -- those VALUEs live somewhere the GC
   cannot see: an xmalloc'd block owned by no Ruby object.  For every
   other data_type that is harmless, but an object-lane kernel calls
   rb_funcall per cell, and any of those can collect.  The results
   written so far are then freed under the buffer, and the array comes
   back holding recycled slots: wrong values, and a crash once a slot is
   reused as something else.

   So such buffers are registered here for the duration and marked from
   a hidden guard object that lives as long as the process.  Two kinds
   are registered:

     holds   a contiguous run of cells, pushed and popped around a
             whole-view transfer or the handoff to a Ruby owner
     slots   an arena scratch, tagged at acquire and held until release

   Only contiguous runs are held.  A strided window would cover the same
   cells but its extent has to be taken on trust from the caller's
   strides, and a window wider than the buffer behind it would be filled
   and marked out of bounds.  The whole-view entry knows the extent
   exactly, and every partial transfer writes inside it. */

#define CA_GC_HOLD_MAX 64

typedef struct ca_gc_hold {
  VALUE    *ptr;
  ca_size_t elements;
} ca_gc_hold_t;

static ca_gc_hold_t ca_gc_holds[CA_GC_HOLD_MAX];
static int          ca_gc_hold_depth = 0;

static void ca_lazy_arena_mark_object_slots (void);

/* Returns the depth to hand back to ca_gc_hold_pop_to, so nested holds
   unwind in order.  Pushing is best-effort at the ceiling: a chain
   deeper than CA_GC_HOLD_MAX loses the protection for its innermost
   buffers rather than raising in the middle of a materialise.  The cells
   must already be valid VALUEs -- the caller fills a fresh buffer with
   Qnil first. */
int
ca_gc_hold_push (void *ptr, ca_size_t n_elements)
{
  int depth = ca_gc_hold_depth;

  if ( depth >= CA_GC_HOLD_MAX || n_elements <= 0 || ptr == NULL ) {
    return -1;
  }
  ca_gc_holds[depth].ptr      = (VALUE *) ptr;
  ca_gc_holds[depth].elements = n_elements;
  ca_gc_hold_depth = depth + 1;
  return depth;
}

void
ca_gc_hold_pop_to (int depth)
{
  if ( depth >= 0 && depth < ca_gc_hold_depth ) {
    ca_gc_hold_depth = depth;
  }
}

/* Buffers held until released, in any order (ca_gc_hold_buffer).  The
   table is grown with the C allocator so that a collection cannot run
   while it is half moved. */
static ca_gc_hold_t *ca_gc_buffers     = NULL;
static int           ca_gc_buffer_n    = 0;
static int           ca_gc_buffer_cap  = 0;

void
ca_gc_hold_buffer (void *ptr, ca_size_t n_elements)
{
  if ( ptr == NULL || n_elements <= 0 ) {
    return;
  }
  if ( ca_gc_buffer_n == ca_gc_buffer_cap ) {
    int cap = ca_gc_buffer_cap ? ca_gc_buffer_cap * 2 : 16;
    ca_gc_hold_t *grown = (ca_gc_hold_t *) realloc(ca_gc_buffers,
                                                   cap * sizeof(ca_gc_hold_t));
    if ( grown == NULL ) {
      rb_memerror();
    }
    ca_gc_buffers    = grown;
    ca_gc_buffer_cap = cap;
  }
  ca_gc_buffers[ca_gc_buffer_n].ptr      = (VALUE *) ptr;
  ca_gc_buffers[ca_gc_buffer_n].elements = n_elements;
  ca_gc_buffer_n++;
}

void
ca_gc_release_buffer (void *ptr)
{
  int i;
  for ( i = ca_gc_buffer_n - 1; i >= 0; i-- ) {
    if ( ca_gc_buffers[i].ptr == (VALUE *) ptr ) {
      ca_gc_buffers[i] = ca_gc_buffers[ca_gc_buffer_n - 1];
      ca_gc_buffer_n--;
      return;
    }
  }
}

static VALUE ca_gc_guard = Qnil;

/* The wrapped pointer must be non-NULL: Ruby's GC skips the mark
   function of a TypedData whose data pointer is NULL. */
static int ca_gc_guard_body = 0;

static void
ca_gc_guard_mark (void *ptr)
{
  int i;
  (void) ptr;
  for ( i = 0; i < ca_gc_hold_depth; i++ ) {
    VALUE    *p = ca_gc_holds[i].ptr;
    ca_size_t n = ca_gc_holds[i].elements;
    while ( n-- ) rb_gc_mark(*p++);
  }
  for ( i = 0; i < ca_gc_buffer_n; i++ ) {
    VALUE    *p = ca_gc_buffers[i].ptr;
    ca_size_t n = ca_gc_buffers[i].elements;
    while ( n-- ) rb_gc_mark(*p++);
  }
  ca_lazy_arena_mark_object_slots();
}

static void
ca_gc_guard_free (void *ptr)
{
  (void) ptr;
}

static const rb_data_type_t ca_gc_guard_data_type = {
  "carray_object_gc_guard",
  { ca_gc_guard_mark, ca_gc_guard_free, NULL, },
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};

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

   Footprint: one slot per scratch held at the same time, each as large
   as the largest request it has served (e.g. N=1M f64, depth-8 chain =
   8 × 8MB = 64MB kept resident).  A request no free slot can hold grows
   a free slot; a new slot opens only while every warm one is in use.
   When all 32 are in use the acquire raises: this signals a programming
   error or a pathological chain rather than a graceful fallback.

   CAREFUL: single-thread only -- thread-safety across concurrent access
   is not a goal (see guides/devel/04_attach_lifecycle.md).  The arena is
   process-global static state. */

#define CA_LAZY_ARENA_SLOTS 32

typedef struct ca_lazy_arena_slot {
  void     *ptr;     /* xmalloc'd buffer, NULL = unused-and-unallocated */
  ca_size_t bytes;   /* allocated size of ptr (= capacity of this slot) */
  int       in_use;  /* 1 = currently acquired, 0 = available */
  ca_size_t object_elements;  /* >0 = holds VALUEs; marked while in_use */
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
      ca_lazy_arena.slots[i].object_elements = 0;
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
  /* Keep all slot buffers, and leave in_use and the object tags alone.
     A scratch can be acquired outside any enter/exit bracket -- a lazy
     view's attach path does exactly that -- so an inner materialise
     dropping to depth 0 is not evidence that nothing is held.  Recovery
     from an abandoned slot happens on the next depth-0 entry instead.

     An abandoned object slot stays marked until then, which is a leak
     but not a hazard: acquire only ever hands out a slot that is not in
     use, so nothing overwrites it, and marking is what keeps its cells
     from being collected in the first place. */
}

/* Runs body(arg) inside an enter / exit bracket that closes however body
   leaves.  cleanup(arg), when given, runs first -- the place to release
   the scratches and detach the arrays body acquired -- and the exit runs
   after it.

   A raise that skipped the exit would leave the depth above 0 for the
   rest of the process: the depth-0 reset that recovers abandoned slots
   would never fire again, and once 32 slots were abandoned every lazy
   expression would fail. */

typedef struct {
  VALUE (*cleanup)(VALUE);
  VALUE   arg;
} ca_lazy_arena_ensure_t;

static VALUE
ca_lazy_arena_ensure (VALUE varg)
{
  ca_lazy_arena_ensure_t *e = (ca_lazy_arena_ensure_t *) varg;
  if ( e->cleanup ) {
    e->cleanup(e->arg);
  }
  ca_lazy_arena_exit();
  return Qnil;
}

VALUE
ca_lazy_arena_protect (VALUE (*body)(VALUE), VALUE (*cleanup)(VALUE),
                       VALUE arg)
{
  ca_lazy_arena_ensure_t e;
  e.cleanup = cleanup;
  e.arg     = arg;
  ca_lazy_arena_enter();
  return rb_ensure(body, arg, ca_lazy_arena_ensure, (VALUE) &e);
}

/* A cleanup for ca_lazy_arena_protect when body holds one scratch: arg
   points at a struct whose first member is that scratch (NULL until it
   is acquired). */
VALUE
ca_lazy_arena_release_held (VALUE arg)
{
  void **held = (void **) arg;
  if ( *held ) {
    ca_lazy_arena_release(*held);
    *held = NULL;
  }
  return Qnil;
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
    ca_lazy_arena.slots[best].object_elements = 0;
    ca_lazy_arena.debug_reuse_count++;
    return ca_lazy_arena.slots[best].ptr;
  }


  /* Pass 2: every free warm slot is too small.  Grow the largest of
     them rather than open another slot: a slot that is free now was not
     needed at the same time as this request, so the arena holds one
     buffer per simultaneous acquire rather than one per size ever asked
     for.  Taking the largest leaves the small slots to the small
     requests (mask scratch next to data scratch).

     The slot is emptied before the xmalloc so that a NoMemoryError
     leaves it unallocated instead of pointing at freed memory. */
  best = -1;
  best_bytes = -1;
  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    ca_lazy_arena_slot_t *s = &ca_lazy_arena.slots[i];
    if ( s->in_use || s->ptr == NULL ) continue;
    if ( s->bytes > best_bytes ) {
      best = i;
      best_bytes = s->bytes;
    }
  }
  if ( best >= 0 ) {
    ca_lazy_arena_slot_t *s = &ca_lazy_arena.slots[best];
    void *old = s->ptr;
    s->ptr   = NULL;
    s->bytes = 0;
    xfree(old);
    s->ptr    = xmalloc(bytes);
    s->bytes  = bytes;
    s->in_use = 1;
    s->object_elements = 0;
    ca_lazy_arena.debug_xmalloc_count++;
    return s->ptr;
  }

  /* Pass 3: every warm slot is in use.  Open an empty one. */
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
    ca_lazy_arena.slots[empty].object_elements = 0;
    ca_lazy_arena.debug_xmalloc_count++;
    return ca_lazy_arena.slots[empty].ptr;
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
      ca_lazy_arena.slots[i].object_elements = 0;
      return;
    }
  }
  /* Unknown ptr — could indicate caller mixed arena release with a
     non-arena pointer.  Be lenient (= no raise) to avoid masking
     genuine bugs at unrelated callsites.  */
}

/* Acquire a scratch that will hold `n_elements` VALUEs.

   Unlike the byte-sized acquire this one Qnil-fills the buffer and tags
   the slot, so the cells stay markable for as long as the caller holds
   it.  Object-lane kernels run rb_funcall over their operands, so a
   scratch pulled from a lazy operand holds VALUEs that exist nowhere
   else until the kernel has consumed them. */
void *
ca_lazy_arena_acquire_object (ca_size_t n_elements)
{
  void *ptr;
  int i;

  if ( n_elements < 0 ) n_elements = 0;
  ptr = ca_lazy_arena_acquire(n_elements * (ca_size_t) sizeof(VALUE));

  {
    VALUE *p = (VALUE *) ptr;
    ca_size_t n = n_elements;
    while ( n-- ) *p++ = Qnil;
  }

  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    if ( ca_lazy_arena.slots[i].ptr == ptr ) {
      ca_lazy_arena.slots[i].object_elements = n_elements;
      break;
    }
  }
  return ptr;
}

static void
ca_lazy_arena_mark_object_slots (void)
{
  int i;
  for ( i = 0; i < CA_LAZY_ARENA_SLOTS; i++ ) {
    ca_lazy_arena_slot_t *s = &ca_lazy_arena.slots[i];
    ca_size_t n;
    VALUE *p;
    if ( ! s->in_use || s->object_elements <= 0 ) continue;
    p = (VALUE *) s->ptr;
    n = s->object_elements;
    while ( n-- ) rb_gc_mark(*p++);
  }
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
  ca_check_uninitialized(ca);
  TypedData_Get_Struct(other, CALazyMarker, &calazy_marker_data_type, cs);
  ca_lazy_marker_setup(ca, cs->parent);
  return self;
}

static void Init_ca_mask_of_operands (void);

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

  /* Hidden, never collected: its mark function is what keeps the
     in-flight CA_OBJECT buffers reachable. */
  ca_gc_guard = TypedData_Wrap_Struct(rb_cObject, &ca_gc_guard_data_type,
                                      &ca_gc_guard_body);
  rb_gc_register_mark_object(ca_gc_guard);

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

  Init_ca_mask_of_operands();
}

/* ---------------------------------------------------------------------------
   Requests to the element-wise lazy views (ca_lazy_req_t, carray_internal.h).

   An operand is pulled over the cells the request names.  In the region
   form the strides address the view's cells, so they are restated at the
   operand's cell width: strides[k] / bytes is the index step the two share.
   (A packed stride over counts is not a substitute -- it walks cells 0, 1,
   2 where the request asked for 0, 2, 4.)
   --------------------------------------------------------------------------- */

void
ca_lazy_req_region (ca_lazy_req_t *req, void *view, ca_size_t *starts,
                    ca_size_t *counts, ca_size_t *strides)
{
  CArray *ca = (CArray *) view;
  int8_t  k;
  req->n = 1;
  for ( k = 0; k < ca->ndim; k++ ) {
    req->n *= counts[k];
  }
  req->addrs   = NULL;
  req->starts  = starts;
  req->counts  = counts;
  req->strides = strides;
  req->bytes   = ca->bytes;
  req->ndim    = ca->ndim;
}

void
ca_lazy_req_addrs (ca_lazy_req_t *req, ca_size_t n, ca_size_t *addrs)
{
  req->n       = n;
  req->addrs   = addrs;
  req->starts  = NULL;
  req->counts  = NULL;
  req->strides = NULL;
  req->bytes   = 0;
  req->ndim    = 0;
}

/* Whether the request names one contiguous run of the view's cells, in
   the view's own row-major order -- the case in which an operand's buffer
   already holds the cells in the order the kernel reads them.  The strides
   must be the native row-major ones, and the box must be whole on every
   axis inside the outermost one it does not span with a count of 1. */
int
ca_lazy_req_is_packed (const ca_lazy_req_t *req, void *view)
{
  CArray   *ca = (CArray *) view;
  ca_size_t native = ca->bytes;
  int       partial = 0;
  int8_t    k;
  if ( req->addrs ) {
    return 0;
  }
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    if ( req->strides[k] != native ) {
      return 0;
    }
    if ( partial && req->counts[k] != 1 ) {
      return 0;
    }
    if ( req->counts[k] != ca->dim[k] ) {
      partial = 1;
    }
    native *= ca->dim[k];
  }
  return 1;
}

/* The cells of a request that any of `ops` masks, as a packed boolean
   slab in arena scratch, or NULL when none of them is masked.  An operand
   of one cell masks every cell or none.  Kernels that can raise on a cell,
   or that call Ruby for it, take this to skip the masked cells, as the
   eager operators do.  Release with ca_lazy_arena_release. */
boolean8_t *
ca_lazy_req_mask (const ca_lazy_req_t *req, int n, CArray **ops)
{
  boolean8_t *m = NULL;
  ca_size_t   j;
  int         i;
  int8_t      k;

  for ( i = 0; i < n; i++ ) {
    CArray *op = ops[i];
    if ( ! op || ! ca_has_mask(op) ) {
      continue;
    }
    if ( ! m ) {
      m = (boolean8_t *) ca_lazy_arena_acquire(req->n);
      memset(m, 0, req->n);
    }
    if ( op->elements == 1 ) {
      ca_size_t  starts[CA_RANK_MAX], counts[CA_RANK_MAX];
      ca_size_t  strides[CA_RANK_MAX];
      boolean8_t bit = 0;
      for ( k = 0; k < op->ndim; k++ ) {
        starts[k] = 0; counts[k] = 1; strides[k] = 1;
      }
      ca_xfer_stride(op->mask, starts, counts, strides, &bit, CA_XFER_GET);
      if ( bit ) {
        memset(m, 1, req->n);
      }
    }
    else {
      volatile VALUE holder;
      boolean8_t *om = ALLOCV_N(boolean8_t, holder, req->n);
      ca_lazy_req_pull(op->mask, req, om, CA_XFER_GET);
      for ( j = 0; j < req->n; j++ ) {
        m[j] |= om[j];
      }
      ALLOCV_END(holder);
    }
  }
  return m;
}

/* A scalar operand (a Ruby value or a CScalar) that the eager promotion
   has cast to the array's data_type comes back as a cast view over a
   CScalar.  Fix it as the CScalar the cast gives, so the expression holds
   a plain value leaf. */
VALUE
ca_lazy_settle_scalar (VALUE operand, int was_scalar)
{
  CArray *ca;
  if ( ! was_scalar ) {
    return operand;
  }
  /* rb_obj_is_cscalar is true for any view carrying the scalar flag, the
     cast view included; the obj_type says whether it is a CScalar. */
  TypedData_Get_Struct(operand, CArray, &carray_data_type, ca);
  if ( ca->obj_type != CA_OBJ_SCALAR ) {
    return rb_ca_copy(operand);
  }
  return operand;
}

void
ca_lazy_req_pull (void *operand, const ca_lazy_req_t *req, void *buf, int dir)
{
  CArray   *op = (CArray *) operand;
  ca_size_t strides[CA_RANK_MAX];
  int8_t    k;

  if ( req->addrs ) {
    ca_xfer_addrs(op, req->n, req->addrs, buf, dir);
    return;
  }
  for ( k = 0; k < req->ndim; k++ ) {
    strides[k] = req->strides[k] / req->bytes * op->bytes;
  }
  ca_xfer_stride(op, req->starts, req->counts, strides, buf, dir);
}

/* An expression the caller is about to compute whole -- a reduction along
   an axis, a sort, a median -- computed by the registered expression
   evaluator instead, when there is one and it takes the expression.
   Returns the array it made, or Qnil where nothing is registered, self is
   not a lazy expression, or the evaluator declined (CArray::Fusion.evaluate
   decides, and asks only above its size threshold).  The caller goes on
   with that array in place of self, or with self as before.

   Only where the expression would be made whole anyway: a reduction that
   streams the expression in chunks keeps doing so, since asking here would
   make it whole and take that much more memory. */
VALUE
ca_lazy_evaluated (VALUE self)
{
  static ID id_evaluator = 0, id_fusion, id_evaluate;
  CArray *ca;
  if ( ! id_evaluator ) {
    id_evaluator = rb_intern("@expression_evaluator");
    id_fusion    = rb_intern("Fusion");
    id_evaluate  = rb_intern("evaluate");
  }
  GetCArray(self, ca);
  if ( ! ca_is_lazy_view(ca) ) {
    return Qnil;
  }
  if ( ! RTEST(rb_attr_get(rb_cCArray, id_evaluator)) ) {
    return Qnil;
  }
  return rb_funcall(rb_const_get(rb_cCArray, id_fusion), id_evaluate, 1, self);
}

/* ---------------------------------------------------------------------------
   CAMaskOfOperands: the mask of an element-wise lazy operation over several
   operands (CABinOp, CABinCmp, CATriOp).

   The operation computes its values each time it is read, so its mask is
   computed the same way: a request pulls each operand's mask over the cells
   it names and ORs them.  An operand with no mask reads as all false, so an
   operand that is given a mask after the expression was first read is seen
   on the next read -- and reading the mask never gives an operand one.

   For the boolean `|` and `&` (three-valued) a masked cell is not masked in
   the result when an unmasked operand already decides it: true for `|`,
   false for `&`.  The operands' values are pulled for that.

   The view is read-only and has no mask of its own (CA_FLAG_VALUE_ARRAY),
   so nothing above it asks for one.  Its parent is the operation, which
   owns it as its mask; the operands are read through the operation's
   parents[].
   --------------------------------------------------------------------------- */

int8_t CA_OBJ_MASK_OF_OPERANDS;
VALUE rb_cCAMaskOfOperands;

typedef struct CAMaskOfOperands {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;
  int32_t   flags;
  ca_size_t bytes;
  ca_size_t elements;
  ca_size_t *dim;
  char     *ptr;
  CArray   *mask;
  char     *_pool;
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  int8_t    mode;          /* CA_LAZY_MASK_OR / _KLEENE_OR / _KLEENE_AND */
} CAMaskOfOperands;

static size_t
ca_mask_of_operands_dsize (const void *ap)
{
  const CAMaskOfOperands *ca = (const CAMaskOfOperands *) ap;
  return sizeof(CAMaskOfOperands) + ca->ndim * sizeof(ca_size_t);
}

const rb_data_type_t camask_of_operands_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAMaskOfOperands",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_mask_of_operands_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

CArray *
ca_mask_of_operands_new (CArray *operation, int mode)
{
  CAMaskOfOperands *ca = ALLOC(CAMaskOfOperands);
  ca->_pool     = NULL;
  ca->obj_type  = CA_OBJ_MASK_OF_OPERANDS;
  ca->data_type = CA_BOOLEAN;
  ca->flags     = CA_FLAG_READ_ONLY | CA_FLAG_VALUE_ARRAY;
  ca->ndim      = operation->ndim;
  ca->bytes     = 1;
  ca->elements  = operation->elements;
  ca->dim       = ALLOC_N(ca_size_t, operation->ndim);
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->parent    = operation;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->mode      = (int8_t) mode;
  memcpy(ca->dim, operation->dim, operation->ndim * sizeof(ca_size_t));
  if ( ca_is_scalar(operation) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }
  return (CArray *) ca;
}

static void
free_ca_mask_of_operands (void *ap)
{
  CAMaskOfOperands *ca = (CAMaskOfOperands *) ap;
  if ( ca != NULL ) {
    xfree(ca->ptr);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
ca_mask_of_operands_func_clone (void *ap)
{
  CAMaskOfOperands *ca = (CAMaskOfOperands *) ap;
  return ca_mask_of_operands_new(ca->parent, ca->mode);
}

/* An operand of one cell beside a larger operation is broadcast: its one
   cell stands for every cell of the request. */
static int
ca_mask_of_operands_operand_is_scalar (CAMaskOfOperands *lm, CArray *op)
{
  return ( op->elements == 1 && lm->elements > 1 );
}

static void
ca_mask_of_operands_pull (CAMaskOfOperands *lm, CArray *src, const ca_lazy_req_t *req,
                   boolean8_t *buf)
{
  if ( ca_mask_of_operands_operand_is_scalar(lm, src) ) {
    boolean8_t one;
    ca_xfer_all(src, &one, CA_XFER_GET);
    memset(buf, one ? 1 : 0, req->n);
  }
  else {
    ca_lazy_req_pull(src, req, buf, CA_XFER_GET);
  }
}

static void
ca_mask_of_operands_eval (CAMaskOfOperands *lm, const ca_lazy_req_t *req, boolean8_t *dst)
{
  CAMultiParent *mp = (CAMultiParent *) lm->parent;
  int kleene = ( lm->mode != CA_LAZY_MASK_OR );
  boolean8_t absorbing = ( lm->mode == CA_LAZY_MASK_KLEENE_OR ) ? 1 : 0;
  volatile VALUE h_mask, h_value, h_known;
  boolean8_t *m, *v = NULL, *known = NULL;
  ca_size_t n = req->n, i;
  int32_t k;

  memset(dst, 0, n);
  m = ALLOCV_N(boolean8_t, h_mask, n);
  if ( kleene ) {
    v     = ALLOCV_N(boolean8_t, h_value, n);
    known = ALLOCV_N(boolean8_t, h_known, n);
    memset(known, 0, n);
  }

  for ( k = 0; k < mp->n_parents; k++ ) {
    CArray *op = mp->parents[k];
    if ( ca_has_mask(op) ) {
      ca_mask_of_operands_pull(lm, op->mask, req, m);
      for ( i = 0; i < n; i++ ) dst[i] |= m[i];
    }
    else {
      memset(m, 0, n);
    }
    if ( kleene ) {
      ca_mask_of_operands_pull(lm, op, req, v);
      for ( i = 0; i < n; i++ ) {
        if ( ! m[i] && ( v[i] ? 1 : 0 ) == absorbing ) known[i] = 1;
      }
    }
  }

  if ( kleene ) {
    for ( i = 0; i < n; i++ ) {
      if ( known[i] ) dst[i] = 0;
    }
    ALLOCV_END(h_known);
    ALLOCV_END(h_value);
  }
  ALLOCV_END(h_mask);
}

NORETURN(static void ca_mask_of_operands_read_only (void));
static void
ca_mask_of_operands_read_only (void)
{
  rb_raise(rb_eRuntimeError, "the mask of a lazy operation is read-only");
}

static void
ca_mask_of_operands_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                               ca_size_t *strides, void *data, int dir)
{
  ca_lazy_req_t req;
  if ( ca_region_is_empty(((CArray *) ap)->ndim, counts) ) return;
  if ( dir != CA_XFER_GET ) ca_mask_of_operands_read_only();
  ca_lazy_req_region(&req, ap, starts, counts, strides);
  ca_mask_of_operands_eval((CAMaskOfOperands *) ap, &req, (boolean8_t *) data);
}

static void
ca_mask_of_operands_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                              void *data, int dir)
{
  ca_lazy_req_t req;
  if ( dir != CA_XFER_GET ) ca_mask_of_operands_read_only();
  ca_lazy_req_addrs(&req, n, addrs);
  ca_mask_of_operands_eval((CAMaskOfOperands *) ap, &req, (boolean8_t *) data);
}

static void
ca_mask_of_operands_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CArray   *ca = (CArray *) ap;
  ca_size_t addr = 0;
  int8_t    k;
  if ( dir != CA_XFER_GET ) ca_mask_of_operands_read_only();
  for ( k = 0; k < ca->ndim; k++ ) {
    addr = addr * ca->dim[k] + idx[k];
  }
  ca_mask_of_operands_func_xfer_addrs(ap, 1, &addr, data, dir);
}

static void
ca_mask_of_operands_func_xfer_all (void *ap, void *data, int dir)
{
  CArray   *ca = (CArray *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  ca_size_t s = 1;
  int8_t    k;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_mask_of_operands_func_xfer_stride(ap, starts, ca->dim, native, data, dir);
}

static VALUE
ca_mask_of_operands_fill_buffer (VALUE arg)
{
  CAMaskOfOperands *ca = (CAMaskOfOperands *) arg;
  ca_mask_of_operands_func_xfer_all(ca, ca->ptr, CA_XFER_GET);
  return Qnil;
}

/* The buffer is published only once it is filled: a read that raises
   frees it and leaves the view unattached. */
static void
ca_mask_of_operands_func_attach (void *ap)
{
  CAMaskOfOperands *ca = (CAMaskOfOperands *) ap;
  int tag = 0;
  ca->ptr = xmalloc(ca->elements);
  rb_protect(ca_mask_of_operands_fill_buffer, (VALUE) ca, &tag);
  if ( tag ) {
    xfree(ca->ptr);
    ca->ptr = NULL;
    rb_jump_tag(tag);
  }
}

static void
ca_mask_of_operands_func_allocate (void *ap)
{
  CAMaskOfOperands *ca = (CAMaskOfOperands *) ap;
  ca->ptr = xmalloc(ca->elements);
  memset(ca->ptr, 0, ca->elements);
}

static void
ca_mask_of_operands_func_sync (void *ap)
{
  /* read-only */
}

static void
ca_mask_of_operands_func_detach (void *ap)
{
  CAMaskOfOperands *ca = (CAMaskOfOperands *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
}

NORETURN(static void ca_mask_of_operands_func_fill_data (void *ap, void *ptr));
static void
ca_mask_of_operands_func_fill_data (void *ap, void *ptr)
{
  ca_mask_of_operands_read_only();
}

NORETURN(static void ca_mask_of_operands_func_create_mask (void *ap));
static void
ca_mask_of_operands_func_create_mask (void *ap)
{
  rb_raise(rb_eRuntimeError, "can not create mask array for the mask array");
}

ca_operation_function_t ca_mask_of_operands_func = {
  -1, /* CA_OBJ_MASK_OF_OPERANDS, set at install time */
  CA_VIEW_ARRAY,
  free_ca_mask_of_operands,
  ca_mask_of_operands_func_clone,
  ca_mask_of_operands_func_allocate,
  ca_mask_of_operands_func_attach,
  ca_mask_of_operands_func_sync,
  ca_mask_of_operands_func_detach,
  ca_mask_of_operands_func_fill_data,
  ca_mask_of_operands_func_create_mask,
  ca_mask_of_operands_func_xfer_index,
  ca_mask_of_operands_func_xfer_addrs,
  NULL,                       /* fold_stride: computed, never folds */
  ca_mask_of_operands_func_xfer_stride,
  ca_mask_of_operands_func_xfer_all,
};

static void
Init_ca_mask_of_operands (void)
{
  rb_cCAMaskOfOperands = rb_define_class("CAMaskOfOperands", rb_cCAView);
  CA_OBJ_MASK_OF_OPERANDS = ca_install_obj_type(rb_cCAMaskOfOperands,
                                         &camask_of_operands_data_type,
                                         rb_cCArrayMask,
                                         &carray_mask_data_type,
                                         &ca_mask_of_operands_func,
                                         sizeof(ca_mask_of_operands_func));
  rb_undef_alloc_func(rb_cCAMaskOfOperands);
  ca_iter_register_source_kind(CA_OBJ_MASK_OF_OPERANDS, CA_ITER_SRC_ATTACH);
}

/* The mask of a lazy operation over several operands: shared with the one
   masked operand when no other operand can ever be given a mask, computed
   from all of them on each read otherwise (CAMaskOfOperands above).

   An operand can be given a mask later unless it is broadcast from one
   cell (a scalar the expression made from a literal), a value array, or a
   read-only entity.  The shared mask is read-only, as the operation is. */
CArray *
ca_lazy_operation_mask (CArray *operation, int mode)
{
  CAMultiParent *mp = (CAMultiParent *) operation;
  CArray *masked = NULL;
  int32_t k, n_masked = 0, n_open = 0;

  for ( k = 0; k < mp->n_parents; k++ ) {
    CArray *op = mp->parents[k];
    if ( ca_has_mask(op) ) {
      masked = op;
      n_masked++;
    }
    else if ( ! ( op->elements == 1 && operation->elements > 1 )
              && ! ca_is_value_array(op)
              && ! ( ca_is_entity(op) && ca_is_readonly(op) ) ) {
      n_open++;
    }
  }

  if ( n_masked == 0 ) {
    return NULL;
  }

  if ( mode == CA_LAZY_MASK_OR && n_masked == 1 && n_open == 0
       && masked->elements == operation->elements ) {
    CArray *shared = (CArray *) ca_refer_new(masked->mask, CA_BOOLEAN,
                                             operation->ndim, operation->dim,
                                             0, 0);
    ca_set_flag(shared, CA_FLAG_READ_ONLY);
    return shared;
  }

  return ca_mask_of_operands_new(operation, mode);
}
