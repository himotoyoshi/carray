require 'carray'

#sc = ImageMap::ColorScale.pm3d(13,10,14,256,:interpolation => false)
#sc = ImageMap::ColorScale.GMT("GMT_globe.cpt")
#sc.set_range(0..Math::PI)
#sc.set_upper_color(127,127,127)
#sc.set_lower_color(127,127,127)
#sc.set_mask_color( 127,127,127)

ca = CArray.float(640, 480)
ca[:i,nil].scale!(-0.1, Math::PI+0.1)
ca.mask = 0
ca.mask[90..110,90..110] = 1

if true
  im = ImageMap.create(ca, sc)
  require 'carray/RMagick'
  il = Magick::Image.new_from_ca(im)
  il.display
else
  im = ImageMap.display(ca, sc)
end

