require "carray/methods/is_in"   # fixlen_widened_with, values_for_lookup

class CArray

  # @!group Sorting and searching

  # @overload locate_addr(ref)
  #   Returns, for each element of `self`, the flat address into `ref`
  #   where the value first occurs, or `UNDEF` where it is not present.
  #   Builds a value-to-first-address map from `ref` in one pass (an
  #   open-addressing hash, the same substrate as {#unique} /
  #   {#value_counts}), then probes each element of `self`; no sort,
  #   peak memory `O(distinct ref values)`.
  #
  #   The return is `ref`'s flat address (0 to `ref.elements - 1`), so a
  #   multi-dimensional `ref` still yields a `self`-shaped result of flat
  #   addresses; downstream reads (`ref[addr]`, `model_var[addr]`, ...)
  #   apply it as a flat gather.
  #
  #   Works on numeric, `CA_OBJECT`, and `CA_FIXLEN` values, matching the
  #   value-hash discovery family: numeric follows `==` with all NaN
  #   collapsed to one value and `-0.0 == +0.0`; object follows Ruby
  #   `hash` / `eql?` with Float NaN collapsed; fixlen follows byte
  #   equality. When `ref` holds duplicate values the returned address is
  #   the earliest (appearance-order) occurrence. Masked cells of `ref` do
  #   not enter the map but still occupy their flat address; masked cells
  #   of `self` are `UNDEF` in the result.
  #
  #   `self` and `ref` are compared at their common type, negotiated by
  #   `CArray.result_type` — a fractional query against an integer `ref`
  #   is compared at the promoted type rather than truncated, so `1.5` no
  #   longer matches `1`, and integers of mixed sign are matched by value
  #   (`-1` never matches `255`). Cross-family input (numeric against
  #   fixlen) raises.
  #
  #   A time key (`CATime`) reads values that are not time arrays -- Time,
  #   Date or String objects, in an Array, an `:object` array or a string
  #   array -- as instants, on either side of the lookup, as {#is_in} does.
  #
  #   Typical use is time-axis lookup: compute the address once against a
  #   reference axis, then reuse it to gather from many `ref`-shaped
  #   variables without repeating the lookup.
  #
  #   @param ref [CArray, Array, Range] reference values to match against;
  #     any shape (used as flat). An Array or Range is the list of its
  #     values, met at a common type with `self` as {#is_in} meets one, so
  #     `2` finds `2.0`.
  #   @return [CArray] `:int64` flat addresses into `ref`, same shape as
  #     `self`; unmatched cells are masked.
  #   @raise [CArray::DataTypeError] when `self` and `ref` have no common data type.
  def locate_addr (ref)
    # A time key (any Face that reconciles operands) against values that do
    # not -- Time, Date or String objects, a string column -- reads them as
    # values of its kind, whichever side they are on.
    if ref.is_a?(CArray) && ref.class == self.class &&
       respond_to?(:in_common_unit_with) && ref.unit != unit
      a, b = in_common_unit_with(ref)
      return a.locate_addr(b)
    end
    # They meet as a comparison does (comparable_pair).
    if respond_to?(:comparable_pair) && !ref.respond_to?(:comparable_pair)
      key, r = comparable_pair(ref)
      return key.locate_addr(r)
    elsif ref.respond_to?(:comparable_pair) && !respond_to?(:comparable_pair)
      r, key = ref.comparable_pair(self)
      return key.locate_addr(r)
    end
    unless ref.is_a?(CArray) || ref.respond_to?(:to_ca)
      raise TypeError, "locate_addr: the reference is an array of values (got #{ref.class})"
    end
    # An Array or Range of values meets self as is_in's does: the common type
    # comes from self and the elements, so 2 finds 2.0 in a float array.  The
    # conversion keeps the order, so the addresses stay positions in ref.
    if ref.is_a?(Array) || ref.is_a?(Range)
      q, r = promote_elements(ref.is_a?(Range) ? ref.to_a : ref)
      return q.send(:__locate_addr__, r)
    end
    ref = ref.to_ca unless ref.is_a?(CArray)
    ref = values_for_lookup(ref)
    if data_type == CA_FIXLEN && ref.data_type == CA_FIXLEN && bytes != ref.bytes
      a, b = fixlen_widened_with(ref)
      return a.locate_addr(b) unless a.equal?(self) && b.equal?(ref)
    end
    # Put self and ref in the type they match in (query_match_type), so a
    # fractional query against an int ref is compared as a float (1.5 does
    # not match 1) and a pair of mixed sign by value.  to_type is elementwise
    # and order-preserving, so the addresses stay valid indices into ref.
    t = ref.send(:query_match_type, self)
    q = (data_type     == t) ? self : to_type(t)
    r = (ref.data_type == t) ? ref  : ref.to_type(t)
    q.send(:__locate_addr__, r)
  end

  # @overload locate_nearest_addr(ref, direction: :round, tolerance: nil)
  #   Returns, for each element of `self`, the flat address into `ref` of
  #   the nearest reference value. Continuous sibling of {#locate_addr}:
  #   each cell is placed among the sorted reference values by comparing
  #   it with them, so an integer key is exact at any size and an infinite
  #   one keeps its place.  `:round` takes the nearer neighbour, the upper
  #   one on a tie.
  #
  #   Outside `ref`'s span the direction still decides: `:floor` matches
  #   a cell after the last value to that last value, `:ceil` matches a
  #   cell before the first value to that first value, and `:round`
  #   matches either to the nearer end.  The other side has no match
  #   (`:floor` before the first value, `:ceil` after the last) and is
  #   masked.  Use `tolerance:` to refuse matches that are too far away.
  #
  #   `tolerance:` (default `nil`) sets a maximum accepted absolute
  #   distance between `self[i]` and its matched `ref` value. When
  #   `|ref[addr] - self[i]| > tolerance`, the result cell is masked. Use
  #   for accuracy-controlled matching (e.g. "an observation snaps to a
  #   time step only if within N seconds").
  #
  #   `ref` need not be given in ascending order: it is sorted internally
  #   and the returned addresses are mapped back to positions in `ref` as
  #   passed.  A masked or NaN `ref` value matches nothing.  Two time keys
  #   of different units are compared in the finer of the two.
  #   With one value present in `ref`, that value is the match for
  #   every cell the direction allows (`:floor` at or after it, `:ceil`
  #   at or before it, `:round` all).  With none, every cell is masked;
  #   an empty `self` gives an empty result.  A masked or NaN cell of
  #   `self` is always masked.
  #
  #   @param ref [CArray] 1-D reference grid to match against.
  #   @param direction [Symbol] `:round`, `:floor`, or `:ceil` — rounding
  #     applied to the fractional position.
  #   @param tolerance [Numeric, String, CATimedelta::Element, nil] maximum
  #     accepted `|self - ref|` distance; cells beyond this are masked.
  #     For a time key it is a duration: a String such as `"10 minutes"` or
  #     a CATimedelta value (a bare number is refused, since its length
  #     would depend on the key's unit). `nil` disables the check.
  #   @return [CArray] `:int64` flat addresses into `ref`, same shape as
  #     `self`; cells with no match in the direction and beyond-tolerance
  #     cells are masked.
  #   @raise [ArgumentError] when `direction` is not one of the accepted
  #     symbols, or `tolerance` is not a duration for a time key.
  def locate_nearest_addr (ref, direction: :round, tolerance: nil)
    unless [:round, :floor, :ceil].include?(direction)
      raise ArgumentError,
            "locate_nearest_addr: direction must be :round / :floor / " \
            ":ceil (got #{direction.inspect})"
    end
    [self, ref].each { |key| nearest_refuse_bytes(key) }
    return CArray.int64(*shape) if elements == 0
    # A masked reference value matches nothing, as in locate_addr: sorting
    # puts the masked ones last, and only the others are searched.  A NaN
    # one has no place among the others either; it sorts after them.
    ri = ref.sort_addr
    ri = ri[0...ref.count_not_masked] if ref.has_mask?
    if ref.float? && ri.elements > 0
      ri = ri[0...(ri.elements - ref[ri].is_nan.count(true))]
    end
    if ri.elements == 0
      out = CArray.int64(*shape)
      out[] = UNDEF
      return out
    end
    rs = ref[ri]
    n = rs.elements
    rk, qk = nearest_keys(rs, self)
    # The position of each cell among the sorted references is counted, not
    # interpolated: :floor takes the last reference at or below it, :ceil the
    # first at or above it.
    # Counting keeps an integer key exact past 2**53 and an infinite one in
    # its place, where an interpolated position would not.
    si = case direction
         when :floor then nearest_count_below(rk, qk, true) - 1
         when :ceil  then nearest_count_below(rk, qk, false)
         when :round then nearest_round(rk, qk, nearest_count_below(rk, qk, false))
         end
    si[si.lt(0) | si.ge(n)] = UNDEF
    si[qk.is_nan.strip_mask(false)] = UNDEF if qk.float?
    si = si.reshape(*shape)
    si[is_masked] = UNDEF if has_mask?
    idx = ri.project(si)
    if tolerance
      dist = (ref.project(idx) - self).abs
      idx[dist > nearest_tolerance(tolerance, dist)] = UNDEF
    end
    idx
  end

  # A key held as fixed-length bytes (raw fixlen, or a fixlen string) has
  # no nearest: the search counts keys as numbers.  A Face whose storage is
  # a number (a time) is searched by that number.
  # +subject+ and +remedy+ let a caller (CAFrame#join_asof) say it in its
  # own words.
  private def nearest_refuse_bytes(key, subject = nil, remedy = "match exact values with locate_addr")
    # A Face whose cells encode the value (a const string, a categorical)
    # is refused later by its own reconcile, which says why.
    return unless key.is_a?(CArray) && key.__send__(:orderable_storage?)
    storage = key.face? ? key.__send__(:face_storage) : key
    return unless storage.data_type == CA_FIXLEN
    subject ||= "locate_nearest_addr: a #{key.face? ? key.class.name : 'fixlen'} key"
    raise CArray::DataTypeError,
          "#{subject} is held as fixed-length bytes, which have no nearest; #{remedy}"
  end

  # The keys locate_nearest_addr orders by: the storage of the sorted
  # reference and of the query, in one numeric type.  A Face key is first
  # brought into the reference's space (two time keys of different units
  # into the finer of the two, which holds both exactly); plain keys meet at
  # the type CArray.result_type gives, an integer pair of mixed sign at one
  # that holds both.
  private def nearest_keys(rs, q)
    if rs.face? || q.face?
      if rs.respond_to?(:to_unit) && q.class == rs.class && q.unit != rs.unit
        u  = CATimeUnitAlgebra.finer(rs.unit, q.unit)
        rs = rs.to_unit(u)
        q  = q.to_unit(u)
      end
      q  = rs.__send__(:reconcile_operand, q, "locate_nearest_addr")
      rs = rs.__send__(:face_storage)
    end
    t = rs.send(:query_match_type, q)
    rk = (rs.data_type == t) ? rs : rs.to_type(t)
    qk = (q.data_type  == t) ? q  : q.to_type(t)
    [rk, qk.flatten]
  end

  # For each query key, how many of the sorted reference keys are below it
  # (inclusive: at or below).  A numeric key is binary-searched in C; an
  # object key is sorted together with the references, a tie putting the
  # reference first when it counts, and counted against the references met
  # before it.
  private def nearest_count_below(rk, qk, inclusive)
    return rk.send(:__count_below__, qk, inclusive) unless rk.data_type == CA_OBJECT
    n, m = rk.elements, qk.elements
    keys = CArray.concatenate([rk, qk])
    tag  = CArray.int8(n + m)
    tag[0...n]   = inclusive ? 0 : 1
    tag[n...n+m] = inclusive ? 1 : 0
    perm  = CArray.sort_addr(keys, tag)
    seen  = perm.lt(n).cumsum.int64
    query = perm.ge(n)
    count = CArray.int64(m)
    count[perm[query] - n] = seen[query]
    count
  end

  # :round -- an exact match takes its first reference; otherwise the
  # nearer of the two neighbours, the upper one on a tie.  +lt+ counts the
  # references below each key, so the upper neighbour is at lt and an exact
  # match is the reference there.
  private def nearest_round(rk, qk, lt)
    lo = rk.project(lt - 1)
    hi = rk.project(lt)
    upper = (hi - qk).le(qk - lo).strip_mask(false)
    upper[lo.is_masked] = true if lo.has_mask?
    upper[hi.is_masked] = false if hi.has_mask?
    upper[hi.eq(qk).strip_mask(false)] = true
    si = lt - 1
    si[upper] = lt[upper]
    si
  end

  # The tolerance in the units of the distance. A time key measures its
  # distance as a CATimedelta, so its tolerance is a duration: a String in
  # the spelling CArray.time takes for a unit ("10 minutes"), or a
  # CATimedelta value. A bare number would mean a different length in each
  # unit, so it is refused there; any other key takes a number.
  private def nearest_tolerance(tolerance, dist)
    unless dist.is_a?(CATimedelta)
      if tolerance.is_a?(String)
        raise ArgumentError,
              "tolerance: #{tolerance.inspect} is a duration, but the key is " \
              "#{data_type_name}; give a number"
      end
      return tolerance
    end
    case tolerance
    when String
      res = CATime::Resolution.parse(tolerance)
      CATimedelta::Element.new(res.count, res.base)
    when CATimedelta::Element
      tolerance
    else
      raise ArgumentError,
            "tolerance: a time key needs a duration such as \"10 minutes\" " \
            "or a CATimedelta value (got #{tolerance.inspect})"
    end
  end

  # @!endgroup

end
