require 'carray'
require 'carray/image_map'
require 'benchmark'

lon = CArray.float(37).span!(-90..180)
lat = CArray.float(12).span!(0..90)

u = lon[:%,lat.dim0]
v = lat[lon.dim0,:%]
val = u.rad.sin! + v.rad 

image = ImageMap.new(CA_DOUBLE, [600, 600]) { -9999 }

image.set_xrange(-103..103)
image.set_yrange(-103..103)

Benchmark.bm do |o|
  o.report {
    image.warp(val, u, v, :grid=>"point", :gradation => true) {
      |_u,_v,_x,_y|
      _x[] = (100 - _v/3) * _u.rad.cos!
      _y[] = (100 - _v/3) * _u.rad.sin!
    }
  }
end

#image.draw_line(0, 0, 0, 90, 0)
image.line(0, 0, 0, 90, 0)

poly = CArray.float(4,2) {[[-90,90],[0,0],[45,45],[0,90]]}

image.polyline(poly[nil,1],poly[nil,0], 0)

image[:lt, -9998] = UNDEF

#sc = nil
#sc = ImageMap::ColorScale.pm3d(11,7,22,12)
sc = ColorScale.GMT("GMT_polar.cpt")
#sc.set_mask_color(64,64,64)
sc.set_range(nil, nil)

ImageMap.display(image, sc)
