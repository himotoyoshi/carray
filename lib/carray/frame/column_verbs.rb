# frozen_string_literal: true

class CAFrame

  # The one rule of a frame-wide verb over the frame's columns -- the group
  # reductions and transforms, the windowed reductions, and the frame's own
  # reductions and running values -- kept in one place: which columns a verb
  # computes, and what a named column without the operation does.
  #
  # - given names, those columns, as the CArray (one) or a Hash of name to
  #   result (several); a named column whose type has no such operation is
  #   refused with CArray::DataTypeError, as the core refuses it, since it
  #   was asked for;
  # - given none, every column whose type has it, the key columns left out,
  #   as a Hash of name to result.
  #
  # The caller decides the shape of the answer from these: a verb whose
  # answers lie on the frame's rows (a transform, a window at the rows,
  # +keep_rows:+) hands one named column back as it is, as +df[name]+
  # returns it, and several as a frame on the frame's rows, while a verb
  # with one row per group, per point or for the whole frame makes a frame
  # of them, labelled by its rows.
  #
  # Whether a type has the operation is asked of the core on two copies of
  # the column's first row (two blank cells of its kind when it has no
  # rows), so the answer is about the type and not the data: a refusal
  # there means the operation does not apply, while an error in the verb
  # itself is left to raise. An object column is the exception: its type
  # says nothing of what it holds, so one with no present value, or whose
  # cells do not answer, is left out of a verb run over every column. An N-D column (each row a profile) is
  # asked, and computed, along the rows.
  module ColumnVerbs

    private

    # The row of each cell, UNDEF where the cell is masked: a first or last
    # taken of it picks the row, and the row picks the value of a Face that
    # cannot hold new values, as lag picks it.
    def present_rows (col)
      rows = CArray.int64(col.elements).seq
      rows[col.is_masked] = UNDEF if col.has_mask?
      rows
    end

    # A verb whose answers lie on the frame's rows, with no column to compute:
    # a frame of no column would also have no row.
    def refuse_no_column_on_rows (verb, out, nrow)
      return unless out.is_a?(Hash) && out.empty? && nrow > 0
      raise ArgumentError, "#{verb}: no column to compute (every column is a key or has no #{verb})"
    end

    def refuse_unknown_fill_columns (verb, fills)
      return unless fills.is_a?(Hash)
      unknown = fills.keys - @frame.column_names
      return if unknown.empty?
      raise ArgumentError, "#{verb}: fill_value names no column #{unknown.map(&:inspect).join(', ')}"
    end

    def over_named_columns (verb, names, key_names, args = [], keywords = {})
      if names.empty?
        cols = {}
        @frame.column_names.each do |name|
          next if key_names.include?(name)
          col = @frame[name]
          next if valueless_object_column?(col, verb, args)
          next unless column_has?(col, verb, args, keywords)
          cols[name] = answer_of_every_column(col, name) { |c, n| yield(c, n) }
          cols.delete(name) if cols[name].equal?(NO_ANSWER)
        end
        return cols
      end
      # A column named twice would be one result column twice over.
      keys = CAFrame.__send__(:refuse_repeated_names,
                              names.map { |name| @frame.__send__(:column_key, name, verb) }, verb)
      results = keys.map do |key|
        name = key
        col = @frame.__send__(:named_column, key, verb)
        unless column_has?(col, verb, args, keywords)
          raise CArray::DataTypeError,
                "#{verb}: column #{name.inspect} " \
                "(#{CArray::Inspector.type_label(col)}) has no #{verb}"
        end
        yield(col, key)
      end
      results.size == 1 ? results.first : keys.zip(results).to_h
    end

    NO_ANSWER = Object.new.freeze
    private_constant :NO_ANSWER

    # What an object column holds shows only in the verb itself: one whose
    # cells do not answer is left out of a verb run over every column, as a
    # column of a type without the operation is, wherever those cells sit.
    # refuse_wrong_reduction_arguments has refused what no column would take.
    def answer_of_every_column (col, name)
      return yield(col, name) if col.face? || col.data_type != CA_OBJECT
      begin
        yield(col, name)
      rescue TypeError, ArgumentError, NoMethodError, RangeError
        NO_ANSWER
      end
    end

    # The arguments of a reduction, asked of the core on a number before any
    # column, so a wrong one is not taken for a column that does not answer.
    # fill_value: is of each column's type, and stays out of this.
    def refuse_wrong_reduction_arguments (verb, args, keywords)
      return if verb == :count
      CArray.float64(1).public_send(verb, *args, **keywords.reject { |k, _| k == :fill_value })
    rescue CArray::DataTypeError, NoMethodError
      nil
    end

    # An object column with no present cell says nothing of what it holds,
    # so a verb run over every column leaves it out, as select leaves it out
    # of every kind; counting the present cells applies to any column. A
    # Face kept in object cells (a CAString) with rows, every one masked, is
    # the same: the type would be asked of masked cells only, which answer
    # with the identity whatever the type. With no rows the type is asked of
    # blank cells of its kind.
    def valueless_object_column? (col, verb, args)
      return false if col.data_type != CA_OBJECT
      return false if col.face? && col.elements == 0
      return false if %i[count_not_masked count_masked].include?(verb)
      return false if verb == :count && args.empty?
      col.count_not_masked == 0
    end

    # count with no value counts the present cells, which every type has;
    # a Face's own count takes a value (CACategorical#count(label)), so the
    # type is asked about count_not_masked instead.
    def column_has? (col, verb, args, keywords)
      verb = :count_not_masked if verb == :count && args.empty?
      # Two cells: one cell does not reach what combines two (a String's
      # median interpolates, its sum adds), and an empty column answers
      # with the identity without asking the type at all. The row is the
      # first that holds a present cell, so a masked first row does not
      # answer with the identity for a column whose values have none.
      tail = [nil] * (col.ndim - 1)
      row = 0
      if col.has_mask? && col.elements > 0
        present = col.is_not_masked.flatten.where
        row = present[0] / (col.elements / col.shape[0]) if present.elements > 0
      end
      probe = if col.shape[0] > 0
                col[CA_INT64([row, row]), *tail]
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
