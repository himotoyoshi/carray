# The value-hash discovery family turns some arrays into another array
# before it hashes them: a complex array into fixlen keys, a Face into its
# storage, the second operand into the first one's space.  Those arrays are
# made inside the method and must stay alive for the whole walk.  A
# collection in the middle of the walk used to free them -- "[BUG] tried to
# detach a detached array" or a segfault, depending on when it ran.
#
# GC.stress makes the timing deterministic.  Each case compares the answer
# under stress with the answer without it, for every member of the family
# and for each kind of array the hashing reads differently.

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

class TestDiscoveryGCStress < Test::Unit::TestCase

  def under_gc_stress
    was = GC.stress
    GC.stress = true
    begin
      yield
    ensure
      GC.stress = was
    end
  end

  def complex128
    a = CArray.new(:cmplx128, [7])
    a[] = [1, Complex(2, 1), 1, 0, 0, Complex(Float::NAN, 0), 5]
    a[6] = UNDEF
    a
  end

  def complex64
    complex128.to_type(:cmplx64)
  end

  def float64
    a = CA_FLOAT64([1.5, 2.0, 1.5, 0.0, -0.0, Float::NAN, 5.0])
    a[6] = UNDEF
    a
  end

  def object
    a = CA_OBJECT([1, "x", 1, :s, Rational(1, 3), "x", 5])
    a[6] = UNDEF
    a
  end

  def fixlen
    a = CA_FIXLEN(%w[ab cd ab ef gh cd ij], bytes: 2)
    a[6] = UNDEF
    a
  end

  def time
    CArray.time(%w[2024-01-01 2024-01-02 2024-01-01 2024-01-03], unit: :D)
  end

  def sources
    {
      "complex128" => [complex128, [1, Complex(2, 1)], CA_INT32([0])],
      "complex64"  => [complex64, [1, Complex(2, 1)], CA_INT32([0])],
      "float64"    => [float64, [1.5, 0.0], CA_INT32([5])],
      "object"     => [object, [1, "x"], CA_OBJECT([:s])],
      "fixlen"     => [fixlen, %w[ab ef], CA_FIXLEN(%w[cd], bytes: 2)],
      "time"       => [time, [time[0]], CArray.time(%w[2024-01-02], unit: :D)],
    }
  end

  # Every member, as one string (NaN != NaN, so compare what is printed).
  def answers (a, set1, set2)
    {
      is_in:           [a.is_in(set1).to_a, a.is_in(set2).to_a],
      unique:          a.unique.to_a,
      value_counts:    a.value_counts.map(&:to_a),
      nunique:         a.nunique,
      mask_duplicates: a.mask_duplicates.is_masked.to_a,
      intersection:    a.intersection(set1).to_a,
      difference:      a.difference(set2).to_a,
      union:           a.union(set2).to_a,
      locate_addr:     a.locate_addr(set1).to_a,
      categorize:      a.categorize.to_a,
    }.inspect
  end

  sources_for_names = %w[complex128 complex64 float64 object fixlen time]
  sources_for_names.each do |name|
    define_method("test_family_under_gc_stress_#{name}") do
      a, set1, set2 = sources.fetch(name)
      expected = answers(a, set1, set2)
      under_gc_stress do
        3.times do |k|
          assert_equal expected, answers(a, set1, set2), "#{name} round #{k}"
        end
      end
    end
  end

  # The original report: two calls in a row, the second with an operand of
  # another type that is converted before it becomes keys.
  def test_complex_is_in_repeated_under_gc_stress
    a = complex128
    first  = a.is_in([1, Complex(2, 1)]).to_a
    second = a.is_in(CA_INT32([0])).to_a
    under_gc_stress do
      20.times do
        assert_equal first,  a.is_in([1, Complex(2, 1)]).to_a
        assert_equal second, a.is_in(CA_INT32([0])).to_a
      end
    end
  end

  def test_numeric_mode_under_gc_stress
    a = CA_FLOAT64([1.0, 2.0, 2.0, 3.0, 3.0, Float::NAN])
    expected = [a.mode.to_a, a.is_mode.to_a]
    under_gc_stress do
      3.times { assert_equal expected, [a.mode.to_a, a.is_mode.to_a] }
    end
  end
end
