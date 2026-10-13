# ----------------------------------------------------------------------------
#
#  spec_ai/test_header_contract.rb
#
#  The public C surface of carray.h called as a companion gem calls it:
#  from an extension built outside carray (spec_ai/ext_header_contract).
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "test/unit"
require_relative "ext_header_contract/load"

class TestHeaderContract < Test::Unit::TestCase

  H = HeaderContract

  # ca_mask_overlay_safe reads each array operand cell by cell over the
  # output's cells; an operand of another size is refused before the
  # output's mask is touched.
  def test_overlay_safe_refuses_an_operand_of_another_size
    out = CArray.int32(4)
    big = CArray.int32(100)
    big[50] = UNDEF
    assert_raise(ArgumentError) { H.overlay_safe(out, big) }
    small = CArray.int32(2)
    small[1] = UNDEF
    assert_raise(ArgumentError) { H.overlay_safe(CArray.int32(100), small) }
    assert_equal false, out.has_mask?
  end

  def test_overlay_safe_takes_an_operand_of_the_same_size_or_a_scalar
    out = CArray.int32(4)
    src = CArray.int32(4)
    src[1] = UNDEF
    H.overlay_safe(out, src)
    assert_equal [false, true, false, false], out.is_masked.to_a
    s = CScalar.new(CA_INT32)
    s[0] = UNDEF
    out2 = CArray.int32(3)
    H.overlay_safe(out2, s)
    assert_equal [true, true, true], out2.is_masked.to_a
  end

  # ca_setup_mask takes a boolean mask with a cell for each of the array's.
  def test_setup_mask_takes_a_boolean_mask_of_the_same_size
    a = CArray.float64(8)
    assert_raise(ArgumentError) { H.setup_mask(a, CArray.boolean(4)) }
    assert_raise(CArray::DataTypeError) { H.setup_mask(a, CArray.uint8(8)) }
    assert_equal false, a.has_mask?
    H.setup_mask(a, CArray.boolean(8) { |i| i.even? })
    assert_equal 4, a.count_masked
    assert_equal 4, a.count_not_masked
    assert_equal [true, false] * 4, a.is_masked.to_a
  end

  # A lazy expression with no masked operand has no mask to create.
  def test_create_mask_on_an_unmasked_lazy_expression
    [CArray.float64(3).lazy + 1,
     CArray.float64(3).lazy * CArray.float64(3).lazy,
     CArray.float64(3).lazy > 0].each do |x|
      H.create_mask(x)
      assert_equal 0, x.count_masked
    end
  end

  def test_unmask_copy_is_declared
    a = CArray.int32(3).seq!
    a[1] = UNDEF
    c = H.unmask_copy(a)
    assert_equal false, c.has_mask?
  end

  # A raise while a view's second attach makes its mask leaves the view at
  # the level it had.
  class MaskRaises < CAObject
    attr_accessor :masked, :boom
    def initialize
      @masked = false
      @boom = false
      super(:int32, [4])
    end
    private
    def fetch_addr (a); a; end
    def store_addr (a, v); end
    def copy_data (d); d[] = CArray.int32(4).seq!; end
    def sync_data (d); end
    def fill_data (v); end
    def mask_created?; @masked; end
    def create_mask; raise "create_mask" if @boom; end
  end

  def test_a_raise_in_a_repeat_attach_leaves_the_level
    o = MaskRaises.new
    H.attach(o)
    assert_equal 1, H.attach_level(o)
    o.masked = true
    o.boom = true
    assert_raise(RuntimeError) { H.attach(o) }
    assert_equal 1, H.attach_level(o)
    H.detach(o)
    assert_equal 0, H.attach_level(o)
  end

  # A refused registration takes no obj_type number.
  def test_a_refused_install_takes_no_number
    n = H.obj_num
    assert_raise(RuntimeError) { H.install(H::FUNC_SIZE + 64) }
    assert_equal n, H.obj_num
  end

  def test_check_data_type_takes_an_expression
    assert_equal true, H.check_data_type(true, :float64)
    assert_equal true, H.check_data_type(false, 0)
    assert_raise(ArgumentError) { H.check_data_type(true, 999) }
  end

end
