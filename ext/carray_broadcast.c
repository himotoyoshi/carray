/* ---------------------------------------------------------------------------

  Implicit broadcasting helpers and CArray#broadcast_to.

    ca_broadcast_view (src, ndim, target_dim)
        Wrap `src` in a CAStride view whose shape is `target_dim`,
        treating size-1 axes of `src` as broadcast (stride 0).
        Returns `src` unchanged when no expansion is needed.
        Called by ca_broadcast_pair below and by the binop dispatcher
        in ext/ca_obj_binop.c.

    ca_broadcast_pair (&self, &other)
        Two-sided expansion for binary ops (case A only: same ndim,
        size-1 axes broadcast pairwise).  Leaves both operands
        unchanged when shapes are already equal or when they are
        incompatible (the caller's existing elements-mismatch raise
        path then handles the error).  Called by carray_cast.c's
        coercion path and by the binop dispatcher.

    rb_ca_broadcast_to -- backs the public CArray#broadcast_to method
        (right-to-left axis pairing; see the docstring at the function).

  Case B (cross-ndim dim-prepending) is not handled by the implicit
  helpers; users with cross-ndim operands keep using the explicit :*
  form or #broadcast_to (which does accept cross-ndim with target axes
  pinned to size 1).  See PROPOSAL_BROADCASTING_AND_UNBOUND.md.

---------------------------------------------------------------------------- */

#include "carray.h"

/* Build a CAStride view of `src` with shape `target_dim`.  For each
   axis where src.dim[i] == target_dim[i], inherit the row-major byte
   stride; for src.dim[i] == 1 and target_dim[i] > 1, use stride 0.
   Otherwise, raise.  If no axis needs expansion, return src as-is. */
VALUE
ca_broadcast_view (VALUE src, int8_t ndim, ca_size_t *target_dim)
{
  CArray *cs;
  ca_size_t src_strides[CA_RANK_MAX];
  ca_size_t new_strides[CA_RANK_MAX];
  ca_size_t s;
  int needs_broadcast = 0;
  int i;
  CAStride *view;
  volatile VALUE obj;

  TypedData_Get_Struct(src, CArray, &carray_data_type, cs);

  if (cs->ndim != ndim) {
    rb_raise(rb_eRuntimeError,
             "broadcast: ndim mismatch (%d vs %d)",
             (int) cs->ndim, (int) ndim);
  }

  /* Row-major byte strides for src treated as contiguous.  When src is
     itself a CAStride, the compose-fold path at attach time collapses
     the chain to root, so passing parent-relative row-major strides
     is correct. */
  s = cs->bytes;
  for (i = ndim - 1; i >= 0; i--) {
    src_strides[i] = s;
    s *= cs->dim[i];
  }

  for (i = 0; i < ndim; i++) {
    if (cs->dim[i] == target_dim[i]) {
      new_strides[i] = src_strides[i];
    }
    else if (cs->dim[i] == 1) {
      new_strides[i] = 0;
      needs_broadcast = 1;
    }
    else {
      rb_raise(rb_eRuntimeError,
               "broadcast: cannot broadcast axis %d (%lld vs %lld)",
               i, (long long) cs->dim[i], (long long) target_dim[i]);
    }
  }

  if (!needs_broadcast) return src;

  view = ca_stride_new(CA_OBJ_STRIDE, cs,
                       cs->data_type, cs->bytes,
                       ndim, target_dim, new_strides, 0);
  ca_set_flag(view, CA_FLAG_READ_ONLY);
  if (view->mask) {
    ca_set_flag(view->mask, CA_FLAG_READ_ONLY);
  }
  obj = ca_wrap_struct(view);
  rb_ca_set_parent(obj, src);
  return obj;
}

/* Two-sided broadcast for binary ops (case A only).  When both
   operands are non-scalar with equal ndim and at least one axis pair
   is (1, N) / (N, 1) / (1, 1), wrap each in a CAStride with stride-0
   axes so the downstream iterator sees matched shapes.  If shapes are
   pairwise equal, no-op.  If any axis pair is incompatible (neither
   side is 1 nor equal), no-op (caller's existing element-count check
   raises). */
void
ca_broadcast_pair (volatile VALUE *self, volatile VALUE *other)
{
  CArray *ca, *cb;
  ca_size_t target_dim[CA_RANK_MAX];
  int can_broadcast = 1;
  int needs_broadcast = 0;
  int i;

  TypedData_Get_Struct(*self,  CArray, &carray_data_type, ca);
  TypedData_Get_Struct(*other, CArray, &carray_data_type, cb);

  if (ca_is_scalar(ca) || ca_is_scalar(cb)) return;
  if (ca->ndim != cb->ndim) return;
  if (ca->ndim == 0) return;

  for (i = 0; i < ca->ndim; i++) {
    if (ca->dim[i] == cb->dim[i]) {
      target_dim[i] = ca->dim[i];
    }
    else if (ca->dim[i] == 1) {
      target_dim[i] = cb->dim[i];
      needs_broadcast = 1;
    }
    else if (cb->dim[i] == 1) {
      target_dim[i] = ca->dim[i];
      needs_broadcast = 1;
    }
    else {
      can_broadcast = 0;
      break;
    }
  }

  if (!can_broadcast || !needs_broadcast) return;

  *self  = ca_broadcast_view(*self,  ca->ndim, target_dim);
  *other = ca_broadcast_view(*other, ca->ndim, target_dim);
}

/* CArray#broadcast_to(*newdim) -- pairs axes right-to-left:
     - source axis == target axis  -> data axis (inherit stride)
     - target axis == 1            -> size-1 collapse, source consumed
                                      only when it is also 1
     - source axis == 1            -> broadcast (stride 0, source
                                      consumed)
     - source exhausted, target 1  -> insert size-1 axis
     - otherwise                   -> RuntimeError

   Intentionally conservative on cross-ndim: prepended axes are only
   inserted as size-1.  Target > 1 on a prepended axis raises, in
   keeping with PROPOSAL_BROADCASTING_AND_UNBOUND.md's strict-ndim
   policy.

   Result is tagged CA_OBJ_REPEAT (CARepeat) rather than plain CAStride
   so introspection (`view.class`) surfaces the broadcast intent. */

static VALUE
rb_ca_broadcast_to (int argc, VALUE *argv, VALUE self)
{
  CArray *cs;
  ca_size_t target_dim[CA_RANK_MAX];
  ca_size_t new_strides[CA_RANK_MAX];
  ca_size_t src_strides[CA_RANK_MAX];
  ca_size_t s;
  int8_t target_ndim;
  int needs_view = 0;
  int t_idx, s_idx;
  int i;
  CAStride *view;
  volatile VALUE obj;

  TypedData_Get_Struct(self, CArray, &carray_data_type, cs);

  if (argc < 0 || argc > CA_RANK_MAX) {
    rb_raise(rb_eArgError, "broadcast_to: invalid number of dims (%d)", argc);
  }
  target_ndim = (int8_t) argc;

  if (target_ndim < cs->ndim) {
    rb_raise(rb_eRuntimeError,
             "broadcast_to: target ndim %d smaller than source ndim %d",
             (int) target_ndim, (int) cs->ndim);
  }

  for (i = 0; i < target_ndim; i++) {
    target_dim[i] = NUM2SIZE(argv[i]);
    if (target_dim[i] < 0) {
      rb_raise(rb_eArgError,
               "broadcast_to: negative dim at axis %d", i);
    }
  }

  /* CScalar source: build an all-stride-0 CARepeat view of any
     target shape.  Generalises the cross-ndim rule, which is strict
     for non-scalar sources (each source axis must pair with a target
     axis); for a scalar the natural extension is "any target shape,
     stride 0 everywhere". */
  if (ca_is_scalar(cs)) {
    for (i = 0; i < target_ndim; i++) {
      new_strides[i] = 0;
    }
    view = ca_stride_new(CA_OBJ_REPEAT, cs,
                         cs->data_type, cs->bytes,
                         target_ndim, target_dim, new_strides, 0);
    ca_set_flag(view, CA_FLAG_READ_ONLY);
    if (view->mask) {
      ca_set_flag(view->mask, CA_FLAG_READ_ONLY);
    }
    obj = ca_wrap_struct(view);
    rb_ca_set_parent(obj, self);
    return obj;
  }

  /* Row-major byte strides for source (interpreted as contiguous;
     compose-fold at attach time handles non-contiguous parents). */
  s = cs->bytes;
  for (i = cs->ndim - 1; i >= 0; i--) {
    src_strides[i] = s;
    s *= cs->dim[i];
  }

  /* Pair right-to-left.  s_idx tracks the next source axis to be
     consumed; -1 means source is exhausted. */
  t_idx = target_ndim - 1;
  s_idx = cs->ndim - 1;

  while (t_idx >= 0) {
    ca_size_t dd = target_dim[t_idx];
    ca_size_t sd = (s_idx >= 0) ? cs->dim[s_idx] : -1;

    if (sd == dd) {
      new_strides[t_idx] = src_strides[s_idx];
      s_idx--;
    }
    else if (dd == 1) {
      new_strides[t_idx] = 0;
      if (sd == 1) s_idx--;
      needs_view = 1;
    }
    else if (sd == 1) {
      new_strides[t_idx] = 0;
      s_idx--;
      needs_view = 1;
    }
    else {
      /* sd == -1 (source exhausted) with dd > 1, or sd > 1 with
         dd > 1 and not equal: cannot broadcast. */
      rb_raise(rb_eRuntimeError,
               "broadcast_to: cannot broadcast axis %d "
               "(source %s, target %lld)",
               t_idx,
               (sd < 0 ? "(exhausted)" : "non-1"),
               (long long) dd);
    }
    t_idx--;
  }

  if (s_idx >= 0) {
    rb_raise(rb_eRuntimeError,
             "broadcast_to: %d source axes left unmatched", s_idx + 1);
  }

  if (!needs_view) return self;

  view = ca_stride_new(CA_OBJ_REPEAT, cs,
                       cs->data_type, cs->bytes,
                       target_ndim, target_dim, new_strides, 0);
  ca_set_flag(view, CA_FLAG_READ_ONLY);
  if (view->mask) {
    ca_set_flag(view->mask, CA_FLAG_READ_ONLY);
  }
  obj = ca_wrap_struct(view);
  rb_ca_set_parent(obj, self);
  return obj;
}

void
Init_carray_broadcast (void)
{
  rb_define_method(rb_cCArray, "broadcast_to", rb_ca_broadcast_to, -1);
}
