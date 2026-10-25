# frozen_string_literal: true
#
# spec_ai/test_fragrant.rb
#
# コードレビューで発見した「香ばしい」バグに絞ったテスト集。
# 発見したバグはすべて修正済み。全テストが pass する状態。
#
# 実行: ruby spec_ai/test_fragrant.rb
#

$:.unshift(File.join(File.dirname(__FILE__), "..", "..", "lib"))

require "test/unit"
require "carray"

# ===========================================================================
# Bug: proc_trim_bang マクロ (carray_generate.c)  [historical]
#
# 旧 hand-written clip!(min, max) で両方指定すると、rmin ループが ptr/m を
# 末尾まで進めた後、rmax ループが同じ変数を使うため配列の範囲外を操作し、
# rmax クランプが実際のデータに適用されない bug があった。
#
# 3.0 で hand-written clip!/clip は retire され、新 clip は mkkernel triop
# + Ruby wrapper (lib/carray/math.rb) で表現される。clip! 自体も
# view-by-default convention で廃止 → `a[] = a.clip(lo, hi)` で代替。
# ここでは regression pin として `a[] = a.clip(...)` 形に書き換え。
# ===========================================================================
class TestTrimBug < Test::Unit::TestCase

  def test_trim_both_bounds
    a = CArray.float(4)
    a[] = [-5.0, 2.0, 8.0, 15.0]
    a[] = a.clip(0.0, 10.0)
    assert_equal [0.0, 2.0, 8.0, 10.0], a.to_a
  end

  def test_trim_min_only
    a = CArray.float(4)
    a[] = [-5.0, 2.0, 8.0, 15.0]
    a[] = a.clip(0.0, nil)
    assert_equal [0.0, 2.0, 8.0, 15.0], a.to_a
  end

  def test_trim_max_only
    a = CArray.float(4)
    a[] = [-5.0, 2.0, 8.0, 15.0]
    a[] = a.clip(nil, 10.0)
    assert_equal [-5.0, 2.0, 8.0, 10.0], a.to_a
  end

end

# ===========================================================================
# Bug: rb_ca_each_with_index (carray_loop.c line 242)
#
# each_with_index は非破壊操作なのに rb_ca_modify を呼ぶため、
# frozen 配列で FrozenError になる。
# each, each_addr, each_index は正常 (rb_ca_modify を呼ばない)。
# ===========================================================================
class TestEachWithIndexFrozen < Test::Unit::TestCase

  def setup
    @a = CArray.int(3)
    @a[] = [10, 20, 30]
    @a.freeze
  end

  def test_each_works_on_frozen
    result = []
    assert_nothing_raised { @a.each { |v| result << v } }
    assert_equal [10, 20, 30], result
  end

  # [修正済み] each_with_index が frozen 配列で FrozenError を誤発生させる → rb_ca_modify 削除
  def test_each_with_index_should_work_on_frozen
    result = []
    assert_nothing_raised do
      @a.each_with_index { |val, idx| result << [val, idx] }
    end
    # 3.0: each_with_index yields (elem, idx0, idx1, ...) — individual args
    assert_equal [[10, 0], [20, 1], [30, 2]], result
  end

end

# ===========================================================================
# Bug: ca_object_func_clone (ca_obj_object.c line 398)
#
#   ca_object_new(ca->bytes, ca->ndim, ca->dim, ca->bytes)
#
# 第1引数は data_type (= CA_OBJECT) であるべきところに ca->bytes (= 8 on 64-bit)
# を渡している。data_type=8 は CA_FLOAT64 に相当するため、
# clone が float64 配列になる可能性がある。
# ===========================================================================
class TestCAObjectClone < Test::Unit::TestCase

  # [修正済み] clone の data_type が CA_OBJECT にならない → ca_object_func_clone の第1引数修正
  def test_clone_preserves_data_type
    a = CArray.object(3)
    a[] = [1, "two", :three]
    b = a.clone
    assert_equal a.data_type, b.data_type
    assert b.object?, "clone should still be an object array"
  end

  def test_clone_preserves_contents
    a = CArray.object(3)
    a[] = [1, "hello", :sym]
    b = a.clone
    assert_equal a.to_a, b.to_a
  end

end

# ===========================================================================
# CA_OBJECT cyclic references (carray_core.c)
#
# An object array can not hold itself.  A cell read that delivers the
# array being read is refused (ca_test_cyclic_check).  A write through
# ca_xfer_index / ca_xfer_addrs / ca_xfer_stride of a CArray that shares
# the destination's cells -- the array or a view of it -- is refused before
# it is made.  A write that reaches the cells another way (fill, a Ruby
# Array) is not checked; the read refuses it.
# ===========================================================================
class TestCyclicReference < Test::Unit::TestCase

  def object_array
    a = CArray.object(3)
    a[] = [1, 2, 3]
    a
  end

  def test_storing_the_array_into_itself_is_refused
    writes = {
      "a[i] = a"         => ->(a) { a[0] = a },
      "view[i] = a"      => ->(a) { a[0..1][0] = a },
      "a[mask][i] = a"   => ->(a) { a[a.eq(2)][0] = a },
      "a[i] = a view"    => ->(a) { a[0] = a[1..2] },
      "elem_store"       => ->(a) { a.elem_store(0, a) },
      "map!"             => ->(a) { a.map! { a } },
      "attach!"          => ->(a) { a.attach! { |x| x[0] = a } },
    }
    writes.each do |name, write|
      next if name == "attach!" && !CArray.method_defined?(:attach!)
      a = object_array
      e = assert_raise(ArgumentError, name) { write.call(a) }
      assert_match(/\A\S+: can not store an object array into itself\z/, e.message, name)
      assert_equal [1, 2, 3], a.to_a, name
      a[0] = 9
      assert_equal 9, a[0], "#{name}: the array stays usable"
    end
  end

  def test_storing_another_array_is_allowed
    a = object_array
    b = CArray.int32(2)
    a[0] = b
    assert_same b, a[0]
  end

  def test_an_array_inside_a_ruby_array_is_allowed
    a = object_array
    a[0] = [a]
    assert_same a, a[0][0]
  end

  # fill and an Array of values are not checked as they write; the read is.
  def test_a_cell_holding_the_array_refuses_reads
    [->(a) { a.fill(a) }, ->(a) { a[] = [a, 2, 3] }].each do |write|
      a = object_array
      write.call(a)
      e = assert_raise(ArgumentError) { a[0] }
      assert_equal "cyclic reference is not allowed in CArray", e.message
      assert_raise(ArgumentError) { a.to_a }
    end
  end

  # A refused read clears the check, so the array is usable again once the
  # cell is overwritten.
  def test_array_usable_after_a_refused_read
    a = object_array
    a.fill(a)
    assert_raise(ArgumentError) { a[0] }
    a[0] = 42
    assert_equal 42, a[0]
  end

  # A computation over an array that holds itself -- arithmetic, a
  # reduction, a sort, a comparison -- calls the same computation again on
  # the cell's value; entering it again is refused as cyclic, as a read is,
  # rather than recursing until the stack runs out.  Twice in one process,
  # since a second overflow used to kill it.
  def test_a_computation_over_an_array_that_holds_itself_is_refused
    ops = {
      "+"      => ->(a) { a + 0 },
      "-@"     => ->(a) { -a },
      "sum"    => ->(a) { a.sum },
      "mean"   => ->(a) { a.mean },
      "max"    => ->(a) { a.max },
      "sort"   => ->(a) { a.sort },
      "median" => ->(a) { a.median },
      "cumsum" => ->(a) { a.cumsum },
      "lt"     => ->(a) { a.lt(2) },
      "=="     => ->(a) { a == a },
      "seq!"   => ->(a) { a.seq!(a) },
    }
    2.times do
      ops.each do |name, op|
        a = object_array
        a[0..0] = [a]
        e = assert_raise(ArgumentError, name) { op.call(a) }
        assert_match(/cyclic reference is not allowed in CArray/, e.message, name)
        a[0] = 9
        assert_equal 9, a[0], "#{name}: the array stays usable"
      end
    end
  end

  # Arrays nested without a cycle still compute and compare.
  def test_nested_arrays_without_a_cycle
    a = CArray.object(1); a[0] = CA_OBJECT([1])
    b = CArray.object(1); b[0] = CA_OBJECT([1])
    assert_equal true, a == b
    x = object_array
    x.sum
    x.sort
    assert_equal [1, 2, 3], x.to_a
  end

  # An error that is not a cyclic reference leaves the array usable.
  def test_array_accessible_after_unrelated_error
    a = CArray.object(2)
    a[0] = 100
    begin
      a[99]  # IndexError
    rescue IndexError, RuntimeError
    end
    assert_equal 100, a[0],
      "array should remain accessible after non-cyclic error"
  end

end
