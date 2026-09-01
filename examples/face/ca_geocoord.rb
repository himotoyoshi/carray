# examples/face/ca_geocoord.rb
#
# CAGeoCoord — a CARecord-based composite Face sample.
# Wraps a CAStruct-backed array (= GeoCoord with lat/lng fields) in a
# CARecord and houses array-level domain methods (= haversine_distance,
# bbox, etc.) in the subclass body.
#
# CADatetime / CATimedelta are "int64 + unit tag" numeric Faces, whereas
# CAGeoCoord is a "CA_FIXLEN entity + data_class" **composite Face**
# (= a Face wrap of a struct array where each element carries multiple
# named fields).
#
# Usage:
#   require 'carray'
#   require_relative 'examples/face/ca_geocoord'
#
#   tokyo  = GeoCoord.new(lat: 35.6762, lng: 139.6503)
#   nyc    = GeoCoord.new(lat: 40.7128, lng: -74.0060)
#   london = GeoCoord.new(lat: 51.5074, lng: -0.1278)
#
#   pts = CAGeoCoord.new(3)
#   pts[0] = tokyo
#   pts[1] = nyc
#   pts[2] = london
#
#   # Array-level methods — the subclass body is the "residence" of
#   # operator/method definitions for this composite element type.
#   pts.haversine_distance(tokyo)   # => distance in [m] from each point to tokyo (target = scalar)
#   pts.haversine_distance(others)  # => pairwise distance in [m]              (target = CAGeoCoord)
#   pts.bbox                        # => [min_lat, min_lng, max_lat, max_lng]
#   pts.centroid                    # => GeoCoord (= elementwise-mean lat/lng)
#
#   # Field projection — pull only the "lat" column (a CAField on parent).
#   pts["lat"]                      # => CAField<float64>, dim=[3]

require "carray"
require "carray/core_extensions"

# ---- CAStruct definition ------------------------------------------------

GeoCoord = CArray.struct {
  float64 :lat   # latitude  (degrees)
  float64 :lng   # longitude (degrees)
} unless defined?(GeoCoord)

# ---- CARecord subclass --------------------------------------------------

class CAGeoCoord < CARecord
  # Enable core_extensions via class-scope `using`.  Only methods defined
  # inside this class body get postfix math (`.cos` / `.sin` / `.sqrt` /
  # `.asin` ...) on Float / Integer, making Numeric scalars symmetric with
  # CArray's same-named instance methods.  The refinement scope is closed
  # to this class body, so the host program's Numeric stays uncontaminated
  # (= the canonical opt-in refinement pattern).
  using CArray::CoreExtensions

  data_class GeoCoord

  EARTH_RADIUS_M = 6_371_008.8  # mean Earth radius [m] (WGS84)

  # Haversine distance in [m] from each of self's points to `target`.
  # `target` may be either a GeoCoord (= scalar broadcast: lat2/lng2 are
  # Floats) or another CAGeoCoord (= same dim, lat2/lng2 are CArrays),
  # and the **same expression** works in both cases.  `using` makes Float
  # and CArray share `.cos` etc. postfix notation, so the body stays
  # polymorphic without any scalar/array if-branch (= polymorphic numeric
  # helper idiom, established in Phase 5a).
  def haversine_distance(target)
    lat1 = self["lat"]   * (Math::PI / 180.0)
    lng1 = self["lng"]   * (Math::PI / 180.0)
    lat2 = target["lat"] * (Math::PI / 180.0)
    lng2 = target["lng"] * (Math::PI / 180.0)

    dlat = lat2 - lat1
    dlng = lng2 - lng1

    a = (dlat / 2.0).sin ** 2 +
        lat1.cos * lat2.cos * ((dlng / 2.0).sin ** 2)
    c = 2.0 * a.sqrt.asin
    c * EARTH_RADIUS_M
  end

  # Bounding box — [min_lat, min_lng, max_lat, max_lng].
  def bbox
    [self["lat"].min, self["lng"].min,
     self["lat"].max, self["lng"].max]
  end

  # Centroid — elementwise mean (= NOT the spherical mean; OK for small
  # local regions only).
  def centroid
    GeoCoord.new(lat: self["lat"].mean, lng: self["lng"].mean)
  end
end

# ---- Demo ---------------------------------------------------------------

if __FILE__ == $0
  tokyo  = GeoCoord.new(lat: 35.6762, lng: 139.6503)
  nyc    = GeoCoord.new(lat: 40.7128, lng: -74.0060)
  london = GeoCoord.new(lat: 51.5074, lng: -0.1278)
  paris  = GeoCoord.new(lat: 48.8566, lng:   2.3522)

  pts = CAGeoCoord.new(4)
  pts[0] = tokyo
  pts[1] = nyc
  pts[2] = london
  pts[3] = paris

  puts "=== CAGeoCoord sample ==="
  puts "pts.class      : #{pts.class}"
  puts "pts.data_class : #{pts.data_class}"
  puts "pts.dim        : #{pts.dim.inspect}"
  puts "pts.parent     : #{pts.parent.class} (FIXLEN, #{pts.parent.bytes}B/elem)"
  puts

  puts "--- per-element access (= GeoCoord.decode via fetch_method) ---"
  pts.each_with_index { |p, i| puts "  pts[#{i}] = #{p.inspect}" }
  puts

  puts "--- field projection (= Face strip, CAField on parent) ---"
  puts "  pts['lat'].class = #{pts['lat'].class}"
  puts "  pts['lat'].to_a  = #{pts['lat'].to_a.inspect}"
  puts

  puts "--- subclass array-level methods ---"
  d_from_tokyo = pts.haversine_distance(tokyo) / 1000.0  # [km]
  puts "  distance from Tokyo [km]:"
  ["Tokyo", "NYC", "London", "Paris"].zip(d_from_tokyo.to_a).each { |c, d|
    puts "    %-7s %.1f" % [c, d]
  }
  puts "  bbox            : #{pts.bbox.map { |v| '%.4f' % v }.inspect}"
  puts "  centroid        : #{pts.centroid.inspect}"
  puts

  puts "--- target broadening (= same method, scalar vs array target) ---"
  # Same haversine_distance definition, with `target` switched to a
  # CAGeoCoord, returns pairwise distances.  Because Float and CArray
  # share the same postfix math via `using`, scalar/array dispatch is
  # carried polymorphically without an if-branch.
  others = CAGeoCoord.new(4)
  others[0] = paris   # Tokyo  -> Paris
  others[1] = london  # NYC    -> London
  others[2] = nyc     # London -> NYC
  others[3] = tokyo   # Paris  -> Tokyo
  d3 = pts.haversine_distance(others) / 1000.0
  puts "  pairwise distance [km]:"
  pairs = [["Tokyo", "Paris"], ["NYC", "London"],
           ["London", "NYC"], ["Paris", "Tokyo"]]
  d3.to_a.each_with_index { |d, i|
    puts "    %-7s -> %-7s %.1f" % [*pairs[i], d]
  }
  puts

  puts "--- chain pattern (= derived CARecord view + domain method) ---"
  # CARecord derived views (slice / transpose / ...) carry data_class
  # transparently as Faces, and transparently accept domain methods
  # (= haversine_distance, etc.).  Methods that live in the subclass
  # body just work — this is the chain composability of the composite
  # Face mechanism.
  asia_eu = pts[0..2]
  puts "  pts[0..2].class      : #{asia_eu.class} (face=#{asia_eu.face?})"
  puts "  pts[0..2].data_class : #{asia_eu.data_class}"
  d4 = asia_eu.haversine_distance(paris) / 1000.0
  puts "  distance from Paris [km] (Tokyo/NYC/London):"
  d4.to_a.each_with_index { |d, i|
    puts "    %-7s %.1f" % [["Tokyo", "NYC", "London"][i], d]
  }
end
