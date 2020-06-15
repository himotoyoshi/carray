class CArray
  serialize_rb = "carray/base/serialize"
  autoload :Serializer, serialize_rb
  autoload_method "self.save", serialize_rb
  autoload_method "self.load", serialize_rb
  autoload_method "self.dump", serialize_rb
  autoload_method "marshal_dump", serialize_rb
  autoload_method "marshal_load", serialize_rb

  autoload_method "save_binary", serialize_rb
  autoload_method "save_binary_io", serialize_rb
  autoload_method "self.load_binary", serialize_rb
  autoload_method "self.load_binary_io", serialize_rb
  autoload_method "self.load_from_file", serialize_rb
end

class Rational < Numeric
  include FloatFunction
end
