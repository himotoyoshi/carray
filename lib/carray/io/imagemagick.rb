# ----------------------------------------------------------------------------
#
#  carray/io/imagemagick.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

#
# carray/imagemagick.rb
#
# This library adds image loading/saving functions to CArray class.
# These method uses the command line tools in ImageMagick internally.
# ImageMagick package is required to use this library, but RMagick
# library is not required.
#
# --- CArray.load_by_magick(filename[, map="rgb", data_type=nil])
#
# Creates a CArray object from the image file _filename_.
# The argument _map_ should be the combination of [r|g|b|a|o|i|c|m|y|b|p].
# The dimension of new array is determined from map's contents.
# The data_type of array is determined automatically by the depth of image,
# unless the data_type is not given.
#
# --- CArray#save_by_magick(filename[, image_type="rgb", options=""])
#
# Saves a CArray object to the image file _filename_.
# The argument _image_type_ should be the one of
#   * gray, rgb, rgba, cmyk, cmyka
# The _options_ are passed to "convert"
#
# --- CArray#display_by_magick([image_type="rgb", options=""])
#

require 'yaml'
require 'carray'

class CArray

  private
  @@magick_tempfile_count = 0

  public
  def self.load_by_magick (filename, imap = "rgb", data_type = nil)
    if not File.exist?(filename)
      raise "can't find image file '#{filename}'"
    end
    identify_command = [
                        "identify",
                        "-format " + "'" + [
                                           "---",
                                           "height: %h",
                                           "width: %w",
                                           "depth: %z",
                                          ].join("\n") + "'",
                        filename,
                        "2>/dev/null"
                       ].join(" ")
    ident = YAML.load(`#{identify_command}`)
    if ident.empty?
      raise "ImageMagick's identify command failed to read image file '#{filename}'"
    end
    height, width, depth = ident.values_at('height', 'width', 'depth')
    unless data_type
      case depth
      when 8
        data_type = CA_UINT8
      when 16
        data_type = CA_UINT16
      when 32
        data_type = CA_UINT32
      end
    end
    storage_type = case data_type
                   when CA_UINT8, CA_INT8
                     "char"
                   when CA_UINT16, CA_INT16
                     "short"
                   when CA_UINT32, CA_INT32
                     "integer"
                   when CA_FLOAT32
                     "float"
                   when CA_FLOAT64
                     "double"
                   else
                     raise "invalid data_type"
                   end
    tempfile = "CA_Magick_#{$$}_#{@@magick_tempfile_count}.dat"
    @@magick_tempfile_count += 1
    stream_command = [
                      "stream",
                      "-storage-type #{storage_type}",
                      "-map #{imap}",
                      filename,
                      tempfile,
                      "2>/dev/null"
                     ].join(" ")
    begin
      system stream_command
      return open(tempfile) { |io|
        if imap.size == 1
          CArray.new(data_type, [height, width]).load_binary(io)
        else
          CArray.new(data_type, [height, width, imap.size]).load_binary(io)
        end
      }
    rescue
      raise "ImageMagick's stream command failed to read image file '#{filename}'"
    ensure
      if File.exist?(tempfile)
        File.unlink(tempfile)
      end
    end
  end

  private

  def magick_guess_image_type
    image_type = nil
    case rank
    when 2
      if fixlen?
        case bytes
        when 1
          image_type = "gray"
        when 3
          image_type = "rgb"
        when 4
          image_type = "rgba"
        end
      else
        image_type = "gray"
      end
    when 3
      case dim2
      when 1
        image_type = "gray"
      when 3
        image_type = "rgb"
      when 4
        image_type = "rgba"
      end
    end
    return image_type
  end

  public

  def save_by_magick (filename, image_type = nil, options = "")
    unless image_type
      image_type = magick_guess_image_type()
    end
    unless image_type
      raise "please specify image_type"
    end
    quantum_format = self.float? ? "-define quantum:format=floating-point" : ""
    case self.data_type
    when CA_INT8, CA_UINT8
      depth = "-depth 8"
    when CA_INT16, CA_UINT16
      depth = "-depth 16"
    when CA_FIXLEN
      depth = "-depth #{8*bytes}"
    else
      depth = "-depth 8"
    end
    convert_command = [
                       "convert",
                       depth,
                       "-size " + [dim1, dim0].join("x"),
                       quantum_format,
                       options,
                       "#{image_type}:-",
                       filename
                      ].join(" ")
    begin
      IO.popen(convert_command, "w") { |io|
        if data_type != CA_FIXLEN and data_type != CA_OBJECT
          if bytes > 1 and CArray.endian == CA_LITTLE_ENDIAN
            self.dump_binary(io)
#            swap_bytes.dump_binary(io)
          else
            self.dump_binary(io)
          end
        else
          self.dump_binary(io)
        end
      }
    rescue
      raise "ImageMagick's convert command failed to write image file '#{filename}'"
    end
  end

  def display_by_magick (image_type = nil, options = "")
    unless image_type
      image_type = magick_guess_image_type()
    end
    unless image_type
      raise "please specify image_type"
    end
    quantum_format = self.float? ? "-define quantum:format=floating-point" : ""
    depth = fixlen? ? "-depth 8" : "-depth #{8*bytes}"
    display_command = [
                       "display",
                       depth,
                       "-size " + [dim1, dim0].join("x"),
                       quantum_format,
                       options,
                       "#{image_type}:-",
                      ].join(" ")
    begin                  
      IO.popen(display_command, "w") { |io|
        if bytes > 1 and CArray.endian == CA_LITTLE_ENDIAN
          swap_bytes.dump_binary(io)
        else
          self.dump_binary(io)
        end
      }
    rescue
      raise "ImageMagick's display command failed to display image"
    end
  end

end



