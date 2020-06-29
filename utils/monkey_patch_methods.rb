require "rational"
require "complex"

class_list = [
  Kernel,
  Object,
  Numeric,
  Float,
  Integer,
  Rational,
]

cnst_orig = Object.constants
orig = {}
intr = {}
orig_s = {}
intr_s = {}

class_list.each do |klass|
  orig[klass] = klass.instance_methods
  orig_s[klass] = klass.singleton_methods
end

$CARRAY_NO_AUTOLOAD = true
require "carray"

class_list.each do |klass|
  intr[klass] = klass.instance_methods - orig[klass]
  intr_s[klass] = klass.singleton_methods - orig_s[klass]
  klass.ancestors[1..-1].each do |mod|
    if orig.has_key?(mod)
      intr[klass] -= intr[mod]
    end
  end
end

cnst_intr = (Object.constants - cnst_orig)

require "pp"

puts "Global Constants"
puts "----------"
pp (cnst_intr.sort)
puts

class_list.each do |klass|
  puts "#{klass}"
  puts "----------"
  unless intr_s[klass].empty?
    puts "### Singleton Methods"
    pp intr_s[klass].sort 
  end
  unless intr[klass].empty?
    puts "### Instance Methods"
    pp intr[klass].sort
  end
  puts
end

#pp CA.singleton_methods.sort


