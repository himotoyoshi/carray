require 'carray'

image  = CArray.float(200, 200) { nan }

y = CArray.float(2,2){[50,50, 65,100]}
x = CArray.float(2,2){[70,100,50,90]}
z = CArray.float(2,2){[30,40, 50,20]}
ImageMap::Image.draw_rectangle_gradation(image, y, x, z)

#image.draw_line(y[0], x[0], y[1], x[1])
#image.draw_line(y[1], x[1], y[2], x[2])
#image.draw_line(y[2], x[2], y[0], x[0])
#image.draw_line(y[2], x[2], y[0], x[0])

image.mask = image.is_nan

sc = ImageMap::ColorScale.pm3d(13,6,10)

ImageMap.display(image, sc)

