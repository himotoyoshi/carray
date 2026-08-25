#  User-defined arbitrary key/value metadata attached to a CArray
#  instance.
#
#  Surface:
#    ca.attr(:unit)             # => getter; nil if absent
#    ca.set_attr(:unit, "m/s")  # => setter; writes to self's @attr
#    ca.attrs                   # => frozen shallow clone of the full Hash
#    ca.has_attr?               # => any attribute present?
#    ca.has_attr?(:unit)        # => specific key present?
#
#  Key:   accepts Symbol or String on input; stored as String.
#  Value: JSON-compatible plus non-finite Floats (String / Numeric,
#         including Infinity / NaN / -Infinity / true / false / nil /
#         Array / Hash<String|Symbol, ...>).  Symbol values are
#         coerced to String on store.  Disallowed types raise
#         TypeError on set.  Non-finite Floats are accepted so
#         imported metadata (e.g. a NetCDF _FillValue of Infinity)
#         is not rejected; the serialize trailer is YAML, whose
#         .inf / .nan literals round-trip them (serialize.rb).
#
#  View semantics (per-key fallback):
#    Getter side (attr / has_attr?) walks the parent chain
#    *per key*: if the receiver's @attr has the key, return it;
#    otherwise walk up.  Each view shadows its parents one key at
#    a time, so writing :slice on a view does not hide :unit
#    inherited from the parent entity.
#    `attrs` returns the effective merged Hash (deeper writes
#    override shallower ones), frozen.
#    Setter side always writes to self's @attr.

class CArray

  # @!group Attributes

  # @overload attr(key)
  #   Returns the value of the attribute `key`, or `nil` when the key
  #   is absent. Walks the parent chain per key: the deepest view
  #   that has an entry for `key` wins.
  #   @param key [Symbol, String] attribute key.
  #   @return [Object, nil]
  def attr (key)
    k = attr_normalize_key(key)
    attr_each_chain do |h|
      return h[k] if h.key?(k)
    end
    nil
  end

  # @overload set_attr(key, value)
  #   Sets attribute `key` to `value` on `self` (not on any parent).
  #   Values are validated as JSON-compatible plus non-finite Floats
  #   (String / Numeric incl. Infinity / NaN / true / false / nil /
  #   Symbol / Array / Hash); Symbol values are coerced to String on
  #   store.
  #   @param key [Symbol, String] attribute key.
  #   @param value [Object] JSON-compatible value.
  #   @return [Object] the coerced stored value.
  #   @raise [TypeError] when `key` or `value` is not accepted.
  def set_attr (key, value)
    attr_validate_value(value)
    (@attr ||= {})[attr_normalize_key(key)] = attr_coerce_value(value)
  end

  # @overload attrs
  #   Returns a frozen shallow Hash of all attributes visible on
  #   `self`, merged along the parent chain (deeper writes shadow
  #   shallower ones on a per-key basis).
  #   @return [Hash{String => Object}]
  def attrs
    merged = nil
    attr_each_chain do |h|
      merged ||= {}
      h.each { |k, v| merged[k] = v unless merged.key?(k) }
    end
    (merged || {}).freeze
  end

  # @overload has_attr?
  #   Returns whether `self` (or any parent view) has any attribute
  #   set.
  #   @return [Boolean]
  # @overload has_attr?(key)
  #   Returns whether `self` (or any parent view) has attribute `key`
  #   set.
  #   @param key [Symbol, String] attribute key.
  #   @return [Boolean]
  def has_attr? (key = nil)
    if key.nil?
      attr_each_chain do |h|
        return true unless h.empty?
      end
      false
    else
      k = attr_normalize_key(key)
      attr_each_chain do |h|
        return true if h.key?(k)
      end
      false
    end
  end

  private

  # Yield each non-nil @attr Hash along the parent chain (self first).
  # Bounded to MAX_CHAIN_DEPTH for paranoia against unexpected cycles;
  # real CArray view chains rarely exceed a handful of levels.
  MAX_CHAIN_DEPTH = 64
  private_constant :MAX_CHAIN_DEPTH

  def attr_each_chain
    ca = self
    MAX_CHAIN_DEPTH.times do
      if ca.instance_variable_defined?(:@attr)
        h = ca.instance_variable_get(:@attr)
        yield(h) if h
      end
      parent = ca.respond_to?(:parent) ? ca.parent : nil
      return nil if parent.nil? || parent.equal?(ca)
      ca = parent
    end
    nil
  end

  def attr_normalize_key (key)
    case key
    when String then key
    when Symbol then key.to_s
    else
      raise TypeError, "attribute key must be String or Symbol (got #{key.class})"
    end
  end

  def attr_validate_value (v, depth = 0)
    raise ArgumentError, "attribute value nests too deep" if depth > 32
    case v
    when String, Integer, Float, true, false, nil, Symbol
      # ok (Symbol will be coerced to String on store)
    when Array
      v.each { |e| attr_validate_value(e, depth + 1) }
    when Hash
      v.each do |k, vv|
        unless k.is_a?(String) || k.is_a?(Symbol)
          raise TypeError, "nested Hash keys must be String or Symbol (got #{k.class})"
        end
        attr_validate_value(vv, depth + 1)
      end
    else
      raise TypeError, "attribute value must be JSON-compatible " \
                       "(String/Numeric/true/false/nil/Symbol/Array/Hash); got #{v.class}"
    end
  end

  def attr_coerce_value (v)
    case v
    when Symbol then v.to_s
    when Array  then v.map { |e| attr_coerce_value(e) }
    when Hash
      v.each_with_object({}) do |(k, vv), h|
        h[k.is_a?(Symbol) ? k.to_s : k] = attr_coerce_value(vv)
      end
    else
      v
    end
  end

end
