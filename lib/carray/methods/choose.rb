class CArray

  # @overload choose(choices, data_type: nil)
  #   Returns label-based per-cell selection: `self` is an integer
  #   label array, and `choices` is a list indexed by those labels.
  #
  #   Where `self == i`, the result takes `choices[i]` -- a scalar
  #   fills those cells, a CArray contributes its corresponding
  #   cells. The result has the same shape as `self`.
  #
  #   @param choices [Array<CArray, Object>] values indexed by the
  #     labels in `self`; each entry is either a same-shape CArray
  #     or a scalar fill.
  #   @param data_type [Symbol, Integer, nil] result `data_type`.
  #     When `nil` it is inferred: `CArray.result_type` of the CArray
  #     choices, or `CA_OBJECT` when every choice is a scalar.
  #   @return [CArray] new CArray with the shape of `self` holding
  #     the chosen values.
  #   @example
  #     ref = CA_INT([[0, 1, 2], [1, 2, 0], [2, 0, 1]])
  #     a = CArray.int(3, 3).seq(1)
  #     b = CArray.int(3, 3).seq(11)
  #     c = CArray.int(3, 3).seq(21)
  #     ref.choose([a, b, c])       # per-cell pick from a / b / c
  #     ref.choose(["a", "b", "c"]) # recode labels to values
  def choose (choices, data_type: nil)
    unless data_type
      ca = choices.select { |v| v.is_a?(CArray) }
      data_type = ca.empty? ? CA_OBJECT : CArray.result_type(*ca)
    end
    out = template(data_type)
    choices.each_with_index do |v, i|
      s = self.eq(i)
      out[s] = v.is_a?(CArray) ? v[s] : v
    end
    out
  end

end
