# Faces

Every CArray has one of the built-in [data types](01_creating_arrays.md) — `int32`, `float64`, `int64`, and so on — that says how the bytes in memory are to be read. Sometimes the data needs behaviour that the built-in data types do not have. An array whose `data_type` is `:object` can hold such data as Ruby objects, but this costs speed.

CArray does not allow new data types to be added. Instead, a view can be built on an array of a built-in data type so that the view behaves like an array of a new type. Such a view is called a *Face*. The data stored in the array does not change, and neither does the shape. What changes is the Ruby class, the value that indexing returns, and the methods that are available.

CArray itself uses several Faces. They usually appear as the result of a method:

```ruby
# CATime            instants in time, over int64
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)

# CACategorical     categories, over integer codes
c = CA_OBJECT(%w[low high mid low high]).categorize

# CAFixlenString    Strings, over 5 bytes a cell
s = CArray.fixlen_string(%w[pear apple fig])
```

This chapter is about what all Faces have in common, so that a class name like these is not a surprise. Each Face has a chapter of its own for the rest (see [The Faces that come with CArray](#the-faces-that-come-with-carray)).

## Storage type and surface type

A Face has two types. The *storage type* is the built-in data type of the array underneath. It says what is stored in memory. The *surface type* is the type of the values that the Face shows. It says what the stored data means.

As an example, think of an array of pizza sizes. The array underneath is a `uint8` array that stores a number for each cell: 0 for S, 1 for M, 2 for L. A Face over this array shows each cell as the name of the pizza size:

| cell | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| storage (`uint8`) | 0 | 2 | 1 | 0 |
| surface (pizza size) | S | L | M | S |

Reading a cell of the Face reads the number in storage and turns it into a name. Writing a name to a cell of the Face turns the name into a number and stores the number. The array underneath always holds only numbers. The names exist only on the surface.

The Faces of the example above follow the same model:

| Face | storage type | surface type |
|---|---|---|
| `CATime` | `int64` (days since 1970 for `unit: :D`) | instants in time |
| `CACategorical` | `uint8` (codes) | category labels (`"low"`, `"high"`, `"mid"`) |
| `CAFixlenString` | `fixlen` (5 bytes a cell) | Strings |

## Elements are values of the Face

Indexing a Face returns a value of the surface type, not the number in storage. For a `CATime` with `unit: :D`, the storage type is `int64` and each stored number is a count of days since 1970-01-01. The date 2024-06-15 is stored as 19889, and indexing returns the date:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
dt[0]                   #  => #<CATime::Element 2024-06-15 (19889D)>
dt[0].to_s              #  => "2024-06-15"
```

The element shows the stored number too: `19889D` means 19889 days.

Writing takes a value of the surface type and stores the number for it. Writing the date 2024-07-01 stores 19905:

```ruby
dt[0] = "2024-07-01"
dt[1] = Time.utc(2024, 8, 1)
dt[0].to_s              #  => "2024-07-01"
```

## Under the Face

The stored numbers, such as 19889 for 2024-06-15, can also be read directly. A Face has a method that returns the array underneath, the array of the storage type. The method is named for what the numbers are: `ticks` for a `CATime`. The returned array shares its storage with the Face, so a write to it is a write to the Face:

```ruby
dt = CArray.time_series("2024-06-15", count: 3, unit: :D)
dt.ticks.to_a           #  => [19889, 19890, 19891]    days since 1970-01-01
dt.ticks[0] = 0
dt[0].to_s              #  => "1970-01-01"
```

For a `CACategorical`, the method is `codes`. The array it returns is read-only, because a categorical is read-only: its codes and its labels have to agree, so a cell is not changed on its own (`c[0] = "mid"` raises `RuntimeError`).

```ruby
c = CA_OBJECT(%w[low high mid low high]).categorize
c.codes.to_a            #  => [0, 1, 2, 0, 1]
```

`face?` tells whether an array is a Face. The array that `ticks` or `codes` returns is not a Face:

```ruby
dt.face?                #  => true
dt.ticks.face?          #  => false
CA_INT32([1, 2]).face?  #  => false
```

## Views of a Face

A view made from a Face is the same Face. A slice of a time array is a time array, and a transposed time array is a time array too:

```ruby
dt = CArray.time_series("2024-01-01", count: 6, unit: :D)
dt[2..4].class                     #  => CATime
dt[2..4][0].to_s                   #  => "2024-01-03"

v = dt.reshape(2, 3).transpose
v.class                            #  => CATime
v[2, 1].to_s                       #  => "2024-01-06"

c = CA_OBJECT(%w[low high mid low high]).categorize
c[1..3].class                      #  => CACategorical
c[1..3].to_a                       #  => ["high", "mid", "low"]
```

As with any view, a write through the view is a write to the Face:

```ruby
v[2, 1] = "2025-01-01"
dt[5].to_s                         #  => "2025-01-01"
```

A result whose meaning is different is not that Face. The day of the month of a time is a plain number, and the difference of two times is a duration:

```ruby
dt.day.class            #  => CArray            int64
(dt - dt[0]).class      #  => CATimedelta
```

## Operations on a Face

Each Face decides which operations it allows: arithmetic, reductions, comparisons, sorting and searching. The operations work on values of the surface type, not on the numbers in storage, so an operation is allowed when it makes sense for those values.

For a time array, the difference of two times is a duration, a duration can be added to a time, and the latest and the mean of the times are times:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
(dt - dt[0]).to_a.map(&:to_s)    #  => ["0D", "1D", "2D", "3D", "4D"]
(dt + "3 days")[0].to_s          #  => "2024-06-18"
dt.max.to_s                      #  => "2024-06-19"
dt.mean.to_s                     #  => "2024-06-17"
```

Comparing, searching and finding distinct values also work on the values. A day and an hour are compared as instants in time, so a day is matched by the hour it starts at. Strings are sorted as strings:

```ruby
hours = CArray.time_series("2024-06-15 00:00", count: 48, unit: :h)
days  = CArray.time_series("2024-06-15", count: 5, unit: :D)
days.is_in(hours).to_a           #  => [true, true, false, false, false]

s = CArray.fixlen_string(%w[pear apple fig])
s.sort.to_a                      #  => ["apple", "fig", "pear"]
```

An operation that has no meaning for values of the surface type raises. Two times cannot be added. A category can be tested for equality and its distinct values can be found, but a number cannot be added to it, and it cannot be sorted, because categories have no order:

```ruby
dt + dt                          #  TypeError: CATime + CATime is ill-defined

c = CA_OBJECT(%w[low high mid low high]).categorize
c.eq("low").to_a                 #  => [true, false, false, true, false]
c.unique.to_a                    #  => ["low", "high", "mid"]
c + 1                            #  CArray::DataTypeError
c.sort                           #  ArgumentError
```

The operations that each Face allows are described in the chapter for that Face (see [The Faces that come with CArray](#the-faces-that-come-with-carray)).

## Masks pass through

A Face has the mask of the array underneath, and everything in [Masks and missing values](05_masks.md) applies to it:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
dt[2] = UNDEF

dt[2]                   #  => UNDEF
dt.is_masked.to_a       #  => [false, false, true, false, false]
dt.min.to_s             #  => "2024-06-15"
```

## The Faces that come with CArray

| Face | what an element is | stored as | chapter |
|---|---|---|---|
| `CATime` | an instant | `int64` ticks on a named grid | [Time arrays](26_time_arrays.md) |
| `CATimedelta` | a duration | `int64` ticks | [Time arrays](26_time_arrays.md) |
| `CAString` | a String | an object array, with String methods | [Text, fixed-length strings, and records](14_text_and_fixlen.md) |
| `CAConstString` | a String, read-only | one shared byte buffer | [Text, fixed-length strings, and records](14_text_and_fixlen.md) |
| `CAFixlenString` | a String of a fixed width | fixed-length bytes | [Text, fixed-length strings, and records](14_text_and_fixlen.md) |
| `CARecord` | a record with named fields | the bytes of a struct | [Text, fixed-length strings, and records](14_text_and_fixlen.md) |
| `CACategorical` | a category label | integer codes | [Categories and grouping](24_categories_and_grouping.md) |

## Writing a new Face

A new Face can be defined in two ways: as a C extension, or in Ruby as a subclass of `CAObject`. Most of the Faces that come with CArray are C extensions, and `CACategorical` is defined in Ruby as a subclass of `CAObject`. A Face in Ruby needs no compiler.

To define a Face in Ruby, make it a subclass of `CAObject` and pass `face: true`. The array given as `parent:` holds the data, and every cell is read and written at the speed of that array. Here prices in one currency, over `int64` amounts:

```ruby
class Price < CAObject
  def initialize(amounts, currency:)
    @currency = currency
    super(CA_INT64, amounts.shape, parent: amounts, face: true)
  end

  attr_reader :currency

  # carry the currency to every view of a Price
  def copy_state(src)
    @currency = src.currency
  end

  def amounts
    parent
  end

  def total
    "#{amounts.accumulate} #{currency}"
  end
end

pr = Price.new(CA_INT64([120, 980, 450, 300]), currency: "JPY")
pr[1..2].class          #  => Price
pr[1..2].currency       #  => "JPY"
pr[1..2].total          #  => "1430 JPY"
pr + pr                 #  CArray::DataTypeError
```

A Face like this one refuses the arithmetic and reductions of the numbers underneath, as the Faces above do; the class adds the operations that have a meaning for its domain (`total` here). Writing Faces in full — keeping the numeric operations, ordering, custom values for the elements — is covered in the Developer's Guide.
