# frozen_string_literal: true

class CAFrame

  # The one rule of a frame-wide verb over the frame's columns -- the group
  # reductions and transforms, the windowed reductions, and the frame's own
  # reductions and running values -- kept in one place: which columns a verb
  # computes, and what a named column without the operation does.
  #
  # - given names, those columns, as the CArray (one) or the Array of them
  #   (several); a named column whose type has no such operation is refused
  #   with CArray::DataTypeError, as the core refuses it, since it was asked
  #   for;
  # - given none, every column whose type has it, the key columns left out,
  #   as a Hash of name to result.
  #
  # The caller decides the shape of the answer from these: a verb whose
  # answers lie on the frame's rows (a transform, a window at the rows,
  # +keep_rows:+) hands named columns back as they are, as +df[...]+ returns
  # columns, while a verb with one row per group, per point or for the
  # whole frame makes a frame of them, labelled by its rows.
  #
  # Whether a type has the operation is asked of the core on two copies of
  # the column's first row (two blank cells of its kind when it has no
  # rows), so the answer is about the type and not the data: a refusal
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
          cols[name] = yield(col, name)
        end
        return cols
      end
      results = names.map do |name|
        key = @frame.__send__(:column_key, name, verb)
        col = @frame[key]
        unless column_has?(col, verb, args, keywords)
          raise CArray::DataTypeError,
                "#{verb}: column #{name.inspect} " \
                "(#{CArray::Inspector.type_label(col)}) has no #{verb}"
        end
        yield(col, key)
      end
      results.size == 1 ? results.first : results
    end

    # count with no value counts the present cells, which every type has;
    # a Face's own count takes a value (CACategorical#count(label)), so the
    # type is asked about count_not_masked instead.
    def column_has? (col, verb, args, keywords)
      verb = :count_not_masked if verb == :count && args.empty?
      # Two cells: one cell does not reach what combines two (a String's
      # median interpolates, its sum adds), and an empty column answers
      # with the identity without asking the type at all.
      tail = [nil] * (col.ndim - 1)
      probe = if col.shape[0] > 0
                col[CA_INT64([0, 0]), *tail]
              else
                col.resize(2, *col.shape[1..])
              end
      keywords = keywords.merge(axis: 0) if col.ndim > 1
      probe.public_send(verb, *args, **keywords)
      true
    rescue CArray::DataTypeError, TypeError, ArgumentError
      false
    end
  end
end
