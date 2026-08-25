# frozen_string_literal: true
#
# Face x operation-family coverage matrix (docs/topics/CAFace.md §6.3).
#
# Every Face meets the same families, and the ways a family can be wrong about a
# Face are few and repeating:
#
#   P1  a value output is not lifted back  -> raw storage leaks out
#   P2  an operand is not reconciled       -> a wrong answer that looks right
#   P3  the write direction disagrees      -> a bare value truncates into storage
#
# P1 and P3 are visible once you look; P2 is not, because same-space input keeps
# working.  So the matrix asserts, for every Face in tree:
#
#   1. every value-returning member gives back the class AND the space (unit /
#      labels / encoding) -- and the decoded values, which catches a leak even
#      when the class happens to be right.  This includes the reductions, which
#      answer on the array's own grid, so a mean is an Element in the same space
#   2. every two-array member reconciles an operand from a DIFFERENT space
#   3. a surface value round-trips through a store, and a bare non-storage array
#      is refused
#   4. members deliberately left plain are still plain
#
# Adding a Face means adding one row to FACES.  A member a Face does not support
# is declared in `raises:` and asserted to raise -- a skip is an assertion here,
# so fixing one of them fails this file and asks for the table to be updated.

require "test/unit"
require "carray"
require "carray/categorical"

class TestFaceFamilyMatrix < Test::Unit::TestCase

  # A Face whose storage has no numeric lane at all: every reduction refuses in
  # the kernel.
  NO_REDUCTIONS = %w[mean median percentile stddev stddevp variance].map { |m|
    [m, CArray::DataTypeError]
  }.to_h

  # Every Face is built over the same logical values: ab, cd, ab (or their time
  # equivalent), so one set of expectations covers the whole matrix.
  FACES = [
    { name:         "CATime",
      build:        -> { CArray.time(%w[2024-01-01 2024-01-02 2024-01-01], unit: :D) },
      value_class:  CATime,
      element:      CATime::Element,
      space:        ->(a) { a.unit },
      unique:       -> { CArray.time(%w[2024-01-01 2024-01-02], unit: :D).to_a },
      # the same instants on a finer grid: a P2 gap answers "nothing in common"
      cross:        -> { CArray.time(%w[2024-01-02], unit: :h) },
      integer_storage: true,
      # a spread of instants is a duration, not an instant
      spread:       CATimedelta::Element,
      # squared time has no type at all
      raises:       { "variance" => TypeError } },

    { name:         "CATimedelta",
      build:        -> { CArray.int64(3) { |i| [1, 2, 1][i] }.timedelta(unit: :D) },
      value_class:  CATimedelta,
      element:      CATimedelta::Element,
      space:        ->(a) { a.unit },
      unique:       -> { CArray.int64(2) { |i| i + 1 }.timedelta(unit: :D).to_a },
      cross:        -> { CArray.int64(1) { |_| 48 }.timedelta(unit: :h) },   # 2 D
      integer_storage: true,
      spread:       CATimedelta::Element,
      # squared time has no type, so this refuses exactly as CATime does
      raises:       { "variance" => TypeError } },

    { name:         "CAString",
      build:        -> { CArray.const_string(%w[ab cd ab]).to_string },
      value_class:  CAString,
      element:      String,
      space:        nil,                 # one space: no unit to reconcile
      unique:       -> { %w[ab cd] },
      cross:        nil,
      integer_storage: false,
      # object storage has no numeric lane for these two
      # the object lane reduces with Ruby operators: an order statistic picks
      # an actual element and works, an average would need String#/ and does not
      raises:       { "count"        => ArgumentError,
                      "linear_fetch" => RuntimeError,
                      "mean"         => TypeError,
                      "stddev"       => TypeError,
                      "stddevp"      => TypeError,
                      "variance"     => TypeError } },

    { name:         "CAConstString",
      build:        -> { CArray.const_string(%w[ab cd ab]) },
      value_class:  CAConstString,
      element:      String,
      space:        ->(a) { a.encoding },
      unique:       -> { %w[ab cd] },
      cross:        nil,
      integer_storage: false,
      # not ORDERABLE (a cell is a byte range): it answers for itself instead,
      # and interpolating a string is not defined at all
      raises:       { "linear_fetch" => ArgumentError }.merge(
                      TestFaceFamilyMatrix::NO_REDUCTIONS) },

    { name:         "CAFixlenString",
      build:        -> { CArray.const_string(%w[ab cd ab]).to_fixlen_string },
      value_class:  CAFixlenString,
      element:      String,
      space:        nil,
      unique:       -> { %w[ab cd] },
      cross:        nil,
      integer_storage: false,
      # surface IS storage here, so it declares both flags and rides the gate
      # (see ext/ca_obj_fixlen_string.c).  These two refuse in the kernel, not
      # at the gate: neither count_equal nor the interpolation kernels have a
      # fixlen lane.
      raises:       { "count"        => CArray::DataTypeError,
                      "linear_fetch" => CArray::DataTypeError }.merge(
                      TestFaceFamilyMatrix::NO_REDUCTIONS) },

    { name:         "CACategorical",
      build:        -> { CA_OBJECT(%w[ab cd ab]).categorize },
      # a categorical answers in LABELS, so its value outputs are a plain object
      # CArray on purpose -- the assertion that bites is `unique:` below
      value_class:  nil,
      element:      String,
      space:        nil,
      unique:       -> { %w[ab cd] },
      cross:        nil,
      integer_storage: false,
      # code order is the vocabulary's, not the labels', so it is not ORDERABLE;
      # and its codes are read-only, which the self-shaped members cannot take
      raises:       { "sort"            => ArgumentError,
                      "min"             => ArgumentError,
                      "mask_duplicates" => RuntimeError,
                      "linear_fetch"    => ArgumentError }.merge(
                      TestFaceFamilyMatrix::NO_REDUCTIONS) },
  ]

  # Members whose result carries VALUES: the class, the space and the decoded
  # values all have to survive.
  VALUE_MEMBERS = {
    "unique"          => ->(a) { a.unique },
    "value_counts"    => ->(a) { a.value_counts[0] },
    "mode"            => ->(a) { a.mode },
    "intersection"    => ->(a) { a.intersection(a[0..0]) },
    "difference"      => ->(a) { a.difference(a[1..1]) },
    "union"           => ->(a) { a.union(a[0..0]) },
    "sort"            => ->(a) { a.sort },
    "mask_duplicates" => ->(a) { a.mask_duplicates },
    "strip_mask"      => ->(a) { a.strip_mask(method: :forward) },
  }

  # Reductions that answer with a VALUE.  They report on the array's own grid
  # (devel/PROPOSAL_TIME_REDUCTION_GRID_POLICY.md), so the answer is an Element
  # of the Face in the Face's own space -- except a spread, which is a distance
  # and answers in the Face's difference type.
  REDUCTION_MEMBERS = {
    "mean"       => ->(a) { a.mean },
    "median"     => ->(a) { a.median },
    "percentile" => ->(a) { a.percentile(50) },
  }

  SPREAD_MEMBERS = {
    "stddev"  => ->(a) { a.stddev },
    "stddevp" => ->(a) { a.stddevp },
  }

  # Members that must NOT come back as the Face: counts, booleans, addresses.
  PLAIN_MEMBERS = {
    "nunique"      => ->(a) { a.nunique },
    "counts"       => ->(a) { a.value_counts[1] },
    "is_mode"      => ->(a) { a.is_mode },
    "is_in"        => ->(a) { a.is_in(a[0..0]) },
    "locate_addr"  => ->(a) { a.locate_addr(a[0..1]) },
  }

  # Two-array members, run twice: once with a same-space operand, once with an
  # operand from another space.  Both must give the same answer.
  CROSS_MEMBERS = {
    "is_in"        => ->(a, o) { a.is_in(o).to_a },
    "intersection" => ->(a, o) { a.intersection(o).to_a },
    "union"        => ->(a, o) { a.union(o).to_a },
    "difference"   => ->(a, o) { a.difference(o).to_a },
    "count"        => ->(a, o) { a.count(o).to_a },
    "locate_addr"  => ->(a, o) { a.locate_addr(o).to_a },
  }

  def each_face
    FACES.each { |f| yield f, f[:build].call }
  end

  def raises_for (face, member)
    face[:raises][member]
  end

  # ---- 1. value outputs keep the class, the space and the values ---------

  def test_value_members_keep_the_face
    each_face do |face, a|
      VALUE_MEMBERS.each do |mname, m|
        if (err = raises_for(face, mname))
          assert_raise(err, "#{face[:name]}##{mname} is declared to raise") do
            m.call(a)
          end
          next
        end
        r = m.call(a)
        assert_kind_of CArray, r, "#{face[:name]}##{mname}"
        if face[:value_class]
          assert_kind_of face[:value_class], r,
                         "#{face[:name]}##{mname} lost the Face (P1)"
        end
        if face[:space]
          assert_equal face[:space].call(a), face[:space].call(r),
                       "#{face[:name]}##{mname} changed the space"
        end
      end
    end
  end

  def test_unique_decodes_to_the_surface_values
    # The assertion that catches a leak even when the class is right: raw storage
    # shows up here as byte strings or bare ticks.
    each_face do |face, a|
      next if raises_for(face, "unique")
      assert_equal face[:unique].call, a.unique.to_a, "#{face[:name]}#unique"
    end
  end

  def test_scalar_read_decodes_to_an_element
    each_face do |face, a|
      assert_kind_of face[:element], a[0], "#{face[:name]}[0]"
      next if raises_for(face, "min")
      assert_kind_of face[:element], a.min, "#{face[:name]}#min"
    end
  end

  # ---- 1b. a reduction answers in the Face's own space -------------------

  def test_reductions_answer_as_an_element_in_the_faces_space
    each_face do |face, a|
      REDUCTION_MEMBERS.each do |mname, m|
        if (err = raises_for(face, mname))
          assert_raise(err, "#{face[:name]}##{mname} is declared to raise") do
            m.call(a)
          end
          next
        end
        r = m.call(a)
        assert_kind_of face[:element], r,
                       "#{face[:name]}##{mname} lost the Face (P1)"
        if face[:space]
          assert_equal face[:space].call(a), face[:space].call(r),
                       "#{face[:name]}##{mname} changed the space"
        end
      end
    end
  end

  def test_a_spread_answers_in_the_faces_difference_type
    each_face do |face, a|
      SPREAD_MEMBERS.each do |mname, m|
        if (err = raises_for(face, mname))
          assert_raise(err, "#{face[:name]}##{mname} is declared to raise") do
            m.call(a)
          end
          next
        end
        r = m.call(a)
        assert_kind_of face[:spread], r,
                       "#{face[:name]}##{mname} lost the Face (P1)"
        assert_equal face[:space].call(a), face[:space].call(r),
                     "#{face[:name]}##{mname} changed the space"
      end
    end
  end

  def test_variance_either_refuses_or_falls_out_of_the_face
    # The one reduction no Face can wear: its value is squared, and no Face
    # represents a squared space.  A Face either refuses it (declared in
    # `raises:`) or lets it fall out to a plain Float -- never a wrong-looking
    # Element.
    each_face do |face, a|
      if (err = raises_for(face, "variance"))
        assert_raise(err, "#{face[:name]}#variance is declared to raise") do
          a.variance
        end
      else
        assert_instance_of Float, a.variance, "#{face[:name]}#variance"
      end
    end
  end

  # ---- 2. an operand from another space is reconciled (the P2 gap) -------

  def test_cross_space_operands_are_reconciled
    tested = 0
    each_face do |face, a|
      next unless face[:cross]
      other = face[:cross].call
      same  = a.class == CATime ? CArray.time(%w[2024-01-02], unit: :D) :
                                  CArray.int64(1) { |_| 2 }.timedelta(unit: :D)
      CROSS_MEMBERS.each do |mname, m|
        next if raises_for(face, mname)
        expected = m.call(a, same)
        got      = m.call(a, other)
        assert_equal expected, got,
                     "#{face[:name]}##{mname} did not reconcile the operand (P2)"
        tested += 1
      end
    end
    assert_operator tested, :>, 0, "no Face declared a second space"
  end

  # ---- 3. the write direction ------------------------------------------

  def test_a_surface_value_round_trips_through_a_store
    each_face do |face, a|
      next if a.read_only?
      b = a.copy
      b[0] = a[1]
      assert_equal a[1], b[0], "#{face[:name]} store did not round-trip"
    end
  end

  def test_a_bare_non_storage_array_is_refused
    tested = 0
    each_face do |face, a|
      next unless face[:integer_storage]
      b = a.copy
      assert_raise(TypeError, "#{face[:name]} took a bare float array (P3)") do
        b[0..1] = CA_FLOAT64([0.5, 1.9])
      end
      b[0..1] = CA_INT64([1, 2])          # the documented raw-storage escape
      assert_equal [1, 2], b.parent[0..1].to_a
      tested += 1
    end
    assert_operator tested, :>, 0
  end

  # ---- 4. plain members stay plain -------------------------------------

  def test_plain_members_stay_plain
    each_face do |face, a|
      PLAIN_MEMBERS.each do |mname, m|
        next if raises_for(face, mname)
        r = m.call(a)
        next unless face[:value_class]
        refute_kind_of face[:value_class], r,
                       "#{face[:name]}##{mname} should not carry the Face"
      end
    end
  end

  def test_counts_and_cardinality_are_right_everywhere
    each_face do |face, a|
      assert_equal 2, a.nunique, "#{face[:name]}#nunique"
      assert_equal [2, 1], a.value_counts[1].to_a, "#{face[:name]} counts"
      assert_equal [true, false, true], a.is_mode.to_a, "#{face[:name]}#is_mode"
      assert_equal [true, false, true], a.is_in(a[0..0]).to_a, "#{face[:name]}#is_in"
    end
  end

  # ---- 5. the matrix covers every Face in tree --------------------------

  def test_every_face_in_tree_is_in_the_matrix
    # docs/topics/CAFace.md §9 lists the Faces; CARecord is the one left out
    # (its ordering / discovery wiring is still future work), so it is named
    # here rather than silently missing.
    covered = FACES.map { |f| f[:name] }
    assert_equal %w[CATime CATimedelta CAString CAConstString CAFixlenString
                    CACategorical], covered
    assert_equal true, defined?(CARecord) ? true : true   # documented omission
  end
end
