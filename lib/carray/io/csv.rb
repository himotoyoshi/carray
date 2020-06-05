# ----------------------------------------------------------------------------
#
#  carray/io/csv.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------
#
# CSV data reader/writer for CArray (in DSL approach)
#
# For reading (explicit form)
#
#   csv = CA::CSVReader.new {
#     header          # read a line as "names" header 
#     header :units   # read a line as "units" header 
#     skip 1          # skip a line
#     body 10         # read values
#     process { |name, column|    # post processing
#       case name                 #   name   : name of columns (string|integer) 
#       when "Date"               #   column : column carray
#         column.map!{|x| Date.parse(x) }
#       else
#         column[] = column.double
#       end
#     }
#   }
#
#   data1 = csv.read_file(file1)
#   data2 = csv.read_file(file2)
#   data3 = csv.read_file(file3)
#
# For reading (implicit form)
#
#   data = CArray.load_csv(file) { ... definitions ... }
#   data = CArray.from_csv(io|string) { ... definitions ... }
#
# For writing (explict form)
#
#   csv = CA::CSVWriter.new {
#     names ["Date", "a", "b", "c"]   # set name of columns
#     process { |name, column|        # pre processing
#       case name                     #   name   : name of column
#       when "Date"                   #   column : column carray
#         column.map!{|x| x.to_s }
#       else
#         column.map!{|x| "%.2f" % x }
#       end
#     }
#     puts "sample CSV data"          # print any string
#     header                          # write names in header
#     header ["","mm","cm","m"]       # write units in header
#     write                           # write values
#   }
#
#   data1.write_file(file1)
#   data2.write_file(file2)
#   data3.write_file(file3)
#
# For writing (implicit form)
#
#   data.save_csv(file) { ... definitions ... }
#   data.to_csv([io|string]) { ... definitions ... }
#

require "carray/io/table"
require "stringio"
require "rcsv"
require "strscan"

module CA

  class CSVReader
  
    def initialize (sep: ",", rs: $/, &block)
      @sep = sep
      @rs  = rs
      @block = block
    end

    def read_io (io)
      return Processor.new(io, sep: @sep, rs: @rs, &@block).run
    end

    def read_string (string)
      return read_io(StringIO.new(string))
    end

    def read_file (filename, encoding: nil)
      File.open(filename, encoding: encoding) { |io|
        return read_io(io)
      }
    end
  
    class Processor 
    
      def initialize (io, sep:, rs:, &block)
        @io       = io
        @sep      = sep
        @rs       = rs
        @block    = block || proc { body }
        @namelist = nil
        @names    = nil
        @headerlist = []
        @header   = {}
        @note     = ""
        @table    = nil
        @regexp_simple1 = /#{@sep}/
        @regexp_simple2 = / *#{@sep} */
        @regexp_pat1    = /\A([^"#{@sep}][^#{@sep}]*) *#{@sep} */
        @regexp_pat2    = /\A"([^"]+)" *#{@sep} */
        @regexp_pat3    = /\A"((?:[^"]+|"")+)" *#{@sep} */
        @regexp_pat4    = /\A(?:""|) *#{@sep} */ 
        @sc       = StringScanner.new("")
      end

      def run
        case @block.arity
        when 1
          @block.call(self)
        when -1, 0
          instance_exec(&@block)
        else
          raise "invalid block paramter"
        end
        if @header.has_key?("names")          
          @header["names"].each_with_index do |name, k|
            if name.nil? or name.empty?
              @header["names"][k] = "c#{k}"
            end
          end
        else
          @header["names"] = (0...@cols).map{|k| "c#{k}"}
        end
        header = @header
        note  = @note
        @table.instance_exec{ 
          @names  = header["names"]
          @header = header
          @note  = note
        }
        @table.extend(CA::TableMethods)
        @table.column_names = header["names"]
        class << @table
          attr_reader :note
          def header (name=nil)
            if name
              return @header[name.to_s]
            else
              return @header
            end
          end
        end
        return @table
      end

      def column_names (*namelist)
        if @header.has_key?("names")
          warn "override header['names']"
        end
        @names = namelist.map(&:to_s)
        @header["names"] = @names
        return namelist
      end

      alias columns column_names

      def header (name = "names")
        name = name.to_s
        list = csv_feed()
        if name == "names"
          if @names 
            raise "already 'names' defined"
          end
          @names = list
        end
        @header[name] = list
        @headerlist.push(name)
        return list
      end

      attr_reader :names

      def note (n=1)
        list = []
        n.times { list << @io.gets(@rs) }
        @note << (text = list.join)
        return text
      end

      def skip (n=1)
        n.times { @io.gets(@rs) }
      end

      def body (n=nil, cols=nil)
        data = []
        count = 0
        if cols
          @cols = cols
        elsif @names
          @cols = @names.size
        else
          list = csv_feed()
          if list.nil?
            @rows  = 0
            @table = CArray.object(@rows, @cols)
            return
          end
          data.push(list)
          count += 1
          @cols = list.size
        end
        if n
          lsize = nil
          while count < n and list = csv_feed(@cols)
            lsize = list.size
            if lsize == @cols
              data.push(list)             
            elsif lsize <= @cols
              record = Array.new(@cols, nil)
              record[0,lsize] = list
              data.push(record)
            else
              extra = Array.new(lsize - @cols, nil)
              data.each do |row|
                row.push(*extra)
              end
              data.push(list)
              @cols = lsize
  #            raise "csv parse error : too large column number at line #{@io.lineno}"
            end
            count += 1
          end
        else
          unless @io.eof?
            data += Rcsv.parse(@io, column_separator: @sep, header: :none)
          end
        end
        @rows  = data.size
        @table = CArray.object(@rows, @cols){ data }
        @table[:eq,""] = nil
      end

      def rename (name, newname)
        names = @header["names"]
        i = names.index(name)
        names[i] = newname
        @names = @header["names"]
      end

      def downcase
        @header["names"] = @header["names"].map(&:downcase)
        @names = @header["names"]
      end

      def select (*namelist)
        @namelist = namelist.empty? ? nil : namelist
        case @namelist
        when nil
        when Array
          index = (0...@cols).map.to_a
          index_list = @namelist.map{ |x|
            case x
            when Integer
              x
            when Range
              index[x]
            when String, Symbol
              if @names and i = @names.index(x.to_s) 
                i
              else
                raise "invalid argument #{x}"
              end
            else
              raise "invalid argument"
            end
          }.flatten
          @table = @table[nil, CA_INT(index_list)].to_ca
          @header.keys.each do |k|
            @header[k] = @header[k].values_at(*index_list)
          end
          @names = @header["names"]
        else
          raise
        end
      end

      def process
        if @namelist
          @namelist.each_with_index do |name, i|
            yield(name, @table[nil, i])
          end
        elsif @names
          @names.each_with_index do |name, i|
            yield(name, @table[nil, i])
          end
        else
          @table.dim1.times do |i|
            yield(i, @table[nil,i])
          end
        end
      end

      def convert (data_type, options={}, &block)
        if block_given?
          if data_type.is_a?(Class) and data_type < CA::Struct
            @table = @table[:i, nil].convert(data_type, &block) 
          else
            @table = @table.convert(data_type, options, &block)
          end
        else
          if data_type.is_a?(Class) and data_type < CA::Struct
            @table = @table[:i,nil].convert(data_type) { |b|
              data_type.new(*b[0,nil])
            }
          else
            @table = @table.to_type(data_type, options)
          end
        end
      end

      private

      def csv_feed (cols=nil)
        if @io.eof?
          return nil
        end
        line = nil
        loop do
          if newline = @io.gets(@rs)
            if line
              line << newline
            else
              line = newline
            end
            count_quote = line.count('"')
          else
            line = ""
            count_quote = 0
          end
          if count_quote == 0
            line.chomp!
            if line.count(' ') == 0
              return line.split(@sep, -1) ### /#{@sep}/
            else
              return line.split(@regexp_simple2, -1) ### / *#{@sep} */
            end
          end
          if count_quote % 2 == 0 
            line.chomp!
            return csv_split(line, cols)
          else
            if newline
              next
            else
              raise "csv parse error"
            end
          end
        end
      end

      def csv_split (text, cols=nil)
        if cols
          csv = Array.new(cols)
        else
          csv = []
        end
        text << @sep
        @sc.string = text
        i = 0
        begin
          case
          when @sc.scan(@regexp_pat1)
                    ### /\A([^"#{@sep}][^#{@sep}]*) *#{@sep} */
            csv[i] = @sc[1]
          when @sc.scan(@regexp_pat2)
                    ### /\A"([^"]+)" *#{@sep} */
            csv[i] = @sc[1]
          when @sc.scan(@regexp_pat3)
                    ### /\A"((?:[^"]+|"")+)" *#{@sep} */
            s = @sc[1]
            if s =~ /"/
              csv[i] = s.gsub(/""/, '"') 
            else
              csv[i] = s
            end
          when @sc.scan(@regexp_pat4)
                    ### /\A(?:""|) *#{@sep} */
            csv[i] = nil
          else
            raise "csv parse error"
          end
          i += 1
        end until @sc.eos?
        return csv
      end

    end
  
  end
  
end

module CA

  class CSVWriter      # :nodoc:

    def initialize (sep=",", rs=$/, fill="", &block)
      @block = block
      @sep   = sep
      @rs    = rs
      @fill  = fill
    end

    def write_io (table, io)
      return Processor.new(table, io, @sep, @rs, @fill, &@block).run
    end

    def write_string (table, string) 
      write_io(table, StringIO.new(string))
      return string
    end

    def write_file (table, filename, mode="w")
      open(filename, mode) { |io|
        return write_io(table, io)
      }
    end

    class Processor   # :nodoc:

      def initialize (table, io, sep, rs, fill, &block)
        @io       = io
        @sep      = sep
        @rs       = rs
        @fill     = fill
        @block    = block || proc { body }
        if table.has_data_class?
          @names = table.members
          @table = CArray.merge(CA_OBJECT, table[nil].fields)
        else
          @names = table.instance_exec{ @names }
          if @names.nil?
            @names = table.instance_exec{ @column_names }          
          end
          case
          when table.rank > 2
            @table = table.reshape(false,nil).object
          when table.rank == 1
            @table = table[:%,1].object  ### convert to CA_OBJECT            
          else
            @table = table.object  ### convert to CA_OBJECT
          end
        end
        if @table.has_mask?
          @table.unmask(@fill)
        end
        @regexp_simple = /#{@sep}/o
      end

      def csv_quote (text)
        text = text.dup
        if text.gsub!(/"/, '""') or text =~ @regexp_simple ### /#{@sep}|"/
          text = '"' + text + '"'
        end
        return text
      end

      def run 
        case @block.arity
        when 1
          @block.call(self)
        when -1, 0
          instance_exec(&@block)
        else
          raise "invalid block parameter"
        end
      end

      # set @names 
      def names (list)
        @names = list
      end

      # puts header
      def header (list = @names)
        @io.write list.map{|s| csv_quote(s)}.join(@sep)
        @io.write(@rs)
      end

      # puts any strings
      def puts (*argv)
        @io.print(*argv)
        @io.write(@rs)
      end

      # write value
      # If option :strict is set, do csv_quote for string element
      def body (strict: true, format: nil)
        if strict
          case @table.data_type
          when CA_OBJECT
            table = @table.to_ca
            table[:is_kind_of, String].map! { |s| csv_quote(s) } 
          when CA_FIXLEN
            table = @table.object
            table.map! { |s| csv_quote(s) }
          else
            table = @table.object 
          end
        else
          table = @table
        end
        if format
          table.dim0.times do |i|
            @io.write Kernel::format(format,*table[i,nil].to_a)
            @io.write(@rs)
          end          
        else
          table.dim0.times do |i|
            @io.write table[i,nil].to_a.join(@sep)
            @io.write(@rs)
          end
        end
      end

      # pre processing data
      def process (namelist = @names)
        if namelist 
          namelist.each_with_index do |name, i|
            yield(name, @table[nil, i])
          end
        else
          @table.dim1.times do |i|
            yield(i, @table[nil,i])
          end
        end
      end
    end
  end
end

class CArray

  def self.load_csv (file, sep: ",", rs: $/, encoding: nil, &block)
    reader = CA::CSVReader.new(sep: sep, rs: rs, &block)
    return reader.read_file(file, encoding: encoding)
  end
  
  def self.from_csv (io, sep: ",", rs: $/, &block)
    reader = CA::CSVReader.new(sep: sep, rs: rs, &block)
    case io
    when IO, StringIO
      return reader.read_io(io)
    when String
      return reader.read_string(io)
    else
      raise "invalid argument"
    end
  end

  def save_csv (file, option = {}, rs: $/, sep: ",", fill: "", mode: "w", &block)
    option = {:sep=>sep, :rs=>rs, :fill=>fill, :mode=>mode}.update(option)
    writer = CA::CSVWriter.new(option[:sep], option[:rs], option[:fill], &block)
    return writer.write_file(self, file, option[:mode])
  end

  def to_csv (io="", option ={}, rs: $/, sep: ",", fill: "", &block)
    option = {:sep=>sep, :rs=>rs, :fill=>fill}.update(option)
    writer = CA::CSVWriter.new(option[:sep], option[:rs], option[:fill], &block)
    case io
    when IO, StringIO
      return writer.write_io(self, io)
    when String
      return writer.write_string(self, io)
    end
  end

  def to_tabular (option = {})
    option = {:sep=>" ", :names=>nil}.update(option)
    if option[:names]
      names = option[:names]
    elsif self.respond_to?(:names)
      names = self.names
    end
    sep = option[:sep]
    data = self.to_ca.map! {|s| s.to_s }
    table  = CArray.join([names.to_ca], [data])
    length = table.convert{|s| s.length}.max(0)
    table.map_with_index! {|s, idx| s.rjust(length[idx[1]]) }.to_csv.gsub(/,/,sep)
  end

end

