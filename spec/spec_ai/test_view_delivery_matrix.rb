# frozen_string_literal: true
#
# View delivery matrix -- every view class read every way, against itself.
#
# A view does not have one way of handing over its cells, it has several:
# xfer_all answers `.copy`, xfer_stride answers a block index, xfer_index
# answers one cell, xfer_addrs answers a list of addresses.  They are separate
# implementations of the same question, so a view can be right through one and
# wrong through another, and nothing in the view itself notices.
#
# That is the failure mode this file is aimed at, and it is the dangerous one
# for a numerical library: the wrong answer is a plausible number, not a raise.
# A test cannot recognise a plausible wrong number on its own -- it needs a
# second opinion.  The second opinion here is `v.copy`, an entity built by the
# whole-view path: every other way of reading v must agree with reading it.
#
# Two things make this catch rather than pass:
#
#   1. the roster is read back out of the class tree, so a view class added
#      later cannot quietly go unread (same mechanism as the identity matrix)
#   2. every row's values must actually differ from each other.  A view whose
#      cells all read alike agrees with itself no matter which cells it read,
#      which is exactly how a lazy compare that never saw a NaN passed this
#      shape of test for a while.  So degenerate data fails the table.

require "test/unit"
require "carray"
require "carray/categorical"

class TestViewDeliveryMatrix < Test::Unit::TestCase

  class DeliveryObject < CAObject
    def initialize
      super(CA_INT32, [4], read_only: true)
    end

    private

    def fetch_index (idx)
      idx[0] * 7 + 1
    end
  end

  NAN = 0.0 / 0.0

  def self.base
    CArray.float64(4, 4).seq! + 1
  end

  # A right-hand operand that alternates, so a comparison against it is true
  # for some cells and false for others whichever cells get read.
  def self.alternating
    CArray.float64(4, 4) { |i, j| (i + j).even? ? 99.0 : -99.0 }
  end

  def self.with_nans
    CArray.float64(4, 4) { |i, j| (i + j).even? ? NAN : (i * 4 + j).to_f }
  end

  VIEWS = {
    "CABlock"        => -> { base[1..2, nil] },
    "CARefer"        => -> { base.refer(CA_FLOAT64, [2, 8]) },
    "CAStride"       => -> { base.reshape(2, 8) },
    "CATranspose"    => -> { base.transpose },
    "CAFarray"       => -> { base.farray },
    "CARepeat"       => -> { (CArray.int32(1, 4).seq! + 1).broadcast_to(3, 4) },
    "CAField"        => -> { a = CArray.fixlen(4, bytes: 8); f = a.field(0, CA_INT32); f[] = CA_INT32([3, 1, 4, 1]); f },
    "CATile"         => -> { base.tile(2, 2) },
    "CARoll"         => -> { base.roll(1, 1) },
    "CASelect"       => -> { a = base; a[a.gt(5)] },
    "CASelectAxis"   => -> { base[CArray.boolean(4) { |i| i.even? }, nil] },
    "CAGrid"         => -> { base[CA_INT32([0, 2]), CA_INT32([1, 3])] },
    "CARemap"        => -> {
      i = CArray.new(CA_SIZE, [4, 4]); i[] = (0...16).to_a.reverse
      base[i]
    },
    "CAShift"        => -> { base.shift(1, 1) },
    "CAWindow"       => -> { base.window(-1..1, -1..1) },
    "CAStack"        => -> { CArray.stack([base, base * 2]) },
    "CAMeld"         => -> { CAMeld.new([base, CArray.float64(2, 4).seq! - 5], axis: 0) },
    "CAFake"         => -> { base.fake(CA_INT32) },
    "CAByteSwap"     => -> { a = CArray.fixlen(4, bytes: 8); a[] = %w[abcdefgh ijklmnop qrstuvwx yzABCDEF]; a.swap_bytes },
    "CABitfield"     => -> { CArray.int32(4).seq!.bitfield(0..1) },
    "CABitarray"     => -> { CArray.int32(4).seq!.bitarray },
    "CALazyMarker"   => -> { base.lazy },
    "CAMonOp"        => -> { -base.lazy },
    "CABinOp"        => -> { base.lazy + alternating.lazy },
    # a compare needs data that answers both ways: is_nan over an array with
    # no NaN in it reads alike everywhere and cannot fail
    "CAMonCmp"       => -> { with_nans.lazy.is_nan },
    "CABinCmp"       => -> { base.lazy.gt(alternating.lazy) },
    "CABinCmp/scalar"=> -> { base.lazy.gt(8.5) },
    "CATriOp"        => -> { base.lazy.clip(5.0, 11.0) },
    "CATime"         => -> { CArray.time(%w[2024-01-01 2024-02-29 2024-03-15 2024-12-31], unit: :D) },
    "CATimedelta"    => -> { (CArray.int64(4).seq! * 3 + 1).timedelta(unit: :D) },
    "CAConstString"  => -> { CArray.const_string(%w[ab cde f ghij]) },
    "CAString"       => -> { CArray.const_string(%w[ab cde f ghij]).to_string },
    "CAFixlenString" => -> { CArray.fixlen_string(%w[ab cd ef gh]) },
    "CARecord"       => -> {
      s = CArray.struct(pack: 1) { uint16 :x; uint32 :y }
      r = CARecord.new(s, 4)
      r["x"] = CA_INT32([1, 2, 3, 4])
      r["y"] = CA_INT32([9, 8, 7, 6])
      r
    },
    "CAObject"       => -> { DeliveryObject.new },
    "CACategorical"  => -> { CA_OBJECT(%w[ab cd ef cd]).categorize },
  }.freeze

  # Each probe reads an array some way and returns something comparable.  What
  # matters is that they do not all land on the same delivery slot.
  PROBES = {
    "whole []"       => ->(x) { x[].to_a },
    "to_a"           => ->(x) { x.to_a },
    "one cell"       => ->(x) { x[1] },
    "range"          => ->(x) { x[1..2].to_a },
    "[nil]"          => ->(x) { x[nil].to_a },
    "block step 2"   => ->(x) { x[[0, (x.elements + 1) / 2, 2]].to_a },
    "block step 2 @1"=> ->(x) { x[[1, x.elements / 2, 2]].to_a },
    "block step 3"   => ->(x) { x[[0, (x.elements + 2) / 3, 3]].to_a },
    "address list"   => ->(x) { x[CA_SIZE([2, 0, 1, 0])].to_a },
    "flatten"        => ->(x) { x.flatten.to_a },
    "reverse"        => ->(x) { x.reverse.to_a },
    "each"           => ->(x) { r = []; x.each { |v| r << v }; r },
    "copy again"     => ->(x) { x.copy.to_a },
  }.freeze

  def base;        self.class.base;        end
  def alternating; self.class.alternating; end
  def with_nans;   self.class.with_nans;   end

  def each_view
    VIEWS.each { |name, build| yield name, instance_exec(&build) }
  end

  # A probe that does not apply to a view's shape or type raises on the entity
  # too; that is not a disagreement, it is a question the view cannot be asked.
  def applies? (probe, entity)
    probe.call(entity)
    true
  rescue StandardError
    false
  end

  # ---- 1. every way of reading a view says the same thing -----------------

  def test_every_read_path_agrees_with_the_entity
    each_view do |name, view|
      entity = view.copy
      PROBES.each do |pname, probe|
        next unless applies?(probe, entity)
        want = probe.call(entity)
        got  =
          begin
            probe.call(view)
          rescue StandardError => e
            flunk "#{name} / #{pname}: raised through the view but not the " \
                  "entity -- #{e.class}: #{e.message}"
          end
        assert_equal want, got,
                     "#{name} / #{pname}: reading through the view disagrees " \
                     "with reading the entity it materialises to"
      end
    end
  end

  # ---- 2. the rows are worth comparing ------------------------------------

  # A view whose cells all read alike agrees with itself whichever cells it
  # read, so it cannot fail the test above.  Requiring two distinct values
  # keeps a row from going quiet as the data around it changes.
  def test_every_row_has_values_that_can_disagree
    each_view do |name, view|
      values = view.copy.to_a.flatten
      assert_operator values.uniq.size, :>=, 2,
                      "#{name}: every cell reads alike, so no wrong cell " \
                      "could show up in the comparisons above"
    end
  end

  # ---- 3. the table covers every view class in tree ------------------------

  DOCUMENTED_OMISSIONS = {
    "CAFace"   => "abstract base; only its subclasses are ever built",
    "CAReduce" => "built only inside C (the mask of a byte-reinterpreting " \
                  "CARefer, and kernel_iterator scratch); never wrapped " \
                  "into a Ruby object",
  }.freeze

  IN_TREE_ROOTS = %w[lib ext].map { |d| File.expand_path("../../#{d}", __dir__) }

  def in_tree_descendants_of (klass)
    ObjectSpace.each_object(Class).select { |k|
      next false unless k.name && k != klass && k < klass
      loc = Object.const_source_location(k.name)
      path = loc && loc[0]
      path && IN_TREE_ROOTS.any? { |root| path.start_with?(root + File::SEPARATOR) }
    }.map(&:name).sort
  end

  def test_every_caview_descendant_is_read_here
    roster = in_tree_descendants_of(CAView).reject { |n| n.end_with?("Mask") }
    # a row may name a variant ("CABinCmp/scalar"); the class is the head
    covered = VIEWS.keys.map { |n| n.split("/").first }
    assert_equal [], roster - (covered + DOCUMENTED_OMISSIONS.keys),
                 "a CAView descendant is read by nothing in this table"
  end

  def test_every_row_builds_the_class_its_name_starts_with
    each_view do |name, view|
      head = name.split("/").first
      assert_kind_of Object.const_get(head), view, "#{name}: built something else"
    end
  end
end
