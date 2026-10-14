# CA_FOR_EACH_WHOLE / CA_FOR_EACH_WHOLE_MASKED hand the kernel the whole
# array as one contiguous run in row-major order, gathering a copy when the
# source does not lend contiguous memory.  The fixture's entry points open
# the macros; the expected answers come from the view's copy and from a
# store through the same view.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_iter_write", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_write"
rescue LoadError
  warn "Skipping test_iter_whole_macro: iter_write not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestIterWholeMacro < Test::Unit::TestCase

  def base
    CArray.float64(3, 4, 5).seq!
  end

  # Views over a root, for reading and for writing.
  VIEWS = {
    "entity"      => ->(b) { b },
    "row block"   => ->(b) { b[1..2, nil, nil] },
    "transpose"   => ->(b) { b.transpose },
    "inner block" => ->(b) { b[nil, 1..2, 1..3] },
    "grid"        => ->(b) { b[CA_INT64([2, 0]), nil, CA_INT64([4, 1])] },
    "select axis" => ->(b) { b[CA_BOOLEAN([1, 0, 1]), nil, nil] },
    "window"      => ->(b) { b.window(0..1, 1..3, 2..4) },
    "shift"       => ->(b) { b.shift(1, 0, -1) },
    "roll"        => ->(b) { b.roll(1, 1, 0) },
    "swap"        => ->(b) { b.swap_bytes.swap_bytes },
    "stack"       => ->(b) { CArray.stack((0..2).map { |i| b[i, nil, nil] }) },
  }

  # Checked by reading only: a tile shows a root cell more than once, so a
  # write to it has no single store to compare with; a lazy expression has
  # no cells to write.
  READ_VIEWS = {
    "tile" => ->(b) { b.tile(1, 2, 1) },
    "lazy" => ->(b) { (b.lazy * 2) + 1 },
  }

  def masked_base
    b = base
    b[(b % 7).eq(3)] = UNDEF
    b
  end

  def test_read_hands_the_cells_of_the_copy
    [false, true].each do |masked|
      VIEWS.merge(READ_VIEWS).each do |name, mk|
        v = mk.call(masked ? masked_base : base)
        c = v.copy
        vals  = c.value.to_a.flatten.map(&:to_f)
        flags = c.has_mask? ? c.mask.to_a.flatten : Array.new(vals.size, false)
        assert_equal vals.zip(flags).map { |x, f| f ? nil : x },
                     CArray.iw_whole_read(v, true), "#{name} masked=#{masked} MASKED form"
        assert_equal vals, CArray.iw_whole_read(v, false), "#{name} masked=#{masked} plain form"
      end
    end
  end

  def test_fake_of_an_integer_array_is_read_converted
    a = CArray.int32(2, 3).seq!
    assert_equal (0..5).map(&:to_f), CArray.iw_whole_read(a.fake(:float64), false)
  end

  def test_write_lands_where_a_store_through_the_view_lands
    [false, true].each do |masked|
      VIEWS.each do |name, mk|
        r = masked ? masked_base : base
        v = mk.call(r)
        flags = r.has_mask? ? r.mask.to_a : nil
        ref = r.value.copy
        mk.call(ref)[] = CA_FLOAT64((0...v.elements).map { |i| 1000.0 + i }).reshape(*v.shape)

        CArray.iw_whole_write(v)

        assert_equal ref.to_a, r.value.to_a, "#{name} masked=#{masked}"
        assert_equal flags, (r.has_mask? ? r.mask.to_a : nil), "#{name} masked=#{masked} mask"
      end
    end
  end

  def test_a_read_only_view_is_refused_for_write
    e = assert_raise(RuntimeError) { CArray.iw_whole_write(READ_VIEWS["lazy"].call(base)) }
    assert_match(/kernel iterator: .+ \(rc=4\)/, e.message)
  end

  def test_break_writes_back_what_was_written
    %w[entity transpose grid].each do |name|
      r = base
      v = VIEWS[name].call(r)
      CArray.iw_whole_break(v, 4)
      want = base
      w = VIEWS[name].call(want)
      w_flat = w.copy.to_a.flatten
      4.times { |i| w_flat[i] = -1.0 }
      w[] = CA_FLOAT64(w_flat).reshape(*w.shape)
      assert_equal want.to_a, r.to_a, name
    end
  end

  # A raising body is opened inside ca_iter_ensure.  The walk is closed
  # either way; whether the cells written before the raise stay depends on
  # the route: a walk that lends the array's memory keeps them, a walk over
  # a gathered copy keeps none.
  def test_a_raise_inside_ca_iter_ensure_closes_the_walk
    %w[entity row\ block transpose grid swap].each do |name|
      r = base
      v = VIEWS[name].call(r)
      lends = CArray.iw_route(VIEWS[name].call(base), 0, 0, true)[:alias_mode] != 0
      before = CArray.respond_to?(:__attached_views__) ? CArray.__attached_views__ : nil

      e = assert_raise(RuntimeError, name) { CArray.iw_whole_raise(v, 4) }
      assert_equal "iw_whole_raise", e.message, name
      assert_equal before, CArray.__attached_views__, "#{name} attached views" if before

      want = base
      if lends
        w = VIEWS[name].call(want)
        w_flat = w.copy.to_a.flatten
        4.times { |i| w_flat[i] = -1.0 }
        w[] = CA_FLOAT64(w_flat).reshape(*w.shape)
      end
      assert_equal want.to_a, r.to_a, "#{name} (lends memory: #{lends})"
    end
  end

end
