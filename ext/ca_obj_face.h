/* ---------------------------------------------------------------------------

  ca_obj_face.h

  Face mechanism — shared op helper signatures + lift/strip entry points.

  Phase 1 (= PROPOSAL_CAFACE_PHASE_1.md): skeleton.
  Phase 2 (= PROPOSAL_CAFACE_PHASE_2.md F.2.1): replace shared op helpers
  with thin-forward to parent.

  This header provides signatures for (1) shared op helpers (= thin-forward
  for storage ops, alias-based since Face is data-layout identical to
  parent), (2) `rb_ca_face_template` (struct duplicate + parent swap),
  (3) `ca_face_lift` (= wrap hook at the tail of user-facing access
  methods), (4) `ca_strip_face` (= Face-stripping helper at kernel_iterator
  entry).

  A Face is a "mask of a semantic type" (= identity layered on a storage
  type such as int64, with no value conversion), sibling to CAFake which
  was a "mask of data_type conversion".

--------------------------------------------------------------------------- */

#ifndef CA_OBJ_FACE_H
#define CA_OBJ_FACE_H

#include "carray.h"

/* -- shared op helpers (= thin-forward to parent, alias-based) --
   Face is data-layout identical to parent (= storage type / bytes /
   strides / dim all match), so:
     - attach: parent attach; ptr aliases parent->ptr (= no xmalloc needed)
     - sync:   parent sync (= alias path, no copy back needed; propagates
               via parent)
     - detach: release ptr alias, parent detach
     - xfer_*: delegate to parent's xfer_* (= identical shape / index space)
     - fill_data / fill_*: delegate to parent (= identical storage bytes,
       and the identity layout makes the parent's addresses ours)

   Subclasses may override as needed (= default policy, not an invariant;
   does not preclude a future transform Face). */

void ca_face_attach     (void *ap);
void ca_face_sync       (void *ap);
void ca_face_detach     (void *ap);
void ca_face_fill_data  (void *ap, void *ptr);
void ca_face_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr);
void ca_face_fill_stride(void *ap, ca_size_t base, int8_t ndim,
                                 ca_size_t *counts, ca_size_t *steps, void *ptr);
void ca_face_xfer_index (void *ap, ca_size_t *idx,
                                 void *data, int dir);
void ca_face_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                                 void *data, int dir);
void ca_face_xfer_stride(void *ap, ca_size_t *starts, ca_size_t *counts,
                                 ca_size_t *strides, void *data, int dir);
void ca_face_xfer_all   (void *ap, void *data, int dir);

/* -- lift / strip helpers -- */

/* Struct duplicate + parent + shape swap (= MEMO §4.3; consumed by Face
   subclass lift / clone / dup machinery in Phase 2). */
VALUE   rb_ca_face_template (VALUE original_face, CArray *new_parent,
                              ca_size_t *new_dim);

/* At the tail of user-facing access methods, `if parent is a Face, wrap
   the result as a Face`. Deployed in Phase 1 for `ca[...]`
   (= rb_ca_aref / rb_ca_store); planned for block / refer / reshape /
   transpose / sort etc. in Phase 2. */
VALUE   ca_face_lift (VALUE view, VALUE face_parent);

/* Follow the Face flag down to parent, e.g. at kernel_iterator entry.
   No call sites in Phase 1; wired into SRC_* path init_l2 in Phase 2
   (F.2.6). */
CArray *ca_strip_face (CArray *src);

/* VALUE-level counterpart: walks the Face parent ivar chain to the root
   storage VALUE.  Used at ordering / search dispatcher entry so both the
   switch (src->data_type) and downstream rb_ca_template* calls see the
   root storage, not the Face surface. */
VALUE   rb_ca_strip_face_value (VALUE v);

/* Face gate for the element-wise comparison operators (< <= > >=, eq, ne).
   When self is a Face over numeric storage, descends both operands to
   storage (ORDERABLE required) and reconciles a Face RHS via to_comparable;
   a fixlen-storage Face or a non-Face self is left untouched.  Called from
   rb_ca_call_bincmp.  See ca_obj_face.c for the full contract. */
void    ca_face_reconcile_comparison (volatile VALUE *pself,
                                      volatile VALUE *pother);

/* CAFace abstract base class init (rev11 2026-06-10).
   Called from ruby_carray.c's Init after rb_cCAView is defined, before
   CATime / CATimedelta Init. */
void Init_ca_face (void);

/* -- R.5: composite Face data_class universal dispatch --
   Extern for direct C access from `rb_ca_data_class` (carray_attribute.c)
   into the CARecord tail. CA_OBJ_RECORD identifies the obj_type (assigned
   at runtime by ca_install_obj_type). To add a future composite Face,
   follow the same pattern: add an extern here and one line of case in the
   switch in carray_attribute.c. */
extern int8_t CA_OBJ_RECORD;
VALUE   rb_ca_record_get_data_class (CArray *ca);

/* -- Convenience macro for view-creating method deployment (F.2.13) --
   Insert at the tail of each view-creating Ruby method (= rb_ca_transpose
   / rb_ca_reshape / etc.) just before return. `ca` is self's CArray *,
   `obj` is the view result, `self` is the calling VALUE. Achieves Face
   transparency in a single C-level line, subclass-agnostic.

   Macroises the pattern hand-written at the tail of `rb_ca_fetch_method`
   in Phase 1; applied uniformly to view-creating methods from Phase 2
   F.2.13 onward. */
#define CA_FACE_LIFT_IF_FACE(obj, self, ca) do {                  \
  if ( ca_is_face(ca) && rb_obj_is_kind_of((obj), rb_cCArray) ) { \
    (obj) = ca_face_lift((obj), (self));                          \
  }                                                               \
} while (0)

/* -- wrapper lift (Face or CALazyMarker) --

   A Face and a CALazyMarker are both storage-identical wrappers: they add
   an interpretation over their parent's bytes without changing them.  Both
   want the same invariant at a view-creating method -- the wrapper stays on
   top, and the view is built against what the wrapper wraps.  For a Face
   that keeps `dt.shift(1)` a CATime; for a marker it keeps a fuse block's
   expression lazy instead of dropping out of the chain.

   The flag test comes first and covers both bits in one mask, so an
   ordinary array leaves through a single AND.  That matters: `[]` is the
   hottest method this is deployed on (see devel/bench_index_percall.rb).

   NOT interchangeable with CA_FACE_LIFT_IF_FACE.  Face is lifted at ~24
   sites, including ones a marker must not follow it through -- `copy` owns
   its data, `sort` reorders values, `value` and `strip_mask` change what
   the mask means.  Deploy this only where the result is a view whose shape
   was fixed at construction and which only moves positions
   (PROPOSAL_LAZY_MARKER_LIFT section 4). */
#define CA_WRAPPER_LIFT(obj, self, ca) do {                          \
  if ( ca_test_flag((ca), CA_FLAG_IS_FACE | CA_FLAG_IS_LAZY_MARKER)  \
       && rb_obj_is_kind_of((obj), rb_cCArray) ) {                   \
    (obj) = ca_wrapper_lift((obj), (self), (ca));                    \
  }                                                                  \
} while (0)

VALUE ca_wrapper_lift (VALUE view, VALUE wrapper, void *wrapper_ca);

/* -- Scalar fetch decode hook (storage -> surface) --
   On the scalar-return path (= tail of rb_ca_fetch_index /
   rb_ca_fetch_addr), if a Face-derived subclass defines a
   `storage_to_scalar(raw_value)` Ruby callback, invoke it.  This is a
   decode (copy the storage value out and construct a new value object),
   not a wrap (a zero-copy lens over live memory).  Its write-direction
   counterpart is `scalar_to_storage` (below).

   Use cases:
     - `dt[i]` for CATime / CATimedelta → Scalar decode
     - `ca[i,j,k]` for user-implemented CAObject Face → custom Scalar return
     - Removes the need for Ruby overrides (= alias_method :[] etc.),
       subclass-agnostic

   Guards:
     - ca_is_face(ca): no-op for non-Face
     - !is_a?(CArray): CArray results go through the lift path
       (= CA_FACE_LIFT_IF_FACE)
     - !UNDEF: don't decode the masked-element sentinel
     - respond_to?(:storage_to_scalar): activates once the subclass adopts
       the convention */
/* Face-local C-level dispatch table for storage_to_scalar, separate
   from the global ca_operation_function_t (no API change to existing
   subsystems). A Face subclass that wants the per-cell scalar fetch hot
   path to skip rb_funcall registers its C function via
   ca_face_register_storage_to_scalar(obj_type, fn) at Init time.
   Unregistered obj_types (= external gem Faces that only define the Ruby
   method) fall through to the rb_funcall branch.  The Ruby
   `storage_to_scalar` method is still defined as a regular method so
   user-facing Ruby code may call it directly. */
typedef VALUE (*ca_face_storage_to_scalar_fn)(VALUE self, VALUE raw);

extern ca_face_storage_to_scalar_fn ca_face_storage_to_scalar_table[];

void ca_face_register_storage_to_scalar (int obj_type,
                                         ca_face_storage_to_scalar_fn fn);

/* -- Scalar store encode hook (surface -> storage), mirror of the decode --
   The write-direction counterpart of storage_to_scalar.  Given a surface
   value object (a Scalar / Time / DateTime), a Face-owned function returns
   a storage-domain value (for datetime/timedelta: an Integer in self's
   unit) that the storage cast in rb_ca_obj2ptr can consume directly.  A
   Face that needs no conversion (surface == storage) simply does not
   register.  Faces may either register a C fast-path function here or
   define the Ruby method `scalar_to_storage`; the C table is consulted
   first, then the Ruby fallback. */
typedef VALUE (*ca_face_scalar_to_storage_fn)(VALUE self, VALUE surface);

extern ca_face_scalar_to_storage_fn ca_face_scalar_to_storage_table[];

void ca_face_register_scalar_to_storage (int obj_type,
                                         ca_face_scalar_to_storage_fn fn);

/* Single source of truth for the surface -> storage-domain conversion.
   Returns `obj` unchanged when `ca` is not a Face or when no hook is
   registered / defined (so a bare Integer / String passes through to the
   existing storage cast).  Otherwise returns the storage-domain value the
   Face produced.  Called from rb_ca_obj2ptr (single-cell / fill / masked /
   range stores) and from the Array-of-scalars bulk store branch. */
VALUE ca_face_scalar_to_storage (VALUE self, CArray *ca, VALUE obj);

/* -- F.S0: Face state homogeneity check (= prerequisite for multi-Face APIs
   such as CAStack lift) --
   Per-obj_type C hook returning 1 if `a` and `b` (= both Face instances of
   the same obj_type) have compatible state (= same struct tail fields).
   Caller of `ca_face_state_compatible` guarantees both args are Face and
   have identical obj_type. */
typedef int (*ca_face_state_compatible_fn)(CArray *a, CArray *b);

extern ca_face_state_compatible_fn ca_face_state_compatible_table[];

void ca_face_register_state_compatible (int obj_type,
                                        ca_face_state_compatible_fn fn);

/* Dispatch order:
     1. C hook registered for a->obj_type → call hook, return its result
     2. Else if the Ruby class of `va` defines `face_state_compatible?`
        on a Face subclass (= overrides CArray's default) → invoke with
        `vb`, return RTEST of result
     3. Else → 1 (= default compatible, class identity only)
   Caller must pre-check a->obj_type == b->obj_type. `va` / `vb` are
   the Ruby VALUEs of the same instances (used only for the Ruby fallback
   path). */
int ca_face_state_compatible (VALUE va, CArray *a, VALUE vb, CArray *b);

/* -- F.S1: Face state portability (= class-level predicate) --
   Whether a Face class's state can be "moved" from one parent to
   another -- i.e., whether list[0]'s state can stand in for the result
   when a multi-parent operation (CAStack lift, compose family Face
   preservation, etc.) is performed.

   - portable = 1: state is metadata-only (= CATime unit, CACircular
     @range), can be carried to the lifted view via ca_face_lift.
   - portable = 0: state holds per-parent storage tied to the specific
     parent (= CAConstString buffer); cannot be exchanged across parents.
     Multi-parent operations must reject.

   Default for unregistered obj_types is 1 (= safe for the common case of
   metadata-only Faces, including Ruby-implemented Faces that don't reach
   a C Init).  Faces whose state holds per-parent storage MUST explicitly
   register 0 (= CAConstString). */
extern int8_t ca_face_state_portable_table[];

void ca_face_register_state_portable (int obj_type, int portable);

/* Dispatch:
     1. C table entry registered for obj_type → return that value
     2. Else if the Ruby class `klass` defines a singleton method
        `face_state_portable?` (= subclass owns it) → invoke and RTEST
     3. Else → 1 (= default portable)
   `klass` is the Ruby class of the Face instance (used for the Ruby
   fallback path).  Pass Qnil when the class is unknown / unavailable
   (= falls through to default). */
int ca_face_state_portable (int obj_type, VALUE klass);

#define CA_FACE_STORAGE_TO_SCALAR_IF_FACE(obj, self, ca) do {                \
  if ( ca_is_face(ca) && (obj) != CA_UNDEF && (obj) != Qnil                  \
       && ! rb_obj_is_kind_of((obj), rb_cCArray) ) {                         \
    ca_face_storage_to_scalar_fn _decode_fn = ca_face_storage_to_scalar_table[(ca)->obj_type]; \
    if ( _decode_fn != NULL ) {                                              \
      (obj) = _decode_fn((self), (obj));                                     \
    }                                                                        \
    else {                                                                   \
      static ID _id_storage_to_scalar = 0;                                   \
      if ( _id_storage_to_scalar == 0 ) _id_storage_to_scalar = rb_intern("storage_to_scalar"); \
      if ( rb_respond_to((self), _id_storage_to_scalar) ) {                  \
        (obj) = rb_funcall((self), _id_storage_to_scalar, 1, (obj));         \
      }                                                                      \
    }                                                                        \
  }                                                                          \
} while (0)

#endif /* CA_OBJ_FACE_H */
