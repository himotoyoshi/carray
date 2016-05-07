# ----------------------------------------------------------------------------
#
#  carray/graphics/zimg.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------


=begin

option

  :debug     => (true|false)
  :output    => filename
  :complex   => (abs|length|phase|real|imaginary)
  :colormap  => (red|blue|gray) | "filename" | [r,g,b]
  :invert    => (true|false)
  :crange    => [min,max]
  :nda_color => color
  :scale     => [x[,y]]
  :align     => [h,[,v,bcol]]
  :quality   => quality
  :interlace => (true|false)
  :colorbox  => (true|false)
  :cbox_tics =>   n
  :cbox_label  => string
  :cbox_format => string
  :display   => (true|false) | "program"
  :legend    => string
  :label     => [[x1,y1,s1], [x2,y2,s2], ...]
  :vlabel    => [[x1,y1,s1], [x2,y2,s2], ...]
  :textfont  => n
  :textcolor => "xxx"|"xxxxxx"
  :smooth    => threshold
  :contors   => [levels,"log",bg,fg] ### Not Implemented

=end

class CArray

  @@zimg_count = 0

  def zimg (option={}) # :nodoc:

    tempfile = "%zimg_#{$$}_#{@@zimg_count}.dat"
    @@zimg_count += 1

    if self.rank != 2
      raise "zimg accept only 2-D data"
    end

    option.each do |k, v|
      if k.kind_of?(String)
        option[k.intern] = v
      end
    end

    if option[:output]
      output = option[:output]
      case output
      when /.ppm$/
        outfmt = "--ppm"
      when /.pgm$/
        outfmt = "--pgm"
      when /.jpg$/i, /.jpeg$/i
        if option[:quality]
          outfmt = "--jpeg=" + option[:quality].to_s
        else
          outfmt = "--jpeg"
        end
      else
        outfmt = ""
      end
    else
      output = "-"
      outfmt = ""
    end

    if option[:interlace]
      interlace = "--interlace"
    else
      interlace = ""
    end

    case self.data_type
    when CA_UINT8
      type_spec = "--unsigned-char"
    when CA_INT8, CA_BOOLEAN
      type_spec = "--char"
    when CA_UINT16
      type_spec = "--unsigned-short"
    when CA_INT16
      type_spec = "--short"
    when CA_UINT32
      type_spec = "--unsigned-int"
    when CA_INT32
      type_spec = "--int"
    when CA_FLOAT32
      type_spec = "--float"
    when CA_FLOAT64
      type_spec = "--double"
    when CA_CMPLX64
      type_spec = "--complex-float=" + ( option[:complex] || "abs" )
    when CA_CMPLX128
      type_spec = "--complex-double=" + ( option[:complex] || "abs" )
    else
      raise "can't create image for invalid numerical data"
    end

    case option[:colormap]
    when "red", "blue", "gray"
      colormap = "--" + option[:colormap]
    when String
      if File.exist?(option[:colormap])
        colormap = "--colormap=" + option[:colormap]
      else
        raise "can't find colomap file"
      end
    when Array
      colormap = "--colormap=" + option[:colormap].join(",")
    else
      colormap = ""
    end

    if option[:crange]
      crange = "--crange=" + option[:crange].join(',')
    else
      crange = ''
    end

    if option[:nda_color]
      if option[:fill_value]
        nda = "--nda=" + [option[:fill_value], option[:nda_color]].join(',')
      else
        nda = "--nda=" + ["Infinity", option[:nda_color]].join(',')
      end
    else
      nda = ""
    end

    if option[:scale]
      scale = "--scale=" + option[:scale].join(',')
    else
      scale = ''
    end

    if option[:align]
      if option[:align].last.kind_of?(String)
        align = "--align=" + option[:align][0..-2].join('x')
                  "," + option[:align].last
      else
        align = "--align=" + option[:align].join('x')
      end
    else
      align = ''
    end

    if option[:colorbox]
      if option[:cbox_tics]
        colorbox = "--colorbox=" + option[:cbox_tics].to_s
      else
        colorbox = "--colorbox"
      end
    else
      colorbox = ""
    end

    if option[:cbox_format]
      cbox_format = option[:cbox_format]
    else
      cbox_format = ""
    end

    if option[:cbox_label]
      cbox_label = option[:cbox_label]
    else
      cbox_label = ""
    end

    geom = lambda{|x,y|
      [ (x > 0 ? "+" : '') + x.to_s, (y > 0 ? '+' :'') + y.to_s].join
    }

    label = ""
    if option[:label]
      option[:label].each do |x, y, s|
        label << "--label=" + [geom[x, y],s].join(',') + " "
      end
    end

    vlabel = ""
    if option[:vlabel]
      option[:vlabel].each do |x, y, s|
        vlabel << "--vlabel=" + [geom[x, y],s].join(',') + " "
      end
    end

    if option[:textfont]
      textfont = "--font=" + option[:textfont].to_s
    else
      textfont = ""
    end

    if option[:textcolor]
      textcolor = "--textcolor=" + option[:textcolor].to_s
    else
      textcolor = ""
    end

    case option[:smooth]
    when Numeric
      smooth = "--smooth=" + option[:smooth].to_s
    else
      if option[:smooth]
        smooth = "--smooth"
      else
        smooth = ""
      end
    end

    command = [
               "zimg",
               "--output=#{output}",
               outfmt,
               interlace,
               type_spec,
               "--size=" + self.dim.reverse.join(","),
               scale,
               align,
               colormap,
               option[:invert] ? "--invert" : "",
               crange,
               nda,
               colorbox,
               cbox_label,
               cbox_format,
               label,
               vlabel,
               textfont,
               textcolor,
               smooth,
               tempfile
              ].join(" ")

    if option[:nda_color] and self.has_mask?
      if option[:fill_value]
        out = self.unmask(option[:fill_value])
      else
        out = self.unmask(nan)
      end
    else
      out = self
    end

    open(tempfile, "w"){ |io|
      out.dump_binary(io)
    }

    if option[:debug]
      puts command
    end

    if option[:output]
      system(command)
      case option[:display]
      when String
        system([option[:display], output].join(" "))
      else
        if option[:display]
          system(["display", output].join(" "))
        end
      end
    else
      case option[:display]
      when String
        system(command + ["|", option[:display], "-"].join(" "))
      else
        if option[:display]
          system(command + ["|", "display -"].join(" "))
        end
      end
    end

  ensure
    if File.exist?(tempfile)
      File.unlink(tempfile)
    end
  end

end

