require 'carray'
require 'rspec-power_assert'

describe "Feature: Indexing" do

  example "index" do
    a = CArray.int(3,3).seq!
    expect { a[0, 0, 0] }.to raise_error(IndexError)
    expect { a[[0,1,1,2], 0] }.to raise_error(IndexError)
    expect { a[[0,4], 0] }.to raise_error(IndexError)
    expect { a[[0,3,2], 0] }.to raise_error(IndexError)
    expect { a[:abcdefg, 0] }.to raise_error(NoMethodError)
    expect { a[0, :abcdefg] }.to raise_error(IndexError)
  end

  example "rubber_dim" do
    a = CArray.int(3,3,3,3,3).seq!

    is_asserted_by { a[false] == a[nil, nil, nil, nil, nil] }

    is_asserted_by { a[0,false] == a[0, nil, nil, nil, nil] }
    is_asserted_by { a[false,0] == a[nil, nil, nil, nil, 0] }
    is_asserted_by { a[0,false,0] == a[0, nil, nil, nil, 0] }

    is_asserted_by { a[0..1,false] == a[0..1, nil, nil, nil, nil] }
    is_asserted_by { a[false,0..1] == a[nil, nil, nil, nil, 0..1] }
    is_asserted_by { a[0..1,false,0..1] == a[0..1, nil, nil, nil, 0..1] }

    is_asserted_by { a[nil,false] == a[nil, nil, nil, nil, nil] }
    is_asserted_by { a[false,nil] == a[nil, nil, nil, nil, nil] }
    is_asserted_by { a[nil,false,nil] == a[nil, nil, nil, nil, nil] }

    expect { a[0,0,0,0,0,0,false] }.to raise_error(IndexError)

  end


  example "scan_index" do
    info = CArray.scan_index([3,3],[])
    is_asserted_by { [info.type, info.index] == [CA_REG_ALL, []] }
    info = CArray.scan_index([3,3],[1])
    is_asserted_by { [info.type, info.index] == [CA_REG_ADDRESS, [1]] }
    info = CArray.scan_index([3,3],[1..2])
    is_asserted_by { [info.type, info.index] == [CA_REG_ADDRESS_COMPLEX, [[1,2,1]]] }
    info = CArray.scan_index([3,3],[1,1])
    is_asserted_by { [info.type, info.index] == [CA_REG_POINT, [1,1]] }
    info = CArray.scan_index([3,3],[1,nil])
    is_asserted_by { [info.type, info.index] == [CA_REG_BLOCK, [1,[0,3,1]]] }
    a = CArray.int(3,3).seq!
    i = CArray.int(3).seq!
    info = CArray.scan_index([3,3],[a.eq(4)])
    is_asserted_by { [info.type, info.index] == [CA_REG_SELECT, []] }
    info = CArray.scan_index([3,3],[a])
    is_asserted_by { [info.type, info.index] == [CA_REG_MAPPING, []] }
    info = CArray.scan_index([3,3],[i,i])
    is_asserted_by { [info.type, info.index] == [CA_REG_GRID, []] }
    info = CArray.scan_index([3,3],[:%, :%, 2])
    is_asserted_by { [info.type, info.index] == [CA_REG_REPEAT, []] }
    info = CArray.scan_index([3,3],[nil, nil, :*])
    is_asserted_by { [info.type, info.index] == [CA_REG_UNBOUND_REPEAT, []] }
  end

  example "addr2index" do
    a = CArray.int(3,3,3)
    is_asserted_by { [1,1,1] == a.addr2index(13) }
    is_asserted_by { 13 == a.index2addr(1,1,1) }
  end

end
