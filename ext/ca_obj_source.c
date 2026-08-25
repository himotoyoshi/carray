/* ---------------------------------------------------------------------------

  ca_obj_source.c

  CASource — the abstract marker class for parentless generate-entities
  (the third entity kind next to own = CArray and borrow = CAWrap).

  This file holds the whole of CASource: a class, a sealed allocator and
  a TypedData chain entry.  There is no operation table, no dispatch, no
  shared helper and no state here, and none may be added — a subclass
  registers its own obj_type via ca_install_obj_type() and writes the
  complete ca_operation_function_t itself.  Nothing in the core reads
  "is this a CASource"; the class exists so that `is_a?(CASource)` holds
  and so subclasses have a home in the hierarchy.

  Subclasses fall into two parallel families that share nothing beyond
  this class: generators (value = f(index), CAGenerator and friends) and
  external bridges (an already-addressable foreign buffer — an image
  pixel cache, a cv::Mat, a file-backed variable).

  A subclass declares its entity_type itself, and that choice decides
  which engine paths it meets:

    CA_REAL_ARRAY  — born warm (the buffer is already addressable).
                     ca_is_entity() is true, so ca_has_mask() stops at
                     the entity branch and ca_iter_classify_source()
                     returns SRC_CASTRIDE; no parent is ever read.
                     The struct takes the plain CArray prefix.
    CA_VIEW_ARRAY  — born cold (values must be produced on demand).
                     The struct takes the CAView prefix with parent
                     left NULL, and the engine's parent-walking paths
                     must be taught to stop (see PROPOSAL_CASOURCE §7).

  See devel/PROPOSAL_CASOURCE.md (§2.1 empty base, §2.2 subclass writes
  every slot, §2.5 struct prefix vs class placement) and
  devel/MEMO_CASOURCE.md §9 (parentless safety audit).

---------------------------------------------------------------------------- */

#include "carray.h"

VALUE rb_cCASource;

/* TypedData chain entry.  Subclasses whose struct carries the CArray
   prefix chain to this one and supply their own dmark / dfree / dsize;
   a subclass built on the CAView prefix chains to caview_data_type
   instead (the TypedData chain follows the C struct, the Ruby class
   hierarchy follows the concept — they are independent). */

const rb_data_type_t casource_data_type = {
    .wrap_struct_name = "CASource",
    .parent = &carray_data_type,
    .function = {
        .dmark = NULL,    /* subclass overrides */
        .dfree = NULL,    /* subclass overrides */
        .dsize = NULL,    /* subclass overrides */
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
rb_ca_source_s_allocate_forbidden (VALUE klass)
{
  rb_raise(rb_eTypeError,
           "CASource is abstract; a source class is defined by a C extension "
           "that registers its own obj_type (see docs/authoring/"
           "WritingCExtensions.md)");
}

void
Init_ca_source (void)
{
  /* CAREFUL: rb_cCArray must already exist (defined in ruby_carray.c
     ahead of this Init) — CASource inherits from it directly, not from
     CAView: a source derives from no other CArray. */
  rb_cCASource = rb_define_class("CASource", rb_cCArray);
  rb_define_alloc_func(rb_cCASource, rb_ca_source_s_allocate_forbidden);
}
