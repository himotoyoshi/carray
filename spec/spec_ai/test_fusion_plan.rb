require "test/unit"
require "carray"

# A plan is what a second evaluator reads: the operations in a lazy
# expression, what each one's mask does, and where the leaves are.  Nothing
# in the core needs one -- CArray walks the view instead -- so what these
# assert is that a plan describes the expression faithfully enough that
# something else could compute the same answer from it.
class TestFusionPlan < Test::Unit::TestCase

  def setup
    @a = CArray.float64(8) { |i| i + 1.0 }
    @b = CArray.float64(8) { |i| (i % 3) + 1.0 }
  end

  def plan_for (view)
    CArray::Fusion.plan(view)
  end

  # -- shape ------------------------------------------------------------

  def test_nodes_come_in_evaluation_order_and_end_at_the_result
    plan = plan_for(CArray.fuse { (@a + @b * 2.0).sqrt - @a })
    assert_equal %i[add mul sqrt sub].sort,
                 plan.nodes.grep(CArray::Fusion::Op).map(&:name).sort
    assert_equal :sub, plan.nodes.last.name
    plan.nodes.each_with_index do |node, i|
      next unless node.is_a?(CArray::Fusion::Op)
      node.args.each { |a| assert_operator a, :<, i, "an operand comes first" }
    end
  end

  def test_leaves_are_the_arrays_in_the_order_they_are_named
    plan = plan_for(CArray.fuse { @a - @b })
    assert_equal 2, plan.leaves.size
    assert_same @a, plan.leaves[0]
    assert_same @b, plan.leaves[1]
    assert_equal [0, 1], plan.nodes.grep(CArray::Fusion::Leaf).map(&:index)
  end

  def test_a_scalar_is_a_constant_rather_than_a_leaf
    plan = plan_for(CArray.fuse { @a * 2.5 })
    consts = plan.nodes.grep(CArray::Fusion::Const)
    assert_equal [2.5], consts.map(&:value)
    assert_equal 1, plan.leaves.size
  end

  def test_an_array_named_twice_is_one_leaf
    plan = plan_for(CArray.fuse { @a + @a })
    assert_equal 1, plan.leaves.size
  end

  def test_it_carries_what_the_result_is
    plan = plan_for(CArray.fuse { @a > @b })
    assert_equal :boolean, plan.data_type
    assert_equal [8], plan.dim
  end

  # -- every operation --------------------------------------------------

  def test_every_lazy_operation_can_be_planned
    operands = {
      float64: [CArray.float64(8) { |i| i + 1.0 }, CArray.float64(8) { |i| (i % 3) + 1.0 }],
      int32:   [CArray.int32(8)   { |i| i + 1 },   CArray.int32(8)   { |i| (i % 3) + 1 }],
      boolean: [CArray.boolean(8) { |i| i.even? }, CArray.boolean(8) { |i| i < 4 }],
    }
    planned = lambda do |arity, method|
      operands.each_value do |x, y|
        begin
          view = case arity
                 when 1 then CArray.fuse { x.send(method) }
                 when 2 then CArray.fuse { x.send(method, y) }
                 when 3 then CArray.fuse { x.send(method, y, 1.0) }
                 end
          return true if CArray::Fusion.plan(view)
        rescue StandardError
        end
      end
      false
    end
    missing = []
    CArray::LAZY_MONOP_OP_IDS.each_key { |m| missing << m unless planned.(1, m) }
    CArray::LAZY_BINOP_OP_IDS.each_key { |m| missing << m unless planned.(2, m) }
    CArray::LAZY_TRIOP_OP_IDS.each_key { |m| missing << m unless planned.(3, m) }
    assert_equal [], missing,
                 "an operation a lazy expression can hold that a plan cannot describe"
  end

  def test_every_operation_carries_the_c_the_kernel_uses
    plan = plan_for(CArray.fuse { (@a + @b).sqrt * 2.0 })
    plan.nodes.grep(CArray::Fusion::Op).each do |op|
      assert_equal CArray.__kernel_body__(op.kind, op.name, op.data_type), op.body
      assert_include op.body, "#1"
    end
  end

  # -- masks ------------------------------------------------------------

  def test_a_view_over_one_array_is_masked_where_that_array_is
    assert_equal :pass, plan_for(CArray.fuse { @a.sqrt }).nodes.last.mask
  end

  def test_two_operands_are_masked_where_either_is
    assert_equal :union, plan_for(CArray.fuse { @a + @b }).nodes.last.mask
  end

  def test_boolean_and_or_are_three_valued
    p1 = CArray.boolean(8) { |i| i.even? }
    p2 = CArray.boolean(8) { |i| i < 4 }
    assert_equal :kleene_or,
                 CArray::Fusion.plan(CArray.fuse { p1 | p2 }).nodes.last.mask
    assert_equal :kleene_and,
                 CArray::Fusion.plan(CArray.fuse { p1 & p2 }).nodes.last.mask
    assert_equal :union,
                 CArray::Fusion.plan(CArray.fuse { p1 ^ p2 }).nodes.last.mask
  end

  def test_a_masked_leaf_is_marked_as_one
    masked = @a.copy
    masked[1] = UNDEF
    plan = CArray::Fusion.plan(CArray.fuse { masked + @b })
    assert_true plan.masked
    assert_equal [true, false], plan.nodes.grep(CArray::Fusion::Leaf).map(&:masked)
  end

  # -- the divisor a mask excludes --------------------------------------

  def test_integer_division_is_marked_as_trapping
    ints = CArray.int32(8) { |i| i + 1 }
    %i[/ %].each do |m|
      plan = CArray::Fusion.plan(CArray.fuse { ints.send(m, ints) })
      assert_true plan.nodes.last.trapping, "#{m} on integers raises on a zero divisor"
    end
  end

  def test_float_division_is_not
    assert_false plan_for(CArray.fuse { @a / @b }).nodes.last.trapping
  end

  # -- the signature ----------------------------------------------------

  def test_expressions_of_the_same_shape_share_a_signature
    other = CArray.float64(8) { |i| i * 3.0 }
    one = CArray::Fusion.plan(CArray.fuse { @a + @b * 2.0 })
    two = CArray::Fusion.plan(CArray.fuse { @b + other * 2.0 })
    assert_equal one.signature, two.signature
  end

  def test_a_different_expression_does_not
    one = plan_for(CArray.fuse { @a + @b })
    two = plan_for(CArray.fuse { @a - @b })
    assert_not_equal one.signature, two.signature
  end

  def test_a_mask_or_a_data_type_changes_it
    masked = @a.copy
    masked[1] = UNDEF
    ints = CArray.int32(8) { |i| i + 1 }
    plain = plan_for(CArray.fuse { @a + @b })
    assert_not_equal plain.signature,
                     CArray::Fusion.plan(CArray.fuse { masked + @b }).signature
    assert_not_equal plain.signature,
                     CArray::Fusion.plan(CArray.fuse { ints + ints }).signature
  end

  def test_a_constant_is_part_of_it
    assert_not_equal (plan_for(CArray.fuse { @a * 2.0 })).signature,
                     (plan_for(CArray.fuse { @a * 3.0 })).signature
  end

  # -- refusing ---------------------------------------------------------

  def test_something_that_is_not_a_lazy_expression_has_no_plan
    assert_nil CArray::Fusion.plan(@a)
    assert_nil CArray::Fusion.plan(3.0)
    assert_nil CArray::Fusion.plan(nil)
  end

  def test_an_object_array_has_no_plan
    # Its kernels call back into the interpreter, so there is no body.
    objs = CArray.object(4) { |i| i }
    assert_nil CArray::Fusion.plan(CArray.fuse { objs + 1 })
  end
end
