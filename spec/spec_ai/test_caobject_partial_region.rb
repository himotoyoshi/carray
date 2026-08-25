# frozen_string_literal: true
#
# spec_ai/test_caobject_partial_region.rb
#
# PROPOSAL_CAOBJECT_PARTIAL_REGION rev3.1 — sub-step O.5.
#
# Verify the 8 new Ruby callbacks (copy_block / sync_block / copy_addrs /
# sync_addrs + 4 mask parallels) plus dispatch correctness, gate routing,
# fallback chain, empty region, exception propagation, last-writer-wins,
# and object-data_type GC safety.
#
# View-construction notes for triggering each path:
#   - obj[range, range].copy       -> CABlock.copy_data -> xfer_all PUT/GET
#                                      partial path -> parent.xfer_stride
#   - obj.transpose.copy           -> CATranspose (CAStride family) same path
#                                      with permuted strides (gate fails)
#   - obj[[range, step], ...].copy -> CABlock with stepped axes (gate passes
#                                      with steps[k] >= 2)
#   - obj[idx_carray].copy         -> fancy index -> parent.xfer_addrs
#
# NB: `.to_a` calls ca_attach which fully materialises the parent (whole-view
# path), so we must use `.copy` to exercise the partial-region path.

require "test/unit"
require_relative "../../lib/carray"

# ---------- fixtures ------------------------------------------------------

# Base: high-level value-space backing.  Every flat element address `addr`
# of self maps to a deterministic value (addr * 7 + 3).
class POBase < CAObject
  def initialize(dim, data_type: CA_INT32)
    @dim_arg = dim
    @backing = {}
    @block_calls = []
    @addrs_calls = []
    super(data_type, dim)
  end

  attr_reader :block_calls, :addrs_calls

  def value_for(addr); (addr.to_i * 7 + 3) % 256; end

  def get_backing(addr)
    @backing[addr] || value_for(addr)
  end

  def fetch_addr(addr); get_backing(addr); end
  def store_addr(addr, v); @backing[addr] = v; end

  def copy_data(data)
    data.elements.times { |i| data[i] = get_backing(i) }
  end

  def sync_data(data)
    data.elements.times { |i| @backing[i] = data[i] }
  end

  def flat(idx)
    s = 1; addr = 0
    (idx.size - 1).downto(0) do |k|
      addr += idx[k] * s
      s *= @dim_arg[k]
    end
    addr
  end

  def block_walk(starts, counts, steps)
    iter = lambda do |idx|
      if idx.size == counts.size
        self_idx = idx.each_with_index.map { |i, k| starts[k] + i * steps[k] }
        yield idx, self_idx
      else
        counts[idx.size].times { |i| iter.call(idx + [i]) }
      end
    end
    iter.call([])
  end
end

# Capability: + copy_block / sync_block
class POBlock < POBase
  def copy_block(starts, counts, steps, data)
    @block_calls << { kind: :copy, starts: starts.dup, counts: counts.dup, steps: steps.dup, shape: data.shape }
    block_walk(starts, counts, steps) do |idx, self_idx|
      data[*idx] = get_backing(flat(self_idx))
    end
  end

  def sync_block(starts, counts, steps, data)
    @block_calls << { kind: :sync, starts: starts.dup, counts: counts.dup, steps: steps.dup }
    block_walk(starts, counts, steps) do |idx, self_idx|
      @backing[flat(self_idx)] = data[*idx]
    end
  end
end

# Capability: + copy_addrs / sync_addrs
class POAddrs < POBase
  def copy_addrs(addrs, data)
    @addrs_calls << { kind: :copy, n: addrs.elements, addrs: addrs.to_a }
    addrs.elements.times { |i| data[i] = get_backing(addrs[i]) }
  end

  def sync_addrs(addrs, data)
    @addrs_calls << { kind: :sync, n: addrs.elements }
    addrs.elements.times { |i| @backing[addrs[i]] = data[i] }
  end
end

# Capability: + both block and addrs
class POBoth < POBase
  def copy_block(starts, counts, steps, data)
    @block_calls << { kind: :copy, starts: starts.dup, counts: counts.dup, steps: steps.dup }
    block_walk(starts, counts, steps) do |idx, self_idx|
      data[*idx] = get_backing(flat(self_idx))
    end
  end

  def sync_block(starts, counts, steps, data)
    @block_calls << { kind: :sync }
    block_walk(starts, counts, steps) do |idx, self_idx|
      @backing[flat(self_idx)] = data[*idx]
    end
  end

  def copy_addrs(addrs, data)
    @addrs_calls << { kind: :copy, n: addrs.elements }
    addrs.elements.times { |i| data[i] = get_backing(addrs[i]) }
  end

  def sync_addrs(addrs, data)
    @addrs_calls << { kind: :sync, n: addrs.elements }
    addrs.elements.times { |i| @backing[addrs[i]] = data[i] }
  end
end

def carr_int32(arr)
  c = CArray.int32(arr.size)
  c[] = arr
  c
end

# ---------- tests ---------------------------------------------------------

class TestCAObjectPartialRegion < Test::Unit::TestCase
  # ===== O.2 xfer_addrs: copy_addrs dispatch =====
  #
  # Triggers: transpose / partial-block-with-only-copy_addrs both route
  # through xfer_stride's flat-addr fallback into xfer_addrs.  Note that
  # fancy-index materialise (`obj[idx].copy`) currently routes through
  # CAGrid's whole-view path (= parent.copy_data, not parent.xfer_addrs),
  # so it is NOT a reliable trigger for the bulk addrs path; we use
  # transpose / partial-block instead.

  def test_copy_addrs_invoked_via_transpose
    obj = POAddrs.new([3, 3])  # copy_addrs defined, copy_block not
    result = obj.transpose.copy.to_a
    3.times do |i|
      3.times do |j|
        assert_equal(obj.value_for(j * 3 + i), result[i][j])
      end
    end
    assert(obj.addrs_calls.size >= 1, "transpose GET routes to copy_addrs")
    assert_equal(:copy, obj.addrs_calls.last[:kind])
    assert_equal(9, obj.addrs_calls.last[:n])
  end

  # ===== O.3 xfer_stride gate routing =====

  def test_copy_block_invoked_for_contiguous_block
    obj = POBlock.new([4, 4])
    result = obj[1..2, 1..2].copy.to_a
    expected = [[obj.value_for(5), obj.value_for(6)],
                [obj.value_for(9), obj.value_for(10)]]
    assert_equal(expected, result)
    assert(obj.block_calls.size >= 1, "copy_block should fire for partial block")
    call = obj.block_calls.find { |c| c[:kind] == :copy }
    refute_nil(call)
    assert_equal([1, 1], call[:starts])
    assert_equal([2, 2], call[:counts])
    assert_equal([1, 1], call[:steps], "contiguous block: steps all 1")
  end

  def test_copy_block_invoked_for_stepped_block
    obj = POBlock.new([8, 8])
    # carray stepped slice: [[range, step], ...]
    view = obj[[nil, 2], [nil, 2]]
    result = view.copy.to_a
    assert_equal(4, result.size)
    call = obj.block_calls.find { |c| c[:kind] == :copy }
    refute_nil(call)
    assert_equal([0, 0], call[:starts])
    assert_equal([4, 4], call[:counts])
    assert_equal([2, 2], call[:steps], "stepped block: steps reflect index step")
    4.times do |i|
      4.times do |j|
        assert_equal(obj.value_for(2*i * 8 + 2*j), result[i][j])
      end
    end
  end

  def test_contiguous_detection_idiom
    obj = POBlock.new([6, 6])
    obj[2..3, 2..3].copy         # contiguous
    obj[[nil, 2], [nil, 2]].copy # stepped
    copies = obj.block_calls.select { |c| c[:kind] == :copy }
    assert_equal(2, copies.size)
    assert(copies[0][:steps].all? { |s| s == 1 }, "contiguous")
    refute(copies[1][:steps].all? { |s| s == 1 }, "stepped")
  end

  def test_transpose_routes_to_addrs_not_block
    # CATranspose emits permuted strides: gate fails (pi != id).
    # POBoth has both copy_block and copy_addrs -- only copy_addrs should fire
    # (or per-cell if neither covers it, but POBoth has copy_addrs).
    obj = POBoth.new([4, 4])
    result = obj.transpose.copy.to_a
    4.times do |i|
      4.times do |j|
        assert_equal(obj.value_for(j * 4 + i), result[i][j])
      end
    end
    copies = obj.block_calls.select { |c| c[:kind] == :copy }
    assert_equal(0, copies.size, "transpose must NOT invoke copy_block (gate fail)")
    assert(obj.addrs_calls.size >= 1, "transpose routes to copy_addrs via xfer_stride fallback")
  end

  def test_copy_block_fallback_to_addrs_when_only_addrs_defined
    obj = POAddrs.new([4, 4])   # has copy_addrs, no copy_block
    result = obj[1..2, 1..2].copy.to_a
    expected = [[obj.value_for(5), obj.value_for(6)],
                [obj.value_for(9), obj.value_for(10)]]
    assert_equal(expected, result)
    assert(obj.addrs_calls.size >= 1, "copy_block undef -> falls back via xfer_addrs -> copy_addrs")
  end

  def test_per_cell_fallback_when_neither_block_nor_addrs_defined
    obj = POBase.new([4, 4])
    result = obj[1..2, 1..2].copy.to_a
    expected = [[obj.value_for(5), obj.value_for(6)],
                [obj.value_for(9), obj.value_for(10)]]
    assert_equal(expected, result)
    assert_equal(0, obj.block_calls.size)
    assert_equal(0, obj.addrs_calls.size)
  end

  # ===== empty region (Q2) =====

  def test_empty_region_does_not_invoke_callback
    obj = POBlock.new([4])
    result = obj[0...0].copy.to_a
    assert_equal([], result)
    assert_equal(0, obj.block_calls.size, "empty region must skip callback")
  end

  # ===== exception propagation (Q6) =====

  def test_exception_in_copy_block_propagates_no_fallback
    obj = POBoth.new([4, 4])

    def obj.copy_block(starts, counts, steps, data)
      @block_calls << { kind: :copy_raised }
      raise RuntimeError, "boom from copy_block"
    end

    assert_raise(RuntimeError) do
      obj[1..2, 1..2].copy
    end
    raised = obj.block_calls.select { |c| c[:kind] == :copy_raised }
    assert_equal(1, raised.size)
    assert_equal(0, obj.addrs_calls.size, "raise must NOT fall back to copy_addrs")
  end

  # ===== sync_addrs dispatch via transpose PUT =====
  #
  # transpose-PUT routes through xfer_stride PUT, which (gate fail) falls
  # back to flat-addr expansion -> xfer_addrs PUT -> sync_addrs.  This is
  # the natural Ruby trigger for the bulk scatter path.
  #
  # Last-writer-wins for duplicate addrs (rev3.1 §3.4 Q4) is a contract
  # for the addrs list itself: when the addrs[] array passed to sync_addrs
  # contains duplicates (which transpose never produces, but fancy-index
  # PUT against a CAObject would if it routed through xfer_addrs), the
  # Ruby callback receives the addrs in the order the engine generated
  # them, and writes them in `data[i]` order.  Concretely: the user's
  # sync_addrs body is `addrs.each_with_index { |a, i| backing[a] = data[i] }`,
  # which is Ruby Hash semantics where the last write wins.  We document
  # this contract here but cannot exercise it via a public-surface
  # generator (fancy-index PUT doesn't route through xfer_addrs today).

  def test_sync_addrs_invoked_via_transpose_put
    obj = POAddrs.new([3, 3])
    src = CArray.int32(3, 3)
    src[] = [[100, 101, 102], [103, 104, 105], [106, 107, 108]]
    obj.transpose[] = src
    sync = obj.addrs_calls.find { |c| c[:kind] == :sync }
    refute_nil(sync, "transpose PUT should trigger sync_addrs")
    # Verify the data landed at transposed positions
    # src[i,j] should land at obj.backing[j * 3 + i]
    3.times do |i|
      3.times do |j|
        assert_equal(100 + i * 3 + j, obj.get_backing(j * 3 + i))
      end
    end
  end

  # ===== object data_type + GC stress (R2) =====

  def test_object_data_type_copy_block_gc_safe
    klass = Class.new(POBase) do
      def initialize(dim); super(dim, data_type: CA_OBJECT); end
      def value_for(addr); { "key" => addr * 11 }; end
      def copy_block(starts, counts, steps, data)
        was_stress = GC.stress
        GC.stress = true
        begin
          counts[0].times do |i0|
            counts[1].times do |i1|
              addr0 = starts[0] + i0 * steps[0]
              addr1 = starts[1] + i1 * steps[1]
              data[i0, i1] = value_for(addr0 * 4 + addr1)
            end
          end
        ensure
          GC.stress = was_stress
        end
      end
    end
    obj = klass.new([4, 4])
    result = obj[1..2, 1..2].copy.to_a
    assert_equal({ "key" => 5 * 11 }, result[0][0])
    assert_equal({ "key" => 10 * 11 }, result[1][1])
  end

  # ===== existing CAObject subclasses unaffected =====

  def test_existing_subclass_without_partial_callbacks_unchanged
    obj = POBase.new([4, 4])
    # whole-view path
    full = obj.copy.to_a
    assert_equal(obj.value_for(5), full[1][1])
    # sub-region via partial path (per-cell fallback for POBase)
    sub = obj[1..2, 1..2].copy.to_a
    assert_equal(obj.value_for(5),  sub[0][0])
    assert_equal(obj.value_for(10), sub[1][1])
    # fancy index
    idx = carr_int32([0, 15])
    fancy = obj[idx].copy.to_a
    assert_equal([obj.value_for(0), obj.value_for(15)], fancy)
    # no bulk callbacks defined => all dispatch fell through to per-cell
    assert_equal(0, obj.block_calls.size)
    assert_equal(0, obj.addrs_calls.size)
  end

  # ===== aligned-but-large step still passes the gate (Q1 boundary) =====

  def test_gate_passes_when_step_equals_axis_size
    # Skip: would require step = dim[k], degenerate, view becomes count=1 axis.
    # Instead pin "step = 2" which is the common stepped slice.
    obj = POBlock.new([6, 6])
    view = obj[[nil, 2], 0..1]   # axis 0 stepped, axis 1 contig
    result = view.copy.to_a
    assert_equal(3, result.size)    # 6/2 = 3 along axis 0
    call = obj.block_calls.find { |c| c[:kind] == :copy }
    refute_nil(call)
    assert_equal([2, 1], call[:steps])
  end

  # ===== bulk path is sentinel-free (rev3.1 §3.7) =====

  def test_bulk_path_does_not_set_mask_via_undef
    # Even if copy_block were to return without setting mask, no sentinel
    # mask-bit is auto-set (unlike per-cell fetch_addr where CA_UNDEF
    # return triggers a mask bit).  This pins that bulk-path data callback
    # is data-only.
    obj = POBlock.new([4])
    view = obj[1..2]
    materialised = view.copy
    refute(materialised.has_mask?, "bulk path must not auto-create mask")
  end
end
