# Face subclass samples

Semantic types built with CArray 3.0's **Face mechanism**. A Face is a layer
over the view family that puts a semantic reading on top of storage, keeping
the two separate while a chain of views still composes
(see [CAFace.md](../../docs/topics/CAFace.md)).

**The point for the author**: a Ruby Face with `face: true` needs no storage
callbacks at all — no `fetch_index`, none of that family. Call
`super(..., parent:, face: true)` from `initialize` and storage
thin-forwards to the parent's native CArray, with per-cell access running at
C speed. You are left writing the domain methods you actually wanted to
write. Every sample here (`ca_circular.rb`, `ca_fixed_point.rb`) defines
zero storage callbacks, which is the demonstration.

There are two kinds:

1. **Ruby Face on `CAObject`** — derive from `CAObject`, pass `face: true`,
   and write it entirely in Ruby. Suits **scalar-like** semantic types:
   numeric, circular, quantities.
2. **Composite Face on `CARecord`** — derive from `CARecord` and use the
   `data_class` DSL to wrap a **CAStruct-backed array**. Suits **composite**
   types, where each element holds several fields: geographic coordinates,
   an RGB pixel, a timestamped record.

## Layout

### Ruby Face (on `CAObject`)

- **`ca_circular.rb`** — angles over a circular range (`:rad` / `:deg`), with
  circular statistics: `circular_mean`, `resultant_length`,
  `circular_variance`, `circular_stddev`. A Numeric Face, so surface and
  storage are both float64.
- **`ca_fixed_point.rb`** — fixed point over int64 storage at a fixed scale,
  which structurally avoids the round-trip drift you get from accumulating
  in float: share prices, currency, measurements. A NonNumeric Face
  (surface is `CA_FIXLEN`) and the reference implementation of the
  `:storage` opt-in. NonNumeric is the point: it is what gates the float64
  promotion that `* Float` would otherwise cause.

### Composite Face (on `CARecord`)

- **`ca_geocoord.rb`** — geographic coordinates as a lat/lng pair backed by
  CAStruct, with `haversine_distance`, `bbox`, `centroid`. The reference
  implementation of the `CARecord` + `data_class GeoCoord` DSL, and the
  example of putting **array-level operations in the subclass body**.

## Using them

### Ruby Face (`CACircular`)

```ruby
require "carray"
require_relative "../../samples/face/ca_circular"

angles = CArray.float64(5)
[0.0, Math::PI/4, Math::PI/2, 3*Math::PI/4, Math::PI].each_with_index { |v, i|
  angles[i] = v
}
cc = CACircular.new(angles, range: :rad)
cc.circular_mean              # => pi/2 (the centre)
cc[1..3].circular_mean        # works on a sliced view too
cc.flip.range                 # => :rad — the range survives the chain
```

### Composite Face (`CAGeoCoord`)

```ruby
require "carray"
require_relative "../../samples/face/ca_geocoord"

tokyo = GeoCoord.new(lat: 35.6762, lng: 139.6503)
nyc   = GeoCoord.new(lat: 40.7128, lng: -74.0060)
paris = GeoCoord.new(lat: 48.8566, lng:   2.3522)

pts = CAGeoCoord.new(2)
pts[0] = tokyo
pts[1] = nyc

# scalar target (a GeoCoord) — distance from each point to tokyo, in metres
pts.haversine_distance(tokyo)

# array target (a CAGeoCoord of the same shape) — pairwise distances
others = CAGeoCoord.new(2)
others[0] = paris; others[1] = paris
pts.haversine_distance(others)

pts.bbox                        # => [min_lat, min_lng, max_lat, max_lng]
pts.centroid                    # => GeoCoord (the mean position)
pts["lat"]                      # => CAField — the lat column on the parent,
                                #    with the Face stripped

# the domain methods carry through derived views (slice, transpose, …)
pts[0..1].haversine_distance(paris)
```

**Where to put the refinement.** Writing `using CArray::CoreExtensions`
inside the class body gives Float and Integer postfix `.cos` / `.sin` /
`.sqrt` within the method bodies, so they read the same as the CArray
methods of the same name. The refinement stays scoped to the class body;
Numeric outside is untouched.

```ruby
class CAGeoCoord < CARecord
  using CArray::CoreExtensions   # class-scope refinement
  data_class GeoCoord
  def haversine_distance(target)
    lat1 = self["lat"]   * (Math::PI / 180.0)   # a CArray
    lat2 = target["lat"] * (Math::PI / 180.0)   # a Float if target is a GeoCoord,
                                                # a CArray if it is a CAGeoCoord
    # lat1.cos and lat2.cos both work — one helper, either kind of operand
  end
end
```

Run `ruby -Iext -Ilib samples/face/ca_geocoord.rb` for the demo.

### NonNumeric Face (`CAFixedPoint`)

```
$ ruby -Iext -Ilib samples/face/ca_fixed_point.rb
=== 5 days of stock closing prices (scale=100, cents) ===
  Mon: $123.45
  Tue: $130.20
  ...

=== forbidden ops (would corrupt scale or unit) ===
  ✓ prices.cumprod (= cents^N, scale explodes) → TypeError
  ✓ Math.sqrt(prices[0]) (= sqrt of cents) → TypeError
  ✓ prices * prices (= cents², needs rescale) → TypeError
```

`prices * 0.95` keeps `parent.data_type == :int64` — the float promotion is
gated — and that is the reason to make this one NonNumeric.

## How to write a Face subclass

### Ruby Face (on `CAObject`)

The full account is in [CAFace.md](../../docs/topics/CAFace.md) §3–§5.

**Numeric Face** (`CACircular` and the like, surface = storage):

- construct with
  `super(STORAGE_DTYPE, parent.dim, parent: parent, face: true)`
- most numeric operations pass straight through the storage path; where the
  Face would be lost, override and re-wrap
- right when there is no structural risk such as FP drift, and you trust the
  user's grasp of the domain

**NonNumeric Face** (`CAFixedPoint` and the like, surface = `CA_FIXLEN`):

- construct with
  `super(CA_FIXLEN, parent.dim, bytes: B, storage: STORAGE, parent: parent, face: true)`
- every numeric operation is gated (the `CA_FIXLEN` slot in mkkernel rejects
  it automatically); bring back the ones you want with Ruby overrides that
  go through `parent.X`
- **declare the numeric conversion by defining `to_numeric`.** The gate stops
  *implicit* numeric dispatch, not an *explicit* `to_type(:float64)`. The
  storage — a scaled integer, a code, a serial — is not the answer to that
  request, and the core has no way to guess, so the Face says.
  `CAFixedPoint#to_numeric` is the one-line reference:
  `parent.float64 / @scale.to_f`. A Face that declares nothing raises on any
  cast other than `:object`, which is how it says "this value is not a
  number".
- right when you want to rule out a class of silent bugs structurally: float
  promotion, a unit quietly falling apart

Both kinds:

- expose semantic state with `attr_reader`
- override `copy_state(src)` so ivars carry, and state survives a sliced view
- override `storage_to_scalar(raw)` to control what `cc[i]` wraps into
  (optional; for a hot path you want in C there is also
  `ca_face_register_storage_to_scalar`)
- no value conversion happens — Face mode bypasses the callbacks
- add whatever semantic methods you like

### Composite Face (on `CARecord`)

- `class CAFoo < CARecord; data_class MyStruct; end` is the canonical form
- define the backing struct with `MyStruct = CArray.struct { ... }`
- project a field with `arr["field_name"]` — a `CAField` on the parent, with
  the Face stripped
- put array-level methods (`def distance(...)` and friends) in the subclass
  body; that is where operations on the array live
- `arr[i]` returns a `MyStruct` instance, via `MyStruct.decode`
- `arr.parent` exposes the plain `CA_FIXLEN` entity, byte layout unchanged
- masks, file I/O and chaining (`arr[range]`, `arr.transpose`) all pass
  through

## Ideas

Faces that might show up here:

- `ca_quantity.rb` — numbers with units (metre, km, kg — unit algebra; a Ruby
  Face)
- `ca_pixel.rb` — RGB / RGBA pixel arrays with image-processing methods (a
  CARecord composite Face)
- `ca_complex_pair.rb` — a complex number laid out by hand as a two-component
  re/im struct, which is not how the built-in complex types are stored (a
  composite Face)

The samples are where extensions grow up: if one of these turns out to earn
its place, moving it into `lib/carray/` is on the table. `CACategorical`
started as an idea in this list and is now part of the library.
