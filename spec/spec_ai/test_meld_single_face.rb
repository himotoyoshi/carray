# ----------------------------------------------------------------------------
#
#  spec_ai/test_meld_single_face.rb
#
#  CArray.meld of a single Face keeps the Face: the weld reads its storage,
#  and the Face is lifted back on top as it is for two or more parents.
#  CAFrame reaches this through a melt with one value column and through
#  CAFrame.meld of one frame.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMeldSingleFace < Test::Unit::TestCase

  FACES = {
    "CATime"         => -> { CArray.time(%w[2024-01-03 2024-01-05], unit: :D) },
    "CATimedelta"    => -> { CArray.time(%w[2024-01-03 2024-01-05], unit: :D) - CArray.time(%w[2024-01-01 2024-01-01], unit: :D) },
    "CACategorical"  => -> { CA_OBJECT(%w[x y x]).categorize },
    "CAConstString"  => -> { CArray.const_string(%w[pear apple]) },
    "CAString"       => -> { CArray.const_string(%w[pear apple]).to_string },
    "CAFixlenString" => -> { CArray.fixlen_string(%w[ab c]) },
  }

  FACES.each do |name, make|
    define_method("test_meld_one_#{name}") do
      a = make.call
      m = CArray.meld([a])
      assert_kind_of a.class, m
      assert_equal a.to_a.map(&:to_s), m.to_a.map(&:to_s)
    end
  end

  def test_melt_one_value_column_keeps_faces
    t = CArray.time(%w[2024-01-01 2024-01-02], unit: :D)
    id = CA_OBJECT(%w[x y]).categorize
    df = CAFrame.new("id" => id, "t" => t)
    m = df.melt(id: "id")
    assert_kind_of CACategorical, m["id"]
    assert_equal %w[x y], m["id"].to_a
    assert_kind_of CATime, m["value"]
    assert_equal %w[2024-01-01 2024-01-02], m["value"].to_a.map(&:to_s)
  end

  def test_frame_meld_of_one_frame_keeps_faces
    t = CArray.time(%w[2024-01-01 2024-01-02], unit: :D)
    df = CAFrame.new("t" => t, "s" => CArray.const_string(%w[a b]))
    m = CAFrame.meld(df)
    assert_kind_of CATime, m["t"]
    assert_equal %w[2024-01-01 2024-01-02], m["t"].to_a.map(&:to_s)
    assert_equal %w[a b], m["s"].to_a
  end

end
