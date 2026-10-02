require "test/unit"
require "carray"
require "fiddle"

# The MemoryView producer answers three questions about an array:
# memory_view_available?, memory_view_reject_reason and the export itself
# (wrap_memory_view / from_memory_view / any other consumer).  They must
# agree for every kind of array, Faces included: an array that says it can
# be exported is exported, and one that cannot says why.
#
# A Face is exported only when its storage bytes carry its values on their
# own (CARecord as a T{...} struct, CAFixlenString as "Ns").  A Face whose
# values need the Face to be read (a time needs its unit, a categorical its
# labels, a const string its buffer) is refused; its storage is exported
# by asking for the storage.

class TestMemoryViewExportMatrix < Test::Unit::TestCase

  def base
    CArray.float64(4, 6).seq
  end

  def record
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    r = CARecord.new(s, 3)
    r["a"][] = CArray.int32(3).seq(1)
    r["b"][] = CArray.float64(3).seq(1.5)
    r
  end

  def cases
    b = base
    {
      "entity"         => b,
      "CScalar"        => CScalar.float64 { 3.5 },
      "CARefer"        => b.refer(CA_INT64, [4, 6]),
      "CABlock rows"   => b[1..2, nil],
      "CABlock cols"   => b[nil, 1..3],
      "CATranspose"    => b.transpose,
      "CARepeat"       => CArray.float64(3).seq[4, :%],
      "CAStride"       => b.as_strided(shape: [2, 2], strides: [16, 8]),
      "CASelect"       => b[b > 5],
      "CAGrid"         => b[CArray.int32(2) { [0, 2] }, nil],
      "CASelectAxis"   => b[CArray.boolean(4) { [1, 0, 1, 0] }, nil],
      "CAShift"        => b.shift(1, 0),
      "CARoll"         => b.roll(1, 0),
      "CAWindow"       => b.window(0..5, 0..3),
      "CATile"         => b.tile(2, 1),
      "CAStack"        => CArray.stack([b, b]),
      "CAMeld"         => CArray.meld([b, b]),
      "CARemap"        => b.sort(axis: 1),
      "CABinOp"        => b.lazy + b,
      "masked"         => b.copy.tap { |x| x[0, 0] = UNDEF },
      "CARecord"       => record,
      "CARecord slice" => record[1..2],
      "CAFixlenString" => CArray.fixlen_string(["ab", "cd", "ef"]),
      "CATime"         => CArray.time(["2024-01-01", "2024-01-02"]),
      "CATimedelta"    => CArray.time(["2024-01-02"]) - CArray.time(["2024-01-01"]),
      "CACategorical"  => CACategorical.from_codes(CArray.uint8(3) { [0, 1, 0] }, ["a", "b"]),
      "CAConstString"  => CArray.const_string(["a", "bb"]),
    }
  end

  # Fiddle asks for a contiguous view; CArray's own consumer asks for
  # strides but does not read T{...} yet.  Either one getting the view is
  # an export.
  def exported?(v)
    Fiddle::MemoryView.new(v).release
    true
  rescue ArgumentError
    begin
      CArray.wrap_memory_view(v)
      true
    rescue ArgumentError
      false
    end
  end

  def test_available_reason_and_export_agree
    cases.each do |name, v|
      avail  = CArray.memory_view_available?(v)
      reason = CArray.memory_view_reject_reason(v)
      assert_equal(avail, exported?(v), "#{name}: available? vs export")
      assert_equal(avail, reason.nil?, "#{name}: available? vs reject_reason (#{reason.inspect})")
    end
  end

  def test_no_export_raises_anything_but_argument_error
    cases.each do |name, v|
      [-> { CArray.wrap_memory_view(v) },
       -> { CArray.from_memory_view(v) },
       -> { Fiddle::MemoryView.new(v).release }].each do |f|
        begin
          f.()
        rescue ArgumentError
        rescue => e
          flunk("#{name}: #{e.class}: #{e.message}")
        end
      end
    end
  end

  def test_record_exports_as_struct
    r = record
    assert_true(CArray.memory_view_available?(r))
    m = Fiddle::MemoryView.new(r)
    assert_equal("T{i:a:d:b:}", m.format)
    assert_equal([3], m.shape)
    assert_equal(r.parent.copy.dump_binary, m.to_s)
    m.release
  end

  def test_record_slice_exports_the_slice
    r = record
    m = Fiddle::MemoryView.new(r[1..2])
    assert_equal(r.parent[1..2].copy.dump_binary, m.to_s)
    m.release
  end

  def test_fixlen_string_exports_as_bytes
    t = CArray.fixlen_string(["ab", "cd", "ef"])
    m = Fiddle::MemoryView.new(t)
    assert_equal("2s", m.format)
    m.release
    assert_equal(["ab", "cd", "ef"], CArray.from_memory_view(t).to_a)
  end

  def test_faces_whose_storage_does_not_carry_the_values_are_refused
    c = cases
    %w[CATime CATimedelta CACategorical CAConstString].each do |name|
      assert_false(CArray.memory_view_available?(c[name]), name)
      assert_match(/Face/, CArray.memory_view_reject_reason(c[name]), name)
    end
  end

  def test_the_storage_of_a_refused_face_is_exported_when_asked_for
    t = CArray.time(["2024-01-01", "2024-01-02"])
    assert_equal(t.ticks.to_a, CArray.from_memory_view(t.ticks).to_a)
    k = CACategorical.from_codes(CArray.uint8(3) { [0, 1, 0] }, ["a", "b"])
    assert_equal([0, 1, 0], CArray.from_memory_view(k.codes).to_a)
  end

  def test_reject_reason_points_at_copy
    b = base
    reason = CArray.memory_view_reject_reason(b[b > 5])
    assert_match(/\.copy/, reason)
    assert_no_match(/to_ca|from_memory_view/, reason)
    assert_equal(b[b > 5].to_a, CArray.wrap_memory_view(b[b > 5].copy).to_a)
  end

end
