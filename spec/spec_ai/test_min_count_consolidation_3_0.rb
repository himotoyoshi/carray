# MEMO_GALAPAGOS_ESCAPE.md 2026-05-28: stat-fn mask-threshold options
# consolidated into a single `:min_count` knob in 3.0.  `:mask_limit` is
# removed.  `:min_count` accepts only non-negative absolute counts;
# negative values (old elements-relative spelling) are rejected.
#
# Semantics: `valid_count >= min_count` -> compute; else UNDEF (or
# fill_value).  Default unspecified -> min_count: 0 (lenient).

require 'test/unit'
require 'carray'

class TestMinCountSemantics < Test::Unit::TestCase

  def setup
    # 5-element array with 2 cells masked -> 3 valid.
    @a = CA_FLOAT64([1.0, 2.0, 3.0, 4.0, 5.0])
    @a[1] = UNDEF
    @a[3] = UNDEF
  end

  def test_default_is_lenient
    # No option -> lenient (= min_count: 0).
    assert_equal 3.0, @a.mean
  end

  def test_min_count_zero_is_lenient
    assert_equal 3.0, @a.mean(min_count: 0)
  end

  def test_min_count_at_valid_count_threshold
    # valid_count == 3 >= min_count == 3 -> compute.
    assert_equal 3.0, @a.mean(min_count: 3)
  end

  def test_min_count_above_valid_count_returns_undef
    # valid_count == 3 < min_count == 4 -> UNDEF.
    assert_equal UNDEF, @a.mean(min_count: 4)
  end

  def test_min_count_equal_to_elements_is_strict
    # min_count == ca.elements means "all cells must be valid".
    assert_equal UNDEF, @a.mean(min_count: 5)  # 2 masked, fail strict
  end

  def test_min_count_with_fill_value
    assert_equal(-9999, @a.mean(min_count: 4, fill_value: -9999))
  end

  def test_min_count_with_all_valid_satisfies_strict
    b = CA_FLOAT64([1.0, 2.0, 3.0, 4.0, 5.0])  # no mask
    assert_equal 3.0, b.mean(min_count: b.elements)
  end

  # ---- error cases (3.0 fail-fast) ----

  def test_negative_min_count_raises
    assert_raise(ArgumentError) { @a.mean(min_count: -1) }
  end

  def test_negative_min_count_message
    # Phase E: migration hint ("elements - k") was retired together with
    # :mask_limit -- pre-3.0 era is over.  Just check the error mentions
    # the non-negative requirement.
    begin
      @a.mean(min_count: -1)
      flunk "expected ArgumentError"
    rescue ArgumentError => e
      assert_match(/non-negative/, e.message)
    end
  end

  # NOTE (Phase E, 2026-06-02): the :mask_limit migration-helper
  # rejection was retired together with the legacy stat_proc path.
  # Reductions now dispatch through mkkernel-generated ki kernels which
  # only accept :min_count / :fill_value; unknown keys are silently
  # ignored (rb_scan_options default).  The transitional helper served
  # its purpose during the 3.0 cycle and is no longer required.
end

class TestMinCountForRubySideMedianPercentile < Test::Unit::TestCase
  # median / percentile have their Ruby-side min_count check.
  def setup
    @a = CA_FLOAT64([1.0, 2.0, 3.0, 4.0, 5.0])
    @a[1] = UNDEF
    @a[3] = UNDEF
  end

  def test_median_min_count_satisfied
    assert_equal 3.0, @a.median(min_count: 3)
  end

  def test_median_min_count_unsatisfied
    assert_equal UNDEF, @a.median(min_count: 4)
  end

  def test_percentile_min_count_satisfied
    assert_equal 3.0, @a.percentile(50, min_count: 3)
  end

  def test_percentile_min_count_unsatisfied
    assert_equal UNDEF, @a.percentile(50, min_count: 4)
  end

  def test_median_rejects_mask_limit
    assert_raise(ArgumentError) { @a.median(mask_limit: 1) }
  end

  def test_percentile_rejects_mask_limit
    assert_raise(ArgumentError) { @a.percentile(50, mask_limit: 1) }
  end

  def test_median_rejects_negative_min_count
    assert_raise(ArgumentError) { @a.median(min_count: -1) }
  end
end

class TestMinCountAxisReduction < Test::Unit::TestCase
  # Axis reductions: min_count is per-slice (along the reduced axis).
  def test_axis_reduce_lenient_by_default
    a = CArray.float64(3, 4).seq
    a[0, 1] = UNDEF
    a[1, 2] = UNDEF
    # Lenient: each row computes its mean over the unmasked cells.
    row_means = a.mean(axis: 1)  # reduce along axis 1
    refute_equal UNDEF, row_means[0]
    refute_equal UNDEF, row_means[1]
    refute_equal UNDEF, row_means[2]
  end

  def test_axis_reduce_strict_min_count
    a = CArray.float64(3, 4).seq
    a[0, 1] = UNDEF  # row 0 has 3 valid
    a[1, 2] = UNDEF  # row 1 has 3 valid
                     # row 2 has 4 valid (no mask)
    # With min_count: 4, only fully-valid rows compute.
    row_means = a.mean(axis: 1, min_count: 4)
    assert_equal UNDEF, row_means[0]
    assert_equal UNDEF, row_means[1]
    refute_equal UNDEF, row_means[2]
  end
end
