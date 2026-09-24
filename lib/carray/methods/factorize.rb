class CArray

  # @overload factorize
  #   Returns `[codes, levels]` in one pass: `levels` is a 1-D CArray of
  #   the distinct values of `self` in first-appearance order — what
  #   {#unique} answers — and `codes` is an integer CArray of `self`'s
  #   shape where `levels[codes[i]]` is `self[i]`.
  #
  #   This is the member of the value-hash discovery family ({#unique},
  #   {#value_counts}, {#mask_duplicates}, {#nunique}) that hands back
  #   the codes as storage. {#unique} answers with the vocabulary alone
  #   and {#categorize} wraps both in a {CACategorical} Face; a caller
  #   who wants the codes themselves — a position to scatter into, a key
  #   to group by, a dense renumbering of sparse keys — would otherwise
  #   pay a second pass or take the Face and its Ruby label list.
  #
  #   `codes` takes the narrowest unsigned data type the vocabulary
  #   fits, reserving that type's top value as the exclusion sentinel.
  #   A cell that joins no category — a masked cell — is both masked and
  #   holds the sentinel, exactly as {CACategorical}'s storage is, so a
  #   consumer may read either.
  #
  #   Distinctness is the family's hash-key judgement (see {#unique}):
  #   `==` for numeric with all NaN collapsed to one value and
  #   -0.0 / +0.0 the same value; `eql?` / `hash` for `CA_OBJECT` and
  #   `CA_FIXLEN`. Complex is not a lane the factorizer takes and raises
  #   {CArray::DataTypeError}.
  #
  #   There is no `sort:` here, unlike {#unique} and {#value_counts}:
  #   the codes index the levels, so reordering the vocabulary would
  #   desync them. Take {#unique}`(sort: true)` where the codes are not
  #   wanted, or sort afterwards and carry the codes through the same
  #   permutation.
  #
  #   @return [Array(CArray, CArray)] `[codes, levels]`.
  def factorize
    # One linear pass through the shared value hash (C
    # __factorize_appearance__). It writes the sentinel into the
    # excluded cells but leaves the codes unmasked; masking them is what
    # CACategorical.from_codes does on its way to the Face, and this
    # surface owes the same, since it hands the storage out bare.
    codes, levels = __factorize_appearance__
    excluded = codes.eq(CACategorical::SENTINEL[codes.data_type])
    if excluded.count(true) > 0
      codes.mask = codes.has_mask? ? (codes.mask | excluded) : excluded
    end
    [codes, levels]
  end

end
