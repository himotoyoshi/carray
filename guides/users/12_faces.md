# Faces

Every CArray has a [data type](01_creating_arrays.md) — `int32`, `float64`, `int64`, and so on — that says how the bytes in memory are to be read as numbers. Sometimes those numbers are not just numbers. An `int64` array might hold days since 1970; a `uint8` array might hold the codes of categories.

A *Face* is a view that sits on top of such an array and says "read these elements as something". The bytes do not change, and neither does the shape. What changes is the Ruby class, the value you get back when you index, and the methods you can call.

You usually meet a Face without asking for one, as the result of a method:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
dt.class                #  => CATime            instants in time, over int64

c = CA_OBJECT(%w[low high mid low high]).categorize
c.class                 #  => CACategorical     categories, over integer codes

s = CArray.fixlen_string(%w[pear apple fig])
s.class                 #  => CAFixlenString    Strings, over 5 bytes a cell
```

This chapter is about what all Faces have in common, so that a class name like these is not a surprise. Each Face has a chapter of its own for the rest (see [The Faces that come with CArray](#the-faces-that-come-with-carray)).

## Elements are values of the Face

Indexing a Face returns a value in its own terms, not the number underneath:

```ruby
dt[0]                   #  => #<CATime::Element 2024-06-15 (19889D)>
dt[0].to_s              #  => "2024-06-15"
c[0]                    #  => "low"
s[0]                    #  => "pear"
```

Writing takes a value in the same terms:

```ruby
dt[0] = "2024-07-01"
dt[1] = Time.utc(2024, 8, 1)
dt[0].to_s              #  => "2024-07-01"
```

Not every Face can be written. A categorical is read-only: its codes and its labels have to agree, so a cell is not changed on its own (`c[0] = "mid"` raises `RuntimeError`).

## Views keep the Face

Every operation that makes a view of a Face — a slice, `reshape`, `transpose`, `flip` — returns the same Face:

```ruby
dt = CArray.time_series("2024-01-01", count: 6, unit: :D)
dt[2..4].class                     #  => CATime
dt.reshape(2, 3).transpose.class   #  => CATime
c[1..3].class                      #  => CACategorical
```

This is what makes a Face useful: the interpretation stays with the data however you cut it.

A result whose meaning is different is not that Face. The day of the month of a time is a plain number, and the difference of two times is a duration:

```ruby
dt.day.class            #  => CArray            int64
(dt - dt[0]).class      #  => CATimedelta
```

## Operations without a meaning are refused

Arithmetic on a Face is the arithmetic of what it stands for. An operation that has no meaning there raises instead of computing on the numbers underneath:

```ruby
dt + dt                 #  TypeError: CATime + CATime is ill-defined
c + 1                   #  TypeError
dt - dt[0]              #  fine: the time since the first one
```

## Values are compared as what they mean

Comparing, searching and finding distinct values work on the values of the Face:

```ruby
c.eq("low").to_a                 #  => [true, false, false, true, false]
c.unique(sort: true).to_a        #  => ["high", "low", "mid"]     label order
s.sort.to_a                      #  => ["apple", "fig", "pear"]

hours = CArray.time_series("2024-06-15 00:00", count: 48, unit: :h)
days  = CArray.time_series("2024-06-15", count: 5, unit: :D)
days.is_in(hours).to_a           #  => [true, true, false, false, false]
```

The last line compares days with hours: a day is matched by the hour it starts at.

## Under the Face

The numbers under a Face are always within reach, through a method named for what they are — `ticks` for a time, `codes` for a categorical. The result is the array underneath, sharing its storage, so a write to it is a write to the Face:

```ruby
dt = CArray.time_series("2024-06-15", count: 3, unit: :D)
dt.ticks.to_a           #  => [19889, 19890, 19891]    days since 1970-01-01
dt.ticks[0] = 0
dt[0].to_s              #  => "1970-01-01"

c.codes.to_a            #  => [0, 1, 2, 0, 1]
```

The other way, a Face is put onto numbers you already have:

```ruby
CA_INT64([19889, 19890]).time(unit: :D)[1].to_s      #  => "2024-06-16"
CACategorical.from_codes(CA_UINT8([2, 0]), ["low", "high", "mid"]).to_a
                                                     #  => ["mid", "low"]
```

## Masks pass through

A Face has the mask of the array underneath, and everything in [Masks and missing values](05_masks.md) applies to it:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
dt[2] = UNDEF

dt[2]                   #  => UNDEF
dt.is_masked.to_a       #  => [false, false, true, false, false]
dt.min.to_s             #  => "2024-06-15"
```

## Where a Face does not go

Some paths out of CArray carry bytes only, and the meaning of a time or a category is not in its bytes. [MemoryView](15_memory_view.md) is one: a `CATime` or a `CACategorical` is not handed to another library. Hand it the numbers underneath:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
CArray.memory_view_available?(dt)          #  => false
CArray.memory_view_available?(dt.ticks)    #  => true
```

## The Faces that come with CArray

| Face | what an element is | stored as | chapter |
|---|---|---|---|
| `CATime` | an instant | `int64` ticks on a grid you name | [Time arrays](26_time_arrays.md) |
| `CATimedelta` | a duration | `int64` ticks | [Time arrays](26_time_arrays.md) |
| `CAString` | a String | an object array, with String methods | [Text, fixed-length strings, and records](14_text_and_fixlen.md) |
| `CAConstString` | a String, read-only | one shared byte buffer | [Text, fixed-length strings, and records](14_text_and_fixlen.md) |
| `CAFixlenString` | a String of a fixed width | fixed-length bytes | [Text, fixed-length strings, and records](14_text_and_fixlen.md) |
| `CARecord` | a record with named fields | the bytes of a struct | [Text, fixed-length strings, and records](14_text_and_fixlen.md) |
| `CACategorical` | a category label | integer codes | [Categories and grouping](24_categories_and_grouping.md) |

## Writing your own Face

A Face for a domain of your own can be written in Ruby. Make it a subclass of `CAObject` and pass `face: true`; the array you give as `parent:` holds the data, and every cell is read and written at the speed of that array. Here prices in one currency, over `int64` amounts:

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

A Face like this one refuses the arithmetic and reductions of the numbers underneath, as the Faces above do; you add the operations that mean something for your domain (`total` here). Writing Faces in full — keeping the numeric operations, ordering, values of your own for the elements — is covered in the Developer's Guide.

## Quick recap

- A Face reads an array as something — times, categories, strings — without changing its bytes.
- Indexing returns a value of the Face, and writing takes one.
- Views keep the Face; a result that means something else is not that Face.
- An operation with no meaning for the Face raises.
- Comparing, searching and finding distinct values work on what the values mean.
- The numbers underneath are reached by a named method (`ticks`, `codes`), sharing storage.
- Masks work as on any CArray.
- A Face can be written in Ruby as a subclass of `CAObject` with `face: true`.
