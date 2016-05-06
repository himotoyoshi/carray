require "rational"
require "complex"

class_list = [
  Kernel,
  Object,
  Numeric,
  Float,
  Integer,
  Bignum,
  Fixnum,
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
pp (cnst_intr.sort)


class_list.each do |klass|
  puts klass
  p intr[klass].sort
  p intr_s[klass].sort
end

p CA.singleton_methods.sort


