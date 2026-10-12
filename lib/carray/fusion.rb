# ---------------------------------------------------------------------------
#  Turning a lazy expression into a plan a compiler can read.
#
#  A lazy view is already a typed, closed expression graph, and the kernels
#  already carry the C that computes each operation (CArray.__kernel_body__,
#  with CArray.__kernel_helpers__ for the functions a body calls beyond the
#  C standard library).
#  What is missing between them is the reading: which operation each node is,
#  what its mask does, and where the leaves are.  That is what a plan holds.
#
#  Nothing here compiles anything.  A plan is plain data, and CArray itself
#  never needs one -- it can always walk the view.  What a plan is for is a
#  second evaluator: hand it to one, and the answer must be the same.
# ---------------------------------------------------------------------------

class CArray

  module Fusion

    # One value per node, in evaluation order; the last is the result.
    #
    #   Op      an operation, reading the nodes named in `args`
    #   Leaf    an array, the `index`-th of plan.leaves, read at the cell
    #           being computed
    #   Shifted the same, read `offset` cells away along each axis -- what
    #           CArray#shift makes.  A cell that falls outside the array is
    #           `fill` where `bounds` says :fill and masked where it says
    #           :mask.  `masked` says whether the array itself has a mask.
    #   Const   a scalar written into the expression
    #
    # A Shifted node reads cells other than the one being computed, so an
    # evaluator that writes its output over one of the plan's leaves must
    # not compute one that is read shifted: a cell it reads may already
    # have been written.
    #
    # A comparison's body is the one for the data type it compares; what it
    # answers is boolean, which is the node's data_type.
    # An Op's fields:
    #
    #   kind       :monop, :binop, :triop, :moncmp or :bincmp
    #   name       the operation as the kernels name it (:add, :sqrt, :ipow)
    #   args       indices of the nodes it reads, in operand order
    #   body       its C, from CArray.__kernel_body__: `#1`, `#2`, ... are
    #              the operands and the next number is the result; `<type>`
    #              is CArray's name for the type (float64_t)
    #   mask       how the result is masked: :pass (as its one operand),
    #              :union (where any operand is), :kleene_or / :kleene_and
    #              (boolean | and &, unmasked where the known side settles it),
    #              :select (where the first operand is, else where the
    #              operand it chooses is: the second where it is true, the
    #              third where it is false)
    #   trapping   true where a masked cell must not be computed at all
    #
    # What a reader may rely on: the node classes, the kinds, the names, the
    # mask rules and the fields above keep the meaning they have here.  New
    # ones are added -- a node class, a kind, an operation, a mask rule --
    # and an evaluator that meets one it does not know declines the plan
    # (returns false).  It does not raise: raising takes it out of service
    # for the rest of the process.  Declining is what lets CArray add to
    # the plan without a new evaluator being released at the same time.
    Op      = Struct.new(:kind, :name, :data_type, :args, :body, :mask, :trapping)
    Leaf    = Struct.new(:index, :data_type, :masked)
    Shifted = Struct.new(:index, :data_type, :masked, :offset, :bounds, :fill)
    Const   = Struct.new(:value, :data_type)

    Plan  = Struct.new(:nodes, :leaves, :data_type, :dim, :masked, :signature)

    LAZY_CLASSES = [CAMonOp, CABinOp, CATriOp, CAMonCmp, CABinCmp, CALazyMarker]

    # A lazy node names its operation by an id and the kernels name it by a
    # symbol.  These are the same operations, spelled the way each side
    # spells them; the rest are spelled alike.
    BINOP_NAMES = {
      :+  => :add,        :-  => :sub,        :*  => :mul,
      :/  => :div,        :** => :power,      :%  => :mod,
      :&  => :bit_and_i,  :|  => :bit_or_i,   :^  => :bit_xor_i,
      :<< => :bit_lshift, :>> => :bit_rshift,
    }.freeze
    TRIOP_NAMES = { :__clip_ki__ => :clip }.freeze

    MONOP_BY_ID = CArray::LAZY_MONOP_OP_IDS.invert.freeze
    # A Float or Complex array to an Integer power is its own node, ipow,
    # which `**` makes and no table above names.
    BINOP_BY_ID = CArray::LAZY_BINOP_OP_IDS.invert
                    .merge(CABinOp::OP_IPOWER => :ipow).freeze
    # The lazy then_else is its own triop, select, which no method names.
    TRIOP_BY_ID = CArray::LAZY_TRIOP_OP_IDS.invert
                    .merge(CATriOp::OP_SELECT => :select).freeze
    MONCMP_BY_ID = CArray::LAZY_MONCMP_OP_IDS.invert.freeze
    # The table holds both spellings of each comparison (`lt` and `<`); the
    # kernels are named by the word.
    BINCMP_BY_ID = CArray::LAZY_BINCMP_OP_IDS
                     .select { |name, _| name.to_s.match?(/\A[a-z]/) }.invert.freeze

    class Refused < StandardError; end

    # ---- who computes a plan --------------------------------------------
    #
    # CArray can always walk the expression, so nothing has to be registered
    # and nothing changes when nothing is.  What a registered evaluator adds
    # is a second way to arrive at the same answer; it is asked, and it may
    # decline.  The dispatch point stays on CArray's side, which is what
    # keeps the threshold below a decision about CArray's own walk rather
    # than one that moves with whatever is installed.
    #
    # The evaluator itself is held by CArray (see carray/lazy.rb), so that
    # materialising an expression need not reach for this file at all until
    # something has been registered.

    # Reaching a compiled kernel costs about the same whatever the array's
    # size, and what it buys is the passes the walk would make.  Below this
    # the walk is the faster answer.  The crossing moves with how wide the
    # expression is -- measured, thirty thousand cells at one operation, six
    # thousand at six -- and this brackets those: a one-operation expression
    # loses a couple of microseconds here, a six-operation one wins ten.
    THRESHOLD = 10_000

    # Returns the array, or nil where nothing computed it.
    def self.evaluate (view)
      plan = worth_asking(view) or return nil
      out = CArray.__alloc_uninit__(view.data_type, view.dim)
      ask(plan, out) ? out : nil
    end

    # Fills an array the caller already has.  Called from the store as well,
    # where making one and copying it over would be most of the work.
    # Returns true when something computed it.
    def self.evaluate_into (view, out)
      plan = worth_asking(view) or return false
      ask(plan, out)
    end

    # The plan to hand over, or nil.  A marker over an array, or anything
    # else with nothing to compute, is not worth handing over.
    def self.worth_asking (view)
      return nil unless askable?(view)
      plan = plan(view) or return nil
      plan.nodes.any? { |n| n.is_a?(Op) } ? plan : nil
    rescue StandardError => error
      retire(error)
      nil
    end

    def self.ask (plan, out)
      evaluator = CArray.expression_evaluator or return false
      return false if overlaps?(plan, out)
      # The walk leaves the destination masked where the expression is, so
      # a destination that arrives masked loses its mask to an expression
      # that has none.
      if plan.masked
        out.mask = 0 unless out.has_mask?
      elsif out.has_mask?
        out.mask = 0
      end
      evaluator.call(plan, out) ? true : false
    rescue StandardError => error
      retire(error)
      false
    end

    # Whether the destination shares storage with a leaf it would read.  An
    # evaluator computes cell by cell, so writing a cell another leaf reads
    # later -- `z[] = y + y` with z and y overlapping slices of one array --
    # reads what it has just written.  The walk reads every operand before
    # it writes.  The destination itself as a leaf is fine as long as it is
    # read at the cell being written, not shifted.
    def self.overlaps? (plan, out)
      mine = storages(out)
      shifted = plan.nodes.grep(Shifted).map(&:index)
      plan.leaves.each_with_index.any? do |leaf, index|
        if leaf.equal?(out)
          shifted.include?(index)
        else
          storages(leaf).any? { |r| mine.any? { |m| m.equal?(r) } }
        end
      end
    end

    # The arrays that hold an array's cells: its root, or each parent's
    # where a view stands over several.
    def self.storages (array, found = [])
      root = array.root_array
      if ! root.entity? && root.respond_to?(:parents)
        root.parents.each { |parent| storages(parent, found) }
      else
        found << root
      end
      found
    end

    def self.retire (error)
      CArray.expression_evaluator = nil
      warn "CArray: the registered expression evaluator raised " \
           "(#{error.class}: #{error.message}); expressions will be walked " \
           "from here on"
    end

    def self.askable? (view)
      ! CArray.expression_evaluator.nil? && view.elements >= THRESHOLD
    end

    # Returns a Plan, or nil where the expression holds something a plan
    # cannot describe.  Refusing is ordinary: the caller walks instead.
    def self.plan (view)
      build(view)
    rescue Refused
      nil
    end

    def self.build (view)
      raise Refused, "not a lazy expression" unless lazy?(view)
      w = Walk.new
      w.visit(view)
      masked = w.leaves.any? { |a| a.has_mask? } ||
               w.nodes.any? { |n| n.is_a?(Shifted) && n.bounds.include?(:mask) }
      Plan.new(w.nodes, w.leaves, view.data_type, view.dim, masked, w.signature)
    end

    def self.lazy? (x)
      LAZY_CLASSES.any? { |k| x.is_a?(k) }
    end

    # ---- the walk -------------------------------------------------------

    class Walk
      attr_reader :nodes, :leaves, :signature

      def initialize
        @nodes = []
        @leaves = []
        @leaf_index = {}
        @seen = {}
        @signature = +""
      end

      def visit (n)
        @seen[n.object_id] ||= build(n)
      end

      private

      def build (n)
        case n
        when CALazyMarker then visit(n.parent)
        when CAMonOp      then unary(n)
        when CABinOp      then binary(n)
        when CATriOp      then ternary(n)
        when CAMonCmp     then unary_comparison(n)
        when CABinCmp     then binary_comparison(n)
        when CAShift      then shifted(n)
        when CScalar      then constant(n)
        when CArray       then leaf(n)
        else raise Refused, "#{n.class} in an expression"
        end
      end

      def unary (n)
        return conversion(n) if n.__op_id__ >= CAMonOp::CAST_BASE
        name = spell(MONOP_BY_ID, n.__op_id__, {})
        args = [visit(n.parent)]
        # A view over one array is masked exactly where that array is
        # (ca_obj_monop.c).
        op(:monop, name, n.data_type, args, :pass, n.__trapping__)
      end

      # A cast node is named by the type it converts to, cast_<data_type>,
      # and its body is keyed by the type it converts from.
      def conversion (n)
        from = n.parent.data_type
        name = :"cast_#{n.data_type}"
        body = CArray.__kernel_body__(:monop, name, from) or
          raise Refused, "monop #{name} has no body at #{from}"
        args = [visit(n.parent)]
        note("c", name, from, args.join(","))
        push Op.new(:monop, name, n.data_type, args, body, :pass, n.__trapping__)
      end

      def binary (n)
        name = spell(BINOP_BY_ID, n.__op_id__, BINOP_NAMES)
        args = [visit(n.parent), visit(n.__binop_right__)]
        # Boolean `&` and `|` are three-valued: a masked cell whose known
        # side settles the answer comes back unmasked (ca_obj_binop.c).
        rule = if n.data_type == :boolean && name == :bit_or_i  then :kleene_or
               elsif n.data_type == :boolean && name == :bit_and_i then :kleene_and
               else :union
               end
        op(:binop, name, n.data_type, args, rule, n.__trapping__)
      end

      def ternary (n)
        name = spell(TRIOP_BY_ID, n.__op_id__, TRIOP_NAMES)
        args = [visit(n.parent), visit(n.__triop_op2__), visit(n.__triop_op3__)]
        # select is masked where its condition is, or where the branch the
        # condition chooses is (ca_obj_triop.c).
        rule = name == :select ? :select : :union
        op(:triop, name, n.data_type, args, rule, n.__trapping__)
      end

      # A comparison is masked where its operands are (ca_obj_moncmp.c,
      # ca_obj_bincmp.c): there is no three-valued comparison.
      def unary_comparison (n)
        name = spell(MONCMP_BY_ID, n.__op_id__, {})
        operand = n.parent
        args = [visit(operand)]
        comparison(:moncmp, name, operand.data_type, args, :pass, n.__trapping__)
      end

      def binary_comparison (n)
        name = spell(BINCMP_BY_ID, n.__op_id__, {})
        right = n.__bincmp_right__
        # Both sides are already of the type compared (CABinCmp casts one
        # to the other); a pair that is not has no single body.
        unless n.parent.data_type == right.data_type
          raise Refused, "#{name} between #{n.parent.data_type} and #{right.data_type}"
        end
        args = [visit(n.parent), visit(right)]
        comparison(:bincmp, name, n.parent.data_type, args, :union, n.__trapping__)
      end

      # `trapping`: the node skips the cells its operands mask rather than
      # computing them -- one that can raise on a cell or calls Ruby for it.
      # Each lazy view answers it from the rule its own kernel follows.
      def comparison (kind, name, compared, args, mask, trapping)
        body = CArray.__kernel_body__(kind, name, compared) or
          raise Refused, "#{kind} #{name} has no body at #{compared}"
        # A body written against its compared type or a tolerance (`feq`)
        # needs more than its operands substituted.
        if body.match?(/<\w+>|\btol\b/)
          raise Refused, "#{kind} #{name} needs more than its operands"
        end
        note(kind.to_s[0..3], name, compared, args.join(","))
        push Op.new(kind, name, :boolean, args, body, mask, trapping)
      end

      def op (kind, name, type, args, mask, trapping)
        body = CArray.__kernel_body__(kind, name, type) or
          raise Refused, "#{kind} #{name} has no body at #{type}"
        note(kind.to_s[0], name, type, args.join(","))
        push Op.new(kind, name, type, args, body, mask, trapping)
      end

      def leaf (n)
        index = leaf_index(n)
        note("a", index, n.data_type, n.has_mask? ? 1 : 0)
        push Leaf.new(index, n.data_type, n.has_mask?)
      end

      # A shift of an array is that array read elsewhere, so it is the
      # array that becomes a leaf.  A shift of anything else -- an
      # expression, say -- has no array to read and is taken as a whole.
      def shifted (n)
        array = n.parent
        bounds = n.__axis_bounds__
        if Fusion.lazy?(array) || array.dim != n.dim ||
           ! bounds.all? { |b| b == :fill || b == :mask }
          return leaf(n)
        end
        offset = n.start
        # The fill as a cell of the array holds it: a boolean array is
        # filled with true or false, not with the Integer it was given.
        fill = bounds.include?(:fill) ? as_cell(n.fill_value, array.data_type) : nil
        index = leaf_index(array)
        note("s", index, array.data_type, array.has_mask? ? 1 : 0,
             offset.join(","), bounds.join(","), fill.inspect)
        push Shifted.new(index, array.data_type, array.has_mask?,
                         offset, bounds, fill)
      end

      def leaf_index (array)
        @leaf_index.fetch(array.object_id) do
          @leaves << array
          @leaf_index[array.object_id] = @leaves.size - 1
        end
      end

      # A masked scalar has no value to write into the expression.
      def constant (n)
        raise Refused, "a masked scalar" if n.has_mask? && n.is_masked[0]
        value = n[0]
        note("k", value.inspect, n.data_type)
        push Const.new(value, n.data_type)
      end

      def as_cell (value, data_type)
        cell = CScalar.new(data_type)
        cell[0] = value
        cell[0]
      end

      def push (node)
        @nodes << node
        @nodes.size - 1
      end

      def spell (table, id, renames)
        ruby = table[id] or raise Refused, "operation id #{id}"
        renames.fetch(ruby, ruby)
      end

      # Two expressions of the same shape compute alike, whatever arrays
      # they are over, so a consumer can keep one compiled kernel for both.
      # The shape includes which node each operation reads and which leaf
      # each read is: `(a - b) - b` and `(a - b) - a` differ only there.
      def note (*parts)
        @signature << parts.join(":") << ";"
      end
    end
  end
end
