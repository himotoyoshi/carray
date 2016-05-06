require 'carray'
require 'carray/image_map'
require 'sdi/hdf'
require 'proj4'

RESOLUTION = 5         # (km) on map projection
UL_CORNER  = [3000, 0] # (km) on map projection
LR_CORNER  = [0, 3000] # (km) on map projection
SCANLINES  = 2

PROJECTION = "+proj=stere +lat_0=-90 +units=km"

IMAGE_HEIGHT = (UL_CORNER[0] - LR_CORNER[0])/RESOLUTION.to_f + 1
IMAGE_WIDTH  = (LR_CORNER[1] - UL_CORNER[1])/RESOLUTION.to_f + 1

SCALE_Y  = -(UL_CORNER[0] - LR_CORNER[0])/(IMAGE_HEIGHT.to_f - 1)
SCALE_X  = (LR_CORNER[1] - UL_CORNER[1])/(IMAGE_WIDTH.to_f - 1)
OFFSET_Y = UL_CORNER[0].to_f # LOWERRIGHT[0].to_f
OFFSET_X = UL_CORNER[1].to_f

image = ImageMap::Image.new(CA_INT32, [IMAGE_HEIGHT, IMAGE_WIDTH]) { -9999 }
image.set_xrange(UL_CORNER[1]..LR_CORNER[1])
image.set_yrange(LR_CORNER[0]..UL_CORNER[0])

#
#
#

sdi = SDI::HDF.open(ARGV[0])
clat = sdi.open("Latitude")[]
clon = sdi.open("Longitude")[]
height = sdi.open("SolarZenith")[]
sdi.close

NSCANS  = clat.dim0/SCANLINES
NPIXELS = clat.dim1

#cidx = clat.index
#cidx = clat.template.random!(1000)
cidx = height.copy

proj = Proj4.new(PROJECTION)

(NSCANS).times do |ns|

  printf("%i/%i\n", ns, NSCANS) 

  line = ns * SCANLINES

  bidx = cidx[[line, SCANLINES], nil].copy
  blat = clat[[line, SCANLINES], nil].copy
  blon = clon[[line, SCANLINES], nil].copy
 
  image.warp(bidx, blon, blat, :grid => "area", :gradation => false) { 
#  image.map_points(bidx, blon, blat) { 
    |lo,la,gx,gy| 
    proj.fwd_f(lo, la, gx, gy)
  }

end

puts "projection done"

#image = height.map_object(image, -9999)
image.mask = image < -9998

puts "masking flipping done"

sc = nil
#sc = ImageMap::ColorScale.GMT("GMT_globe.cpt")
#sc = ImageMap::ColorScale.GMT("DEM_poster.cpt")

ImageMap.display(image, sc)

open("projection.tfw", "w") { |io|
  io.printf([["%g\n"]*6].join(), 
            RESOLUTION*1000,
            0,
            0,
            -RESOLUTION*1000,
            OFFSET_X*1000+RESOLUTION*500,
            OFFSET_Y*1000+RESOLUTION*500)
}
