require "test/unit"
require "carray"

# A lazy receiver or branch makes then_else a lazy node (CATriOp select)
# that answers as the eager selection does, and that a plan can describe.
class TestThenElseLazy < Test::Unit::TestCase

  def setup
    srand(11)
    @n = 9
    @c  = CArray.boolean(@n) { |i| rand(2) }
    @mc = @c.copy
    @mc[CArray.boolean(@n) { |i| rand(3) == 0 }] = UNDEF
  end

  def array (type, masked)
    a = case type
        when :float64  then CArray.float64(@n) { |i| rand * 10 - 5 }
        when :float32  then CArray.float32(@n) { |i| rand * 10 - 5 }
        when :int32    then CArray.int32(@n) { |i| rand(100) - 50 }
        when :uint8    then CArray.uint8(@n) { |i| rand(200) }
        when :boolean  then CArray.boolean(@n) { |i| rand(2) }
        when :cmplx128 then CArray.cmplx128(@n) { |i| Complex(rand, rand) }
        end
    a[CArray.boolean(@n) { |i| rand(3) == 0 }] = UNDEF if masked
    a
  end

  def branches
    list = []
    %i[float64 float32 int32 uint8 boolean cmplx128].each do |t|
      list << array(t, false) << array(t, true)
    end
    list + [1.5, 7, UNDEF, true, CScalar.int8.tap { |s| s[0] = 3 }]
  end

  def test_answers_as_the_eager_selection
    bs = branches
    [@c, @mc].each do |c|
      bs.each do |x|
        bs.each do |y|
          eager = begin; c.then_else(x, y); rescue => e; e; end
          lazy  = begin; c.lazy.then_else(x, y).copy; rescue => e; e; end
          if eager.is_a?(Exception)
            assert_equal eager.class, lazy.class
          else
            assert_equal eager.data_type, lazy.data_type
            assert_equal eager.to_a, lazy.to_a
          end
        end
      end
    end
  end

  def test_any_lazy_operand_makes_it_lazy
    x = array(:float64, true)
    assert_kind_of CATriOp, @c.then_else(x.lazy, 0.0)
    assert_kind_of CATriOp, @c.then_else(1, x.lazy)
    assert_not_kind_of CATriOp, @c.then_else(x, 0.0)
  end

  def test_an_object_result_stays_eager
    o = CA_OBJECT(Array.new(@n) { |i| i })
    assert_not_kind_of CATriOp, @c.lazy.then_else(o, 0)
  end

  def test_a_part_reads_as_the_whole_does
    x = CArray.float64(4, 6) { |i| rand }
    x[CArray.boolean(4, 6) { |i| rand(4) == 0 }] = UNDEF
    c = CArray.boolean(4, 6) { |i| rand(2) }
    c[CArray.boolean(4, 6) { |i| rand(4) == 0 }] = UNDEF
    eager = c.then_else(x, 2)
    lazy  = c.lazy.then_else(x, 2)
    assert_equal eager.is_masked.to_a, lazy.is_masked.to_a
    assert_equal eager[1..2, 2..4].to_a, lazy[1..2, 2..4].to_a
    assert_equal eager[nil, CA_INT64([5, 0, 3])].to_a, lazy[nil, CA_INT64([5, 0, 3])].to_a
    assert_equal eager.sum(axis: 1).to_a, lazy.sum(axis: 1).to_a
  end

  def test_a_plan_describes_the_selection
    b = CArray.float64(4).seq!
    plan = CArray::Fusion.plan((b.lazy > 1.0).then_else(b.lazy, 0.0))
    op = plan.nodes.last
    assert_equal [:triop, :select, :float64, :select],
                 [op.kind, op.name, op.data_type, op.mask]
    assert_equal "(#4) = (#1) ? (#2) : (#3);", op.body
    assert_equal :cast_float64, plan.nodes[op.args[0]].name
  end

  def test_an_undef_branch_is_walked
    b = CArray.float64(4).seq!
    assert_nil CArray::Fusion.plan((b.lazy > 1.0).then_else(b.lazy, UNDEF))
  end
end
