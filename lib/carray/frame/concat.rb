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
#
# +CAFrame.stack+ and +CAFrame#unstack+ add and take away a layer axis
# instead of rows.

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
  #
  # A frame with no rows adds no values, so it takes no part in the result
  # past these checks: its column set and index still have to agree, but the
  # data types are the other frames' (a header-only CSV reads as object
  # columns, which would otherwise refuse or demote the rest).  When every
  # frame is empty, the first one stands for them.
  # Column-set mismatch raises — a union-with-UNDEF mode is a possible
  # future opt-in, kept out here to stay explicit (memo §4.2).
  #
  #   CAFrame.meld(jan, feb, mar)      # view over three months
  #   CAFrame.meld([jan, feb, mar])    # an Array is accepted too
  def self.meld(*frames)
    frames = frames.flatten
    check_concat_inputs(frames, verb: "meld")
    first = frames.first
    names = first.column_names
    check_column_sets(frames, names, verb: "meld")
    index_pieces(frames, verb: "meld")
    frames = frames_with_rows(frames)
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
  # Column matching, index handling, column-set / index-mix rules and the
  # treatment of a frame with no rows match {CAFrame.meld}: an empty frame's
  # data types take no part in the common type.
  #
  #   CAFrame.concatenate(jan, feb, mar)     # eager, independent result
  #   CAFrame.concatenate([jan, feb, mar])   # an Array is accepted too
  def self.concatenate(*frames)
    frames = frames.flatten
    check_concat_inputs(frames, verb: "concatenate")
    first = frames.first
    names = first.column_names
    check_column_sets(frames, names, verb: "concatenate")
    index_pieces(frames, verb: "concatenate")
    frames = frames_with_rows(frames)
    cols = {}
    names.each do |name|
      cols[name] = CArray.concatenate(frames.map { |f| f[name] })
    end
    new(cols, axis_name: first.axis_name, index: concatenate_index(frames))
  end

  # Stack frames of the same shape as layers.  Each output column is
  # +CArray.stack+ of that column across the frames along +axis+, counted in
  # the column's own axes (0 is the row axis, so +axis+ starts at 1): a
  # scalar column of K frames becomes a column of shape (nrow, K).  The rows
  # stay as they are, so row verbs work on the stack unchanged and a layer is
  # a column axis -- +s["temp"][nil, k]+ is frame k's column, and
  # +s["temp"].mean(axis: 1)+ reduces across the layers.
  #
  # The result is a view frame: its columns are CAStack views over the
  # frames' columns, and writes reach them.  Call +copy+ for an independent
  # frame.  The layers carry no labels; keep them alongside (the dates of the
  # files, say) as an array of your own.
  #
  # Every frame must have the same columns, the same number of rows and the
  # same index (by value) under the same axis name, or none; the result
  # takes the first frame's.  +unstack+ is the inverse:
  #
  #   s = CAFrame.stack(jan1, jan2, jan3)    # temp:float64 -> temp:float64[3]
  #   CAFrame.stack(*s.unstack(axis: 1))       # the same frame again
  def self.stack(*frames, axis: 1)
    frames = frames.flatten
    check_concat_inputs(frames, verb: "stack")
    check_layer_axis(axis, "stack")
    first = frames.first
    names = first.column_names
    check_column_sets(frames, names, verb: "stack")
    frames.each_with_index do |f, i|
      next if i.zero?
      unless f.nrow == first.nrow
        raise ArgumentError,
              "stack: frame #{i} has #{f.nrow} rows, frame 0 has #{first.nrow}"
      end
    end
    indexes, = index_pieces(frames, verb: "stack")
    if indexes && ! indexes.all? { |x| x.to_a == indexes.first.to_a }
      raise ArgumentError, "stack: the frames' indexes differ; stacked rows have to be the same rows"
    end
    cols = {}
    names.each do |name|
      parts = frames.map { |f| f[name] }
      if axis > parts.first.ndim
        raise ArgumentError,
              "stack: axis #{axis} out of range for column #{name.inspect} " \
              "(a #{parts.first.ndim}-D column takes 1 to #{parts.first.ndim})"
      end
      cols[name] = CArray.stack(parts, axis: axis)
    end
    new(cols, axis_name: first.axis_name, index: first.index)
  end

  # Split the frame along a column axis into an Array of frames, one per
  # position on that axis -- the inverse of {CAFrame.stack}.  +axis+ counts
  # the columns' own axes (0 is the row axis, so it starts at 1).  Every
  # column must have that axis, and the same length along it: a column
  # without it has no layer to give each frame.  Each frame's columns are
  # views of this frame's, and each has this frame's index.
  #
  #   s.unstack(axis: 1)    # => [frame of layer 0, frame of layer 1, ...]
  def unstack(axis:)
    self.class.send(:check_layer_axis, axis, "unstack")
    if @columns.empty?
      raise ArgumentError, "unstack: the frame has no columns to unstack"
    end
    length = nil
    @columns.each do |name, col|
      unless axis < col.ndim
        raise ArgumentError,
              "unstack: column #{name.inspect} is #{col.ndim}-D and has no axis #{axis}"
      end
      length ||= col.shape[axis]
      unless col.shape[axis] == length
        raise ArgumentError,
              "unstack: column #{name.inspect} has #{col.shape[axis]} along axis #{axis}, " \
              "the others #{length}"
      end
    end
    (0...length).map do |k|
      cols = @columns.to_h do |name, col|
        idx = [nil] * col.ndim
        idx[axis] = k
        [name, col[*idx]]
      end
      CAFrame.new(cols, axis_name: @axis_name, index: @index)
    end
  end

  def self.check_layer_axis(axis, verb)
    unless axis.is_a?(Integer)
      raise TypeError, "#{verb}: axis must be an Integer (got #{axis.inspect})"
    end
    if axis == 0
      raise ArgumentError,
            "#{verb}: axis 0 is the row axis; rows are joined by meld or concatenate"
    end
    if axis < 0
      raise ArgumentError,
            "#{verb}: axis counts a column's axes from 1 (got #{axis}); " \
            "a negative axis would mean a different axis in columns of different ndim"
    end
  end
  private_class_method :check_layer_axis

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
      if f.column_names.sort != expected
        raise ArgumentError,
              "#{verb}: frame #{i} has columns #{f.column_names.inspect}, " \
              "expected the same set as #{names.inspect}"
      end
    end
  end
  private_class_method :check_column_sets

  # The frames that add rows, or the first frame when none does.
  def self.frames_with_rows(frames)
    with_rows = frames.reject { |f| f.nrow.zero? }
    with_rows.empty? ? [frames.first] : with_rows
  end
  private_class_method :frames_with_rows

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
