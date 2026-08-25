require "test/unit"
require "carray"

# Tests for CArray#unfold (PROPOSAL_VECTORIZE_PATTERNS Pattern D).
#
# unfold is sliding_windows over the *leading* S axes, with the
# trailing (ndim - S) axes passed through untouched and appended at the
# end.  Parent [d0, ..., dS-1, c0, ..., cT-1] becomes a CAStride view of
# shape [(d0-w0)/s0+1, ..., wS-1..., c0, ..., cT-1].  Memory is shared.

class TestUnfold < Test::Unit::TestCase

  def test_method_defined
    assert(CArray.instance_methods.include?(:unfold))
  end

  # ---- shape ----

  def test_shape_rgb_image
    img = CArray.int32(4, 4, 3).seq        # [H, W, C] = 2 spatial + 1 channel
    v = img.unfold([3, 3])
    assert_kind_of(CAStride, v)
    assert_equal([2, 2, 3, 3, 3], v.shape) # pos2 + window2 + channel1
  end

  def test_shape_single_spatial_axis
    src = CArray.int32(6, 3).seq           # 1 spatial + 1 channel
    v = src.unfold([2])
    assert_equal([5, 2, 3], v.shape)       # (6-2)+1=5 positions, window 2, channel 3
  end

  def test_shape_two_trailing_axes
    src = CArray.int32(5, 4, 2).seq        # 1 spatial + 2 trailing
    v = src.unfold([3])
    assert_equal([3, 3, 4, 2], v.shape)    # (5-3)+1=3, window 3, then 4, 2
  end

  def test_result_rank_is_ndim_plus_spatial
    src = CArray.int32(4, 4, 2).seq
    assert_equal(src.ndim + 2, src.unfold([2, 2]).ndim)
    assert_equal(src.ndim + 1, src.unfold([2]).ndim)
  end

  # ---- argument forms ----

  def test_variadic_and_array_forms_agree
    img = CArray.int32(4, 4, 3).seq
    assert_equal(img.unfold([3, 3]).to_a, img.unfold(3, 3).to_a)
  end

  def test_single_integer_form
    src = CArray.int32(6, 3).seq
    assert_equal(src.unfold([2]).to_a, src.unfold(2).to_a)
  end

  # ---- per-channel parity with sliding_windows ----

  def test_parity_with_sliding_windows_per_channel
    img = CArray.int32(5, 5, 3).seq
    u = img.unfold([3, 3])                  # [3, 3, 3, 3, 3]
    3.times do |c|
      plane = img[nil, nil, c]             # [5, 5] grayscale plane
      sw = plane.sliding_windows([3, 3])   # [3, 3, 3, 3]
      uc = u[nil, nil, nil, nil, c]        # channel-c slice -> [3, 3, 3, 3]
      assert_equal(sw.to_a, uc.to_a, "channel #{c} mismatch")
    end
  end

  def test_degenerates_to_sliding_windows_when_no_channel
    a = CArray.float64(5, 5).seq           # S == ndim, no trailing axes
    assert_equal(a.sliding_windows([3, 3]).to_a, a.unfold([3, 3]).to_a)
  end

  # ---- values ----

  def test_window_contents_carry_full_channel_vector
    img = CArray.int32(3, 3, 2).seq        # values 0..17
    v = img.unfold([2, 2])                 # [2, 2, 2, 2, 2]
    # window at position (0,0): spatial cells (0,0),(0,1),(1,0),(1,1),
    # each carrying its 2 channels.
    patch = v[0, 0, nil, nil, nil].to_a
    expected = [
      [[img[0, 0, 0], img[0, 0, 1]], [img[0, 1, 0], img[0, 1, 1]]],
      [[img[1, 0, 0], img[1, 0, 1]], [img[1, 1, 0], img[1, 1, 1]]],
    ]
    assert_equal(expected, patch)
  end

  # ---- step ----

  def test_step_keyword_scalar
    src = CArray.int32(7, 2).seq           # 1 spatial + 1 channel
    v = src.unfold([2], step: 2)
    assert_equal([3, 2, 2], v.shape)       # (7-2)/2+1 = 3
  end

  def test_step_keyword_array
    src = CArray.int32(8, 8, 3).seq
    v = src.unfold([3, 3], step: [2, 2])
    assert_equal([3, 3, 3, 3, 3], v.shape) # (8-3)/2+1 = 3 on each spatial axis
  end

  # ---- memory sharing (view, not copy) ----

  def test_write_through_to_parent
    img = CArray.int32(4, 4, 3).seq
    v = img.unfold([2, 2])
    v[0, 0, 0, 0, 0] = 999
    assert_equal(999, img[0, 0, 0])
  end

  def test_reduction_over_window_axes
    img = CArray.float64(4, 4, 1).seq
    v = img.unfold([2, 2])                 # [3, 3, 2, 2, 1]
    # mean over the two window axes is a 2x2 box filter per channel
    blur = v.mean(axis: [2, 3])
    assert_equal([3, 3, 1], blur.shape)
    # top-left window mean of cells 0,1,4,5 (channel folded as size-1)
    assert_in_delta((0 + 1 + 4 + 5) / 4.0, blur[0, 0, 0], 1e-9)
  end

  # ---- errors ----

  def test_empty_window_raises
    assert_raise(ArgumentError) { CArray.int32(4, 4, 3).seq.unfold([]) }
  end

  def test_window_longer_than_ndim_raises
    assert_raise(ArgumentError) { CArray.int32(4, 4, 3).seq.unfold([3, 3, 3, 3]) }
  end

  def test_window_larger_than_dim_raises
    assert_raise(ArgumentError) { CArray.int32(4, 4, 3).seq.unfold([5, 5]) }
  end

  def test_zero_window_raises
    assert_raise(ArgumentError) { CArray.int32(4, 4, 3).seq.unfold([0, 2]) }
  end

  def test_zero_step_raises
    assert_raise(ArgumentError) { CArray.int32(4, 4, 3).seq.unfold([2, 2], step: 0) }
  end

  def test_step_length_mismatch_raises
    assert_raise(ArgumentError) { CArray.int32(4, 4, 3).seq.unfold([2, 2], step: [1]) }
  end
end
