module OpenCV
  class CvMat
    autoload_method "ca", "carray-opencv"
    autoload_method "to_ca", "carray-opencv"
    autoload_method "from_ca", "carray-opencv"
    autoload_method "image", "carray-opencv"
  end
  class IplImage < CvMat
    autoload_method "ca", "carray-opencv"
  end
end

class CArray
  autoload_method "to_cvmat", "carray-opencv"
  autoload_method "to_iplimage", "carray-opencv"
end
