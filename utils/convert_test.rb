require 'parser/current'
require 'unparser'

module YourHelper
  def s(type, *children)
    Parser::AST::Node.new(type, children)
  end
end

include YourHelper

while line = gets
  if line =~ /require .test\/unit./ or line =~ /\$\:\.unshift/
    next
  end
  line.gsub!(/(require .carray.\s*$)/, %{\\1require "rspec-power_assert"})
  line.gsub!(/class (Test.*)\s*<\s*Test::Unit::TestCase/, 'describe "\1" do')
  line.gsub!(/def test_(.*)/, 'example "\1" do')
  line.gsub!(/\A(\s*)(assert_raise\((.*)\))\s*{(.*)}/, "\\1expect {\\4}.to raise_error(\\3)")
  line.gsub!(/\A(\s*)assert_nothing_raised\s*{(.*)}/, "\\1expect {\\2}.not_to raise_error()")

  if line =~ /\A(\s*)(assert_equal\(.*\))\s*\z/
    prespc = $1
    body   = $2
    ast = Unparser.parse(body)
    newast = s(:block,
                s(:send, nil, :is_asserted_by),
                s(:args),
                s(:send,
                  ast.children[2], :==,
                  ast.children[3]))
    conv = Unparser.unparse(newast).dup # => 'your(ruby(code))'
    conv.gsub!(/do\n\s*/, "{ ")
    conv.gsub!(/\n\s*end/, " }")
    line = prespc + conv
  end
  line.gsub!(/assert_equal\(/, 'is_asserted_by { ')

  if line =~ /\A(\s*)(assert_not_equal\(.*\))/
    prespc = $1
    body   = $2
    ast = Unparser.parse(body)
    newast = s(:block,
                s(:send, nil, :is_asserted_by),
                s(:args),
                s(:send,
                  ast.children[2], :!=,
                  ast.children[3]))
    conv = Unparser.unparse(newast).dup # => 'your(ruby(code))'
    conv.gsub!(/do\n\s*/, "{ ")
    conv.gsub!(/\n\s*end/, " }")
    line = prespc + conv
  end

  if line =~ /\A(\s*)(assert_instance_of\(.*\))/
    prespc = $1
    body   = $2
    ast = Unparser.parse(body)
    newast = s(:block,
                s(:send, nil, :is_asserted_by),
                s(:args),
                s(:send,
                  s(:send,
                    ast.children[3], :class), :==,
                      ast.children[2]))
    conv = Unparser.unparse(newast).dup # => 'your(ruby(code))'
    conv.gsub!(/do\n\s*/, "{ ")
    conv.gsub!(/\n\s*end/, " }")
    line = prespc + conv
  end

  puts line
end