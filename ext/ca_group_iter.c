/* ---------------------------------------------------------------------------

  Axis-group reduction surface: the `[]` type gate and CAGroupIterator.

  The apply path is C-level: the `[]` type gate that routes a CACategorical /
  AxisGroup index to the group path (vs ordinary selection), the
  CAGroupIterator construction and the :group reduce dispatch all live here.
  The classifier is CACategorical (`categorical` (lib/carray/categorical.rb)):
  a READONLY Face over narrow-uint codes; this surface consumes its codes / k
  / labels.  The value-independent metadata (AxisGroup spec derivation,
  GroupLabels) is Ruby (`axis_group` (lib/carray/axis_group.rb)) — it is not on
  the `[]` hot path and is plain O(ndim) metadata.

  Split summary:
    - ca_argv_has_group / rb_ca_fetch_group  : here (called by carray_access.c)
    - CAGroupIterator + the tier-1 reduction methods driving
      __axis_group_reduce__ : here
    - reduce_plan / bundle assembly / output-axis permutation (metadata) : Ruby
    - the O(N) compute kernel __axis_group_reduce__ : ca_axis_group.c

--------------------------------------------------------------------------- */

#include "carray.h"

/* lib/carray/axis_group.rb registers these classes here on first load (and
   loading is wired so that load happens as soon as any categorical exists —
   see autoload_base.rb).  Until then they stay Qnil and the [] type-gate scan
   short-circuits, so a normal index pays nothing (no kind_of on the hot
   path). */
static VALUE rb_cCategorical     = Qnil;
static VALUE rb_cAxisGroup       = Qnil;
static VALUE rb_cCAGroupIterator = Qnil;

static ID id_value, id_spec, id_axis_group, id_reduce_plan, id_parse_axis;
static ID id_axis_group_reduce, id_reshape, id_transpose, id_labels;

/* CArray.__register_axis_group_classes__(CACategorical, AxisGroup) — called
   from the top of lib/carray/axis_group.rb so the C type gate can recognise
   the classifier/spec types without triggering autoload on every [] call. */
static VALUE
rb_ca_register_axis_group_classes (VALUE klass, VALUE cat, VALUE ag)
{
  rb_cCategorical = cat;
  rb_cAxisGroup   = ag;
  rb_gc_register_address(&rb_cCategorical);
  rb_gc_register_address(&rb_cAxisGroup);
  return Qnil;
}

/* Cheap per-arg pre-filter + kind_of check.  Returns 1 if any arg is a
   CACategorical (one-shot slot) or an AxisGroup (pre-built spec) — the group
   apply path — and 0 otherwise.

   The two group-arg forms have different Ruby representations, so each gets a
   pre-filter that keeps ordinary indexing off the kind_of walk:

     - AxisGroup is a plain Ruby object (T_OBJECT).  The scalar index kinds
       (Integer / nil / Symbol / Range) are not T_OBJECT, so they cost only the
       RB_TYPE_P bit test.

     - CACategorical is a CArray (T_DATA) whose SURFACE data_type is CA_FIXLEN
       (its narrow-uint codes are the storage parent).  A plain fancy-index is a
       numeric CArray, so the cheap data_type read lets ordinary selection args
       skip the kind_of — only a fixlen CArray index pays it.

   Arming: the classes are registered by lib/carray/axis_group.rb.  We cannot
   pre-arm on categorical construction (CACategorical is a CArray, so routing
   its autoload through the axis-group file recurses when categorical.rb reopens
   the class), so the gate arms itself lazily the first time it sees a fixlen
   CArray index — the only thing a categorical can be, and never a real plain
   index.  That covers a categorical built via CACategorical.from_codes that
   never touched the axis-group file.  Scalar / range / integer indices never
   reach this branch, so they never trigger the require. */
int
ca_argv_has_group (int argc, VALUE *argv)
{
  int i;
  for ( i = 0; i < argc; i++ ) {
    VALUE a = argv[i];
    if ( RB_TYPE_P(a, T_OBJECT) ) {
      if ( ! NIL_P(rb_cAxisGroup) && rb_obj_is_kind_of(a, rb_cAxisGroup) ) {
        return 1;
      }
    }
    else if ( RB_TYPE_P(a, T_DATA)
              && rb_typeddata_is_kind_of(a, &carray_data_type) ) {
      CArray *ca = (CArray *) DATA_PTR(a);
      if ( ca->data_type == CA_FIXLEN ) {
        if ( NIL_P(rb_cCategorical) ) {
          rb_require("carray/axis_group");   /* lazily arm (registers) */
        }
        if ( ! NIL_P(rb_cCategorical) && rb_obj_is_kind_of(a, rb_cCategorical) ) {
          return 1;
        }
      }
    }
  }
  return 0;
}

/* Build a CAGroupIterator for `self[*argv]`.  Two entry forms:
     (A) one-shot   self[idx, nil, ...]  -> build the spec via axis_group(*argv)
     (B) pre-built  self[g]              -> g is already an AxisGroup spec
   Pre-condition: ca_argv_has_group(argc, argv) is true. */
VALUE
rb_ca_fetch_group (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE spec;

  if ( argc == 1 && ! NIL_P(rb_cAxisGroup)
       && rb_obj_is_kind_of(argv[0], rb_cAxisGroup) ) {
    spec = argv[0];
  }
  else {
    /* one-shot: raw CACategorical / nil slots -> build the spec (axis_group
       validates the slot layout = one slot per source axis). */
    spec = rb_funcallv(self, id_axis_group, argc, argv);
  }
  return rb_funcall(rb_cCAGroupIterator, rb_intern("__build__"), 2, self, spec);
}

/* --- CAGroupIterator -------------------------------------------------------

   A reduction dispatcher, not an array: it holds the source value + the
   AxisGroup spec and exposes the tier-1 reductions.  There is no to_ca / copy
   / materialise path — the grouping only exists as the reduction's argument. */

static VALUE
rb_ca_group_iter_build (VALUE klass, VALUE value, VALUE spec)
{
  VALUE obj = rb_obj_alloc(klass);
  rb_ivar_set(obj, id_value, value);
  rb_ivar_set(obj, id_spec,  spec);
  return obj;
}

static VALUE
rb_ca_group_iter_value (VALUE self)
{
  return rb_ivar_get(self, id_value);
}

static VALUE
rb_ca_group_iter_spec (VALUE self)
{
  return rb_ivar_get(self, id_spec);
}

static VALUE
rb_ca_group_iter_labels (int argc, VALUE *argv, VALUE self)
{
  VALUE spec = rb_ivar_get(self, id_spec);
  return rb_funcallv_kw(spec, id_labels, argc, argv, RB_PASS_CALLED_KEYWORDS);
}

/* Reduce the grouped result by `perm`/`squeeze` from the plan:
     result (= [K_total, *band]) -> reshape [*group_dims, *band]
                                  -> transpose to slot order (perm)
                                  -> squeeze the length-1 fused-band axes. */
static VALUE
group_iter_shape_output (VALUE result, VALUE group_dims, VALUE perm, VALUE squeeze)
{
  CArray *cr;
  VALUE   dims[CA_RANK_MAX];
  VALUE   pargv[CA_RANK_MAX];
  long    ng, nband, nd, i;

  GetCArray(result, cr);

  /* reshape target = group_dims ++ result.shape[1..] (drop leading K_total) */
  ng    = RARRAY_LEN(group_dims);
  nband = cr->ndim - 1;
  nd    = ng + nband;
  if ( nd > CA_RANK_MAX ) {
    rb_raise(rb_eRuntimeError, "axis_group: output ndim %ld too large", nd);
  }
  for ( i = 0; i < ng; i++ ) {
    dims[i] = RARRAY_AREF(group_dims, i);
  }
  for ( i = 0; i < nband; i++ ) {
    dims[ng + i] = SIZE2NUM(cr->dim[i + 1]);
  }
  result = rb_funcall2(result, id_reshape, (int) nd, dims);

  /* transpose to slot order */
  for ( i = 0; i < nd; i++ ) {
    pargv[i] = RARRAY_AREF(perm, i);
  }
  result = rb_funcall2(result, id_transpose, (int) nd, pargv);

  /* squeeze the fused (length-1) band slots */
  if ( RARRAY_LEN(squeeze) > 0 ) {
    char drop[CA_RANK_MAX];
    VALUE keep[CA_RANK_MAX];
    long  nkeep = 0, j;
    GetCArray(result, cr);
    for ( i = 0; i < cr->ndim; i++ ) drop[i] = 0;
    for ( j = 0; j < RARRAY_LEN(squeeze); j++ ) {
      long s = NUM2LONG(RARRAY_AREF(squeeze, j));
      if ( s >= 0 && s < cr->ndim ) drop[s] = 1;
    }
    for ( i = 0; i < cr->ndim; i++ ) {
      if ( ! drop[i] ) keep[nkeep++] = SIZE2NUM(cr->dim[i]);
    }
    result = rb_funcall2(result, id_reshape, (int) nkeep, keep);
  }
  return result;
}

/* Shared driver for every tier-1 reduction.  The op is read from the called
   method name (rb_frame_this_func), so the 10 white-list names all bind here.
   axis: absent / no :group  -> delegate to the value's plain same-named
   reduction (grouping NOT engaged).  axis: contains :group -> group reduction
   (+ any integer band axes folded into the statistic). */
static VALUE
group_iter_reduce (int argc, VALUE *argv, VALUE self)
{
  ID    op_id  = rb_frame_this_func();
  VALUE op_sym = ID2SYM(op_id);
  VALUE value  = rb_ivar_get(self, id_value);
  VALUE spec   = rb_ivar_get(self, id_spec);
  VALUE kw = Qnil, vaxis;
  VALUE parsed, plan;
  VALUE group_axes, bundles, group_dims, perm, squeeze, fused;
  VALUE result;

  rb_scan_args(argc, argv, "0:", &kw);
  vaxis = NIL_P(kw)
          ? Qundef
          : rb_hash_lookup2(kw, ID2SYM(rb_intern("axis")), Qundef);

  /* (has_group, fused_band_slots) */
  parsed = rb_funcall(rb_cAxisGroup, id_parse_axis,
                      1, (vaxis == Qundef) ? Qnil : vaxis);
  if ( RTEST(RARRAY_AREF(parsed, 0)) == 0 ) {
    /* no :group -> plain reduction on the value (grouping not engaged) */
    if ( vaxis == Qundef ) {
      return rb_funcall(value, op_id, 0);
    }
    else {
      VALUE h = rb_hash_new();
      rb_hash_aset(h, ID2SYM(rb_intern("axis")), vaxis);
      return rb_funcallv_kw(value, op_id, 1, &h, RB_PASS_KEYWORDS);
    }
  }

  /* group reduction */
  fused = RARRAY_AREF(parsed, 1);
  plan  = rb_funcall(spec, id_reduce_plan, 1, fused);
  group_axes = RARRAY_AREF(plan, 0);
  bundles    = RARRAY_AREF(plan, 1);
  group_dims = RARRAY_AREF(plan, 2);
  perm       = RARRAY_AREF(plan, 3);
  squeeze    = RARRAY_AREF(plan, 4);

  result = rb_funcall(value, id_axis_group_reduce, 3,
                      group_axes, bundles, op_sym);
  return group_iter_shape_output(result, group_dims, perm, squeeze);
}

void
Init_ca_group_iter (void)
{
  id_value             = rb_intern("@value");
  id_spec              = rb_intern("@spec");
  id_axis_group        = rb_intern("axis_group");
  id_reduce_plan       = rb_intern("reduce_plan");
  id_parse_axis        = rb_intern("parse_axis");
  id_axis_group_reduce = rb_intern("__axis_group_reduce__");
  id_reshape           = rb_intern("reshape");
  id_transpose         = rb_intern("transpose");
  id_labels            = rb_intern("labels");

  rb_define_singleton_method(rb_cCArray, "__register_axis_group_classes__",
                             rb_ca_register_axis_group_classes, 2);

  rb_cCAGroupIterator =
    rb_define_class("CAGroupIterator",
                    rb_const_get(rb_cObject, rb_intern("CAIterator")));
  rb_gc_register_address(&rb_cCAGroupIterator);

  rb_define_singleton_method(rb_cCAGroupIterator, "__build__",
                             rb_ca_group_iter_build, 2);
  rb_define_method(rb_cCAGroupIterator, "value",  rb_ca_group_iter_value,  0);
  rb_define_method(rb_cCAGroupIterator, "spec",   rb_ca_group_iter_spec,   0);
  rb_define_method(rb_cCAGroupIterator, "labels", rb_ca_group_iter_labels, -1);

  /* reduction white-list.  All bind to one driver; the op is recovered from
     the called method name.  count_not_masked is a synonym of count (present
     count); elements / count_masked / minmax / wsum / wmean are composed in
     Ruby (lib/carray/axis_group.rb).  min_addr / max_addr give the flat source
     address of the extremum (there is no group-local min_index for the group
     iterator -- the order-preserving flat address is the meaningful position). */
  {
    const char *ops[] = { "sum", "accumulate", "prod", "mean", "min", "max",
                          "variance", "stddev", "variancep", "stddevp",
                          "count", "count_not_masked", "min_addr", "max_addr",
                          "all", "any", NULL };
    int i;
    for ( i = 0; ops[i]; i++ ) {
      rb_define_method(rb_cCAGroupIterator, ops[i], group_iter_reduce, -1);
    }
  }
}
