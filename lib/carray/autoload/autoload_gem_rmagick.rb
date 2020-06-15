module Magick
  class Image
    autoload_method "export_pixels_to_ca", "carray-rmagick"
    autoload_method "import_pixels_from_ca", "carray-rmagick"
  end
end

class CArray
  autoload_method "self.load_image", "carray-rmagick"
  autoload_method "save_image", "carray-rmagick"
  autoload_method "display_image", "carray-rmagick"
  autoload_method "to_image", "carray-rmagick"
end

autoload :CAMagickImage, "carray-rmagick"

module Magick
  class Image
    autoload_method "ca", "carray-rmagick"
    autoload_method "to_ca", "carray-rmagick"
  end
end

