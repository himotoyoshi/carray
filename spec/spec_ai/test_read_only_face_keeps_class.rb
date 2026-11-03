require "test/unit"
require "carray"

# A read-only view of a Face is read-only only as that view: what is computed
# from it is the same Face, and writable.
class TestReadOnlyFaceKeepsClass < Test::Unit::TestCase

  S = CArray.struct(order_by: [:a]) { int32 :a }

  def faces
    r = CARecord.new(S, 3)
    r["a"][] = CA_INT32([1, 2, 3])
    [CArray.int64(3).seq!.time(unit: :s), CArray.int64(3).seq!.timedelta(unit: :s),
     CArray.string(%w[a b c]), CArray.fixlen_string(%w[a b c]), r]
  end

  def read_only_views (f)
    frozen = f.copy
    frozen.freeze
    [frozen.flip(0), f[nil, :_].broadcast_to(3, 2).flatten[0...3]]
  end

  def each_view
    faces.each { |f| read_only_views(f).each { |v| yield f, v } }
  end

  def test_the_views_are_read_only
    each_view { |f, v| assert_true v.read_only?, f.class.to_s }
  end

  def test_template_is_the_face_and_writable
    each_view { |f, v|
      t = v.template
      assert_instance_of f.class, t
      assert_false t.read_only?, f.class.to_s
      t[0] = f[1]
      assert_equal f[1].to_s, t[0].to_s
    }
  end

  def test_then_else
    each_view { |f, v| assert_instance_of f.class, v.is_masked.then_else(v[0], v) }
  end

  def test_group_reductions
    each_view { |f, v|
      g = v.group_by_category(CA_INT32([0, 1, 0]).categorize)
      assert_instance_of f.class, g.min
      assert_instance_of f.class, g.first
    }
  end

  def test_slab_iterators
    each_view { |f, v|
      assert_instance_of f.class, v.map_slab(axis: 0) { |s| s.copy }
      assert_instance_of f.class, v.reduce_slab(axis: 0) { |s| s[0] }
    }
  end

  def test_sort_and_unique_are_writable
    each_view { |f, v|
      [v.sort.copy, v.unique, v.copy].each { |x|
        assert_instance_of f.class, x
        assert_false x.read_only?, f.class.to_s
      }
    }
  end

  def test_the_view_itself_stays_read_only
    f = CArray.string(%w[a b c])
    f.freeze
    assert_raise(RuntimeError) { f.flip(0)[0] = "z" }
    assert_equal %w[a b c], f.to_a
  end

  def test_a_face_that_holds_no_new_value_stays_read_only
    c = CA_OBJECT(%w[a b]).categorize
    assert_true c.template.read_only?
    k = CArray.const_string(%w[a b])
    assert_equal CArray, k.template.class
  end

end
