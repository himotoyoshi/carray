require 'carray'
require "rspec-power_assert"

describe "CScalar#[]" do
  
  example "basic" do  
    a = CA_DOUBLE(3.0)
    
    is_asserted_by { a[0] == 3.0 }
    is_asserted_by { a[1] == 3.0 }

    # a[] returns self
    is_asserted_by { a[].class == CScalar }
    is_asserted_by { a[] == a }

    # a[nil] returns self
    is_asserted_by { a[nil].class == CScalar }
    is_asserted_by { a[nil] == a }

    # a[block] returns self
    is_asserted_by { a[0..5].class == CScalar }
    is_asserted_by { a[0..5] == a }

    a[0] = 5.0
    is_asserted_by { a[0] == 5.0 }
    expect { a[1] = 5.0 }.to raise_error(IndexError)
  end

  example "select" do  
    a = CA_DOUBLE(3.0)
    idx = CA_BOOLEAN([true,false,true,false,true])
    expect { a[idx] }.to raise_error(RuntimeError)
  end

  example "mapping" do  
    a = CA_DOUBLE(3.0)
    idx = CA_INT([0,0,0,0,0])
    is_asserted_by { a[idx] == CA_DOUBLE([3,3,3,3,3]) }

    idx = CA_INT([0,1,2,3,4])
    expect { a[idx] }.to raise_error(IndexError)
  end

  example "method" do  
    a = CA_DOUBLE(3.0)
    a[:gt,1] = 10
    is_asserted_by { a[0] == 10 }

    a = CA_DOUBLE(3.0)
    a[:lt,1] = 10
    is_asserted_by { a[0] == 3.0 }
  end
    
end

