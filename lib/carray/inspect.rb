require "pp"  # CArray#source_code uses Array#pretty_inspect

class CArray::Inspector  # :nodoc:

  def initialize (carray)
    @carray = carray
  end

  # @!visibility private
  #
  #  `abbrev` false renders every element instead of eliding with `...`.
  #  It is the one difference between #inspect and #inspect_full: the
  #  header and the layout are the same, so there is one renderer rather
  #  than two that could drift apart.
  def inspect_string (abbrev: true)
    if @carray.ndim == 0
      raise "can't inspect CArray of ndim == 0"
    end
    formatter  = get_formatter()
    label      = get_label()
    shape      = get_shape()
    data_spec  = get_data_spec(0, Array.new(@carray.ndim){0}, formatter, abbrev)
    info_list  = get_info_list()
    output = ["<",
              format("%s(%s)", label, shape.join(",")),
              ": ",
              info_list.join(" "),
              "\n",
              data_spec,
              ">"
             ].join
    return output
  end
  
  private

  # The name before the shape: the class and the storage type, or for a
  # Face its own name (see .face_label).
  def get_label
    return CArray::Inspector.face_label(@carray) if @carray.face?
    return format("%s.%s", get_class_name, get_type_name)
  end

  public

  # The name a Face goes by where a person reads it -- the head of inspect,
  # a frame's column list.  A Face's data_type is the surface the kernels
  # dispatch on (fixlen for a time, so arithmetic on it raises), which says
  # nothing to a reader, so it is named by its class: what a private
  # inspect_label gives (CATime adds its tick), or the class, with the
  # surface type only for a Face whose surface is numeric.
  # The type of an array as a person reads it in a message or a table: a
  # Face by its name (face_label), any other array by its data type name.
  # Every message and listing that names a type goes through here, so a
  # Face is never named by its storage (:fixlen for a time).
  def self.type_label (ca)
    ca.face? ? face_label(ca) : CArray.data_type_name(ca.data_type).to_s
  end

  def self.face_label (ca)
    return ca.send(:inspect_label) if ca.respond_to?(:inspect_label, true)
    klass = ca.class
    klass = klass.superclass while klass.name.nil?
    return klass.name if [CA_FIXLEN, CA_OBJECT].include?(ca.data_type)
    "#{klass.name}.#{CArray.data_type_name(ca.data_type)}"
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
    return @carray.shape
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
    # A Face can write its cells itself through a private
    # inspect_cell_formatter, a lambda taking the decoded cell.
    if @carray.respond_to?(:inspect_cell_formatter, true)
      return @carray.send(:inspect_cell_formatter)
    end
    # A Face that defines storage_to_element decodes each cell into a surface
    # value (CATime::Element, a String, a category label, ...) that has nothing
    # to do with the storage data_type, so the formatter must follow the decoded
    # value, not the storage.  Faces without the hook (CAString) hand back the
    # stored value itself and fall through to the storage formatters below.
    if @carray.face? and @carray.respond_to?(:storage_to_element)
      return lambda { |x| x.inspect }
    end
    data_type = @carray.data_type
    # The same Faces behind a gated (fixlen) surface hand back the value of
    # their storage, so they take the storage's formatter.
    if @carray.face? and data_type == CA_FIXLEN and not @carray.data_class
      storage = @carray.parent.data_type
      data_type = storage unless storage == CA_FIXLEN
    end
    case data_type
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
        # A record shows its members, as the element's own inspect does.
        lambda{|x| x.inspect }
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

  def get_data_spec (level, idx, formatter, abbrev = true)
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
        if abbrev and io.length > 48 - 2*level
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
      show = abbrev ? [dim[level], 5].min : dim[level]
      show.times do |i|
        idx[level] = i
        io << get_data_spec(level+1, idx, formatter, abbrev)
        if i < show - 1
          io << ",\n" + "  " * (level+1)
        end
        if abbrev and i >= 2 and dim[level] > 5
          break
        end
      end
      if abbrev and dim[level] > 5
        io << "... ... ..."
        over = true
      end
      if over
        idx[level] = dim[level] - 1
        io << "\n"+ "  " * (level+1) + get_data_spec(level+1, idx, formatter, abbrev)
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
    # A cell of an object array can hold an expression over the array, whose
    # inspect shows the array again: that is refused as cyclic, as reading a
    # cell that holds the array is.
    return CArray::Inspector.new(self).inspect_string unless object?
    refuse_reentry("inspect") { CArray::Inspector.new(self).inspect_string }
  end

  # @overload inspect_full
  #   The same description as {#inspect}, with every element rendered
  #   instead of the `...` preview.
  #
  #   `inspect` abbreviates on purpose -- it is what `p`, `irb` and an
  #   error message call, and a million-cell array has to stay readable
  #   there. `inspect_full` is for the other moment, when the whole
  #   array is the thing you came to look at:
  #
  #     puts a.inspect_full
  #
  #   The header, the layout and the `_` for a masked cell are
  #   `inspect`'s; only the eliding is dropped, so for an array small
  #   enough that `inspect` was not abbreviating anything the two give
  #   the same string.
  #
  #   Note that neither of these is `to_s`, which returns the **raw
  #   bytes** of the storage rather than anything printable.
  #
  #   The result is one String holding every element, so it is as large
  #   as the array is: nothing here is streamed, and a line is as long
  #   as the last axis makes it.
  #
  #   @return [String]
  def inspect_full
    return CArray::Inspector.new(self).inspect_string(abbrev: false) unless object?
    refuse_reentry("inspect_full") { CArray::Inspector.new(self).inspect_string(abbrev: false) }
  end

  private

  def desc  
    output = +""  # mutable buffer; `<<` below appends into it
    case data_type 
    when CA_FIXLEN
      output << sprintf("CArray.%s(%s, :bytes=>%i)", 
                        data_type_name, shape.inspect[1..-2], bytes)
    else
      output << sprintf("CArray.%s(%s)", 
                        data_type_name, shape.inspect[1..-2])
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
