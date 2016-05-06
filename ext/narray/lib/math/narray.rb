# ----------------------------------------------------------------------------
#
#  carray/math/narray.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

begin
  require "narray"
  require "carray/carray_narray"
rescue LoadError, TypeError
end