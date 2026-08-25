# PROPOSAL_SLAB_FAMILY β.3 — reduce_slab live tests
#
# Scope (= β.3 first cut, proposal §5.4 acceptance):
#   - dual surface: per-slab block (no init) / per-element fiber (init: given)
#   - dispatch fixed at __init__ time from `init:` presence
#   - output shape = src.dim with axis k removed (1-D src → dim=[1])
#   - data_type default = self.data_type; data_type: kwarg override
#   - per-slab block: scalar return required, multi-elem CArray raises
#   - per-slab block 待ち customer: median CA_OBJECT per-axis (= proposal §1.2)
#   - axis: -1 / 0 / inner / outer; 1-D / 2-D / 3-D src
#   - axis-0 = SCRATCH mode (carrier path)
#   - errors: missing block / bad return / out-of-range axis / multi-axis NotImp
#   - mask transparent carry = β.3b (currently raises NotImpError)

require 'test/unit'
require 'carray'

class TestReduceSlabBeta3 < Test::Unit::TestCase

  # ---- per-slab block form (= init: 不在)

  def test_per_slab_sum_axis_inner
    a = CArray.float64(3, 4).seq!
    r = a.reduce_slab(axis: 1) { |row| row.sum }
    assert_equal [3],            r.dim.to_a
    assert_equal [6.0, 22.0, 38.0], r.to_a
  end

  def test_per_slab_sum_axis_outer_SCRATCH
    a = CArray.float64(3, 4).seq!
    r = a.reduce_slab(axis: 0) { |col| col.sum }
    assert_equal [4],                       r.dim.to_a
    assert_equal [12.0, 15.0, 18.0, 21.0],  r.to_a
  end

  def test_per_slab_axis_negative
    a = CArray.float64(3, 4).seq!
    r = a.reduce_slab(axis: -1) { |row| row.max }
    assert_equal [3.0, 7.0, 11.0], r.to_a
  end

  def test_per_slab_3d_axis_inner
    a = CArray.int32(2, 3, 4).seq!
    r = a.reduce_slab(axis: -1) { |row| row.sum }
    assert_equal [2, 3],                  r.dim.to_a
    assert_equal [[6, 22, 38], [54, 70, 86]], r.to_a
  end

  def test_per_slab_3d_axis_middle
    a = CArray.int32(2, 3, 4).seq!
    r = a.reduce_slab(axis: 1) { |fiber| fiber.sum }
    assert_equal [2, 4], r.dim.to_a
  end

  def test_per_slab_1d_collapses_to_length_one
    a = CArray.float64(5).seq!
    r = a.reduce_slab(axis: 0) { |row| row.sum }
    assert_equal [1],     r.dim.to_a
    assert_equal [10.0],  r.to_a
  end

  # ---- per-slab 待ち customer: median CA_OBJECT per-axis (= proposal §1.2)

  def test_per_slab_median_ca_object_per_axis
    src = CArray.object(2, 5) { |i, j| (i + 1) * (j + 1) }
    # CArray#median doesn't support CA_OBJECT; user converts to Ruby Array
    # and picks the middle, which is the canonical β.3 customer pattern.
    r = src.reduce_slab(axis: 1) do |row|
      arr = row.to_a.sort
      arr[arr.size / 2]
    end
    assert_equal [3, 6], r.to_a    # row 0: [1,2,3,4,5] median=3; row 1: [2,4,6,8,10] median=6
  end

  def test_per_slab_median_float_per_axis_via_carray_method
    a = CArray.float64(3, 4).seq!
    r = a.reduce_slab(axis: 1) { |row| row.median }
    assert_equal [1.5, 5.5, 9.5], r.to_a
  end

  # ---- per-element fiber form (= init: 指定)

  def test_per_element_fiber_inject_sum
    a = CArray.float64(3, 4).seq!
    r = a.reduce_slab(axis: 1, init: 0.0) { |acc, x| acc + x }
    assert_equal [6.0, 22.0, 38.0], r.to_a
  end

  def test_per_element_fiber_inject_product
    a = CArray.float64(3, 4).seq!
    r = a.reduce_slab(axis: 1, init: 1.0) { |acc, x| acc * (x + 1) }
    assert_equal [24.0, 1680.0, 11880.0], r.to_a
  end

  def test_per_element_fiber_axis_0_SCRATCH
    a = CArray.int32(3, 4) { |i, j| i + j }
    r = a.reduce_slab(axis: 0, init: 0) { |acc, x| acc + x }
    assert_equal [3, 6, 9, 12], r.to_a   # col j: i in 0..2 of (i+j) = 0+1+2+3j = 3+3j
  end

  def test_per_element_fiber_object_accumulator
    # init: '' → string concat accumulator; data_type: :object so output holds strings
    a = CArray.object(2, 3) { |i, j| "r#{i}c#{j}" }
    r = a.reduce_slab(axis: 1, init: "", data_type: :object) { |acc, x| acc + (acc.empty? ? "" : ",") + x }
    assert_equal "r0c0,r0c1,r0c2", r[0]
    assert_equal "r1c0,r1c1,r1c2", r[1]
  end

  # ---- data_type kwarg

  def test_data_type_default_matches_source
    a = CArray.int32(3, 4).seq!
    r = a.reduce_slab(axis: 1) { |row| row.sum }
    assert_equal :int32, r.data_type_name.to_sym
  end

  def test_data_type_override
    a = CArray.float64(3, 4).seq!
    r = a.reduce_slab(axis: 1, data_type: :int32) { |row| row.sum.to_i }
    assert_equal :int32,        r.data_type_name.to_sym
    assert_equal [6, 22, 38],   r.to_a
  end

  # ---- error contract

  def test_raises_without_block
    a = CArray.float64(3, 4).seq!
    assert_raise(LocalJumpError) { a.reduce_slab(axis: 1) }
  end

  def test_raises_on_non_scalar_carray_return_per_slab
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) do
      a.reduce_slab(axis: 1) { |row| row }   # returns 4-element CArray
    end
  end

  def test_raises_on_single_element_carray_return
    # Strict scalar contract: even a 1-element CArray is a contract
    # violation; user must extract the scalar via `slab[0]` etc.
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) do
      a.reduce_slab(axis: 1) { |row| CArray.float64(1) { 99.0 } }
    end
  end

  def test_raises_on_axis_out_of_range
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) { a.reduce_slab(axis: 99) { |row| row.sum } }
  end

  # β.xc' Piece B: non-contig multi-axis works via own-scratch K-D gather.
  def test_non_contig_multi_axis_works_via_own_scratch
    a = CArray.float64(2, 3, 4).seq!
    r = a.reduce_slab(axis: [0, 1]) { |slab| slab.sum }
    assert_equal [4],                       r.dim.to_a
    assert_equal [60.0, 66.0, 72.0, 78.0],  r.to_a
  end

  # β.xb mask carry: per-slab block honors mask via slab.sum / .mean /
  # etc.; per-element fiber yields masked cells as CA::UNDEF.
  def test_per_slab_form_honors_mask
    a = CArray.float64(3, 4).seq!
    a[0, 0] = UNDEF
    a[1, 2] = UNDEF
    r = a.reduce_slab(axis: 1) { |row| row.sum }
    # row 0 sum = 1+2+3=6 (skip [0,0]), row 1 = 4+5+7=16 (skip [1,2]), row 2 = 38
    assert_equal [6.0, 16.0, 38.0], r.to_a
  end

  def test_per_element_form_yields_UNDEF_for_masked
    a = CArray.float64(2, 3).seq!
    a[0, 1] = UNDEF
    seen = []
    a.reduce_slab(axis: 1, init: 0.0) do |acc, x|
      seen << x
      x.equal?(UNDEF) ? acc : acc + x
    end
    # Row 0 yields [0.0, UNDEF, 2.0]; row 1 yields [3.0, 4.0, 5.0]
    assert_equal [0.0, UNDEF, 2.0, 3.0, 4.0, 5.0], seen
  end

  # ---- dispatch correctness: init nil treated as fiber form, not slab form

  def test_init_explicit_nil_uses_fiber_form
    # Sentinel distinguishes "init: omitted" (per-slab block) from
    # "init: nil" (per-element fiber with nil starting acc).  This test
    # pins that explicit `init: nil` reaches the 2-arg block.
    a = CArray.float64(3).seq!
    seen_arity = nil
    a.reduce_slab(axis: 0, init: nil) do |acc, x|
      seen_arity = 2
      (acc || 0) + x
    end
    assert_equal 2, seen_arity
  end

  # ---- in-block derived view safety (= memo §5.2 audit blind spot pin)

  def test_per_slab_row_dup_reads_current_iter
    a = CArray.float64(3, 4).seq!
    seen = []
    a.reduce_slab(axis: 1) { |row| seen << row.dup.to_a; row.sum }
    assert_equal [[0.0, 1.0, 2.0, 3.0],
                  [4.0, 5.0, 6.0, 7.0],
                  [8.0, 9.0, 10.0, 11.0]], seen
  end

  def test_per_slab_row_derived_arithmetic_reads_current_iter
    a = CArray.float64(3, 4).seq!
    r = a.reduce_slab(axis: 1) { |row| (row + 1).sum }
    # row i sum = (4*i + 0..3 + 1) = 4*i*4 + (1+2+3+4) = 16i + 10
    assert_equal [10.0, 26.0, 42.0], r.to_a
  end

  # ---- rb_ensure cleanup: exception in block does not leak

  def test_exception_in_block_propagates
    a = CArray.float64(3, 4).seq!
    raised = false
    begin
      a.reduce_slab(axis: 1) { |row| raise "boom" }
    rescue => e
      raised = (e.message == "boom")
    end
    assert raised
    # Subsequent call must still work.
    r = a.reduce_slab(axis: 1) { |row| row.sum }
    assert_equal [6.0, 22.0, 38.0], r.to_a
  end
end
