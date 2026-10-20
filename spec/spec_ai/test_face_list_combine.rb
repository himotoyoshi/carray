require "test/unit"
require "carray"

# Combining arrays into one keeps a list of one Face class as that Face, and
# refuses a mix of Face and non-Face arrays, two Face classes, two or more
# of a Face whose values live in storage of its own (CAConstString), and
# Faces whose state differs (two time units).  Every way of combining
# answers the same, and names itself in the refusal.

class TestFaceListCombine < Test::Unit::TestCase

  def lists
    t_s  = CArray.time(["2024-01-01", "2024-01-02"], unit: :s)
    t_s2 = CArray.time(["2024-02-01", "2024-02-02"], unit: :s)
    t_d  = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    cs1  = CArray.const_string(["a", "bb"])
    cs2  = CArray.const_string(["cc", "d"])
    st1  = CArray.string(["a", "bb"])
    st2  = CArray.string(["cc", "d"])
    plain  = CA_INT64([1, 2])
    plain2 = CA_INT64([3, 4])
    {
      "time, same unit"     => [[t_s, t_s2], CATime],
      "time, other unit"    => [[t_s, t_d], /Face state mismatch/],
      "one time"            => [[t_s], CATime],
      "two const strings"   => [[cs1, cs2], /not portable/],
      "one const string"    => [[cs1], CAConstString],
      "two strings"         => [[st1, st2], CAString],
      "Face, then plain"    => [[t_s, plain], /cannot mix Face and non-Face/],
      "plain, then Face"    => [[plain, t_s], /cannot mix Face and non-Face/],
      "two Face classes"    => [[t_s, st1], /cannot mix Face and non-Face/],
      "plain"               => [[plain, plain2], nil],
    }
  end

  ENTRIES = {
    "CArray.stack"       => [->(l) { CArray.stack(l) },       "promote_list"],
    "CArray.meld"        => [->(l) { CArray.meld(l) },        "promote_list"],
    "CArray.concatenate" => [->(l) { CArray.concatenate(l) }, "promote_list"],
    "promote_list"       => [->(l) { CArray.promote_list(l).first }, "promote_list"],
    "CAStack.new"        => [->(l) { CAStack.new(l) },        "CAStack.new"],
    "CAMeld.new"         => [->(l) { CAMeld.new(l) },         "CAMeld.new"],
  }

  def test_every_way_of_combining_answers_the_same
    lists.each do |case_name, (list, want)|
      ENTRIES.each do |entry, (call, who)|
        label = "#{entry}: #{case_name}"
        case want
        when Regexp
          err = assert_raise(ArgumentError, label) { call.(list) }
          assert_match(want, err.message, label)
          assert(err.message.start_with?("#{who}: "), "#{label}: #{err.message}")
        when Class
          assert_kind_of(want, call.(list), label)
        else
          got = call.(list)
          assert_false(got.respond_to?(:face?) && got.face?, label)
        end
      end
    end
  end
end
