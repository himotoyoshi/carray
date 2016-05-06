#
#
#

#
# :type => type
#
#   * "linear"
#   * "polynomial"
#   * "cspline"
#   * "cspline_periodic"
#   * "akima"
#   * "akima_periodic"
#

require "carray/math/interp"
begin
  require "gsl"
rescue LoadError
end

class CA::Interp::GSLSpline < CA::Interp::Adapter
  
  install_adapter "gsl:spline"
  
  def initialize (scales, value, options={})
    @y  = value
    @x  = scales
    type = options[:type] || "linear"
    CArray.attach(@x, @y) {
      @interp = GSL::Spline.alloc(type, @x.na, @y.na)
    }
  end
  
  def evaluate (x0)
    case x0
    when CArray
      return x0.attach { @interp.eval(x0.na).ca }
    else
      return @interp.eval(x0)
    end
  end
  
  alias grid evaluate

end

