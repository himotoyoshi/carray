# A tour of the features

The User's Guide teaches CArray from the beginning: arrays, indexing, element-wise operations, reductions, masks, views, broadcasting. Its chapters on the rest of CArray are still being written.

This page fills the gap in the meantime. It walks the feature list in the README, one short example each, so that a feature you read about there is at least something you can see working. Fuller documentation of each topic exists and is being brought up to date release by release; this page will point at those pages as they are ready.

Examples assume `require "carray"`.

## Masks

Any array — a view included — can mark individual elements as undefined. The mark is kept beside the data rather than written into it, so no representable value is spent on it, and reductions leave the marked elements out instead of letting them contaminate the result.

```ruby
a = CArray.float64(2, 3).seq!
a[0, 1] = UNDEF
a.sum(axis: 0)             #  => [ 3, 4, 7 ]
```

Covered in full by the guide: [Masks and missing values](../guides/users/05_masks.md).

## Views

Slicing, reshaping, transposing, selecting by condition — each hands back a view that refers to the original storage rather than copying it. Views refer to views, so a slice of a transpose stays a view, and a write through the outermost one reaches the data underneath.

```ruby
a = CArray.int32(3, 4).seq!
a.transpose[1..2, nil][] = 0
a
#  => [ [ 0, 0, 0,  3 ],
#       [ 4, 0, 0,  7 ],
#       [ 8, 0, 0, 11 ] ]
```

Covered in full by the guide: [Views](../guides/users/06_views.md).

## MemoryView on both sides

An array is bytes, a shape, a data type, and strides. MemoryView is Ruby's standard envelope for exactly that, and CArray implements it as both producer and consumer — so a buffer can cross between libraries without being copied, and without either side knowing about the other.

Anything that exposes a MemoryView can be taken in. `fiddle` is in the standard library, so this needs nothing installed:

```ruby
require "fiddle"

buf = Fiddle::Pointer[[1.5, 2.5, 3.5].pack("d*")]   #  a foreign buffer
ca  = CArray::Float64.wrap_memory_view(buf)         #  no copy
ca.sum                                              #  => 7.5
```

`wrap_memory_view` points at the producer's memory; `CArray.from_memory_view` takes a copy instead. A buffer that is laid out strided rather than contiguous is accepted either way.

The other direction needs no code at all — a consumer reads the array through the protocol:

```ruby
mv = Fiddle::MemoryView.new(CArray.float64(2, 3).seq!)
mv.shape                   #  => [2, 3]
mv.format                  #  => "d"
mv[1, 2]                   #  => 5.0
```

## Kernel-style iteration

When a reduction you want is not among the built-ins, you can write it as a Ruby block and have CArray run it over each sub-array along the axes you choose. The block sees an ordinary CArray, so everything CArray offers is available inside it.

```ruby
a = CArray.float64(2, 4).seq!

a.map_slab(axis: -1) { |row| row - row.mean }    #  same shape back
#  => [ [ -1.5, -0.5, 0.5, 1.5 ],
#       [ -1.5, -0.5, 0.5, 1.5 ] ]

a.reduce_slab(axis: -1) { |row| row.median }     #  the axis collapses
#  => [ 1.5, 5.5 ]
```

`each_slab` is the third of the set, for when you only want the side effect. Beside them are four more iterators built on the same surface — over rolling windows, over non-overlapping tiles, over categories, and over grid groups.

## Faces — domain meaning over unchanged storage

A Face is a view that changes what the elements *mean* without touching how they are stored. `CATime` is the worked example: the storage stays integer ticks on a grid you name, while the array reads and writes instants, and subtracting two of them answers a duration rather than a number.

```ruby
t = CArray.time(["2026-01-01", "2026-01-08", "2026-01-15"], unit: :D)
t[0]                       #  => #<CATime::Element 2026-01-01 (20454D)>
t[2] - t[0]                #  => #<CATimedelta::Element 14D>
t.ticks                    #  => [ 20454, 20461, 20468 ]   the storage, untouched
```

Because the meaning rides on a view, it survives slicing and every other view operation, and it can be stripped to get the plain numbers back. Faces of your own — an angle that wraps, a quantity carrying units — are written the same way.

## Array classes written in Ruby

Subclass `CAObject`, say what shape and data type you present, and answer elements when asked. What you get back is a full array: reductions, views, masks and arithmetic all work on it, and it can be built on by other views.

```ruby
class Countdown < CAObject
  def initialize(n)
    super(CA_INT32, [n])
  end

  private

  def fetch_index(idx)
    100 - idx[0]
  end
end

c = Countdown.new(5)       #  => [ 100, 99, 98, 97, 96 ]
c[1..3]                    #  => [ 99, 98, 97 ]
```

Values can come from anywhere — a computation, a file, a remote store — and only the elements actually asked for are produced.

## Record elements

An element can hold several named values packed into one fixed-width record. The array stays a single block of memory; a field is reached as a view onto the bytes, so it can be computed on like any other array.

```ruby
GeoCoord = CArray.struct { float64 :lat; float64 :lng }

g = CARecord.new(GeoCoord, 3)
g["lat"][] = [35.7, 34.7, 43.1]
g["lng"][] = [139.7, 135.5, 141.3]

g[0]                       #  => #<GeoCoord "lat" => 35.7, "lng" => 139.7>
g["lat"].mean              #  => 37.833333333333336
```

## A DataFrame whose columns are arrays

`CAFrame` adds names to a set of columns and nothing else. A column handed back is the CArray itself, not a wrapper around one, so masks, views, Faces and MemoryView keep working on it — anything the frame does not offer, you do on the column.

```ruby
df = CAFrame.new(
  "fruit" => CA_OBJECT(["apple", "orange", "apple"]),
  "price" => CA_FLOAT64([120.0, 80.0, 140.0]),
)

df["price"].class             #  => CArray
df.group_by("fruit").mean
#  fruit   price
#  ------  -----
#  apple   130.0
#  orange   80.0
```

Columns may carry trailing axes of their own, so a pair of coordinates or a 3×3 tensor per row is an ordinary column rather than something to flatten.
