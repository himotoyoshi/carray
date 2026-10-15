require "test/unit"
require "carray"

# A Face that keeps state of its own (here a tag in an ivar, carried by
# copy_state) keeps it in every result it answers in its own terms: a view,
# a copy, and a fresh array a reduction, a scan or a partition builds.

class TestFaceRelifState < Test::Unit::TestCase

  class TaggedTicks < CAObject
    def initialize (parent, tag: :default)
      @tag = tag
      super(CA_FIXLEN, parent.shape, bytes: 8, storage: CA_INT64, parent: parent,
            face: true, orderable_storage: true)
    end
    attr_reader :tag
    def copy_state (src) ; @tag = src.tag ; end
    def storage_to_element (raw)
      raw.is_a?(String) ? raw.unpack1("q") : raw
    end
  end

  def setup
    base = CArray.int64(3, 4) { |i| (i * 7) % 11 }
    @face = TaggedTicks.new(base, tag: :hello)
  end

  def test_every_result_in_the_face_keeps_the_state
    {
      "min(axis: 0)"     => -> { @face.min(axis: 0) },
      "max(axis: 1)"     => -> { @face.max(axis: 1) },
      "cummax(axis: 1)"  => -> { @face.cummax(axis: 1) },
      "cummin(axis: 0)"  => -> { @face.cummin(axis: 0) },
      "partition_copy"   => -> { @face.partition_copy(1, axis: 1) },
      "sort(axis: 1)"    => -> { @face.sort(axis: 1) },
      "slice"            => -> { @face[0..1, nil] },
      "copy"             => -> { @face.copy },
    }.each do |name, op|
      got = op.call
      assert_kind_of TaggedTicks, got, name
      assert_equal :hello, got.tag, name
    end
  end
end
