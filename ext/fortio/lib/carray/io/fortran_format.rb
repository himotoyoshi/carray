require "fortio"

class CArray

  def self.from_fortran_format (fmt, io)
    case io
    when String
      io = StringIO.new(io)
    end
    case fmt
    when String
      fmt = FortranFormat.new(fmt)
    end
    data = []
    begin
      data << fmt.read(io)
    end until io.eof?
    return data.to_ca
  end

  def to_fortran_format (fmt, input="")
    case input
    when String
      io = StringIO.new(input)
    else
      io = input
    end
    case fmt
    when String
      fmt = FortranFormat.new(fmt)
    end
    n = fmt.count_args
    attach {
      self[nil].blocks(0...n).each do |blk|
        fmt.write(io, *blk.to_a)
      end
    }
    return input
  end

end


