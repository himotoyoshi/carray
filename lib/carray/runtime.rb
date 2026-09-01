# Load-bearing Ruby support that the core depends on at run time.  Unlike
# carray/basics.rb (convenience methods kept eager merely because they are
# frequent), the definitions here are NOT optional: removing or lazy-loading
# them breaks core behaviour.  Keep this file eager-loaded.

class CArray

  # String fallback for the global cast functions CA_INT32(data) etc.  The C
  # dispatcher (ext/carray_cast.c) handles every other input class in C and
  # delegates only String here, because the whitespace / `,` / `;` /
  # `_`->UNDEF parser is far more natural (and maintainable) in Ruby.
  # +type+ arrives as the data_type Symbol.  Required: without it
  # +CA_INT32("1 2 3")+ and friends raise.
  def self.__cast_string__ (type, v) # :nodoc:
    if type == CA_OBJECT
      return CScalar.new(CA_OBJECT) { v }
    elsif type == CA_BOOLEAN
      v = v.dup
      v.tr!('^01',"1")
      v.tr!('01',"\x0\x1")
      return CArray.boolean(v.length).load_binary(v)
    else
      case v
      when /;/
        v = v.strip.split(/\s*;\s*/).
                         map{|s| s.split(/\s+|\s*,\s*/).map{|x| x=='_' ? UNDEF : x} }
      else
        v = v.strip.split(/\s+|\s*,\s*/).map{|x| x=='_' ? UNDEF : x}
      end
      return CArray.new(type, CArray.guess_array_shape(v)).tap { |a| a[] = v }
    end
  end
  private_class_method :__cast_string__

  # CA_OBJECT escape for the weighted-sum kernel (mkkernel object_escape:).
  # The C dispatcher (carray_kernels.c rb_ca_wsum_ki) intercepts CA_OBJECT
  # source and forwards here verbatim, because a per-cell object weighted sum
  # is more naturally (and exactly, for Rational / BigDecimal weights) a
  # +(self * weights).sum+ composition than a dedicated :object kernel branch.
  #
  # +weights+ is a Ruby Numeric scalar (W-A1) or a same-shape CArray; the 1-D
  # axis-broadcast form (W-A2) is not supported for object weights (pass a
  # scalar or a full-shape weight), matching CArray's explicit-broadcast rule.
  # +opts+ is the trailing options Hash (axis:/keep_axis:/min_count:/
  # fill_value:) forwarded verbatim by the C escape; it goes straight to +sum+.
  def __wsum_object__ (weights, opts = {}) # :nodoc:
    (self * weights).sum(**opts)
  end
  private :__wsum_object__

  # CA_OBJECT escape for the weighted-mean kernel.  Weighted mean is
  # +Σ(w*v) / Σw+ over the cells valid after mask overlay (a masked value OR a
  # masked weight drops the cell from BOTH sums).  The denominator is guarded:
  # an empty / all-masked slab or weights summing to zero yields UNDEF (the
  # object analogue of the numeric kernel's 0/0 -> NaN, since objects have no
  # NaN).  Weight forms and +opts+ as in {#__wsum_object__}.
  def __wmean_object__ (weights, opts = {}) # :nodoc:
    axis      = opts[:axis]
    keep_axis = opts[:keep_axis]
    prod = self * weights
    wv   = (weights.is_a?(CArray) ? weights : self * 0 + weights).copy
    wv[prod.is_masked] = UNDEF if prod.has_mask?
    nopt = { axis: axis, keep_axis: keep_axis }
    nopt[:min_count] = opts[:min_count] unless opts[:min_count].nil?
    num = prod.sum(**nopt)
    den = wv.sum(axis: axis, keep_axis: keep_axis)
    result =
      if axis
        den = den.copy
        den[den.eq(0)] = UNDEF          # zero / empty denominator -> undetermined
        num / den                        # UNDEF propagates cell-wise
      elsif den.equal?(UNDEF) || den == 0
        UNDEF
      else
        num / den
      end
    fill_value = opts[:fill_value]
    return result if fill_value.nil?
    if result.is_a?(CArray)
      result[result.is_masked] = fill_value if result.has_mask?
      result
    else
      result.equal?(UNDEF) ? fill_value : result
    end
  end
  private :__wmean_object__

end

