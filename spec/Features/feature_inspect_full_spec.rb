require "carray"
require 'rspec-power_assert'

describe "CArray#inspect_full" do

  # 2026-09-13
  # inspect abbreviates a large array on purpose; inspect_full is the
  # same rendering with the eliding dropped.
  example "inspect elides and inspect_full does not" do

    a = CArray.int32(8, 12).seq!

    is_asserted_by { a.inspect.include?("... ... ...") }
    is_asserted_by { not a.inspect_full.include?("...") }

  end

  # 2026-09-13
  example "every element is there" do

    a = CArray.int32(8, 12).seq!
    text = a.inspect_full

    is_asserted_by { text.lines.count { |l| l.include?("[") } == 8 }
    is_asserted_by { text.include?("95") }

  end

  # 2026-09-13
  # A long fiber is elided inside the line too, and that goes as well.
  example "a long 1-D array comes out whole" do

    v = CArray.float64(30).seq!(0, 0.25)

    is_asserted_by { v.inspect.include?("...") }
    is_asserted_by { not v.inspect_full.include?("...") }
    is_asserted_by { v.inspect_full.include?("3.75") }

  end

  # 2026-09-13
  example "a 40x40 array renders 40 rows and 1600 values" do

    a = CArray.float64(40, 40).seq!
    text = a.inspect_full

    is_asserted_by { text.lines.size == 41 }              # a header plus 40 rows
    is_asserted_by { text.lines[1..-1].join.scan(/\d+\.\d+/).size == 1600 }

  end

  # 2026-09-13
  # For an array small enough that inspect was not abbreviating, the two
  # give the same string: there is one renderer, not two.
  example "on a small array the two agree" do

    a = CArray.int32(3, 4).seq!

    is_asserted_by { a.inspect == a.inspect_full }

  end

  # 2026-09-13
  example "the header, the mask mark and the view class are inspect's" do

    a = CArray.int32(8, 12).seq!
    a[7, 11] = UNDEF

    is_asserted_by { a.inspect_full.start_with?("<CArray.int32(8,12): elem=96") }
    is_asserted_by { a.inspect_full.include?("_ ]") }
    is_asserted_by { a[1..6, nil].inspect_full.start_with?("<CABlock") }

  end

  # 2026-09-13
  example "3-D and object arrays" do

    v = CArray.int32(7, 2, 3).seq!
    is_asserted_by { not v.inspect_full.include?("...") }

    o = CA_OBJECT([[:a, :b], [:c, :d]])
    is_asserted_by { o.inspect_full.include?(":d") }

  end

  # 2026-09-13
  # Asking for the full form does not change what inspect does next.
  example "inspect still abbreviates afterwards" do

    a = CArray.int32(8, 12).seq!
    a.inspect_full

    is_asserted_by { a.inspect.include?("... ... ...") }

  end

end
