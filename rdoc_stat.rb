class CArray

  # Accumulates the all elements. The overflow is treated in 
  # the C-language way.
  #
  #   a = CArray.int8(2) { [127,1] };
  #   a.sum
  #   => 128.0
  #   a.accumulate
  #   => -128
  #
  #   a = CArray.uint32(2) { [0xffffffff,1] };
  #   a.sum
  #   => 4294967296.0
  #   a.accumulate
  #   => 0
  #
  #   a = CArray.float(2) { [0xffffffff,1] };
  #   a.sum
  #   => 4294967297.0
  #   a.accumulate
  #   => 4294967296.0
  #
  #   a = CArray.object(2) { [0xffffffff,1] };
  #   a.sum
  #   => 4294967296
  #   a.accumulate
  #   => 4294967296
  def accumulate (options={})
  end
end
