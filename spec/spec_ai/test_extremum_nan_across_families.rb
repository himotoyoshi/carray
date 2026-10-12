require "test/unit"
require "carray"

# A NaN loses every contest of a minimum or a maximum: it never displaces a
# number, the first number displaces it, and only a set of nothing but NaN
# answers NaN.
#
# Which of -0.0 and 0.0 a minimum answers is not settled: the core keeps the
# first of two equal values when it walks the cells in order, but its
# vectorised reductions split the cells into lanes, so on a long array the
# answer depends on where the zeros sit.  The inputs below are short enough
# that every family walks them in order and keeps the first.
#
# The core reductions decide this with CA_EXTREMUM_REPLACES.  Each family
# below answers min / max over groups of cells of its own; this checks every
# one against the core reduction over the same cells, so a family that
# decides the contest by itself and decides it differently fails here.
#
# Not covered: pmin / pmax and cummin / cummax, which use C99 fmin / fmax.
# Those pick either zero of -0.0 and 0.0, so they can differ from the core
# on the sign of a zero.

class TestExtremumNaNAcrossFamilies < Test::Unit::TestCase

  N = Float::NAN

  SEQUENCES = [
    [N, 3.0, 1.0, 2.0],
    [3.0, N, 1.0, 2.0],
    [2.0, 1.0, N, N],
    [N, N, N, N],
    [-0.0, 0.0, 0.0, -0.0],
    [0.0, -0.0, -0.0, 0.0],
    [2.0, 1.0, 4.0, 3.0],
  ]

  TYPES = [CA_FLOAT64, CA_FLOAT32]

  # Same value, NaN equal to NaN, and the sign of a zero distinguished.
  def assert_same_value (want, got, label)
    if want.is_a?(Float) && got.is_a?(Float)
      if want.nan?
        assert(got.nan?, "#{label}: want NaN, got #{got}")
      else
        assert_equal(want, got, label)
        assert_equal(want.zero? && 1.0 / want < 0, got.zero? && 1.0 / got < 0,
                     "#{label}: sign of zero")
      end
    else
      assert_equal(want, got, label)
    end
  end

  def core (type, vals, op)
    a = CArray.new(type, [vals.size])
    a[] = vals
    a.send(op)
  end

  def each_case
    TYPES.each do |type|
      SEQUENCES.each do |vals|
        a = CArray.new(type, [vals.size])
        a[] = vals
        yield type, vals, a, "#{CArray.data_type_name(type)} #{vals.inspect}"
      end
    end
  end

  # Cells 0 and 2 go to slot 0, cells 1 and 3 to slot 1, over a slot that
  # starts at NaN (so the cells alone decide).
  def test_scatter
    idx = CA_INT64([0, 1, 0, 1])
    each_case do |type, vals, a, label|
      [[:scatter_min!, :min], [:scatter_max!, :max]].each do |m, op|
        b = CArray.new(type, [2])
        b[] = N
        b.send(m, idx, a)
        assert_same_value(core(type, [vals[0], vals[2]], op), b[0], "#{label} #{m} slot 0")
        assert_same_value(core(type, [vals[1], vals[3]], op), b[1], "#{label} #{m} slot 1")
      end
    end
  end

  # Groups of cells 0..1 and 2..3, without and with an axis.
  def test_group_by_category
    cat = CArray.int32(4).seq!.div(2).categorize
    each_case do |type, vals, a, label|
      g = a.group_by_category(cat)
      [:min, :max].each do |op|
        got = g.send(op)
        assert_same_value(core(type, vals[0, 2], op), got[0], "#{label} #{op} group 0")
        assert_same_value(core(type, vals[2, 2], op), got[1], "#{label} #{op} group 1")
      end
      mm = g.minmax
      assert_same_value(core(type, vals[0, 2], :min), mm[0][0], "#{label} minmax")
      assert_same_value(core(type, vals[0, 2], :max), mm[1][0], "#{label} minmax")

      a2 = CArray.new(type, [2, vals.size])
      a2[0, nil] = vals
      a2[1, nil] = vals.reverse
      g2 = a2.group_by_category(cat)
      [:min, :max].each do |op|
        got = g2.send(op, axis: 1)
        [vals, vals.reverse].each_with_index do |row, r|
          assert_same_value(core(type, row[0, 2], op), got[0, r], "#{label} #{op}(axis: 1) row #{r} group 0")
          assert_same_value(core(type, row[2, 2], op), got[1, r], "#{label} #{op}(axis: 1) row #{r} group 1")
        end
      end
    end
  end

  # Non-overlapping tiles of two cells.
  def test_blocks
    each_case do |type, vals, a, label|
      [:min, :max].each do |op|
        got = a.blocks(2).send(op)
        assert_same_value(core(type, vals[0, 2], op), got[0], "#{label} blocks #{op} 0")
        assert_same_value(core(type, vals[2, 2], op), got[1], "#{label} blocks #{op} 1")
      end
    end
  end

  # A meld and a stack of two halves reduce to the reduction of the whole.
  def test_meld_and_stack
    each_case do |type, vals, a, label|
      h0 = a[0..1]
      h1 = a[2..3]
      [:min, :max].each do |op|
        want = core(type, vals, op)
        assert_same_value(want, CArray.meld([h0, h1]).send(op), "#{label} meld #{op}")
        assert_same_value(want, CArray.stack([h0, h1]).send(op), "#{label} stack #{op}")
      end
    end
  end
end
