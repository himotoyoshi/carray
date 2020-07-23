$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

module TestCAVirtualMixin

  def test_fetch_index
    10.times do 
      idx = @ref.dim.map{|x| rand(x)}
      assert_equal(@ref[*idx], @obj[*idx])
    end
  end

  def test_fetch_addr
    10.times do 
      addr = rand(@ref.elements)
      assert_equal(@ref[addr], @obj[addr])
    end
  end

  def test_store_index
    unless @obj.read_only?
      10.times do 
        idx = @ref.dim.map{|x| rand(x)}
        v = rand(10)
        @ref[*idx] = v
        @obj[*idx] = v
        assert_equal(@ref[*idx], @obj[*idx])
      end
      assert_equal(@ref, @obj)
    end
  end

  def test_store_addr
    unless @obj.read_only?
      10.times do 
        addr = rand(@ref.elements)
        @ref[addr] = @obj[addr] = rand(10)
        assert_equal(@ref[addr], @obj[addr])
      end
      assert_equal(@ref, @obj)
    end
  end

  def test_attach
    assert_equal(@ref, @obj)
  end

  def test_sync
    unless @obj.read_only?
      assert_equal(@ref.seq!, @obj.seq!)
    end
  end

  def test_copy_data
    assert_equal(@ref, @obj.to_ca)
  end

  def test_sync_data
    unless @obj.read_only?
      val = @ref.reverse
      @ref[] = val
      @obj[] = val
      assert_equal(@ref, @obj)
    end
  end

  def test_fill_data
    unless @obj.read_only?
      @obj[] = 1
      assert_equal(@ref.template{1}, @obj)
    end
  end

  def test_create_mask
    unless @obj.read_only?
      5.times do 
        addr = rand(@ref.elements)
        @ref[addr] = UNDEF
        @obj[addr] = UNDEF
      end
      assert_equal(@ref, @obj)
    end
  end

end

class TestCARefer < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int32(10, 10).seq!
    orig = CArray.int32(10, 10).seq!
    @obj = orig[]
  end

end

class TestCABlock < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int32(10, 10).seq!
    orig = CArray.int32(10, 10).seq!
    @obj = orig[0..-1, 0..-1]
  end

end

class TestCASelect < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int32(10, 10).seq!.flatten
    orig = CArray.int32(10, 10).seq!
    @obj = orig[orig.true]
  end

end

class TestCAMapping < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int32(10, 10).seq!
    orig = CArray.int32(10, 10).seq!
    @obj = orig[orig]
  end

end

class TestCAGrid < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int32(10, 10).seq!
    orig = CArray.int32(10, 10).seq!
    idx  = CArray.int32(10).seq!
    @obj = @ref[idx,idx]
  end

end

class TestCARepeat < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    orig = CArray.int32(10).seq!
    @ref = CArray.int32(10, 10)
    10.times do |i|
      @ref[nil,i] = orig
    end
    @obj = orig[:%, 10]
  end

end

class TestCAFake < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int16(10, 10).seq!
    orig = CArray.int32(10,10).seq!
    @obj = orig.as_int16
  end

end

class TestCAFarray < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int32(10,10).seq!
    @ref[] = @ref.to_a.transpose
    orig = CArray.int32(10,10).seq!
    @obj = orig.t
  end

end

class TestCATranspose < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int32(10,10).seq!
    @ref[] = @ref.to_a.transpose
    orig = CArray.int32(10,10).seq!
    @obj = orig.transposed
  end

end

class TestCAWindow < Test::Unit::TestCase

  include TestCAVirtualMixin

  def setup
    @ref = CArray.int32(15,15).seq![0..9, 0..9].to_ca
    orig = CArray.int32(15,15).seq!
    @obj = orig.window(0..9, 0..9)
  end

end

