# ---------------------------------------------------------------------------
#  Reading `CArray.fuse { a + b * c }`.
#
#  The block is not called.  Its `a` is the array itself, so calling it would
#  evaluate the expression eagerly -- which is the thing fuse exists to avoid.
#  The source is read instead, every name that holds a CArray is given `.lazy`,
#  and the result is evaluated back in the block's own binding, so `self`,
#  instance variables, methods and constants are what they were.
#
#  Ruby has no macro, so the alternative was to pass the arrays in and take
#  shadows back -- `fuse(a, b) { |x, y| ... }` -- which names each of them
#  twice.  Julia writes `@.` for the same reason and does the same thing to
#  the expression underneath.
#
#  Reading and rewriting a block gives the same text every time it is
#  called, so it is done once per block -- per place in the source -- and
#  kept.  What is kept is a lambda that takes the block's free locals as
#  arguments and is run with the block's `self`; a call only reads the
#  locals.
# ---------------------------------------------------------------------------

require "prism"

class CArray

  module FuseSource

    # Runtime coercion, so the rewrite never has to work out what a name
    # holds: anything that is not an array passes through untouched.
    def self.shadow (value)
      value.is_a?(CArray) ? value.lazy : value
    end

    def self.evaluate (block)
      result = compiled(block).call(block)
      # An expression that is just an array is that array; the shadow put
      # around it has nothing to fuse.
      result.is_a?(CALazyMarker) ? result.parent : result
    end

    # -- one compiled form per block --------------------------------------

    # Keyed by the block's instruction sequence, which is the same object
    # every time the same block is called and a different one for each
    # block, even two on one line.  Where Ruby has weak keys, a block whose
    # code is unloaded takes its entry with it.
    SITES = defined?(ObjectSpace::WeakKeyMap) ? ObjectSpace::WeakKeyMap.new
                                              : {}.compare_by_identity

    def self.compiled (block)
      site = RubyVM::InstructionSequence.of(block)
      return compile(block) unless site
      SITES[site] || (SITES[site] = compile(block))
    end

    # The block's free locals, handed to a lambda that was compiled without
    # them.  `self` is the block's own, so instance variables and methods
    # are what they were.
    Compiled = Struct.new(:locals, :lambda) do
      def call (block)
        scope = block.binding
        values = locals.map { |name| scope.local_variable_get(name) }
        scope.receiver.instance_exec(*values, &lambda)
      end
    end

    # A block that needs its own frame -- it assigns to a local outside it,
    # or yields, or asks for its binding -- is evaluated there every time;
    # only the rewrite is kept.
    InFrame = Struct.new(:text, :file, :line) do
      def call (block)
        eval(text, block.binding, file, line)
      end
    end

    # Calls that mean something only in the frame they are made from.
    FRAME_BOUND = %i[binding local_variables block_given? __method__ __dir__
                     eval].freeze

    FRAME_BOUND_NODES = [Prism::YieldNode, Prism::SuperNode,
                         Prism::ForwardingSuperNode, Prism::ReturnNode,
                         Prism::BreakNode, Prism::NextNode,
                         Prism::RedoNode].freeze

    def self.compile (block)
      body = body_source(block)
      text = rewrite(body)
      file, line = block.source_location
      scope = block.binding
      locals, needs_frame = free_locals(body, scope.local_variables)
      return InFrame.new(text, file, line) if needs_frame
      Compiled.new(locals, compile_lambda(text, locals, scope, file, line))
    end

    # Read on its own, a body names a local from outside as a call with no
    # receiver and no arguments, so every one of them is found this way.  A
    # body that assigns to one has to keep its frame.
    def self.free_locals (body, outer)
      reads = []
      needs_frame = false
      Prism.parse(body).value.breadth_first_search do |node|
        case node
        when Prism::CallNode
          reads << node.name if node.variable_call? && outer.include?(node.name)
          needs_frame = true if node.receiver.nil? && FRAME_BOUND.include?(node.name)
        when *FRAME_BOUND_NODES
          needs_frame = true
        else
          if node.class.name.match?(/\APrism::LocalVariable\w*(Write|Target)Node\z/) &&
             outer.include?(node.name)
            needs_frame = true
          end
        end
        false
      end
      [reads.uniq, needs_frame]
    end

    # Constants resolve as they do where the block was written: each module
    # it sits in is reopened around the lambda, outermost first.  The
    # refinements active there are activated again.  None of it sees the
    # frame of the call that compiles it.
    def self.compile_lambda (text, locals, scope, file, line)
      nesting = scope.eval("Module.nesting").reverse
      refinements = scope.eval("Module.used_modules")
      Thread.current[:__carray_fuse_scope__] = [nesting, refinements]
      code = refinements.each_index.map { |i|
        "using Thread.current[:__carray_fuse_scope__][1][#{i}];"
      }.join + "lambda { |#{locals.join(", ")}| #{text}\n}"
      (nesting.size - 1).downto(0) do |i|
        code = "Thread.current[:__carray_fuse_scope__][0][#{i}]" \
               ".module_eval(#{code.dump}, #{file.dump}, #{line})"
      end
      EMPTY_SCOPE.call.eval(code, file, line)
    ensure
      Thread.current[:__carray_fuse_scope__] = nil
    end

    # -- the block's own text ---------------------------------------------

    def self.body_source (block)
      text = extract(block)
      wrapped = "proc " + text
      node = Prism.parse(wrapped).value
                  .breadth_first_search { |n| n.is_a?(Prism::BlockNode) }
      inner = node && node.body
      unless inner
        raise ArgumentError,
              "CArray.fuse could not read an expression out of this block"
      end
      wrapped.byteslice(inner.location.start_offset...inner.location.end_offset)
    end

    def self.extract (block)
      sequence = RubyVM::InstructionSequence.of(block) rescue nil
      location = sequence && sequence.to_a[4][:code_location]
      path     = sequence && (sequence.absolute_path || sequence.path)
      unless location && path && File.readable?(path)
        raise ArgumentError,
              "CArray.fuse cannot read this block's source (defined in irb, " \
              "eval, or a file that is no longer there).  Write `.lazy` on " \
              "the operands instead: `a.lazy + b.lazy`."
      end
      lines = File.readlines(path)
      first_line, first_column, last_line, last_column = location
      # The columns count bytes, not characters, so a line with anything
      # multi-byte on it slices in the wrong place unless this does too.
      if first_line == last_line
        lines[first_line - 1].byteslice(first_column...last_column)
      else
        [lines[first_line - 1].byteslice(first_column..),
         *lines[first_line...(last_line - 1)],
         lines[last_line - 1].byteslice(0...last_column)].join
      end
    end

    # -- the rewrite -------------------------------------------------------

    # The leaves are the names being read.  Everything else keeps its shape:
    # calls are inserted around leaves and the expression they sit in is
    # left alone.
    class Leaves < Prism::Visitor
      attr_reader :spots

      def initialize
        @spots = []
      end

      def visit_local_variable_read_node (node)    = mark(node)
      def visit_instance_variable_read_node (node) = mark(node)
      def visit_constant_read_node (node)          = mark(node)

      # `Math::PI` is one name, not `Math` with something after it.
      def visit_constant_path_node (node)
        mark(node)
      end

      def visit_call_node (node)
        if node.name == :[] || node.name == :[]=
          # An index is a position, not a value to fuse: `a[i]` shadows `a`
          # and leaves `i` alone.
          visit(node.receiver)
          return
        end
        mark(node) if node.receiver.nil? && node.arguments.nil? && node.block.nil?
        super
      end

      private

      def mark (node)
        @spots << [node.location.start_offset, node.location.end_offset]
      end
    end

    def self.rewrite (source)
      visitor = Leaves.new
      Prism.parse(source).value.accept(visitor)
      out = source.dup
      visitor.spots.sort_by { |start, _| -start }.each do |start, stop|
        out[start...stop] = "::CArray::FuseSource.shadow(#{source[start...stop]})"
      end
      out
    end
  end
end

# A scope with no locals and no refinements in it, for compiling a block's
# expression where it can neither see nor hold on to the frame of the call
# that happens to compile it.  Both are true only of the top of a file.
CArray::FuseSource::EMPTY_SCOPE = -> { binding }
CArray::FuseSource.private_constant :EMPTY_SCOPE
