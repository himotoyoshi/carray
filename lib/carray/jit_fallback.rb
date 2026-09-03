# ----------------------------------------------------------------------------
#
#  carray/jit_fallback.rb
#
#  The interpreted forms of CArray.per_cell and CArray.per_element, and the
#  stubs the carray-jit gem replaces.
#
#  These two methods are where an array algorithm is written -- a recurrence,
#  a stencil, a reduction, an element-wise expression -- and the two halves of
#  each live in different places on purpose:
#
#    - this file runs the block as ordinary Ruby, so that a program written
#      against per_cell or per_element runs wherever CArray does;
#    - `require "carray/jit"` overwrites both methods with ones that parse the
#      block, translate it to C, compile it and call the result, one to two
#      orders of magnitude faster.
#
#  So the file is named for the relation rather than for the methods: what is
#  here is what runs when the compiler is not installed.  Nothing in the core
#  calls either method, and the file is autoloaded, so a program that never
#  writes a kernel pays nothing for it.
#
#  The two implementations have to agree on where the line between the methods
#  falls, and they do: a block that names indices is per_cell's, a block that
#  names none is per_element's, and each turns the other's block away rather
#  than quietly doing something with it.  A block accepted here and a block
#  accepted there are the same block.
#
#  What a block may contain is written out in the documentation below.  Ruby
#  will of course run more than that -- it is running the block, not reading
#  it -- but a block that stays inside the subset is one that keeps working
#  when the compiler is installed, which is the point of writing it against
#  these methods at all.
#
#  Both walk the extents they were handed, in the order they were handed.
#  That is why the direction of a loop is written at the call site --
#  `(high - 1).step(low, -1)` -- rather than worked out from the body: this
#  file has no analysis to work it out with, and would otherwise run a
#  downward kernel the wrong way round without saying so.
#
#  "cell" is the user's guide's word for an individual position in an array
#  ("masked cells", "the per-cell block", "evaluates it per-cell"); "element"
#  is its word for counting them and for element-wise operations.  per_cell
#  computes one position at a time and may read its neighbours, so it takes
#  the former; per_element reaches no neighbour, so it takes the latter.
#
#  Autoloaded from carray/autoload_carray.rb.
#
# ----------------------------------------------------------------------------

class CArray

  # @overload per_cell(*extents) { |i, j, ...| ... }
  #   Runs a per-cell computation over an index space.
  #
  #   The block's parameters are the loop indices, and each extent is the
  #   sequence one of them runs through: a `Range`, an `Integer` standing for
  #   `0...n`, or an `Enumerator::ArithmeticSequence` such as
  #   `(high - 1).step(low, -1)` for a loop that runs downward.  There is one
  #   extent per index, so a whole array is `CArray.per_cell(*array.dim)`.
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
  #   Naming an index is what lets a kernel reach a neighbouring cell, and
  #   reaching a neighbouring cell is what makes the extent and its direction
  #   matter.  A computation that reaches no neighbour names no index and
  #   needs no extent, and is written with {CArray.per_element} instead; a
  #   block that names none is turned away here rather than run element-wise.
  #
  #   `reassociate:` is a licence rather than an instruction -- it says a
  #   reduction's accumulator *may* be taken out of order -- so it is accepted
  #   and has nothing to do here, where the fold is a Ruby loop and runs in
  #   the order it is written.  It is taken so that a program that asks the
  #   compiler for one order or the other still runs without it.
  #
  #   @return [nil, Object] nil here; see below.
  #
  #   === What a block may contain
  #
  #   Ruby runs whatever is in the block, so this list constrains nothing
  #   here.  It is the subset carray-jit compiles, and a block that stays
  #   inside it is one that gets faster rather than raising when the compiler
  #   is installed:
  #
  #   - reads and writes of the arrays and scalars the block closes over,
  #     subscripted by an index plus a constant offset (`a[i-1]`, `a[i+1,j]`),
  #     by a pinned axis (`a[i, 0]`), or by a value the kernel works out --
  #     a gather or a scatter, `table[index[i]]`, checked at the access
  #   - block-locals, assigned before they are read
  #   - arithmetic, comparison and boolean operators, and the literals
  #   - `Math.sqrt(x)` and the rest of the sixteen names that are 1:1 with
  #     math.h, and the same sixteen postfix -- `x.sqrt` -- under
  #     `using CArray::CoreExtensions`.  Postfix without the `using` compiles
  #     but raises `NoMethodError` here, since here the block is actually run
  #   - `if` / `else` in statement position
  #   - `a[i] == UNDEF` to ask whether a cell is missing, and
  #     `a[i] = UNDEF` to mark one
  #   - an inner loop whose index addresses arrays and writes nothing -- which
  #     is what makes a reduction, a dot product and a matrix multiply
  #     expressible as loops.  It is written in the three spellings an extent
  #     is written in: `(0...n).each { |j| ... }`, `n.times { |j| ... }` and
  #     `(n..0).step(-2) { |j| ... }` (or `n.step(0, -2)`), the step written
  #     out rather than computed
  #   - `while` and `loop` are not in it, having no trip count to compile
  #     from; a bounded loop with a `break` in it is how one with a condition
  #     is written
  #   - `f.call(x)` for a C function bound with `CArray::JIT.cfunc`
  #
  #   === What the compiled form does differently
  #
  #   This is the interpreted form, and it is a loop like any other: for a
  #   million cells it costs what a million Ruby iterations cost.  Its reason
  #   for being in the core is that `per_cell` is where an array algorithm is
  #   *written*, and code written that way should run wherever CArray does.
  #
  #   Installing the carray-jit gem replaces this method with one that
  #   compiles the block to C.  What it compiles is the subset above; outside
  #   it the compiled form raises rather than falling back here, because a
  #   caller who reached for the compiler asked for speed and would not be
  #   served by getting the slow thing quietly.  It returns the compiled
  #   kernel, where this returns nil.
  #
  #   Every operation means what Ruby means by it either way -- integer
  #   division floors, `%` is not `fmod`, a named function is not swapped for
  #   a cheaper one.  What differs is three things:
  #
  #   - A masked cell reads back as `UNDEF` here, so a kernel that computes
  #     with masked values raises where the compiled one propagates the mask.
  #     Ask outright -- `a[i] == UNDEF` -- and the two agree.
  #   - An `Integer` is unbounded here and 64-bit when compiled.
  #   - A reduction folds serially here, and the compiled one splits the
  #     accumulator into partial sums: a different order, and usually the
  #     more accurate answer.  `per_cell(..., reassociate: false)` asks the
  #     compiled form for this one's order, which is what makes the two
  #     comparable to the last bit.
  def self.per_cell (*extents, reassociate: nil, &block)
    unless block
      raise ArgumentError, "per_cell needs a block"
    end

    if block.arity.zero?
      raise ArgumentError,
            "per_cell's block names the cells it is on, so it takes the loop " \
            "indices as its parameters; a block that names none is " \
            "element-wise and belongs to per_element"
    end

    count = block.arity.abs
    if extents.empty?
      raise ArgumentError,
            "this block names #{count == 1 ? 'an index' : "#{count} indices"}, " \
            "so it needs #{count == 1 ? 'an extent' : 'one extent each'}; " \
            "pass a Range, a count or `(high - 1).step(low, -1)`, or drop the " \
            "#{count == 1 ? 'index' : 'indices'} and write the arrays whole " \
            "with per_element"
    end

    unless extents.size == count
      raise ArgumentError,
            "the block names #{count} #{count == 1 ? 'index' : 'indices'}, " \
            "and #{extents.size} " \
            "#{extents.size == 1 ? 'extent was' : 'extents were'} given"
    end

    sequences = extents.map { |extent| per_cell_sequence(extent) }
    per_cell_walk(sequences, [], block)
    nil
  end

  # @overload per_element { ... }
  #   Runs an element-wise expression, written over whole arrays.
  #
  #   The arrays are the variables the block closes over, and the expression
  #   is written the way CArray already writes it.  The left-hand side keeps
  #   its brackets because Ruby needs them: `out = ...` would bind a local.
  #
  #     CArray.per_element { out[] = a + b * c }
  #
  #   @return [nil, Object] nil here; see below.
  #
  # @overload per_element(*arrays) { |x, y, ...| ... }
  #   Runs an element-wise expression, written over one cell.
  #
  #   One parameter per array, bound by position at the call site, each
  #   holding the cell's value rather than a position -- so nothing here can
  #   reach a neighbour, which is the same thing the whole-array spelling
  #   cannot do.  The block's value is what every cell of the result gets, so
  #   there is no output array to name and the result is returned.
  #
  #     sums = CArray.per_element(a, b) { |x, y| x + y }
  #
  #   The arrays are broadcast against one another, as CArray broadcasts them
  #   anywhere else.
  #
  #   @return [CArray] the result.
  #
  # @!method self.per_element
  #   Element-wise means what it means everywhere else in CArray: every cell
  #   is computed from the cells beside it in the other arrays, none reaches a
  #   neighbour, and the shapes are broadcast.  So there is no index to name
  #   and no extent to give.
  #
  #   It is {CArray.per_cell}'s sibling and not its special case, and the
  #   names are the point: "cell" is a position, which is what a block names
  #   when it can reach the positions around it, and "element" is what CArray
  #   calls the same work done at every cell at once.  A block that names an
  #   index is turned away here, and a block that names none is turned away
  #   there.
  #
  #   What a block may contain is {CArray.per_cell}'s list, less the parts
  #   that need an index: no offset subscript, no inner loop.
  #
  #   Running the expression is what this form costs here -- one pass per
  #   operation, with an intermediate array between them, which is what the
  #   same expression written outside a block costs.  Installing carray-jit
  #   replaces the method with one that compiles the whole expression into a
  #   single pass over the cells with no intermediates at all, and returns the
  #   compiled kernel where the whole-array spelling here returns nil.
  #
  #   One difference is this form's own.  The result of the element spelling
  #   is typed from the values the block returned, since there is no
  #   expression analysis here to type it in advance; the compiled form types
  #   it from the expression.  The two agree except where the values do not
  #   fill their type -- an expression in doubles whose every cell comes out
  #   whole is an integer array here.
  def self.per_element (*arrays, &block)
    unless block
      raise ArgumentError, "per_element needs a block"
    end

    if block.arity.zero?
      unless arrays.empty?
        raise ArgumentError,
              "this block names the arrays itself, so it takes none at the " \
              "call site; #{arrays.size} " \
              "#{arrays.size == 1 ? 'was' : 'were'} given"
      end
      block.call
      return nil
    end

    if arrays.empty?
      raise ArgumentError,
            "this block names its elements, so it takes one array per " \
            "parameter at the call site, as in " \
            "`per_element(a, b) { |x, y| x + y }`; none were given"
    end

    parameters = block.parameters.map(&:last)
    unless parameters.size == arrays.size
      raise ArgumentError,
            "the block names #{parameters.size} " \
            "#{parameters.size == 1 ? 'element' : 'elements'}, and " \
            "#{arrays.size} #{arrays.size == 1 ? 'array was' : 'arrays were'} " \
            "given"
    end

    parameters.zip(arrays).each do |name, array|
      next if array.is_a?(CArray)
      raise ArgumentError,
            "`#{name}` stands for the cells of an array, and a " \
            "#{array.class} was given"
    end

    aligned = arrays.size == 1 ? arrays : CArray.broadcast(*arrays)
    values  = (0...aligned.first.elements).map { |addr|
      block.call(*aligned.map { |array| array[addr] })
    }

    result = CArray.new(per_element_result_type(values), aligned.first.dim)
    result[] = values unless values.empty?
    result
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

  # The result of the element spelling is typed from what the block returned,
  # since nothing here reads the expression.  The order is the widening one,
  # so a mixture takes the type that holds all of it.
  #
  # @!visibility private
  def self.per_element_result_type (values)
    case
    when values.empty?                              then CA_OBJECT
    when values.all? { |v| v == true or v == false } then CA_BOOLEAN
    when values.all? { |v| v.is_a?(Integer) }        then CA_INT64
    when values.all? { |v| v.is_a?(Integer) or v.is_a?(Float) }
      CA_DOUBLE
    when values.all? { |v| v.is_a?(Numeric) }        then CA_CMPLX128
    else CA_OBJECT
    end
  end

end
