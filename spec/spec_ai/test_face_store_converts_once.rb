# frozen_string_literal: true
#
# A value stored into a Face goes through the Face's element_to_storage
# once. The hook below refuses anything but its own element, so a second
# call (with the storage value the first one returned) raises.

require "test/unit"
require_relative "../../lib/carray"

class TestFaceStoreConvertsOnce < Test::Unit::TestCase

  class Tenths < CAObject
    Elem = Struct.new(:v)
    class << self; attr_accessor :calls; end
    self.calls = 0
    def initialize(parent)
      super(parent.data_type, parent.shape, parent: parent, face: true,
            orderable_storage: true)
    end
    def storage_to_element(raw) = Elem.new(raw / 10.0)
    def element_to_storage(x)
      Tenths.calls += 1
      raise TypeError, "a Tenths stores an Elem, not #{x.inspect}" unless x.is_a?(Elem)
      x.v * 10.0
    end
    def to_comparable(x) = x.is_a?(Elem) ? x.v * 10.0 : raise(TypeError, x.inspect)
  end

  E = Tenths::Elem

  STORES = {
    point:      [->(t) { t[1] = E.new(1) },                       [10.0, 10.0, 30.0], 1],
    address:    [->(t) { t[[1]] = E.new(1) },                     [10.0, 10.0, 30.0], 1],
    all:        [->(t) { t[] = E.new(1) },                        [10.0, 10.0, 10.0], 1],
    block:      [->(t) { t[0..1] = E.new(1) },                    [10.0, 10.0, 30.0], 1],
    select:     [->(t) { t[t.parent.gt(15.0)] = E.new(1) },       [10.0, 10.0, 10.0], 1],
    mapping:    [->(t) { t[CA_INT64([0, 2])] = E.new(5) },        [50.0, 20.0, 50.0], 1],
    predicate:  [->(t) { t[:eq, E.new(2)] = E.new(5) },           [10.0, 50.0, 30.0], 1],
    ruby_array: [->(t) { t[0..1] = [E.new(4), E.new(5)] },        [40.0, 50.0, 30.0], 2],
    fill:       [->(t) { t.fill(E.new(7)) },                      [70.0, 70.0, 70.0], 1],
    elem_store: [->(t) { t.elem_store([2], E.new(9)) },           [10.0, 20.0, 90.0], 1],
    view:       [->(t) { t[1..2][0] = E.new(9) },                 [10.0, 90.0, 30.0], 1],
  }

  STORES.each do |name, (store, expected, calls)|
    define_method("test_#{name}_converts_once") do
      storage = CA_FLOAT64([10.0, 20.0, 30.0])
      t = Tenths.new(storage)
      Tenths.calls = 0
      store.call(t)
      assert_equal expected, storage.to_a
      assert_equal calls, Tenths.calls
    end
  end

  def test_a_flattened_store_on_two_axes_converts_once
    storage = CArray.float64(2, 2) { 0.0 }
    t = Tenths.new(storage)
    Tenths.calls = 0
    t[[3]] = E.new(2)
    assert_equal [[0.0, 0.0], [0.0, 20.0]], storage.to_a
    assert_equal 1, Tenths.calls
  end

  def test_undef_masks_the_storage_without_the_hook
    storage = CA_FLOAT64([10.0, 20.0, 30.0])
    t = Tenths.new(storage)
    Tenths.calls = 0
    t[1] = UNDEF
    assert_equal [10.0, UNDEF, 30.0], storage.to_a
    assert_equal 0, Tenths.calls
  end

  def test_a_bare_number_is_refused_by_the_hook
    t = Tenths.new(CA_FLOAT64([10.0, 20.0]))
    assert_raise(TypeError) { t[0] = 3.0 }
  end
end
