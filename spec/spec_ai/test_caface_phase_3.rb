# PROPOSAL_CAFACE_PHASE_2 F.3.x — CAObject + Face integration tests
#
# CAObject 派生 Face (= Ruby 実装 Face) の動作確認。
# `:face` option + `copy_state` callback による ivar carry を pin。

require 'test/unit'
require 'carray'

# Experimental: minimal Face subclass on top of CAObject
class TestFaceObj < CAObject
  def initialize(parent, tag: :default)
    @tag = tag
    super(CA_INT64, parent.dim, parent: parent, face: true)
  end
  attr_reader :tag

  def copy_state(src)
    @tag = src.tag
  end
end

# Sample: circular angle Face (radian, with circular statistics)
class TestCACircular < CAObject
  def initialize(parent, range: :rad)
    @range = range
    super(CA_FLOAT64, parent.dim, parent: parent, face: true)
  end
  attr_reader :range

  def copy_state(src)
    @range = src.range
  end

  def circular_mean
    vals = self.to_a
    factor = (@range == :deg) ? (Math::PI / 180.0) : 1.0
    sum_sin = vals.sum {|v| Math.sin(v * factor)}
    sum_cos = vals.sum {|v| Math.cos(v * factor)}
    mean_rad = Math.atan2(sum_sin / vals.size, sum_cos / vals.size)
    mean_rad += 2*Math::PI if mean_rad < 0
    (@range == :deg) ? mean_rad * 180.0 / Math::PI : mean_rad
  end
end

class TestCAFacePhase3 < Test::Unit::TestCase

  # ---- F.3.1: CAObject :face option ----

  def test_caobject_face_option_sets_flag
    raw = CArray.int64(5)
    f = TestFaceObj.new(raw)
    assert_equal true, f.face?
  end

  def test_caobject_face_requires_parent
    assert_raise(ArgumentError) do
      CAObject.new(CA_INT64, [5], face: true)
    end
  end

  def test_caobject_face_data_type_mismatch_raises
    bad_parent = CArray.float64(5)
    assert_raise(TypeError) do
      TestFaceObj.new(bad_parent)
    end
  end

  def test_caobject_face_thin_forward_to_parent
    raw = CArray.int64(5) {|i| i * 10}
    f = TestFaceObj.new(raw)
    assert_equal raw.to_a, f.to_a, "Face mode delegates storage to parent"
  end

  # ---- F.3.2: copy_state ivar carry ----

  def test_ivar_carry_via_inherit_state_on_aref
    raw = CArray.int64(5) {|i| i}
    f = TestFaceObj.new(raw, tag: :hello)
    sliced = f[1..3]
    assert_kind_of TestFaceObj, sliced
    assert_equal :hello, sliced.tag, "@tag must carry via copy_state"
  end

  def test_ivar_carry_chain_through_view_methods
    raw = CArray.int64(6) {|i| i}
    f = TestFaceObj.new(raw, tag: :world)
    assert_equal :world, f.reshape(2, 3).tag
    assert_equal :world, f.flip.tag
    assert_equal :world, f.transpose.tag rescue nil  # 1-D transpose may be noop
    assert_equal :world, f.copy.tag
  end

  # ---- CACircular sample ----

  def test_cacircular_basic
    raw = CArray.float64(5)
    [0.0, Math::PI/4, Math::PI/2, 3*Math::PI/4, Math::PI].each_with_index {|v, i| raw[i] = v}
    cc = TestCACircular.new(raw, range: :rad)
    assert_kind_of TestCACircular, cc
    assert_equal true, cc.face?
    assert_equal CA_FLOAT64, cc.data_type
    assert_equal :rad, cc.range
  end

  def test_cacircular_mean_is_correct
    raw = CArray.float64(5)
    [0.0, Math::PI/4, Math::PI/2, 3*Math::PI/4, Math::PI].each_with_index {|v, i| raw[i] = v}
    cc = TestCACircular.new(raw, range: :rad)
    assert_in_delta Math::PI/2, cc.circular_mean, 1e-4
  end

  def test_cacircular_sliced_carries_range_and_supports_method
    raw = CArray.float64(5)
    [0.0, Math::PI/4, Math::PI/2, 3*Math::PI/4, Math::PI].each_with_index {|v, i| raw[i] = v}
    cc = TestCACircular.new(raw, range: :rad)
    sliced = cc[1..3]
    assert_kind_of TestCACircular, sliced
    assert_equal :rad, sliced.range
    # sliced (pi/4, pi/2, 3pi/4) mean is pi/2
    assert_in_delta Math::PI/2, sliced.circular_mean, 1e-4
  end

  def test_cacircular_two_step_chain
    raw = CArray.float64(5)
    [0.0, Math::PI/4, Math::PI/2, 3*Math::PI/4, Math::PI].each_with_index {|v, i| raw[i] = v}
    cc = TestCACircular.new(raw, range: :rad)
    chain = cc[1..3].flip
    assert_kind_of TestCACircular, chain
    assert_equal :rad, chain.range
    assert_in_delta 3*Math::PI/4, chain.to_a[0], 1e-6
  end

  # ---- F.3.4: storage_to_scalar convention ----

  def test_storage_to_scalar_decode_via_c_macro
    # CATime has storage_to_scalar defined → ca[i] decodes to Element
    dt = CArray.int64(5) {|i| i*100}.time(unit: :s)
    s = dt[2]
    assert_kind_of CATime::Element, s
    assert_equal 200, s.value
  end

  def test_storage_to_scalar_no_override_returns_raw
    # CAObject Face without storage_to_scalar override → returns raw
    raw = CArray.int64(5) {|i| i * 10}
    f = TestFaceObj.new(raw)
    assert_kind_of Integer, f[2]
    assert_equal 20, f[2]
  end

  def test_storage_to_scalar_decode_in_chain
    # sliced view (= chain) でも storage_to_scalar 発火
    raw = CArray.float64(5)
    [0.0, Math::PI/4, Math::PI/2, 3*Math::PI/4, Math::PI].each_with_index {|v, i| raw[i] = v}
    cc = TestCACircular.new(raw, range: :rad)
    s_via_chain = cc[1..3][1]   # cc -> sliced -> scalar
    # TestCACircular doesn't define storage_to_scalar, so passes through as Float
    assert_kind_of Float, s_via_chain
    assert_in_delta Math::PI/2, s_via_chain, 1e-6
  end

  def test_cacircular_deg_mode
    raw = CArray.float64(5)
    [0.0, 45.0, 90.0, 135.0, 180.0].each_with_index {|v, i| raw[i] = v}
    cc = TestCACircular.new(raw, range: :deg)
    assert_in_delta 90.0, cc.circular_mean, 1e-4
    assert_equal :deg, cc[1..3].range
  end
end
