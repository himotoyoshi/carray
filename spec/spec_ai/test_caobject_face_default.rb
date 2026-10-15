# frozen_string_literal: true
#
# A CAObject Face over a numeric storage is NonNumeric unless it says
# numeric: true. Its cells read as the stored values, and storage_to_element
# receives those values rather than their bytes.

require "test/unit"
require_relative "../../lib/carray"

class TestCAObjectFaceDefault < Test::Unit::TestCase

  class Plain < CAObject
    def initialize(parent, **opts)
      super(parent.data_type, parent.shape, bytes: parent.bytes, parent: parent,
            face: true, **opts)
    end
  end

  class Doubled < CAObject
    def initialize(parent)
      super(parent.data_type, parent.shape, parent: parent, face: true)
    end
    def storage_to_element(raw)
      [raw.class, raw * 2]
    end
  end

  NUMERIC = {
    float64:  -> { CA_FLOAT64([1.5, 2.5, 3.5]) },
    int64:    -> { CA_INT64([1, 2, 3]) },
    uint8:    -> { CA_UINT8([1, 2, 3]) },
    cmplx128: -> { CA_CMPLX128([1 + 2i, 3, 4i]) },
  }

  def test_numeric_storage_is_gated_by_default
    NUMERIC.each do |name, make|
      f = Plain.new(make.call)
      assert_equal :fixlen, f.data_type, name.to_s
      assert_raise(TypeError, name.to_s)               { f + 1 }
      assert_raise(CArray::DataTypeError, name.to_s)   { f.sum }
      assert_raise(TypeError, name.to_s)               { f.to_type(:float64) }
    end
  end

  def test_cells_read_as_the_stored_values
    NUMERIC.each do |name, make|
      p = make.call
      f = Plain.new(p)
      assert_equal p.to_a, f.to_a, name.to_s
      assert_equal p[1], f[1], name.to_s
      assert_equal p.to_a, f.each.to_a, name.to_s
      assert_equal p.to_a, f.to_type(:object).to_a, name.to_s
      assert_equal p[1..2].to_a, f[1..2].to_a, name.to_s
      assert_kind_of Plain, f[1..2], name.to_s
    end
  end

  def test_boolean_cells_read_as_true_and_false
    f = Plain.new(CA_BOOLEAN([true, false]))
    assert_equal [true, false], f.to_a
    assert_equal true, f[0]
  end

  def test_writes_reach_the_storage
    p = CA_FLOAT64([1.0, 2.0, 3.0])
    f = Plain.new(p)
    f[0] = 9.5
    f[1..2] = [7, 8]
    assert_equal [9.5, 7.0, 8.0], p.to_a
    f[2] = UNDEF
    assert_equal [9.5, 7.0, UNDEF], p.to_a
  end

  def test_inspect_shows_the_stored_values
    assert_match(/\[ 1\.5, 2\.5, 3\.5 \]/, Plain.new(CA_FLOAT64([1.5, 2.5, 3.5])).inspect)
    assert_match(/\[ 1, 2, 3 \]/, Plain.new(CA_INT64([1, 2, 3])).inspect)
  end

  def test_storage_to_element_receives_the_stored_value
    f = Doubled.new(CA_INT64([1, 2, 3]))
    assert_equal [Integer, 4], f[1]
    g = Doubled.new(CA_FLOAT64([1.5]))
    assert_equal [Float, 3.0], g[0]
    assert_equal [[Float, 3.0]], g.to_a
  end

  def test_numeric_true_passes_through
    p = CA_FLOAT64([1.0, 2.0])
    f = Plain.new(p, numeric: true)
    assert_equal :float64, f.data_type
    assert_equal [2.0, 3.0], (f + 1).to_a
    assert_equal CArray, (f + 1).class
    assert_equal 1.5, f.mean
    assert_equal [1.0, 2.0], f.to_type(:float64).to_a
  end

  def test_object_and_fixlen_storage_keep_their_data_type
    o = Plain.new(CA_OBJECT(["a", 3]))
    assert_equal :object, o.data_type
    assert_equal ["a", 3], o.to_a
    x = Plain.new(CArray.new(CA_FIXLEN, [2], bytes: 4))
    assert_equal :fixlen, x.data_type
  end

  def test_numeric_is_refused_where_it_means_nothing
    assert_raise(ArgumentError) { Plain.new(CA_OBJECT([1]), numeric: true) }
    assert_raise(ArgumentError) { Plain.new(CArray.new(CA_FIXLEN, [1], bytes: 4), numeric: true) }
    assert_raise(ArgumentError) { CAObject.new(CA_INT64, [2], numeric: true) }
    assert_raise(ArgumentError) do
      CAObject.new(CA_FIXLEN, [2], bytes: 8, storage: CA_INT64,
                   parent: CA_INT64([1, 2]), face: true, numeric: true)
    end
  end

  def test_storage_must_be_the_parents
    assert_raise(TypeError) do
      CAObject.new(CA_INT64, [2], parent: CA_FLOAT64([1, 2]), face: true)
    end
    assert_raise(TypeError) do
      CAObject.new(CA_INT64, [2], parent: CA_FLOAT64([1, 2]), face: true, numeric: true)
    end
  end

  def test_an_object_storage_is_not_read_as_bytes
    assert_raise(TypeError) do
      CAObject.new(CA_FIXLEN, [1], bytes: 8, storage: CA_OBJECT,
                   parent: CA_OBJECT([1]), face: true)
    end
  end

  def test_explicit_storage_is_the_same_face_written_out
    p = CA_INT64([1, 2])
    f = CAObject.new(CA_FIXLEN, [2], bytes: 8, storage: CA_INT64,
                     parent: p, face: true)
    assert_equal :fixlen, f.data_type
    assert_equal [1, 2], f.to_a
  end
end
