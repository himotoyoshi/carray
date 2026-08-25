require "test/unit"
require "carray"

# Consumer-side handling of PEP 3118 SIMPLE-form producers: a typed view that
# advertises a format and ndim == 1 but leaves shape/strides NULL for a
# contiguous 1-D buffer.  Two fixes in carray_memory_view.c are pinned here:
#
#   - SIMPLE-form typed producer support: shape == NULL must be read as 1-D
#     (length = byte_size / item_size) instead of dereferencing NULL.
#   - Zero-init of the rb_memory_view_t before rb_memory_view_get, so a
#     producer whose release() frees item_desc.components unconditionally
#     gets a NULL there rather than stack garbage.
#
# Both used to be covered only through red-arrow, whose primitive arrays
# happen to produce exactly this shape.  MVBorrower::Producer reproduces it
# directly, so the pins do not depend on an external gem being installed and
# working.
#
# Build the peer:
#   cd spec/spec_ai/ext_memory_view_test && ruby extconf.rb && make

borrower_dir = File.expand_path("ext_memory_view_test", __dir__)
$LOAD_PATH.unshift(borrower_dir)
begin
  require "mv_borrower"
rescue LoadError
  warn "Skipping test_memory_view_simple_form: mv_borrower.bundle not built."
  warn "Build it with: (cd #{borrower_dir} && ruby extconf.rb && make)"
  return
end

class TestMemoryViewSimpleForm < Test::Unit::TestCase

  # format string -> [pack directive, item_size, carray data_type, values]
  CASES = {
    "c" => ["c*", 1, CA_INT8,    [-1, 2, -3, 4]],
    "C" => ["C*", 1, CA_UINT8,   [1, 2, 3, 250]],
    "s" => ["s*", 2, CA_INT16,   [-1000, 2000, -3000, 4000]],
    "S" => ["S*", 2, CA_UINT16,  [1, 2, 3, 60000]],
    "l" => ["l*", 4, CA_INT32,   [-1, 2, -3, 100000]],
    "L" => ["L*", 4, CA_UINT32,  [1, 2, 3, 4_000_000]],
    "q" => ["q*", 8, CA_INT64,   [1, 2, 3, 9_000_000_000]],
    "Q" => ["Q*", 8, CA_UINT64,  [1, 2, 3, 9_000_000_000]],
    "f" => ["f*", 4, CA_FLOAT32, [1.5, 2.5, -3.5, 4.5]],
    "d" => ["d*", 8, CA_FLOAT64, [1.5, 2.5, -3.5, 4.5]],
  }

  # A SIMPLE-form producer: typed, ndim == 1, shape/strides omitted.
  def simple (values, pack, format, item_size)
    MVBorrower::Producer.new(values.pack(pack), format, item_size, true)
  end

  # --- from_memory_view: SIMPLE-form typed producer, all data types -------

  def test_from_memory_view_all_data_types
    CASES.each do |format, (pack, item_size, data_type, values)|
      src = simple(values, pack, format, item_size)
      ca = CArray.from_memory_view(src)
      assert_equal(data_type, ca.data_type, "#{format}: data_type")
      assert_equal([values.length], ca.shape, "#{format}: shape")
      assert_equal(values, ca.to_a, "#{format}: values")
    end
  end

  # --- wrap_memory_view: zero-copy CAWrap of a contiguous 1-D source ------

  def test_wrap_memory_view_zero_copy
    w = CArray.wrap_memory_view(simple([10, 20, 30, 40], "q*", "q", 8))
    assert_equal(CAWrap, w.class)
    assert_equal([10, 20, 30, 40], w.to_a)
    assert_true(w.read_only?, "read-only producer yields a read-only wrap")
  end

  # --- explicit data_type marker class dispatch ---------------------------

  def test_explicit_class_dispatch
    ca = CArray::Int32.from_memory_view(simple([1, 2, 3], "l*", "l", 4))
    assert_equal(CA_INT32, ca.data_type)
    assert_equal([1, 2, 3], ca.to_a)
  end

  # --- data_type probing reads the format with no shape to lean on --------

  def test_probe_reads_format_without_shape
    assert_equal(:float64, CArray.result_type(simple([1.0, 2.0], "d*", "d", 8)))
  end

  # --- acquire/release stability: pins the rb_memory_view_t zero-init -----
  #     Without it, the sloppy producer's release() frees stack garbage.

  def sloppy (values, pack, format, item_size)
    MVBorrower::Producer.new(values.pack(pack), format, item_size, true, true)
  end

  def test_acquire_release_stability
    src = sloppy([1.0, 2.0, 3.0, 4.0], "d*", "d", 8)
    assert_nothing_raised do
      100.times { CArray.from_memory_view(src) }
    end
    assert_equal([1.0, 2.0, 3.0, 4.0], CArray.from_memory_view(src).to_a)
  end

  def test_acquire_release_stability_on_probe
    src = sloppy([1, 2, 3], "l*", "l", 4)
    assert_nothing_raised do
      100.times { CArray.result_type(src) }
    end
  end
end
