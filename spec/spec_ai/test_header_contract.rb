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

  # The slots without a default (xfer_index, xfer_addrs, xfer_all) are
  # required: a table that stops before the end of xfer_all is refused.
  def test_a_table_short_of_xfer_all_is_refused
    n = H.obj_num
    assert_raise(RuntimeError) { H.install(H::XFER_INDEX_OFFSET) }
    assert_raise(RuntimeError) { H.install(H::XFER_ALL_END - 1) }
    assert_equal n, H.obj_num
  end

  # Two fixlen arrays have the same data type only at the same width.
  def test_check_same_data_type_compares_the_fixlen_width
    a = CArray.fixlen(2, bytes: 8)
    assert_equal true, H.check_same_data_type(a, CArray.fixlen(3, bytes: 8))
    assert_raise(CArray::DataTypeError) { H.check_same_data_type(a, CArray.fixlen(2, bytes: 4)) }
    assert_raise(CArray::DataTypeError) { H.check_same_data_type(CArray.int32(1), CArray.int64(1)) }
  end

  def test_promote_type_refuses_a_code_outside_the_data_types
    assert_raise(ArgumentError) { H.promote_type(40, 40) }
    assert_raise(ArgumentError) { H.promote_type(-1, 3) }
  end

  # Clearing the mask is a write: a read-only array refuses it, with or
  # without a fill value.
  def test_unmask_without_a_fill_value_refuses_a_read_only_array
    a = CArray.int32(3)
    a[1] = UNDEF
    a.set_read_only_flag
    assert_raise(RuntimeError) { H.unmask_without_fill(a) }
    assert_equal 1, a.count_masked
  end

  def test_check_data_type_takes_an_expression
    assert_equal true, H.check_data_type(true, :float64)
    assert_equal true, H.check_data_type(false, 0)
    assert_raise(ArgumentError) { H.check_data_type(true, 999) }
  end

end
