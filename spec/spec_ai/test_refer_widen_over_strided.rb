# frozen_string_literal: true
#
# A CARefer whose cell is wider than its parent's (two float64 read as one
# complex128) covers several parent elements per cell.  When the parent is a
# view whose consecutive elements are not adjacent in memory (a transpose, a
# flip, a column slice), the view must still read and write the parent's
# elements in the parent's own order -- the same answer as referring a copy.

require "test/unit"
require_relative "../../lib/carray"

class TestReferWidenOverStrided < Test::Unit::TestCase

  B = CArray.struct { float64 :lo; float64 :hi }

  # Parents of shape [4, 2] float64, built in different ways over one root.
  def parents
    {
      contiguous: -> { CArray.float64(4, 2).seq! },
      transpose:  -> { CArray.float64(2, 4).seq!.transpose },
      flip:       -> { CArray.float64(4, 2).seq!.flip(1) },
      column_cut: -> { CArray.float64(4, 4).seq![nil, 1..2] },
      every_other: -> { CArray.float64(8, 2).seq![CA_INT64([0, 2, 4, 6]), nil] },
      stepped:    -> { CArray.float64(4, 3).seq![nil, [0, 2]] },
      transpose_of_block: -> { CArray.float64(3, 6).seq![0..1, 1..4].transpose },
    }
  end

  def test_bulk_read_matches_copy
    parents.each do |name, make|
      p = make.call
      expected = p.copy.refer(CA_CMPLX128, [4]).to_a
      assert_equal expected, p.refer(CA_CMPLX128, [4]).to_a, name.to_s
      assert_equal expected, p.refer(CA_CMPLX128, [4]).copy.to_a, name.to_s
    end
  end

  def test_cell_read_matches_copy
    parents.each do |name, make|
      p = make.call
      expected = p.copy.refer(CA_CMPLX128, [4]).to_a
      c = p.refer(CA_CMPLX128, [4])
      4.times { |i| assert_equal expected[i], c[i], "#{name} [#{i}]" }
    end
  end

  def test_cell_write_reaches_both_parent_elements
    parents.each do |name, make|
      p = make.call
      c = p.refer(CA_CMPLX128, [4])
      c[2] = Complex(-1.0, -2.0)
      assert_equal [-1.0, -2.0], p[2, nil].to_a, name.to_s
    end
  end

  def test_cell_write_leaves_other_cells
    parents.each do |name, make|
      p = make.call
      before = p.to_a
      p.refer(CA_CMPLX128, [4])[1] = Complex(100.0, 200.0)
      after = p.to_a
      before[1] = [100.0, 200.0]
      assert_equal before, after, name.to_s
    end
  end

  def test_bulk_write_matches_copy
    parents.each do |name, make|
      p = make.call
      vals = [Complex(1, 2), Complex(3, 4), Complex(5, 6), Complex(7, 8)]
      p.refer(CA_CMPLX128, [4])[] = vals
      assert_equal [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [7.0, 8.0]], p.to_a,
                   name.to_s
    end
  end

  def test_fixlen_record_fields_over_strided_parent
    parents.each do |name, make|
      p = make.call
      rec = CARecord.wrap(p.refer(CA_FIXLEN, [4], bytes: 16), B)
      assert_equal p[nil, 0].to_a, rec["lo"].to_a, name.to_s
      assert_equal p[nil, 1].to_a, rec["hi"].to_a, name.to_s
      rec["hi"][] = -9.0
      assert_equal [-9.0] * 4, p[nil, 1].to_a, name.to_s
    end
  end

  def test_fixlen_back_to_float64_round_trip
    parents.each do |name, make|
      p = make.call
      back = p.refer(CA_FIXLEN, [4], bytes: 16).refer(CA_FLOAT64, [4, 2])
      assert_equal p.to_a, back.to_a, name.to_s
    end
  end

  def test_three_wide_cell
    t = CArray.float64(3, 4).seq!.transpose      # [4, 3]
    f = t.refer(CA_FIXLEN, [4], bytes: 24).refer(CA_FLOAT64, [4, 3])
    assert_equal t.to_a, f.to_a
    f[1, 2] = -5.0
    assert_equal(-5.0, t[1, 2])
  end
end
