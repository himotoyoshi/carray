require 'carray'
require 'carray/image_map'
require 'sdi/hdf'
require 'proj4'
require 'benchmark'

RESOLUTION = 10         # (km) on map projection
UL_CORNER  = [3000, -3000] # (km) on map projection
LR_CORNER  = [-3000, 3000] # (km) on map projection
SCANLINES  = 2

PROJECTION = "+proj=stere +lat_0=-90 +units=km"

IMAGE_HEIGHT = (UL_CORNER[0] - LR_CORNER[0])/RESOLUTION.to_f + 1
IMAGE_WIDTH  = (LR_CORNER[1] - UL_CORNER[1])/RESOLUTION.to_f + 1

SCALE_Y  = -(UL_CORNER[0] - LR_CORNER[0])/(IMAGE_HEIGHT.to_f - 1)
SCALE_X  = (LR_CORNER[1] - UL_CORNER[1])/(IMAGE_WIDTH.to_f - 1)
OFFSET_Y = UL_CORNER[0].to_f # LOWERRIGHT[0].to_f
OFFSET_X = UL_CORNER[1].to_f

image = ImageMap.new(CA_INT32, [IMAGE_HEIGHT, IMAGE_WIDTH]) { -9999 }
image.set_xrange(UL_CORNER[1]..LR_CORNER[1])
image.set_yrange(LR_CORNER[0]..UL_CORNER[0])

#
#
#

sdi = SDI::HDF.open(ARGV[0])
clat = sdi.open("Latitude")[]
clon = sdi.open("Longitude")[]
height = sdi.open("Height")[]
sdi.close

NSCANS  = clat.dim0/SCANLINES
NPIXELS = clat.dim1

#cidx = clat.index
#cidx = clat.template.random!(1000)
cidx = height.copy

proj = Proj4.new(PROJECTION)

Benchmark.bm do |rep|
  rep.report do 
    (NSCANS).times do |ns|

#  printf("%i/%i\n", ns, NSCANS) 

  line = ns * SCANLINES

  bidx = cidx[[line, SCANLINES], nil].copy
  blat = clat[[line, SCANLINES], nil].copy
  blon = clon[[line, SCANLINES], nil].copy
 
  image.warp(bidx, blon, blat, :grid => "area", :gradation => false) { 
#   image.map_points(bidx, blon, blat) { 
    |lo,la,gx,gy| 
    proj.fwd_f(lo, la, gx, gy)
  }

    end
  end
end

puts "projection done"

#image = height.map_object(image, -9999)
image.mask = image < -9998

puts "masking flipping done"

#sc = nil
sc = ColorScale.GMT("GMT_topo.cpt")
#sc = ImageMap::ColorScale.GMT("DEM_poster.cpt")

#colors = CArray.float(5,5) 
#colors[0,nil] = [0, 0, 0, 0, 1]
#colors[1,nil] = [1990, 0, 0, 0, 1]
#colors[2,nil] = [2000, 1, 1, 1, 0]
#colors[3,nil] = [2010, 0, 0, 0, 1]
#colors[4,nil] = [5000, 0, 0, 0, 1]
#sc = ImageMap::ColorScale.mapping(colors)
#p sc.scale
#p sc.palette

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

