# Object cells are VALUEs.  A view marks its buffer strictly from the moment
# the buffer is published, so a fresh buffer for object cells has to hold
# valid VALUEs before anything can run a collection (ca_alloc_cells).
#
# Every view class carray defines is listed below, either with a recipe that
# builds it with object cells or with the reason it cannot hold them.  A new
# view class fails test_every_view_class_is_listed until it is added, and the
# recipes run over roots whose cells are computed (a CAObject, a lazy
# expression) under GC.stress, where an invalid cell is marked at the first
# allocation.

require 'test/unit'
require 'carray'

class TestObjectCellsGCMatrix < Test::Unit::TestCase

  class Thirds < CAObject
    def initialize (n, m)
      super(CA_OBJECT, [n, m], read_only: true)
      @m = m
    end

    private

    def fetch_index (idx)
      Rational(idx[0] * @m + idx[1] + 1, 3)
    end
  end

  def self.entity
    CA_OBJECT(Array.new(6) { |i| Rational(i + 1, 3) }).reshape(2, 3).copy
  end

  ROOTS = {
    "CAObject" => -> { Thirds.new(2, 3) },
    "lazy"     => -> { entity.lazy + 1 },
  }

  RECIPES = {
    CABlock      => ->(r) { r[0..1, 1..2] },
    CAStride     => ->(r) { r.reshape(3, 2) },
    CATranspose  => ->(r) { r.transpose },
    CARefer      => ->(r) { r.refer(CA_OBJECT, [3, 2]) },
    CAFarray     => ->(r) { r.farray },
    CARepeat     => ->(r) { r.reshape(1, 2, 3).broadcast_to(2, 2, 3) },
    CASelect     => ->(r) { r[r > 1] },
    CASelectAxis => ->(r) { r[CA_BOOLEAN([1, 0]), nil] },
    CAGrid       => ->(r) { r[CA_INT64([1, 0])] },
    CARoll       => ->(r) { r.roll(1, 1) },
    CAShift      => ->(r) { r.shift(1, 1) },
    CAWindow     => ->(r) { r.window(-1..1, nil) },
    CATile       => ->(r) { r.tile(2, 1) },
    CAStack      => ->(r) { CArray.stack([r, r]) },
    CAMeld       => ->(r) { CArray.meld(r, r) },
    CARemap      => ->(r) { r.sort(axis: 1) },
    CAFake       => ->(r) { r.fake(CA_OBJECT) },
    CALazyMarker => ->(r) { r.lazy },
    CAMonOp      => ->(r) { -(r.lazy) },
    CABinOp      => ->(r) { r.lazy * 2 },
    CATriOp      => ->(r) { r.lazy.fma(r.lazy, r.lazy) },
    CAObject     => ->(r) { Thirds.new(2, 3) },
  }

  NO_OBJECT_CELLS = {
    CABitarray       => "refuses an object parent",
    CABitfield       => "refuses an object parent",
    CAByteSwap       => "refuses an object parent",
    CAField          => "refuses CA_OBJECT as its data type",
    CABinCmp         => "its cells are boolean",
    CAMonCmp         => "its cells are boolean",
    CAMaskOfOperands => "its cells are boolean",
    CAReduce         => "its cells are boolean",
    CACategorical    => "a CAObject whose cells are codes; the CAObject recipe covers its buffer",
  }

  # A Face's cells are its storage array's, whose views are listed here; a
  # mask's cells are boolean.  Classes defined by the test fixtures are not
  # carray's.
  def carray_view_classes
    bundle = $LOADED_FEATURES.grep(/carray_ext\./).first
    ObjectSpace.each_object(Class).select { |c|
      next false unless c < CAView && c.name && !c.name.include?("::")
      next false if c <= CAFace || c.name.end_with?("Mask")
      loc = Object.const_source_location(c.name)
      loc && (loc[0] == bundle || loc[0].include?("/lib/carray/"))
    }
  end

  def test_every_view_class_is_listed
    missing = carray_view_classes.reject { |c| RECIPES.key?(c) || NO_OBJECT_CELLS.key?(c) }
    assert_equal([], missing.map(&:name).sort,
                 "add a recipe with object cells, or the reason it has none")
  end

  def test_recipes_build_their_class_with_object_cells
    RECIPES.each do |klass, recipe|
      v = recipe.(self.class.entity)
      assert_kind_of(klass, v, klass.name)
      assert_equal(CA_OBJECT, v.data_type, klass.name)
    end
  end

  def under_stress
    GC.stress = true
    yield
  ensure
    GC.stress = false
  end

  def answers (v)
    [v.copy.to_a, v.sum]
  end

  def test_views_of_computed_cells_under_gc_stress
    ROOTS.each do |rname, root|
      RECIPES.each do |klass, recipe|
        want = answers(recipe.(root.()))
        view = recipe.(root.())
        got  = under_stress { answers(view) }
        assert_equal(want, got, "#{klass.name} over #{rname}")
      end
    end
  end

end
