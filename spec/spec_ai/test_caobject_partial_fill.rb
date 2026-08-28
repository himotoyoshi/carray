require "carray"
require "test/unit"

# Filling part of a CAObject.
#
# `fill_data` carries no region -- it can only say "fill everything I cover"
# -- so until the fill_addrs / fill_stride slots were wired here, writing one
# value into part of a CAObject had nowhere to go but the per-cell default:
# one `store_addr` per cell.  A 1000x1000 region meant a million Ruby calls.
#
# Two optional callbacks take the region instead.  `fill_block` receives it as
# a per-axis sub-box of self, which is what an author with a block-shaped
# backing wants; `fill_addrs` receives a flat address list, which is what is
# left when the region is not a forward sub-box (a transpose, a descending
# range, a region that drops an axis).  Defining neither leaves the old
# behaviour exactly as it was, so an existing subclass sees no change.
#
# What was never at stake is escalation: the per-cell default already touched
# only the cells the caller named.  This is about the cost of a partial fill,
# not about it reaching cells it should not.
#
# See devel/PROPOSAL_PARTIAL_FILL_WHOLE_ROOT_WRITEBACK.md section 6.3 for the
# slot contract.

class TestCAObjectPartialFill < Test::Unit::TestCase

  # A CAObject over a plain array, counting the callbacks the engine reaches
  # for.  Subclasses below add one region callback each so that a single
  # assignment can be attributed to exactly one route.
  class Backed < CAObject
    attr_reader :log, :buf

    def initialize (n, m)
      super(CA_INT32, [n, m])
      @buf = CArray.int32(n, m) { 0 }
      @log = Hash.new(0)
    end

    def fetch_addr (addr)
      @buf[addr]
    end

    def store_addr (addr, val)
      @log[:store_addr] += 1
      @buf[addr] = val
    end

    def copy_data (data)
      data[] = @buf
    end

    def fill_data (val)
      @log[:fill_data] += 1
      @buf[] = val
    end
  end

  class WithBlock < Backed
    def fill_block (starts, counts, steps, val)
      @log[:fill_block] += 1
      @log[:args] = [starts, counts, steps, val]
      @buf[*starts.zip(counts, steps)] = val
    end
  end

  class WithAddrs < Backed
    def fill_addrs (addrs, val)
      @log[:fill_addrs] += 1
      @log[:addrs] = addrs.to_a
      addrs.each { |addr| @buf[addr] = val }
    end
  end

  # The answer every route has to agree on.
  def reference (n = 6, m = 8)
    ref = CArray.int32(n, m) { 0 }
    yield ref
    ref
  end

  # ----- the region reaches the callback that fits it -------------------

  def test_a_forward_sub_box_goes_to_fill_block
    o = WithBlock.new(6, 8)
    o[1..3, 2..5] = 7
    assert_equal 1, o.log[:fill_block], "region was not delivered in one call"
    assert_equal [[1, 2], [3, 4], [1, 1], 7], o.log[:args]
    assert_equal 0, o.log[:store_addr]
  end

  def test_a_step_is_carried_as_a_step_not_expanded
    o = WithBlock.new(6, 8)
    o[[1, 2, 2], nil] = 7          # start 1, count 2, step 2
    assert_equal 1, o.log[:fill_block]
    assert_equal [[1, 0], [2, 8], [2, 1], 7], o.log[:args]
  end

  def test_without_fill_block_the_region_goes_to_fill_addrs
    o = WithAddrs.new(6, 8)
    o[1..3, 2..5] = 7
    assert_equal 1, o.log[:fill_addrs], "region was not delivered in one call"
    assert_equal 12, o.log[:addrs].size
    assert_equal 0, o.log[:store_addr]
  end

  # A region that is not a forward sub-box of self has no per-axis form to
  # hand over, so it takes the address route even when fill_block exists.
  def test_a_transposed_region_falls_through_to_the_address_route
    o = WithBlock.new(6, 8)
    o.transpose[1..2, 2..3] = 7
    assert_equal 0, o.log[:fill_block]
    assert_operator o.log[:store_addr], :>, 0
  end

  def test_a_descending_range_falls_through_to_the_address_route
    o = WithBlock.new(6, 8)
    o[2..1, nil] = 7
    assert_equal 0, o.log[:fill_block]
  end

  # Dropping an axis leaves a region whose ndim does not match self's, so
  # there is no box to name either.
  def test_an_axis_dropping_region_takes_the_address_route
    o = WithBlock.new(6, 8)
    o[2, nil] = 7
    assert_equal 0, o.log[:fill_block]
  end

  # ----- whole-view and no-callback behaviour is unchanged --------------

  def test_the_whole_view_still_goes_to_fill_data
    o = WithBlock.new(6, 8)
    o[] = 7
    assert_equal 1, o.log[:fill_data]
    assert_equal 0, o.log[:fill_block]
  end

  # The point of the slot is to be optional: a subclass that defines neither
  # callback behaves exactly as before, one store_addr per cell of the region
  # and none outside it.
  def test_with_no_region_callback_it_is_still_per_cell_and_region_only
    o = Backed.new(6, 8)
    o[1..3, 2..5] = 7
    assert_equal 12, o.log[:store_addr]
  end

  # ----- every route writes the same thing ------------------------------

  def test_all_three_routes_agree
    ref = reference { |r| r[1..3, 2..5] = 7 }
    [Backed, WithBlock, WithAddrs].each do |klass|
      o = klass.new(6, 8)
      o[1..3, 2..5] = 7
      assert_equal ref.to_a, o.buf.to_a, "#{klass} wrote something else"
    end
  end

  def test_all_three_routes_agree_on_a_transposed_region
    ref = reference { |r| r.transpose[1..2, 2..3] = 7 }
    [Backed, WithBlock, WithAddrs].each do |klass|
      o = klass.new(6, 8)
      o.transpose[1..2, 2..3] = 7
      assert_equal ref.to_a, o.buf.to_a, "#{klass} wrote something else"
    end
  end

  def test_all_three_routes_agree_on_a_strided_region
    ref = reference { |r| r[[1, 2, 2], nil] = 7 }
    [Backed, WithBlock, WithAddrs].each do |klass|
      o = klass.new(6, 8)
      o[[1, 2, 2], nil] = 7
      assert_equal ref.to_a, o.buf.to_a, "#{klass} wrote something else"
    end
  end

  # A view of the view still resolves to one region of the CAObject.
  def test_a_nested_view_still_arrives_as_one_region
    o = WithBlock.new(6, 8)
    o[1..5, nil][0..1, nil] = 5
    ref = reference { |r| r[1..5, nil][0..1, nil] = 5 }
    assert_equal 1, o.log[:fill_block]
    assert_equal ref.to_a, o.buf.to_a
  end
end

# A Face has the same layout as its parent, so a region of the Face is the
# same region of the parent.  Before the fill slots were delegated, a partial
# fill on any Face -- CATime, CAString, CARecord -- fell to the per-cell
# default even when the parent could take the whole region at once.
class TestFacePartialFill < Test::Unit::TestCase

  class Int64Backed < CAObject
    attr_reader :log, :buf

    def initialize (n)
      super(CA_INT64, [n])
      @buf = CArray.int64(n) { 0 }
      @log = Hash.new(0)
    end

    def fetch_addr (addr)
      @buf[addr]
    end

    def store_addr (addr, val)
      @log[:store_addr] += 1
      @buf[addr] = val
    end

    def copy_data (data)
      data[] = @buf
    end

    def fill_block (starts, counts, steps, val)
      @log[:fill_block] += 1
      @buf[*starts.zip(counts, steps)] = val
    end
  end

  def test_a_face_hands_the_region_to_its_parent
    backing = Int64Backed.new(10)
    face = backing.time(unit: :D)
    face[2..5] = CArray.time(%w[2024-01-11], unit: :D)[0]
    assert_equal 1, backing.log[:fill_block], "the Face did not pass the region down"
    assert_equal 0, backing.log[:store_addr]
    assert_equal [0, 0, 19733, 19733, 19733, 19733, 0, 0, 0, 0], backing.buf.to_a
  end

  def test_a_partial_fill_on_a_face_over_an_entity_is_right
    face = CArray.time(%w[2024-01-01 2024-01-02 2024-01-03 2024-01-04], unit: :D)
    face[1..2] = CArray.time(%w[2024-03-01], unit: :D)[0]
    assert_equal %w[2024-01-01 2024-03-01 2024-03-01 2024-01-04],
                 face.to_a.map(&:to_s)
  end

  def test_a_partial_fill_leaves_the_rest_of_a_string_face_alone
    face = CArray.string(4) { |i| "row#{i}" }
    face[1..2] = "x"
    assert_equal %w[row0 x x row3], face.to_a
  end
end
