/* ---------------------------------------------------------------------------

  Sort surface: sort / sort_copy (value & view), sort_addr / axis2addr
  (address sort).  The typed textbook sort kernels live in
  carray_sort_kernel.c; partition / partition_copy in carray_partition.c.

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "ca_for_buffer.h"        /* CA_WITH_BUFFER (scoped attach/detach) */
#include "ca_kernel_iterator.h"   /* CA_FOR_EACH_FIBER_INOUT (sort_copy) */
#include "ca_obj_face.h"          /* CA_FACE_LIFT_IF_FACE */
#include "ca_sort_kernels.h"      /* ca_sort_quick_* / ca_sort_merge_* / ca_partition_nan_* */
#include "ca_compare.h"           /* ca_elem_cmp[] -- shared element comparators */
#include <math.h>
#include <float.h>

/* ----------------------------------------------------------------- */

/* CA_FIXLEN comparator: direct memcmp over the packed byte width.
 * The shared ca_elem_cmp table (ca_compare.h) leaves FIXLEN unsupported
 * because a 2-arg comparator cannot carry the width; numeric / object
 * data_types go through ca_elem_cmp[data_type].
 *
 * Called by sort_addr_cmp only. */
static int
cmp_fixlen_bytes (char *a, char *b, ca_size_t bytes)
{
  return memcmp(a, b, (size_t) bytes);
}

/* ----------------------------------------------------------------- */

struct cmp_base {
  int      n;
  CArray **ca;
  int      masked_last;  /* 1 (default, :last) or 0 (:first) */
};

struct sort_addr_key {
  ca_size_t  i;
  struct cmp_base *base;
};

/* Multi-key comparator for CArray.sort_addr: compares keys in priority
 * order, original index breaks ties (stable).  Masked cells are an
 * incomparable sentinel clustered at base->masked_last's end (same
 * role NaN plays for float data types, and the same masked_position:
 * contract as the sort/partition family's :sentinel kernel mode --
 * see MASKED_POSITION rev1 in mkkernel.rb's MkKernel.sort doc).
 *
 * Called as a qsort/mergesort callback in rb_ca_s_sort_addr. */
static int
sort_addr_cmp (struct sort_addr_key *a, struct sort_addr_key *b)
{
  struct cmp_base *base = a->base;
  int n = base->n;
  CArray **ca = base->ca;
  ca_size_t ia = a->i;
  ca_size_t ib = b->i;
  int result;
  int i;
  for (i=0; i<n; i++) {
    int8_t data_type = ca[i]->data_type;
    char  *ptr = ca[i]->ptr;
    boolean8_t  *m = ( ca[i]->mask ) ? (boolean8_t *) ca[i]->mask->ptr : NULL;
    ca_size_t bytes = ca[i]->bytes;
    if ( ( ! m ) ||
         ( ( ! m[ia] ) && ( ! m[ib] ) ) ) {
      if ( data_type == CA_FIXLEN ) {
        result = cmp_fixlen_bytes(ptr + ia*bytes,
                                  ptr + ib*bytes, bytes);
      }
      else {
        result = ca_elem_cmp[data_type](ptr + ia*bytes,
                                        ptr + ib*bytes);
      }
    }
    else if ( ( ! m[ia] ) && ( m[ib] ) ) {
      result = base->masked_last ? -1 : 1;
    }
    else if ( ( m[ia] ) && ( ! m[ib] ) ) {
      result = base->masked_last ? 1 : -1;
    }
    else {
      result = 0;
    }
    if ( result ) {
      return result;
    }
  }
  return ( ia > ib ) ? 1 : -1; /* for stable sort */
}

/* CArray.sort_addr(*args, masked_position: :last) — multi-key lex
 * sort.  Returns a 1-D CA_SIZE array of indices that sorts the
 * arguments in priority order (a > b > c):
 *
 *     idx = CArray.sort_addr(a, b, c)
 *     a[idx]; b[idx]; c[idx]
 *
 * All arguments must have the same element count.  Masked cells are
 * an incomparable sentinel clustered at masked_position: (:last
 * default, or :first); ties are broken by original index (stable). */
static VALUE
rb_ca_s_sort_addr (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out;
  CArray *co;
  struct cmp_base *base;
  struct sort_addr_key *data;
  ca_size_t elements;
  ca_size_t *q;
  int j;
  ca_size_t i;

  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE vmasked_position = Qnil;
  rb_scan_options(ropt, "masked_position", &vmasked_position);
  int masked_last = 1;
  if ( !NIL_P(vmasked_position) ) {
    static ID sym_first = 0, sym_last = 0;
    if ( !sym_first ) sym_first = rb_intern("first");
    if ( !sym_last )  sym_last  = rb_intern("last");
    ID mp_id = SYM2ID(vmasked_position);
    if      ( mp_id == sym_last )  masked_last = 1;
    else if ( mp_id == sym_first ) masked_last = 0;
    else {
      rb_raise(rb_eArgError,
               "sort_addr: unknown masked_position %s (expected :first or :last)",
               rb_id2name(mp_id));
    }
  }

  if ( argc <= 0 ) {
    rb_raise(rb_eArgError, "no arg given");
  }

  rb_check_carray_object(argv[0]);
  elements = NUM2SIZE(rb_ca_elements(argv[0]));

  for (j=0; j<argc; j++) {
    CArray *ca_j;
    rb_check_carray_object(argv[j]);
    if ( elements != NUM2SIZE(rb_ca_elements(argv[j])) ) {
      rb_raise(rb_eArgError, "elements mismatch");
    }
    /* Face gate: descend a Face to its storage and build attach / comparator
       / template output on that plain storage (this also removes the SEGV
       from a face-lifted NULL-ptr index output).  A fixlen storage sorts by
       memcmp (the default order for fixlen, as for a plain fixlen array); a
       numeric storage requires ORDERABLE so the numeric order equals the
       surface order, else it raises. */
    TypedData_Get_Struct(argv[j], CArray, &carray_data_type, ca_j);
    if ( ca_is_face(ca_j) ) {
      int orderable = ca_test_flag(ca_j, CA_FLAG_FACE_ORDERABLE_STORAGE);
      VALUE stripped = rb_ca_strip_face_value(argv[j]);
      CArray *sc;
      TypedData_Get_Struct(stripped, CArray, &carray_data_type, sc);
      if ( sc->data_type != CA_FIXLEN && ! orderable ) {
        rb_raise(rb_eArgError,
                 "sort_addr: Face-typed input (%s) is not orderable by "
                 "storage; use ca.parent to descend to storage",
                 rb_obj_classname(argv[j]));
      }
      argv[j] = stripped;
    }
  }

  base = xmalloc(sizeof(struct cmp_base));
  base->n = argc;
  base->masked_last = masked_last;
  base->ca = xmalloc(sizeof(CArray *)*base->n);

  for (j=0; j<argc; j++) {
    CArray *ca;
    TypedData_Get_Struct(argv[j], CArray, &carray_data_type, ca);
    base->ca[j] = ca;
    ca_attach(ca);
  }

  data = xmalloc(sizeof(struct sort_addr_key)*elements);
  for (i=0; i<elements; i++) {
    data[i].i = i;
    data[i].base = base;
  }

#ifdef HAVE_MERGESORT
  mergesort(data, elements, sizeof(struct sort_addr_key),
            (int (*)(const void*,const void*)) sort_addr_cmp);
#else
  qsort(data, elements, sizeof(struct sort_addr_key),
            (int (*)(const void*,const void*)) sort_addr_cmp);
#endif

  out = rb_ca_template_with_type(argv[0], INT2NUM(CA_SIZE), INT2NUM(0));
  TypedData_Get_Struct(out, CArray, &carray_data_type, co);
  q = (ca_size_t *) co->ptr;
  
  for (i=0; i<elements; i++) {
    *q = data[i].i;
    q++;
  }

  for (j=0; j<argc; j++) {
    ca_detach(base->ca[j]);
  }

  xfree(data);
  xfree(base->ca);  
  xfree(base);        

  return out;
}

/* Internal sort_addr_ki kernel entries (C-level only, no Ruby binding;
 * declared in the generated carray_kernels.c).  The _quick and _stable
 * variants implement the kind: dispatch; _ki itself is a 2-arg alias of
 * _quick retained for older callers.  The _mp ("masked position") twins
 * take an explicit masked_last so `sort` / `sort_copy` can pass the
 * masked_position: kwarg through (see MASKED_POSITION rev1 in
 * mkkernel.rb's MkKernel.sort doc). */
extern VALUE rb_ca_sort_addr_ki        (VALUE self, VALUE vaxis);
extern VALUE rb_ca_sort_addr_ki_quick  (VALUE self, VALUE vaxis);
extern VALUE rb_ca_sort_addr_ki_stable (VALUE self, VALUE vaxis);
extern VALUE rb_ca_sort_addr_ki_quick_mp  (VALUE self, VALUE vaxis, int masked_last);
extern VALUE rb_ca_sort_addr_ki_stable_mp (VALUE self, VALUE vaxis, int masked_last);
extern VALUE rb_ca_remap_new           (VALUE cary, VALUE rmapper); /* ca_obj_remap.c (sort view) */

/* sort_addr(axis: nil, kind: :quick, masked_position: :last) — returns
 * view-flat addresses that index a sort.  Two modes:
 *
 *   axis: nil (no kwarg) — flat lex form, equivalent to
 *                          CArray.sort_addr(self, masked_position:).
 *                          Shape is preserved (NOT flattened -- this is
 *                          the legacy "1 key" case of the class method's
 *                          multi-key lex sort, pinned by
 *                          test_sort_addr_no_arg_2d_preserves_shape).
 *                          kind: has no effect (the flat lex path uses
 *                          qsort/mergesort with its own comparator).
 *   axis: k             — per-fiber view-flat addresses along axis k.
 *                          Output shape == self.shape.  Dispatches to
 *                          sort_addr_ki (mkkernel `:sort` kind).
 *
 * kind: selects the sort algorithm for the axis: path:
 *   :quick  (default) — introsort with mergesort escape
 *   :stable           — bottom-up mergesort
 *
 * Both kinds are algorithmically stable (pair sort with index tie-
 * break); kind: chooses the performance characteristic only.
 *
 * masked_position: (:last default, or :first) picks which end masked
 * cells cluster to.  Effective on BOTH modes: the axis: path forwards
 * to sort_addr_ki's masked_last-aware _mp entries; the no-axis path
 * forwards to CArray.sort_addr's own masked_last-aware comparator
 * (sort_addr_cmp).  See {sort}'s doc for the underlying incomparable-
 * sentinel contract.
 */

/* C-callable entry: skip rb_scan_args (which depends on call-frame
 * keyword-splat state, only set by full Ruby method dispatch).
 *   axis = Qnil      -> flat (= CArray.sort_addr(self, masked_position:))
 *   axis = Integer   -> per-fiber axis path
 *   stable: 0 (quick, default) / non-zero (stable)
 *   masked_last: 1 (default, :last) / 0 (:first)
 *
 * Called by the Ruby binding rb_ca_sort_addr below, and externally
 * by rb_ca_sort_by_key in carray_order.c (always with axis given, so
 * the flat branch below is unreached from that caller). */
VALUE
rb_ca_sort_addr_c (VALUE self, VALUE axis, int stable, int masked_last)
{
  if ( NIL_P(axis) ) {
    /* Legacy flat: equivalent to CArray.sort_addr(self, masked_position:).
       kind: ignored for now (the flat path uses qsort/mergesort
       internally).  rb_ca_s_sort_addr's rb_pop_options handles a trailing
       Hash the same way regardless of call-frame keyword-splat state (it
       type-checks the last positional arg, not rb_keyword_given_p), so
       this raw C call is safe unlike the rb_scan_args "1:" pattern used
       elsewhere in this file. */
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(rb_intern("masked_position")),
                 masked_last ? ID2SYM(rb_intern("last")) : ID2SYM(rb_intern("first")));
    VALUE flat_argv[2] = { self, kw };
    return rb_ca_s_sort_addr(2, flat_argv, rb_cCArray);
  }
  return stable ? rb_ca_sort_addr_ki_stable_mp(self, axis, masked_last)
                : rb_ca_sort_addr_ki_quick_mp (self, axis, masked_last);
}

/* Ruby binding entry: parses (axis: / kind: / masked_position:) kwargs,
   then forwards. */
static VALUE
rb_ca_sort_addr (int argc, VALUE *argv, VALUE self)
{
  VALUE opts = Qnil;
  VALUE axis = Qnil;
  VALUE kind = Qnil;
  VALUE vmasked_position = Qnil;

  rb_scan_args(argc, argv, "0:", &opts);
  rb_scan_options(opts, "axis,kind,masked_position", &axis, &kind, &vmasked_position);

  int do_stable = 0;
  if ( ! NIL_P(kind) ) {
    static ID sym_quick = 0, sym_stable = 0;
    if ( ! sym_quick )  sym_quick  = rb_intern("quick");
    if ( ! sym_stable ) sym_stable = rb_intern("stable");
    ID kind_id = SYM2ID(kind);
    if      ( kind_id == sym_quick )  do_stable = 0;
    else if ( kind_id == sym_stable ) do_stable = 1;
    else {
      rb_raise(rb_eArgError,
               "sort_addr: unknown kind %s (expected :quick or :stable)",
               rb_id2name(kind_id));
    }
  }

  int masked_last = 1;
  if ( ! NIL_P(vmasked_position) ) {
    static ID sym_first = 0, sym_last = 0;
    if ( !sym_first ) sym_first = rb_intern("first");
    if ( !sym_last )  sym_last  = rb_intern("last");
    ID mp_id = SYM2ID(vmasked_position);
    if      ( mp_id == sym_last )  masked_last = 1;
    else if ( mp_id == sym_first ) masked_last = 0;
    else {
      rb_raise(rb_eArgError,
               "sort_addr: unknown masked_position %s (expected :first or :last)",
               rb_id2name(mp_id));
    }
  }

  return rb_ca_sort_addr_c(self, axis, do_stable, masked_last);
}

/* axis2addr(indices, axis: 0) — converts per-fiber axis-local indices
 * into row-major view-flat addresses into self.  For each cell at coord
 * c = (c_0, ..., c_(n-1)) in `indices`:
 *
 *     addr[c] = sum_{j != axis} c_j * stride_j + indices[c] * stride_axis
 *
 * where strides are row-major over self.shape
 * (stride_j = product of self.dim[j+1..n-1]).
 *
 * This is the canonical converter between the two axis-position
 * representations the *_index / *_addr kernel families produce:
 *
 *     a.min_index(axis: k) — axis-local scalar per fiber
 *     a.min_addr(axis: k)  — view-flat address per fiber
 *     flat_addrs = key.axis2addr(key.min_index(axis: k), axis: k)
 *     # == key.min_addr(axis: k)
 *
 * Sits underneath `take_along_axis`: the heavy "axis-local -> view-
 * flat" arithmetic lives here, and `take_along_axis` is a one-liner
 * on top of `flatten[axis2addr(...)]`.
 *
 * Shape rule: indices.ndim == self.ndim, indices.dim[j] == self.dim[j]
 * for all j != axis; indices.dim[axis] is free (the output along axis
 * can be any length).
 *
 * indices data_type: any integer kind (zero-copy if already CA_SIZE).
 * Negative indices: Python-style (-1 = last), normalized internally.
 * OOB indices: raises RangeError.  Default axis: 0; negative axis
 * Python-style.
 *
 * Returns: CArray of CA_SIZE, same shape as indices.
 */

/* C-callable entry: skip rb_scan_args (call-frame state dependency).
 * vaxis = Qnil treated as axis 0; Integer is taken as-is (negative
 * axis normalized internally).
 *
 * Called by the Ruby binding rb_ca_axis2addr below, and externally
 * by rb_ca_take_along_axis_c / rb_ca_put_along_axis in
 * carray_order.c. */
VALUE
rb_ca_axis2addr_c (VALUE self, VALUE vindices, VALUE vaxis)
{
  rb_check_carray_object(vindices);

  CArray *ca, *idx_ca, *out_ca;
  TypedData_Get_Struct(self,     CArray, &carray_data_type, ca);
  TypedData_Get_Struct(vindices, CArray, &carray_data_type, idx_ca);

  /* axis normalization + range check. */
  int axis_raw = NIL_P(vaxis) ? 0 : NUM2INT(vaxis);
  int axis = (axis_raw < 0) ? ((int) ca->ndim + axis_raw) : axis_raw;
  if ( axis < 0 || axis >= ca->ndim ) {
    rb_raise(rb_eIndexError,
             "axis2addr: axis %d out of range for ndim %d",
             axis_raw, (int) ca->ndim);
  }

  /* Shape rule: indices.ndim == self.ndim, dims match except at axis. */
  if ( idx_ca->ndim != ca->ndim ) {
    rb_raise(rb_eArgError,
             "axis2addr: indices.ndim (%d) must equal self.ndim (%d)",
             (int) idx_ca->ndim, (int) ca->ndim);
  }
  for ( int8_t j = 0; j < ca->ndim; j++ ) {
    if ( j == axis ) continue;
    if ( idx_ca->dim[j] != ca->dim[j] ) {
      rb_raise(rb_eArgError,
               "axis2addr: indices.dim[%d] (%lld) must equal "
               "self.dim[%d] (%lld)",
               (int) j, (long long) idx_ca->dim[j],
               (int) j, (long long) ca->dim[j]);
    }
  }

  /* indices data_type: integer kind accepted; cast to CA_SIZE if needed
     (zero-copy when already CA_SIZE via to_type identity). */
  if ( ! ca_is_integer_type(idx_ca) ) {
    rb_raise(rb_eArgError,
             "axis2addr: indices data_type must be integer kind (got %d)",
             (int) idx_ca->data_type);
  }
  volatile VALUE vidx_cast = vindices;
  CArray         *idx_cast = idx_ca;
  if ( idx_ca->data_type != CA_SIZE ) {
    vidx_cast = rb_funcall(vindices, rb_intern("to_type"), 1,
                           INT2NUM(CA_SIZE));
    TypedData_Get_Struct(vidx_cast, CArray, &carray_data_type, idx_cast);
  }

  /* Row-major view-flat strides for self (in cells). */
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t s = 1;
  for ( int8_t j = (int8_t)(ca->ndim - 1); j >= 0; j-- ) {
    strides[j] = s;
    s *= ca->dim[j];
  }
  ca_size_t axis_size = ca->dim[axis];

  /* Allocate output: same shape as indices, data_type CA_SIZE. */
  volatile VALUE vout =
    rb_ca_template_with_type(vidx_cast, INT2NUM(CA_SIZE), INT2NUM(0));
  TypedData_Get_Struct(vout, CArray, &carray_data_type, out_ca);

  /* out_ca is a freshly allocated entity (ptr already valid), so it needs
     no attach/sync/detach.  idx_cast may still be a view (CA_SIZE identity
     branch above), so its contig buffer is delivered via CA_WITH_BUFFER,
     which aliases when contig / materialises a view into scratch and scopes
     the attach/detach to the block. */
  ca_size_t *out_ptr = (ca_size_t *) out_ca->ptr;

  ca_size_t coord[CA_RANK_MAX];
  int       ndim = idx_cast->ndim;

  /* OOB is reported after the block: rb_raise from inside CA_WITH_BUFFER
     would longjmp past the scoped ca_detach and leak the attach (= doc
     constraint "restructure to break").  Record the offender, break, raise
     once the buffer lifecycle has closed. */
  ca_size_t  bad_k   = -1;
  ca_size_t  bad_raw = 0;

  ca_size_t       *idx_ptr;
  ca_size_t        n;
  CA_WITH_BUFFER(idx_cast, ca_size_t, idx_ptr, n) {
    for ( int8_t j = 0; j < ndim; j++ ) coord[j] = 0;
    for ( ca_size_t k = 0; k < n; k++ ) {
      /* Negative normalize + OOB check (raises on out-of-bounds). */
      ca_size_t raw = idx_ptr[k];
      ca_size_t norm = (raw < 0) ? (raw + axis_size) : raw;
      if ( norm < 0 || norm >= axis_size ) {
        bad_k = k; bad_raw = raw;
        break;
      }
      /* Compute flat addr: sum c_j * stride_j (with c_axis = norm). */
      ca_size_t addr = 0;
      for ( int8_t j = 0; j < ndim; j++ ) {
        if ( j == axis ) {
          addr += norm * strides[j];
        } else {
          addr += coord[j] * strides[j];
        }
      }
      out_ptr[k] = addr;
      /* Advance coord row-major (last axis ticks fastest). */
      for ( int8_t j = (int8_t)(ndim - 1); j >= 0; j-- ) {
        if ( ++coord[j] < idx_cast->dim[j] ) break;
        coord[j] = 0;
      }
    }
  }

  if ( bad_k >= 0 ) {
    rb_raise(rb_eRangeError,
             "axis2addr: indices[%lld] = %lld out of range [0, %lld) "
             "(after negative normalize)",
             (long long) bad_k, (long long) bad_raw, (long long) axis_size);
  }

  return vout;
}

/* Ruby binding entry: parses (indices, axis:) -> forwards to _c. */
static VALUE
rb_ca_axis2addr (int argc, VALUE *argv, VALUE self)
{
  VALUE vindices;
  VALUE opts = Qnil;
  VALUE vaxis = Qnil;

  rb_scan_args(argc, argv, "1:", &vindices, &opts);
  rb_scan_options(opts, "axis", &vaxis);
  return rb_ca_axis2addr_c(self, vindices, vaxis);
}


/* ===== sort / sort_copy (value & view surface, sibling of the
   sort_addr / axis2addr block above). =============== */

/* sort(axis: nil, kind: :quick, masked_position: :last) — returns a
 * CARemap view of self whose elements are sorted along the given axis.
 * When axis: is omitted, self is first flattened to 1-D and the entire
 * array is sorted (so the result is a 1-D view regardless of self.ndim).
 *
 * kind: selects the sort algorithm.  Both kinds are algorithmically
 * stable (pair sort with fiber-local index tie-break), so the order
 * is identical for equal values; the choice is a performance
 * characteristic:
 *
 *   :quick  (default) — portable textbook introsort with mergesort
 *                       escape.  Faster on random data.
 *   :stable           — portable textbook bottom-up mergesort with
 *                       insertion pre-pass and sorted-skip merge.
 *                       Slightly slower on random data but predictable
 *                       worst case.
 *
 * Mask handling: masked cells are an incomparable sentinel, the same
 * role NaN plays for float data types.  They are excluded from the value
 * comparison and clustered at one end of each fiber; masked_position:
 * picks which end (:last, default, or :first).  Relative order within
 * the masked cluster is unspecified (same contract as the < / > regions
 * of partition).  Since `sort` gathers through CARemap, each masked
 * cell's mask bit shows through at its new (clustered) position -- no
 * separate output mask handling is needed here.
 *
 * Dispatch:
 *   CA_FIXLEN   flows through sort_addr_ki's fixlen dialect (memcmp
 *               lexicographic order) + ca_remap_new, same view path as
 *               numeric.  kind: has no effect.
 *   CA_OBJECT   flows through sort_addr_ki's object dialect (Ruby `<=>`
 *               via rb_funcall) + ca_remap_new, same view path as
 *               numeric, both no-axis and axis: forms.
 */
static VALUE
rb_ca_sorted_view (int argc, VALUE *argv, VALUE self)
{
  VALUE rkw = Qnil;
  VALUE vaxis = Qnil;
  VALUE vkind = Qnil;
  VALUE vmasked_position = Qnil;

  /* Parse kwargs: `sort` accepts `axis:`, `kind:`, `masked_position:`. */
  rb_scan_args(argc, argv, "0:", &rkw);
  rb_scan_options(rkw, "axis,kind,masked_position", &vaxis, &vkind, &vmasked_position);

  /* Resolve kind: -> do_stable.  :quick (default) = introsort; :stable
     = bottom-up mergesort.  Both share the same pair layout and produce
     identical orderings; only the algorithm differs. */
  int do_stable = 0;
  if ( !NIL_P(vkind) ) {
    static ID sym_quick = 0, sym_stable = 0;
    if ( !sym_quick )  sym_quick  = rb_intern("quick");
    if ( !sym_stable ) sym_stable = rb_intern("stable");
    ID kind_id = SYM2ID(vkind);
    if      ( kind_id == sym_quick )  do_stable = 0;
    else if ( kind_id == sym_stable ) do_stable = 1;
    else {
      rb_raise(rb_eArgError,
               "sort: unknown kind %s (expected :quick or :stable)",
               rb_id2name(kind_id));
    }
  }

  /* Resolve masked_position: -> masked_last.  :last (default) or :first. */
  int masked_last = 1;
  if ( !NIL_P(vmasked_position) ) {
    static ID sym_first = 0, sym_last = 0;
    if ( !sym_first ) sym_first = rb_intern("first");
    if ( !sym_last )  sym_last  = rb_intern("last");
    ID mp_id = SYM2ID(vmasked_position);
    if      ( mp_id == sym_last )  masked_last = 1;
    else if ( mp_id == sym_first ) masked_last = 0;
    else {
      rb_raise(rb_eArgError,
               "sort: unknown masked_position %s (expected :first or :last)",
               rb_id2name(mp_id));
    }
  }

  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Build target view (flatten for no-arg, identity for axis: kwarg)
     before mask handling: rb_ca_flatten re-propagates the mask field
     from the parent, so any mask stripping must happen on the post-
     flatten target. */
  VALUE target;
  VALUE vaxis_use;
  if ( NIL_P(vaxis) ) {
    target    = rb_ca_flatten(self);
    vaxis_use = INT2NUM(0);
  } else {
    target    = self;
    vaxis_use = vaxis;
  }

  /* sort_addr_ki_{quick,stable}_mp returns a CA_SIZE same-shape array of
     view-flat addresses into target, with masked cells clustered at
     masked_position: (mask field present but nothing actually masked is
     handled gracefully too -- the split degenerates to a no-op).  Feed
     directly to ca_remap_new to produce the sorted view; the remap gather
     carries target's mask bits through, so masked cells land at their
     clustered position still marked masked -- no extra output-mask step
     needed. */
  volatile VALUE sigma_addr = do_stable
                            ? rb_ca_sort_addr_ki_stable_mp(target, vaxis_use, masked_last)
                            : rb_ca_sort_addr_ki_quick_mp (target, vaxis_use, masked_last);
  {
    VALUE obj = rb_ca_remap_new(target, sigma_addr);
    CA_FACE_LIFT_IF_FACE(obj, self, ca);
    return obj;
  }
}

/* sort_copy(axis: nil, kind: :quick, masked_position: :last) — eager
 * counterpart to {sort}.  Returns a fresh entity CArray of the same
 * shape and data_type as self, with elements sorted along the given
 * axis (no-arg flattens to 1-D, same convention as sort).
 *
 * Implementation: per-fiber gather + sort + scatter via
 * CA_FOR_EACH_FIBER_INOUT.  Bypasses the sort_addr_ki + ca_remap_new
 * view chain that sort uses: a single gather + sort + scatter per
 * fiber, no pair struct, no view layer.  This fast path is numeric-only
 * and mask-free (CA_KERNEL_NO_MASK below).
 *
 * CA_FIXLEN and masked input both delegate to {sort} + copy instead of
 * duplicating the fixlen dialect / mask-position split in this per-
 * fiber loop: masked_position: is forwarded unchanged.  Masked cells
 * keep their masked-ness (the view's remap gather carries the mask bit
 * through, and .copy materializes it), clustered at masked_position:
 * within each fiber -- same contract as {sort}.
 */
static VALUE
rb_ca_sort_copy (int argc, VALUE *argv, VALUE self)
{
  VALUE rkw = Qnil;
  VALUE vaxis = Qnil;
  VALUE vkind = Qnil;
  VALUE vmasked_position = Qnil;

  rb_scan_args(argc, argv, "0:", &rkw);
  rb_scan_options(rkw, "axis,kind,masked_position", &vaxis, &vkind, &vmasked_position);

  /* Resolve kind:: :quick (default) = portable textbook quicksort,
     :stable = portable textbook bottom-up mergesort. */
  int do_stable = 0;
  if ( !NIL_P(vkind) ) {
    static ID sym_quick = 0, sym_stable = 0;
    if ( !sym_quick )  sym_quick  = rb_intern("quick");
    if ( !sym_stable ) sym_stable = rb_intern("stable");
    ID kind_id = SYM2ID(vkind);
    if      ( kind_id == sym_quick )  do_stable = 0;
    else if ( kind_id == sym_stable ) do_stable = 1;
    else {
      rb_raise(rb_eArgError,
               "sort_copy: unknown kind %s (expected :quick or :stable)",
               rb_id2name(kind_id));
    }
  }

  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* CA_FIXLEN and masked input: the per-fiber path below covers
     unmasked numeric data types only.  Delegate to {sort} (which handles
     both the fixlen dialect and the masked_position split) + copy to
     get the same shape/class contract as the fast path. */
  if ( ca_is_fixlen_type(ca) || ca_has_mask(ca) ) {
    VALUE sv_kw = rb_hash_new();
    if ( !NIL_P(vaxis) )            rb_hash_aset(sv_kw, ID2SYM(rb_intern("axis")), vaxis);
    if ( !NIL_P(vkind) )            rb_hash_aset(sv_kw, ID2SYM(rb_intern("kind")), vkind);
    if ( !NIL_P(vmasked_position) ) rb_hash_aset(sv_kw, ID2SYM(rb_intern("masked_position")), vmasked_position);
    VALUE sv_argv[1] = { sv_kw };
    int   sv_argc = ( NIL_P(vaxis) && NIL_P(vkind) && NIL_P(vmasked_position) ) ? 0 : 1;
    VALUE obj = rb_ca_copy(rb_ca_sorted_view(sv_argc, sv_argv, self));
    CA_FACE_LIFT_IF_FACE(obj, self, ca);
    return obj;
  }

  /* Build target view (flatten for no-arg, identity for axis: kwarg).
     Unmasked past this point (guarded above), so no mask handling is
     needed here -- see the analogous block in rb_ca_sorted_view. */
  VALUE target;
  VALUE vaxis_use;
  if ( NIL_P(vaxis) ) {
    target    = rb_ca_flatten(self);
    vaxis_use = INT2NUM(0);
  } else {
    target    = self;
    vaxis_use = vaxis;
  }

  CArray *cat;
  TypedData_Get_Struct(target, CArray, &carray_data_type, cat);

  /* Normalize axis (negative -> +ndim, range check). */
  int axis = NUM2INT(vaxis_use);
  if ( axis < 0 ) axis += cat->ndim;
  if ( axis < 0 || axis >= cat->ndim ) {
    rb_raise(rb_eArgError, "sort_copy: axis %d out of range for ndim %d",
             NUM2INT(vaxis_use), cat->ndim);
  }

  /* data_type check: ALL_NUMERIC only (CA_INT8..CA_FLOAT64).
     Complex / object are rejected here; CA_OBJECT goes through the
     axis: lift in rb_ca_sorted_view, and complex sort semantics
     differ enough that we do not pick a default. */
  if ( cat->data_type < CA_INT8 || cat->data_type > CA_FLOAT64 ) {
    rb_raise(rb_eCADataTypeError,
             "sort_copy: data_type %d not supported "
             "(expected one of: i8, u8, i16, u16, i32, u32, i64, u64, f32, f64)",
             cat->data_type);
  }

  /* Allocate output: same shape and data_type as target
     (bytes=0 = preserve native bytes). */
  volatile VALUE vout = rb_ca_template_with_type(target,
                                                 INT2NUM(cat->data_type),
                                                 INT2NUM(0));
  CArray *cao;
  TypedData_Get_Struct(vout, CArray, &carray_data_type, cao);

  /* Per-fiber sort via the CA_FOR_EACH_FIBER_INOUT catalog macro.
     The kernel_iterator engine guarantees pi/po contig delivery
     (aliasing the parent when possible, materialising into per-fiber
     or whole-view scratch otherwise), so the author body is stride-
     free: copy contig input -> contig output, sort in place. */
  ca_size_t fiber_n_for_check = (ca_size_t) cat->dim[axis];
  ca_size_t bytes   = (ca_size_t) cat->bytes;
  ca_iter_state st_in, st_out;
  char       *pi, *po;
  ca_size_t   n;

  /* Per-fiber aux buffer for the stable path: allocated once outside
     the fiber loop and reused across fibers (all fibers share the
     same axis length and data_type). */
  void *aux = NULL;
  if ( do_stable ) {
    aux = xmalloc((size_t) cat->dim[axis] * (size_t) bytes);
  }
  CA_FOR_EACH_FIBER_INOUT(st_in, st_out, cat, cao, (int8_t) axis,
                          CA_KERNEL_NO_MASK, pi, po, n) {
    (void) fiber_n_for_check;
    memcpy(po, pi, (size_t) n * (size_t) bytes);
    if ( do_stable ) {
      switch ( cat->data_type ) {
        case CA_INT8:    ca_sort_merge_i8 ((int8_t    *) po, (int8_t    *) aux, n); break;
        case CA_UINT8:   ca_sort_merge_u8 ((uint8_t   *) po, (uint8_t   *) aux, n); break;
        case CA_INT16:   ca_sort_merge_i16((int16_t   *) po, (int16_t   *) aux, n); break;
        case CA_UINT16:  ca_sort_merge_u16((uint16_t  *) po, (uint16_t  *) aux, n); break;
        case CA_INT32:   ca_sort_merge_i32((int32_t   *) po, (int32_t   *) aux, n); break;
        case CA_UINT32:  ca_sort_merge_u32((uint32_t  *) po, (uint32_t  *) aux, n); break;
        case CA_INT64:   ca_sort_merge_i64((int64_t   *) po, (int64_t   *) aux, n); break;
        case CA_UINT64:  ca_sort_merge_u64((uint64_t  *) po, (uint64_t  *) aux, n); break;
        case CA_FLOAT32: {
          ca_size_t fin = ca_partition_nan_f32((float32_t *) po, n);
          ca_sort_merge_f32((float32_t *) po, (float32_t *) aux, fin);
          break;
        }
        case CA_FLOAT64: {
          ca_size_t fin = ca_partition_nan_f64((double *) po, n);
          ca_sort_merge_f64((double *) po, (double *) aux, fin);
          break;
        }
        default:
          rb_raise(rb_eCADataTypeError,
                   "sort_copy: BUG: unexpected data_type %d", cat->data_type);
      }
    } else {
      switch ( cat->data_type ) {
        case CA_INT8:    ca_sort_quick_i8 ((int8_t    *) po, n); break;
        case CA_UINT8:   ca_sort_quick_u8 ((uint8_t   *) po, n); break;
        case CA_INT16:   ca_sort_quick_i16((int16_t   *) po, n); break;
        case CA_UINT16:  ca_sort_quick_u16((uint16_t  *) po, n); break;
        case CA_INT32:   ca_sort_quick_i32((int32_t   *) po, n); break;
        case CA_UINT32:  ca_sort_quick_u32((uint32_t  *) po, n); break;
        case CA_INT64:   ca_sort_quick_i64((int64_t   *) po, n); break;
        case CA_UINT64:  ca_sort_quick_u64((uint64_t  *) po, n); break;
        case CA_FLOAT32: {
          ca_size_t fin = ca_partition_nan_f32((float32_t *) po, n);
          ca_sort_quick_f32((float32_t *) po, fin);
          break;
        }
        case CA_FLOAT64: {
          ca_size_t fin = ca_partition_nan_f64((double *) po, n);
          ca_sort_quick_f64((double *) po, fin);
          break;
        }
        default:
          rb_raise(rb_eCADataTypeError,
                   "sort_copy: BUG: unexpected data_type %d", cat->data_type);
      }
    }
  }
  if ( aux ) xfree(aux);

  return vout;
}


void
Init_carray_sort (void)
{
  rb_define_singleton_method(rb_cCArray, "sort_addr", rb_ca_s_sort_addr, -1);
  rb_define_method(rb_cCArray, "sort_addr", rb_ca_sort_addr, -1);
  rb_define_method(rb_cCArray, "axis2addr", rb_ca_axis2addr, -1);

  /* `sort` returns a CARemap view (no-axis flattens to 1-D);
     `sort_copy` is the eager entity counterpart.  Both accept axis:
     and kind: kwargs -- see the function comments above. */
  rb_define_method(rb_cCArray, "sort", rb_ca_sorted_view, -1);
  rb_define_method(rb_cCArray, "sort_copy", rb_ca_sort_copy, -1);
}
