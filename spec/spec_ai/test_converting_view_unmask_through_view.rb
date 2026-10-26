require 'test/unit'
require 'carray'

# A value written into the masked cells of a converting view (a fake, a
# writable cast, a byte swap) reaches the root and clears the mask, also
# when the view sits on a parent whose mask is a view (a transpose, a
# grid, a stepped block).
class TestConvertingViewUnmaskThroughView < Test::Unit::TestCase

  VIEWS = {
    "transpose"     => ->(x) { x.transpose },
    "index array"   => ->(x) { x[CA_INT([1, 0]), nil] },
    "stepped block" => ->(x) { x[nil, (0..2).step(2)] },
  }

  CONVERTERS = {
    "fake"       => [->(x) { x.fake(:uint32) },                     99],
    "cast"       => [->(x) { CArray.wrap_writable(x, CA_FLOAT64) }, 99],
    "swap_bytes" => [->(x) { x.swap_bytes },                        [99].pack("l").reverse.unpack1("l")],
  }

  def root
    r = CArray.int32(2, 3).seq!
    r[1, 1] = UNDEF
    r[0, 2] = UNDEF
    r
  end

  # The same unmask through the view alone, with the stored value replaced
  # by what the converter writes for 99.
  def expected (view, stored)
    e = root
    view.call(e).unmask(99)
    e.to_a.map { |row| row.map { |c| c == 99 ? stored : c } }
  end

  def test_unmask_with_a_value
    CONVERTERS.each do |cname, (conv, stored)|
      VIEWS.each do |vname, view|
        r = root
        conv.call(view.call(r)).unmask(99)
        assert_equal expected(view, stored), r.to_a, "#{cname} over #{vname}"
      end
    end
  end

  # A write that leaves the masked cells alone keeps them masked.
  def test_map_keeps_the_mask
    CONVERTERS.each do |cname, (conv, _)|
      VIEWS.each do |vname, view|
        r = root
        conv.call(view.call(r)).map! { |x| x }
        assert_equal root.to_a, r.to_a, "#{cname} over #{vname}"
      end
    end
  end
end
