# frozen_string_literal: true
#
# View identity matrix -- every view class in tree, in one table.
#
# CArray keeps a class per kind of view where other array libraries collapse
# them all into one.  That is a promise made to the reader of `p a`: the class
# names the derivation, `virtual?` says the array computes rather than owns,
# and `parent` is the link back to what it was derived from.  The CAStride
# unification changed how these classes are implemented but was not allowed to
# touch any of that.
#
# The promise is per class, so a per-class assertion is worth little: what
# matters is that it holds for *every* view class, including the next one
# added.  So the roster is read back out of the class tree and the table has to
# account for all of it -- a new CAView descendant fails this file until VIEWS
# grows a row.  That is the whole point of the shape; the three assertions per
# row are deliberately small.
#
# Each row builds its view from a source it also hands back, so the parent link
# can be checked by object identity rather than by value.  A view that has no
# single source says so (`parent: :none` for the parentless CAObject) or names
# what it does have (`parent: :internal` for the Faces, which are built by a
# factory over storage the caller never sees).

require "test/unit"
require "carray"
# CACategorical is the one view class defined in Ruby rather than in the
# extension, and it is not loaded by default.  Requiring it here keeps the
# roster below the same whether this file runs alone or with the rest.
require "carray/categorical"

class TestViewIdentityMatrix < Test::Unit::TestCase

  # A CAObject subclass is the only way to reach CAObject at all: the class is
  # a template, and an instance exists only once someone implements a reader.
  class IdentityObject < CAObject
    def initialize
      super(CA_INT32, [4], read_only: true)
    end

    private

    def fetch_index (idx)
      idx[0]
    end
  end

  def self.base
    CArray.float64(4, 4).seq!
  end

  # `build` returns [source, view].  `parent` declares what #parent must be:
  #
  #   :source    -- the very object the row built the view from
  #   :internal  -- some array in tree, but not one the caller ever named
  #   :none      -- no parent at all
  #
  # `klass` overrides the expected class when the row cannot name it directly.
  VIEWS = [
    # ---- CAStride family: a base offset plus one stride per axis ----------
    { name: "CABlock",
      build: -> { a = base; [a, a[1..2, nil]] } },
    { name: "CARefer",
      build: -> { a = base; [a, a.refer(CA_FLOAT64, [2, 8])] } },
    { name: "CAStride",
      build: -> { a = base; [a, a.reshape(2, 8)] } },
    { name: "CATranspose",
      build: -> { a = base; [a, a.transpose] } },
    { name: "CAFarray",
      build: -> { a = base; [a, a.farray] } },
    { name: "CARepeat",
      build: -> { a = CArray.int32(1, 4).seq!; [a, a.broadcast_to(3, 4)] } },
    { name: "CAField",
      build: -> { a = CArray.fixlen(4, bytes: 8); [a, a.field(0, CA_INT32)] } },
    { name: "CATile",
      build: -> { a = base; [a, a.tile(2, 2)] } },
    { name: "CARoll",
      build: -> { a = base; [a, a.roll(1, 1)] } },

    # ---- gather / scatter: an index per cell, or per axis -----------------
    { name: "CASelect",
      build: -> { a = base; [a, a[a.gt(5)]] } },
    { name: "CASelectAxis",
      build: -> { a = base; [a, a[CArray.boolean(4) { |i| i.even? }, nil]] } },
    { name: "CAGrid",
      build: -> { a = base; [a, a[CA_INT32([0, 2]), CA_INT32([1, 3])]] } },
    { name: "CARemap",
      build: -> {
        a = base
        i = CArray.new(CA_SIZE, [4, 4]); i[] = (0...16).to_a.reverse
        [a, a[i]]
      } },

    # ---- bounded: cells outside the source are filled, not read -----------
    { name: "CAShift",
      build: -> { a = base; [a, a.shift(1, 1)] } },
    { name: "CAWindow",
      build: -> { a = base; [a, a.window(-1..1, -1..1)] } },

    # ---- multi-parent: the chain fans out here ---------------------------
    { name: "CAStack",
      build: -> { a = base; [a, CArray.stack([a, a.copy])] } },
    { name: "CAMeld",
      build: -> { a = base; [a, CAMeld.new([a, CArray.float64(2, 4).seq!], axis: 0)] } },

    # ---- reinterpreting: same bytes, read as something else ---------------
    { name: "CAFake",
      build: -> { a = base; [a, a.fake(CA_INT32)] } },
    { name: "CAByteSwap",
      # numeric byte swap is a monop; CAByteSwap keeps the fixlen cases
      build: -> { a = CArray.fixlen(4, bytes: 8); [a, a.swap_bytes] } },
    { name: "CABitfield",
      build: -> { a = CArray.int32(4).seq!; [a, a.bitfield(0..1)] } },
    { name: "CABitarray",
      build: -> { a = CArray.int32(4).seq!; [a, a.bitarray] } },

    # ---- lazy: the value is an expression, evaluated on demand ------------
    { name: "CALazyMarker",
      build: -> { a = base; [a, a.lazy] } },
    { name: "CAMonOp",
      build: -> { a = base; [a, -a.lazy] } },
    { name: "CABinOp",
      build: -> { a = base; [a, a.lazy + 1] } },
    { name: "CAMonCmp",
      build: -> { a = base; [a, a.lazy.is_nan] } },
    { name: "CABinCmp",
      build: -> { a = base; [a, a.lazy.gt(2)] } },
    { name: "CATriOp",
      build: -> { a = base; [a, a.lazy.clip(1, 5)] } },

    # ---- Faces: same storage, read as a different kind of value -----------
    { name: "CATime",     parent: :internal,
      build: -> { [nil, CArray.time(%w[2024-01-01 2024-01-02], unit: :D)] } },
    { name: "CATimedelta",
      build: -> { a = CArray.int64(2).seq!; [a, a.timedelta(unit: :D)] } },
    { name: "CAConstString", parent: :internal,
      build: -> { [nil, CArray.const_string(%w[ab cd])] } },
    { name: "CAString",   parent: :internal,
      build: -> { [nil, CArray.const_string(%w[ab cd]).to_string] } },
    { name: "CAFixlenString", parent: :internal,
      build: -> { [nil, CArray.fixlen_string(%w[ab cd])] } },
    { name: "CARecord",   parent: :internal,
      build: -> {
        s = CArray.struct(pack: 1) { uint16 :x; uint32 :y }
        [nil, CARecord.new(s, 2)]
      } },

    # ---- computed: no source array at all ---------------------------------
    { name: "CAObject", klass: IdentityObject, parent: :none,
      build: -> { [nil, IdentityObject.new] } },
    # a categorical is a CAObject over its own codes array, so unlike a bare
    # CAObject it does have a parent -- one the caller never named
    { name: "CACategorical", parent: :internal,
      build: -> { [nil, CA_OBJECT(%w[ab cd ab]).categorize] } },
  ].freeze

  def each_view
    VIEWS.each do |row|
      source, view = instance_exec(&row[:build])
      yield row, source, view
    end
  end

  def base
    self.class.base
  end

  # ---- 1. the class names the derivation ---------------------------------

  def test_every_row_builds_the_class_it_names
    each_view do |row, _source, view|
      assert_equal((row[:klass] || Object.const_get(row[:name])), view.class,
                   "#{row[:name]}: built something else")
    end
  end

  # ---- 2. a view says it computes rather than owns ------------------------

  def test_every_view_reports_itself_virtual
    each_view do |row, _source, view|
      assert_equal true,  view.virtual?, "#{row[:name]} is not virtual?"
      assert_equal false, view.entity?,  "#{row[:name]} claims to be an entity"
    end
  end

  # ---- 3. the parent link is the one the row declares ---------------------

  def test_the_parent_link_is_as_declared
    each_view do |row, source, view|
      case row[:parent] || :source
      when :source
        assert_same source, view.parent,
                    "#{row[:name]}#parent is not the array it was built from"
      when :internal
        assert_kind_of CArray, view.parent, "#{row[:name]} has no parent"
      when :none
        assert_nil view.parent, "#{row[:name]} grew a parent"
      end
    end
  end

  # A source-linked view is reachable from the chain walkers, which read the
  # same link.  The views that set CA_FLAG_MULTI_PARENTS stop the chain at
  # themselves by design -- there is no single parent to walk to -- so they are
  # named here rather than derived, and a new one fails until it is listed.
  MULTI_PARENT = %w[CAStack CAMeld CABinOp CABinCmp CATriOp].freeze

  def test_a_source_linked_view_can_walk_back_to_its_source
    each_view do |row, source, view|
      next unless (row[:parent] || :source) == :source
      next if MULTI_PARENT.include?(row[:name])
      assert_equal true, view.ancestors.include?(source),
                   "#{row[:name]} is not on a chain back to its source"
    end
  end

  # ---- 4. the table covers every view class in tree -----------------------

  # A view class left out of VIEWS is invisible to everything above, so the
  # roster is read from the class tree rather than kept by hand.
  #
  # Mask classes are not listed individually: each one is the mask of exactly
  # one view class, which is asserted below as a rule instead of as 18 rows.

  # View classes with no Ruby-reachable instance, and why.  Naming one here is
  # a claim that has to be paid off, not a way to stay quiet.
  DOCUMENTED_OMISSIONS = {
    "CAFace"   => "abstract base; only its subclasses are ever built",
    "CAReduce" => "built only inside C (the mask of a byte-reinterpreting " \
                  "CARefer, and kernel_iterator scratch); never wrapped " \
                  "into a Ruby object",
  }.freeze

  # spec_ai is required into one process and several files define view
  # subclasses as fixtures -- including this one.  A class counts as in tree
  # only when its constant was first defined under lib/ or in the extension.
  IN_TREE_ROOTS = %w[lib ext].map { |d| File.expand_path("../../#{d}", __dir__) }

  def in_tree_descendants_of (klass)
    ObjectSpace.each_object(Class).select { |k|
      next false unless k.name && k != klass && k < klass
      loc = Object.const_source_location(k.name)
      path = loc && loc[0]
      path && IN_TREE_ROOTS.any? { |root| path.start_with?(root + File::SEPARATOR) }
    }.map(&:name).sort
  end

  def test_every_caview_descendant_is_in_the_matrix
    roster = in_tree_descendants_of(CAView).reject { |n| n.end_with?("Mask") }
    accounted = VIEWS.map { |r| r[:name] } + DOCUMENTED_OMISSIONS.keys
    assert_equal [], roster - accounted,
                 "a CAView descendant is neither in VIEWS nor a documented omission"
  end

  def test_a_mask_class_sits_under_the_view_it_is_the_mask_of
    in_tree_descendants_of(CAView).select { |n| n.end_with?("Mask") }.each do |name|
      view = name.sub(/Mask\z/, "")
      assert_equal view, Object.const_get(name).superclass.name,
                   "#{name} is not defined under #{view}"
    end
  end

  def test_documented_omissions_are_still_in_tree
    DOCUMENTED_OMISSIONS.each_key do |name|
      assert_equal true, Object.const_defined?(name),
                   "#{name} is named as a documented omission but is gone"
    end
  end
end
