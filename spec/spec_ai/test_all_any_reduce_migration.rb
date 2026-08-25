# all/any reduce test pin.  bool input -> bool output, axis-aware,
# lazy fuse, streaming reduce.  (Phase 2 all_equal?/any_equal?/...
# predicate family removed 2026-06-23 as galapagos thin wrappers;
# canonical idiom is `a.eq(v).all` / `a.is_close(v, t).any` etc.)

require 'test/unit'
require 'carray'

class TestAllAnyReduceMigration < Test::Unit::TestCase
  # ---- Phase 1: bool .all / .any ----

  def test_all_bool_basic
    assert_equal(true,  CArray.boolean(5) { true }.all)
    assert_equal(false, CArray.boolean(5) { _1.odd? }.all)
    assert_equal(false, CArray.boolean(5) { false }.all)
  end

  def test_any_bool_basic
    assert_equal(true,  CArray.boolean(5) { true }.any)
    assert_equal(true,  CArray.boolean(5) { _1.odd? }.any)
    assert_equal(false, CArray.boolean(5) { false }.any)
  end

  def test_all_returns_ruby_bool
    assert_equal(TrueClass,  CArray.boolean(3) { true }.all.class)
    assert_equal(FalseClass, CArray.boolean(3) { false }.all.class)
  end

  def test_any_returns_ruby_bool
    assert_equal(TrueClass,  CArray.boolean(3) { true }.any.class)
    assert_equal(FalseClass, CArray.boolean(3) { false }.any.class)
  end

  def test_all_axis
    m = CArray.boolean(3, 4) { |i, j| (i + j).even? }
    # row 0: [1,0,1,0] -> all=false, any=true
    # row 1: [0,1,0,1] -> all=false, any=true
    # row 2: [1,0,1,0] -> all=false, any=true
    assert_equal([false, false, false], m.all(axis: 1).to_a)
    assert_equal([true, true, true], m.any(axis: 1).to_a)
    # col 0..3: [1,0,1], [0,1,0], [1,0,1], [0,1,0] -> all=false, any=true
    assert_equal([false, false, false, false], m.all(axis: 0).to_a)
    assert_equal([true, true, true, true], m.any(axis: 0).to_a)
  end

  def test_all_axis_output_is_boolean_array
    m = CArray.boolean(3, 4) { |i, j| (i + j).even? }
    r = m.all(axis: 1)
    assert_equal(CA_BOOLEAN, r.data_type)
    assert_equal([3], r.dim)
  end

  def test_all_empty_returns_identity_true
    a = CArray.boolean(0) { }
    assert_equal(true, a.all)
  end

  def test_any_empty_returns_identity_false
    a = CArray.boolean(0) { }
    assert_equal(false, a.any)
  end

  def test_all_non_bool_raises
    assert_raise(CArray::DataTypeError) { CArray.int32(3).seq.all }
    assert_raise(CArray::DataTypeError) { CArray.float64(3).seq.any }
  end

  def test_all_mask_ignored
    a = CArray.boolean(5) { _1.odd? ? true : false }
    a[0] = UNDEF   # masked cell ignored (= treated as identity true)
    # remaining: [_, true, false, true, false] with masked at 0
    # .all = false (because index 2,4 are false)
    assert_equal(false, a.all)
    a2 = CArray.boolean(5) { true }
    a2[1] = UNDEF
    # remaining: [true, _, true, true, true] -> all = true
    assert_equal(true, a2.all)
  end

end
