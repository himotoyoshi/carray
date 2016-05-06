require 'carray'

o = Object.new

a = CArray.int(3)
#a = NArray.int(3)

list = a.methods - o.methods
#list = list.sort_by{|x| [x.length, x] }
list = list.sort

require 'pp'

pp list

