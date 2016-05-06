# ----------------------------------------------------------------------------
#
#  carray/graphics/imagemap.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require 'carray'

#
# CArray#index_linear(scale)
# CArray#index_log10(scale)
#
# ImageMap.create_image_map_linear(idx, n, palette, mask_color)
# ImageMap.create_image_map_log10(idx, n, palette, mask_color)
#

class ImageMap < CArray

  def line (x0, y0, x1, y1, z)
    x0 = (x0 - @xoffset)*@xscale
    y0 = (y0 - @yoffset)*@yscale
    x1 = (x1 - @xoffset)*@xscale
    y1 = (y1 - @yoffset)*@yscale
    draw_line(y0, x0, y1, x1, z)
  end

  def polyline (x, y, z)
    x = (x - @xoffset).mul!(@xscale)
    y = (y - @xoffset).mul!(@xscale)
    draw_polyline(y, x, z)
  end

  def map_points (pw, pu, pv)
    lines, pixels = pw.dim0, pw.dim1
    gx = CArray.float(lines, pixels)
    gy = CArray.float(lines, pixels)
    yield(pu,pv,gx,gy)
    gx.sub!(@xoffset).mul!(@xscale)
    gy.sub!(@yoffset).mul!(@yscale)
    draw_points(gy, gx, pw)
  end

  def warp_image0 (pw, pu, pv)
    lines, pixels = pw.dim0, pw.dim1
    mu = CArray.float(lines, pixels+1)
    mv = CArray.float(lines, pixels+1)
    gu = CArray.float(lines+1, pixels+1)
    gv = CArray.float(lines+1, pixels+1)
    gx = CArray.float(lines+1, pixels+1)
    gy = CArray.float(lines+1, pixels+1)
    CArray.attach(pu,pv,pw) {
      [[pu,mu,gu], [pv,mv,gv]].each do |p,m,g|
        m[nil,1..-2] =  0.5*p[nil,0..-2] + 0.5*p[nil,1..-1]
        m[nil,0]     =  1.5*p[nil,0]     - 0.5*p[nil,1]
        m[nil,-1]    = -0.5*p[nil,-2]    + 1.5*p[nil,-1]
        g[1..-2,nil] =  0.5*m[0..-2,nil] + 0.5*m[1..-1,nil]
        g[ 0,nil]    =  1.5*m[0,nil]     - 0.5*m[1,nil]
        g[-1,nil]    = -0.5*m[-2,nil]    + 1.5*m[-1,nil]
      end
      yield(gu,gv,gx,gy)
      gx.sub!(@xoffset).mul!(@xscale)
      gy.sub!(@yoffset).mul!(@yscale)
      fill_rectangle_image(gy, gx, pw)
    }
  end

  def warp_image1 (pw, pu, pv)
    lines, pixels = pw.dim0, pw.dim1
    px = CArray.float(lines, pixels)
    py = CArray.float(lines, pixels)
    mx = CArray.float(lines, pixels+1)
    my = CArray.float(lines, pixels+1)
    gx = CArray.float(lines+1, pixels+1)
    gy = CArray.float(lines+1, pixels+1)
    CArray.attach(pu,pv,pw) {
      yield(pu,pv,px,py)
      px.sub!(@xoffset).mul!(@xscale)
      py.sub!(@yoffset).mul!(@yscale)
      [[px,mx,gx], [py,my,gy]].each do |p,m,g|
        m[nil,1..-2] =  0.5*p[nil,0..-2] + 0.5*p[nil,1..-1]
        m[nil,0]     =  1.5*p[nil,0]     - 0.5*p[nil,1]
        m[nil,-1]    = -0.5*p[nil,-2]    + 1.5*p[nil,-1]
        g[1..-2,nil] =  0.5*m[0..-2,nil] + 0.5*m[1..-1,nil]
        g[ 0,nil]    =  1.5*m[0,nil]     - 0.5*m[1,nil]
        g[-1,nil]    = -0.5*m[-2,nil]    + 1.5*m[-1,nil]
      end
      fill_rectangle_image(gy, gx, pw)
    }
  end

  def warp_grid (pw, pu, pv)
    lines, pixels = pw.dim0, pw.dim1
    gx = CArray.float(lines, pixels)
    gy = CArray.float(lines, pixels)
    CArray.attach(pu,pv,pw) {
      yield(pu,pv,gx,gy)
      gx.sub!(@xoffset).mul!(@xscale)
      gy.sub!(@yoffset).mul!(@yscale)
      fill_rectangle_grid(gy, gx, pw)
    }
  end

  def warp_image_gradation (pw, pu, pv)
    lines, pixels = pw.dim0, pw.dim1
    mu = CArray.float(lines, pixels+1)
    mv = CArray.float(lines, pixels+1)
    mw = CArray.float(lines, pixels+1)
    gu = CArray.float(lines+1, pixels+1)
    gv = CArray.float(lines+1, pixels+1)
    gw = CArray.float(lines+1, pixels+1)
    gx = CArray.float(lines+1, pixels+1)
    gy = CArray.float(lines+1, pixels+1)
#    bgx = gx[[0,2],[0,2]]
#    bgy = gy[[0,2],[0,2]]
#    bgw = gw[[0,2],[0,2]]
#    p("hello")
    CArray.attach(pu,pv,pw) {
      [[pu,mu,gu], [pv,mv,gv], [pw.float32,mw,gw]].each do |p,m,g|
        m[nil,1..-2] =  0.5*p[nil,0..-2] + 0.5*p[nil,1..-1]
        m[nil,0]     =  1.5*p[nil,0]     - 0.5*p[nil,1]
        m[nil,-1]    = -0.5*p[nil,-2]    + 1.5*p[nil,-1]
        g[1..-2,nil] =  0.5*m[0..-2,nil] + 0.5*m[1..-1,nil]
        g[ 0,nil]    =  1.5*m[0,nil]     - 0.5*m[1,nil]
        g[-1,nil]    = -0.5*m[-2,nil]    + 1.5*m[-1,nil]
      end
      yield(gu,gv,gx,gy)
      gx.sub!(@xoffset).mul!(@xscale)
      gy.sub!(@yoffset).mul!(@yscale)
      draw_rectangle_gradation_grid(gy, gx, gw)
#      pw.each_index do |i,j|
#        draw_rectangle_gradation(bgy.move(i,j), bgx.move(i,j), bgw.move(i,j))
#      end
    }
  end

  def warp_grid_gradation (pw, pu, pv)
    lines, pixels = pu.dim0, pv.dim1
    gx = CArray.float(lines, pixels)
    gy = CArray.float(lines, pixels)
    CArray.attach(pu,pv,pw) {
      yield(pu,pv,gx,gy)
      gx.sub!(@xoffset).mul!(@xscale)
      gy.sub!(@yoffset).mul!(@yscale)
#      bx = gx[[0,2],[0,2]]
#      by = gy[[0,2],[0,2]]
#      bw = pw[[0,2],[0,2]]
      draw_rectangle_gradation_grid(gy, gx, pw)
#      pw[0..-2,0..-2].each_index do |i,j|
#        draw_rectangle_gradation(by.move(i,j), bx.move(i,j), bw.move(i,j))
#      end
    }
  end

  def warp_grid_interpolation (pw, pu, pv, n, &block)
    lines, pixels = pu.dim0, pv.dim1
    m = 2+n
    hu = CArray.float(m, m)
    hv = CArray.float(m, m)
    hw = CArray.float(m, m)
    bu = pu[[0,2],[0,2]]
    bv = pv[[0,2],[0,2]]
    bw = pw[[0,2],[0,2]]
    CArray.attach(pu,pv,pw) {
      pw[0..-2,0..-2].each_index do |i,j|
        bu.move(i,j)
        bv.move(i,j)
        bw.move(i,j)
        hu.grid_new([[0,m-1],[0,m-1]])[] = bu
        hv.grid_new([[0,m-1],[0,m-1]])[] = bv
        hw.grid_new([[0,m-1],[0,m-1]])[] = bw
        [hu, hv, hw].each do |h|
          h[nil, 0].span!(h[0,0]..h[m-1,0])
          h[nil, m-1].span!(h[0,m-1]..h[m-1,m-1])
          h.dim0.times do |i|
            h[i, nil].span!(h[i,0]..h[i,m-1])
          end
        end
        warp_grid_gradation(hw, hu, hv, &block)
      end
    }
  end

  def initialize (*argv)
    super
    @yscale  = 1
    @xscale  = 1
    @yoffset = 0
    @xoffset = 0
  end

  attr_accessor :yscale, :xscale, :yoffset, :xoffset

  def set_xrange (rng)
    first = rng.begin
    last  = rng.end
    if rng.exclude_end?
      @xscale = (dim1-1).to_f/(last-first).to_f
    else
      @xscale = dim1.to_f/(last-first).to_f
    end
    @xoffset = first
  end

  def set_yrange (rng)
    first = rng.begin
    last  = rng.end
    if rng.exclude_end?
      @yscale = (dim0-1).to_f/(first-last).to_f
      @yoffset = last - @yscale
    else
      @yscale = dim0.to_f/(first-last).to_f
      @yoffset = last
    end
  end

  def warp (data, x, y, opt = {}, &block)
    option = {
      :grid => "point",
      :interpolation => nil,
      :gradation => false,
    }
    option.update(opt)
    case option[:grid] 
    when /^area([01]|)$/, "pixel"
      if option[:interpolation] 
        raise("can't interpolate in pixel mode")
      else
        if option[:gradation]
          warp_image_gradation(data, x, y, &block)
        else
          if option[:grid] == "area" or option[:grid] == "area0" 
            warp_image0(data, x, y, &block) ### inter(extra)polation before
          else
            warp_image1(data, x, y, &block) ### inter(extra)polation after
          end
        end
      end
    when "point"
      if option[:interpolation]
        warp_grid_interpolation(data, x, y, option[:interpolation], &block)
      else
        if option[:gradation]
          warp_grid_gradation(data, x, y, &block)
        else
          warp_grid(data, x, y, &block)
        end
      end
    else
      raise("unknown grid type")
    end
  end

  def tfw (metric = 1.0)
    format([["%f"]*6].join("\n"), 
           metric/@xscale,
           0,
           0,
           metric/@yscale,
           metric*(@xoffset+0.5/@xscale),
           metric*(@yoffset+0.5/@yscale))
  end

end

require 'carray/carray_imagemap.so'


