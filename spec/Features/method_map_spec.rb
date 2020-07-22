require 'carray'
require "rspec-power_assert"

describe "CArray#map" do

  # 2020-07-22
  example "same shape" do
    #
    a = CArray.int32(3,3).seq
    b = a.map{|x| x.to_s }
    is_asserted_by { b.class == Array }
    is_asserted_by { b.size  == 3 }
    is_asserted_by { b[0].size  == 3 }
    is_asserted_by { b == [ [ "0", "1", "2" ],
                            [ "3", "4", "5" ],
                            [ "6", "7", "8" ] ] }

    # mask does not be templated
    a = CArray.int32(3,3).seq
    a[1,1] = UNDEF
    b = a.map{|x| x.to_s }
    is_asserted_by { b == [ [ "0", "1", "2" ],
                            [ "3", UNDEF, "5" ],
                            [ "6", "7", "8" ] ] }
  end

  # 2020-07-22
  example "flatten list" do
    a = CArray.int32(3,3).seq
    b = a[nil].map{|x| x.to_s }
    is_asserted_by { b == [ "0", "1", "2", "3", "4", "5", "6", "7", "8"] }
  end

  example "string generation" do
    # ---
    a = CArray.int(3).seq!
    if RUBY_VERSION >="1.9.0"
      b = a.map {|x| (x+"a".ord).chr }
    else
      b = a.map {|x| (x+?a).chr }
    end
    is_asserted_by { ["a", "b", "c"] == b }

    # ---
    a = CArray.int(3,3).seq!
    if RUBY_VERSION >= "1.9.0"
      b = a.map {|x| (x+"a".ord).chr }
    else
      b = a.map {|x| (x+?a).chr }
    end
    is_asserted_by { [["a", "b", "c"], ["d", "e", "f"], ["g", "h", "i"]] == b }
  end

end
