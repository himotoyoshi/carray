require 'carray'
require_relative "ext_xfer_smoke/load"
require 'test/unit'

# PROPOSAL_XFER_PROTOCOL step 1: ca_xfer_index must be byte-for-byte equivalent
# to the legacy ca_fetch_index / ca_store_index for every cell, across the
# entity reference implementation (CA_OBJ_ARRAY, which now sets the xfer_index
# slot) and the NULL -> fetch/store fallback path taken by every other view.
#
# CArray.xfer_index_smoke(ca) returns the number of cells where
#   - ca_xfer_index(GET) != ca_fetch_index, or
#   - a PUT round-trip (write the fetched value back) changes the cell.
# 0 == parity.
class TestXferIndex < Test::Unit::TestCase

  def assert_parity(ca, msg = nil)
    n = CArray.xfer_index_smoke(ca)
    assert_equal(0, n, "xfer_index parity mismatch (#{n}) for #{msg || ca.class}")
    # step 2: ca_xfer_addrs over the full address list must match per-element
    # ca_fetch_addr, with PUT round-trip identity.
    a = CArray.xfer_addrs_smoke(ca)
    assert_equal(0, a, "xfer_addrs parity mismatch (#{a}) for #{msg || ca.class}")
    # step 3: ca_xfer_stride over the whole view (one contiguous region) must
    # match per-element ca_fetch_addr, with PUT round-trip identity.
    s = CArray.xfer_stride_smoke(ca)
    assert_equal(0, s, "xfer_stride parity mismatch (#{s}) for #{msg || ca.class}")
  end

  # ---- entity reference implementation (slot path) ----

  def test_entity_data_types
    [:int8, :int16, :int32, :int64, :uint8, :uint32,
     :float32, :float64].each do |t|
      a = CArray.send(t, 3, 4).tap { |i| i[] = i }
      assert_parity(a, "entity #{t}")
    end
  end

  def test_entity_ranks
    assert_parity(CArray.int32(7).tap { |i| i[] = i }, "1D")
    assert_parity(CArray.int32(3, 4).tap { |i| i[] = i }, "2D")
    assert_parity(CArray.int32(2, 3, 4).tap { |i| i[] = i }, "3D")
    assert_parity(CArray.float64(2, 2, 2, 2).tap { |i| i[] = i }, "4D")
  end

  def test_entity_object
    # default-initialized object array (elements = Fixnum 0); values are
    # irrelevant to parity, which compares xfer vs fetch on whatever is stored.
    a = CArray.object(2, 3)
    a[0, 0] = "hello"
    a[1, 2] = :sym
    assert_parity(a, "CA_OBJECT entity")
  end

  def test_entity_boolean
    a = CArray.boolean(3, 3).tap { |i| i[] = i % 2 }
    assert_parity(a, "boolean entity")
  end

  # ---- views: NULL xfer_index -> fetch/store fallback path ----

  def test_view_reshape
    a = CArray.int32(3, 4).tap { |i| i[] = i }
    assert_parity(a.reshape(4, 3), "reshape")
    assert_parity(a.reshape(12), "flatten")
  end

  def test_view_block
    a = CArray.int32(6, 6).tap { |i| i[] = i }
    assert_parity(a[1..4, 2..5], "block slice")
    assert_parity(a[nil, 2], "column")
  end

  def test_view_transpose
    a = CArray.float64(3, 5).tap { |i| i[] = i }
    assert_parity(a.transpose, "transpose")
  end

  def test_view_refer_retype_same_bytes
    a = CArray.int32(4).tap { |i| i[] = i }
    assert_parity(a.refer(CA_FLOAT32, [4]), "refer int32->float32 (same bytes)")
  end

  def test_view_fake_cast
    a = CArray.int32(3, 4).tap { |i| i[] = i }
    assert_parity(a.float64, "fake cast int32->float64")
  end

  def test_view_window_shift
    a = CArray.int32(6, 6).tap { |i| i[] = i }
    assert_parity(a.window(1..4, 1..4), "CAWindow interior")
    assert_parity(a.shift(1, -1), "CAShift (OOB fill)")
  end

  def test_view_tile
    a = CArray.int32(2, 3).tap { |i| i[] = i }
    assert_parity(a.tile(2, 2), "CATile")
  end

  def test_view_roll
    a = CArray.int32(5).tap { |i| i[] = i + 1 }
    assert_parity(a.roll(2), "CARoll")
  end

  def test_view_byte_swap
    a = CArray.int32(3, 4).tap { |i| i[] = i + 1 }
    assert_parity(a.swap_bytes, "CAByteSwap")
  end

  def test_view_field_complex
    # CAField .real / .imag over complex: byte-mismatched reinterpret, exercises
    # the sub-byte scratch delegate path in ca_stride_func_xfer_index.
    a = CArray.cmplx64(3, 4)
    a[0, 0] = Complex(1, -2)
    a[1, 3] = Complex(5, 6)
    a[2, 1] = Complex(-7, 8)
    assert_parity(a.real, "CAField .real (byte-mismatch)")
    assert_parity(a.imag, "CAField .imag (byte-mismatch)")
  end

  def test_view_chain
    # multi-stage stride chain: block of a reshape (compose-fold path)
    a = CArray.int32(6, 6).tap { |i| i[] = i }
    assert_parity(a.reshape(4, 9)[1..3, 2..7], "chain reshape+block")
  end

  def test_view_repeat
    a = CArray.int32(3).tap { |i| i[] = i }
    assert_parity(a[:%, 2], "repeat") if a.respond_to?(:[])
  end

  def test_view_select
    a = CArray.int32(20).tap { |i| i[] = i }
    assert_parity(a[a > 10], "select (boolean mask)")
  end

  def test_view_grid
    a = CArray.int32(5, 5).tap { |i| i[] = i }
    assert_parity(a[[0, 2, 4], [1, 3]], "grid")
  end

  def test_view_select_axis
    # CASelectAxis (CSA): per-axis boolean mask -> ca_select_axis_func
    a = CArray.int32(5, 4).tap { |i| i[] = i }
    m = CArray.boolean(5).tap { |i| i[] = i % 2 }
    assert_parity(a[m, nil], "CSA (select axis)")
  end

  # ---- masked arrays (mask out of scope, but data-byte parity must hold) ----

  def test_masked_entity
    a = CArray.int32(3, 4).tap { |i| i[] = i }
    a[1, 2] = UNDEF
    assert_parity(a, "masked entity")
  end

  # ---- readonly view: PUT path is skipped inside the smoke, GET still checked ----

  def test_readonly_value_array
    a = CArray.int32(3, 4).tap { |i| i[] = i }
    a[1, 1] = UNDEF
    assert_parity(a.value, "value (readonly)")
  end
end
