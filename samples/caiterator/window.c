/* ---------------------------------------------------------------------------

  CAWindowIterator: per-cell iterator that walks a CAWindow kernel
  over a reference CArray.  Each step relocates the kernel's
  start[] to a target cell and resyncs the embed descriptor.  Legacy
  surface (speed-non-critical); kernel_iterator is the modern path
  for windowed traversal.

---------------------------------------------------------------------------- */

#include "carray.h"

typedef struct {
  int8_t  ndim;
  ca_size_t dim[CA_RANK_MAX];
  CArray *reference;
  CArray * (*kernel_at_addr)(void *, ca_size_t, CArray *);
  CArray * (*kernel_at_index)(void *, ca_size_t *, CArray *);
  CArray * (*kernel_move_to_addr)(void *, ca_size_t, CArray *);
  CArray * (*kernel_move_to_index)(void *, ca_size_t *, CArray *);
  /* ----------- */
  CArray *kernel;
  ca_size_t offset[CA_RANK_MAX];
} CAWindowIterator;

const rb_data_type_t cawindowiterator_data_type = {
    .parent = &caiterator_data_type,
    .wrap_struct_name = "CAWindowIterator",
    .function = {
        .dmark = NULL,
        .dfree = xfree,
        .dsize = NULL,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

VALUE rb_cCAWindowIterator;

extern int8_t CA_OBJ_WINDOW;

/* ----------------------------------------------------------------- */

/* bounds is per-axis (uint8_t *); CAWindowIterator passes through the
   kernel's existing per-axis bounds. */
CAWindow *
ca_window_new (CArray *carray,
             ca_size_t *start, ca_size_t *count, uint8_t *bounds, char *fill);

/* Defined in ext/ca_obj_window.c.  Recomputes the kernel's embed
   descriptor and eligibility flags from current start[]/count[]/
   bounds[].  CAREFUL: must be called after every kernel->start[]
   mutation below, otherwise embed_* goes stale and the next access
   reads from a wrong sub-window.  Same pattern as rb_ca_window_move
   in ext/ca_obj_window.c. */
extern void ca_window_recompute_embed (CAWindow *ca);


/* Return a fresh CAWindow kernel positioned so that the iterator's
   anchor cell (= the cell at relative offset[]) lands on idx[] in
   `ref`.  When `ref` is the original reference, clones vit->kernel;
   otherwise builds a new CAWindow over `ref` sharing the kernel's
   start[]/count[]/bounds[]/fill.  Called via the kernel_at_index
   dispatch slot wired in ca_vi_setup. */
static CArray *
ca_vi_kernel_at_index (void *it, ca_size_t *idx, CArray *ref)
{
  CAWindowIterator *vit = (CAWindowIterator *) it;
  CAWindow *kernel;
  int8_t  i;
  ca_size_t j;

  if ( ref == vit->reference ) {
    kernel = (CAWindow *)ca_clone(vit->kernel);
  }
  else {
    CAWindow *ck = (CAWindow *)vit->kernel;
    kernel = ca_window_new(ref, ck->start, ck->count, ck->bounds, ck->fill);
  }

  ca_update_mask(kernel);

  for (i=0; i<kernel->ndim; i++) {
    j = idx[i];
    CA_CHECK_INDEX(j, vit->dim[i]);
    kernel->start[i] = j - vit->offset[i];
    if ( kernel->mask ) {
      ((CAWindow*)(kernel->mask))->start[i] = j - vit->offset[i];
    }
  }

  /* kernel->start[] just mutated → embed_* may be stale; resync the
     descriptor and the mask sub-window. */
  ca_window_recompute_embed(kernel);
  if ( kernel->mask ) {
    ca_window_recompute_embed((CAWindow *) kernel->mask);
  }

  return (CArray*) kernel;
}

/* Flat-address variant of ca_vi_kernel_at_index: unravels `addr` over
   the iterator's row-major dim[] and delegates. */
static CArray *
ca_vi_kernel_at_addr (void *it, ca_size_t addr, CArray *ref)
{
  CAWindowIterator *vit = (CAWindowIterator *) it;
  ca_size_t *dim = vit->dim;
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;
  for (i=vit->ndim-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_vi_kernel_at_index(it, idx, ref);
}

/* Relocate an already-built kernel `kern` to idx[] in place (= reuse
   path; no clone, no fresh CAWindow allocation).  Same start[] +
   embed resync as ca_vi_kernel_at_index; called via the
   kernel_move_to_index dispatch slot. */
static CArray *
ca_vi_kernel_move_to_index (void *it, ca_size_t *idx, CArray *kern)
{
  CAWindowIterator *vit = (CAWindowIterator *) it;
  CAWindow *kernel = (CAWindow *) kern;
  ca_size_t *dim    = vit->dim;
  ca_size_t *offset = vit->offset;
  int8_t  i;
  ca_size_t j;

  ca_update_mask(kernel);

  for (i=0; i<kernel->ndim; i++) {
    j = idx[i];
    CA_CHECK_INDEX(j, dim[i]);
    kernel->start[i] = j - offset[i];
    if ( kernel->mask ) {
      ((CAWindow*)(kernel->mask))->start[i] = j - offset[i];
    }
  }

  /* Resync embed after start[] mutation; see ca_vi_kernel_at_index. */
  ca_window_recompute_embed(kernel);
  if ( kernel->mask ) {
    ca_window_recompute_embed((CAWindow *) kernel->mask);
  }

  return (CArray*) kernel;
}

/* Flat-address variant of ca_vi_kernel_move_to_index: unravels
   `addr` over the iterator's row-major dim[] and delegates. */
static CArray *
ca_vi_kernel_move_to_addr (void *it, ca_size_t addr, CArray *ref)
{
  CAWindowIterator *vit = (CAWindowIterator *) it;
  ca_size_t *dim = vit->dim;
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;
  for (i=vit->ndim-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_vi_kernel_move_to_index(it, idx, ref);
}

/* Initialise a CAWindowIterator over reference `rref` with kernel
   `rker`.  Records the reference's shape as the iteration domain,
   wires the four kernel_{at,move_to}_{addr,index} dispatch slots,
   and derives offset[] = -kernel->start[] so that idx == offset
   places the kernel back at its construction position.  Called by
   rb_vi_initialize (fresh) and rb_vi_initialize_copy (dup). */
void
ca_vi_setup (VALUE self, VALUE rref, VALUE rker)
{
  CAWindowIterator *it;
  CArray *ref, *ker;
  int8_t i;

  rker = rb_obj_clone(rker);

  TypedData_Get_Struct(self, CAWindowIterator, &cawindowiterator_data_type, it);
  TypedData_Get_Struct(rref, CArray, &carray_data_type, ref);
  TypedData_Get_Struct(rker, CArray, &carray_data_type, ker);

  if ( ref->ndim != ker->ndim ) {
    rb_raise(rb_eRuntimeError, "ndim mismatch between reference and kernel");
  }

  it->ndim      = ref->ndim;
  memcpy(it->dim, ref->dim, it->ndim * sizeof(ca_size_t));
  it->reference = ref;
  it->kernel    = ker;
  it->kernel_at_addr  = ca_vi_kernel_at_addr;
  it->kernel_at_index = ca_vi_kernel_at_index;
  it->kernel_move_to_addr  = ca_vi_kernel_move_to_addr;
  it->kernel_move_to_index = ca_vi_kernel_move_to_index;

  for (i=0; i<it->ndim; i++) {
    it->offset[i] = -(((CAWindow*)ker)->start[i]);
  }

  rb_ivar_set(self, rb_intern("@reference"), rref); /* required ivar */
  rb_ivar_set(self, rb_intern("@kernel"), rker);
}

/* ----------------------------------------------------------------- */

static VALUE
rb_vi_s_allocate (VALUE klass)
{
  CAWindowIterator *it;
  return TypedData_Make_Struct(klass, CAWindowIterator, &cawindowiterator_data_type, it);
}

static VALUE
rb_vi_initialize (VALUE self, VALUE rker)
{
  CArray *ker;
  
  rb_check_carray_object(rker);
  TypedData_Get_Struct(rker, CArray, &carray_data_type, ker);
  if ( ker->obj_type != CA_OBJ_WINDOW ) {
    rb_raise(rb_eRuntimeError, "kernel must be CAWindow object");
  }

  ca_vi_setup(self, rb_ca_parent(rker), rker);

  return Qnil;
}

static VALUE
rb_vi_initialize_copy (VALUE self, VALUE other)
{
  ca_vi_setup(self, rb_ivar_get(other, rb_intern("@reference")),
              rb_ivar_get(other, rb_intern("@kernel")));
  return self;
}

void
Init_ca_iter_window ()
{
  rb_cCAWindowIterator = rb_define_class("CAWindowIterator", rb_cCAIterator);
  rb_define_const(rb_cCAWindowIterator, "UNIFORM_KERNEL", Qtrue);

  rb_define_alloc_func(rb_cCAWindowIterator, rb_vi_s_allocate);
  rb_define_method(rb_cCAWindowIterator, "initialize", rb_vi_initialize, 1);
  rb_define_method(rb_cCAWindowIterator, "initialize_copy",
                            rb_vi_initialize_copy, 1);
}

