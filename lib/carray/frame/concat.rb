# CAFrame row concatenation (memo §5, spine = addressing + gather).
#
# Two entry points, mirroring the CArray-level taxonomy:
#
#   +CAFrame.meld+         view frame,  strict same data type per column,
#                          each column is a CAMeld view over the inputs
#   +CAFrame.concatenate+  eager frame, auto-casts per column,
#                          each column is a materialised entity
#
# Both are class methods (symmetric N-ary; no frame is privileged), like
# +CArray.meld+ / +CArray.concatenate+, not instance verbs.

class CAFrame
  # Weld frames along the row axis, view-style.  Each output column is
  # +CArray.meld+ of that column across the input frames, so the result
  # is a view frame that shares storage with the inputs (chain composability
  # preserved: writes to the result flow back to whichever input frame owns
  # the target segment, and vice versa).
  #
  # Per-column +data_type+ must match across frames (CArray.meld is a view
  # constructor that refuses to auto-cast — silent promotion here would
  # hide schema drift).  For an eager, auto-casting alternative use
  # {CAFrame.concatenate}.
  #
  # Column matching is by name (output order follows the first frame);
  # every frame must carry the same column-name set.  N-D columns carry
  # their trailing dimensions along; masks are preserved.
  #
  # The index is welded too when every frame has one (their +axis_name+
  # must agree); if none do, the result has no index; a mix raises.
  # Column-set mismatch raises — a union-with-UNDEF mode is a possible
  # future opt-in, kept out here to stay explicit (memo §4.2).
  #
  #   CAFrame.meld(jan, feb, mar)      # view over three months
  #   CAFrame.meld([jan, feb, mar])    # an Array is accepted too
  def self.meld(*frames)
    frames = frames.flatten
    check_concat_inputs(frames, verb: "meld")
    first = frames.first
    names = first.variable_names
    check_column_sets(frames, names, verb: "meld")
    cols = {}
    names.each do |name|
      cols[name] = CArray.meld(frames.map { |f| f[name] }, axis: 0)
    end
    new(cols, axis_name: first.axis_name, index: meld_index(frames))
  end

  # Concatenate frames along the row axis, eagerly.  Each output column is
  # +CArray.concatenate+ of that column across the input frames, so per-column
  # data types auto-promote to a common type.  The result is a fresh, independent
  # frame — writes to it do not propagate back to the input frames.
  #
  # For a view frame that shares storage with the inputs (strict same data type
  # per column, chain composability preserved) use {CAFrame.meld}.
  #
  # Column matching, index handling, and column-set / index-mix rules
  # match {CAFrame.meld}.
  #
  #   CAFrame.concatenate(jan, feb, mar)     # eager, independent result
  #   CAFrame.concatenate([jan, feb, mar])   # an Array is accepted too
  def self.concatenate(*frames)
    frames = frames.flatten
    check_concat_inputs(frames, verb: "concatenate")
    first = frames.first
    names = first.variable_names
    check_column_sets(frames, names, verb: "concatenate")
    cols = {}
    names.each do |name|
      cols[name] = CArray.concatenate(frames.map { |f| f[name] })
    end
    new(cols, axis_name: first.axis_name, index: concatenate_index(frames))
  end

  # ---- shared validators -------------------------------------------------

  def self.check_concat_inputs(frames, verb:)
    raise ArgumentError, "#{verb} requires at least one frame" if frames.empty?
    unless frames.all? { |f| f.is_a?(CAFrame) }
      raise ArgumentError, "#{verb} expects CAFrame arguments"
    end
  end
  private_class_method :check_concat_inputs

  def self.check_column_sets(frames, names, verb:)
    expected = names.sort
    frames.each_with_index do |f, i|
      next if i.zero?
      if f.variable_names.sort != expected
        raise ArgumentError,
              "#{verb}: frame #{i} has columns #{f.variable_names.inspect}, " \
              "expected the same set as #{names.inspect}"
      end
    end
  end
  private_class_method :check_column_sets

  # ---- index helpers -----------------------------------------------------

  # Index welded via CArray.meld (view).  Every frame must agree: all
  # indexed (axis names must match) or none.
  def self.meld_index(frames)
    indexes, axis = index_pieces(frames, verb: "meld")
    return nil unless indexes
    axis   # unused; kept for symmetry
    CArray.meld(indexes, axis: 0)
  end
  private_class_method :meld_index

  # Index concatenated eagerly via CArray.concatenate.
  def self.concatenate_index(frames)
    indexes, _axis = index_pieces(frames, verb: "concatenate")
    return nil unless indexes
    CArray.concatenate(indexes)
  end
  private_class_method :concatenate_index

  def self.index_pieces(frames, verb:)
    indexes = frames.map(&:index)
    return nil if indexes.none?
    unless indexes.all?
      raise ArgumentError, "#{verb}: some frames have an index and others do not"
    end
    axis_names = frames.map(&:axis_name).uniq
    unless axis_names.size == 1
      raise ArgumentError,
            "#{verb}: indexed frames have different axis names #{axis_names.inspect}"
    end
    [indexes, axis_names.first]
  end
  private_class_method :index_pieces
end
