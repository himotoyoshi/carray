# frozen_string_literal: true
#
# Inspecting a Face array.
#
# The formatter has to follow what a cell decodes to, not the storage
# data_type.  A Face with a storage_to_element hook hands back a surface value
# -- an Element, a String, a category label -- which the storage formatter
# cannot render: an int64-backed CATimedelta used to raise TypeError out of
# the "%i" formatter.  Faces without the hook (CAString) store their surface
# value directly and keep the storage formatter.

require "test/unit"
require "carray"

class TestFaceInspect < Test::Unit::TestCase

  # --- the reported hole: an integer-storage Face -------------------------

  def test_timedelta_inspect
    td = CA_INT64([1, 2, 3]).timedelta(unit: :D)
    # NonNumeric surface (the FIXLEN gate); the int64 is the storage.
    assert_equal :fixlen, CArray.data_type_name(td.data_type).to_sym
    assert_equal :int64, CArray.data_type_name(td.parent.data_type).to_sym
    assert_equal "<CATimedelta[D](3): elem=3 mem=24b\n[ 1D, 2D, 3D ]>", td.inspect
  end

  def test_timedelta_inspect_with_mask
    td = CA_INT64([1, 2, 3]).timedelta(unit: :D)
    td[1] = UNDEF
    s = td.inspect
    assert_match(/mask=1/, s)
    assert_match(/\[ 1D, _, 3D \]/, s)   # the masked cell prints as _
  end

  def test_timedelta_inspect_all_masked
    td = CA_INT64([1, 2]).timedelta(unit: :D)
    td[] = UNDEF
    assert_match(/mask=2/, td.inspect)
  end

  # --- the sibling Faces keep their existing rendering ---------------------

  # A time array names its tick, which the storage type (fixlen[8]) does
  # not tell, and writes each cell as Element#to_s does, without the
  # Element wrapper or the tick count.
  def test_time_inspect
    t = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    assert_equal "<CATime[D](2): elem=2 mem=16b\n[ 2024-01-01, 2024-01-02 ]>", t.inspect
    t[0] = UNDEF
    assert_match(/mask=1/, t.inspect)
    assert_match(/\[ _, 2024-01-02 \]/, t.inspect)
    assert_match(/\A<CATime\[M\]\(1\)/, CArray.time(["2024-03"], unit: :M).inspect)
    assert_match(/\A<CATime\[10 m\]\(1\)/, CArray.time(["2024-01-01 00:10"], unit: "10 minutes").inspect)
    assert_match(/\A<CATimedelta\[10 m\]\(2\).*\n\[ 10m, 20m \]/,
                 CA_INT64([1, 2]).timedelta(unit: "10 minutes").inspect)
  end

  # The digits of a second are the fewest any cell needs, the same in every
  # cell; the unit is in the label, so a whole-second us array has none.
  def test_time_inspect_second_digits
    whole = CArray.time(["2024-12-01T00:01", "2024-12-01T00:02"], unit: :us)
    assert_match(/\[ 2024-12-01T00:01:00Z, 2024-12-01T00:02:00Z \]/, whole.inspect)
    half = CArray.time(["2024-12-01T00:00:00.5", "2024-12-01T00:00:01"], unit: :ns)
    assert_match(/\[ 2024-12-01T00:00:00.500Z, 2024-12-01T00:00:01.000Z \]/, half.inspect)
    fine = CArray.time(["2024-12-01T00:00:00.123456789"], unit: :ns)
    assert_match(/2024-12-01T00:00:00.123456789Z/, fine.inspect)
    quarter = CArray.time(["2024-12-01 00:00:00.25"], unit: "250 milliseconds")
    assert_match(/2024-12-01T00:00:00.250Z/, quarter.inspect)
    # A masked cell does not ask for digits, whatever its storage holds.
    masked = CArray.time(["2024-12-01T00:00:00.5", "2024-12-01T00:00:01"], unit: :ms)
    masked[0] = UNDEF
    assert_match(/\[ _, 2024-12-01T00:00:01Z \]/, masked.inspect)
    # The cells past the abbreviation count too.
    long = CArray.time(Array.new(20) { |i| "2024-12-01T00:00:#{format('%02d', i)}" } +
                       ["2024-12-01T00:01:00.001"], unit: :us)
    assert_match(/2024-12-01T00:00:00\.000Z/, long.inspect)
  end

  def test_string_faces_inspect_as_strings
    assert_match(/"ab"/, CArray.fixlen_string(["ab", "cd"]).inspect)
    assert_match(/"a"/,  CArray.const_string(["a", "bb"]).inspect)
    assert_match(/"a"/,  CArray.string(["a", "bb"]).inspect)   # no decode hook
  end

  # --- a plain array is untouched by the Face branch -----------------------

  def test_plain_arrays_unaffected
    assert_match(/\[ 1, 2, 3 \]/, CA_INT64([1, 2, 3]).inspect)
    assert_match(/\[ 1, 0 \]/,    CA_BOOLEAN([1, 0]).inspect)
    assert_match(/1\.5/,          CA_FLOAT64([1.5]).inspect)
  end

end
