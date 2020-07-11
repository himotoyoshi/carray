require "carray"
require 'rspec-power_assert'

describe "CArray#[]" do

  example "should return one element array with [nil,-1]" do
    ca = CArray.int(4,4).seq!
    is_asserted_by { ca[[nil,-1]].elements == 1 }
    is_asserted_by { ca[[nil,-1]] == ca[[0]] }
  end

  example "should return self[[0],nil] with [nil,-1], nil" do
    ca = CArray.int(4,4).seq!
    is_asserted_by { ca[[nil,-1],nil] == ca[[0],nil] }
  end

  example "should return self[[0],nil] with nil, [nil,-1]" do
    ca = CArray.int(4,4).seq!
    is_asserted_by { ca[nil,[nil,-1]] == ca[nil,[0]] }
  end

  example "should return self[[0],nil] with [nil,-1], [nil,-1]" do
    ca = CArray.int(4,4).seq!
    is_asserted_by { ca[[nil,-1],[nil,-1]] == ca[[0],[0]] }
  end

end