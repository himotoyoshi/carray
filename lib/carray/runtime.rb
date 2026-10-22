# Load-bearing Ruby support that the core depends on at run time.  Unlike
# carray/basics.rb (convenience methods kept eager merely because they are
# frequent), the definitions here are NOT optional: removing or lazy-loading
# them breaks core behaviour.  Keep this file eager-loaded.

class CArray

  # A fast path answers by a different algorithm what a general path also
  # answers.  A development build defines this in C, false when run with
  # CARRAY_GENERAL_PATH=1 so the test suite takes the general paths (see
  # ext/carray_internal.h); a release build has no switch.
  unless respond_to?(:__fast_paths_enabled__)
    def self.__fast_paths_enabled__ # :nodoc:
      true
    end
  end

  # True when a development build runs with CARRAY_GENERAL_PATH=2: the
  # kernel iterator then delivers every source through the view's own
  # transfer.  A release build has no switch.
  unless respond_to?(:__iter_by_transfer_only__)
    def self.__iter_by_transfer_only__ # :nodoc:
      false
    end
  end

  # String fallback for the global cast functions CA_INT32(data) etc.  The C
  # dispatcher (ext/carray_cast.c) handles every other input class in C and
  # delegates only String here, because the whitespace / `,` / `;` /
  # `_`->UNDEF parser is far more natural (and maintainable) in Ruby.
  # +type+ arrives as the data_type Symbol.  Required: without it
  # +CA_INT32("1 2 3")+ and friends raise.
  def self.cast_string (type, v)
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
  private_class_method :cast_string

  # CA_OBJECT escape for the weighted-sum kernel (mkkernel object_escape:).
  # The C dispatcher (carray_kernels.c rb_ca_wsum_ki) intercepts CA_OBJECT
  # source and forwards here verbatim, because a per-cell object weighted sum
  # is more naturally (and exactly, for Rational / BigDecimal weights) a
  # +(self * weights).sum+ composition than a dedicated :object kernel branch.
  #
  # +weights+ takes the forms the numeric kernel takes: a scalar (or a
  # one-element CArray), an array of the shape of the reduced axes (taken in
  # ascending axis order), or an array of self.shape.  +opts+ is the trailing
  # options Hash (axis:/keep_axis:/min_count:/fill_value:) forwarded verbatim
  # by the C escape; it goes straight to +sum+.
  def wsum_object (weights, opts = {}) # :nodoc:
    weights = weights_over_self_shape(weights, opts[:axis], "wsum")
    return (self * weights).sum(**opts)
  end
  private :wsum_object

  # CA_OBJECT escape for the weighted-mean kernel.  Weighted mean is
  # +Σ(w*v) / Σw+ over the cells valid after mask overlay (a masked value OR a
  # masked weight drops the cell from BOTH sums).  The denominator is guarded:
  # an empty / all-masked slab or weights summing to zero yields UNDEF (the
  # object analogue of the numeric kernel's 0/0 -> NaN, since objects have no
  # NaN).  Weight forms and +opts+ as in {#wsum_object}.
  def wmean_object (weights, opts = {}) # :nodoc:
    axis      = opts[:axis]
    keep_axis = opts[:keep_axis]
    weights = weights_over_self_shape(weights, axis, "wmean")
    prod = self * weights
    wv   = (weights.is_a?(CArray) ? weights : self * 0 + weights).copy
    wv[prod.is_masked] = UNDEF if prod.has_mask?
    nopt = { axis: axis, keep_axis: keep_axis }
    nopt[:min_count] = opts[:min_count] unless opts[:min_count].nil?
    num = prod.sum(**nopt)
    den = wv.sum(axis: axis, keep_axis: keep_axis)
    result =
      if den.is_a?(CArray)               # axis given, or keep_axis
        den = den.copy
        den[den.eq(0)] = UNDEF          # zero / empty denominator -> undetermined
        num / den                        # UNDEF propagates cell-wise
      elsif num.equal?(UNDEF) || den.equal?(UNDEF) || den == 0
        UNDEF                            # min_count unmet leaves num UNDEF
      else
        num / den
      end
    CArray.__fill_undefined_result_cells__(result, opts[:fill_value])
  end
  private :wmean_object

  # The weights of wsum / wmean as a scalar or an array of self.shape.  An
  # array of the shape of the reduced axes (in ascending axis order) is
  # repeated along the kept axes; any other shape is refused, with the same
  # message as the numeric kernel.
  def weights_over_self_shape (weights, axis, name) # :nodoc:
    unless weights.is_a?(CArray)
      return weights
    end
    if weights.elements == 1
      return weights[0]
    end
    if weights.shape == self.shape
      return weights
    end
    axes = case axis
           when nil     then (0...self.ndim).to_a
           when Integer then [axis]
           else              axis
           end
    axes = axes.map { |a| ( a < 0 ) ? a + self.ndim : a }.sort
    reduced_shape = axes.map { |a| self.shape[a] }
    unless weights.shape == reduced_shape
      raise ArgumentError,
            "#{name}: weights of shape #{weights.shape.inspect} not accepted " \
            "(expected a scalar, the shape of the reduced axes " \
            "#{reduced_shape.inspect}, or self.shape #{self.shape.inspect})"
    end
    spread = self.shape.each_index.map { |i| axes.include?(i) ? self.shape[i] : 1 }
    return weights.reshape(*spread).broadcast_to(*self.shape)
  end
  private :weights_over_self_shape

  # Define on +mod+ one method per name in +names+, each a `def` that passes
  # its own name and its arguments to the private method +to+:
  #
  #   CArray.send(:define_named_methods, self, [:sum, :min], :fold_reduction)
  #   # def sum (...) = fold_reduction(:sum, ...)
  #
  # A method made by define_method carries no name in its frame, so an error
  # raised inside it cannot name the method the user called; a `def` does.
  # With +super_block+ the method passes its arguments as an Array and a Hash,
  # and a block that calls the method it overrides with the arguments the
  # block is given (`yield(*args, **kw)`).
  #
  # With +template+ (and no +to+) each method is written out from it, for a
  # method on a path where a helper call would cost: __NAME__ is the name and
  # __VALUE__ the value +names+ (a Hash) gives it, inspected.
  NAMED_METHOD = /\A(?:[a-z_]\w*[?!]?|\+|-|\*\*?|\/|%|<=>|==|<=?|>=?|<<|>>|&|\||\^|~|[+-]@)\z/
  def self.define_named_methods (mod, names, to = nil, super_block: false, template: nil)
    loc = caller_locations(1, 1).first
    names.each do |name, value|
      unless name.to_s.match?(NAMED_METHOD)
        raise ArgumentError, "define_named_methods: #{name.inspect} is not a method name"
      end
      src = if template
              template.gsub("__NAME__", name.to_s).gsub("__VALUE__", value.inspect)
            elsif super_block
              "def #{name}(*args, **kw, &blk)\n" \
              "  #{to}(:#{name}, args, kw) { |*a, **k| super(*a, **k, &blk) }\n" \
              "end\n"
            else
              "def #{name}(...)\n  #{to}(:#{name}, ...)\nend\n"
            end
      mod.class_eval(src, loc.path, loc.lineno)
    end
  end
  private_class_method :define_named_methods

end

