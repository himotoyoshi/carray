require 'carray'

lon = CArray.float(121).span!(-180..180)
lat = CArray.float(12).span!(0..90)
p val = CArray.uint16(121,12).seq!.quantize(256)

img = ImageMap.uint16(600,600) { 9999 }

img.warp(val, lon[:%,lat.dim0], lat[lon.dim0,:%], 
         :grid=>"area0", :gradation=>false) { |u,v,x,y|
  x[] = (100 - v/2) * u.rad.cos!
  y[] = (100 - v/2) * u.rad.sin!
  x.mul!(2).add!(300)
  y.mul!(2).add!(300)
}

img[:eq,9999] = UNDEF

RGB = CA.struct{ uint8 :r,:g,:b }
rgb = CArray.new(RGB, [255,3])
rgb["r"].seq!

out = rgb.project(img)

out.display_by_magick("rgb")

