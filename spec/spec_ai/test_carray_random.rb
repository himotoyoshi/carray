require "test/unit"
require "carray"

class TestRandomBang < Test::Unit::TestCase

  # --- float64 ---

  def test_random_float64_default_range
    a = CArray.float64(1000).random!
    assert(a.to_a.all? { |v| v >= 0.0 && v < 1.0 })
  end

  def test_random_float64_with_max
    a = CArray.float64(1000).random!(5.0)
    assert(a.to_a.all? { |v| v >= 0.0 && v < 5.0 })
  end

  def test_random_float64_mean_close_to_half
    a = CArray.float64(100_000).random!
    mean = a.mean
    assert_in_delta(0.5, mean, 0.01)
  end

  # --- float32 ---

  def test_random_float32
    a = CArray.float32(1000).random!
    assert(a.to_a.all? { |v| v >= 0.0 && v < 1.0 })
  end

  # --- integer types ---

  def test_random_int32_with_max
    a = CArray.int32(1000).random!(10)
    vals = a.to_a
    assert(vals.all? { |v| v >= 0 && v < 10 })
    assert(vals.uniq.size > 1)
  end

  def test_random_int8_with_max
    a = CArray.int8(1000).random!(5)
    assert(a.to_a.all? { |v| v >= 0 && v < 5 })
  end

  def test_random_uint16_with_max
    a = CArray.uint16(1000).random!(100)
    assert(a.to_a.all? { |v| v >= 0 && v < 100 })
  end

  def test_random_int64_with_max
    a = CArray.int64(1000).random!(1000)
    assert(a.to_a.all? { |v| v >= 0 && v < 1000 })
  end

  def test_random_int_requires_max
    a = CArray.int32(10)
    assert_raise(ArgumentError) { a.random! }
  end

  def test_random_int_max_must_be_positive
    a = CArray.int32(10)
    assert_raise(ArgumentError) { a.random!(0) }
    assert_raise(ArgumentError) { a.random!(-1) }
  end

  # --- boolean ---

  def test_random_boolean
    a = CArray.boolean(1000).random!
    vals = a.to_a
    assert(vals.include?(0) || vals.include?(false))
    assert(vals.include?(1) || vals.include?(true))
  end

  # --- complex ---

  def test_random_complex128
    a = CArray.dcomplex(100).random!
    a.to_a.each do |v|
      assert(v.real >= 0.0 && v.real < 1.0)
      assert(v.imaginary >= 0.0 && v.imaginary < 1.0)
    end
  end

  def test_random_complex64
    a = CArray.complex(100).random!
    a.to_a.each do |v|
      assert(v.real >= 0.0 && v.real < 1.0)
      assert(v.imaginary >= 0.0 && v.imaginary < 1.0)
    end
  end

  # --- rng keyword ---

  def test_random_rng_reproducibility
    rng1 = Random.new(42)
    rng2 = Random.new(42)
    a1 = CArray.float64(100).random!(rng: rng1)
    a2 = CArray.float64(100).random!(rng: rng2)
    assert_equal(a1.to_a, a2.to_a)
  end

  def test_random_rng_different_seeds_differ
    rng1 = Random.new(42)
    rng2 = Random.new(99)
    a1 = CArray.float64(100).random!(rng: rng1)
    a2 = CArray.float64(100).random!(rng: rng2)
    assert_not_equal(a1.to_a, a2.to_a)
  end

  def test_random_rng_with_max
    rng1 = Random.new(7)
    rng2 = Random.new(7)
    a1 = CArray.float64(50).random!(3.0, rng: rng1)
    a2 = CArray.float64(50).random!(3.0, rng: rng2)
    assert_equal(a1.to_a, a2.to_a)
    assert(a1.to_a.all? { |v| v >= 0.0 && v < 3.0 })
  end

  def test_random_rng_int
    rng1 = Random.new(7)
    rng2 = Random.new(7)
    a1 = CArray.int32(50).random!(100, rng: rng1)
    a2 = CArray.int32(50).random!(100, rng: rng2)
    assert_equal(a1.to_a, a2.to_a)
  end

  # --- edge cases ---

  def test_random_zero_element
    a = CArray.float64(0).random!
    assert_equal([], a.to_a)
  end

  def test_random_single_element
    a = CArray.float64(1).random!
    assert(a[0] >= 0.0 && a[0] < 1.0)
  end

  def test_random_multidim
    a = CArray.float64(3, 4).random!
    assert_equal([3, 4], a.dim.to_a)
    a.flatten.to_a.each { |v| assert(v >= 0.0 && v < 1.0) }
  end

  def test_random_object_raises
    a = CArray.object(5)
    assert_raise(CArray::DataTypeError) { a.random! }
  end

  # --- returns self ---

  def test_random_returns_self
    a = CArray.float64(10)
    assert_same(a, a.random!)
  end
end

class TestRandomnBang < Test::Unit::TestCase

  def test_randomn_float64
    a = CArray.float64(10_000).randomn!
    mean = a.mean
    var = a.variancep
    assert_in_delta(0.0, mean, 0.05)
    assert_in_delta(1.0, var, 0.05)
  end

  def test_randomn_float32
    a = CArray.float32(10_000).randomn!
    mean = a.to_type(CA_FLOAT64).mean
    assert_in_delta(0.0, mean, 0.05)
  end

  def test_randomn_odd_elements
    a = CArray.float64(7).randomn!
    assert_equal(7, a.elements)
    assert(a.to_a.all? { |v| v.is_a?(Float) })
  end

  def test_randomn_single_element
    a = CArray.float64(1).randomn!
    assert(a[0].is_a?(Float))
  end

  def test_randomn_complex128
    a = CArray.dcomplex(1000).randomn!
    reals = a.to_a.map(&:real)
    imags = a.to_a.map(&:imaginary)
    r_mean = reals.sum / reals.size
    i_mean = imags.sum / imags.size
    assert_in_delta(0.0, r_mean, 0.1)
    assert_in_delta(0.0, i_mean, 0.1)
  end

  def test_randomn_rng_reproducibility
    rng1 = Random.new(42)
    rng2 = Random.new(42)
    a1 = CArray.float64(100).randomn!(rng: rng1)
    a2 = CArray.float64(100).randomn!(rng: rng2)
    assert_equal(a1.to_a, a2.to_a)
  end

  def test_randomn_int_raises
    a = CArray.int32(10)
    assert_raise(CArray::DataTypeError) { a.randomn! }
  end

  def test_randomn_returns_self
    a = CArray.float64(10)
    assert_same(a, a.randomn!)
  end
end

class TestShuffleBang < Test::Unit::TestCase

  def test_shuffle_1d
    a = CArray.int32(10).seq!
    orig = a.to_a.dup
    a.shuffle!
    assert_equal(orig.sort, a.to_a.sort)
  end

  def test_shuffle_preserves_elements
    a = CArray.float64(100).random!
    sorted_before = a.to_a.sort
    a.shuffle!
    assert_equal(sorted_before, a.to_a.sort)
  end

  def test_shuffle_axis0
    a = CArray.int32(4, 3).seq!
    rows_before = 4.times.map { |i| a[i, nil].to_a }
    a.shuffle!(axis: 0)
    rows_after = 4.times.map { |i| a[i, nil].to_a }
    assert_equal(rows_before.sort, rows_after.sort)
  end

  def test_shuffle_axis1
    a = CArray.int32(3, 5).seq!
    rows_before = 3.times.map { |i| a[i, nil].to_a.sort }
    a.shuffle!(axis: 1)
    rows_after = 3.times.map { |i| a[i, nil].to_a.sort }
    assert_equal(rows_before, rows_after)
  end

  def test_shuffle_axis_negative
    a = CArray.int32(3, 4).seq!
    rows_before = 3.times.map { |i| a[i, nil].to_a }
    a.shuffle!(axis: -2)
    rows_after = 3.times.map { |i| a[i, nil].to_a }
    assert_equal(rows_before.sort, rows_after.sort)
  end

  def test_shuffle_axis_out_of_range
    a = CArray.int32(3, 4)
    assert_raise(ArgumentError) { a.shuffle!(axis: 2) }
    assert_raise(ArgumentError) { a.shuffle!(axis: -3) }
  end

  def test_shuffle_3d_axis1
    a = CArray.int32(2, 3, 4).seq!
    slices_before = 3.times.map { |j| a[0, j, nil].to_a }
    a.shuffle!(axis: 1)
    slices_after = 3.times.map { |j| a[0, j, nil].to_a }
    assert_equal(slices_before.sort, slices_after.sort)
  end

  def test_shuffle_rng_reproducibility
    a1 = CArray.int32(20).seq!
    a2 = CArray.int32(20).seq!
    rng1 = Random.new(42)
    rng2 = Random.new(42)
    a1.shuffle!(rng: rng1)
    a2.shuffle!(rng: rng2)
    assert_equal(a1.to_a, a2.to_a)
  end

  def test_shuffle_single_element
    a = CArray.int32(1)
    a[0] = 42
    a.shuffle!
    assert_equal(42, a[0])
  end

  def test_shuffle_returns_self
    a = CArray.int32(10).seq!
    assert_same(a, a.shuffle!)
  end
end

class TestShuffleCopy < Test::Unit::TestCase

  def test_shuffle_returns_new_array
    a = CArray.int32(10).seq!
    b = a.shuffle
    assert_equal(a.to_a.sort, b.to_a.sort)
    assert_not_same(a, b)
  end

  def test_shuffle_does_not_modify_original
    a = CArray.int32(10).seq!
    orig = a.to_a.dup
    a.shuffle
    assert_equal(orig, a.to_a)
  end
end

class TestRandomCopy < Test::Unit::TestCase

  def test_random_returns_new_array
    a = CArray.float64(5)
    b = a.random
    assert_not_same(a, b)
    assert(b.to_a.all? { |v| v >= 0.0 && v < 1.0 })
  end

  def test_randomn_returns_new_array
    a = CArray.float64(5)
    b = a.randomn
    assert_not_same(a, b)
    assert(b.to_a.all? { |v| v.is_a?(Float) })
  end
end

class TestRandomRangeSurface < Test::Unit::TestCase

  # --- (low, high) 2-positional half-open [low, high) ---

  def test_two_positional_integer
    vals = CArray.int32(1000).random!(-5, 5).to_a
    assert(vals.all? { |v| v >= -5 && v < 5 })
    assert(vals.include?(-5))
    assert(vals.include?(4))
    assert(! vals.include?(5))
  end

  def test_two_positional_float
    vals = CArray.float64(1000).random!(-1.0, 1.0).to_a
    assert(vals.all? { |v| v >= -1.0 && v < 1.0 })
  end

  def test_two_positional_low_ge_high_raises
    assert_raise(ArgumentError) { CArray.int32(3).random!(5, 5) }
    assert_raise(ArgumentError) { CArray.int32(3).random!(10, 5) }
    assert_raise(ArgumentError) { CArray.float64(3).random!(1.0, 1.0) }
  end

  # --- Range closed (`..`) — integer includes the endpoint ---

  def test_range_closed_integer_dice
    # 1..6 = dice: 6 must be reachable
    vals = CArray.int32(5000).random!(1..6).to_a
    assert(vals.all? { |v| v >= 1 && v <= 6 })
    assert(vals.include?(6))
    assert(vals.include?(1))
    # rough uniformity: each face 500-fold ± tolerance
    (1..6).each do |face|
      count = vals.count(face)
      assert(count > 700 && count < 950,
             "face #{face} count=#{count}, expected ~833")
    end
  end

  def test_range_closed_integer_negative
    vals = CArray.int32(1000).random!(-3..3).to_a
    assert(vals.all? { |v| v >= -3 && v <= 3 })
    assert(vals.include?(3))
    assert(vals.include?(-3))
  end

  # --- Range half-open (`...`) — integer excludes the endpoint ---

  def test_range_half_open_integer
    vals = CArray.int32(1000).random!(1...6).to_a
    assert(vals.all? { |v| v >= 1 && v < 6 })
    assert(! vals.include?(6))
    assert(vals.include?(5))
    assert(vals.include?(1))
  end

  # --- Range float (closed and half-open are equivalent at sampler) ---

  def test_range_closed_float
    vals = CArray.float64(1000).random!(-0.5..0.5).to_a
    assert(vals.all? { |v| v >= -0.5 && v < 0.5 })
  end

  def test_range_half_open_float
    vals = CArray.float64(1000).random!(-0.5...0.5).to_a
    assert(vals.all? { |v| v >= -0.5 && v < 0.5 })
  end

  # --- error cases ---

  def test_range_plus_second_positional_raises
    assert_raise(ArgumentError) { CArray.int32(3).random!(1..5, 10) }
  end

  def test_range_with_nil_endpoint_raises
    assert_raise(ArgumentError) { CArray.int32(3).random!(1..) }
    assert_raise(ArgumentError) { CArray.int32(3).random!(..5) }
  end

  # --- removed kwargs (3.0 breaking) ---

  def test_min_max_kwargs_removed
    assert_raise(ArgumentError) {
      CArray.float64(3).random!(min: 0.0, max: 1.0)
    }
    assert_raise(ArgumentError) {
      CArray.int32(3).random!(min: 0, max: 10)
    }
  end

  # --- rng: with new forms ---

  def test_rng_with_range_closed_reproducibility
    r1 = Random.new(42)
    r2 = Random.new(42)
    a = CArray.int32(50).random!(1..6, rng: r1).to_a
    b = CArray.int32(50).random!(1..6, rng: r2).to_a
    assert_equal a, b
  end

  def test_rng_with_two_positional_reproducibility
    r1 = Random.new(42)
    r2 = Random.new(42)
    a = CArray.float64(50).random!(-1.0, 1.0, rng: r1).to_a
    b = CArray.float64(50).random!(-1.0, 1.0, rng: r2).to_a
    assert_equal a, b
  end

  # --- copy variant honors same surface ---

  def test_copy_random_with_range
    template = CArray.int32(1000)
    b = template.random(1..6)
    assert(b.to_a.all? { |v| v >= 1 && v <= 6 })
    assert(b.to_a.include?(6))
  end

end
