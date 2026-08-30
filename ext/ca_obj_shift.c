/* ---------------------------------------------------------------------------

  CAShift is a pure typedef of CAWindow (see carray.h).  CAShift
  construction maps (shift[], roll[], fill, fill_mask) onto CAWindow's
  (start = -shift, count = parent->dim, bounds = roll ? PERIODIC :
  (fill_mask ? MASK : FILL), fill) via ca_window_setup, then bumps
  obj_type to CA_OBJ_SHIFT.  Operations (attach / sync / copy_data /
  sync_data / fill_data / ptr_at_* / fetch_index / store_index) are
  shared with CAWindow's per-axis bounds engine via the `ca_shift_func`
  table, which is built by copying `ca_window_func` and only overriding
  free / clone / create_mask so that CAShift-typed instances are produced
  on cloning and mask-projection.

  User surface (CArray#shift) is documented in yard-stubs/ca_obj_shift.rb.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"  /* CA_FACE_LIFT_IF_FACE */

/* External: CAWindow's operation table + setup are the basis for CAShift. */
extern ca_operation_function_t ca_window_func;
extern VALUE rb_cCAWindow;
extern int ca_window_setup (CAWindow *ca, CArray *parent,
                            ca_size_t *start, ca_size_t *count,
                            uint8_t *bounds, char *fill);

/* CAShift dsize: same formula as CAWindow (the structs share layout).
   CAREFUL: forward-declared so the const rb_data_type_t initialisers
   below can reference it.  Patching dsize into the table in Init via a
   (rb_data_type_t *) cast would write into .rodata and SIGBUS on macOS. */
static size_t ca_shift_dsize (const void *ap);

const rb_data_type_t cashift_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAShift",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_shift_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* CAREFUL: mask TypedData uses ca_free_nop.  The mask CArray is owned
   by the parent CAShift's `ca->mask` field and freed by free_ca_shift's
   ca_free(ca->mask).  If the wrapped Ruby VALUE (from the `ca.mask`
   accessor / rb_ca_mask_array) also freed it, the result is a
   double-free that explodes under GC stress. */
const rb_data_type_t cashift_mask_data_type = {
    .parent = &cashift_data_type,
    .wrap_struct_name = "CAShiftMask",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free_nop,
        .dsize = ca_shift_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_SHIFT;

VALUE rb_cCAShift;
VALUE rb_cCAShiftMask;

/* Custom op table for CAShift — populated in Init from ca_window_func. */
static ca_operation_function_t ca_shift_func;

/* CAShift dsize: same formula as CAWindow (same struct layout). */
static size_t
ca_shift_dsize (const void *ap)
{
  const CAShift *ca = (const CAShift *) ap;
  return sizeof(CAShift) + 3 * ca->ndim * sizeof(ca_size_t)
       + ca->ndim * sizeof(uint8_t) + ca->bytes;
}

/* ------------------------------------------------------------------- */

int
ca_shift_setup (CAShift *ca, CArray *parent,
                ca_size_t *shift, char *fill, int8_t *roll, int fill_mask)
{
  ca_size_t start[CA_RANK_MAX];
  ca_size_t count[CA_RANK_MAX];
  uint8_t   bounds[CA_RANK_MAX];
  int8_t k, ndim;

  ndim = parent->ndim;
  CA_ASSUME(ndim >= 0 && ndim <= CA_RANK_MAX);   /* bound loop over [CA_RANK_MAX] arrays */
  for (k = 0; k < ndim; k++) {
    start[k] = -shift[k];
    count[k] = parent->dim[k];
    if ( roll[k] ) {
      bounds[k] = CA_BOUNDS_PERIODIC;
    } else if ( fill_mask ) {
      bounds[k] = CA_BOUNDS_MASK;
    } else {
      bounds[k] = CA_BOUNDS_FILL;
    }
  }

  /* Delegate to CAWindow setup. */
  ca_window_setup((CAWindow *) ca, parent, start, count, bounds, fill);

  /* Override obj_type so dispatch (ca_func[obj_type]) lands on the
     CAShift-specific table (which differs from CAWindow only in
     free / clone / create_mask, all forwarding to a CAShift-typed
     result). */
  ca->obj_type = CA_OBJ_SHIFT;

  return 0;
}

CAShift *
ca_shift_new (CArray *parent, ca_size_t *shift, char *fill, int8_t *roll,
              int fill_mask)
{
  CAShift *ca = (CAShift *) ca_array_alloc(CA_OBJ_SHIFT, parent->ndim);
  ca_shift_setup(ca, parent, shift, fill, roll, fill_mask);
  return ca;
}

/* Free: same fields as CAWindow (same struct).  CAShift goes through
   ca_window_setup, so the same seven ndim-sized fields live in ca->_pool
   (fill stays separate). */
static void
free_ca_shift (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->fill);              /* always separate (bytes-sized) */
    if ( ca->_pool ) {
      ca_array_free(ca);
    }
    else {
      xfree(ca->bounds);
      xfree(ca->start);
      xfree(ca->count);
      xfree(ca->size0);
      xfree(ca->embed_parent_start);
      xfree(ca->embed_count);
      xfree(ca->embed_output_offset);
      xfree(ca);
    }
  }
}

/* Clone: produce a CAShift (not CAWindow) by rebuilding via setup.
   Recover (shift[], roll[], fill_mask) from current (start[], bounds[]). */
static void *
ca_shift_func_clone (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  ca_size_t shift[CA_RANK_MAX];
  int8_t   roll[CA_RANK_MAX];
  int fill_mask = 0;
  int8_t k;

  /* shift[k] = -start[k] (inverse of setup's start = -shift) */
  for (k = 0; k < ca->ndim; k++) {
    shift[k] = -ca->start[k];
    if ( ca->bounds[k] == CA_BOUNDS_PERIODIC ) {
      roll[k] = 1;
    } else {
      roll[k] = 0;
      if ( ca->bounds[k] == CA_BOUNDS_MASK ) fill_mask = 1;
    }
  }

  return ca_shift_new(ca->parent, shift, ca->fill, roll, fill_mask);
}

/* create_mask: produce a CAShift-typed mask (not CAWindow-typed).
   Following the original ca_shift_func_create_mask semantics:
   - Ensure parent has mask
   - Build mask sub-view using same shift/roll, fill = 1 if fill_mask
     else 0 (i.e. range-outside cells get masked when fill_mask was on,
     unmasked otherwise) */
static void
ca_shift_func_create_mask (void *ap)
{
  CAShift *ca = (CAShift *) ap;
  ca_size_t shift[CA_RANK_MAX];
  int8_t   roll[CA_RANK_MAX];
  boolean8_t fill_val;
  int fill_mask_was_on = 0;
  int8_t k;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  for (k = 0; k < ca->ndim; k++) {
    shift[k] = -ca->start[k];
    if ( ca->bounds[k] == CA_BOUNDS_PERIODIC ) {
      roll[k] = 1;
    } else {
      roll[k] = 0;
      if ( ca->bounds[k] == CA_BOUNDS_MASK ) fill_mask_was_on = 1;
    }
  }

  /* If MASK policy was set, the mask sub-view should mark out-of-range
     cells as "masked" (fill value = 1).  Otherwise out-of-range cells
     get the fill value (fill = 0) and aren't masked. */
  fill_val = fill_mask_was_on ? 1 : 0;

  /* Build the mask as CAShift with same shift/roll but using fill_mask=0
     (the mask itself shouldn't recursively create a mask) and fill = 0/1
     boolean.  Bounds for mask: replace MASK→FILL so the mask values are
     written, not the mask's mask. */
  {
    /* Construct mask via direct ca_window_new with adjusted bounds. */
    uint8_t mbounds[CA_RANK_MAX];
    ca_size_t mstart[CA_RANK_MAX];
    ca_size_t mcount[CA_RANK_MAX];
    CAShift *m;
    CA_ASSUME(ca->ndim >= 0 && ca->ndim <= CA_RANK_MAX);   /* bound loop over [CA_RANK_MAX] arrays */
    for (k = 0; k < ca->ndim; k++) {
      mstart[k] = ca->start[k];
      mcount[k] = ca->count[k];
      mbounds[k] = ( ca->bounds[k] == CA_BOUNDS_MASK )
                       ? CA_BOUNDS_FILL : ca->bounds[k];
    }
    /* CAShift-typed mask: allocate, setup as CAWindow with adjusted
       bounds, bump obj_type. */
    m = (CAShift *) ca_array_alloc(CA_OBJ_SHIFT, ca->ndim);
    ca_window_setup((CAWindow *) m, ca->parent->mask,
                    mstart, mcount, mbounds, (char *) &fill_val);
    m->obj_type = CA_OBJ_SHIFT;
    ca->mask = (CArray *) m;
  }
  (void) shift; (void) roll;   /* recovered above but unused in this block */
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_shift_new (VALUE cary, ca_size_t *shift, char *fill, int8_t *roll,
                 int fill_mask)
{
  volatile VALUE obj;
  CArray *parent;
  CAShift *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca = ca_shift_new(parent, shift, fill, roll, fill_mask);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* CArray#shift(*shifts, fill_value:) — returns a CAShift view translated
 * by `shifts` along each axis (one shift per dimension).
 *
 * Out-of-range cells take fill_value (default 0); fill_value: UNDEF masks
 * them instead.  Raises ArgumentError on argument-count mismatch, on the
 * removed :roll option, and on the removed block form. */
VALUE
rb_ca_shift (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ropt, rfval = CA_NIL, rroll = Qnil, rcs;
  CArray *ca;
  CScalar *cs;
  ca_size_t shift[CA_RANK_MAX];
  int8_t roll[CA_RANK_MAX];
  char *fill = NULL;
  int fill_mask = 0;
  int8_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  ropt = rb_pop_options(&argc, &argv);
  rb_scan_options(ropt, "roll,fill_value", &rroll, &rfval);

  /* The :roll option was removed in 3.0.  Cyclic shift is now CArray#roll
     (returns a CARoll view, ca_obj_roll.c).  Mixed per-axis roll is
     expressed via chain: a.roll(1, 0) followed by .shift(...). */
  if ( ! NIL_P(rroll) ) {
    rb_raise(rb_eArgError,
             "shift: :roll option removed in 3.0; "
             "use CArray#roll(...) for cyclic shift (returns CARoll view)");
  }

  if ( argc != ca->ndim ) {
    rb_raise(rb_eArgError, "# of arguments mismatch with ndim");
  }

  for (i=0; i<ca->ndim; i++) {
    shift[i] = NUM2SIZE(argv[i]);
  }

  if ( rb_block_given_p() ) {
    rb_raise(rb_eArgError,
             "shift: block form for fill value removed in 3.0; "
             "use fill_value: kwarg (e.g. shift(1, fill_value: -2))");
  }

  if ( rfval == CA_NIL ) {
    /* Default fill value = 0 (or INT2NUM(0) for OBJECT type) */
    rcs = rb_cscalar_new(ca->data_type, ca->bytes, NULL);
    TypedData_Get_Struct(rcs, CScalar, &cscalar_data_type, cs);
    fill = cs->ptr;
    if ( ca_is_object_type(ca) ) {
      *(VALUE *)fill = INT2NUM(0);
    }
    else {
      memset(fill, 0, cs->bytes);
    }
  }
  else if ( rfval == CA_UNDEF ) {
    /* Range-outside cells should be masked, not value-filled. */
    fill = NULL;
    fill_mask = 1;
  }
  else {
    rcs = rb_cscalar_new_with_value(ca->data_type, ca->bytes, rfval);
    TypedData_Get_Struct(rcs, CScalar, &cscalar_data_type, cs);
    fill = cs->ptr;
  }

  if ( NIL_P(rroll) ) {
    for (i=0; i<ca->ndim; i++) {
      roll[i] = 0;
    }
  }
  else {
    Check_Type(rroll, T_ARRAY);

    if ( RARRAY_LEN(rroll) != ca->ndim ) {
      rb_raise(rb_eArgError, "# of arguments mismatch with ndim");
    }

    for (i=0; i<ca->ndim; i++) {
      roll[i] = NUM2INT(rb_ary_entry(rroll, i));
    }
  }

  obj = rb_ca_shift_new(self, shift, fill, roll, fill_mask);

  CA_WRAPPER_LIFT(obj, self, ca);
  return obj;
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_shift_s_allocate (VALUE klass)
{
  CAShift *ca;
  return TypedData_Make_Struct(klass, CAShift, &cashift_data_type, ca);
}

static VALUE
rb_ca_shift_initialize_copy (VALUE self, VALUE other)
{
  CAShift *ca, *cs;
  ca_size_t shift[CA_RANK_MAX];
  int8_t   roll[CA_RANK_MAX];
  int fill_mask = 0;
  int8_t k;

  TypedData_Get_Struct(self,  CAShift, &cashift_data_type, ca);
  TypedData_Get_Struct(other, CAShift, &cashift_data_type, cs);

  /* Recover shift/roll/fill_mask from cs (same scheme as clone). */
  for (k = 0; k < cs->ndim; k++) {
    shift[k] = -cs->start[k];
    if ( cs->bounds[k] == CA_BOUNDS_PERIODIC ) {
      roll[k] = 1;
    } else {
      roll[k] = 0;
      if ( cs->bounds[k] == CA_BOUNDS_MASK ) fill_mask = 1;
    }
  }
  /* `self` came from rb_ca_shift_s_allocate (TypedData_Make_Struct,
     _pool == NULL).  Attach the pool before setup. */
  if ( ca_func[CA_OBJ_SHIFT].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_SHIFT, cs->ndim);
  }
  ca_shift_setup(ca, cs->parent, shift, cs->fill, roll, fill_mask);

  return self;
}

/* `shift!` removed in 3.0; the canonical in-place idiom is
   `ca[] = ca.shift(...)`.
   [MOVED] roll -> ext/ca_obj_roll.c (CARoll view). */

void
Init_ca_obj_shift (void)
{
  /* Build the CAShift op table by copying CAWindow's and overriding
     just the slots that need to produce CAShift-typed results. */
  ca_shift_func = ca_window_func;
  ca_shift_func.free_object = free_ca_shift;
  ca_shift_func.clone       = ca_shift_func_clone;
  ca_shift_func.create_mask = ca_shift_func_create_mask;

  rb_cCAShift = rb_define_class("CAShift", rb_cCAWindow);
  rb_cCAShiftMask = rb_define_class("CAShiftMask", rb_cCAShift);

  CA_OBJ_SHIFT = ca_install_obj_type(rb_cCAShift,
                                     &cashift_data_type,
                                     rb_cCAShiftMask,
                                     &cashift_mask_data_type, &ca_shift_func, sizeof(ca_shift_func));
  rb_define_const(rb_cObject, "CA_OBJ_SHIFT", INT2NUM(CA_OBJ_SHIFT));

  rb_define_method(rb_cCArray, "shift", rb_ca_shift, -1);
  /* "shift!" removed in 3.0; "roll" defined in Init_ca_obj_roll. */

  rb_define_alloc_func(rb_cCAShift, rb_ca_shift_s_allocate);
  rb_define_method(rb_cCAShift, "initialize_copy",
                                      rb_ca_shift_initialize_copy, 1);
}
