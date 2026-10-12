# ----------------------------------------------------------------------------
#
#  spec_ai/test_face_class_sort_addr.rb
#
#  CArray.sort_addr (the class method, several keys) orders a Face key by the
#  Face's own order, as the instance sort_addr does.  A Face whose storage is
#  fixlen but not ORDERABLE (CAConstString = (start, end) offsets, CARecord =
#  the struct's bytes) has no order in its storage bytes.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestFaceClassSortAddr < Test::Unit::TestCase

  def test_const_string_single_key
    c = CArray.const_string(%w[b a c a])
    assert_equal c.sort_addr.to_a, CArray.sort_addr(c).to_a
    assert_equal [1, 3, 0, 2], CArray.sort_addr(c).to_a
  end

  def test_const_string_ties_defer_to_the_next_key
    c = CArray.const_string(%w[b a b a])
    assert_equal [3, 1, 2, 0], CArray.sort_addr(c, CA_INT32([4, 3, 2, 1])).to_a
  end

  def test_const_string_secondary_key
    k = CA_INT32([1, 1, 0, 0])
    c = CArray.const_string(%w[b a c a])
    assert_equal [3, 2, 1, 0], CArray.sort_addr(k, c).to_a
  end

  def test_const_string_masked_goes_last
    s = CArray.const_string(%w[b a c a]).to_string
    s[0] = UNDEF
    c = s.to_const_string
    assert_equal [1, 3, 2, 0], CArray.sort_addr(c).to_a
    assert_equal [0, 1, 3, 2], CArray.sort_addr(c, masked_position: :first).to_a
  end

  def test_record_by_declared_order
    st = CArray.struct(pack: 1, order_by: [:id]) { int32 :id }
    r = CARecord.new(st, 3)
    r["id"] = CA_INT32([-1, 256, 2])
    assert_equal [0, 2, 1], CArray.sort_addr(r).to_a
  end

  def test_record_without_declared_order_raises
    st = CArray.struct(pack: 1) { int32 :id }
    r = CARecord.new(st, 3)
    assert_raise(ArgumentError) { CArray.sort_addr(r) }
  end

  def test_categorical_still_refused
    k = CA_OBJECT(%w[b a c a]).categorize
    assert_raise(ArgumentError) { CArray.sort_addr(k) }
  end

  def test_frame_sort_by_key_ascending_const_string
    df = CAFrame.new("x" => CArray.const_string(%w[b a c a]),
                     "v" => CA_FLOAT64([1, 2, 3, 4]))
    s = df.sort_by_key("x")
    assert_equal %w[a a b c], s["x"].to_a
    assert_equal [2.0, 4.0, 1.0, 3.0], s["v"].to_a
  end

end
