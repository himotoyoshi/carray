# CAMeld reduce fast paths (per-parent decompose family).
#
# All decomposable reductions along the meld axis land at eager-entity
# parity via the identity
#   op(concat_k p_k) = combine_k op(p_k)
# where op is sum/min/max/mean/etc. and combine_k is +, min, max, or the
# Welford update (variance/stddev).  Each per-parent op runs on an entity,
# hitting the fastest kernel_iterator path, and dodges the whole-view
# SRC_ATTACH materialise (K per-parent xfer_all GET into scratch).
#
# Reductions along a non-meld axis (memo §7.4) also decompose: each
# parent independently reduces the non-meld axis, and the K results are
# concatenated back along the meld axis via `CArray.meld`.  Result is
# materialised (`.copy`) to preserve the entity-returning semantic of
# `CArray#sum`/`#mean`/etc.
#
# Fast path activates when:
#   - axis kwarg is a single Integer (or absent for flat reduce)
#   - no mask on CAMeld or any parent (skipna needs per-cell dispatch;
#     the decompose would not see correct mask propagation across parents)
#   - no non-:axis kwargs (min_count / fill_value / keep_axis / etc. punt
#     to super; those change finalisation semantics)
# When any condition fails the method falls through to super, landing on
# the kernel_iterator SRC_ATTACH path (correct, just slower).
#
# Order statistics (median / percentile / quantile) do NOT decompose —
# per-parent medians are not a function of the overall median — so those
# stay on the SRC_ATTACH path, which is already essentially parity because
# the sort cost dominates.
#
# See docs/objects/CAMeld.md and devel/bench_cameld_*.rb for numbers.

class CAMeld

  # ---------- monoid reductions (sum / mean / min / max) ----------

  def sum(*args, **kw)
    return super unless args.empty? && meld_reduce_fast_path_ok?(kw)
    axis = kw[:axis]
    if axis.nil?
      parents.map(&:sum).inject(:+)
    elsif meld_axis_normalized?(axis)
      parents.map { |p| p.sum(axis: axis) }.inject(:+)
    else
      non_meld_axis_decompose(:sum, axis)
    end
  end

  # Same result as `CArray#mean`, obtained by reducing each parent and
  # combining, so the melded array is never materialised.  Falls back to
  # the generic path when the decomposition does not apply.
  # @return [CArray, Numeric]
  def mean(*args, **kw)
    return super unless args.empty? && meld_reduce_fast_path_ok?(kw)
    axis = kw[:axis]
    # `mean` has no identity: an empty set of contributors has no defined
    # mean (0/0 = NaN).  Punt to super, which returns UNDEF: a reduction
    # with no contributors yields the identity where one exists and UNDEF
    # where none does, and never raises.
    if axis.nil?
      return super if parents.all? { |p| p.elements == 0 }
      total_sum = parents.map(&:sum).inject(:+)
      total_count = parents.map(&:elements).inject(:+)
      total_sum / total_count.to_f
    elsif meld_axis_normalized?(axis)
      return super if parents.all? { |p| p.dim[meld_axis] == 0 }
      total_sum = parents.map { |p| p.sum(axis: axis) }.inject(:+)
      total_count = parents.map { |p| p.dim[meld_axis] }.inject(:+)
      total_sum / total_count.to_f
    else
      non_meld_axis_decompose(:mean, axis)
    end
  end

  # Same result as `CArray#min`, obtained by reducing each parent and
  # combining, so the melded array is never materialised.  Falls back to
  # the generic path when the decomposition does not apply.
  # @return [CArray, Numeric]
  def min(*args, **kw)
    return super unless args.empty? && meld_reduce_fast_path_ok?(kw)
    axis = kw[:axis]
    # `min` has no identity — empty parent list / all-empty parents punt to
    # super for UNDEF.
    if axis.nil?
      return super if parents.all? { |p| p.elements == 0 }
      parents.reject { |p| p.elements == 0 }.map(&:min).min
    elsif meld_axis_normalized?(axis)
      return super if parents.all? { |p| p.dim[meld_axis] == 0 }
      nonempty = parents.reject { |p| p.dim[meld_axis] == 0 }
      CArray.stack(nonempty.map { |p| p.min(axis: axis) }).min(axis: 0)
    else
      non_meld_axis_decompose(:min, axis)
    end
  end

  # Same result as `CArray#max`, obtained by reducing each parent and
  # combining, so the melded array is never materialised.  Falls back to
  # the generic path when the decomposition does not apply.
  # @return [CArray, Numeric]
  def max(*args, **kw)
    return super unless args.empty? && meld_reduce_fast_path_ok?(kw)
    axis = kw[:axis]
    if axis.nil?
      return super if parents.all? { |p| p.elements == 0 }
      parents.reject { |p| p.elements == 0 }.map(&:max).max
    elsif meld_axis_normalized?(axis)
      return super if parents.all? { |p| p.dim[meld_axis] == 0 }
      nonempty = parents.reject { |p| p.dim[meld_axis] == 0 }
      CArray.stack(nonempty.map { |p| p.max(axis: axis) }).max(axis: 0)
    else
      non_meld_axis_decompose(:max, axis)
    end
  end

  # ---------- variance family (Welford combine along meld axis) ----------
  #
  # Chan / Welford parallel merge: each parent contributes (n_k, mean_k,
  # M2_k = Σ (x - mean_k)^2).  Combine two chunks (n1, m1, M1) + (n2, m2, M2):
  #   n = n1 + n2
  #   δ = m2 - m1
  #   mean = m1 + δ * n2 / n
  #   M2   = M1 + M2 + δ² * (n1 * n2 / n)
  # sample variance   = M2 / (n - 1)
  # population variance = M2 / n
  #
  # M2 per parent is recovered from CArray's variance:
  #   M2_k = variance_k * (n_k - 1)   [sample-variance CArray path]
  # This inherits CArray's ε-close SIMD reduce contract (memo: reduction is
  # ε-close, not bit-exact).  Falls through to super when any parent has
  # n <= 1 along the axis (sample variance undefined).

  def variance(*args, **kw)
    variance_family(args, kw, sample: true, sqrt: false) { super }
  end

  # Same result as `CArray#variancep`, obtained by reducing each parent and
  # combining, so the melded array is never materialised.  Falls back to
  # the generic path when the decomposition does not apply.
  # @return [CArray, Numeric]
  def variancep(*args, **kw)
    variance_family(args, kw, sample: false, sqrt: false) { super }
  end

  # Same result as `CArray#stddev`, obtained by reducing each parent and
  # combining, so the melded array is never materialised.  Falls back to
  # the generic path when the decomposition does not apply.
  # @return [CArray, Numeric]
  def stddev(*args, **kw)
    variance_family(args, kw, sample: true, sqrt: true) { super }
  end

  # Same result as `CArray#stddevp`, obtained by reducing each parent and
  # combining, so the melded array is never materialised.  Falls back to
  # the generic path when the decomposition does not apply.
  # @return [CArray, Numeric]
  def stddevp(*args, **kw)
    variance_family(args, kw, sample: false, sqrt: true) { super }
  end

  private

  def meld_axis_normalized?(axis)
    (axis < 0 ? axis + ndim : axis) == meld_axis
  end

  # Fast path fires when: no mask anywhere, no non-:axis kwargs, and axis
  # (if given) is a valid single Integer within [-ndim, ndim).  Anything
  # more elaborate (min_count / fill_value / keep_axis / multi-axis /
  # mask propagation) punts to super.
  def meld_reduce_fast_path_ok?(kw)
    return false unless (kw.keys - [:axis]).empty?
    axis = kw[:axis]
    unless axis.nil?
      return false unless axis.is_a?(Integer)
      norm = axis < 0 ? axis + ndim : axis
      return false unless norm >= 0 && norm < ndim
    end
    return false if has_mask?
    parents.each { |p| return false if p.has_mask? }
    true
  end

  # Non-meld-axis decompose: each parent reduces the same axis independently,
  # then the K per-parent results are concatenated back along the meld axis.
  # Materialised to entity (`.copy`) to match CArray#reduce entity semantics.
  #
  # Axis index in the reduced result: if the reduced axis is < meld_axis in
  # the CAMeld frame, meld_axis shifts down by 1 in the per-parent result
  # (post-reduce ndim = ndim - 1).  If reduced axis > meld_axis, meld_axis
  # is unchanged.  (Reduced axis == meld_axis is handled by the callers'
  # meld_axis branch and never reaches here.)
  def non_meld_axis_decompose(op, axis)
    parts = parents.map { |p| p.public_send(op, axis: axis) }
    axis_norm = axis < 0 ? axis + ndim : axis
    new_meld_axis = axis_norm < meld_axis ? meld_axis - 1 : meld_axis
    CArray.meld(parts, axis: new_meld_axis).copy
  end

  def variance_family(args, kw, sample:, sqrt:)
    return yield unless args.empty? && meld_reduce_fast_path_ok?(kw)
    axis = kw[:axis]
    # Empty-parent / short-parent handling — Welford needs n >= 2 per parent
    # to recover m2 from p.variance for sample, n >= 1 for variancep (n=1
    # gives m2=0, fine).  Any parent below its threshold punts to super,
    # which handles the UNDEF / zero-count cases.
    min_n = sample ? 2 : 1
    if axis.nil?
      return yield if parents.any? { |p| p.elements < min_n }
      finalize_scalar(welford_flat, sample, sqrt)
    elsif meld_axis_normalized?(axis)
      return yield if parents.any? { |p| p.dim[meld_axis] < min_n }
      finalize_vector(welford_axis(axis), sample, sqrt)
    else
      # Non-meld-axis: each parent's variance/stddev is independent along
      # its own local axis; concatenate the K results along the meld axis.
      op_super = sqrt ? (sample ? :stddev : :stddevp) : (sample ? :variance : :variancep)
      non_meld_axis_decompose(op_super, axis)
    end
  end

  # Flat Welford — reduces every parent fully; returns scalar (n_tot, mean, M2)
  # trio in a shape suitable for finalize_scalar.  Returns [n_tot, M2].
  # Preconditions (checked in variance_family): every parent has enough
  # elements (>= 2 for sample, >= 1 for population).
  def welford_flat
    n_tot = 0
    mean = nil
    m2 = nil
    parents.each do |p|
      np = p.elements
      mp = p.mean
      # variance is undefined at n=1 (returns UNDEF / raises).  For
      # variancep (min_n=1) with n=1, m2_p = 0 by definition; skip the
      # p.variance call which would blow up.
      m2p = np < 2 ? 0.0 : p.variance * (np - 1)
      if mean.nil?
        n_tot = np; mean = mp; m2 = m2p
      else
        delta = mp - mean
        nn = n_tot + np
        mean = mean + delta * np / nn.to_f
        m2 = m2 + m2p + delta * delta * (n_tot * np / nn.to_f)
        n_tot = nn
      end
    end
    [n_tot, m2]
  end

  # Per-axis Welford — reduces every parent along the given (meld) axis and
  # combines the vector-shaped (n_tot, mean, M2) trio.  Returns [n_tot, M2]
  # (n_tot is scalar since the meld axis is what we're reducing; M2 is a
  # CArray of the collapsed shape).
  def welford_axis(axis)
    n_tot = 0
    mean = nil
    m2 = nil
    parents.each do |p|
      np = p.dim[meld_axis]
      mp = p.mean(axis: axis)
      # variance is undefined at n=1; for variancep with n=1, m2_p = 0 by
      # definition (variance_family already gated n >= min_n).
      m2p = np < 2 ? mp * 0 : p.variance(axis: axis) * (np - 1)
      if mean.nil?
        n_tot = np; mean = mp; m2 = m2p
      else
        delta = mp - mean
        nn = n_tot + np
        mean = mean + delta * (np.to_f / nn)
        m2 = m2 + m2p + delta * delta * (n_tot * np.to_f / nn)
        n_tot = nn
      end
    end
    [n_tot, m2]
  end

  def finalize_scalar(pair, sample, sqrt)
    n_tot, m2 = pair
    div = sample ? (n_tot - 1) : n_tot
    v = m2 / div.to_f
    sqrt ? Math.sqrt(v) : v
  end

  def finalize_vector(pair, sample, sqrt)
    n_tot, m2 = pair
    div = sample ? (n_tot - 1) : n_tot
    v = m2 / div.to_f
    sqrt ? v.sqrt : v
  end
end
