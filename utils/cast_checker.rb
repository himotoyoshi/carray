require "carray"
require "rational"
types = [
         :boolean,
         :int8,
         :int32,
         :float32,
         :float64,
         :cmplx64,
         :cmplx128,
         :object,
        ]
types.each do |type1|
  [
   2, 2.0, 2.to_r, :int8, :uint8, :float64, :object
  ].each do |type2|
    ca1 = CArray.new(type1, [1])
    if type2.is_a?(Symbol)
      ca2 = CArray.new(type2, [1])
    else
      ca2 = type2
    end
    begin
      atype1, atype2 = CArray.cast_self_or_other(ca1, ca2).map{|a| a.data_type_name }
      printf("(%s, %s)\t -> (%s, %s)\n", type1.inspect, type2.inspect, atype1.inspect, atype2.inspect)
    rescue
      printf("(%s, %s)\t -> invalid pair\n", type1.inspect, type2.inspect)
    end
  end
end
