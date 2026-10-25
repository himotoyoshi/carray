require 'carray'
require "rspec-power_assert"

describe "CScalar#[]" do

  example "basic" do
    a = CA_DOUBLE(3.0)

    # a[] and a[0] read the value
    is_asserted_by { a[] == 3.0 }
    is_asserted_by { a[0] == 3.0 }

    # any other index is refused
    expect { a[1] }.to raise_error(ArgumentError)
    expect { a[nil] }.to raise_error(ArgumentError)
    expect { a[0..5] }.to raise_error(ArgumentError)

    a[0] = 5.0
    is_asserted_by { a[0] == 5.0 }
    a[] = 6.0
    is_asserted_by { a[] == 6.0 }
    expect { a[1] = 5.0 }.to raise_error(ArgumentError)
  end

  example "select" do
    a = CA_DOUBLE(3.0)
    idx = CA_BOOLEAN([true,false,true,false,true])
    expect { a[idx] }.to raise_error(ArgumentError)
  end

  example "mapping" do
    a = CA_DOUBLE(3.0)
    expect { a[CA_INT([0,0,0,0,0])] }.to raise_error(ArgumentError)
  end

  example "method" do
    a = CA_DOUBLE(3.0)
    expect { a[:gt,1] = 10 }.to raise_error(ArgumentError)
    is_asserted_by { a[0] == 3.0 }
  end

end
