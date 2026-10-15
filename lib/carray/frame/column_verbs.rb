# frozen_string_literal: true

class CAFrame

  # The one rule of a frame-wide verb over the frame's columns -- the group
  # reductions and transforms, the windowed reductions -- kept in one place
  # so that every verb answers in the same shape:
  #
  # - given names, the CArray (one) or the Array of them (several), as
  #   +df[...]+ returns columns; a named column whose type has no such
  #   operation is refused with CArray::DataTypeError, as the core refuses
  #   it, since it was asked for;
  # - given none, every column whose type has it, the key columns left out,
  #   as a Hash of name to result that the caller makes a frame of.
  #
  # Whether a type has the operation is asked of the core on the column's
  # first row, so the answer is about the type and not the data: a refusal
  # there means the operation does not apply, while an error in the verb
  # itself is left to raise. An N-D column (each row a profile) is asked,
  # and computed, along the rows.
  module ColumnVerbs

    private

    def over_named_columns (verb, names, key_names, args = [], keywords = {})
      if names.empty?
        cols = {}
        @frame.column_names.each do |name|
          next if key_names.include?(name)
          col = @frame[name]
          next unless column_has?(col, verb, args, keywords)
          cols[name] = yield(col)
        end
        return cols
      end
      results = names.map do |name|
        col = @frame[@frame.__send__(:column_key, name, verb)]
        unless column_has?(col, verb, args, keywords)
          raise CArray::DataTypeError,
                "#{verb}: column #{name.inspect} " \
                "(#{CArray::Inspector.type_label(col)}) has no #{verb}"
        end
        yield(col)
      end
      results.size == 1 ? results.first : results
    end

    def column_has? (col, verb, args, keywords)
      probe = col.elements > 0 ? col[0..0, *[nil] * (col.ndim - 1)] : col
      keywords = keywords.merge(axis: 0) if col.ndim > 1
      probe.public_send(verb, *args, **keywords)
      true
    rescue CArray::DataTypeError, TypeError, ArgumentError
      false
    end
  end
end
