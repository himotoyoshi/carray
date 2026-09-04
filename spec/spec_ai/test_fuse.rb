require "test/unit"
require "carray"
require "carray/core_extensions"

# `CArray.fuse { ... }` reads its block rather than calling it: `a` inside
# would otherwise be the array itself, and the expression would be computed
# eagerly, which is what fuse exists to avoid.  What it returns is the
# expression, computed where it is used.
class TestFuse < Test::Unit::TestCase
  using CArray::CoreExtensions

  ORIGIN = CArray.float64(4) { |i| i * 100.0 }

  def setup
    @a = CArray.float64(4) { |i| i.to_f }
    @b = CArray.float64(4) { |i| i + 1.0 }
  end

  # -- what comes back --------------------------------------------------

  def test_it_returns_the_expression_rather_than_an_array
    assert_kind_of CABinOp, CArray.fuse { @a + @b }
    assert_kind_of CAMonOp, CArray.fuse { @a.sqrt }
    assert_kind_of CABinCmp, CArray.fuse { @a > @b }
  end

  def test_the_expression_computes_what_the_eager_one_does
    want = (@a + @b) * (@b - @a) + @a
    assert_equal want.to_a, CArray.fuse { (@a + @b) * (@b - @a) + @a }.to_a
  end

  def test_it_is_computed_where_it_is_used
    out = CArray.float64(4)
    out[] = CArray.fuse { @a + @b }
    assert_equal (@a + @b).to_a, out.to_a
    assert_equal (@a + @b).sum, CArray.fuse { @a + @b }.sum
    assert_equal (@a + @b).to_a, CArray.fuse { @a + @b }.to_ca.to_a
  end

  def test_a_block_holding_no_arrays_returns_what_it_evaluated_to
    scale = 2.0
    assert_equal 4.0, CArray.fuse { scale * 2 }
    assert_nil CArray.fuse { nil }
  end

  def test_an_array_by_itself_comes_back_as_itself
    # There is nothing to fuse, so the shadow around it comes off again.
    plain = @a
    assert_same plain, CArray.fuse { plain }
  end

  # -- where the names come from ----------------------------------------

  def test_locals
    scale = 3.0
    assert_equal (@a * 3.0).to_a, CArray.fuse { @a * scale }.to_a
  end

  def test_instance_variables_and_a_method_on_self
    assert_equal (@a * 2.0 + 7.0).to_a,
                 CArray.fuse { @a * two + seven }.to_a
  end

  def two   = 2.0
  def seven = 7.0

  def test_a_constant
    assert_equal (ORIGIN + @a).to_a, CArray.fuse { ORIGIN + @a }.to_a
  end

  def test_a_call_to_a_method_that_takes_the_array
    assert_equal (@a * 3.0 + @b).to_a, CArray.fuse { tripled(@a) + @b }.to_a
  end

  def tripled (x) = x * 3.0

  def test_an_index_is_a_position_not_a_value
    i = 1
    assert_equal @a[i] + @b[i], CArray.fuse { @a[i] + @b[i] }
    assert_equal (@a[1..3] + @b[1..3]).to_a,
                 CArray.fuse { @a[1..3] + @b[1..3] }.to_a
  end

  def test_a_block_written_over_several_lines
    want = (@a + @b) * 2.0
    got = CArray.fuse {
      (@a + @b) *
        2.0
    }
    assert_equal want.to_a, got.to_a
  end

  def test_a_do_end_block
    assert_equal (@a + @b).to_a, (CArray.fuse do @a + @b end).to_a
  end

  # -- one helper for a scalar and for an array --------------------------
  #
  # The point of reading names rather than taking them as arguments: the
  # same helper reads either way, because a value that is not an array
  # passes through untouched.

  def magnus (t)
    CArray.fuse { 6.1078 * ((17.27 * t) / (t + 237.3)).exp }
  end

  def test_a_helper_over_a_scalar_stays_ruby
    result = magnus(25.0)
    assert_instance_of Float, result
    assert_in_delta 31.677, result, 0.001
  end

  def test_the_same_helper_over_an_array_gives_an_expression
    arr = CArray.float64(5).seq(20.0, 1.0)
    result = magnus(arr)
    assert_kind_of CArray, result
    eager = 6.1078 * ((17.27 * arr) / (arr + 237.3)).exp
    assert_equal eager.to_ca.to_a, result.to_ca.to_a
  end

  # -- the expression does not write ------------------------------------

  def test_the_operands_are_read_only_inside
    assert_raise(RuntimeError) { CArray.fuse { @a[0] = 99.0 } }
  end

  def test_the_arrays_themselves_are_untouched
    before = @a.to_a
    CArray.fuse { @a + @b }.to_ca
    assert_equal before, @a.to_a
  end

  def test_an_array_outside_is_still_writable_afterwards
    CArray.fuse { @a + @b }.to_ca
    @a[0] = 42.0
    assert_equal 42.0, @a[0]
  end

  # -- masks -------------------------------------------------------------

  def test_a_mask_travels_with_the_expression
    masked = @a.copy
    masked[1] = UNDEF
    got = CArray.fuse { masked + @b }.to_ca
    assert_equal (masked + @b).mask.to_a, got.mask.to_a
  end

  # -- refusing ----------------------------------------------------------

  def test_without_a_block
    assert_raise(LocalJumpError) { CArray.fuse }
  end

  def test_the_argument_form_is_gone_and_says_so
    error = assert_raise(ArgumentError) { CArray.fuse(@a, @b) { |x, y| x + y } }
    assert_match(/takes no arguments/, error.message)
  end

  def test_a_block_whose_source_cannot_be_read_says_what_to_write_instead
    error = assert_raise(ArgumentError) { eval("CArray.fuse { @a + @b }", binding) }
    assert_match(/cannot read this block's source/, error.message)
    assert_match(/\.lazy/, error.message)
  end
end
