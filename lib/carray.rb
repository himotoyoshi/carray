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

require 'carray/basic'
require 'carray/constructor'
require 'carray/mask'
require 'carray/ordering'
require 'carray/composition'
require 'carray/transformation'
require 'carray/testing'

require 'carray/math'
require 'carray/iterator'
require 'carray/struct'
require 'carray/inspect'
require 'carray/string'

require "carray/carray_mathfunc"
require "carray/carray_calculus"
require "carray/math/calculus"

# obsolete methods

require 'carray/obsolete'

# autoload

require 'carray/autoload'
require 'carray/autoload/autoload_base'
require 'carray/autoload/autoload_io_imagemagick'
require 'carray/autoload/autoload_io_table'
require 'carray/autoload/autoload_math_histogram'
require 'carray/autoload/autoload_math_interp'
require 'carray/autoload/autoload_math_recurrence'
require 'carray/autoload/autoload_object_iterator'
require 'carray/autoload/autoload_object_link'
require 'carray/autoload/autoload_object_pack'

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

