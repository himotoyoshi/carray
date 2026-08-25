require "pp"  # CArray#source_code uses Array#pretty_inspect

class CArray::Inspector  # :nodoc:

  def initialize (carray)
    @carray = carray
  end

  # @!visibility private
  def inspect_string
    if @carray.ndim == 0
      raise "can't inspect CArray of ndim == 0"
    end
    formatter  = get_formatter()
    class_name = get_class_name()
    type_name  = get_type_name()
    shape      = get_shape()
    data_spec  = get_data_spec(0, Array.new(@carray.ndim){0}, formatter)
    info_list  = get_info_list()
    output = ["<",
              format("%s.%s(%s)", class_name, type_name, shape.join(",")),
              ": ",
              info_list.join(" "),
              "\n",
              data_spec,
              ">"
             ].join
    return output
  end
  
  private

  def get_class_name
    return @carray.class.to_s
  end

  def get_type_name
    type_name = CArray.data_type_name(@carray.data_type)
    @carray.instance_exec {
      case data_type
      when CA_FIXLEN
        # Kernel.format explicitly: inside instance_exec self is the CArray,
        # where a bare format() would resolve to the public CArray#format.
        return Kernel.format("%s[%i]", type_name, bytes)
      else
        return type_name
      end
    }
  end

  def get_shape
    case @carray.obj_type
    when CA_OBJ_UNBOUND_REPEAT
      dim = @carray.spec
    else
      dim = @carray.shape
    end
    return dim
  end

  def get_info_list
    list = []
    @carray.instance_exec {
      # ---
      if data_class
        list << "data_class=%s" % data_class.inspect
      end
      # ---
      if scalar?
        list << "scalar"
      end
      # ---
      unless kind_of?(CScalar)
        list << "elem=%i" % elements
      end
      # ---      
      if has_mask?
        list << "mask=%i" % count_masked
      end
      # ---
      memsize = elements * bytes
      case true
      when memsize < 1024
        list << "mem=%ib" % memsize
      when memsize < 1024*1024
        list << "mem=%.1fkb" % (memsize/1024.0)
      else
        list << "mem=%.1fmb" % (memsize/1024.0/1024.0)
      end
      # ---
      if mask_array?
        list << "mask_array"
      end
      if value_array?
        list << "value_array"
      end
      # ---
      if read_only?
        list << "ro"
      end
      # ---
      if virtual? and attached?
        list << "attached"
      end
      # ---
      if has_attr?
        list << "attrs={" + attrs.keys.join(",") + "}"
      end
    }
    return list
  end

  def get_formatter
    # A Face that defines storage_to_scalar decodes each cell into a surface
    # value (CATime::Element, a String, a category label, ...) that has nothing
    # to do with the storage data_type, so the formatter must follow the decoded
    # value, not the storage.  Faces without the hook (CAString) hand back the
    # stored value itself and fall through to the storage formatters below.
    if @carray.face? and @carray.respond_to?(:storage_to_scalar)
      return lambda { |x| x.inspect }
    end
    case @carray.data_type
    when CA_BOOLEAN
      # Boolean cells fetch as true/false; show compact 1/0 (masked = _).
      # The type name in the inspect header distinguishes this from an int array.
      lambda{|x| x ? "1" : "0" }
    when CA_INT8, CA_INT16, CA_INT32, CA_INT64
      lambda{|x| "%i" % x }
    when CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64
      lambda{|x| "%u" % x }
    when CA_FLOAT32, CA_FLOAT64
      lambda{|x| x.inspect }
    when CA_CMPLX64, CA_CMPLX128
      lambda{|x| format("%s%s%si",
                        x.real.inspect, (x.imag >= 0) ? "+" : "-", x.imag.abs.inspect) }
    when CA_FIXLEN
      if @carray.data_class
        if @carray.bytes <= 6
          lambda{|x| "%s" % x.encode.dump }
        else
          lambda{|x| "%s" % (x.encode.chomp[0, 5]+"...").dump }
        end
      else
        if @carray.bytes <= 6
          lambda{|x| "%s" % x.dump }
        else
          lambda{|x| "%s" % (x.chomp[0, 5]+"...").dump }
        end
      end
    when CA_OBJECT
      lambda { |x| x.inspect }
    end
  end

  def get_data_spec (level, idx, formatter)
    io = +"[ "  # mutable buffer; `<<` below appends into it
    ndim = @carray.ndim
    dim  = @carray.shape
    if level == ndim - 1
      over = false
      dim[level].times do |i|
        idx[level] = i
        v = @carray[*idx]
        if v == UNDEF
          io << '_'
        else
          io << formatter[v]
        end
        if i != dim[level] - 1
          io << ", "
        end
        if io.length > 48 - 2*level
          if i < dim[level] - 1
            io << "..."
            over = true
          end
          break
        end
      end
      if over
        idx[level] = dim[level] - 1
        v = @carray[*idx]
        if v == UNDEF
          io << ", _"
        else
          io << ", " + formatter[v]
        end
      end
    else
      over = false
      show = [dim[level], 5].min
      show.times do |i|
        idx[level] = i
        io << get_data_spec(level+1, idx, formatter)
        if i < show - 1
          io << ",\n" + "  " * (level+1)
        end
        if i >= 2 and dim[level] > 5
          break
        end
      end
      if dim[level] > 5
        io << "... ... ..."
        over = true
      end
      if over
        idx[level] = dim[level] - 1
        io << "\n"+ "  " * (level+1) + get_data_spec(level+1, idx, formatter)
      end
    end
    io << " ]"
    return io
  end

end

class CArray

  # @overload inspect
  #   Returns a human-readable description of `self` including
  #   class, `data_type`, shape, element and memory summaries, mask
  #   count, and a truncated data preview.
  #   @return [String]
  def inspect
    return CArray::Inspector.new(self).inspect_string
  end

  private

  def desc  
    output = +""  # mutable buffer; `<<` below appends into it
    case data_type 
    when CA_FIXLEN
      output << sprintf("CArray.%s(%s, :bytes=>%i)", 
                        data_type_name, dim.inspect[1..-2], bytes)
    else
      output << sprintf("CArray.%s(%s)", 
                        data_type_name, dim.inspect[1..-2])
    end
    return output
  end
  
  public

  # @overload source_code
  #   Returns a Ruby source-like string that would reconstruct
  #   `self`, combining the type/shape descriptor with a pretty
  #   printed value block. Useful for embedding fixtures in scripts.
  #   @return [String]
  def source_code
    text = [
      desc,
      " { ",
      self.to_a.pretty_inspect.split("\n").map{|s|
        " " * (desc.length+3) + s
      }.join("\n").lstrip,
      " }"
    ].join
    return text
  end

end
