# CF.1 pin: count_equal_ki kernel (= first user of mkkernel value_arg: DSL).
#
# Verifies the value_arg framework end-to-end through the public count(v)
# surface (numeric path forwards to rb_ca_count_equal_ki in carray_count.c):
#   - DSL accepts value_arg: { target: :T_IN }
#   - dispatcher pops first positional argv as Ruby VALUE, casts per-src
#   - kernel body references `value_arg` as plain C identifier
#   - integrates with mask_policy: :min_count + fill_value option
#   - per-axis reduction via standard mkkernel machinery
#
# The kernel has no dev-only Ruby binding (bind_ruby: false); count(v) is
# the sole user-facing entry and a faithful forwarder, so these pins cover
# the value_arg DSL contract via the public surface.

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestCF1CountEqualKi < Test::Unit::TestCase

  def test_basic_flatten
    a = CArray.int32(10).seq           # [0,1,2,...,9]
    assert_equal(1, a.count(5))
    assert_equal(1, a.count(0))
    assert_equal(1, a.count(9))
    assert_equal(0, a.count(99))
  end

  def test_basic_returns_integer
    a = CArray.int32(5).seq
    # full reduction returns Ruby Integer (= LL2NUM scalar), not CArray
    assert_kind_of(Integer, a.count(2))
  end

  def test_masked_cells_skipped
    a = CArray.int32(10).seq
    a[3] = UNDEF
    a[5] = UNDEF
    # Masked cells (= 3, 5) excluded from matching
    assert_equal(0, a.count(3))
    assert_equal(0, a.count(5))
    # Unmasked values still count normally
    assert_equal(1, a.count(7))
  end

  def test_per_axis_2d
    b = CArray.int32(3, 4).seq.mod(3)
    # b = [[0,1,2,0],
    #      [1,2,0,1],
    #      [2,0,1,2]]
    assert_equal(4, b.count(0))                # flatten: 4 zeros
    # axis 0: per-column zero counts
    r0 = b.count(0, axis: 0)
    assert_kind_of(CArray, r0)
    assert_equal([4],            r0.shape)
    assert_equal([1, 1, 1, 1],   r0.to_a)
    # axis 1: per-row zero counts
    r1 = b.count(0, axis: 1)
    assert_equal([3],            r1.shape)
    assert_equal([2, 1, 1],      r1.to_a)
  end

  def test_data_type_coverage_int
    [:int8, :int16, :int32, :int64, :uint8, :uint16, :uint32, :uint64].each do |t|
      a = CArray.send(t, 10).seq
      assert_equal(1, a.count(5), "data_type #{t} failed")
      assert_equal(0, a.count(99), "data_type #{t} failed")
    end
  end

  def test_data_type_coverage_float
    [:float32, :float64].each do |t|
      a = CArray.send(t, 5).seq        # [0.0, 1.0, 2.0, 3.0, 4.0]
      assert_equal(1, a.count(2.0), "data_type #{t} failed")
      assert_equal(0, a.count(2.5), "data_type #{t} failed")
    end
  end

  def test_value_arg_cast_to_src_data_type
    # value_arg: { target: :T_IN } -- ensure integer comparison stays
    # integer (no f64 round-trip).  Pass Float to int32 array -> cast.
    a = CArray.int32(5).seq
    # 2.0 (Ruby Float) should cast to 2 (int32) via NUM2LL.
    assert_equal(1, a.count(2.0))
    # 2.7 truncates to 2 by NUM2LL (= Float-to-Integer in Ruby).
    # This pins the cast behavior; if it changes, this test signals.
    assert_equal(1, a.count(2.7))
  end

  def test_min_count_opt
    a = CArray.int32(10).seq           # 10 valid cells
    # Sentinel (no opt) = legacy default (any 1 valid).
    assert_equal(1, a.count(5))
    # min_count: 5 → need 5 valid, we have 10, so normal result.
    assert_equal(1, a.count(5, min_count: 5))
    # min_count: 20 → need 20 valid, we have 10 → UNDEF (full reduction)
    assert_equal(UNDEF, a.count(5, min_count: 20))
  end

  def test_min_count_with_fill_value
    a = CArray.int32(10).seq
    # min_count exceeds elements → fill_value substitutes UNDEF
    assert_equal(-1, a.count(5, min_count: 20, fill_value: -1))
  end

  def test_per_axis_min_count_with_fill_value
    b = CArray.int32(3, 4).seq.mod(3)
    # axis 0, slab_elements = 3, min_count: 5 → all UNDEF
    r = b.count(0, axis: 0, min_count: 5, fill_value: -99)
    assert_equal([4],                  r.shape)
    assert_equal([-99, -99, -99, -99], r.to_a)
  end

  def test_per_axis_all_masked_slab
    # ERI.2: count over an all-masked slab = count of matches in the empty
    # set of unmasked cells = 0 (identity), NOT UNDEF, under default
    # min_count.  UNDEF is opt-in via min_count: 1.
    b = CArray.int32(3, 4).seq.mod(3)
    b[nil, 0] = UNDEF             # mask entire column 0
    r = b.count(0, axis: 0)       # axis 0 reduce; column 0 all masked
    assert_equal(false, r.is_masked[0])   # column 0 result is defined (identity 0)
    assert_equal(0, r[0])             # zero matches in the empty set
    assert_equal(false, r.is_masked[1])   # other columns have valid result
    # opt-in: require >= 1 valid cell -> all-masked column is UNDEF
    r2 = b.count(0, axis: 0, min_count: 1)
    assert_equal(true, r2.is_masked[0])
  end

  def test_no_value_arg_forwards_to_count_not_masked
    # 3.0: count with no value argument is the arity-0 rung of the
    # dispatch ladder (present-cell cardinality), not an error.
    a = CArray.int32(5).seq
    assert_equal(a.count_not_masked, a.count)
    assert_equal(5, a.count)
  end

  def test_consistency_with_eq_count_chain
    # count(v) should equal (a.eq(v)).count(true), modulo mask handling.
    a = CArray.int32(20).seq.mod(4)
    [0, 1, 2, 3].each do |v|
      assert_equal(a.eq(v).count(true),
                   a.count(v),
                   "value #{v} mismatch")
    end
  end
end
