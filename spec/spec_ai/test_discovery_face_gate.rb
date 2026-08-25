# frozen_string_literal: true
#
# Face gate on the value-hash discovery family (unique / value_counts / mode /
# is_in / set operations / locate_addr / categorize).
#
# The value hash keys on raw cells, so a Face is descended to its storage,
# operands are reconciled through the reference (to_comparable), and outputs
# that carry *values* are lifted back.  Two things were wrong before the gate:
# the value outputs came back as raw storage bytes, and the two-array members
# compared the ticks of whichever unit each side happened to carry -- so a
# cross-unit is_in / intersection answered wrongly but plausibly.
#
# A Face without ORDERABLE keeps its old behaviour: its equality is not its
# storage's, so descending would answer the wrong question (CAConstString's
# cells are (start, end) byte ranges).  See
# devel/PROPOSAL_DISCOVERY_FAMILY_FACE_GATE.md.

require "test/unit"
require "carray"
require "carray/categorical"

class TestDiscoveryFaceGate < Test::Unit::TestCase

  def days(*strs)
    CArray.time(strs, unit: :D)
  end

  # ---- value outputs come back as the Face ------------------------------

  def test_unique_returns_the_face_on_its_own_unit
    t = days("2024-01-01", "2024-01-02", "2024-01-01", "2024-01-03")
    u = t.unique
    assert_instance_of CATime, u
    assert_equal t.unit, u.unit
    assert_equal [19723, 19724, 19725], u.parent.to_a
    assert_equal :int64, u.parent.data_type     # storage, not the fixlen surface
  end

  def test_value_counts_lifts_the_values_and_leaves_the_counts_plain
    t = days("2024-01-01", "2024-01-02", "2024-01-01")
    values, counts = t.value_counts
    assert_instance_of CATime, values
    assert_equal t.unit, values.unit
    assert_equal [19723, 19724], values.parent.to_a
    assert_instance_of CArray, counts
    assert_equal [2, 1], counts.to_a
  end

  def test_mode_returns_the_face
    t = days("2024-01-01", "2024-01-02", "2024-01-01")
    m = t.mode
    assert_instance_of CATime, m
    assert_equal [19723], m.parent.to_a
  end

  def test_mode_per_axis_returns_the_face
    # CATime rides the Ruby per-fiber path (its surface reads as fixlen);
    # CATimedelta rides the C kernel (its surface is int64).  Both lift.
    m = CArray.int64(2, 3) { |i, j| 19723 + (j == 2 ? 0 : j) }.time(unit: :D)
    cols = m.mode(axis: 1)
    assert_equal 1, cols.size
    assert_instance_of CATime, cols[0]
    assert_equal m.unit, cols[0].unit
    assert_equal [19723, 19723], cols[0].parent.to_a

    td = CArray.int64(2, 3) { |i, j| (j == 2 ? 0 : j) + 1 }.timedelta(unit: :D)
    tcols = td.mode(axis: 1)
    assert_instance_of CATimedelta, tcols[0]
    assert_equal [1, 1], tcols[0].parent.to_a
  end

  def test_set_operations_return_the_face
    a = days("2024-01-01", "2024-01-02", "2024-01-03")
    b = days("2024-01-02", "2024-01-05")
    assert_instance_of CATime, a.intersection(b)
    assert_equal [19724],               a.intersection(b).parent.to_a
    assert_equal [19723, 19725],        a.difference(b).parent.to_a
    assert_equal [19723, 19724, 19725, 19727], a.union(b).parent.to_a
    assert_equal a.unit, a.union(b).unit
  end

  def test_timedelta_is_symmetric
    td = CArray.int64(3) { |i| [1, 2, 1][i] }.timedelta(unit: :D)
    assert_instance_of CATimedelta, td.unique
    assert_equal [1, 2], td.unique.parent.to_a
    assert_instance_of CATimedelta, td.value_counts[0]
  end

  def test_categorize_labels_agree_between_its_two_paths
    # The discovery path (sort_labels:) went through mask_duplicates and already
    # produced Element labels; the one-pass path emitted raw storage bytes.
    t = days("2024-01-01", "2024-01-02", "2024-01-01")
    fast = t.categorize
    slow = t.categorize(sort_labels: true)
    assert_equal slow.labels, fast.labels
    assert_instance_of CATime::Element, fast.labels[0]
    assert_equal [0, 1, 0], fast.codes.to_a
    assert_equal 2, fast.count(t[0])
  end

  # ---- two-array members reconcile the unit (the wrong answers) ---------

  def test_cross_unit_membership_and_set_operations
    d = days("2024-01-01", "2024-01-02", "2024-01-03")   # ticks [19723, 19724, 19725]
    h = CArray.time(["2024-01-02", "2024-01-05"], unit: :h)  # ticks [473376, 473448]
    # 2024-01-02 is the shared instant; comparing raw ticks would find nothing.
    assert_equal [false, true, false], d.is_in(h).to_a
    assert_equal [19724],              d.intersection(h).parent.to_a
    assert_equal [19723, 19725],       d.difference(h).parent.to_a
    assert_equal [19723, 19724, 19725, 19727], d.union(h).parent.to_a
  end

  def test_cross_unit_locate_addr_uses_the_reference_as_the_reference
    # locate_addr's reference is the *argument*, so the gate runs the other way
    # round: d reconciles h.
    d = days("2024-01-01", "2024-01-02", "2024-01-03")
    h = CArray.time(["2024-01-02"], unit: :h)
    assert_equal [1], h.locate_addr(d).to_a
    assert_equal [1], h.locate_nearest_addr(d).to_a
  end

  def test_cross_unit_agrees_with_the_already_gated_search_family
    d = days("2024-01-01", "2024-01-02", "2024-01-03")
    h = CArray.time(["2024-01-02"], unit: :h)
    assert_equal 1, d.bsearch(h[0])                       # search family
    assert_equal [1], d.count(h[0..0]).to_a               # count family
    assert_equal [false, true, false], d.is_in(h).to_a    # discovery family
  end

  def test_same_unit_operands_are_unchanged
    a = days("2024-01-01", "2024-01-02", "2024-01-03")
    b = days("2024-01-02", "2024-01-05")
    assert_equal [false, true, false], a.is_in(b).to_a
    assert_equal [19724], a.intersection(b).parent.to_a
  end

  # ---- members that were already right stay right ----------------------

  def test_count_shaped_and_boolean_members_stay_plain
    t = days("2024-01-01", "2024-01-02", "2024-01-01")
    assert_equal 2, t.nunique
    assert_equal [true, false, true], t.is_mode.to_a
    assert_instance_of CATime, t.mask_duplicates      # self-shaped: keeps the Face
    assert_equal [false, false, true], t.mask_duplicates.is_masked.to_a
  end

  # ---- a non-ORDERABLE Face answers for itself instead ------------------

  def test_non_orderable_face_does_not_ride_the_gate
    # CAConstString cells are (start, end) byte ranges, so storage equality is
    # not string equality: descending would count "ab" twice.  It is not
    # ORDERABLE, so the gate leaves it alone, and the class answers in string
    # space itself (lib/carray/const_string.rb).
    cs = CArray.const_string(%w[ab cd ab ef])
    assert_equal 3, cs.nunique
    assert_instance_of CAConstString, cs.unique
    assert_equal %w[ab cd ef], cs.unique.to_a
    assert_equal [true, false, true, false], cs.is_in(%w[ab]).to_a
  end

  def test_categorical_answers_in_label_space
    # A categorical is not ORDERABLE either (code order is the vocabulary's,
    # not the labels'), so it too answers for itself -- in labels, not codes.
    cat = CA_OBJECT(%w[b a b c]).categorize
    assert_equal %w[b a c], cat.unique.to_a
    assert_equal [%w[b a c], [2, 1, 1]], cat.value_counts.map(&:to_a)
    assert_equal [false, true, false, true], cat.is_in(%w[a c]).to_a
  end

  # ---- plain arrays are untouched --------------------------------------

  def test_plain_arrays_unchanged
    assert_equal [3, 1, 2], CA_INT32([3, 1, 3, 2]).unique.to_a
    assert_equal [["a", "b"], [2, 1]],
                 CA_OBJECT(%w[a b a]).value_counts.map(&:to_a)
    assert_equal [true, false], CA_INT32([1, 5]).is_in(CA_INT32([1, 2])).to_a
    assert_equal [1, 0], CA_INT32([5, 3]).locate_addr(CA_INT32([3, 5, 7])).to_a
    assert_equal ["ab"], CArray.fixlen(3, bytes: 2) { |i| %w[ab cd ab][i] }.mode.to_a
  end
end
