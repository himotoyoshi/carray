# ---------------------------------------------------------------------------
#  Turning a lazy expression into a plan a compiler can read.
#
#  A lazy view is already a typed, closed expression graph, and the kernels
#  already carry the C that computes each operation (CArray.__kernel_body__).
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
    #   Op    an operation, reading the nodes named in `args`
    #   Leaf  an array, the `index`-th of plan.leaves
    #   Const a scalar written into the expression
    Op    = Struct.new(:kind, :name, :data_type, :args, :body, :mask, :trapping)
    Leaf  = Struct.new(:index, :data_type, :masked)
    Const = Struct.new(:value, :data_type)

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
    BINOP_BY_ID = CArray::LAZY_BINOP_OP_IDS.invert.freeze
    TRIOP_BY_ID = CArray::LAZY_TRIOP_OP_IDS.invert.freeze

    # Integer division and its relatives raise on a zero divisor, so a cell
    # the mask excludes must not be computed at all -- the divisor there is
    # nobody's business (ca_binop_dispatch.c).
    TRAPPING = %i[div mod quo_i fmod].freeze
    INTEGERS = %i[int8 int16 int32 int64 uint8 uint16 uint32 uint64].freeze

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
      return nil unless askable?(view)
      out = CArray.__alloc_uninit__(view.data_type, view.dim)
      evaluate_into(view, out) ? out : nil
    end

    # Fills an array the caller already has.  Called from the store as well,
    # where making one and copying it over would be most of the work.
    # Returns true when something computed it.
    def self.evaluate_into (view, out)
      evaluator = CArray.expression_evaluator or return false
      return false unless askable?(view)
      plan = plan(view) or return false
      # A marker over an array, or anything else with nothing to compute,
      # is not worth handing over.
      return false unless plan.nodes.any? { |n| n.is_a?(Op) }
      out.mask = 0 if plan.masked && ! out.has_mask?
      evaluator.call(plan, out) ? true : false
    rescue StandardError => error
      CArray.expression_evaluator = nil
      warn "CArray: the registered expression evaluator raised " \
           "(#{error.class}: #{error.message}); expressions will be walked " \
           "from here on"
      false
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
      Plan.new(w.nodes, w.leaves, view.data_type, view.dim,
               w.leaves.any? { |a| a.has_mask? }, w.signature)
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
        when CScalar      then constant(n)
        when CArray       then leaf(n)
        else raise Refused, "#{n.class} in an expression"
        end
      end

      def unary (n)
        name = spell(MONOP_BY_ID, n.__op_id__, {})
        args = [visit(n.parent)]
        # A view over one array is masked exactly where that array is
        # (ca_obj_monop.c).
        op(:monop, name, n.data_type, args, :pass)
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
        op(:binop, name, n.data_type, args, rule)
      end

      def ternary (n)
        name = spell(TRIOP_BY_ID, n.__op_id__, TRIOP_NAMES)
        args = [visit(n.parent), visit(n.__triop_op2__), visit(n.__triop_op3__)]
        op(:triop, name, n.data_type, args, :union)
      end

      def op (kind, name, type, args, mask)
        body = CArray.__kernel_body__(kind, name, type) or
          raise Refused, "#{kind} #{name} has no body at #{type}"
        note(kind.to_s[0], name, type)
        push Op.new(kind, name, type, args, body, mask,
                    TRAPPING.include?(name) && INTEGERS.include?(type))
      end

      def leaf (n)
        note("a", n.data_type, n.has_mask? ? 1 : 0)
        @leaves << n
        push Leaf.new(@leaves.size - 1, n.data_type, n.has_mask?)
      end

      def constant (n)
        note("k", n[0], n.data_type)
        push Const.new(n[0], n.data_type)
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
      def note (*parts)
        @signature << parts.join(":") << ";"
      end
    end
  end
end
