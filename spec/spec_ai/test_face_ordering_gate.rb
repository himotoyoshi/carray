# frozen_string_literal: true
#
# Face ordering / search gate — 2026-07-02.
#
# Face-typed CArray (CATime / CATimedelta / CARecord / any user-
# defined Face) has surface data_type = CA_FIXLEN with arbitrary storage
# semantic underneath.  Ordering / search primitives (sort_addr, bsearch,
# search, linear_section, ...) previously fell into the CA_FIXLEN memcmp
# branch and produced silent-wrong results (and, in one hand-written
# path, SEGV via face-lifted NULL-ptr template output).
#
# The gate has two axes (PROPOSAL_FACE_ORDERING_GATE §Future work):
#
#   ORDERABLE_STORAGE (commit 1): storage native order == surface order.
#     Faces that declare it (CATime / CATimedelta) may descend to
#     storage for the sort family (sort_addr / sort_index / partition /
#     rank).  Non-orderable Faces (CARecord, exotic user Faces) still raise.
#
#   COMPARABLE_STORAGE + to_comparable (commit 2): external query may be
#     compared against storage.  Governs the search family.
#
# Faces that declare neither still raise (silent-wrong is worse than raise).
#
# See devel/PROPOSAL_FACE_ORDERING_GATE.md for the design.

require "test/unit"
require "carray"

class TestFaceOrderingGate < Test::Unit::TestCase

  T0 = Time.new(2026, 7, 1).to_i

  # ascending time reference (sort_addr = identity)
  def dt_ref
    CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
  end

  # shuffled time reference (sort_addr is a real permutation)
  def dt_shuffled
    order = [3, 1, 4, 1, 5, 9, 2, 6].to_a   # note the duplicate 1
    CArray.int64(order.size) { |i| T0 + order[i] * 3600 }.time(unit: :s)
  end

  def td_ref
    CArray.int64(5) { |i| [3, 1, 4, 1, 5].to_a[i] * 1000 }.timedelta(unit: :ms)
  end

  # CARecord over a struct: fixlen storage, so the sort family descends to
  # the fixlen bytes and orders by memcmp (the default for fixlen storage).
  def rec_ref
    s = CArray.struct(pack: 1) { uint16 :h; uint32 :p }
    rs = CARecord.new(s, 4)
    rs[0] = s.new(h: 3, p: 10)
    rs[1] = s.new(h: 1, p: 20)
    rs[2] = s.new(h: 2, p: 30)
    rs[3] = s.new(h: 1, p: 5)
    rs
  end

  # A Face with NUMERIC storage but no ORDERABLE flag: descending would
  # numeric-sort into an order that need not match the surface, so the sort
  # family rejects it (unlike a fixlen Face, which has memcmp as a default).
  class NonOrderableNumFace < CAObject
    def initialize (parent)
      super(CA_INT64, parent.dim, parent: parent, face: true)  # no orderable_storage
    end
  end

  def num_face
    NonOrderableNumFace.new(CArray.int64(4) { |i| [3, 1, 2, 1].to_a[i] })
  end

  # ----- ORDERABLE Face: sort_addr descends to storage ---------------

  def test_sort_addr_flat_on_datetime_returns_storage_order
    ref = dt_shuffled
    idx = ref.sort_addr
    # index CArray, not a Face
    assert_kind_of CArray, idx
    refute_kind_of CATime, idx
    # storage gathered by idx must be non-decreasing
    raw = ref.parent
    gathered = idx.to_a.map { |k| raw[k] }
    assert_equal gathered.sort, gathered
  end

  def test_sort_addr_axis_on_datetime_works
    ref = dt_ref
    assert_equal (0..23).to_a, ref.sort_addr(axis: 0).to_a
  end

  def test_sort_addr_flat_on_timedelta_works
    idx = td_ref.sort_addr
    raw = td_ref.parent
    gathered = idx.to_a.map { |k| raw[k] }
    assert_equal gathered.sort, gathered
  end

  def test_sort_index_on_datetime_works
    ref = dt_shuffled
    idx = ref.sort_index
    raw = ref.parent
    gathered = idx.to_a.map { |k| raw[k] }
    assert_equal gathered.sort, gathered
  end

  def test_partition_index_on_datetime_works
    ref = dt_shuffled
    k = 3
    idx = ref.partition_index(k)
    raw = ref.parent
    gathered = idx.to_a.map { |j| raw[j] }
    sorted = raw.to_a.sort
    # kth element is in its final sorted position
    assert_equal sorted[k], gathered[k]
  end

  def test_class_sort_addr_multi_key_descends_to_storage
    a = dt_shuffled
    b = dt_shuffled
    idx = CArray.sort_addr(a, b)
    assert_kind_of CArray, idx
    ra = a.parent
    gathered = idx.to_a.map { |j| ra[j] }
    assert_equal gathered.sort, gathered
  end

  # ----- sort_addr on non-Face works (regression pin) ----------------

  def test_sort_addr_on_plain_carray_still_works
    # dt_ref.parent is the raw int64 CArray; sort_addr should work.
    idx = dt_ref.parent.sort_addr
    assert_equal (0..23).to_a, idx.to_a
  end

  # ----- fixlen Face sorts by memcmp (default for fixlen storage) ----

  def test_sort_index_on_fixlen_face_is_memcmp
    # rec_ref packs {uint16 h; uint32 p}; memcmp orders big-endian-agnostic
    # by the raw bytes.  h = [3,1,2,1], p = [10,20,30,5]; the two h=1 rows
    # tie-break on p (20 vs 5), so 3 (p=5) precedes 1 (p=20).
    idx = rec_ref.sort_index
    assert_kind_of CArray, idx
    refute rec_ref.class == idx.class          # index is plain, not a Face
    assert_equal [3, 1, 2, 0], idx.to_a
  end

  def test_sort_addr_on_fixlen_face_is_memcmp
    assert_equal [3, 1, 2, 0], rec_ref.sort_addr.to_a
  end

  def test_partition_index_on_fixlen_face_works
    idx = rec_ref.partition_index(1)
    assert_kind_of CArray, idx
    assert_equal (0..3).to_a, idx.to_a.sort   # a valid permutation
  end

  # ----- non-orderable NUMERIC Face still rejects sort family --------

  def test_sort_addr_rejects_non_orderable_numeric_face
    assert_raise(ArgumentError) { num_face.sort_addr }
  end

  def test_sort_index_rejects_non_orderable_numeric_face
    assert_raise(ArgumentError) { num_face.sort_index }
  end

  def test_partition_index_rejects_non_orderable_numeric_face
    assert_raise(ArgumentError) { num_face.partition_index(1) }
  end

  # ----- COMPARABLE (via to_comparable): time search works -------

  def test_bsearch_on_datetime_works_via_to_comparable
    r = dt_ref   # sorted ascending
    q = CArray.int64(3) { |i| T0 + [0, 3600 * 5, 3600 * 23].to_a[i] }.time(unit: :s)
    assert_equal [0, 5, 23], r.bsearch(q).to_a
  end

  def test_search_on_datetime_works_via_to_comparable
    r = dt_ref
    q = CArray.int64(3) { |i| T0 + [3600 * 2, 3600 * 10, 3600 * 20].to_a[i] }.time(unit: :s)
    assert_equal [2, 10, 20], r.search(q).to_a
  end

  def test_bsearch_addr_on_datetime_works_via_to_comparable
    r = dt_ref
    q = CArray.int64(1) { |_| T0 + 3600 * 5 }.time(unit: :s)
    assert_equal [5], r.bsearch_addr(q).to_a
  end

  def test_timedelta_bsearch_works
    td = CArray.int64(5) { |i| i * 60 }.timedelta(unit: :s)
    q  = CArray.int64(2) { |i| [60, 180].to_a[i] }.timedelta(unit: :s)
    assert_equal [1, 3], td.bsearch(q).to_a
  end

  def test_locate_addr_on_datetime_works
    # The motivating use case: locate_addr composes sort_addr + bsearch,
    # both of which are Face-gated.  With ORDERABLE + to_comparable it runs.
    axis  = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    query = CArray.int64(3) { |i| T0 + [2, 10, 20].to_a[i] * 3600 }.time(unit: :s)
    assert_equal [2, 10, 20], query.locate_addr(axis).to_a
  end

  # ----- search cross-unit auto-cast (to_comparable) -----------------

  def test_bsearch_coarse_to_fine_query_converts
    # axis :ns, query :s -- coarse query is lifted (x10^9) losslessly.
    axis = CArray.int64(6) { |i| (T0 + i * 3600) * 10**9 }.time(unit: :ns)
    q    = CArray.int64(2) { |i| T0 + [2, 4].to_a[i] * 3600 }.time(unit: :s)
    assert_equal [2, 4], axis.bsearch(q).to_a
  end

  def test_bsearch_fine_to_coarse_exact_converts
    # axis :s, query :ns all landing exactly on whole seconds -- converts.
    axis = CArray.int64(6) { |i| T0 + i * 3600 }.time(unit: :s)
    q    = CArray.int64(2) { |i| (T0 + [2, 4].to_a[i] * 3600) * 10**9 }.time(unit: :ns)
    assert_equal [2, 4], axis.bsearch(q).to_a
  end

  def test_bsearch_fine_to_coarse_with_remainder_raises
    # axis :s, query :ns with a sub-second remainder -- lossy, so raise.
    axis = CArray.int64(6) { |i| T0 + i * 3600 }.time(unit: :s)
    q    = CArray.int64(2) { |i| (T0 + [2, 4].to_a[i] * 3600) * 10**9 + [0, 500_000_000].to_a[i] }.time(unit: :ns)
    assert_raise(ArgumentError) { axis.bsearch(q) }
  end

  def test_bsearch_cross_group_calendar_coarsens_on_boundary
    # A time :M value HAS an instant, so a cross-group cast is possible
    # (convert_instant!, unlike a duration): a :D query on a month boundary
    # coarsens exactly to the :M axis and searches.
    axis = CArray.int64(3) { |i| 672 + i }.time(unit: :M)   # 2026-01,02,03
    onb  = CArray.int64(1) { |_| 20454 }.time(unit: :D)     # 2026-01-01 (month start)
    assert_equal [0], axis.bsearch(onb).to_a
    # a :D query NOT on a month boundary cannot coarsen to :M -> raises
    off  = CArray.int64(1) { |_| 20460 }.time(unit: :D)     # 2026-01-07
    assert_raise(ArgumentError) { axis.bsearch(off) }
  end

  def test_bsearch_cross_group_calendar_widens_to_fixed
    # the reverse direction: a :M query widens exactly to a fixed-length axis
    axis = CArray.int64(3) { |i| 672 + i }.time(unit: :M)   # 2026-01,02,03
    axis_s = axis.to_comparable(axis)                            # keep :M
    q    = axis.value                                            # storage
    # widen a :M query onto an hourly axis
    hourly = CArray.time_series("2026-01-01T00:00:00Z", count: 48, unit: :h)
    assert_equal [0], hourly.bsearch(CArray.int64(1) { |_| 672 }.time(unit: :M)).to_a
  end

  def test_cross_group_week_vs_calendar_raises
    # :W is the one cross-group case that stays impossible: month / year
    # starts are not aligned to a week grid.
    wk = CArray.int64(1) { |_| 1 }.time(unit: :W)  # 1970-01-08 (not a month start)
    mo = CArray.int64(3) { |i| 672 + i }.time(unit: :M)
    # :M/:Y widening to :W is always impossible (month starts are off the week grid)
    assert_raise(ArgumentError) { wk.to_comparable(mo) }
    # :W coarsening to :M raises when the week is not on a month boundary
    assert_raise(ArgumentError) { mo.to_comparable(wk) }
  end

  def test_bsearch_calendar_year_to_month_converts
    # :M axis, :Y query -- lifted x12 losslessly.
    axis = CArray.int64(3) { |i| 672 + i * 12 }.time(unit: :M)  # 2026-01, 2027-01, 2028-01
    q    = CArray.int64(2) { |i| [56, 57].to_a[i] }.time(unit: :Y)
    assert_equal [0, 1], axis.bsearch(q).to_a
  end

  def test_timedelta_fine_to_coarse_remainder_raises
    td = CArray.int64(4) { |i| i * 60 }.timedelta(unit: :s)
    q  = CArray.int64(1) { |_| 60_500 }.timedelta(unit: :ms)   # 60.5 s
    assert_raise(ArgumentError) { td.bsearch(q) }
  end

  def test_to_comparable_rejects_foreign_class
    assert_raise(TypeError) { dt_ref.to_comparable(td_ref) }
  end

  # ----- Face query against plain self rejects -----------------------

  def test_bsearch_rejects_face_query_when_self_is_plain
    # Reference-side reconcile (PROPOSAL_TO_COMPARABLE_RECEIVER_FLIP): only a
    # Face *reference* drives reconciliation.  Here r is plain int64 (not a
    # Face), so there is no reference to bring the Face query into its space;
    # the query is coerced to the reference's data_type, and a Face has no
    # view of its values in another one -- it says so, naming #to_numeric and
    # #parent.  Descend via q.parent to search the storage directly.
    r = dt_ref.parent
    q = CArray.int64(3) { |i| T0 + [0, 3600 * 5, 3600 * 23].to_a[i] }.time(unit: :s)
    err = assert_raise(TypeError) { r.bsearch(q) }
    assert_match(/no numeric conversion/, err.message)
  end

  # ----- linear_section / linear_fetch on time (float-space) -----
  #
  # linear/nearest work in float64 space (fractional axis position), so the
  # query is cast to the axis unit as float -- no exact-multiple requirement
  # (nearest is approximate); only cross-group casts raise.

  def test_linear_section_on_datetime_on_grid
    axis = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    q    = CArray.int64(3) { |i| T0 + [0, 5, 23].to_a[i] * 3600 }.time(unit: :s)
    assert_equal [0.0, 5.0, 23.0], axis.linear_section(q).to_a
  end

  def test_linear_section_on_datetime_fractional
    axis = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    q    = CArray.int64(2) { |i| T0 + 5 * 3600 + [1800, 3 * 3600].to_a[i] }.time(unit: :s)
    assert_equal [5.5, 8.0], axis.linear_section(q).to_a
  end

  def test_linear_section_cross_unit_ms_fractional
    axis = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    # :ms query 1.8e6 ms past the 5h grid point = +1800 s = +0.5 grid cell.
    # Cross-unit alignment is exact (whole seconds); the +0.5 GRID-cell
    # fraction lives in the axis unit, so the continuous index is fractional.
    q = CArray.int64(2) { |i| (T0 + 5 * 3600) * 1000 + [1_800_000, 3_600_000].to_a[i] }.time(unit: :ms)
    assert_equal [5.5, 6.0], axis.linear_section(q).to_a
  end

  def test_linear_section_cross_unit_sub_unit_remainder_raises
    # A :ms query with sub-second precision on a :s axis truncates on the
    # unit alignment (same to_comparable path as search), so it raises --
    # the fractional-nearest tolerance is a GRID-cell concept, not a licence
    # to drop query resolution below the axis unit.
    axis = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    q    = CArray.int64(1) { |_| (T0 + 5 * 3600) * 1000 + 500 }.time(unit: :ms)  # +0.5 s
    assert_raise(ArgumentError) { axis.linear_section(q) }
  end

  def test_gate_widens_calendar_query_to_fixed_axis
    # linear_section / locate ride the same ORDERABLE gate as bsearch: the
    # cross-group cast is done by to_comparable.  A :M query widens exactly to
    # the :s axis unit (2026-07 -> the axis' first instant, T0).
    axis = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    q    = CArray.int64(1) { |_| 678 }.time(unit: :M)  # 2026-07
    conv = axis.to_comparable(q)
    assert_equal :s, conv.unit.base
    assert_equal [Time.utc(2026, 7, 1).to_i], conv.parent.to_a  # UTC instant of 2026-07
  end

  def test_linear_section_wrong_class_raises
    axis = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    q    = CArray.int64(1) { |_| 100 }.timedelta(unit: :s)
    assert_raise(TypeError) { axis.linear_section(q) }
  end

  def test_linear_fetch_on_datetime
    axis = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    # linear_fetch returns a value (not a position), so unlike linear_section it
    # re-lifts: a CATime on the axis' own unit, rounded to that grid.  The
    # 3.5 index lands on a whole second here, so it is exact.
    got = axis.linear_fetch(CArray.float64(2) { |i| [3.5, 10.0].to_a[i] })
    assert_instance_of CATime, got
    assert_equal :s, got.unit.base
    assert_equal [T0 + 3.5 * 3600, T0 + 10.0 * 3600].map(&:to_i), got.parent.to_a
  end

  def test_locate_nearest_addr_on_datetime_same_unit
    axis  = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    query = CArray.int64(3) { |i| T0 + [5, 12, 20].to_a[i] * 3600 + 700 }.time(unit: :s)
    assert_equal [5, 12, 20], query.locate_nearest_addr(axis).to_a
  end

  def test_locate_nearest_addr_on_datetime_cross_unit
    axis  = CArray.int64(24) { |i| T0 + i * 3600 }.time(unit: :s)
    # :ms query near the 5h/20h grid points (round to nearest hour)
    query = CArray.int64(2) { |i| (T0 + [5, 20].to_a[i] * 3600) * 1000 + [400_000, -100_000].to_a[i] }.time(unit: :ms)
    assert_equal [5, 20], query.locate_nearest_addr(axis).to_a
  end

  def test_gate_coarsen_fixed_query_to_calendar_axis
    # the coarsening direction: a fixed query lands on the :M axis only when it
    # sits exactly on a month boundary, else raises (no silent truncation).
    axis = CArray.int64(3) { |i| 672 + i }.time(unit: :M)
    onb  = CArray.int64(1) { |_| 20454 }.time(unit: :D)  # 2026-01-01
    assert_equal [672], axis.to_comparable(onb).parent.to_a
    off  = CArray.int64(1) { |_| 20460 }.time(unit: :D)  # 2026-01-07
    assert_raise(ArgumentError) { axis.to_comparable(off) }
  end

  # ----- SEGV pin: the original reproducer must not crash ------------

  def test_original_segv_reproducer_now_returns_index
    # Pre-gate: this SEGV'd at ext/carray_sort.c via face-lifted NULL-ptr
    # template output.  With ORDERABLE_STORAGE the entry now strips to
    # storage, so the template output is a plain index CArray and the
    # write target is valid.
    raw = CArray.int64(24) { |i| T0 + i * 3600 }
    ref = raw.time(unit: :s)
    idx = ref.sort_addr
    assert_equal (0..23).to_a, idx.to_a
  end

  # ----- sort / partition delegate via time.rb (unchanged) -------

  def test_sort_on_datetime_still_works_via_ruby_delegate
    # lib/carray/time.rb overrides sort to call parent.sort.time.
    # This gate does not affect that path.
    r = dt_ref
    sorted = r.sort
    assert_kind_of CATime, sorted
  end

  # ----- error message references escape hatch -----------------------

  def test_error_message_points_to_parent_descent
    err = assert_raise(ArgumentError) { num_face.sort_addr }
    assert_match(/parent/, err.message)
  end

  # ----- frame-less Face: COMPARABLE direct-storage path -------------
  #
  # A frame-less Face (no unit / single-interpretation storage relabel)
  # declares COMPARABLE_STORAGE via the CAObject kwarg, so the search
  # kernel strips it (and a Face query) to storage and compares directly --
  # no to_comparable delegate needed.

  class RelabelFace < CAObject          # ORDERABLE + COMPARABLE
    def initialize (parent)
      super(CA_INT64, parent.dim, parent: parent, face: true,
            orderable_storage: true, comparable_storage: true)
    end
  end

  class OrderOnlyFace < CAObject         # ORDERABLE only
    def initialize (parent)
      super(CA_INT64, parent.dim, parent: parent, face: true,
            orderable_storage: true)
    end
  end

  def relabel_ref
    RelabelFace.new(CArray.int64(6) { |i| [10, 30, 50, 70, 90, 110].to_a[i] })
  end

  def test_comparable_face_bsearch_plain_query
    q = CArray.int64(2) { |i| [30, 90].to_a[i] }
    assert_equal [1, 4], relabel_ref.bsearch(q).to_a
  end

  def test_comparable_face_bsearch_face_query
    f = relabel_ref
    qf = RelabelFace.new(CArray.int64(2) { |i| [30, 90].to_a[i] })
    assert_equal [1, 4], f.bsearch(qf).to_a
  end

  def test_comparable_face_sort_addr
    assert_equal (0..5).to_a, relabel_ref.sort_addr.to_a
  end

  def test_orderable_only_face_sort_works_but_search_raises
    # ORDERABLE licenses sort_addr (self-scope ordering).  Search compares an
    # external value against storage, which a non-COMPARABLE Face does not
    # license: a plain query (direct storage compare) AND a Face query with no
    # to_comparable both raise.  Storage search goes through g.parent.
    g = OrderOnlyFace.new(CArray.int64(6) { |i| [10, 30, 50, 70, 90, 110].to_a[i] })
    assert_equal (0..5).to_a, g.sort_addr.to_a
    assert_raise(ArgumentError) { g.bsearch(CArray.int64(1) { |_| 30 }) }        # plain
    assert_raise(ArgumentError) { g.bsearch(RelabelFace.new(CArray.int64(1) { |_| 30 })) }  # Face, no to_comparable
    assert_equal [1], g.parent.bsearch(CArray.int64(1) { |_| 30 }).to_a          # explicit storage escape
  end

  def test_face_flag_kwargs_require_face_mode
    raw = CArray.int64(3) { |i| i }
    assert_raise(ArgumentError) { CAObject.new(CA_INT64, [3], orderable_storage: true) }
    assert_raise(ArgumentError) { CAObject.new(CA_INT64, [3], comparable_storage: true) }
  end

  # ----- frame-less Face: generic linear path (no Ruby delegate) -----
  #
  # linear_section / linear_fetch descend an ORDERABLE Face axis to storage
  # in ca_linear_prep (C), so a frame-less numeric-relabel Face participates
  # generically -- no per-Face Ruby override.  The fractional index is defined
  # in storage space (which for a numeric-relabel Face is the coordinate).

  def linear_ref
    RelabelFace.new(CArray.int64(6) { |i| [0, 2, 4, 6, 8, 10].to_a[i] })
  end

  def test_frameless_face_linear_section_plain_query
    # axis [0,2,4,6,8,10]: query 1 -> 0.5, query 7 -> 3.5.
    assert_equal [0.5, 3.5], linear_ref.linear_section(CArray.int64(2) { |i| [1, 7].to_a[i] }).to_a
  end

  def test_frameless_face_linear_section_face_query
    # COMPARABLE axis strips a Face query to storage.
    qf = RelabelFace.new(CArray.int64(2) { |i| [1, 7].to_a[i] })
    assert_equal [0.5, 3.5], linear_ref.linear_section(qf).to_a
  end

  def test_frameless_face_linear_fetch
    assert_equal [1.0, 7.0], linear_ref.linear_fetch(CArray.float64(2) { |i| [0.5, 3.5].to_a[i] }).to_a
  end

  def test_orderable_only_face_linear_rejects_plain_and_unreconcilable_query
    # ORDERABLE axis descends, but not COMPARABLE: linear_section places an
    # external value, so both a plain query and a Face query without
    # to_comparable raise.  Storage interpolation goes through g.parent.
    g  = OrderOnlyFace.new(CArray.int64(6) { |i| [0, 2, 4, 6, 8, 10].to_a[i] })
    qf = RelabelFace.new(CArray.int64(1) { |_| 1 })
    assert_raise(ArgumentError) { g.linear_section(qf) }                                   # Face, no to_comparable
    assert_raise(ArgumentError) { g.linear_section(CArray.int64(2) { |i| [1, 7].to_a[i] }) }  # plain
    assert_equal [0.5, 3.5], g.parent.linear_section(CArray.int64(2) { |i| [1, 7].to_a[i] }).to_a
  end

  def test_non_orderable_face_linear_still_rejected
    assert_raise(ArgumentError) { rec_ref.linear_section(CArray.float64(1) { 1.0 }) }
  end

end
