
module Cairo
  class Surface
  end
  class ImageSurface < Surface
    autoload_method "self.new_from_ca", "carray-cairo"
    autoload_method "ca", "carray-cairo"
  end
end
