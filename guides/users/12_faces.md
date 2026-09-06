# Faces

Every CArray has a [data type](01_creating_arrays.md) — `int32`, `float64`, `int64`, and so on — that says how the bytes in memory are to be read as numbers. Sometimes those numbers are not just numbers. An `int64` array might be storing the number of seconds since 1970; an `int32` array might be storing angles in degrees, or codes for categories, or amounts in cents.

A *Face* is a thin wrapper that sits on top of a numeric array and says: "read these elements as something". The bytes do not change. The shape does not change. What changes is the Ruby class on top, the scalar value you get back when you index, and the methods you can call.

The canonical example shipped with CArray is `CATime`, which gives an `int64` array a time interpretation.

## A first look

```ruby
dt = CArray.time_series("2024-06-15", count: 7, unit: :D)

dt.class                #  => CATime
dt.unit                 #  => #<CATime::Resolution 1 D>
dt.day.to_a             #  => [15, 16, 17, 18, 19, 20, 21]
dt.weekday.to_a         #  => [6, 0, 1, 2, 3, 4, 5]   #  Sun=0..Sat=6
```

What is going on underneath is that `dt` is a *view* (see [Views](06_views.md)) over an ordinary `int64` array. The `int64` values are day counts since 1970-01-01; the Face is what knows that "19891" means 2024-06-17. The named accessor `ticks` exposes those raw values:

```ruby
dt.ticks.class          #  => CArray
dt.ticks.data_type      #  => :int64
dt.ticks.to_a           #  => [19889, 19890, 19891, 19892, 19893, 19894, 19895]
```

The Face and its underlying array share storage byte-for-byte. There is no conversion happening at the boundary; the Face is purely an interpretation.

## Constructing a CATime array

There are several ways to make one.

### From a time series

`CArray.time_series` builds an array of evenly spaced instants from a start point:

```ruby
CArray.time_series("2024-06-15", count: 7, unit: :D)
CArray.time_series("2024-06-15T12:00:00", count: 24, unit: :h)
```

`count:` is the number of elements; `unit:` is the resolution of the grid — `:D` (day), `:h` (hour), `:m` (minute), `:s` (second), and so on. It is also the *unit* of the resulting array.

### From a single literal

```ruby
CArray.time("2024-06-15", unit: :D)
#  => 1-element CATime
```

### From an existing int64 array

If you already have an `int64` CArray whose values you want to interpret as datetimes, wrap it directly:

```ruby
raw = CArray.int64(5) { |i| i * 86400 }
dt  = raw.time(unit: :s)

dt.class                     #  => CATime
dt.unit.base                 #  => :s
dt.ticks.to_a == raw.to_a    #  => true
```

The Face is zero-copy: `dt` shares its storage with `raw`. Writes through `dt` reach back to `raw`, and vice versa.

### Empty allocation

```ruby
CATime.new(10, unit: :ns)
#  => 10-element CATime, all zero (= 1970-01-01)

CATime.new(3, 4, unit: :D)
#  => 3x4 CATime
```

## Units

The integer values in the underlying storage are interpreted as a count of units since the **1970-01-01 UTC** epoch.

| unit | meaning      |
|------|--------------|
| `:D` | day          |
| `:h` | hour         |
| `:m` | minute       |
| `:s` | second       |
| `:ms`| millisecond  |
| `:us`| microsecond  |
| `:ns`| nanosecond   |

A few less common units (`:Y`, `:M`, `:W`, `:ps`, `:fs`, `:as`) also exist, and a unit can be a composite resolution such as `"10 minutes"`. See [Time arrays](26_time_arrays.md) for the full table.

Operations between arrays of different units are reconciled by the unit algebra — exact conversions happen automatically, and a conversion that would silently lose precision raises instead. The details are in [Time arrays](26_time_arrays.md); the point here is that the Face is what carries the unit through every operation so that the reconciliation can happen at all.

## Indexing returns an Element, not a number

For a plain `int64` array, `a[2]` returns an `Integer`. For a Face, indexing returns an *Element* object that carries the same interpretation as the array:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
s  = dt[2]

s.class       #  => CATime::Element
s.value       #  => 19891       (raw int64 in the array's unit)
s.unit        #  => #<CATime::Resolution 1 D>
s.to_s        #  => "2024-06-17"
s.to_time     #  => 2024-06-17 00:00:00 UTC
s < dt[3]     #  => true
```

Elements compare with each other via `Comparable`, so you can use `<`, `<=`, `<=>`, `==`, sort arrays of them, and so on.

## Calendar fields

A Face is free to add its own methods. `CATime` adds accessors for the calendar fields of each element:

```ruby
dt = CArray.time_series("2024-06-15", count: 7, unit: :D)

dt.year.to_a        #  => [2024, 2024, 2024, 2024, 2024, 2024, 2024]
dt.month.to_a       #  => [6, 6, 6, 6, 6, 6, 6]
dt.day.to_a         #  => [15, 16, 17, 18, 19, 20, 21]
dt.weekday.to_a     #  => [6, 0, 1, 2, 3, 4, 5]
```

These return plain numeric CArrays — `dt.year` is an `int32` array of years, not a Face. The reasoning is that a year number is no longer a time, so carrying the Face would be misleading. The Face is *stripped* when the result no longer has time semantics.

`strftime` works the same way:

```ruby
dt.strftime("%Y-%m-%d").to_a
#  => ["2024-06-15", "2024-06-16", "2024-06-17",
#      "2024-06-18", "2024-06-19", "2024-06-20", "2024-06-21"]
```

The result is a `String` CArray, not a `CATime`.

## Arithmetic that respects meaning

The other thing a Face decides is what arithmetic means. For datetimes, the algebra is that of instants and durations: you can add a duration to an instant, you can subtract two instants to get a duration, but you cannot add two instants.

```ruby
dt = CArray.time_series("2024-06-15", count: 7, unit: :D)
td = CArray.int64(7) { |i| i + 1 }.timedelta(unit: :D)

(dt + td).class     #  => CATime
(dt - dt).class     #  => CATimedelta
(dt + dt)
#  => TypeError: CATime + CATime is ill-defined
```

`CATimedelta` is the second Face shipped with CArray. It also wraps an `int64` array, but interprets it as a duration. Unlike `CATime`, ordinary arithmetic *is* meaningful on durations:

```ruby
td + td             #  => CATimedelta
td * 2              #  => CATimedelta
td.sum.value        #  => sum as a plain integer count in the unit
```

## Reductions

Reductions follow the same rule as fields: those that produce something with the same meaning keep the Face, others strip it.

```ruby
dt.min              #  => CATime::Element  (earliest instant)
dt.max              #  => CATime::Element  (latest instant)
dt.mean             #  => CATime::Element  (midpoint)

dt.sum
#  => TypeError: CATime#sum is ill-defined; use mean for centroid
```

`min`, `max`, `mean`, `median` all return a `CATime::Element`, because each of those is still an instant. `sum` raises, because the sum of dates is nonsense.

For `CATimedelta`, `sum` and `mean` are fine — durations add.

## Slicing and reshape preserve the Face

Every view-creating operation preserves the Face. Whatever you do to the array — slice it, reshape it, transpose it, flip it, mask it, sort it — what comes back is still a `CATime`, still carrying its unit.

```ruby
dt = CArray.time_series("2024-01-01", count: 12, unit: :D)

dt[2..5].class                                     #  => CATime
dt.reshape(3, 4).class                             #  => CATime
dt.reshape(3, 4).transpose.class                   #  => CATime
dt.reshape(3, 4).transpose.flip[0..1].unit.base    #  => :D
```

This is the property that makes a Face actually useful. A time array that turned back into a plain `int64` array after the first slice would be no better than a comment in the code; the whole point is that the interpretation survives.

## Going back to the underlying numbers

If you ever want the raw numbers — to send them to a function that wants a plain integer, to compute something the Face does not provide, to compare storage values directly — `ticks` is the escape hatch.

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)

dt.ticks.class       #  => CArray
dt.ticks.data_type   #  => :int64
dt.ticks.to_a        #  => [19889, 19890, 19891, 19892, 19893]
```

`dt.ticks` is the underlying `int64` array. It shares storage with `dt`, so modifying one modifies the other.

You can also go in the opposite direction at any time: take a plain integer array and put a Face on it with `raw.time(unit: ...)`.

## Masks pass through

A Face inherits the mask of its parent. Anything you know about masks from [Masks](05_masks.md) applies directly:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
dt[2] = UNDEF

dt[2]                  #  => UNDEF
dt.is_masked.to_a      #  => [false, false, true, false, false]
dt.min.to_s            #  => "2024-06-15"   # ignores masked
```

`dt.strip_mask(0)` clears the mask, replacing the masked entries with the fill value (interpreted in the array's unit).

## Other built-in Faces

CArray ships with two Faces:

- `CATime` — instants in time, this chapter.
- `CATimedelta` — durations, briefly shown above.

Both are layered on `int64` storage and follow the same pattern: a numeric array underneath, a domain interpretation on top, kept across the view algebra.

The Face mechanism itself is general — it is just as much at home with angles in radians, money in a given currency, or any other interpretation where a numeric array is not "just numbers". The two shipped Faces are covered in full — construction, unit algebra, search, and the time bucketing system — in [Time arrays](26_time_arrays.md).

## Quick recap

- A Face puts a domain interpretation on top of a numeric array without copying.
- `CATime` and `CATimedelta` interpret an `int64` array as instants and durations.
- Indexing returns an `Element` object that carries the interpretation.
- Fields (`year`, `month`, …) and `strftime` return plain numeric or string arrays — the Face is stripped when the result no longer has the same meaning.
- Arithmetic follows the algebra of the domain: instant ± duration is fine, instant + instant raises.
- View-creating operations (`reshape`, slice, `transpose`, `flip`, …) keep the Face on top.
- `dt.ticks` is the underlying `int64` array, sharing storage.
- Masks are inherited from the underlying array and work exactly as on a plain CArray.
