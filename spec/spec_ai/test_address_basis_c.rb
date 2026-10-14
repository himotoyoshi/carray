# ca_with_address_bases, the C entry to the address bases, used by an
# extension compiled outside carray (spec/spec_ai/ext_address_basis).  A
# kernel reads cells by address across rows (a stencil) and writes by
# address; whatever the arrays are -- an entity, a view folded down to one,
# a gathered view, a lazy expression -- the answer is the same computation
# on the arrays' copies, and a write lands as a store through the view.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_address_basis", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "address_basis_c"
rescue LoadError
  warn "Skipping test_address_basis_c: address_basis_c not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

# A CAObject view: cells come from Ruby, a write goes to a Hash.
class ABComputed < CAObject
  attr_reader :written
  def initialize (rows, cols)
    super(CA_FLOAT64, [rows, cols])
    @cols = cols
    @written = {}
  end
  private
  def fetch_addr (addr) = @written.fetch(addr) { ((addr * 37) % 101).to_f }
  def store_addr (addr, val) = (@written[addr] = val)
  def create_mask; end
end

class TestAddressBasisC < Test::Unit::TestCase

  def base
    CArray.float64(6, 5) { |i| ((i * 37) % 101).to_f }
  end

  def expected (a)
    c = a.copy
    n = c.shape[0]
    (c[0..n - 3, nil] + c[2..n - 1, nil]).to_a
  end

  SOURCES = {
    "entity"    => ->(r) { r },
    "row block" => ->(r) { r[1..5, nil] },
    "transpose" => ->(r) { CArray.float64(5, 6) { |i| ((i * 13) % 97).to_f }.transpose },
    "grid"      => ->(r) { r[CA_INT64([0, 2, 1, 4, 3, 5]), nil] },
    "fake"      => ->(r) { CArray.int32(6, 5) { |i| (i * 7) % 50 }.fake(:float64) },
    "lazy"      => ->(r) { (r.lazy * 2) + 1 },
    "CAObject"  => ->(r) { ABComputed.new(6, 5) },
  }

  def test_a_stencil_reads_across_rows_of_any_source
    SOURCES.each do |name, mk|
      a = mk.call(base)
      out = CArray.float64(a.shape[0] - 2, a.shape[1])
      CArray.ab_stencil(a, out)
      assert_equal expected(a), out.to_a, name
    end
  end

  def test_a_stencil_writes_through_a_view_of_the_destination
    a = base
    {
      "transpose" => ->() { r = CArray.float64(5, 4); [r, r.transpose] },
      "grid"      => ->() { r = CArray.float64(6, 5); [r, r[CA_INT64([3, 0, 2, 1]), nil]] },
    }.each do |name, mk|
      r, out = mk.call
      CArray.ab_stencil(a, out)
      assert_equal expected(a), out.to_a, name
    end
  end

  def test_a_stencil_writes_into_a_caobject
    a = base
    out = ABComputed.new(4, 5)
    before = out.to_a.flatten
    CArray.ab_stencil(a, out)
    assert_equal expected(a), out.to_a
    # only the cells whose value changed are sent back
    want = expected(a).flatten
    changed = (0...want.size).reject { |i| before[i] == want[i] }
    assert_equal changed, out.written.keys.sort
  end

  def test_a_box_write_reaches_a_caobject_only_inside_the_box
    o = ABComputed.new(6, 5)
    CArray.ab_fill_box(o, 1, 2, 2, 3, -1.0)
    assert_equal [7, 8, 9, 12, 13, 14], o.written.keys.sort
    assert o.written.values.all? { |v| v == -1.0 }
  end

  def test_a_box_write_leaves_the_cells_outside_it
    big = 2**53 + 1
    {
      "entity" => ->() { r = base; [r, r] },
      "grid"   => ->() { r = base; [r, r[CA_INT64([5, 0, 3, 1, 4, 2]), nil]] },
      "lossy fake" => ->() { r = CArray.int64(6, 5) { big }; [r, r.fake(:float64)] },
    }.each do |name, mk|
      r, v = mk.call
      ref = r.copy
      ref_v = name == "lossy fake" ? ref.fake(:float64) :
              name == "grid" ? ref[CA_INT64([5, 0, 3, 1, 4, 2]), nil] : ref
      ref_v[1..2, 2..4] = -1.0
      CArray.ab_fill_box(v, 1, 2, 2, 3, -1.0)
      assert_equal ref.to_a, r.to_a, name
    end
  end

  def test_a_box_outside_the_array_is_refused
    assert_raise(ArgumentError) { CArray.ab_fill_box(base, 5, 0, 2, 1, 0.0) }
  end

  def test_a_write_lands_when_the_body_raises
    [->(r) { r }, ->(r) { r[CA_INT64([1, 0, 2, 3, 4, 5]), nil] }].each do |mk|
      r = base
      v = mk.call(r)
      assert_raise(RuntimeError) { CArray.ab_write_then_raise(v) }
      assert_equal 42.0, v[0, 0]
    end
  end

  def test_read_only_and_object_arrays_are_refused
    assert_raise(RuntimeError) { CArray.ab_write_then_raise(base.lazy + 1) }
    o = CArray.object(6, 5) { 1.0 }
    assert_raise(ArgumentError) { CArray.ab_stencil(o, CArray.float64(4, 5)) }
  end

  def test_the_masks_are_lent_with_the_cells
    [->(r) { r }, ->(r) { r[CA_INT64([0, 2, 1, 4, 3, 5]), nil] }].each do |mk|
      r = base
      r[1, 1] = UNDEF
      a = mk.call(r)
      out = CArray.float64(4, 5)
      out.mask = 0
      CArray.ab_stencil(a, out)
      c = a.copy
      want = (0...4).map { |i| (0...5).map { |j| c.mask[i, j] || c.mask[i + 2, j] } }
      assert_equal want, out.mask.to_a
      (0...4).each do |i|
        (0...5).each do |j|
          next if want[i][j]
          assert_equal c[i, j] + c[i + 2, j], out[i, j]
        end
      end
    end
  end

end
