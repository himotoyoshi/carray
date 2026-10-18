class CArray

  # @overload choose(choices, data_type: nil)
  #   Returns label-based per-cell selection: `self` is an integer
  #   label array, and `choices` is a list indexed by those labels.
  #
  #   Where `self == i`, the result takes `choices[i]` -- a scalar
  #   fills those cells, a CArray contributes its corresponding
  #   cells. The result has the same shape as `self`. Where a label
  #   is masked, the result is masked.
  #
  #   @param choices [Array<CArray, Object>] values indexed by the
  #     labels in `self`; each entry is either a same-shape CArray
  #     or a scalar fill.
  #   @param data_type [Symbol, Integer, nil] result `data_type`.
  #     When `nil` it is inferred: `CArray.result_type` of the CArray
  #     choices, or `CA_OBJECT` when every choice is a scalar.
  #   @return [CArray] new CArray with the shape of `self` holding
  #     the chosen values; a {CAString} when every choice is a String
  #     or a {CAString} and `data_type` is not given.
  #   @raise [IndexError] if a label that is not masked is negative or
  #     not less than the number of choices.
  #   @example
  #     ref = CA_INT([[0, 1, 2], [1, 2, 0], [2, 0, 1]])
  #     a = CArray.int(3, 3).seq(1)
  #     b = CArray.int(3, 3).seq(11)
  #     c = CArray.int(3, 3).seq(21)
  #     ref.choose([a, b, c])       # per-cell pick from a / b / c
  #     ref.choose(["a", "b", "c"]) # recode labels to values
  def choose (choices, data_type: nil)
    outside = (self.lt(0) | self.ge(choices.size)).where
    if outside.elements > 0
      addr = outside[0]
      raise IndexError,
            "choose: label #{self[addr]} at address #{addr} is out of range " \
            "for #{choices.size} choices"
    end
    text = !data_type && CArray.send(:selection_text?, choices)
    unless data_type
      ca = choices.select { |v| v.is_a?(CArray) }
      data_type = ca.empty? ? CA_OBJECT : CArray.result_type(*ca)
    end
    out = template(data_type)
    choices.each_with_index do |v, i|
      s = self.eq(i)
      out[s] = v.is_a?(CArray) ? v[s] : v
    end
    out[self.is_masked] = UNDEF if has_mask?
    text ? CAString.wrap(out) : out
  end

end
