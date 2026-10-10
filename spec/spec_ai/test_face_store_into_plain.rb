require "test/unit"
require "carray"

# A Face array stored into an array that is not the same Face: an object
# array receives the surface values, and any other plain array refuses rather
# than receive storage bytes.
class TestFaceStoreIntoPlain < Test::Unit::TestCase

  Pixel = CArray.struct { uint8 :r; uint8 :g; uint8 :b } unless defined?(Pixel)

  def faces
    {
      "time"   => CArray.time(%w[2024-01-01 2024-01-02 2024-01-03], unit: :D),
      "tdelta" => CA_INT64([1, 2, 3]).timedelta(unit: :D),
      "cat"    => CA_OBJECT(%w[x y x]).categorize,
      "cstr"   => CArray.const_string(%w[a bb c]),
      "fixstr" => CArray.fixlen_string(%w[ab cd ef]),
    }
  end

  def values (a)
    a.to_a.map { |v| v.respond_to?(:unit) ? v.to_s : v }
  end

  def test_object_destination_receives_the_values
    faces.each do |name, f|
      expected = values(f.to_type(:object))
      stores = {
        "whole" => ->(o) { o[] = f },
        "range" => ->(o) { o[0..2] = f[0..2] },
        "index" => ->(o) { i = CA_INT64([2, 0, 1]); o[i] = f[i] },
        "mask"  => ->(o) { m = CA_BOOLEAN([true, true, true]); o[m] = f[m] },
        "paste" => ->(o) { o.paste([0], f) },
      }
      stores.each do |how, store|
        o = CArray.object(3)
        store.call(o)
        assert_equal expected, values(o), "#{name} / #{how}"
      end
    end
  end

  def test_object_block_fill
    t = faces["time"]
    assert_equal values(t.to_type(:object)), values(CArray.object(3) { t })
  end

  def test_other_plain_destination_refuses
    {
      "time" => CArray.int64(3),
      "cat"  => CArray.uint8(3),
      "cstr" => CArray.new(CA_FIXLEN, [3], bytes: 16),
    }.each do |name, dst|
      err = assert_raise(TypeError, name) { dst[] = faces[name] }
      assert_match(/can not store a #{faces[name].class} array/, err.message)
    end
    assert_raise(TypeError) { CArray.new(CA_FIXLEN, [3], bytes: 8)[] = faces["time"] }
  end

  def test_a_face_that_is_its_bytes_goes_into_plain_fixlen
    fx = CArray.new(CA_FIXLEN, [3], bytes: 2)
    fx[] = faces["fixstr"]
    assert_equal %w[ab cd ef], fx.to_a

    rec = CARecord.new(Pixel, 1)
    rec[0] = Pixel.new(r: 1, g: 2, b: 3)
    fx = CArray.new(CA_FIXLEN, [1], bytes: 3)
    fx[] = rec
    assert_equal ["\x01\x02\x03".b], fx.to_a.map(&:b)
  end

  def test_const_string_into_fixlen_string
    fs = CArray.fixlen_string(%w[zz zz zz])
    fs[] = faces["cstr"]
    assert_equal %w[a bb c], fs.to_a
  end

  def test_same_face_still_stores
    t = CArray.time(%w[2000-01-01 2000-01-01 2000-01-01], unit: :h)
    t[] = faces["time"]
    assert_equal faces["time"].to_a.map { |e| e.to_time }, t.to_a.map { |e| e.to_time }
  end
end
