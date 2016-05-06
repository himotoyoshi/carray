# ----------------------------------------------------------------------------
#
#  carray/graphics/gnuplot.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require "date"
require "time"
require "open3"
require "carray"
require "ostruct"

def CA.gnuplot (*argv, &block)
  CA::Gnuplot.new(*argv, &block)
end

class CA::Gnuplot # :nodoc:

  if File.directory?("/tmp")
    TMPDIR = "/tmp"
  else
    TMPDIR = "."    
  end

  def initialize (command = "gnuplot", stdout: STDOUT, &block)
    begin
      @io, @stdout, @stderr = Open3.popen3(command + " -noraise")
    rescue NotImplementedError
      raise NotImplementedError, "system dosen't support Open3.popen3"
    end

    @defaults        = {}
    @temp_file_count = 0
    @multiplot_mode  = false
    @script_mode     = false
    @pause_mode      = :default
    @reset_mode      = :default
    @init            = nil
    @last            = nil
    @listen = Thread.start {
      Thread.abort_on_exception = true
      begin
        stdout << @stdout.gets
        while line = @stdout.gets ### read(1024)
#          unless line =~ /\Agnuplot>/
            stdout << line
            stdout.flush
#          end
        end
      rescue IOError ### @stdout may externally closed
      end
    }

    @gnuplot_version = evaluate("GPVAL_VERSION").to_f

    epoch  = evaluate %{strftime("%Y-%m-%d",0)}
    @EP_T  = Time.parse(epoch)
    @EP_D  = Date.parse(epoch)
    @EP_DT = DateTime.parse(epoch)

    @reset_script = reset_script() ## RESET_SCRIPT

    reset
    if block_given?
      begin
        case block.arity
        when 1
          yield(self)
        when -1, 0
          instance_exec(&block)
        else
          raise "invalid # of block parameters"
        end
      ensure
        self.close
      end
    end
  end

  attr_accessor :debug, :script_mode
  attr_reader   :multiplot_mode, :multiplot_option, :last

  def close
    put("quit")
    @io.close
    @listen.join
    @stdout.close
    @stderr.close
  end

  def put (*args)
    lines = args.map {|s| s.respond_to?(:to_gnuplot) ? s.to_gnuplot : s.to_s }
    command = lines.join("\n")
    if @debug
      STDERR.puts command 
    end
    thread = Thread.start {
      begin
        size = command.size
        s = 0
        while s < size
          s += @io.write(command[s, 2048])
        end
        @io.puts
        @io.puts %{ print "SIGNAL FOR CA::Gnuplot" }
        @io.flush
      rescue Errno::EPIPE
      end
    }
    output = ""
    while line = @stderr.gets
      case line.chomp
      when /SIGNAL FOR CA::Gnuplot$/
        STDERR.print(output) if @debug and not output.empty?
        return output.chomp
      when /         line \d+: (.*?) /
        if $1 =~ /warning:/
          output << line
          STDERR.print output          
          next
        else
          output << line
          STDERR.print output
          raise "Gnuplot Processor Error"
        end
      else
        output << line 
      end
    end
  ensure
    thread.join
  end

  def reset_script
    # TO BE COMENNTED OUT
    # set size ratio 0 1,1
    # set origin 0,0
    # set lmargin  -1
    # set bmargin  -1
    # set rmargin  -1
    # set tmargin  -1
    # set locale "ja_JP.UTF-8"
    # set decimalsign
    # set encoding
    # set loadpath 
    # set fontpath 
    # set psdir
    # set fit brief errorvariables nocovariancevariables errorscaling prescale nowrap
    script = put(%{ save set "|cat 1>&2" }).split($/)
    script.delete_if {|s| s =~ /^set size ratio/ }
    script.delete_if {|s| s =~ /^set origin/ }
    script.delete_if {|s| s =~ /^set .margin/ }
    script.delete_if {|s| s =~ /^set locale/ }
    script.delete_if {|s| s =~ /^set decimalsign/ }
    script.delete_if {|s| s =~ /^set encoding/ }
    script.delete_if {|s| s =~ /^set loadpath/ }
    script.delete_if {|s| s =~ /^set fontpath/ }
    script.delete_if {|s| s =~ /^set psdir/ }
    script.delete_if {|s| s =~ /^set fit/ }
    return script.join($/)
  end

  def debug_on
    self.debug = true
  end

  def debug_off
    self.debug = false
  end

  def init (&block)
    @init = block
    @init.call
    return @init
  end

  def set (*argv)
    put "set " + argv.map{|s| s.gsub(/\n/,'') }.join(" ")
  end

  def unset (*argv)
    put "unset " + argv.map{|s| s.gsub(/\n/,'') }.join(" ")
  end

  def evaluate (expr)
    return put("print #{expr}")
  end

  def color_style (fgcolor, bgcolor = nil, framecolor = nil, shadowcolor = nil)
    if fgcolor
      @defaults[:fgcolor]     = fgcolor
      put %{ fgcolor = "#{fgcolor}" }
    end
    if bgcolor
      @defaults[:bgcolor]     = bgcolor
      put %{ bgcolor = "#{bgcolor}" }
    end
    if framecolor
      @defaults[:framecolor]  = framecolor
      put %{ framecolor = "#{framecolor}" }
    end
    if shadowcolor
      @defaults[:shadowcolor] = shadowcolor
      put %{ shadowcolor = "#{shadowcolor}" }
    end    
  end

  def framecolor (spec)
    @defaults[:framecolor] = spec
    put %{ framecolor = "#{spec}" }
  end

  alias frame_color framecolor

  def shadowcolor (spec)
    @defaults[:shadowcolor] = spec
    put %{ shadowcolor = "#{spec}" }
  end

  alias shadow_color shadowcolor

  def bgcolor (spec)
    @defaults[:bgcolor] = spec
    put %{ bgcolor = "#{spec}" }
  end

  alias bg_color bgcolor

  def fgcolor (spec)
    @defaults[:fgcolor] = spec
    put %{ fgcolor = "#{spec}" }
  end

  alias fg_color fgcolor

  def color_scheme (*names)
    if @gnuplot_version >= 5.0
      case names.first
      when :keynote
        put %{
          set linetype 1 lc rgb "#BB2C2F"
          set linetype 2 lc rgb "#5E9648"
          set linetype 3 lc rgb "#2E578B"
          set linetype 4 lc rgb "#6F3B77"
          set linetype 5 lc rgb "#002C63"
          set linetype 6 lc rgb "#E6A03D"
          set linetype 7 lc rgb "#7D807E"
          set linetype 8 lc rgb "#1B0C00"
          set linetype cycle 8
        }    
      when :grads
        put %{
          set linetype 2 lc rgb "#fa3c3c"
          set linetype 3 lc rgb "#00dc00"
          set linetype 4 lc rgb "#1e3cff"
          set linetype 5 lc rgb "#00c8c8"
          set linetype 6 lc rgb "#f00082"
          set linetype 7 lc rgb "#e6dc32"
          set linetype 8 lc rgb "#f08228"
          set linetype 9 lc rgb "#a000c8"
          set linetype 10 lc rgb "#a0e632"
          set linetype 11 lc rgb "#00a0ff"
          set linetype 12 lc rgb "#e6af2d"
          set linetype 13 lc rgb "#00d28c"
          set linetype 14 lc rgb "#8200dc"
          set linetype 15 lc rgb "#aaaaaa"
          set linetype cycle 15
        }
      when :podo
        set %{ colorsequence podo }
      when :classic
        set %{ colorsequence classic }
      when :default
        set %{ colorsequence default }
      else
        style = []
        names.each_with_index do |col, i|
          style << %{ set linetype #{i+1} lc rgb "#{col.to_s}"}
        end
        put style.join("\n")
      end
    else
      case names.first
      when :keynote
        put %{
          set style increment user
          set style line 1 lc rgb "#BB2C2F"
          set style line 2 lc rgb "#5E9648"
          set style line 3 lc rgb "#2E578B"
          set style line 4 lc rgb "#6F3B77"
          set style line 5 lc rgb "#002C63"
          set style line 6 lc rgb "#E6A03D"
          set style line 7 lc rgb "#7D807E"
          set style line 8 lc rgb "#1B0C00"
        }    
      when :grads
        put %{
          set style increment user
          set style line 2 lc rgb "#fa3c3c"
          set style line 3 lc rgb "#00dc00"
          set style line 4 lc rgb "#1e3cff"
          set style line 5 lc rgb "#00c8c8"
          set style line 6 lc rgb "#f00082"
          set style line 7 lc rgb "#e6dc32"
          set style line 8 lc rgb "#f08228"
          set style line 9 lc rgb "#a000c8"
          set style line 10 lc rgb "#a0e632"
          set style line 11 lc rgb "#00a0ff"
          set style line 12 lc rgb "#e6af2d"
          set style line 13 lc rgb "#00d28c"
          set style line 14 lc rgb "#8200dc"
          set style line 15 lc rgb "#aaaaaa"
        }
      else
        style = ["set style increment user"]
        names.each_with_index do |col, i|
          style << %{ set style line #{i+1} lc rgb "#{col.to_s}"}
        end
        put style.join("\n")
      end
    end
  end


  def pause_mode (arg = nil)
    # :none     - no pausing
    # :default  - return on terminal
    # :mouse    - mouse click on window
    # :keypress - keypress on window
    orig = @pause_mode
    if arg
      @pause_mode = arg
    else
      @pause_mode = :default
    end
    if block_given?
      begin
        yield
      ensure
        @pause_mode = orig
      end
    end
  end

  def pause (arg = -1)
    if @multiplot_mode
      return
    else
      case @pause_mode
      when :none
        return
      when :mouse
        pause_mouse
      when :keypress
        pause_keypress
      else # :key
        term = evaluate("GPVAL_TERM")
        case term
        when /x11/, /aqua/, /wxt/
          STDIN.gets
        end
      end
    end
  end
  
  def pause_mouse
    put "pause mouse"
    mx = evaluate "MOUSE_X"
    my = evaluate "MOUSE_Y"
    mk = evaluate "MOUSE_KEY"
    return [mx, my, mk]
  end

  def pause_keypress
    put "pause mouse keypress"
    mx = evaluate "MOUSE_X"
    my = evaluate "MOUSE_Y"
    mk = evaluate "MOUSE_KEY"
    return [mx, my, mk]
  end

  def reset_mode (arg = nil)
    orig = @reset_mode
    if arg
      @reset_mode = arg
    else
      @reset_mode = :default
    end
    if block_given?
      begin
        yield
      ensure
        @reset_mode = orig
      end
    end
  end

  def reset ()
    if @script_mode or @reset_mode == :none
      return
    end
    if @multiplot_mode and 
        ( @multiplot_option[:layout] or @multiplot_option[:noreset] ) 
      put @reset_script
      put("set xyplane relative 0",
          "set key Left reverse noautotitle")
    else
      put "reset"
      put("set xyplane relative 0",
          "set key Left reverse noautotitle")
    end
  end

  def terminal (text)
    text = text.split("\n").map{|l| l.strip }.join(" ").strip
    put("set term #{text}")
  end

  def output (text)
    @output = text
    text = text.split("\n").map{|l| l.strip }.join(" ").strip
    put("set output '#{text}'")
  end

  def time (data)
    case data
    when Numeric
      data
    when String
      Time.parse(data) - @EP_T
    when Time
      data - @EP_T
    when Date
      (data - @EP_D)*86400
    when DateTime
      (data - @EP_DT)*86400
    when CArray
      return data.convert(CA_DOUBLE){|x|
        case x
        when Numeric
          x
        when Time
          x - @EP_T
        when Date
          (x - @EP_D)*86400
        when DateTime
          (x - @EP_DT)*86400
        when String
          Time.parse(x) - @EP_T
        end
      }
    when Range
      time(data.first)..time(data.last)
    end
  end

  def csv (*args)
    list = []
    args.each do |arg|
      case arg
      when Array
        list.push(arg.to_ca)
      else
        list.push(arg)
      end
    end
    return CArray.join(:object, list).to_csv
  end

  private

  def with_tempfile (nfiles=1)
    tempfile = Array.new(nfiles) {
      @temp_file_count += 1
      File.join(TMPDIR, "CA_Gnuplot_#{$$}_#{@temp_file_count}.dat")
    }
    yield(*tempfile)
  ensure
    tempfile.each do |file|
      if File.exist?(file) 
        File.unlink(file)
      end
    end
  end

  def parse_args (argv, &block)
    opt = @defaults.clone
    if argv.size >= 1 and argv.last.is_a?(Hash)
      opt.update(argv.pop)
    elsif argv.size >= 1 and argv.last.is_a?(Option)
      opt = argv.pop
    end
    if block
      block.call(argv)
    end
    plots = argv.clone
    if opt.is_a? Option
      return plots, opt
    else
      return plots, Option.new(self, opt)
    end
  end

  def parse_data (list)
    list = list.clone
    conf = []
    while not list.empty? and
          ( list.last.is_a?(Fixnum) or
            list.last.is_a?(Symbol) or
            list.last.is_a?(String) or
            list.last.nil? )
      conf.unshift(list.pop)
    end
    if conf.last.is_a?(Fixnum)
      idx = conf.pop
      case idx
      when 1,2
        iy = idx
        axis = "x1y#{iy}"
      when 11,12,21,22
        ix = idx / 10
        iy = idx % 10
        axis = "x#{ix}y#{iy}"
      else
        raise "unknown axis specification"
      end
    end
    if conf.last.is_a?(Symbol)
      axis = conf.pop.to_s
    end
    using_ok = false
    using = nil
    if (conf.size == 2 or conf.size == 3 or conf.size == 4) 
      if conf.first =~ /^every /
        dataspec = conf.shift
      elsif conf.first =~ /^using /
        using = conf.shift
        using_ok = true
      else
        dataspec = nil        
      end
    else
      dataspec = nil
    end
    title, with = *conf
    if title =~ /\A\s*(col|column|columnhead|columnheader(\(.*?\)|))\s*\z/
      title = $1
    else
      title = %{"#{title}"}
    end
    return list, dataspec, using, title, with, axis
  end

  def histogram_tics (names)
    return names.to_a.map.with_index {|n,i| [i,n.to_s]}
  end

  public

  def plot_number
    return @multiplot_plot_number
  end

  def multiplot (option = {})
    @multiplot_mode   = true
    @multiplot_option = option
    @multiplot_plot_number = 1
    @saved_init = @init
    options = ""
    if option[:layout]
      options << " layout " + option[:layout].join(",") 
      if option[:columnsfirst]
        options << " columnsfirst "
      else
        options << " rowsfirst "
      end
      if option[:upwards]
        options << " upwards "
      else
        options << " downwards "
      end
    end
    if option[:scale]
      options << " scale " + option[:scale].join(",")  
    end
    if option[:offset]
      options << " offset " + option[:offset].join(",")  
    end
    if option[:title]
      options << " title '" + option[:title] + "'"
    end
    put( "set multiplot" + options )
    reset()
    yield
  ensure
    put( "unset multiplot" )    
    @multiplot_option = nil
    @multiplot_mode   = false
    @multiplot_plot_number = 0
    @init = @saved_init 
    unless option[:nopause]
      pause 
    end
    unless option[:noreset]
      reset 
    end
  end

  def canvas (*argv, &block)
    plots, opt = parse_args(argv, &block)
    put %{
      unset xtics 
      unset x2tics 
      unset ytics 
      unset y2tics 
      unset xlabel
      unset ylabel
      unset x2label
      unset y2label
      unset key
    }
    opt.set(:margin, :title, :bgcolor,
            :xaxis, :yaxis, :x2axis, :y2axis,
            :border, :parametric,
            :options)
    put %{
      plot "-" with dots
-1e30,-1e30
e
    }
    if @multiplot_mode
      @multiplot_plot_number += 1 
    end
    pause() unless opt[:nopause]
    reset() unless opt[:noreset]
  end

  def scanvas (*argv, &block)
    plots, opt = parse_args(argv, &block)
    put %{
      unset xtics 
      unset x2tics 
      unset ytics 
      unset y2tics 
      unset ztics 
      unset xlabel
      unset ylabel
      unset zlabel
      unset x2label
      unset y2label
      unset key
    }
    opt.set(:margin, :title, :bgcolor,
            :xaxis, :yaxis, :zaxis,
            :border, :parametric,
            :options)
    put %{
      splot "-" with dots
-1e30,-1e30,-1e30
e
    }
    if @multiplot_mode
      @multiplot_plot_number += 1 
    end
    pause() unless opt[:nopause]
    reset() unless opt[:noreset]
  end

  #
  # with csv file
  #  ["foo.csv","1:2","title","with","y2"]
  #
  def blank (*argv, &block)
    plots, opt = parse_args(argv, &block)
    put %{
      unset xtics
      unset ytics
      unset x2tics
      unset y2tics
      unset xlabel
      unset ylabel
      unset x2label
      unset y2label
      unset border
      unset key
      unset grid
    }
    opt.set(:margin, :title, :bgcolor,
            :parametric,
            :options)
    put %{
      plot [0:1] [0:1] "-" with dots
-1,-1
e
    }
    if @multiplot_mode
      @multiplot_plot_number += 1 
    end
    pause() unless opt[:nopause]
    reset() unless opt[:noreset]
  end

  #
  # with csv file
  #  ["foo.csv","1:2","title","with","axes"]
  #
  # with csv string
  #  ["1,2\n2,3\n4,5","1:2","title","with","axes"]
  #
  def plot (*argv, &block)
    @init.call if @init
    plots, opt = parse_args(argv, &block)
    @last = plots + [opt]
    with_tempfile(plots.size) { |*tempfile|
      plot_list = []
      plots.each_with_index do |arg, i|
        arg = arg.clone
        local_ranges = []
        loop do 
          case arg.first
          when Range
            rng = arg.shift
            local_ranges << "[" + [rng.begin,rng.end].join(":") + "] "
          when Hash
            var,rng = arg.shift.first
            case var
            when :x
              local_ranges[0] = "[" + [rng.begin,rng.end].join(":") + "] "              
            when :y
              local_ranges[1] = "[" + [rng.begin,rng.end].join(":") + "] "
            when :z
              local_ranges[2] = "[" + [rng.begin,rng.end].join(":") + "] "
            else
              local_ranges << "[#{var}=" + [rng.begin,rng.end].join(":") + "] "              
            end
          else
            break
          end
        end
        if i == 0 and not local_ranges.empty?
          local_ranges.unshift "sample"
        end
        local_ranges = local_ranges.map{|v| v.nil? ? "[:]" : v }
        if arg.first.is_a?(Symbol) and arg.first == :newhistogram
          arg.shift
          arg, dataspec, using, title, with, axis = *parse_data(arg)
          plot_cmd = [
            "newhistogram",
            using ? using : "",
            title ? title : "",
            with  ? with : "",
          ]
        elsif arg.first.is_a?(DataBlock)
          datablock = arg.shift
          if datablock.is_csv?
            put("set datafile separator ','") 
          end
          arg, dataspec, using, title, with, axis = *parse_data(arg)
          plot_cmd = local_ranges + [ 
            datablock.name,
            dataspec ? dataspec : "",
            @gnuplot_version >= 4.4 ? "volatile" : "",
            opt[:using] ? "using " + opt[:using] : 
                          using ? using : "",
            axis ? "axes #{axis}" : "",
            with ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
            title ? "title #{title}" : ""
          ]
        elsif arg.first.is_a?(String)
          file  = arg.shift
          if file =~ /\.(png|jpg)\z/ 
            arg, dataspec, using, title, with, axis = *parse_data(arg)
            plot_cmd = local_ranges + [ 
              "'#{file}'",
              dataspec ? dataspec : "",
              "binary filetype=auto", 
              @gnuplot_version >= 4.4 ? "volatile" : "",
              opt[:using] ? "using " + opt[:using] : 
                            using ? using : "",
              axis ? "axes #{axis}" : "",
              with ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
              title ? "title #{title}" : ""
            ]
          else
            if file == ""
            elsif file =~ /,/ or file =~ /[\n\r]/
              if file =~ /,/
                put("set datafile separator ','") 
              end
              file = file.gsub(/UNDEF/, "NaN")
              open(tempfile[i], "w") { |io| io.write file }
              file = tempfile[i]
            else
              unless File.exist?(file)
                raise "can't open file #{file} for plot2d"
              end
            end
            arg, dataspec, using, title, with, axis = *parse_data(arg)
            plot_cmd = local_ranges + [ 
              "'#{file}'",
              dataspec ? dataspec : "",
              @gnuplot_version >= 4.4 ? "volatile" : "",
              opt[:using] ? "using " + opt[:using] : 
                            using ? using : "",
              axis ? "axes #{axis}" : "",
              with ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
              title ? "title #{title}" : ""
            ]
          end
        elsif arg.first.is_a?(Array)
          funcs, dataspec, using, title, with, axis = *parse_data(arg)
          plot_cmd = local_ranges + [
            funcs.join(","),
            dataspec ? dataspec : "",
            opt[:using] ? "using " + opt[:using] : 
                           using ? using : "",
            axis ? "axes #{axis}" : "",
            with ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
            title ? "title #{title}" : ""
          ]
        else
          arg, dataspec, using, title, with, axis = *parse_data(arg)
          arg = arg.map{|x| CArray.wrap_readonly(x, CA_DOUBLE) }
          if with.to_s =~ /rgbimage/ or opt[:with].to_s =~ /rgbimage/
            if arg[2] and arg[2].rank >= 2 and 
               ( arg[2].size != arg[0].size or arg[2].size != arg[1].size )
              xlen = arg[0].size
              ylen = arg[1].size
              arg[0] = arg[0][ylen,:%]
              arg[1] = arg[1][:%,xlen]
              if arg[2].rank == 3
                arg2 = arg[2]
                arg[2] = arg2[nil,nil,0]
                arg[3] = arg2[nil,nil,1]
                arg[4] = arg2[nil,nil,2]
              end
            end
            is_image = true
            is_rgb   = true
          elsif with.to_s =~ /image/ or opt[:with].to_s =~ /image/
            if arg[2] and arg[2].rank == 2 and 
               ( arg[2].size != arg[0].size or arg[2].size != arg[1].size )
              xlen = arg[0].size
              ylen = arg[1].size
              arg[0] = arg[0][ylen,:%]
              arg[1] = arg[1][:%,xlen]
            end
            is_image = true
            is_rgb   = false
          else
            arg = arg.map{|x| x.rank > 1 ? x[nil] : x }
            is_image = false
          end
          out = CArray.merge(CA_DOUBLE, arg, -1)
          if is_image 
            if is_rgb
              datalen = out.dim2
              if arg.size == 1
                datalen = 1
                array = "(" + [out.dim1,out.dim0].join(',') + ")"
                record = nil
              else
                datalen = 5
                array = nil
                record = "(" + [out.dim1,out.dim0].join(',') + ")"
              end
            else
              if arg.size == 1
                datalen = 1
                array = "(" + [out.dim1,out.dim0].join(',') + ")"
                record = nil
              else
                datalen = 3
                array = nil
                record = out.dim1*out.dim0
              end
            end
          else
            datalen = arg.size
            record = out.dim0
            array = nil
          end
          open(tempfile[i], "w") { |io| 
            out.unmask_copy(0.0/0.0).dump_binary(io) 
          }
          plot_cmd = local_ranges + [ 
            "'#{tempfile[i]}'",
            "binary",
            record ? "record=#{record}" : "",
            array  ? "array=#{array}" : "",
            "format='#{'%double'*datalen}'",
            dataspec ? dataspec : "",
            @gnuplot_version >= 4.4 ? "volatile" : "",
            opt[:using] ? "using " + opt[:using] : 
                          using ? using : 
                                  "using " + "#{(1..datalen).map{|x|'%i' % x}.join(':')}",
            axis  ? "axes #{axis}" : "",
            with  ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
            title ? "title #{title}" : ""
          ]
        end
        plot_list.push(plot_cmd.join(" "))
      end
      opt.set(:margin, :title, :key, :bgcolor, :palette, 
              :timefmt, :xaxis, :x2axis, :yaxis, :y2axis,
              :cbaxis, :grid, :border, :parametric,
              :options)
      put("plot " + plot_list.join(","))
      if @multiplot_mode
        @multiplot_plot_number += 1 
      end
      pause() unless opt[:nopause]
      reset() unless opt[:noreset]
    }
  end

  alias scatter plot
  alias plot2d plot

  def splot (*argv, &block)
    @init.call if @init
    plots, opt = parse_args(argv, &block)
    @last = plots + [opt]
    with_tempfile(plots.size) { |*tempfile|
      plot_list = []
      plots.each_with_index do |arg, i|
        arg = arg.clone
        local_ranges = []
        loop do 
          case arg.first
          when Range
            rng = arg.shift
            local_ranges << "[" + [rng.begin,rng.end].join(":") + "] "
          when Hash
            var,rng = arg.shift.first
            case var
            when :x
              local_ranges[0] = "[" + [rng.begin,rng.end].join(":") + "] "              
            when :y
              local_ranges[1] = "[" + [rng.begin,rng.end].join(":") + "] "
            when :z
              local_ranges[2] = "[" + [rng.begin,rng.end].join(":") + "] "
            else
              local_ranges << "[#{var}=" + [rng.begin,rng.end].join(":") + "] "              
            end
          else
            break
          end
        end
        if i == 0 and not local_ranges.empty?
          local_ranges.unshift "sample"
        end
        local_ranges = local_ranges.map{|v| v.nil? ? "[:]" : v }
        if arg.first.is_a?(DataBlock)
          datablock = arg.shift
          if datablock.is_csv?
            put("set datafile separator ','") 
          end
          arg, dataspec, using, title, with, axis = *parse_data(arg)
          plot_cmd = local_ranges + [ 
            datablock.name,
            dataspec ? dataspec : "",
            @gnuplot_version >= 4.4 ? "volatile" : "",
            opt[:using] ? "using " + opt[:using] : 
                          using ? using : "",
            axis ? "axes #{axis}" : "",
            with ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
            title ? "title #{title}" : ""
          ]
        elsif arg.first.is_a?(String)
          file  = arg.shift
          if file =~ /\.(png|jpg)\z/ 
            arg, dataspec, using, title, with, axis = *parse_data(arg)
            plot_cmd = [
              "'#{file}'",
              dataspec ? dataspec : "",
              "binary filetype=auto", 
              @gnuplot_version >= 4.4 ? "volatile" : "",
              opt[:using] ? "using " + opt[:using] : 
                             using ? using : "",
              axis ? "axes #{axis}" : "",
              with ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
              title ? "title #{title}" : ""
            ]          
          else
            if file == ""
            elsif file =~ /,/ or file =~ /[\n\r]/
              if file =~ /,/
                put("set datafile separator ','") 
              end
              file = file.gsub(/UNDEF/, "NaN")
              open(tempfile[i], "w") { |io| io.write file }
              file = tempfile[i]            
            else
              unless File.exist?(file)
                raise "can't open file #{file} for splot"
              end
            end
            arg, dataspec, using, title, with, axis = *parse_data(arg)
            plot_cmd = [
              "'#{file}'",
              dataspec ? dataspec : "", 
              @gnuplot_version >= 4.4 ? "volatile" : "",
              opt[:using] ? "using " + opt[:using] : 
                             using ? using : "",
              axis ? "axes #{axis}" : "",
              with ? "with #{with}"
               : opt[:with] ? "with #{opt[:with]}" : "",
              title ? "title #{title}" : ""
            ]
          end
        elsif arg.first.is_a?(Array)
          funcs, dataspec, using, title, with, axis = *parse_data(arg)
          plot_cmd = [
            funcs.join(","),
            dataspec ? dataspec : "",
            opt[:using] ? "using " + opt[:using] : 
                           using ? using : "",
            axis ? "axes #{axis}" : "",
            with ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
            title ? "title #{title}" : ""
          ]
        else
          arg, dataspec, using, title, with, axis = *parse_data(arg)
          arg = arg.map{|x| CArray.wrap_readonly(x, CA_DOUBLE) }
          if arg[2] and arg[2].rank == 2 and 
              ( arg[2].size != arg[0].size or arg[2].size != arg[1].size )
            xlen = arg[0].size
            ylen = arg[1].size
            arg[0] = arg[0][ylen,:%]
            arg[1] = arg[1][:%,xlen]
            is_image = true
          elsif arg[0] and arg[0].rank == 2
            is_image = true
          elsif arg[0] and arg[0].rank == 3
            is_image = true
          else
            is_image = false
          end
          out = CArray.merge(CA_DOUBLE, arg, -1)
          if is_image 
            datalen = out.dim2 
            record = "(" + [out.dim1,out.dim0].join(",") + ")"
          else
            datalen = arg.size
            record = out.dim0
          end
          open(tempfile[i], "w") { |io| 
            out.unmask_copy(0.0/0.0).dump_binary(io) 
          }
          plot_cmd = local_ranges + [
            "'#{tempfile[i]}'",
            "binary",
            record ? "record=#{record}" : "",
            "format='#{'%double'*datalen}'",
            dataspec ? dataspec : "",
            @gnuplot_version >= 4.4 ? "volatile" : "",
            opt[:using] ? "using " + opt[:using] : 
                          using ? using : 
                                  "using " + "#{(1..datalen).map{|x|'%i' % x}.join(':')}",
            axis  ? "axes #{axis}" : "",
            with  ? "with #{with}" : opt[:with] ? "with #{opt[:with]}" : "",
            title ? "title #{title}" : ""
          ]
        end
        plot_list.push(plot_cmd.join(" "))
      end
      opt.set(:margin, :title, :key, :bgcolor, :view, :palette,
              :timefmt, :xaxis, :yaxis, :zaxis, 
              :cbaxis, :border, :parametric, :options)
      put("splot " + plot_list.join(","))
      if @multiplot_mode
        @multiplot_plot_number += 1 
      end
      pause() unless opt[:nopause]
      reset() unless opt[:noreset]
    }
  end

  alias scatter3d splot
  alias mesh3d splot
  alias grid3d splot

  def image (*argv, &block)
    raise "image() will be obsolete, use plot(..., :with=>'(rgb)image')"
  end

  def imagemap (*argv, &block)
    raise "imagemap() will be obsolete, use plot(..., :with=>'(rgb)image')"
  end

  #
  # fit(function, params, data, options)
  #
  #
  # with csv file
  #  ["foo.csv","1:2","title","with","axes"]
  #
  # with csv string
  #  ["1,2\n2,3\n4,5","1:2","title","with","axes"]
  #
  def fit (expr, params, data, opt = {})
    with_tempfile(2) { |tempfile, logfile|
      if data.first.is_a?(DataBlock)
        datablock = data.shift
        if datablock.is_csv?
          put("set datafile separator ','") 
        end
        using = data.shift
        fitdata = [
            datablock.name,
            using ? "using " + using : 
                  opt[:using] ? "using " + opt[:using] : "",
        ]
      elsif data.first.is_a?(String)
        file  = data.shift
        if file =~ /,/ or file =~ /[\n\r]/
          if file =~ /,/
            put("set datafile separator ','") 
          end
          open(tempfile, "w") { |io| io.write file }
          file = tempfile
        else
          unless File.exist?(file)
            raise "can't open file #{file} for plot2d"
          end
        end
        using = data.shift
        fitdata = [
            "'#{file}'",
            using ? "using " + using : 
                  opt[:using] ? "using " + opt[:using] : "",
        ]
      else
        arg = data.map{|x| CArray.wrap_readonly(x, CA_DOUBLE) }
        if arg[2] and arg[2].rank == 2 and 
               ( arg[2].size != arg[0].size or arg[2].size != arg[1].size )
          xlen = arg[0].size
          ylen = arg[1].size
          arg[0] = arg[0][ylen,:%]
          arg[1] = arg[1][:%,xlen]
          record = arg[0].dim1
        elsif arg[0] and arg[0].rank == 2
          record = arg[0].dim1
        else
          record = arg[0].dim0
        end
        datalen = arg.size
        out = CArray.merge(CA_DOUBLE, arg, -1)
        open(tempfile, "w") { |io| 
          out.unmask_copy(0.0/0.0).dump_binary(io) 
        }
        fitdata = [
          "'#{tempfile}'",
          "binary",
          record ? "record=#{record}" : "",
          "format='#{'%double'*datalen}'",
          "using " + ( opt[:using] || 
                         "#{(1..datalen).map{|x|'($%i)' % x}.join(':')}" ),
        ]
      end
      if opt[:ranges]
        ranges = opt[:ranges]
      else
        ranges = ""
      end
      set("fit logfile '#{logfile}' errorvariables covariancevariables")
      put("fit #{ranges} #{expr} #{fitdata.join(" ")} via " + params.map{|x| x.to_s}.join(","))
      res = OpenStruct.new
      res.expression = expr
      res.parameters = params
      result_params = put("print " + params.map{|x| x.to_s}.join(",")).split.map{|_x| _x.to_f}
      result_err    = put("print " + params.map{|x| x.to_s + "_err"}.join(",")).split.map{|_x| _x.to_f}
      result_cov    = put("print " + params.map{|x| params.map{|y| "FIT_COV_" + x.to_s + "_" + y.to_s }}.join(",")).split.map{|_x| _x.to_f}
      params.each_with_index do |name, i|
        res.send(name.to_s+"=", result_params[i])
        res.send(name.to_s+"_err=", result_err[i])
      end
      i=0
      params.each do |x|
        params.each do |y|
          res.send("cov_" + x.to_s + "_" + y.to_s + "=", result_cov[i])
        end
        i+=1
      end
      res.log = File.read(logfile)
      result = put("print FIT_NDF, FIT_WSSR, FIT_STDFIT, FIT_P")
      res.ndf, res.wssr, res.stdfit, res.fit_p = result.split.map{|_x| _x.to_f}

      return result_params, res
    }
  end

  #
  # my_palette = [[0,  '#ffffff'],
  #               [1,  '#909090'],
  #               [5,  '#000090'],
  #               [10, '#000fff'],
  #               [25, '#0090ff'],
  #               [50, '#0fffee'],
  #               [75, '#90ff70'],
  #               [100,'#ffee00'],
  #               [200,'#ff7000'],
  #               [300,'#ee0000'],
  #               [400,'#7f0000']]
  # index = gp.set_palette_discrete(depth, my_palette)
  def set_palette_discrete (data, my_palette, option = {})
    default = { :model=>"RGB", 
                :continuous=>false, 
                :lower=>nil, 
                :upper=>nil,
                :lower_label=>false,
                :upper_label=>false }
    option = default.update(option)
    model, continuous, lower, lower_label, upper, upper_label = 
            option.values_at(:model, :continuous, :lower, :lower_label, :upper, :upper_label)
    levels = my_palette.size
    scale = my_palette.map{|r| r[0] }
    scalec = scale.clone
    color = my_palette.map{|r| r[1] }
    out = []
    cbmin = 0
    cbmax = levels - 1
    maxcolors = levels-1
    if continuous
      if lower
        out << [-1, %{'#{lower}'}]
        cbmin = -1
        maxcolors += 1
      end
      (levels).times do |i|
         level  = i
         out << [level,  %{'#{color[i]}'}]
      end
      if upper
        out << [levels,   %{'#{upper}'}]
        cbmax = levels
        maxcolors += 1
      end      
    else
      if lower
        out << [-1, %{'#{lower}'}]
        out << [0,  %{'#{lower}'}]
        cbmin = -1
        maxcolors += 1
      end
      (levels-1).times do |i|
         level  = i
         level1 = i+1
         out << [level,  %{'#{color[i]}'}]
         out << [level1, %{'#{color[i]}'}]
      end
      if upper
        out << [levels-1, %{'#{upper}'}]
        out << [levels,   %{'#{upper}'}]
        cbmax = levels
        maxcolors += 1
      end      
    end
    put ["set palette model #{model} maxcolors #{maxcolors} defined (\\",
        out.map{|list| "  " + list.join(" ")}.join(",\\\n") + "\\",
        ")"].join("\n")
    out = []
    if lower and lower_label
      out << [%{''{/Symbol <}#{scale.first}'}, cbmin]
    end
    scale.each_with_index do |s, i|
      out << [%{'#{s}'}, i]
    end
    if upper and upper_label
      out << [%{'{/Symbol \\263}#{scale.last}'}, cbmax]
    end
    put %{ set cbtics (#{out.map {|d| d.join(" ")}.join(",")}) }
    put %{ set cbrange [#{cbmin}:#{cbmax}] }
    return CA_DOUBLE(scale).section(data)
  end

  #
  def set_xtics_monthly (start, last, fmt = nil, interval=nil, linewidth = 1, style = "lc rgb 'black' back")
    unless fmt
      fmt = "%b"
    end
    unless interval
      interval = 3
    end
    case start
    when String
      start = DateTime.parse(start)
    end
    case last
    when String
      last = DateTime.parse(last)
    end
    if interval < 0
      start = DateTime.parse(start.strftime("%Y-%m-01")) + 0.5
      last  = (DateTime.parse(last.strftime("%Y-%m-01"))) + 0.5 >> 1
    else
      start = DateTime.parse(start.strftime("%Y-%m-01"))
      last  = (DateTime.parse(last.strftime("%Y-%m-01"))) >> 1
    end
    set %{ xrange [#{time(start)}:#{time(last)}] }
    if linewidth > 0
      set %{ xtics  ("" 0) scale 0,2 mirror }
      set %{ x2tics ("" 0) scale 0,1 mirror }
    else
      set %{ xtics  ("" 0) scale 0,0 mirror }
      set %{ x2tics ("" 0) scale 0,0 mirror }      
    end
    d = start
    while d <= last
      set %{ xtics add ('' #{time(d)} 1) }
      set %{ xtics add ('#{d.strftime(fmt)}' #{time(d+15)} 0) }
      case interval
      when -2,2
        set %{ x2tics add ('' #{time(d+15)} 1) }
      when -3,3
        set %{ x2tics add ('' #{time(d+10)} 1) }
        set %{ x2tics add ('' #{time(d+20)} 1) }
      when -6,6
        set %{ x2tics add ('' #{time(d+5)} 1) }
        set %{ x2tics add ('' #{time(d+10)} 1) }
        set %{ x2tics add ('' #{time(d+15)} 1) }
        set %{ x2tics add ('' #{time(d+20)} 1) }
        set %{ x2tics add ('' #{time(d+25)} 1) }
      else
      end
      d >>= 1
    end
    if linewidth > 0
      d = start >> 1
      while d < last
        set %{ arrow nohead from #{time(d)}, graph 0 
                            rto graph 0, graph 1 #{style} }
        d >>= 1
      end
    end
  end  

  class DataBlock

    @@datablock_count = 0  

    def initialize (processor, *args)
      put_ok = false
      if args.size == 1 and args.first.is_a?(Symbol)
        @name = "$" + args.first.to_s
        @text = processor.put %{ print #{@name}}
      elsif args.size == 1 and args.first.is_a?(String)        
        @@datablock_count += 1
        @name = "$DBLK_#{@@datablock_count}"
        @text = args.first.dup
        put_ok = true
      else
        @@datablock_count += 1
        @name = "$DBLK_#{@@datablock_count}"
        @text = CArray.join(*args).to_csv
        @text.gsub!(/UNDEF/,"NaN")
        put_ok = true
      end
      @text.strip!
      @text.chomp!
      if put_ok
        processor.put %{
#{@name} <<__EOD__
#{@text}
__EOD__
        }
      end
    end
    
    def is_csv?
      return (@text =~ /,/)
    end
    
    def to_s
      return @text.dup
    end
    
    def to_ca
      data = []
      @text.each_line do |line|
        case line
        when /^#/
        else
          data << line.strip.split(/ +/)
        end
      end
      return CA_OBJECT(data)
    end
    
    attr_reader :name, :text
    
  end
  
  def datablock (*args)
    return DataBlock.new(self, *args)
  end

  class Option  # :nodoc:

    def initialize (processor, option)
      @processor = processor
      @o       = option
    end

    def set (*names)
      names.each do |name|
        self.send("set_#{name}")
      end
    end

    def [] (name)
      @o[name]
    end

    def []= (name, value)
      @o[name] = value
    end

    def update (hash)
      @o.update(hash)
    end

    private

    def put (*lines)
      return @processor.put(*lines)
    end

    def evaluate (expr)
      return @processor.evaluate(expr)
    end

    def set_title
      textcolor = @o[:fgcolor] ? "textcolor rgb \"#{@o[:fgcolor]}\"" : ""
      if @o[:title]
        put('set title "' + @o[:title] + '" ' + textcolor)
      end
    end

    def set_key
#      ver = evaluate("GPVAL_VERSION")
#      if ver.to_f <= 4.2
#        tc = ""
#      else
#        tc = @o[:fgcolor] ? "tc rgb \"#{@o[:fgcolor]}\"" : ""
#      end
#      put("set key #{tc}")
    end

    def set_bgcolor
      if @o[:framecolor]
        put "set object rect from screen 0, screen 0 " \
                        "to screen 1, screen 1 behind " \
                        "fc rgb '#{@o[:framecolor]}' " \
                        "fillstyle solid 1.0 noborder"
      end
      if @o[:shadowcolor]
        put "set object rect from graph 0.01, graph -0.02 " \
                        "to graph 1.01, graph 0.98 behind " \
                        "fc rgb '#{@o[:shadowcolor]}' " \
                        "fillstyle solid 1.0 noborder"
      end
      if @o[:bgcolor]
        put "set object rect from graph 0, graph 0 " \
                        "to graph 1, graph 1 behind " \
                        "fc rgb '#{@o[:bgcolor]}' " \
                        "fillstyle solid 1.0 noborder"
      end
    end

    def set_border
      if @o[:noborder]
        put("unset border")      
      end
      if @o[:noaxis]
        put("unset xtics")
        put("unset ytics")
        put("unset ztics")
        put("unset xlabel")
        put("unset ylabel")
        put("unset zlabel")
        return
      end
      if @o[:fgcolor]
        put("set border linecolor rgb \"#{@o[:fgcolor]}\" ")
        if @o[:zeroaxis]
          put("set xzeroaxis linecolor rgb \"#{@o[:fgcolor]}\" ")
          put("set yzeroaxis linecolor rgb \"#{@o[:fgcolor]}\" ")
        end
      else
        if @o[:zeroaxis]
          put("set xzeroaxis",
              "set yzeroaxis")
        end
      end
    end

    def set_axis(axis)
      label, range, fmt, tics, mtics, ticsopts = *@o[axis]
      logscale = @o["#{axis}log".intern]
      timescale = @o["#{axis}time".intern]
      reverse  = @o["#{axis}reverse".intern]
      textcolor = @o[:fgcolor] ? "textcolor rgb \"#{@o[:fgcolor]}\"" : ""
      if label
        put("set #{axis}label " + %{ "#{label} "} + textcolor)
      else
        put("unset #{axis}label")
      end
      if timescale
        put("set #{axis}data time")
      end
      if range
        case range
        when Range
          put("set #{axis}range [" + [range.begin,range.end].join(":") + "] " +
              ( reverse ? "reverse " : "" ))
        when Array
          srange = range.join(":")
          put("set #{axis}range [" + srange + "] " + ( reverse ? "reverse " : "" ))
        else
          raise "invalid range specification"
        end
      else
        if reverse
          put("set #{axis}range [*:*] reverse")
        end
      end
      if tics
        if tics.is_a?(Array)
          ticslist = tics.collect do |v|
            v = [v].flatten
            case v.size
            when 1
              v.first.to_s
            else
              ['"'+v[1].to_s+'"', v[0], v[2]||0].join(" ")
            end
          end.join(",")
          put("set #{axis}tics (#{ticslist}) #{textcolor} #{ticsopts}")
        else
          put("set #{axis}tics #{tics} #{textcolor} #{ticsopts}")
        end
      else
        put("set #{axis}tics #{textcolor} #{ticsopts}")
      end
      if mtics
        put("set m#{axis}tics #{mtics}")
      end
      if fmt
        put(%{ set format #{axis} "#{fmt}"})
      end
      if logscale
        put("set logscale #{axis}")
      end
    end

    def set_xaxis
      set_axis(:x)
    end

    def set_yaxis
      set_axis(:y)
    end

    def set_x2axis
      if @o[:x2]
        set_axis(:x2)
      end
    end

    def set_y2axis
      if @o[:y2]
        set_axis(:y2)
      end
    end

    def set_zaxis
      set_axis(:z)
    end

    def set_cbaxis
      set_axis(:cb)
    end

    def set_grid
      if @o[:grid]
        linecolor = @o[:fgcolor] ? "linecolor rgb \"#{@o[:fgcolor]}\"" : ""
        case @o[:grid]
        when Array
          tics = @o[:grid].map{|a| "#{a}tics" }.join(" ")
          put("set grid #{tics} back linetype 0 #{linecolor}")
        else
          put("set grid xtics ytics y2tics back linetype 0 #{linecolor}")
        end
      end
    end

    def set_options
      if @o[:ratio]
        put("set size ratio #{@o[:ratio]}")
#        put("set view equal xy")
      end
    end

    def set_timefmt
      if @o[:timefmt]
        put("set timefmt \"#{@o[:timefmt]}\"")
      end
    end

    def set_view
      if @o[:view]
        put("set view #{[@o[:view]].flatten.join(",")}")
      end
    end

    def set_parametric
      if @o[:parametric]
        put("set parametric")
      end
    end

    def set_margin
      if @o[:floating] or 
           ( @processor.multiplot_mode and 
               ( @processor.multiplot_option[:layout] or 
                     @processor.multiplot_option[:floating] ) )
        if @o[:nomargin]
          put("set lmargin 0",
              "set rmargin 0",
              "set tmargin 0",
              "set bmargin 0")
        end
      else
        put("set size 0.7, 0.7",
            "set origin 0.15, 0.15",
            "set lmargin 0",
            "set rmargin 0",
            "set tmargin 0",
            "set bmargin 0")
      end
    end
    
    def set_palette (*argv)
      case @o[:palette]
      when Array
        list = @o[:palette].clone
        kind = list.shift
        Palette.set(@processor, kind.intern, *list)
      else
        Palette.set(@processor, @o[:palette])
      end
    end

  end
  
  def palette (kind, *argv)
    return Palette.set(self, kind, *argv)
  end
  
  module Palette
    
    def self.quote (text)
      case text
      when Symbol
        text.to_s
      when /^\{\{(.*)\}\}$/
        $1
      else
        text = text.clone
        if text[0, 1] == "\\"
          text[1..-1]
        else
          text.gsub!(/\n/, '\\n')
          text.gsub!(/\t/, '\\t')
          text.gsub!(/"/, '\\\\"')
          '"' + text + '"'
        end
      end
    end
    
    def self.set (gp, kind, *argv)
      if argv.last.is_a?(Hash)
        opt = argv.pop
      else
        opt = {}
      end
      if opt[:model]
        gp.set %{ palette model #{opt[:model]} }
      end
      if opt[:maxcolors]
        gp.set %{ palette maxcolors #{opt[:maxcolors]} }
      end
      case kind
      when :defined
        self.set_palette_array(gp, argv)
      when :random
        n = argv.first || 10
        list = []
        n.times do |i|
          value = rand(256)*0x10000 + rand(256)*0x100 + rand(256)
          list << [i, "#%6x" % value]
        end
        self.set_palette_array(gp, list)
      when :rgbformulae
        set_palette_formula(gp, *argv[0,3])        
      when :file
        set_palette_file(gp, argv.first)                
      when :gmt
        set_palette_gmt(gp, argv.first, opt)
      when :cpt_city
        set_palette_cpt_city(gp, argv.first, opt)
      when Symbol
        set_palette_predefined(gp, kind)        
      when String
        set_palette_string(gp, kind)
      when CArray
        set_palette_carray(gp, kind)
      when Array
        self.set_palette_array(gp, kind)        
      when ColorPalette
        set_palette_color_palette(gp, kind)
      end
    end

    def self.set_palette_formula (gp, *argv)
      gp.set 'palette rgbformulae ' + argv.join(', ')
    end

    def self.set_palette_file (gp, *argv)
      gp.set 'palette file ' + quote(argv[0]) + " " + argv[1].to_s       
    end

    def self.set_palette_string (gp, string)
      gp.set "palette " + string
    end

    def self.set_palette_array (gp, array)
      gp.set "palette " + 
        'defined (' + array.map { |x|
          case x[1]
          when String
            [x[0], quote(x[1])].join(' ')
          else
            x.join(' ')
          end
        }.join(', ') + ')'
    end
    
    def self.set_palette_carray (gp, ca)
      gp.instance_exec {
        with_tempfile(1) { |tmpfile|
          open(tmpfile, "w") {|io| ca.dump_binary(io)}
          if ca.rank == 1 or ( ca.rank == 2 and ca.dim1 == 1)
            set("palette file '#{tmpfile}' binary record=#{ca.dim0} using 1:1:1 model #{model}")
          elsif ca.rank == 2 and ca.dim1 == 3
            set("palette file '#{tmpfile}' binary record=#{ca.dim0} using 1:2:3 model #{model}")
          else
            raise "invalid palette specification"
          end
        }
      }
    end
    
    def self.set_palette_color_palette (gp, pal)
      gp.put(pal.to_gnuplot)
    end

    def self.set_palette_gmt (gp, name, opt)
      cpt = ColorPalette::CPT(name, :continuous=>opt[:continuous])
      if opt[:use_scale]
        min, max = cpt.min, cpt.max
        gp.set %{ cbrange [#{min}:#{max}] }
      end
      gp.put(cpt.to_gnuplot)
    end

    def self.set_palette_cpt_city (gp, name, opt)
      file = File.expand_path(File.join(ENV["CPTCITY"],name) + ".cpt")
      cpt = ColorPalette::CPT(file, :continuous=>opt[:continuous])
      if opt[:use_scale]
        min, max = cpt.min, cpt.max
        gp.set %{ cbrange [#{min}:#{max}] }
      end
      gp.put(cpt.to_gnuplot)
    end

    def self.set_palette_predefined (gp, name)
      case name.to_s
      when "gray"
        gp.set %{ palette defined (0     "#FFFFFF", \
                                   1     "#000000") }
      when "gray_inv"
        gp.set %{ palette defined (0     "#000000", \
                                   1     "#FFFFFF") }
      when "rainbow"
        gp.set %{ palette rgbformulae 22,13,-31 }
      when "polar"
        gp.set %{ palette defined (-1 "blue",  \
                                    0 "white", \
                                    1 "red") }
      when "jet"
        gp.set %{ palette defined (0     "#00007F", \
                                   0.125 "#0000FF", \
                                   0.375 "#FFFFFF", \
                                   0.625 "#FFFF00", \
                                   0.875 "#FF0000", \
                                   1     "#7F0000") }
      when "split"
        gp.set %{ palette defined (-1.0 "#7F7FFF", \
                                   -0.5 "#000080", \
                                    0.0 "#000000", \
                                    0.5 "#800000", \
                                    1.0 "#FF7F7F" ) }
      when "green_metal"
        gp.set %{ palette defined ( 0.0    "#000000", \
                                    0.5263 "#8D8D6C", \
                                    0.6842 "#92BDBE", \
                                    1.0    "#FFFFFF" )}
      when "matlab"
        gp.set %{ palette defined ( 0 '#000090', \
                                    1 '#000fff', \
                                    2 '#0090ff', \
                                    3 '#0fffee', \
                                    4 '#90ff70', \
                                    5 '#ffee00', \
                                    6 '#ff7000', \
                                    7 '#ee0000', \
                                    8 '#7f0000')}
      when "matlabw"
        gp.set %{ palette defined ( 0 'white',
                                    0.01 '#000090', \
                                    1 '#000fff', \
                                    2 '#0090ff', \
                                    3 '#0fffee', \
                                    4 '#90ff70', \
                                    5 '#ffee00', \
                                    6 '#ff7000', \
                                    7 '#ee0000', \
                                    8 '#7f0000')}
      else
        raise "Unknown palette name"
      end
    end


  end

  class ColorPalette  # :nodoc:

    def initialize (model, levels, color, scale = nil, continuous = false)
      @model  = model
      @levels = levels
      @color  = color
      @scale  = scale || CArray.int(levels).seq!
      @continuous = continuous
    end

    attr_reader :scale, :colors

    def min
      return @scale.min
    end

    def max
      return @scale.max
    end

    def range
      return @scale.min..@scale.max
    end

    def to_gnuplot
      out = []
      maxcolors = 1024
      if @continuous
        (@levels).times do |i|
          level = @scale[i]
          out.push([level, *@color[i,nil].to_a])
        end
      else
        (@levels-1).times do |i|
          level  = @scale[i]
          level1 = @scale[i+1]
          out.push([level, *@color[i,nil].to_a])
          out.push([level1, *@color[i,nil].to_a])
        end
        maxcolors = @levels-1
      end
      return ["set palette model #{@model} maxcolors #{maxcolors} defined (\\",
        out.map{|list| "  " + list.join(" ")}.join(",\\\n") + "\\",
        ")"].join("\n")
    end

  end

  class ColorPalette

    def self.CPT (file, opt = nil)
      options = {:continuous => false}.update(opt)
      continuous = options[:continuous]
      if File.exist?(file)
        text = File.read(file)
      else
        if continuous
          text = IO.popen("makecpt -C#{file} -Z", "r") { |io| io.read }
        else
          text = IO.popen("makecpt -C#{file}", "r") { |io| io.read }        
        end 
        if text =~ /\A\s*\Z/
          raise "failed to makecpt #{file}"
        end
      end

      lines = text.split("\n").map{|line| line.strip }

      model   = "RGB"
      entries = []
      lines.each do |line|
        case line
        when /\A\#\s*COLOR_MODEL\s*=\s*\+(.+)\s*\Z/
          model = $1.upcase
        when /\A\Z/, /\A#/, /\A([FBN])\s*(.*)\Z/
          next
        else
          entries.push(line.split(/\s+/)[0,8].map{|x| x.to_f})
        end
      end

      levels = entries.size * 2
      color  = CArray.float(levels, 3)
      scale  = CArray.float(levels)
      level = 0
      entries.each do |entry|
        scale[level] = entry[0]
        color[level, nil] = entry[1, 3]
        level += 1
        scale[level] = entry[4]
        color[level, nil] = entry[5, 3]
        level += 1
      end

      if model =~ /HSV/
        color[nil, 0] /= 360
      else
        color[] /= 255
      end

      return ColorPalette.new(model, levels, color, scale, options[:contiuous])
    end

    def self.GMT (file, continuous = true)    
      return CPT(file, :continuous=>continuous)
    end
  end

end

class ColorPalette < CA::Gnuplot::ColorPalette
end

class CA::Gnuplot

  def pi2arc (th0, th1)
    return format("%f:%f", -th1+90, -th0+90)
  end

  def xtics_histogram (ticslabels)
    max = ticslabels.size - 1
    return -0.5..max+0.5, 
           (0..max).map{|k|[k,ticslabels[k]]} + (0..max-1).map{|k|[k+0.5,"",1]}
  end

  def guide_with_x11 (*arg)
    @pause_mouse_mode = arg
    @pause_mouse_term = "x11"
    __guide__
  end

  def guide_with_wxt (*arg)
    @pause_mouse_mode = arg
    @pause_mouse_term = "wxt"
    __guide__
  end

  def __guide__ 
    guides = []
    @pause_mouse_mode.each do |mode|
      guide = ""
      if mode.to_s[-1,1] == "!"
        confirm = true
        mode = mode.to_s[0..-2].intern
      else
        confirm = false
      end
      loop do
        begin
          put %{ 
            set term push 
            set term #{@pause_mouse_term}
            replot
          }
          case mode
          when :click
            puts "Wait mouse: 1-mouse click required"
            put "pause mouse"
            mx = evaluate "MOUSE_X"
            my = evaluate "MOUSE_Y"
          when :point
            puts "Draw point: 1-mouse click required"
            put "pause mouse"
            mx = evaluate "MOUSE_X"
            my = evaluate "MOUSE_Y"
            guide = %{set %{ label "" at #{mx},#{my} point }}
            set %{ label "" at #{mx},#{my} point pt 7 ps 2 }
            put %{ refresh }
          when :label, :clabel, :llabel, :rlabel
            puts "Draw label: 1-mouse click required"
            put "pause mouse"
            mx = evaluate "MOUSE_X"
            my = evaluate "MOUSE_Y"
            print "label text: "
            STDOUT.flush
            text = STDIN.gets.chomp
            case mode
            when :label, :llabel
              just = "left"
            when :clabel
              just = "center"
            when :rlabel
              just = "right"
            end
            guide = %{set %{ label #{text.dump} at #{"%.5g" % mx},#{"%.5g" %my} #{just} }}
            set %{ label #{text.dump} at #{mx},#{my} #{just} }
            put %{ refresh }
          when :arrow
            puts "Draw arrow: finish with right click"
            guide = ""
            pairs = []
            i = 0
            loop do 
              put "pause mouse"
              mx = evaluate "MOUSE_X"
              my = evaluate "MOUSE_Y"
              mb = evaluate "MOUSE_BUTTON"
              pairs << [mx, my]
              if i >= 1
                if i == 1
                  head = ""
                else
                  head = "nohead"
                end
                mx1,my1 = pairs[i-1]
                mx2,my2 = pairs[i]
                guide << %{set %{ arrow from #{"%.5g" % mx2},#{"%.5g" % my2} to #{"%.5g" % mx1},#{"%.5g" % my1} #{head}} } << "\n"
                set %{ arrow from #{"%.5g" % mx2},#{"%.5g" % my2} to #{"%.5g" % mx1},#{"%.5g" % my1} #{head}} 
                put %{ refresh }
              end
              if mb == "3"
                break
              end
              i += 1
            end
          when :key
            puts "Draw key: 1-mouse click required"
            put "pause mouse"
            mx = evaluate "MOUSE_X"
            my = evaluate "MOUSE_Y"
            guide = %{set %{ key at #{"%.5g" % mx},#{"%.5g" % my} }} 
            set %{ key at #{mx},#{my} }
            put %{ refresh }          
          else
            raise "invalid pause_mouse_mode #{@pause_mouse_mode}"
          end
          terminal %{ pop }
          if @output
            output @output
          end
          put %{ replot }
          unset %{ output }
          if confirm
            print "ok? (Y/n) "
            STDOUT.flush
            begin
              curstty = %x{stty -g}
              system "stty raw -echo -icanon isig"
              c = STDIN.getc; 
            ensure
              system "stty #{curstty}"
            end
            puts
            if c == ?N or c == ?n 
              raise
            end
          end
          break
        rescue 
          retry
        end
      end
      guides << guide 
    end
    @pause_mouse_mode = nil
    puts guides.join("\n")
    pause
  end
  

end