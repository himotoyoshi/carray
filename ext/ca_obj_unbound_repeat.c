/* ---------------------------------------------------------------------------

  CAUnboundRepeat — a CAStride subclass representing the "shape
  pending" broadcast view.  Each `:*` axis becomes a size-1 stride-0
  entry in the CAStride prefix; each sized axis inherits the parent's
  contiguous byte stride.  The original spec is preserved in the
  rep_dim[] tail (0 = `*`, n = sized) so #spec / #bind / #bind_with /
  #shave observe the user's original layout.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */
#include "ca_obj_face.h"  /* CA_FACE_LIFT_IF_FACE */

extern ca_operation_function_t ca_stride_func;

VALUE rb_cCAUnboundRepeat;
VALUE rb_cCAUnboundRepeatMask;

/* Filled in by Init_ca_obj_unbound_repeat as `ca_stride_func` plus
   custom free / clone / create_mask. */
ca_operation_function_t ca_ubrep_func;

static size_t
ca_ubrep_dsize (const void *ap)
{
  const CAUnboundRepeat *ca = (const CAUnboundRepeat *) ap;
  /* dim + strides + rep_dim, each ndim cells (legacy ALLOC_N x3 or one
     framework-managed _pool buffer; same byte total). */
  return sizeof(CAUnboundRepeat) + 3 * ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks (CABlock pattern: CAStride base + one extra
   tail).  The view ndim equals rep_ndim, so dim, strides and rep_dim
   are all ndim-sized.  CAREFUL: dim/strides must stay at CAStride
   base offsets (0, n) so ca_stride_setup's pool branch finds them;
   the rep_dim tail follows at 2n. */
static size_t
ca_ubrep_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return 3 * (size_t) n * sizeof(ca_size_t);
}

static void
ca_ubrep_pool_init (void *ap, int8_t ndim)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_size_t        n  = (ndim > 0) ? ndim : 1;
  ca_size_t       *base = (ca_size_t *) ca->_pool;
  ca->dim     = base + 0 * n;   /* CAStride prefix */
  ca->strides = base + 1 * n;   /* CAStride prefix */
  ca->rep_dim = base + 2 * n;   /* CAUnboundRepeat tail */
}

const rb_data_type_t caunboundrepeat_data_type = {
    .parent = &castride_data_type,
    .wrap_struct_name = "CAUnboundRepeat",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_ubrep_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t caunboundrepeat_mask_data_type = {
    .parent = &caunboundrepeat_data_type,
    .wrap_struct_name = "CAUnboundRepeatMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_ubrep_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

int
ca_ubrep_setup (CAUnboundRepeat *ca, CArray *parent,
                int32_t rep_ndim, ca_size_t *rep_dim)
{
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  ca_size_t newdim[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  int8_t data_ndim = 0;
  int8_t i, j;

  CA_CHECK_RANK(rep_ndim);

  /* parent_byte_stride[k] = bytes * Π_{i>k} parent->dim[i].  Only the
     [0, parent->ndim) entries are touched; the array is private to this
     setup call. */
  {
    ca_size_t s = parent->bytes;
    for (i = parent->ndim - 1; i >= 0; i--) {
      parent_byte_stride[i] = s;
      s *= parent->dim[i];
    }
  }

  j = 0;
  for (i = 0; i < rep_ndim; i++) {
    if (rep_dim[i] == 0) {
      /* `*` (unbound) axis: size 1 placeholder, stride 0. */
      newdim[i]  = 1;
      strides[i] = 0;
    }
    else {
      if (j >= parent->ndim) {
        rb_raise(rb_eArgError,
                 "too many sized axes for parent of ndim %d",
                 (int) parent->ndim);
      }
      if (rep_dim[i] != parent->dim[j]) {
        rb_raise(rb_eArgError,
                 "mismatch in entity dim at axis %d (%lld vs parent %lld)",
                 (int) i,
                 (long long) rep_dim[i], (long long) parent->dim[j]);
      }
      newdim[i]  = parent->dim[j];
      strides[i] = parent_byte_stride[j];
      data_ndim += 1;
      j++;
    }
  }
  if (data_ndim != parent->ndim) {
    rb_raise(rb_eArgError,
             "mismatch in number of sized axes (%d for parent ndim %d)",
             (int) data_ndim, (int) parent->ndim);
  }

  /* CAREFUL: initialise the rep_dim tail before ca_stride_setup.
     ca_stride_setup may call ca_create_mask when the parent has a
     mask, which dispatches into ca_ubrep_func_create_mask — and that
     reads ca->rep_dim. */
  if ( ! ca->_pool ) {
    ca->rep_dim = ALLOC_N(ca_size_t, rep_ndim > 0 ? rep_ndim : 1);
  }
  for (i = 0; i < rep_ndim; i++) {
    ca->rep_dim[i] = rep_dim[i];
  }

  ca_stride_setup((CAStride *) ca, CA_OBJ_UNBOUND_REPEAT, parent,
                  parent->data_type, parent->bytes,
                  (int8_t) rep_ndim, newdim, strides, 0);

  return 0;
}

CAUnboundRepeat *
ca_ubrep_new (CArray *parent, int32_t rep_ndim, ca_size_t *rep_dim)
{
  CAUnboundRepeat *ca =
      (CAUnboundRepeat *) ca_array_alloc(CA_OBJ_UNBOUND_REPEAT, (int8_t) rep_ndim);
  ca_ubrep_setup(ca, parent, rep_ndim, rep_dim);
  return ca;
}

static void
free_ca_ubrep (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  if (ca == NULL) return;
  ca_free(ca->mask);
  if (ca->_pool) {
    /* dim/strides/rep_dim all live in ca->_pool. */
    ca_array_free(ca);
  }
  else {
    xfree(ca->rep_dim);
    xfree(ca->strides);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
ca_ubrep_func_clone (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  return ca_ubrep_new(ca->parent, ca->ndim, ca->rep_dim);
}

static void
ca_ubrep_func_create_mask (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_update_mask(ca->parent);
  if (!ca->parent->mask) {
    ca_create_mask(ca->parent);
  }
  ca->mask =
    (CArray *) ca_ubrep_new(ca->parent->mask, ca->ndim, ca->rep_dim);
}

/* ------------------------------------------------------------------- */

/* rb_ca_rewrap_unbound_repeat(src, out) — when src is an unresolved
 * CAUnboundRepeat, re-wrap out so the result carries the same `*`
 * markers; otherwise return out unchanged.  Called from the unary /
 * binary operator and math paths so downstream `.bind` / `.bind_with`
 * on the operator result still see the `*` axes. */
VALUE
rb_ca_rewrap_unbound_repeat (VALUE src, VALUE out)
{
  CArray *ca;
  CAUnboundRepeat *cx;
  TypedData_Get_Struct(src, CArray, &carray_data_type, ca);
  if (ca->obj_type != CA_OBJ_UNBOUND_REPEAT) return out;
  cx = (CAUnboundRepeat *) ca;
  return rb_ca_ubrep_new(rb_ca_ubrep_shave(src, out), cx->ndim, cx->rep_dim);
}

VALUE
rb_ca_ubrep_shave (VALUE self, VALUE other)
{
  CAUnboundRepeat *ca;
  CArray *co;
  int8_t ndim, i;
  ca_size_t dim[CA_RANK_MAX];

  rb_check_carray_object(self);
  rb_check_carray_object(other);

  TypedData_Get_Struct(self, CAUnboundRepeat, &caunboundrepeat_data_type, ca);
  TypedData_Get_Struct(other, CArray, &carray_data_type, co);

  if (ca->elements != co->elements) {
    rb_raise(rb_eRuntimeError, "mismatch in # of elements");
  }

  ndim = 0;
  for (i = 0; i < ca->ndim; i++) {
    if (ca->rep_dim[i]) {
      dim[ndim] = ca->rep_dim[i];
      ndim += 1;
    }
  }

  return rb_ca_refer_new(other, co->data_type, ndim, dim, co->bytes, 0);
}

VALUE
rb_ca_ubrep_new (VALUE cary, int32_t rep_ndim, ca_size_t *rep_dim)
{
  volatile VALUE obj;
  CArray *parent;
  CAUnboundRepeat *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca = ca_ubrep_new(parent, rep_ndim, rep_dim);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

VALUE
rb_ca_unbound_repeat (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  int8_t ndim;
  int32_t rep_ndim;
  ca_size_t rep_dim[CA_RANK_MAX];
  ca_size_t elements, count, i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  rep_ndim = argc;

  count = 0;
  ndim  = 0;
  elements = 1;
  for (i = 0; i < rep_ndim; i++) {
    if (TYPE(argv[i]) == T_SYMBOL) {
      if (argv[i] == ID2SYM(rb_intern("*"))) {
        rep_dim[i] = 0;
      }
      else {
        rb_raise(rb_eArgError, "unknown symbol (!= ':*') in arguments");
      }
    }
    else {
      if (!NIL_P(argv[i])) {
        rb_raise(rb_eArgError, "invalid argument");
      }
      rep_dim[i] = ca->dim[count];
      elements  *= ca->dim[count];
      count++; ndim++;
    }
  }

  if (elements != ca->elements) {
    rb_raise(rb_eArgError, "mismatch in entity elements (%lli for %lli)",
             (long long) elements, (long long) ca->elements);
  }

  if (ndim != ca->ndim) {
    rb_raise(rb_eArgError, "invalid number of nil's (%i for %i)",
             (int) ndim, (int) ca->ndim);
  }

  {
    VALUE obj = rb_ca_ubrep_new(self, rep_ndim, rep_dim);
    CA_FACE_LIFT_IF_FACE(obj, self, ca);
    return obj;
  }
}

static VALUE
rb_ca_ubrep_s_allocate (VALUE klass)
{
  CAUnboundRepeat *ca;
  return TypedData_Make_Struct(klass, CAUnboundRepeat,
                               &caunboundrepeat_data_type, ca);
}

static VALUE
rb_ca_ubrep_initialize_copy (VALUE self, VALUE other)
{
  CAUnboundRepeat *ca, *cs;

  TypedData_Get_Struct(self,  CAUnboundRepeat, &caunboundrepeat_data_type, ca);
  TypedData_Get_Struct(other, CAUnboundRepeat, &caunboundrepeat_data_type, cs);

  if ( ca_func[CA_OBJ_UNBOUND_REPEAT].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_UNBOUND_REPEAT, cs->ndim);
  }
  ca_ubrep_setup(ca, cs->parent, cs->ndim, cs->rep_dim);

  return self;
}

VALUE
ca_ubrep_bind2 (VALUE self, int32_t new_ndim, ca_size_t *new_dim)
{
  CAUnboundRepeat *ca;
  ca_size_t rep_spec[CA_RANK_MAX];
  ca_size_t upr_spec[CA_RANK_MAX];
  ca_size_t srp_spec[CA_RANK_MAX];
  int uprep = 0, srp_ndim;
  int ndim_real;
  int i;

  TypedData_Get_Struct(self, CAUnboundRepeat, &caunboundrepeat_data_type, ca);

  if (ca->ndim != new_ndim) {
    rb_raise(rb_eArgError, "invalid new_ndim (%i <-> %i)",
             (int) ca->ndim, (int) new_ndim);
  }

  srp_ndim = 0;
  ndim_real = 0;
  for (i = 0; i < new_ndim; i++) {
    if (ca->rep_dim[i] == 0) {
      if (new_dim[i] == 0) {
        uprep = 1;
      }
      else {
        srp_spec[srp_ndim++] = new_dim[i];
      }
      rep_spec[i] = new_dim[i];
      upr_spec[i] = new_dim[i];
    }
    else {
      ndim_real++;
      rep_spec[i] = 0;
      srp_spec[srp_ndim++] = 0;
      upr_spec[i] = ca->rep_dim[i];
    }
  }

  if (uprep) {
    volatile VALUE rep;
    if (srp_ndim >= ndim_real) {
      rep = rb_ca_repeat_new(rb_ca_parent(self), srp_ndim, srp_spec);
    }
    else {
      rep = rb_ca_parent(self);
    }
    return rb_ca_ubrep_new(rep, new_ndim, upr_spec);
  }
  else {
    return rb_ca_repeat_new(rb_ca_parent(self), new_ndim, rep_spec);
  }
}

/* CAUnboundRepeat#bind_with(other) — bind `*` axes to shape borrowed
 * from `other` (CArray, another CAUnboundRepeat, or a scalar). */
VALUE
ca_ubrep_bind_with (VALUE self, VALUE other)
{
  CAUnboundRepeat *cup;
  CArray *co;

  rb_check_carray_object(other);

  TypedData_Get_Struct(other, CArray, &carray_data_type, co);

  if (co->obj_type == CA_OBJ_UNBOUND_REPEAT) {
    TypedData_Get_Struct(other, CAUnboundRepeat,
                         &caunboundrepeat_data_type, cup);
    return ca_ubrep_bind2(self, cup->ndim, cup->rep_dim);
  }
  else if (ca_is_scalar(co)) {
    return self;
  }
  else {
    return ca_ubrep_bind2(self, co->ndim, co->dim);
  }
}

/* CAUnboundRepeat#bind(*sizes) (alias broadcast_to) — bind each `*`
 * axis to an explicit size and return the resulting CARepeat view. */
static VALUE
rb_ca_ubrep_bind (int argc, VALUE *argv, VALUE self)
{
  CAUnboundRepeat *ca;
  ca_size_t rep_spec[CA_RANK_MAX];
  int i;

  TypedData_Get_Struct(self, CAUnboundRepeat, &caunboundrepeat_data_type, ca);

  if (ca->ndim != argc) {
    rb_raise(rb_eArgError, "invalid new_ndim");
  }

  for (i = 0; i < argc; i++) {
    if (ca->rep_dim[i] == 0) {
      rep_spec[i] = NUM2SIZE(argv[i]);
    }
    else {
      rep_spec[i] = 0;
    }
  }

  return rb_ca_repeat_new(rb_ca_parent(self), argc, rep_spec);
}

static VALUE
rb_ca_ubrep_spec (VALUE self)
{
  volatile VALUE spec;
  CAUnboundRepeat *ca;
  int i;

  TypedData_Get_Struct(self, CAUnboundRepeat, &caunboundrepeat_data_type, ca);

  spec = rb_ary_new2(ca->ndim);
  for (i = 0; i < ca->ndim; i++) {
    if (ca->rep_dim[i]) {
      rb_ary_store(spec, i, SIZE2NUM(ca->rep_dim[i]));
    }
    else {
      rb_ary_store(spec, i, ID2SYM(rb_intern("*")));
    }
  }

  return spec;
}

void
Init_ca_obj_unbound_repeat (void)
{
  /* rb_cCAUnboundRepeat, CA_OBJ_UNBOUND_REPEAT are defined in
     ruby_carray.c / carray.h.  Build the custom op table by copying
     ca_stride_func and overriding only the slots that need to know
     about the rep_dim tail (free + clone + create_mask). */
  ca_ubrep_func = ca_stride_func;
  ca_ubrep_func.free_object = free_ca_ubrep;
  ca_ubrep_func.clone       = ca_ubrep_func_clone;
  ca_ubrep_func.create_mask = ca_ubrep_func_create_mask;
  /* CAUnboundRepeat owns 3*ndim cells (dim/strides + rep_dim); override the
     2*ndim CAStride base pool hooks and the struct_size so ca_array_alloc
     reserves room for the rep_dim tail too. */
  ca_ubrep_func.struct_size = sizeof(CAUnboundRepeat);
  ca_ubrep_func.pool_bytes  = ca_ubrep_pool_bytes;
  ca_ubrep_func.pool_init   = ca_ubrep_pool_init;
  ca_func[CA_OBJ_UNBOUND_REPEAT] = ca_ubrep_func;

  rb_define_const(rb_cObject, "CA_OBJ_UNBOUND_REPEAT",
                                                 INT2NUM(CA_OBJ_UNBOUND_REPEAT));

  rb_define_method(rb_cCArray, "unbound_repeat", rb_ca_unbound_repeat, -1);

  rb_define_alloc_func(rb_cCAUnboundRepeat, rb_ca_ubrep_s_allocate);
  rb_define_method(rb_cCAUnboundRepeat, "initialize_copy",
                                      rb_ca_ubrep_initialize_copy, 1);

  rb_define_method(rb_cCAUnboundRepeat, "bind", rb_ca_ubrep_bind, -1);
  rb_define_alias(rb_cCAUnboundRepeat, "broadcast_to", "bind");
  rb_define_method(rb_cCAUnboundRepeat, "bind_with", ca_ubrep_bind_with, 1);
  rb_define_method(rb_cCAUnboundRepeat, "spec", rb_ca_ubrep_spec, 0);
}
