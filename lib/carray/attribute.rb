#  User-defined arbitrary key/value metadata attached to a CArray
#  instance.
#
#  Surface:
#    ca.attr(:unit)             # => getter; nil if absent
#    ca.set_attr(:unit, "m/s")  # => setter; writes to self's @attr
#    ca.set_attrs(other.attrs)  # => sets every key of a Hash at once
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
#    The walk stops at a lazy operation view (CAMonOp / CABinOp /
#    CATriOp / CAMonCmp / CABinCmp): its cells are computed, not the
#    parent's cells, so the parent's attributes do not describe them.
#    `a.lazy` itself (CALazyMarker) is a view of `a` and walks through,
#    and so does a lazy type conversion (the cast lane `promote_list`
#    and `wrap_readonly` build), for the reason `to_type` carries them.
#    A view of a Face shows the attributes of the Face it was taken
#    from (the walk goes to that Face, which the view's own parent
#    chain skips).
#    A view of several arrays (CAStack / CAMeld, so `stack`, `meld` and
#    `montage`) shows, below its own @attr, the keys every one of its
#    arrays shows with the same value; a key they disagree on, or one
#    some of them lack, is not shown.
#
#  Stored values are frozen copies, nested Arrays and Hashes included, so
#  an attribute changes only through set_attr / set_attrs: a value read
#  back cannot be changed in place, and a copy that shares it with its
#  source cannot change the source.  A frozen array takes no new
#  attribute.
#
#  A mask array (`a.mask`) holds no attributes: set_attr / set_attrs raise.
#
#  Copies: `dup` and `clone` give the new array its own Hash of the
#  receiver's own attributes.  `copy` and `to_type` give the new array the attributes the
#  source shows, as its own Hash; `concatenate`, `mosaic` and `tabulate`
#  give it the keys every piece shows with the same value, as the views
#  do.  A conversion to another type or representation (`to_type`,
#  `categorize`, a CAFrame `cast` / `parse_to_time` / `to_time`) carries
#  them.  Arithmetic and reductions do not -- the result is a different
#  quantity -- including those that pick a value (`first`, `last`, `min`,
#  `max`, `unique`).  A CAFrame index built from a key column's values
#  (group and pivot) shows the key column's attributes.

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
  #   The value is stored as a frozen copy (nested Arrays and Hashes
  #   too).
  #   @return [Object] the stored value.
  #   @raise [TypeError] when `key` or `value` is not accepted.
  #   @raise [ArgumentError] when `value` nests more than 32 levels.
  #   @raise [FrozenError] when `self` is frozen.
  #   @raise [TypeError] when `self` is a mask array.
  def set_attr (key, value)
    attr_check_writable
    attr_validate_value(value)
    (@attr ||= {})[attr_normalize_key(key)] = attr_coerce_value(value)
  end

  # @overload set_attrs(hash)
  #   Sets every key of `hash` on `self`, as {#set_attr} does one key.
  #   Keys already on `self` and not in `hash` are kept. Every value is
  #   validated before any is written, so a rejected value leaves `self`
  #   unchanged. `b.set_attrs(a.attrs)` gives `b` the attributes `a`
  #   shows.
  #   @param hash [Hash{Symbol, String => Object}] attributes to set.
  #   @return [CArray] self.
  #   @raise [TypeError] when a key or a value is not accepted.
  #   @raise [ArgumentError] when a value nests more than 32 levels.
  #   @raise [FrozenError] when `self` is frozen.
  #   @raise [TypeError] when `self` is a mask array.
  def set_attrs (hash)
    attr_check_writable
    unless hash.is_a?(Hash)
      raise TypeError, "set_attrs takes a Hash (got #{hash.class})"
    end
    entries = hash.map do |key, value|
      attr_validate_value(value)
      [attr_normalize_key(key), attr_coerce_value(value)]
    end
    unless entries.empty?
      h = (@attr ||= {})
      entries.each { |k, v| h[k] = v }
    end
    self
  end

  # @overload delete_attr(key)
  #   Removes attribute `key` from `self` (not from any parent) and
  #   returns its value, or `nil` when `self` has no such key. A key a
  #   view shows from its parent stays visible after this, as `set_attr`
  #   writes to `self` only.
  #   @param key [Symbol, String] attribute key.
  #   @return [Object, nil] the removed value.
  #   @raise [FrozenError] when `self` is frozen.
  def delete_attr (key)
    k = attr_normalize_key(key)
    return nil unless instance_variable_defined?(:@attr) && @attr
    attr_check_not_frozen
    @attr.delete(k)
  end

  # @overload attrs
  #   Returns a frozen Hash of all attributes visible on
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
  # The chain has no fixed bound; an array seen twice ends the walk.
  def attr_each_chain
    ca = self
    seen = nil
    loop do
      if ca.instance_variable_defined?(:@attr)
        h = ca.instance_variable_get(:@attr)
        yield(h) if h
      end
      return nil if attr_computing_view?(ca)
      if ca.is_a?(CAStack) || ca.is_a?(CAMeld)
        shared = CArray.__send__(:attrs_shared_by, ca.parents)
        yield(shared) unless shared.empty?
        return nil
      end
      parent = ca.is_a?(CArray) ? ca.__send__(:attribute_parent) : nil
      return nil if parent.nil?
      seen ||= {}.compare_by_identity
      return nil if seen.key?(parent)
      seen[ca] = true
      ca = parent
    end
  end

  def attr_check_not_frozen
    raise FrozenError.new("can't modify frozen #{self.class}: attributes", receiver: self) if frozen?
  end

  def attr_check_writable
    attr_check_not_frozen
    raise TypeError, "a mask array holds no attributes" if mask_array?
  end

  # Give `out`, a new array holding self's values in another type or
  # representation, the attributes self shows; returns `out`.  A view of
  # self that already shows them is left alone.
  def carry_attrs (out)
    return out if out.equal?(self)
    shown = attrs
    out.set_attrs(shown) unless shown.empty? || out.attrs == shown
    out
  end

  # Remove what `out`, a new array a reduction made, holds of self's
  # attributes; returns `out`.
  def drop_carried_attrs (out)
    out.remove_instance_variable(:@attr) if out.instance_variable_defined?(:@attr)
    out
  end

  # The attributes every array in `list` shows with the same value.
  def self.attrs_shared_by (list)
    first, *rest = list.map(&:attrs)
    return {} if first.nil?
    first.select { |k, v| rest.all? { |h| h.key?(k) && h[k] == v } }
  end
  private_class_method :attrs_shared_by

  def attr_computing_view? (ca)
    return ca.__op_id__ < CAMonOp::CAST_BASE if ca.is_a?(CAMonOp)
    ca.is_a?(CABinOp) || ca.is_a?(CATriOp) ||
      ca.is_a?(CAMonCmp) || ca.is_a?(CABinCmp)
  end

  def attr_normalize_key (key)
    CArray.__send__(:attr_normalize_key, key)
  end

  def attr_validate_value (v)
    CArray.__send__(:attr_validate_value, v)
  end

  def attr_coerce_value (v)
    CArray.__send__(:attr_coerce_value, v)
  end

  # The key and value rules, as class methods so that CAFrame's attributes
  # follow the same ones.
  def self.attr_normalize_key (key)
    case key
    when String then key
    when Symbol then key.to_s
    else
      raise TypeError, "attribute key must be String or Symbol (got #{key.class})"
    end
  end

  def self.attr_validate_value (v, depth = 0)
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

  def self.attr_coerce_value (v)
    case v
    when Symbol then v.to_s.freeze
    when String then v.frozen? ? v : v.dup.freeze
    when Array  then v.map { |e| attr_coerce_value(e) }.freeze
    when Hash
      v.each_with_object({}) do |(k, vv), h|
        h[(k.is_a?(Symbol) ? k.to_s : k.dup).freeze] = attr_coerce_value(vv)
      end.freeze
    else
      v
    end
  end
  private_class_method :attr_normalize_key, :attr_validate_value, :attr_coerce_value

end
