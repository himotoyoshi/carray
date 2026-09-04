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
      result = eval(rewrite(body_source(block)), block.binding,
                    *block.source_location)
      # An expression that is just an array is that array; the shadow put
      # around it has nothing to fuse.
      result.is_a?(CALazyMarker) ? result.parent : result
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
