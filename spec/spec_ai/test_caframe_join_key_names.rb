# frozen_string_literal: true

require "test/unit"
require "carray"

# join / join_asof take a Hash of this frame's key name to the other's.
class TestCAFrameJoinKeyNames < Test::Unit::TestCase
  def left
    CAFrame.new("station" => CA_OBJECT(%w[A B C]), "t" => CA_FLOAT64([1, 2, 3]))
  end

  def right
    CAFrame.new("code" => CA_OBJECT(%w[A B D]), "name" => CA_OBJECT(%w[Alpha Bravo Delta]))
  end

  def test_left
    out = left.join(right, on: { "station" => "code" })
    assert_equal %w[station t name], out.column_names
    assert_equal ["Alpha", "Bravo", UNDEF], out["name"].to_a
  end

  def test_the_same_as_renaming_first
    a = left.join(right, on: { "station" => "code" }, how: :outer)
    b = left.join(right.rename("code" => "station"), on: "station", how: :outer)
    assert_equal b.column_names, a.column_names
    b.column_names.each { |n| assert_equal b[n].to_a, a[n].to_a, n }
  end

  def test_a_right_column_named_as_the_left_key_is_suffixed
    r = right.append("station", CA_OBJECT(%w[x y z]))
    out = left.join(r, on: { "station" => "code" })
    assert_equal %w[station t name station_right], out.column_names
    assert_equal ["A", "B", "C"], out["station"].to_a
  end

  def test_several_keys_and_semi
    l = left.append("d", CA_INT32([1, 1, 2]))
    r = right.append("day", CA_INT32([1, 2, 2]))
    assert_equal ["Alpha", UNDEF, UNDEF],
                 l.join(r, on: { "station" => "code", "d" => "day" })["name"].to_a
    assert_equal %w[A B], left.join(right, on: { "station" => "code" }, how: :semi)["station"].to_a
  end

  def test_join_asof
    l = CAFrame.new("time" => CA_FLOAT64([1, 2, 3]), "s" => CA_OBJECT(%w[A A B]))
    r = CAFrame.new("tt" => CA_FLOAT64([0.5, 1.5, 2.5]), "code" => CA_OBJECT(%w[A A A]),
                    "v" => CA_FLOAT64([10, 20, 30]))
    out = l.join_asof(r, on: { "time" => "tt" }, by: { "s" => "code" })
    assert_equal %w[time s v], out.column_names
    assert_equal [10.0, 20.0, UNDEF], out["v"].to_a
  end

  def test_refusals
    assert_raise(KeyError) { left.join(right, on: { "station" => "nope" }) }
    assert_raise(TypeError) { left.join(right, on: { station: "code" }) }
    assert_raise(ArgumentError) { left.join(right, on: {}) }
    l = CAFrame.new("time" => CA_FLOAT64([1]), "s" => CA_OBJECT(%w[A]))
    assert_raise(ArgumentError) { l.join_asof(l, on: { "time" => "time", "s" => "s" }) }
  end
end
