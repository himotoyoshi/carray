require 'test/unit'
require 'carray'

# Masks of views whose parent can be given a mask later (a lazy expression,
# a stack or meld part), and refused writes to the mask of a stack or meld
# with a part that can have no mask.
class TestViewMaskSecondPass < Test::Unit::TestCase

  # A shift or window that masks its out-of-bounds cells over a lazy
  # expression none of whose operands has a mask yet.
  def test_bounds_mask_over_unmasked_lazy_expression
    x = CArray.float64(4, 5).seq!
    [
      -> { (x.lazy + 1).shift(1, 1, fill_value: UNDEF) },
      -> { x.lazy.gt(3).window(-1..4, nil, fill_value: UNDEF) },
      -> { (x.lazy + 1)[0..2, nil].shift(1, 0, fill_value: UNDEF) },
      -> { (x.lazy + 1).roll(1, 0).shift(1, 0, fill_value: UNDEF) },
    ].each do |make|
      v = make.call
      assert_equal v.copy.to_a, v.to_a
      assert_equal true, v.to_a.flatten.include?(UNDEF)
    end
    v = (x.lazy + 1).shift(1, 1, fill_value: UNDEF)
    assert_equal [UNDEF] * 5, v.to_a[0]
    assert_equal 1.0, v[1, 1]
    x[0, 0] = UNDEF                       # an operand is given a mask later
    assert_equal UNDEF, v[1, 1]
    assert_equal (x + 1).shift(1, 1, fill_value: UNDEF).to_a, v.to_a
  end

  # Masking the out-of-bounds cells of a shift or window gives the parent
  # no mask; the window's mask follows a mask the parent is given later,
  # and a true written through the window gives the parent its mask.
  def test_bounds_mask_gives_the_parent_no_mask
    a = CArray.float64(4, 5).seq!.freeze
    v = a.shift(1, 1, fill_value: UNDEF)
    assert_equal false, a.has_mask?
    assert_equal 8, v.count_masked
    assert_equal false, a.has_mask?

    b = CArray.float64(4, 5).seq!
    w = b.window(-1..4, nil, fill_value: UNDEF)
    assert_equal 10, w.count_masked
    assert_equal false, b.has_mask?
    b[1, 1] = UNDEF
    assert_equal UNDEF, w[2, 1]
    assert_equal 11, w.count_masked
    assert_equal w.to_a, b.window(-1..4, nil, fill_value: UNDEF).copy.to_a

    c = CArray.float64(4, 5).seq!
    s = c.shift(1, 1, fill_value: UNDEF)
    s.mask.dup
    s[2, 2] = UNDEF
    assert_equal UNDEF, c[1, 1]
    assert_equal 1, c.count_masked

    t = CArray.float64(4, 5).seq!
    u = t.shift(1, 1, fill_value: UNDEF)
    u.invert_mask
    assert_equal 12, t.count_masked

    x = CArray.float64(4, 5).seq!
    e = x.lazy + 1
    e.shift(1, 1, fill_value: UNDEF).to_a
    assert_equal false, e.has_mask?
  end

  # The dup of a view's mask is another view onto the same parent mask, for
  # every kind of view: it follows later changes, a write to it lands in the
  # parent's mask, and copy is the way to a mask of its own.
  def test_dup_of_a_view_mask_stays_on_the_parent
    views = {
      "transpose"  => ->(a) { a.transpose },
      "roll"       => ->(a) { a.roll(0, 0) },
      "block"      => ->(a) { a[0..1, nil] },
      "fake"       => ->(a) { a.fake(:float32) },
      "swap_bytes" => ->(a) { a.swap_bytes },
      "lazy"       => ->(a) { a.lazy + 1 },
    }
    views.each do |name, make|
      [:dup, :clone].each do |how|
        a = CArray.float64(2, 3).seq
        a[0, 0] = UNDEF
        m = make.(a).mask.send(how)
        snap = make.(a).mask.copy
        a[1, 1] = UNDEF
        assert_equal 2, m.count(true), "#{name}.mask.#{how}"
        assert_equal 1, snap.count(true), "#{name}.mask.copy"
      end
    end
    t = CArray.int64(2, 3).seq.time(unit: :s)
    t[0, 0] = UNDEF
    m = t.transpose.mask.dup
    t[1, 1] = UNDEF
    assert_equal 2, m.count(true)

    a = CArray.float64(2, 3).seq
    a[0, 0] = UNDEF
    d = a.fake(:float32).mask.dup
    d[0, 1] = 1
    assert_equal UNDEF, a[0, 1]

    a = CArray.float64(2, 3).seq
    a[0, 0] = UNDEF
    d = a.mask.dup                      # the mask of an entity is copied
    a[1, 1] = UNDEF
    assert_equal 1, d.count(true)
    assert_equal true, (a.lazy + 1).mask.dup.read_only?
    assert_equal true, a.fake(:float32).mask.clone(freeze: true).frozen?
  end

  def test_remap_mask_dup
    a = CArray.float64(3, 4).seq!
    a[0, 0] = UNDEF
    m = a.sort(axis: 1).mask
    assert_equal m.to_a, m.dup.to_a
    assert_equal m.to_a, m.clone.to_a
  end

  # A stack or meld read once, after which a read-only part's operand is
  # given a mask.
  def test_stack_sees_a_later_mask_of_a_read_only_part
    a = CArray.float64(2, 3).seq
    b = CArray.float64(2, 3).seq(100)
    b[0, 0] = UNDEF
    v = CArray.stack([a.lazy + 1, b])
    v.to_a
    a[1, 1] = UNDEF
    assert_equal UNDEF, v[0, 1, 1]
    assert_equal 2, v.count_masked
    assert_equal CArray.stack([a + 1, b]).sum, v.sum
  end

  def test_meld_sees_a_later_mask_of_a_read_only_part
    a = CArray.float64(3).seq
    b = CArray.float64(2).seq(100)
    b[0] = UNDEF
    v = CArray.meld(a.lazy + 1, b)
    v.to_a
    a[1] = UNDEF
    assert_equal UNDEF, v[1]
    assert_equal CArray.meld(a + 1, b).to_a, v.to_a
  end

  def stack_with_value_part
    a = CArray.float64(3).seq(1)
    a[1] = UNDEF
    b = CArray.float64(3).seq(1)
    [b, CArray.stack([b, a.value])]
  end

end
