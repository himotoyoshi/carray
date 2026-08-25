# Face view single-lift invariant (docs/CAFace.md §1.3 / §8.2 / §8.3).
#
# Slicing / gathering / sorting a Face must leave EXACTLY ONE Face in the view
# parent chain (the top wrapper), never a redundant intermediate Face between
# the wrapper and storage. ca_face_lift performs the §8.3 one-level local swap:
# the reference node is put where the Face used to sit, so the Face stays on top
# and any distinct Face the user stacked underneath is preserved (one level, not
# a strip-to-storage walk).
#
# The OPS table below is the canonical "must preserve Face" registry: a new
# view-creating method should be added here so a forgotten lift (result is not a
# Face at all) is caught, not only a wrong swap (double Face). Regression sweep
# is `rake spec_ai`.
#
# NOTE: CAStack (multi-parent) is a deferred follow-up — see #stack tests below.

require "test/unit"
require "carray"

class TestFaceDoubleLift < Test::Unit::TestCase

  # count Face nodes (flag-based, so CAObject `face:true` counts too) in the chain
  def face_depth (v)
    n = 0
    x = v
    while x.respond_to?(:parent) && x.parent
      n += 1 if x.face?
      x = x.parent
    end
    n += 1 if x.respond_to?(:face?) && x.face?
    n
  end

  # 6-element 1-D column of each core Face
  def each_face
    yield "const",     CArray.const_string(%w[aa bb cc dd ee ff])
    yield "fixlen",    CArray.fixlen_string(%w[aa bb cc dd ee ff], bytes: 4)
    yield "string",    CArray.string(%w[aa bb cc dd ee ff])
    yield "time",      CArray.time(CA_INT64([0, 1, 2, 3, 4, 5]), unit: "1 day")
    yield "timedelta", CA_INT64([0, 1, 2, 3, 4, 5]).timedelta(unit: "1 day")
  end

  # canonical view-op registry (add a row when adding a view-creating method)
  OPS = {
    "block"     => ->(f) { f[1..4] },
    "gather"    => ->(f) { f[CA_INT32([3, 0, 2])] },
    "boolean"   => ->(f) { f[CA_BOOLEAN([1, 0, 1, 0, 1, 0])] },
    "reverse"   => ->(f) { f.reverse },
    "reshape"   => ->(f) { f[0..5].reshape(2, 3) },
    "transpose" => ->(f) { f[0..5].reshape(2, 3).transpose },
    "nested3"   => ->(f) { f[0..4][0..3][0..2] },
  }.freeze

  # AC-7 (forgot-to-lift net): every view-op on every Face returns a Face.
  # AC-1 (wrong-swap net): exactly one Face, and its parent is not a Face.
  def test_every_view_op_stays_single_face
    each_face do |name, f|
      OPS.each do |op, fn|
        v = fn.call(f)
        assert v.face?,                    "#{name}.#{op}: result lost Face identity (forgot lift?)"
        assert_equal 1, face_depth(v),     "#{name}.#{op}: not single-Face (#{face_depth(v)})"
        refute v.parent.face?,             "#{name}.#{op}: parent is a Face (middle double-Face)"
      end
    end
  end

  # const_string is byte-orderable → sort is an internal self[sort_index]
  def test_orderable_sort_single_face
    c = CArray.const_string(%w[bb aa cc aa])
    assert c.sort.face?
    assert_equal 1, face_depth(c.sort)
  end

  # AC-2: a user-stacked distinct Face is PRESERVED by the one-level swap
  # (a strip-to-storage walk would destroy it — the rejected behavior).
  def test_user_stacked_face_preserved
    td  = CA_INT64([10, 20, 30, 40]).timedelta(unit: "1 day")
    # The Tag mirrors its parent's surface -- CATimedelta is NonNumeric
    # (CA_FIXLEN), so a Face stacked on it decodes the storage itself.
    tag = Class.new(CAObject) do
      def initialize (parent)
        super(CA_FIXLEN, parent.dim, bytes: 8, parent: parent, face: true)
      end
      def storage_to_scalar (raw) ; raw.unpack1("q") ; end
    end.new(td)
    v = tag[1..2]
    assert v.face?,               "top Tag Face lost"
    refute v.parent.face?,        "middle Tag not swapped out"
    assert v.parent.parent.face?, "inner Timedelta destroyed (walk, not swap)"
    assert_kind_of CATimedelta, v.parent.parent
    assert_equal [20, 30], v.to_a
  end

  # AC-5: decode / write-back / state carry unchanged by the re-parenting
  def test_decode_correct
    c = CArray.const_string(%w[delta alpha gamma beta])
    assert_equal %w[alpha gamma],  c[1..2].to_a
    assert_equal %w[beta delta],   c[CA_INT32([3, 0])].to_a
    assert_equal %w[alpha gamma],  c[1..2][0..1][0..1].to_a   # nested
  end

  def test_writable_face_writeback_through_views
    fs = CArray.fixlen_string(%w[aa bb cc dd], bytes: 4)
    fs[1..2][0] = "XX"                                        # nested-view write
    assert_equal %w[aa XX cc dd], fs.to_a
    fs[CA_BOOLEAN([0, 0, 1, 1])] = "ZZ"                       # boolean-select write
    assert_equal %w[aa XX ZZ ZZ], fs.to_a
  end

  def test_time_state_carry
    t = CArray.time(CA_INT64([0, 1, 2, 3]), unit: "1 day")
    v = t[1..2]
    assert_kind_of CATime, v
    assert_equal t.unit.base, v.unit.base
  end

  def test_masked_face_slice
    cm = CArray.const_string(["x", nil, "z", nil, "w"])
    v  = cm[0..2]
    assert_equal 1, face_depth(v)
    assert_equal [false, true, false], v.is_masked.to_a
    assert_equal ["x", nil, "z"], v.to_a.map { |e| e == UNDEF ? nil : e }
  end

  # Idempotent lift: a builder that lifts internally (rb_ca_refer_new →
  # rb_ca_refer) whose caller lifts the result again must NOT stack an adjacent
  # same-class double Face. #value / #strip_mask go through that path.
  def test_mask_family_lifts_are_single_face
    dt = CArray.int64(5) { |i| i * 10 }.time(unit: :s)
    assert_kind_of CATime, dt.value
    assert_equal 1, face_depth(dt.value)          # was Time -> Time -> Refer -> entity
    assert_equal 1, face_depth(dt.strip_mask(0))
    c = CArray.const_string(%w[aa bb cc])
    assert_equal 1, face_depth(c.value)           # the other double-lift class
  end

  # CAStack (multi-parent): a stacked Face is single-Face too. Its parents are
  # pre-stripped one level in the builder (ca_stack_setup_with_axis), so the
  # chain is CATime[CAStack[entity, ...]] — one Face on top, non-Face parents.
  def test_castack_stacked_face_single_face
    t = CArray.time(CA_INT64([0, 1]), unit: "1 day")
    s = CArray.stack([t, t])
    assert s.face?
    assert_equal 1, face_depth(s)                    # was Time -> Stack -> Time -> entity
    refute s.parent.face?                            # CAStack's parent is storage
    assert_equal [2, 2], s.shape
    assert_equal t[0].to_s, s[0, 0].to_s             # values decode correctly
    assert_equal t[1].to_s, s[1, 1].to_s
  end

  # A plain-array stack is unlifted and its #parents accessor keeps identity.
  def test_plain_stack_parents_identity_preserved
    x = CA_INT32([1, 2, 3]); y = CA_INT32([4, 5, 6])
    s = CArray.stack([x, y])
    refute s.face?
    assert_same x, s.parents[0]
    assert_same y, s.parents[1]
  end
end
