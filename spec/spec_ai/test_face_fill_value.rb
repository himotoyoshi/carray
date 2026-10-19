require "test/unit"
require "carray"

# A fill value is a value of the array it fills: a Time for a time array, a
# struct for a record array.  Every verb that takes one writes it the way a
# store writes it, so they all give the cell the same value.

class TestFaceFillValue < Test::Unit::TestCase

  # ORDERABLE, not COMPARABLE, no to_comparable.
  class OrderedTicks < CAObject
    def initialize (parent)
      super(CA_FIXLEN, parent.shape, bytes: 8, storage: CA_INT64, parent: parent,
            face: true, orderable_storage: true)
    end
    def storage_to_element (raw)
      raw.is_a?(String) ? raw.unpack1("q") : raw
    end
  end

  def time (*s)
    CArray.time(s, unit: :D)
  end

  def strings (a)
    a.to_a.map(&:to_s)
  end

  def test_every_fill_verb_writes_the_value_a_store_writes
    arrays = [CA_INT8([0, 0, 0]), CA_FLOAT32([0, 0, 0]), CA_OBJECT([0, 0, 0]),
              time("2024-01-01", "2024-01-02", "2024-01-03"),
              CArray.string(%w[a b c]), CArray.fixlen_string(%w[aa bb cc])]
    values = [1, 300, 1.5, "2", Time.utc(2024, 1, 5), "2024-01-05", "zz"]
    arrays.each do |a|
      values.each do |v|
        verbs = {
          "store"      => -> { b = a.copy; b[0] = v; b[0] },
          "shift"      => -> { a.shift(1, fill_value: v)[0] },
          "window"     => -> { a.window(-1..1, fill_value: v)[0] },
          "template"   => -> { a.template { v }[0] },
          "project"    => -> { a.project(CA_INT64([-1, 0]), v)[0] },
          "unmask"     => -> { b = a.copy; b[0] = UNDEF; b.unmask(v); b[0] },
          "strip_mask" => -> { b = a.copy; b[0] = UNDEF; b.strip_mask(v)[0] },
        }
        answers = verbs.transform_values { |f| begin; f.call; rescue => e; e.class; end }
        assert_equal 1, answers.values.uniq.size, "#{a.class} #{a.data_type} #{v.inspect}: #{answers}"
      end
    end
  end

  def test_resize_writes_its_fill_value_as_a_value_of_the_array
    t = time("2024-01-01", "2024-01-02")
    assert_equal %w[2024-01-01 2024-01-02 2024-01-09],
                 strings(t.resize(3, fill_value: Time.utc(2024, 1, 9)))
    assert_equal %w[2024-01-01 2024-01-02 1970-01-01], strings(t.resize(3))
    assert_equal [true, false, false], t.resize(-3, fill_value: UNDEF).is_masked.to_a
    assert_equal [1, 2, 7], CA_INT32([1, 2]).resize(3, fill_value: 7).to_a
    assert_equal ["ab", "cd", ""], CArray.fixlen_string(%w[ab cd]).resize(3).to_a
  end

  def test_a_categorical_leaves_new_cells_undefined_unless_given_a_label
    k = CArray.string(%w[b a b]).categorize
    assert_equal ["b", "a", "b", UNDEF], k.resize(4).to_a
    assert_equal ["b", "a", "b", "a"], k.resize(4, fill_value: "a").to_a
    assert_raise(ArgumentError) { k.resize(4, fill_value: "z") }
    assert_equal ["b", UNDEF, "a", "b"], k.insert_block([1], [1]).to_a
    assert_equal ["b", "b", "a", "b"], k.insert_block([1], [1]) { "b" }.to_a
    c = CArray.const_string(%w[ab cd])
    assert_equal ["ab", "cd", ""], c.resize(3).to_a
  end

  def test_insert_block_writes_the_block_value_as_a_value_of_the_array
    t = time("2024-01-01", "2024-01-02")
    assert_equal %w[2024-01-09 2024-01-01 2024-01-02],
                 strings(t.insert_block([0], [1]) { Time.utc(2024, 1, 9) })
    assert_kind_of CATime, t.insert_block([1], [1])
    assert_equal [1, 9, 9, 2], CA_INT32([1, 2]).insert_block([1], [2]) { 9 }.to_a
  end

  def test_locate_nearest_addr_takes_operands_by_the_shared_rule
    ticks = OrderedTicks.new(CA_INT64([1, 5, 9]))
    assert_raise(ArgumentError) { CA_INT64([4]).locate_nearest_addr(ticks) }
    assert_raise(ArgumentError) { ticks.locate_nearest_addr(CA_INT64([4])) }
    assert_raise(ArgumentError) {
      CArray.string(%w[b]).locate_nearest_addr(CArray.const_string(%w[a b]))
    }
    h = CArray.time(["2024-01-04T20"], unit: :h)
    assert_equal [1], h.locate_nearest_addr(time("2024-01-01", "2024-01-05")).to_a
  end
end

class TestFaceInterpolates < Test::Unit::TestCase

  # A Face that says it interpolates by defining its own linear_fetch.
  class Ticks < CAObject
    def initialize (parent)
      super(CA_FIXLEN, parent.shape, bytes: 8, storage: CA_INT64, parent: parent,
            face: true, orderable_storage: true, comparable_storage: true)
    end
    def storage_to_element (raw)
      raw.is_a?(String) ? raw.unpack1("q") : raw
    end
    def linear_fetch (x)
      Ticks.new(parent.linear_fetch(x).round.to_type(:int64))
    end
  end

  def ticks
    a = CA_INT64([10, 0, 30, 0])
    a[1] = UNDEF
    a[3] = UNDEF
    Ticks.new(a)
  end

  def test_the_core_and_a_frame_agree_on_which_faces_interpolate
    core = ticks.strip_mask(method: :linear)
    assert_equal [10, 20, 30], core.parent.to_a[0, 3]
    df = CAFrame.new({ "t" => ticks }, index: CA_FLOAT64([0, 1, 2, 3]))
    df.fill("t", :linear)
    assert_kind_of Ticks, df["t"]
    assert_equal [10, 20, 30], df["t"].parent.to_a[0, 3]
  end

  def test_a_face_takes_a_face_of_its_own_class
    a = Ticks.new(CA_INT64([1, 2, 3]))
    b = Ticks.new(CA_INT64([0, 0, 0]))
    b[] = a
    assert_equal [1, 2, 3], b.parent.to_a
    o = TestFaceFillValue::OrderedTicks.new(CA_INT64([0, 0]))
    o[] = TestFaceFillValue::OrderedTicks.new(CA_INT64([4, 5]))
    assert_equal [4, 5], o.parent.to_a
  end

  def test_neither_interpolates_a_face_without_linear_fetch
    c = CArray.string(%w[a b])
    c[1] = UNDEF
    assert_raise(ArgumentError) { c.strip_mask(method: :linear) }
    df = CAFrame.new({ "c" => c }, index: CA_FLOAT64([0, 1]))
    assert_raise(ArgumentError) { df.fill("c", :linear) }
  end
  # Faces with no store of their own: a categorical's fill value is a label,
  # a CAConstString takes only UNDEF.
  def test_a_categorical_and_a_const_string_take_a_fill_value_as_a_value
    c = CA_OBJECT(%w[a b a]).categorize
    assert_equal %w[b a b], c.shift(1, fill_value: "b").to_a
    assert_equal %w[b a b], c.window(-1..1, fill_value: "b").to_a
    assert_raise(ArgumentError) { c.shift(1, fill_value: 1) }
    assert_raise(ArgumentError) { c.shift(1, fill_value: "zz") }
    assert_equal [UNDEF, "a", "b"], c.shift(1, fill_value: UNDEF).to_a
    n = CA_OBJECT([1.0, Float::NAN]).categorize
    assert n.shift(1, fill_value: Float::NAN)[0].nan?
    cs = CArray.const_string(%w[hello world xyz])
    assert_raise(ArgumentError) { cs.shift(1, fill_value: "zz") }
    assert_raise(ArgumentError) { cs.window(-1..1, fill_value: [0, 3].pack("q<q<")) }
    assert_equal [UNDEF, "hello", "world"], cs.shift(1, fill_value: UNDEF).to_a
  end

end
