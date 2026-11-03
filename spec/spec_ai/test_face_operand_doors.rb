# frozen_string_literal: true
#
# Doors a Face reaches through a method that was not written with it in mind:
# the receiver check of face_lift, the order of then_else's branches, refer to
# another type, the views that lift, the word forms of the operators, a Ruby
# object operand, CArray.select, and the picks by order.

require "test/unit"
require "carray"

class TestFaceOperandDoors < Test::Unit::TestCase
  Rec = CArray.struct(order_by: [:a]) { int32 :a; int32 :b }

  def days
    CArray.time(%w[2024-01-01 2024-01-02], unit: :D)
  end

  def hours
    CArray.time(%w[2024-01-01T06 2024-01-02T12], unit: :h)
  end

  def seconds (*v)
    CA_INT64(v).timedelta(unit: :s)
  end

  def fix (values, bytes)
    CArray.fixlen_string(values, bytes: bytes)
  end

  def record
    r = CARecord.new(Rec, 2)
    r["a"][] = CA_INT32([1, 2])
    r["b"][] = CA_INT32([3, 4])
    r
  end

  def cond
    CA_BOOLEAN([true, false])
  end

  def texts (a)
    a.to_a.map(&:to_s)
  end

  # ---- face_lift --------------------------------------------------------

  def test_face_lift_refuses_cells_of_another_type
    assert_raise(ArgumentError) { CA_FLOAT64([1.0, 2.0]).face_lift(CArray.string(%w[a b])) }
    assert_raise(ArgumentError) { CA_INT8([1, 2]).face_lift(days) }
  end

  def test_face_lift_refuses_a_face_of_another_cell_type
    names = CArray.string(%w[a b])
    assert_raise(ArgumentError) { names.face_lift(CArray.fixlen_string(%w[s1 s2], bytes: 4)) }
    assert_raise(ArgumentError) { names.face_lift(CArray.const_string(%w[x y])) }
    assert_equal(:object, names.data_type)
    assert_equal(%w[a b], names.to_a)
  end

  def test_face_lift_takes_the_storage_type_and_a_face
    lifted = CA_INT64([1, 2]).face_lift(CA_INT64([3, 4]).time(unit: :s))
    assert_kind_of(CATime, lifted)
    assert_kind_of(CATime, days.face_lift(days))
  end

  # ---- then_else --------------------------------------------------------

  def test_then_else_keeps_the_wider_fixlen_whichever_branch_it_is
    short = fix(%w[ab cd], 2)
    long  = fix(%w[abcdefgh ijklmnop], 8)
    assert_equal(%w[ab ijklmnop], cond.then_else(short, long).to_a)
    assert_equal(%w[abcdefgh cd], cond.then_else(long, short).to_a)
    assert_equal(%w[abcdefgh cd], cond.then_else("abcdefgh", short).to_a)
    assert_equal(%w[ab abcdefgh], cond.then_else(short, "abcdefgh").to_a)
  end

  def test_then_else_meets_time_units_whichever_branch_is_finer
    a = cond.then_else(hours, days)
    b = cond.not.then_else(days, hours)
    assert_equal("h", a.unit.to_s[/h/])
    assert_equal(texts(a), texts(b))
    assert_equal("2024-01-01T06:00:00Z", cond.then_else(hours[0], days)[0].to_s)
    assert_equal("2024-01-05T07:00:00Z", cond.then_else(Time.utc(2024, 1, 5, 7), days)[0].to_s)
  end

  def test_then_else_of_one_unit_stays_in_it
    r = cond.then_else(days, days[1])
    assert_kind_of(CATime, r)
    assert_equal(%w[2024-01-01 2024-01-02], texts(r))
  end

  # ---- refer ------------------------------------------------------------

  def test_refer_refuses_another_type
    assert_raise(TypeError) { days.refer(:int8, [16]) }
    assert_raise(TypeError) { record.refer(:int32, [4]) }
    assert_raise(TypeError) { fix(%w[ab cd], 2).refer(:int8, [4]) }
  end

  def test_refer_reads_the_face_in_its_own_types
    t = days
    assert_kind_of(CATime, t.refer(t.data_type, [2]))
    assert_kind_of(CATime, t.refer(:int64, [2]))
    assert_equal(%w[2024-01-01 2024-01-02], texts(t.refer(:int64, [2])))
    assert_equal(16, t.parent.refer(:int8, [16]).elements)
  end

  # ---- views ------------------------------------------------------------

  def faces
    {
      "delta"  => seconds(1, 2, 3, 4),
      "string" => CArray.string(%w[a b c d]),
      "fixlen" => fix(%w[a b c d], 1),
      "const"  => CArray.const_string(%w[a b c d]),
      "cat"    => CA_OBJECT(%w[a b c d]).categorize,
    }
  end

  def test_farray_keeps_the_face
    faces.merge("time" => CArray.time(%w[2024-01-01 2024-01-02 2024-01-03 2024-01-04], unit: :D)).each { |name, a|
      v = a.reshape(2, 2)
      assert_equal(a.class, v.farray.class, name)
      assert_equal(v[1, 0].to_s, v.farray[0, 1].to_s, name)
    }
  end

  def test_grid_keeps_the_face
    faces.each { |name, a|
      g = a.grid(CA_INT32([2, 0]))
      assert_equal(a.class, g.class, name)
      assert_equal([a[2].to_s, a[0].to_s], texts(g), name)
      assert_equal(a[2].to_s, a.grid(2).to_s, name)
    }
  end

  def test_grid_by_a_boolean_axis_keeps_the_face
    a = seconds(1, 2, 3, 4, 5, 6).reshape(2, 3)
    g = a.grid(nil, CA_BOOLEAN([true, false, true]))
    assert_kind_of(CATimedelta, g)
    assert_equal(%w[1s 3s 4s 6s], g.flatten.to_a.map(&:to_s))
  end

  def test_write_through_a_lifted_grid_reaches_the_root
    a = seconds(1, 2, 3)
    a.grid(CA_INT32([0, 2]))[] = a[1]
    assert_equal(%w[2s 2s 2s], texts(a))
  end

  # ---- word forms -------------------------------------------------------

  def test_word_forms_are_the_operators
    t = seconds(4, 6)
    assert_equal(texts(t + t), texts(t.add(t)))
    assert_equal(texts(t - t), texts(t.sub(t)))
    assert_equal(texts(t * 2), texts(t.mul(2)))
    assert_equal(texts(t / 2), texts(t.div(2)))
    assert_equal((t / t).to_a, t.div(t).to_a)
    assert_equal(texts(-t), texts(t.neg))
    assert_kind_of(CATimedelta, t.add(t[0]))
    d = days
    assert_equal(texts(d + seconds(86400, 0)), texts(d.add(seconds(86400, 0))))
    assert_equal(texts(d - d), texts(d.sub(d)))
    assert_kind_of(CATimedelta, d.sub(d[0]))
  end

  # ---- a Ruby object operand --------------------------------------------

  def test_a_face_does_not_go_down_to_objects_to_meet_a_ruby_object
    t = seconds(1, 2)
    r = record
    %w[and or xor rcp_mul].each { |op|
      assert_raise(CArray::DataTypeError, op) { t.public_send(op, t[0]) }
      assert_raise(CArray::DataTypeError, op) { r.public_send(op, r[0]) }
    }
    %w[pmax pmin maximum minimum fmax fmin].each { |op|
      assert_raise(CArray::DataTypeError, op) { r.public_send(op, r[0]) }
    }
    assert_raise(CArray::DataTypeError) { fix(%w[a b], 1).and("a") }
  end

  def test_object_arrays_still_meet_ruby_objects
    assert_equal([2, 3], CA_OBJECT([1, 2]).add(1).to_a)
    assert_equal(%w[ax bx], CArray.string(%w[a b]).add("x").to_a)
    assert_equal([true, false], CA_OBJECT([days[0], days[1]]).eq(days[0]).to_a)
  end

  # ---- CArray.select ----------------------------------------------------

  def test_select_keeps_the_face_and_masks_what_no_condition_picks
    r = CArray.select([cond], [days])
    assert_kind_of(CATime, r)
    assert_equal(["2024-01-01", UNDEF], r.to_a.map { |v| UNDEF.equal?(v) ? v : v.to_s })
    s = CArray.select([cond], [CArray.string(%w[a b])])
    assert_kind_of(CAString, s)
    assert_equal(["a", UNDEF], s.to_a)
  end

  def test_select_takes_a_default_read_by_the_face
    assert_equal(%w[2024-01-01 2024-03-01], texts(CArray.select([cond], [days], default: "2024-03-01")))
    assert_equal(%w[2024-01-01 2024-01-02], texts(CArray.select([cond], [days], default: days[1])))
    assert_equal(%w[ab zzzz], CArray.select([cond], [fix(%w[ab cd], 2)], default: "zzzz").to_a)
  end

  def test_select_first_match_wins_across_units
    r = CArray.select([cond, CA_BOOLEAN([true, true])], [days, hours])
    assert_equal(%w[2024-01-01T00:00:00Z 2024-01-02T12:00:00Z], texts(r))
  end

  def test_select_among_faces_that_cannot_be_written
    c = CArray.select([cond], [CArray.const_string(%w[a b])])
    assert_kind_of(CAConstString, c)
    assert_equal(["a", UNDEF], c.to_a.map { |v| v.nil? ? UNDEF : v })
    k = CArray.select([cond, cond.not], [CA_OBJECT(%w[a b]).categorize, CA_OBJECT(%w[b c]).categorize])
    assert_equal(%w[a c], k.to_a)
  end

  def test_select_of_plain_arrays_keeps_its_default
    assert_equal([1, 0], CArray.select([cond], [CA_INT32([1, 2])]).to_a)
  end

  # ---- picks by order ---------------------------------------------------

  def test_pmax_family_of_durations
    t = seconds(5, 1)
    assert_equal(%w[5s 2s], texts(t.pmax(seconds(2, 2))))
    assert_equal(%w[2s 1s], texts(t.pmin(seconds(2, 2))))
    assert_equal(%w[5s 3s], texts(t.maximum(seconds(3, 3)[0])))
    assert_equal(%w[3s 1s], texts(t.fmin(seconds(3, 3)[0])))
    assert_kind_of(CATimedelta, t.pmax(t))
    m = CA_INT64([1, 1]).timedelta(unit: :m)
    assert_equal(%w[60s 1s], texts(CA_INT64([60, 1]).timedelta(unit: :s).pmin(m)))
  end

  def test_pmax_family_of_fixlen_strings
    a = fix(%w[ab cd], 2)
    assert_equal(%w[bb cd], a.pmax("bb").to_a)
    assert_equal(%w[ab bb], a.minimum("bb").to_a)
    assert_equal(%w[abcd cd], a.fmax(fix(%w[abcd aaaa], 4)).to_a)
    assert_equal(4, a.fmax(fix(%w[abcd aaaa], 4)).bytes)
    assert_equal(2, a.pmin(UNDEF).count_masked)
  end

  def test_extreme_by_a_fixlen_key
    v = CA_INT64([1, 2, 3])
    k = fix(%w[bb cc aa], 2)
    assert_equal(2, v.max_by_key(k))
    assert_equal(3, v.min_by_key(k))
    plain = k.parent
    assert_equal(2, v.max_by_key(plain))
    assert_equal(2, v.max_by_key(k, axis: 0))
  end

  def test_extreme_by_a_fixlen_key_skips_a_masked_key
    k = fix(%w[zz cc aa], 2)
    k[0] = UNDEF
    assert_equal(2, CA_INT64([1, 2, 3]).max_by_key(k))
  end
end
