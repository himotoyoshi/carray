require "test/unit"
require "carray"

# int64 / uint64 to float32 / cmplx64 goes through double everywhere: a
# conversion, a store, a mixed-type operation, a lazy expression and the
# body a plan hands to an evaluator.  A value past 2**53 then has one answer
# wherever it sits in the array (a one-step conversion rounds once where the
# loop stays scalar and twice where it is vectorised through double), and
# that answer is the one a Ruby Integer stored into a float32 cell gets.
class TestInt64ToFloat32ThroughDouble < Test::Unit::TestCase

  V = 2**60 + 2**36 + 1      # just past a float32 midpoint once it is exact
  U = 2**63 + 2**39 + 1

  def bits (a)
    a.to_a.flatten.map { |x| [x.is_a?(Complex) ? x.real : x].pack("e").unpack1("V") }.uniq
  end

  def through_double (v)
    [[v.to_f].pack("e").unpack1("V")]
  end

  def test_every_route_gives_the_answer_through_double
    n = 40
    {
      "to_type"          => -> { CArray.int64(n) { V }.to_type(:float32) },
      "store an Integer" => -> { a = CArray.float32(n); a[] = V; a },
      "store an array"   => -> { a = CArray.float32(n); a[] = CArray.int64(n) { V }; a },
      "lazy"             => -> { CArray.int64(n) { V }.lazy.to_type(:float32).copy },
      "mixed binop"      => -> { CArray.float32(n) { 0 } + CArray.int64(n) { V } },
      "transposed"       => -> { CArray.int64(8, 5) { V }.transpose.to_type(:float32) },
      "cmplx64"          => -> { CArray.int64(n) { V }.to_type(:cmplx64) },
    }.each do |name, make|
      assert_equal through_double(V), bits(make.()), name
    end
    assert_equal through_double(U), bits(CArray.uint64(n) { U }.to_type(:float32))
  end

  def test_the_plan_body_goes_through_double
    assert_equal "(#2) = (float)(double)(#1);",
                 CArray.__kernel_body__("monop", "cast_float32", "int64")
    assert_equal "(#2) = (cmplx64_t)(double)(#1);",
                 CArray.__kernel_body__("monop", "cast_cmplx64", "uint64")
    assert_equal "(#2) = (float)(#1);",
                 CArray.__kernel_body__("monop", "cast_float32", "int32")
  end
end
