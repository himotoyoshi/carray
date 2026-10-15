# frozen_string_literal: true
#
# A Face's storage is read as its order only when the Face declares
# ORDERABLE_STORAGE (docs/authoring/FaceOrderingSearch.md).  A Face that
# defines its own #order answers by that order; any other Face is refused by
# every family that orders, compares, searches or hashes its cells.
#
# The in-tree Faces whose storage is not their order (CAConstString,
# CARecord, CACategorical) all answer for themselves in Ruby, so the families
# never met one that does not.  A Face written by a user does not: here a
# little-endian uint16 kept in 2-byte fixlen cells, whose byte order is not
# the order of its values (256 = 00 01 sorts before 1 = 01 00).
#
# Before, the families disagreed about it: the reductions took a fixlen
# storage as ordered by memcmp and answered min = 256 for [256, 1, 2, 300];
# the sort family handed it to its own #order, which is CArray#order and came
# straight back, until the stack ran out.

require "test/unit"
require "carray"

class TestFaceOrderGateUserFixlen < Test::Unit::TestCase

  class LE16 < CAObject
    def initialize (parent)
      super(CA_FIXLEN, parent.shape, bytes: 2, parent: parent, face: true)
    end

    def storage_to_element (raw)
      raw.unpack1("v")
    end
  end

  # The same Face with an order of its own: the families that can take a key
  # order by it.
  class LE16Ordered < LE16
    def order (descending: false, method: :ordinal, **kw)
      CA_INT64(to_a).order(descending: descending, method: method, **kw)
    end
  end

  VALUES = [256, 1, 2, 300].freeze

  def storage
    s = CArray.fixlen(VALUES.size, bytes: 2)
    VALUES.each_with_index { |v, i| s[i] = [v].pack("v") }
    s
  end

  def le16 ; LE16.new(storage) ; end

  def refused (&block)
    e = assert_raise(ArgumentError, &block)
    assert_match(/LE16 is not orderable by storage/, e.message)
  end

  def test_the_face_reads_its_values
    assert_equal VALUES, le16.to_a
  end

  # ---- reductions: no memcmp on a fixlen storage that is not ORDERABLE ----

  def test_reductions_refuse
    a = le16
    refused { a.min }
    refused { a.max }
    refused { a.minmax }
    refused { a.reshape(2, 2).max(axis: 0) }
    refused { a.lazy.min }
  end

  # ---- the sort family: no recursion through CArray#order ----------------

  def test_sort_family_refuses
    a = le16
    refused { a.sort }
    refused { a.sort_addr }
    refused { a.rank_index }
    refused { a.partition_copy(1) }
    refused { a.nlargest(2) }
    refused { CA_INT32([1, 2, 3, 4]).max_by_key(a) }
  end

  # ---- search, interpolation, equality, comparison -----------------------

  def test_search_and_equality_refuse
    a = le16
    refused { a.bsearch(a[1..1]) }
    refused { a.linear_section(a[1..1]) }
    refused { a.unique }
    refused { a.is_in(a[1..1]) }
    refused { a.count(a[1]) }
    refused { a < a[2] }
  end

  # ---- a Face with its own #order is ordered by it -----------------------

  def test_own_order_orders_the_key_families
    a = LE16Ordered.new(storage)
    assert_equal [1, 2, 0, 3], a.sort_addr.to_a
    assert_equal [1, 2, 256, 300], a.sort.to_a
    assert_equal [2, 0, 1, 3], a.rank_index.to_a
    assert_equal [300, 256], a.nlargest(2).to_a
    assert_equal 4, CA_INT32([1, 2, 3, 4]).max_by_key(a)
  end

  # Its own order is a key, not a storage: a family that has to read the
  # storage still refuses it.
  def test_own_order_does_not_unlock_the_storage
    a = LE16Ordered.new(storage)
    e = assert_raise(ArgumentError) { a.min }
    assert_match(/not orderable by storage/, e.message)
    assert_raise(ArgumentError) { a.unique }
  end

end
