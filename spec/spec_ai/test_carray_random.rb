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

# CArray::Rng -- a generator with its own state, whose C is handed out.
#
# The state is a plain CA_INT64 array rather than something only this
# extension can read, and the C is a file both this extension and carray-jit
# compile.  Those two together are what let a sequence begin in `random!`
# and continue inside a compiled kernel; what is checked here is the half
# that lives on this side.
class TestCArrayRng < Test::Unit::TestCase

  def straight(seed, count)
    rng = CArray::Rng.new(seed: seed)
    Array.new(count) { rng.rand }
  end

  def test_state_is_four_int64_cells
    rng = CArray::Rng.new(seed: 4)
    assert_equal :int64, rng.state.data_type
    assert_equal 4, rng.state.elements
    assert_equal :xoshiro256pp, rng.generator
    assert_equal 4, rng.seed
  end

  # splitmix64's published output for seed 0, which is what the state is
  # stretched through.  A transcription slip in the seeder would show here
  # and nowhere else -- every later draw would still be self-consistent.
  def test_seeding_matches_the_published_splitmix64_vector
    rng = CArray::Rng.new(seed: 0)
    expected = [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4,
                0x06C45D188009454F, 0xF88BB8A8724C81EC]
    got = rng.state.to_a.map { |cell| cell & 0xFFFFFFFFFFFFFFFF }
    assert_equal expected, got
  end

  def test_same_seed_repeats_and_different_seeds_differ
    assert_equal straight(4, 20), straight(4, 20)
    assert_not_equal straight(4, 20), straight(5, 20)
  end

  def test_no_seed_draws_one_so_two_generators_differ
    assert_not_equal CArray::Rng.new.rand, CArray::Rng.new.rand
  end

  def test_reset_repeats_the_run
    rng = CArray::Rng.new(seed: 4)
    first = Array.new(5) { rng.rand }
    rng.reset
    assert_equal first, Array.new(5) { rng.rand }
  end

  def test_reset_with_a_seed_starts_a_different_run
    rng = CArray::Rng.new(seed: 4)
    rng.reset(7)
    assert_equal 7, rng.seed
    assert_equal straight(7, 5), Array.new(5) { rng.rand }
  end

  # A seed wider than a word, and a negative one, are folded rather than
  # refused -- which is what `&` does and what the seed is.
  def test_a_wide_or_negative_seed_is_accepted
    assert_equal CArray::Rng.new(seed: -1).rand,
                 CArray::Rng.new(seed: 0xFFFFFFFFFFFFFFFF).rand
    assert_kind_of Float, CArray::Rng.new(seed: 2**200 + 3).rand
  end

  def test_draws_are_in_the_unit_interval
    rng = CArray::Rng.new(seed: 11)
    values = Array.new(2000) { rng.rand }
    assert(values.all? { |v| v >= 0.0 && v < 1.0 })
  end

  # 53 bits of mantissa: a million draws collide zero times.  A generator
  # handing back 32 bits would collide about 116 times here.
  def test_draws_use_the_whole_mantissa
    rng = CArray::Rng.new(seed: 3)
    values = Array.new(1_000_000) { rng.rand }
    assert_equal values.size, values.uniq.size
  end

  # --- random! through the generator ---

  def test_random_bang_fills_from_the_generator
    rng = CArray::Rng.new(seed: 4)
    assert_equal straight(4, 10), CArray.float64(10).random!(rng: rng).to_a
  end

  # The state advances, so two fills are one sequence.  This is what a
  # kernel picks up.
  def test_two_fills_continue_one_sequence
    rng = CArray::Rng.new(seed: 4)
    first = CArray.float64(4).random!(rng: rng).to_a
    second = CArray.float64(6).random!(rng: rng).to_a
    assert_equal straight(4, 10), first + second
  end

  def test_a_fill_and_a_ruby_draw_continue_one_sequence
    rng = CArray::Rng.new(seed: 4)
    filled = CArray.float64(4).random!(rng: rng).to_a
    assert_equal straight(4, 10), filled + Array.new(6) { rng.rand }
  end

  def test_randomn_and_shuffle_take_the_generator_too
    a = CArray.float64(100).randomn!(rng: CArray::Rng.new(seed: 5))
    b = CArray.float64(100).randomn!(rng: CArray::Rng.new(seed: 5))
    assert_equal a.to_a, b.to_a

    c = CArray.int32(50).seq.shuffle(rng: CArray::Rng.new(seed: 5))
    d = CArray.int32(50).seq.shuffle(rng: CArray::Rng.new(seed: 5))
    assert_equal c.to_a, d.to_a
    assert_equal (0...50).to_a, c.to_a.sort
  end

  def test_a_bounded_integer_fill_stays_in_range
    rng = CArray::Rng.new(seed: 5)
    values = CArray.int32(5000).random!(1..6, rng: rng).to_a
    assert(values.all? { |v| v >= 1 && v <= 6 })
    assert_equal [1, 2, 3, 4, 5, 6], values.uniq.sort
  end

  def test_an_unknown_generator_is_refused
    assert_raise(ArgumentError) { CArray::Rng.new(:mersenne) }
  end

  # #bits is the generator's raw word, which is what the published sequences
  # are given in.  The state is a plain array, so it can be set to the one
  # those sequences start from rather than reached through a seed.
  def test_bits_match_the_published_xoshiro_sequence
    rng = CArray::Rng.new(seed: 1)
    rng.state[] = [1, 2, 3, 4]
    expected = [41943041, 58720359, 3588806011781223,
                3591011842654386, 9228616714210784205]
    assert_equal expected, Array.new(5) { rng.bits }
  end

  # And #rand is that word's top 53 bits, so the two are one draw seen twice
  # rather than two sequences.
  def test_rand_is_the_top_bits_of_the_same_word
    a = CArray::Rng.new(seed: 4)
    b = CArray::Rng.new(seed: 4)
    assert_equal (b.bits >> 11) * 2.0**-53, a.rand
  end

  # --- the source that is handed out ---

  def test_the_source_is_the_file_the_extension_compiled
    text = CArray::Rng::SOURCE.fetch(:xoshiro256pp)
    assert_equal File.read(CArray::Rng::SOURCE_FILES[:xoshiro256pp]), text
    assert(text.include?(CArray::Rng::DRAW_FUNCTION[:xoshiro256pp]))
  end

  # It has to be pasteable into someone else's translation unit: no include
  # guard (which would silence a second paste), no directives, and nothing
  # from a header beyond <stdint.h>.
  def test_the_source_is_pasteable
    text = CArray::Rng::SOURCE.fetch(:xoshiro256pp)
    directives = text.lines.grep(/^\s*#/)
    assert_equal [], directives, "the source carries preprocessor directives"
    assert(text.include?("static inline"))
  end

end
