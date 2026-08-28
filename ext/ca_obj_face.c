/* ---------------------------------------------------------------------------

  Face mechanism — shared helpers, abstract CAFace base class, and
  registration tables for state homogeneity / portability.

  A Face is storage-identical to its parent (same data_type, same
  layout) and performs no value transformation.  Storage ops therefore
  thin-forward:
    attach       parent attach + alias parent->ptr
    sync         parent sync (alias path auto-propagates)
    detach       release alias + parent detach
    xfer_* /     delegate to parent
      fill_data
  Concrete Faces (CATime / CATimedelta / CARecord / ...) may
  override individually; the default is pure thin-forward.

  Also housed here:
    rb_ca_face_template    struct duplication that carries subclass tail
    ca_face_lift           re-wrap a view as a Face when the source was
    ca_strip_face          walk down through Face parents to storage
    CAFace abstract class  organisational relay in the class hierarchy
    storage_to_scalar /    per-obj_type dispatch for element decode (read)
      scalar_to_storage    and encode (write) between surface and storage
    state-compatible /     homogeneity + portability registries used by
      state-portable       promote_list / CAStack / MV producer

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "ca_obj_face.h"

/* ---- shared op helpers (thin-forward) ---- */

void
ca_face_attach (void *ap)
{
  CAView *cav = (CAView *) ap;
  CArray    *ca  = (CArray *) ap;
  ca_attach(cav->parent);
  /* alias parent->ptr (Face has identical data layout, so copy is unneeded) */
  ca->ptr = cav->parent->ptr;
}

void
ca_face_sync (void *ap)
{
  CAView *cav = (CAView *) ap;
  /* alias means no copy-back is needed; parent sync propagates */
  ca_sync(cav->parent);
}

void
ca_face_detach (void *ap)
{
  CAView *cav = (CAView *) ap;
  CArray    *ca  = (CArray *) ap;
  ca->ptr = NULL;  /* release alias (do not xfree — parent owns) */
  ca_detach(cav->parent);
}

void
ca_face_fill_data (void *ap, void *ptr)
{
  CAView *cav = (CAView *) ap;
  ca_fill(cav->parent, ptr);
}

void
ca_face_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr)
{
  CAView *cav = (CAView *) ap;
  ca_fill_addrs(cav->parent, n, addrs, ptr);
}

void
ca_face_fill_stride (void *ap, ca_size_t base, int8_t ndim,
                            ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CAView *cav = (CAView *) ap;
  ca_fill_stride(cav->parent, base, ndim, counts, steps, ptr);
}

void
ca_face_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAView *cav = (CAView *) ap;
  ca_xfer_index(cav->parent, idx, data, dir);
}

void
ca_face_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                           void *data, int dir)
{
  CAView *cav = (CAView *) ap;
  ca_xfer_addrs(cav->parent, n, addrs, data, dir);
}

void
ca_face_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                            ca_size_t *strides, void *data, int dir)
{
  CAView *cav = (CAView *) ap;
  ca_xfer_stride(cav->parent, starts, counts, strides, data, dir);
}

void
ca_face_xfer_all (void *ap, void *data, int dir)
{
  CAView *cav = (CAView *) ap;
  ca_xfer_all(cav->parent, data, dir);
}

/* rb_ca_face_template(original_face, new_parent, new_dim) — duplicate
 * the CArray struct of original_face (including its subclass tail) and
 * return a new Face VALUE bound to new_parent with its own shape.
 *
 * Called from ca_face_lift and from subclass lift / clone / dup paths. */
VALUE
rb_ca_face_template (VALUE original_face, CArray *new_parent,
                     ca_size_t *new_dim)
{
  CArray   *src;
  CArray   *dst;
  CAView *vdst;
  size_t    size;
  const rb_data_type_t *tdata;

  TypedData_Get_Struct(original_face, CArray, &carray_data_type, src);
  tdata = ca_typeddata[src->obj_type];

  /* Actual subclass size (incl. tail) — via TypedData's dsize callback */
  size = (tdata && tdata->function.dsize)
            ? tdata->function.dsize(src)
            : sizeof(CAView);

  dst = (CArray *) xmalloc(size);
  /* CAREFUL: the whole-struct memcpy is how a C-tail Face
     (CATime.unit, CARecord.data_class, ...) carries its subclass
     state without per-subclass knowledge.  It necessarily also copies
     the CAView instance-state prefix — shape, attach state, and
     framework-owned storage pointers — which must be reset below
     before the new struct is exposed to GC. */
  memcpy(dst, src, size);

  /* CAREFUL: reset every field that was copied above but must not be
     inherited from src.  The framework-owned _pool / dim in
     particular must be allocated fresh — reusing src's pool buffer
     would alias it and double-free at GC.  Pool-migrated obj_types
     route through ca_array_pool_alloc; legacy ones fall back to
     ALLOC_N.  Any raw struct copy of a CArray-family object owes
     this reset. */
  vdst = (CAView *) dst;
  vdst->parent  = new_parent;
  vdst->attach  = 0;
  vdst->nosync  = 0;
  dst->ptr      = NULL;
  dst->mask     = NULL;
  dst->elements = new_parent->elements;
  dst->_pool    = NULL;
  if ( ca_func[src->obj_type].pool_init ) {
    ca_array_pool_alloc(dst, src->obj_type, new_parent->ndim);  /* ndim + _pool + dim */
  }
  else {
    dst->ndim = new_parent->ndim;
    dst->dim  = ALLOC_N(ca_size_t, new_parent->ndim);
  }
  memcpy(dst->dim,
         new_dim ? new_dim : new_parent->dim,
         sizeof(ca_size_t) * new_parent->ndim);

  return TypedData_Wrap_Struct(CLASS_OF(original_face),
                                (rb_data_type_t *) tdata,
                                dst);
}

/* ca_face_lift(view, face_parent) — at the tail of user-facing entry
 * points (`ca[...]` etc.), when the operand was a Face, re-wrap the
 * resulting view as a Face of the same subclass.  Thin wrapper over
 * rb_ca_face_template.
 *
 * Caller (rb_ca_aref / rb_ca_store) must have already checked that
 * face_parent carries the CA_FLAG_IS_FACE flag. */
VALUE
ca_face_lift (VALUE view, VALUE face_parent)
{
  CArray *view_ca;
  VALUE  lifted;
  static ID id_copy_state = 0;
  if ( id_copy_state == 0 ) id_copy_state = rb_intern("copy_state");

  TypedData_Get_Struct(view, CArray, &carray_data_type, view_ca);

  /* Idempotent lift: if the view is already a Face of the same class as
     face_parent, it has already been lifted — a builder that lifts internally
     (e.g. rb_ca_refer_new → rb_ca_refer) whose caller lifts the result again.
     Re-wrapping would stack an adjacent same-class double Face; return the
     already-lifted view unchanged.  Same *class* (not just obj_type) so two
     distinct CAObject-based Faces, which share obj_type CA_OBJ_OBJECT, are not
     conflated — that is a legitimate stack and must proceed to a real lift. */
  if ( ca_is_face(view_ca)
       && rb_obj_class(view) == rb_obj_class(face_parent) ) {
    return view;
  }

  /* CAREFUL: rewrite view's data_type to the storage data_type before
     lifting.  view-creation inherits the Face's surface data_type
     (often CA_FIXLEN), but the invariant is that Face.parent.data_type
     is always the storage type — so view (the new Face's parent-to-be)
     must carry the storage type, and only the new Face wrapper
     presents the surface. */
  {
    CArray *fp, *p;
    TypedData_Get_Struct(face_parent, CArray, &carray_data_type, fp);
    p = fp;
    while (p && ca_is_face(p)) {
      p = ((CAView *) p)->parent;
    }
    if (p && p->data_type != view_ca->data_type) {
      view_ca->data_type = p->data_type;
    }

    /* §8.3 one-level local swap: put the view where the Face used to sit, so
       the lifted chain carries exactly ONE Face (the new wrapper) rather than
       a redundant intermediate Face.  A fetch-path builder builds its view on
       the un-stripped Face operand, leaving view->parent == the Face; move it
       down ONE level to fp->parent.  Never a full strip_face walk: an inner
       distinct Face the user stacked underneath (docs/topics/CAFace.md §8.3) must be
       preserved, and fp->parent points at it.  Guard on pointer-equality so
       only a view built directly on this Face fires (order.c builds on
       stripped storage → no-op).  CAStack (multi-parent) is excluded here and
       handled by builder-side pre-strip.  data_type above stays a full strip
       (surface concern, §8 #7) — the parent pointer is the structural concern
       (§8.3); the two axes are deliberately separate. */
    if ( ((CAView *) view_ca)->parent == fp
         && ! ca_test_flag(view_ca, CA_FLAG_MULTI_PARENTS) ) {
      ((CAView *) view_ca)->parent = ((CAView *) fp)->parent;   /* C pointer: one level */
      rb_ca_set_parent(view, rb_ca_parent(face_parent));        /* @parent ivar: lockstep */
    }
  }

  /* Pass view_ca->dim explicitly: passing new_dim=NULL would adopt
     new_parent->dim, but new_parent here is the (typically) narrower
     view. */
  lifted = rb_ca_face_template(face_parent, view_ca, view_ca->dim);
  /* Pin view as a GC root of lifted so the slice is not collected. */
  rb_ca_set_parent(lifted, view);

  /* Optional Ruby callback for ivar / state carry.  Faces holding
     semantic state in the struct tail (CATime / CATimedelta
     etc.) auto-carry via the template memcpy; Faces holding state in
     Ruby ivars (Ruby-implemented CAObject-derived Faces etc.) should
     override copy_state to copy them. */
  if ( rb_respond_to(face_parent, id_copy_state) ) {
    rb_funcall(lifted, id_copy_state, 1, face_parent);
  }

#ifdef CARRAY_DEV_BUILD
  /* Soundness tripwire (docs/internal/FaceLiftSoundness.md §0/§7): after a lift the view
     node under the new Face must not point back at the Face we lifted from —
     the §8.3 one-level swap must have moved it exactly one level, so a
     redundant middle Face is structurally caught here, wherever it enters.
     Skip only when the lifted node is not a view (the ordering kernels lift a
     fresh entity result — no swap applies).  Multi-parent CAStack is covered:
     its parents are pre-stripped in the builder (ca_stack_setup_with_axis), so
     ->parent (slot 0) is storage; this checks that slot. */
  {
    CArray *lifted_ca, *lp, *fps;
    TypedData_Get_Struct(lifted, CArray, &carray_data_type, lifted_ca);
    lp = CAVIEW(lifted_ca)->parent;
    TypedData_Get_Struct(face_parent, CArray, &carray_data_type, fps);
    if ( lp && ca_is_view(lp) ) {
      if ( CAVIEW(lp)->parent == fps ) {
        rb_bug("ca_face_lift: §8.3 one-level swap did not fire — redundant "
               "middle Face (view->parent still points at the lifted Face)");
      }
      if ( ca_is_face(lp) && lp->obj_type == fps->obj_type ) {
        rb_bug("ca_face_lift: adjacent same-class double Face under the lifted "
               "wrapper (CAFace.md §8 #2/#3)");
      }
    }
  }
#endif

  return lifted;
}

/* ca_strip_face(src) — walk down through Face parents to the storage
 * CArray.  Called at kernel_iterator entry and lazy chain endpoints
 * where downstream code needs to observe the storage layout, not the
 * Face surface. */
CArray *
ca_strip_face (CArray *src)
{
  while (src && ca_is_face(src)) {
    src = ((CAView *) src)->parent;
  }
  return src;
}

/* rb_ca_strip_face_value(v) — VALUE-level counterpart to ca_strip_face.
 * Walks down the Face `parent` ivar chain and returns the root storage
 * VALUE (a non-Face CArray).  Non-Face input is returned as-is.
 *
 * Used by ordering / search kernel dispatchers where the switch on
 * data_type must see storage type instead of Face surface (CA_FIXLEN),
 * and where subsequent `rb_ca_template*` calls must not re-lift the
 * result into a Face wrapper (index / addr / linear outputs are not
 * Face-semantic).  Complements ca_strip_face on the C-struct axis. */
VALUE
rb_ca_strip_face_value (VALUE v)
{
  CArray *ca;
  if ( ! rb_obj_is_kind_of(v, rb_cCArray) ) return v;
  TypedData_Get_Struct(v, CArray, &carray_data_type, ca);
  while ( ca_is_face(ca) ) {
    v = rb_ca_parent(v);
    TypedData_Get_Struct(v, CArray, &carray_data_type, ca);
  }
  return v;
}

/* CAFace — abstract marker class used as the code-organisation relay
   for the Face mechanism.  The semantic gate is CA_FLAG_IS_FACE only,
   read via ca_is_face(); the class hierarchy is organisation, not the
   basis for the predicate.  CAObject-derived Faces satisfy
   ca_is_face()=true without inheriting CAFace at the Ruby level.

   caface_data_type is a TypedData chain entry with no callbacks;
   subclasses provide their own dmark / dfree / dsize.

   rb_cCAFace's allocator is sealed off so the class cannot be
   instantiated directly; it exists only as the inheritance target
   for concrete Faces (CATime / CATimedelta / CARecord / ...). */

VALUE rb_cCAFace;

const rb_data_type_t caface_data_type = {
    .wrap_struct_name = "CAFace",
    .parent = &caview_data_type,
    .function = {
        .dmark = NULL,    /* subclass overrides */
        .dfree = NULL,    /* subclass overrides */
        .dsize = NULL,    /* subclass overrides */
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
rb_ca_face_s_allocate_forbidden (VALUE klass)
{
  rb_raise(rb_eTypeError,
           "CAFace is abstract; instantiate a concrete Face subclass "
           "(CATime / CATimedelta / ...)");
}

/* Face-local C dispatch table for storage_to_scalar (the read/decode
   direction).  Sized to CA_OBJ_TYPE_MAX so any registered obj_type can be
   indexed directly; file-scope zero-init leaves unregistered slots NULL. */
ca_face_storage_to_scalar_fn ca_face_storage_to_scalar_table[CA_OBJ_TYPE_MAX];

void
ca_face_register_storage_to_scalar (int obj_type, ca_face_storage_to_scalar_fn fn)
{
  if ( obj_type < 0 || obj_type >= CA_OBJ_TYPE_MAX ) {
    rb_raise(rb_eArgError,
             "ca_face_register_storage_to_scalar: obj_type %d out of range",
             obj_type);
  }
  ca_face_storage_to_scalar_table[obj_type] = fn;
}

/* Face-local C dispatch table for scalar_to_storage (the write/encode
   direction), the mirror of the decode table above.  Unregistered slots
   stay NULL; a Face without a C fast path relies on the Ruby fallback in
   ca_face_scalar_to_storage (carray_cast.c). */
ca_face_scalar_to_storage_fn ca_face_scalar_to_storage_table[CA_OBJ_TYPE_MAX];

void
ca_face_register_scalar_to_storage (int obj_type, ca_face_scalar_to_storage_fn fn)
{
  if ( obj_type < 0 || obj_type >= CA_OBJ_TYPE_MAX ) {
    rb_raise(rb_eArgError,
             "ca_face_register_scalar_to_storage: obj_type %d out of range",
             obj_type);
  }
  ca_face_scalar_to_storage_table[obj_type] = fn;
}

/* -- Face state homogeneity check -- */

ca_face_state_compatible_fn ca_face_state_compatible_table[CA_OBJ_TYPE_MAX];

void
ca_face_register_state_compatible (int obj_type, ca_face_state_compatible_fn fn)
{
  if ( obj_type < 0 || obj_type >= CA_OBJ_TYPE_MAX ) {
    rb_raise(rb_eArgError,
             "ca_face_register_state_compatible: obj_type %d out of range",
             obj_type);
  }
  ca_face_state_compatible_table[obj_type] = fn;
}

/* Detect whether `va`'s class overrides `face_state_compatible?` (= the
   method is owned by a class other than rb_cCArray). Uses #method / #owner
   reflection; called only on the cold path (no C hook registered). */
static int
ca_face_has_ruby_state_check (VALUE va)
{
  static ID id_face_state_compatible_p = 0;
  static ID id_method = 0;
  static ID id_owner  = 0;
  VALUE m, owner;
  if ( id_face_state_compatible_p == 0 ) {
    id_face_state_compatible_p = rb_intern("face_state_compatible?");
    id_method                  = rb_intern("method");
    id_owner                   = rb_intern("owner");
  }
  m = rb_funcall(va, id_method, 1, ID2SYM(id_face_state_compatible_p));
  owner = rb_funcall(m, id_owner, 0);
  return ( owner != rb_cCArray ) ? 1 : 0;
}

int
ca_face_state_compatible (VALUE va, CArray *a, VALUE vb, CArray *b)
{
  ca_face_state_compatible_fn fn = ca_face_state_compatible_table[a->obj_type];
  if ( fn != NULL ) {
    return fn(a, b);
  }
  if ( ca_face_has_ruby_state_check(va) ) {
    VALUE r = rb_funcall(va, rb_intern("face_state_compatible?"), 1, vb);
    return RTEST(r) ? 1 : 0;
  }
  return 1;
}

/* Ruby-side: CArray#face_state_compatible?(other) */
static VALUE
rb_ca_face_state_compatible_p (VALUE self, VALUE other)
{
  CArray *a, *b;

  if ( ! rb_obj_is_kind_of(other, rb_cCArray) ) {
    rb_raise(rb_eArgError,
             "face_state_compatible?: argument must be a CArray");
  }
  TypedData_Get_Struct(self,  CArray, &carray_data_type, a);
  TypedData_Get_Struct(other, CArray, &carray_data_type, b);
  if ( ! ca_is_face(a) || ! ca_is_face(b) ) {
    rb_raise(rb_eArgError,
             "face_state_compatible?: both receiver and argument must be Face");
  }
  if ( a->obj_type != b->obj_type ) {
    rb_raise(rb_eArgError,
             "face_state_compatible?: must be the same Face class");
  }
  return ca_face_state_compatible(self, a, other, b) ? Qtrue : Qfalse;
}

/* -- Face state portability -- */

/* int8_t per slot to distinguish "unregistered" (-1, dispatch falls
   through to Ruby fallback) from "registered as not-portable"
   (0, e.g. CAConstString) and "registered as portable" (1). */
int8_t ca_face_state_portable_table[CA_OBJ_TYPE_MAX];

/* Per-obj_type bound Ruby class method returning the registered value.
   Defined once for each obj_type that registers a value, so user-facing
   `<FaceClass>.face_state_portable?` reflects the C table without
   needing a reverse-lookup at every call. */
static VALUE
rb_ca_s_face_state_portable_true (VALUE klass)
{
  return Qtrue;
}

static VALUE
rb_ca_s_face_state_portable_false (VALUE klass)
{
  return Qfalse;
}

void
ca_face_register_state_portable (int obj_type, int portable)
{
  if ( obj_type < 0 || obj_type >= CA_OBJ_TYPE_MAX ) {
    rb_raise(rb_eArgError,
             "ca_face_register_state_portable: obj_type %d out of range",
             obj_type);
  }
  ca_face_state_portable_table[obj_type] = portable ? 1 : 0;
  /* Mirror to a singleton method on the class so Ruby-side
     introspection (<FaceClass>.face_state_portable?) agrees with the
     C table.  CAREFUL: ca_class[obj_type] must be set by
     ca_install_obj_type before this call — Faces register from
     within their Init_*, which runs after ca_install_obj_type. */
  if ( !NIL_P(ca_class[obj_type]) ) {
    rb_define_singleton_method(ca_class[obj_type], "face_state_portable?",
                               portable ? rb_ca_s_face_state_portable_true
                                        : rb_ca_s_face_state_portable_false,
                               0);
  }
}

/* Detect whether `klass`'s singleton class owns `face_state_portable?`
   (= the predicate is defined on the Face class itself, not inherited
   from rb_cCArray's metaclass).  Cold path; only consulted when no C
   entry is registered. */
static int
ca_face_class_has_portable_method (VALUE klass)
{
  static ID id_face_state_portable_p = 0;
  static ID id_method = 0;
  static ID id_owner  = 0;
  VALUE m, owner;
  if ( NIL_P(klass) ) return 0;
  if ( id_face_state_portable_p == 0 ) {
    id_face_state_portable_p = rb_intern("face_state_portable?");
    id_method                = rb_intern("method");
    id_owner                 = rb_intern("owner");
  }
  if ( !rb_respond_to(klass, id_face_state_portable_p) ) return 0;
  m = rb_funcall(klass, id_method, 1, ID2SYM(id_face_state_portable_p));
  owner = rb_funcall(m, id_owner, 0);
  /* owner is a (singleton) class — if it isn't rb_singleton_class(rb_cCArray)
     or the singleton chain rooted at CArray, the Face class (or its
     ancestor) has its own definition. */
  return ( owner != rb_singleton_class(rb_cCArray) ) ? 1 : 0;
}

int
ca_face_state_portable (int obj_type, VALUE klass)
{
  int8_t entry;
  if ( obj_type < 0 || obj_type >= CA_OBJ_TYPE_MAX ) return 1;
  entry = ca_face_state_portable_table[obj_type];
  if ( entry >= 0 ) {
    return entry ? 1 : 0;
  }
  if ( !NIL_P(klass) && ca_face_class_has_portable_method(klass) ) {
    VALUE r = rb_funcall(klass, rb_intern("face_state_portable?"), 0);
    return RTEST(r) ? 1 : 0;
  }
  return 1;   /* default portable */
}

/* CArray.face_state_portable? — class method on CArray.  Subclasses
   (Face classes) override by defining their own `def self.face_state_portable?`.
   This default returns true (= 1) for non-Face CArray classes; the actual
   per-Face decision goes through ca_face_state_portable from C callers. */
static VALUE
rb_ca_s_face_state_portable_p (VALUE klass)
{
  return Qtrue;
}

/* CArray#face_lift(face_parent) — Ruby surface for ca_face_lift.
   Used by CArray.stack to re-wrap a raw CAStack with the homogeneous
   Face class carried by face_parent (typically list[0] after the
   promote_list pass).  Delegates the data_type rewrite and optional
   copy_state callback to ca_face_lift. */
static VALUE
rb_ca_face_lift_method (VALUE self, VALUE face_parent)
{
  CArray *fp;
  if ( ! rb_obj_is_kind_of(face_parent, rb_cCArray) ) {
    rb_raise(rb_eArgError, "face_lift: face_parent must be a CArray");
  }
  TypedData_Get_Struct(face_parent, CArray, &carray_data_type, fp);
  if ( ! ca_is_face(fp) ) {
    rb_raise(rb_eArgError, "face_lift: face_parent must be a Face instance");
  }
  return ca_face_lift(self, face_parent);
}

/* ca_face_reconcile_comparison(pself, pother) — Face gate for the element-
 * wise comparison operators (< <= > >=, eq, ne; <=> composes from > and <).
 * Mirrors the search query gate (PROPOSAL_FACE_ORDERING_GATE): when the LHS
 * is a Face over NUMERIC storage, memcmp on the surface fixlen bytes would
 * mis-order the storage, so descend to storage (ORDERABLE licenses that the
 * numeric order equals the surface order) and reconcile the RHS:
 *
 *   - RHS is a Face: COMPARABLE self strips it; else it must respond to
 *     to_comparable (reconcile to self's reference, e.g. unit alignment,
 *     which may raise on loss); else raise.
 *   - RHS is plain (bare number / non-Face array / Scalar): a direct storage
 *     compare, which only a COMPARABLE self licenses -- a non-COMPARABLE
 *     Face (e.g. a unit-bearing CATime) rejects it.
 *
 * A Face over FIXLEN storage (CARecord / string faces) is left untouched:
 * memcmp on its bytes is already the correct order/equality, same as a plain
 * fixlen array.  Both operands are rebound to storage via *pself / *pother.
 * No-op when self is not a Face. */
void
ca_face_reconcile_comparison (volatile VALUE *pself, volatile VALUE *pother)
{
  VALUE self = *pself, other = *pother;
  CArray *sc, *storage;

  if ( ! rb_obj_is_kind_of(self, rb_cCArray) ) {
    return;
  }
  TypedData_Get_Struct(self, CArray, &carray_data_type, sc);
  if ( ! ca_is_face(sc) ) {
    return;
  }

  storage = ca_strip_face(sc);
  if ( storage->data_type == CA_FIXLEN ) {
    /* genuine fixlen semantics: memcmp is the correct comparison, leave
       the Face(s) in place (same result as a plain fixlen array). */
    return;
  }

  if ( ! ca_test_flag(sc, CA_FLAG_FACE_ORDERABLE_STORAGE) ) {
    rb_raise(rb_eArgError,
             "comparison: Face operand (%s) is not orderable by storage; "
             "use ca.parent to descend to storage",
             rb_obj_classname(self));
  }

  {
    VALUE self_ref = self;   /* reference before stripping (for to_comparable) */
    int   comparable = ca_test_flag(sc, CA_FLAG_FACE_COMPARABLE_STORAGE);
    int   other_is_face = 0;

    if ( rb_obj_is_kind_of(other, rb_cCArray) ) {
      CArray *oc;
      TypedData_Get_Struct(other, CArray, &carray_data_type, oc);
      other_is_face = ca_is_face(oc);
    }

    if ( comparable ) {
      /* directly comparable Face reference: strip a Face operand, take a
         plain operand as-is (storage compare is licensed). */
      if ( other_is_face ) {
        other = rb_ca_strip_face_value(other);
      }
    }
    else if ( rb_respond_to(self_ref, rb_intern("to_comparable")) ) {
      /* non-COMPARABLE Face reference: the reference brings the operand into
         its own space (unit alignment / instant lift), whatever the operand
         type -- Face CArray, our Scalar, a Ruby Time / DateTime, etc.  The
         reference's to_comparable raises if it cannot reconcile it. */
      other = rb_funcall(self_ref, rb_intern("to_comparable"), 1, other);
      other = rb_ca_strip_face_value(other);
    }
    else {
      rb_raise(rb_eArgError,
               "comparison: non-comparable Face reference (%s) has no "
               "to_comparable to reconcile the operand; use ca.parent to "
               "compare the hidden storage explicitly",
               rb_obj_classname(self_ref));
    }

    *pself  = rb_ca_strip_face_value(self);
    *pother = other;
  }
}

void
Init_ca_face (void)
{
  int i;

  /* CAREFUL: rb_cCAView must already exist (defined in ruby_carray.c
     ahead of this Init) — CAFace inherits from it. */
  rb_cCAFace = rb_define_class("CAFace", rb_cCAView);
  rb_define_alloc_func(rb_cCAFace, rb_ca_face_s_allocate_forbidden);

  /* Initialise the portable table to -1 for every slot so dispatch
     can distinguish "explicitly registered 0" (CAConstString) from
     "never registered" (falls through to the Ruby default). */
  for ( i = 0; i < CA_OBJ_TYPE_MAX; i++ ) {
    ca_face_state_portable_table[i] = -1;
  }

  rb_define_method(rb_cCArray, "face_state_compatible?",
                   rb_ca_face_state_compatible_p, 1);
  rb_define_singleton_method(rb_cCArray, "face_state_portable?",
                             rb_ca_s_face_state_portable_p, 0);
  rb_define_method(rb_cCArray, "face_lift", rb_ca_face_lift_method, 1);
}
