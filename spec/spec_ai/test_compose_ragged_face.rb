# Regression: CArray.concatenate / mosaic (eager ragged paste) must
# preserve fixlen byte width and Face identity, mirroring CArray.stack.
#
# Before the __ragged_paste rewrite (2026-06-24), the eager ragged path
# derived the output element width only from a data_class (= CARecord), so:
#   - plain fixlen arrays were rebuilt with bytes == 0  (data corruption)
#   - numeric Faces (CATime / CATimedelta) were demoted to their
#     storage type, losing Face identity
# CARecord happened to work via the data_class special-case.  The rewrite
# routes everything through promote_list (homogeneity gate) + face_lift,
# matching the uniform view-default path (CArray.stack / meld).

require 'test/unit'
require 'carray'

class TestComposeRaggedFace < Test::Unit::TestCase

  # ---------------- plain fixlen (no Face) ----------------

  def test_concatenate_fixlen_preserves_bytes
    a = CArray.new(:fixlen, [2], bytes: 4); a[0] = "abcd"; a[1] = "efgh"
    b = CArray.new(:fixlen, [2], bytes: 4); b[0] = "ijkl"; b[1] = "mnop"
    r = CArray.concatenate([a, b], axis: 0)
    assert_equal :fixlen, r.data_type
    assert_equal 4, r.bytes
    assert_equal ["abcd", "efgh", "ijkl", "mnop"], r.to_a
  end

  def test_mosaic_fixlen_preserves_bytes
    a = CArray.new(:fixlen, [1], bytes: 3); a[0] = "AAA"
    b = CArray.new(:fixlen, [1], bytes: 3); b[0] = "BBB"
    r = CArray.mosaic([a, b], [2], axis: 0)
    assert_equal 3, r.bytes
    assert_equal ["AAA", "BBB"], r.to_a
  end

  # ---------------- numeric Face (CATime) ----------------

  def test_concatenate_datetime_preserves_face
    a = CArray.time(2) { |i| "2020-01-0#{i + 1}" }
    b = CArray.time(2) { |i| "2020-02-0#{i + 1}" }
    r = CArray.concatenate([a, b], axis: 0)
    assert_kind_of CATime, r
    assert_equal 8, r.bytes
    # storage values round-trip (int64 seconds since epoch)
    assert_equal a.parent.to_a + b.parent.to_a, r.parent.to_a
  end

  def test_mosaic_datetime_preserves_face
    a = CArray.time(1) { |i| "2020-01-01" }
    b = CArray.time(1) { |i| "2020-01-02" }
    r = CArray.mosaic([a, b], [2], axis: 0)
    assert_kind_of CATime, r
    assert_equal 8, r.bytes
  end

  # ---------------- CARecord (data_class Face) ----------------

  def test_concatenate_carecord_preserves_data_class
    klass = CArray.struct { int32 :x; int32 :y }
    a = CARecord.new(klass, 2)
    a["x"][0] = 1; a["y"][0] = 2; a["x"][1] = 3; a["y"][1] = 4
    b = CARecord.new(klass, 2)
    b["x"][0] = 5; b["y"][0] = 6; b["x"][1] = 7; b["y"][1] = 8
    r = CArray.concatenate([a, b], axis: 0)
    assert_kind_of CARecord, r
    assert_equal klass, r.data_class
    assert_equal [1, 3, 5, 7], r["x"].to_a
    assert_equal [2, 4, 6, 8], r["y"].to_a
  end

  # ---------------- plain numeric (regression: unchanged) ----------------

  def test_concatenate_numeric_unchanged
    a = CArray.int32(2) { |i| i + 1 }
    b = CArray.int32(2) { |i| i + 3 }
    r = CArray.concatenate([a, b], axis: 0)
    assert_equal :int32, r.data_type
    assert_equal [1, 2, 3, 4], r.to_a
  end

  # ---------------- heterogeneity is rejected by promote_list ----------------

  def test_concatenate_mixed_face_nonface_rejected
    a = CArray.time(2) { |i| i }
    b = CArray.int64(2) { |i| i }
    assert_raise(ArgumentError) do
      CArray.concatenate([a, b], axis: 0)
    end
  end

  # ---------------- resize: bytes + Face preservation ----------------

  def test_resize_fixlen_preserves_bytes
    a = CArray.new(:fixlen, [2], bytes: 3); a[0] = "abc"; a[1] = "def"
    r = a.resize(4)
    assert_equal 3, r.bytes
    # new area = zero bytes (3 NULs per cell)
    assert_equal ["abc", "def", "\x00\x00\x00", "\x00\x00\x00"], r.to_a
  end

  def test_resize_fixlen_undef_masks_new_area
    a = CArray.new(:fixlen, [2], bytes: 3); a[0] = "abc"; a[1] = "def"
    r = a.resize(4, fill_value: UNDEF)
    assert_equal [false, false, true, true], r.is_masked.to_a
  end

  def test_resize_carecord_preserves_data_class
    klass = CArray.struct { int32 :x }
    rec = CARecord.new(klass, 2); rec["x"][0] = 1; rec["x"][1] = 2
    r = rec.resize(4)
    assert_kind_of CARecord, r
    assert_equal klass, r.data_class
    assert_equal [1, 2, 0, 0], r["x"].to_a
  end

  def test_resize_datetime_preserves_face
    strs = CArray.object(2) { |i| ["2020-01-01", "2020-01-02"][i] }
    dt = CArray.time(strs, unit: :D)
    r = dt.resize(4)
    assert_kind_of CATime, r
    assert_equal 8, r.bytes
    assert_equal dt.parent.to_a + [0, 0], r.parent.to_a
  end

  def test_resize_numeric_unchanged
    a = CArray.int32(2) { |i| i + 1 }
    assert_equal [1, 2, 9, 9], a.resize(4, fill_value: 9).to_a
  end

  # ---------------- insert_block: bytes + Face preservation ----------------

  def test_insert_block_fixlen_preserves_bytes
    a = CArray.new(:fixlen, [3], bytes: 3); 3.times { |i| a[i] = ("a".ord + i).chr * 3 }
    r = a.insert_block([1], [2])
    assert_equal 3, r.bytes
    assert_equal ["aaa", "\x00\x00\x00", "\x00\x00\x00", "bbb", "ccc"], r.to_a
  end

  def test_insert_block_carecord_preserves_data_class
    klass = CArray.struct { int32 :x }
    rec = CARecord.new(klass, 3); 3.times { |i| rec["x"][i] = i + 1 }
    r = rec.insert_block([1], [1])
    assert_kind_of CARecord, r
    assert_equal klass, r.data_class
    assert_equal [1, 0, 2, 3], r["x"].to_a
  end
end
