# ----------------------------------------------------------------------------
#
#  carray/math/interp/adapter_interp1d.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require "carray/math/interp"

class CA::Interp::CAInterp1D < CA::Interp::Adapter
  
  install_adapter "interp1d"
  
  def initialize (scales, value, options={})
    @y  = value
    @x  = scales
  end
  
  def evaluate (x0)
    @y.interpolate(@x, x0)
  end

  alias grid evaluate

end

