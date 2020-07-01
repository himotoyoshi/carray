# ----------------------------------------------------------------------------
#
#  lib/carray.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

major = RbConfig::CONFIG['MAJOR'].to_i
minor = RbConfig::CONFIG['MINOR'].to_i
teeny = RbConfig::CONFIG['TEENY'].to_i
ruby_version_code = major * 100 + minor * 10 + teeny

if ruby_version_code < 190
  require 'complex'
end

# main 

require 'carray_ext'

require 'carray/inspect'
require 'carray/basic'
require 'carray/construct'
require 'carray/mask'
require 'carray/compose'
require 'carray/transform'
require 'carray/convert'
require 'carray/testing'
require 'carray/ordering'

require 'carray/math'
require 'carray/iterator'
require 'carray/struct'
require 'carray/table'
require 'carray/string'

# obsolete methods

require 'carray/obsolete'

# autoload

unless $CARRAY_NO_AUTOLOAD 
  require 'carray/autoload'
  require 'carray/autoload/autoload_base'
  require 'carray/autoload/autoload_io_imagemagick'
  require 'carray/autoload/autoload_math_histogram'
  require 'carray/autoload/autoload_math_recurrence'
  require 'carray/autoload/autoload_object_iterator'
  require 'carray/autoload/autoload_object_link'
  require 'carray/autoload/autoload_object_pack'

  require 'carray/autoload/autoload_gem_random'
  require 'carray/autoload/autoload_gem_gnuplot'
  require 'carray/autoload/autoload_gem_narray'
  require 'carray/autoload/autoload_gem_numo_narray'
  require 'carray/autoload/autoload_gem_io_csv'
  require 'carray/autoload/autoload_gem_io_sqlite3'
  require 'carray/autoload/autoload_gem_rmagick'
  require 'carray/autoload/autoload_gem_cairo'
  require 'carray/autoload/autoload_gem_opencv'
  require 'carray/autoload/autoload_gem_ffi'

  undef autoload_method
end
