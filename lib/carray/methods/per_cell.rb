class CArray

  # @overload per_cell(*extents) { |i, j, ...| ... }
  #   Runs a per-cell computation over an index space.
  #
  #   The block's parameters are the loop indices, and each extent is the
  #   sequence one of them runs through: a `Range`, an `Integer` standing for
  #   `0...n`, or an `Enumerator::ArithmeticSequence` such as
  #   `(high - 1).step(low, -1)` for a loop that runs downward.
  #
  #     CArray.per_cell(2...n) { |i|
  #       w  = x * legendre[i-1]
  #       wy = w - legendre[i-2]
  #       legendre[i] = wy + w - wy/i
  #     }
  #
  #   Arrays and scalars are the variables the block closes over, so nothing
  #   is named twice, and the body reads as the ordinary Ruby loop it is.
  #
  #   A block that names no index takes no extents. There the arrays are
  #   written whole, in CArray's own spelling for the whole of one, and the
  #   expression is evaluated once:
  #
  #     CArray.per_cell { out[] = a[] + b[] * c[] }
  #
  #   @return [nil, Object] nil here; see below.
  #
  #   This is the interpreted form, and it is a loop like any other: for a
  #   million cells it costs what a million Ruby iterations cost. Its reason
  #   for being in the core is that `per_cell` is where an array algorithm is
  #   *written* -- a recurrence, a stencil, a reduction -- and code written
  #   that way should run wherever CArray does.
  #
  #   Installing the carray-jit gem replaces this method with one that
  #   compiles the block to C, for one to two orders of magnitude. What it
  #   compiles is a recognized subset; outside that it raises rather than
  #   falling back here, because a caller who reached for the compiler asked
  #   for speed and would not be served by getting the slow thing quietly.
  #   It returns the compiled kernel, where this returns nil.
  #
  #   Two things differ between running the block and compiling it, and both
  #   are properties of Ruby rather than of either implementation:
  #
  #   - A masked cell reads back as `UNDEF` here, so a kernel that computes
  #     with masked values raises where the compiled one propagates the mask.
  #     Ask outright -- `a[i] == UNDEF` -- and the two agree.
  #   - An `Integer` is unbounded here and 64-bit when compiled.
  def self.per_cell (*extents, &block)
    unless block
      raise ArgumentError, "per_cell needs a block"
    end

    if block.arity.zero?
      unless extents.empty?
        raise ArgumentError,
              "this block names no index, so it covers the arrays whole and " \
              "takes no extents; #{extents.size} " \
              "#{extents.size == 1 ? 'was' : 'were'} given"
      end
      block.call
      return nil
    end

    if extents.empty?
      count = block.arity
      raise ArgumentError,
            "this block names #{count == 1 ? 'an index' : "#{count} indices"}, " \
            "so it needs #{count == 1 ? 'an extent' : 'one extent each'}; " \
            "pass a Range, a count or `(high - 1).step(low, -1)`, or drop the " \
            "#{count == 1 ? 'index' : 'indices'} and write the arrays whole " \
            "as `a[]`"
    end

    sequences = extents.map { |extent| per_cell_sequence(extent) }
    per_cell_walk(sequences, [], block)
    nil
  end

  # @!visibility private
  def self.per_cell_sequence (extent)
    case extent
    when Integer then 0...extent
    when Range, Enumerator::ArithmeticSequence then extent
    else
      raise ArgumentError,
            "an extent is a Range, an Integer or an arithmetic sequence, " \
            "got #{extent.class}"
    end
  end

  # @!visibility private
  def self.per_cell_walk (sequences, indices, block)
    if sequences.size == 1
      sequences.first.each { |index| block.call(*indices, index) }
    else
      head, *rest = sequences
      head.each { |index| per_cell_walk(rest, indices + [index], block) }
    end
  end

end
