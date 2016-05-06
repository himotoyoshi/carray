
require "carray"

describe "CArray#[]" do
  it "should return CARepeat object" do
    ca = CArray.int(3).seq!
    ca[:%,3] # =>
    ca[3,:%] # => 
  end
end
