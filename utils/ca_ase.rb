require 'carray'
require 'pp'

class CArray
  def ase_inspect (name)
    io = "assert_equal("
    type_name = CArray.data_type_name(self.data_type)
    head = "CA_#{type_name.upcase}("
    io << head
    text = self.to_a.pretty_inspect().chomp!
    io << text.map { |line|
      line.sub(/\A +/, " " * (14 + head.length))
    }.join
    io << "), " << name << ")" << "\n"
    return io
  end
end

a = CArray.int(3,3).seq!

puts a.ase_inspect("a")
