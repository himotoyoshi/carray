# frozen_string_literal: true
#
# Inspecting a Face array.
#
# The formatter has to follow what a cell decodes to, not the storage
# data_type.  A Face with a storage_to_scalar hook hands back a surface value
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
    s = td.inspect
    assert_match(/CATimedelta/, s)
    assert_match(/CATimedelta::Element/, s)
  end

  def test_timedelta_inspect_with_mask
    td = CA_INT64([1, 2, 3]).timedelta(unit: :D)
    td[1] = UNDEF
    s = td.inspect
    assert_match(/mask=1/, s)
    assert_match(/_/, s)               # the masked cell prints as _
    assert_match(/CATimedelta::Element/, s)
  end

  def test_timedelta_inspect_all_masked
    td = CA_INT64([1, 2]).timedelta(unit: :D)
    td[] = UNDEF
    assert_match(/mask=2/, td.inspect)
  end

  # --- the sibling Faces keep their existing rendering ---------------------

  def test_time_inspect
    t = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    s = t.inspect
    assert_match(/CATime/, s)
    assert_match(/CATime::Element/, s)
    t[0] = UNDEF
    assert_match(/mask=1/, t.inspect)
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
