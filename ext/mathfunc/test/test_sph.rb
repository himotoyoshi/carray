require "carray"

r = CA_DOUBLE(1)
theta = CA_DOUBLE(30).rad
phi = CA_DOUBLE(45).rad

x,y,z = CAMath.spherical_to_xyz(r, theta, phi)
p CAMath.xyz_to_spherical(x,y,z)
p [r, theta, phi]
