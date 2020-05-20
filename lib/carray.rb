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

require 'carray_ext'
require 'carray/base/basic'
require 'carray/base/math'
require 'carray/base/iterator'
require 'carray/base/struct'
require 'carray/base/inspect'
require 'carray/base/autoload'
require 'carray/base/obsolete'
require 'carray/base/string'
