# Time arrays — CATime and CATimedelta

[Faces](12_faces.md) introduced the idea of putting an interpretation on top
of a numeric array. This chapter covers the two time Faces that ship with
CArray in full: `CATime`, an array of *instants* (points in time), and
`CATimedelta`, an array of *durations* (amounts of elapsed time).

The core idea is that **time is an integer index on a tick grid**. Each
stored value is the k-th tick of a chosen resolution, counted from the Unix
epoch. The resolution — a tick of `"10 minutes"`, `"3 hours"`, `:D`, `:ns` —
is a property of the array, so the same `int64` storage can hold a 10-minute
grid, a daily grid, or a nanosecond grid.

The time semantics are layered on plain `int64` storage: numerical kernels
see a regular `int64` array, while you see a time-aware array that survives
slicing, reshaping, masking, and every other view-creating method. A few
fixed points frame everything below:

- the epoch is **1970-01-01 UTC**, fixed;
- the calendar is proleptic Gregorian;
- parsing is UTC by default (an explicit `"+09:00"` suffix is respected);
- storage is `int64`, fixed.

## A first look

```ruby
dt = CArray.time_series("2024-06-15", count: 7, unit: :D)
# => 7-element CATime on a daily grid

dt.year.to_a       # => [2024, 2024, 2024, 2024, 2024, 2024, 2024]
dt.day.to_a        # => [15, 16, 17, 18, 19, 20, 21]
dt.weekday.to_a    # => [6, 0, 1, 2, 3, 4, 5]        # Sun=0..Sat=6

dt[2]              # => CATime::Element 2024-06-17
dt[2].to_time      # => 2024-06-17 00:00:00 UTC

td = CArray.int64(7) { |i| i + 1 }.timedelta(unit: :D)
dt + td            # => CATime, each element advanced
dt - dt            # => CATimedelta (all zero)

dt.min.to_s        # => "2024-06-15"
dt.max.to_s        # => "2024-06-21"
dt.sum             # => raises TypeError (sum of instants is undefined)

dt[2..5]           # => CATime         (views keep the time type)
```

## Construction

### A regular series: `time_series`

`CArray.time_series` builds a run of consecutive ticks from a start instant:

```ruby
CArray.time_series("2024-06-15", count: 7, unit: :D)
CArray.time_series("2024-06-15T12:00:00", count: 24, unit: :h)
CArray.time_series("2024-06-15", count: 144, unit: "10 minutes")
```

`count:` is the number of elements; `unit:` is the resolution of the grid
(and of the resulting array). The third example shows a *composite*
resolution — a tick of ten minutes — described below.

Spacing is one tick by default. When you want the elements further apart
than the grid they sit on, say so with `step:`:

```ruby
CArray.time_series("2024-06-15", count: 7, unit: :h, step: "1 day")
# one instant per day, carried on an hourly grid

CArray.time_series("2024-01-01", count: 5, unit: :M, step: "1 year")
```

Keep the two roles apart: `unit:` is the grid the result is *stored* on,
`step:` is how far apart the elements are. A `step:` has to be a whole
multiple of `unit:` — stepping by less than one tick has nowhere to land,
and a calendar step on a fixed-length grid (`unit: :h, step: "1 month"`)
raises, because a month is not a fixed number of hours.

### An inclusive range: `time_range`

`CArray.time_range` covers the span between two instants on the unit grid,
both endpoints included; an off-grid endpoint floors to its bucket head:

```ruby
r = CArray.time_range("2024-06-15T10:00", "2024-06-16T00:00", unit: "10 minutes")
r.size          # => 85
r[0].to_s       # => "2024-06-15T10:00:00Z"
r[-1].to_s      # => "2024-06-16T00:00:00Z"
```

`step:` works here too, with the same rule:

```ruby
CArray.time_range("2024-06-15", "2024-06-18", unit: :h, step: "1 day")
# => 2024-06-15, 06-16, 06-17, 06-18   (hourly grid, daily spacing)
```

With a `step:` wider than one tick, the phase is anchored at `start` and
`last` becomes a bound rather than a member: the series stops at the last
step at or before it. So a `last` of `"2024-06-18 13:00"` above still ends
at `06-18 00:00`.

### From values: `CArray.time`

`CArray.time` builds an array from a value or a collection of values —
strings, Ruby `Time` / `DateTime` objects, or Unix-seconds integers. A single
literal gives a 1-element result; a Ruby `Array` or a CArray gives a
same-shape result parsed per cell.

```ruby
CArray.time("2024-06-15", unit: :D)                            # 1-element
CArray.time(%w[2024-01-15 2024-02-15 2024-03-15], unit: :D)    # Ruby Array
CArray.time(CA_OBJECT(%w[2024-01-15 2024-02-15]), unit: :D)    # CArray
CArray.time(%w[15/01/2024 20/06/2024], format: "%d/%m/%Y", unit: :D)
```

Parsing uses Ruby's own date parser under the hood — the flexible
`Date._parse` heuristic by default, or strict `strftime`-style pattern
matching when you pass `format:`. Use `format:` when the day/month order is
ambiguous or the layout is not ISO.

There are two departures from `Date._parse`. A year-month (`"2019-09"`) and
a bare year (`"2019"`) are read as such, so the form a `:M` or `:Y` element
prints comes back in; a missing finer field names the head of that period.
And a field out of range raises instead of rolling over into another date —
`"2019-02-31"` is refused rather than becoming 2019-03-03. Watch out for
`"201909"`: to Ruby that is a valid YYMMDD (2020-19-09), so it is refused as
well. Write `"2019-09"`, or name the layout with `format: "%Y%m"`.

`CArray.time` is **strict by default**: an unparseable value raises. Pass
`on_error: :mask` to turn parse failures into UNDEF cells instead. A masked
or `nil` *input* cell is a missing value, not a parse failure, and always
becomes UNDEF regardless:

```ruby
CArray.time(CA_OBJECT(["2024-01-01", "oops"]), unit: :D)
# => raises

x = CArray.time(CA_OBJECT(["2024-01-01", "oops"]), unit: :D, on_error: :mask)
x.is_masked.to_a    # => [false, true]
```

### Wrapping an existing integer array

If you already have an `int64` CArray whose values are tick counts, put the
time interpretation on it directly — this is zero-copy:

```ruby
raw = CArray.int64(5) { |i| i * 86400 }
dt  = raw.time(unit: :s)          # instance-method sugar
dt  = CATime.wrap(raw, unit: :s)  # the same, spelled as a class method

dt.ticks.to_a == raw.to_a         # => true (same storage)
```

A narrower integer type is widened to `int64` first — a copy, but lossless.
A `Float` or other non-integer receiver raises `TypeError`; cast explicitly
(`arr.int64.time(unit: :s)`) if the truncation is intended.

A fresh, zero-filled allocation is also available:

```ruby
CATime.new(10, unit: :ns)    # 10 elements, all zero (= 1970-01-01)
CATime.new(3, 4, unit: :D)   # multi-dimensional
```

### Rebasing relative indices: `origin:`

`CArray#time` takes an `origin:` for the common "index relative to a base
instant" pattern — a forecast lead-time axis, an elapsed-step counter. The
array's values are counted from `origin` and rebased to the epoch:

```ruby
lead = CArray.int64(4) { |i| i }               # lead-time steps 0..3
lt   = lead.time(unit: "3 hours", origin: "2022-01-01T09:00")
lt.strftime("%H:%M").to_a
# => ["09:00", "12:00", "15:00", "18:00"]
```

With `origin` omitted the values are already epoch-anchored (and the wrap is
zero-copy). `timesteps` (later in this chapter) is the inverse — it recovers
the relative index.

## Resolutions: count × base

A resolution is a **base unit** times an integer **count**. The stored
`int64` value counts *ticks* (a tick = count × base) since the epoch. A bare
base such as `:D` is count 1; `"10 minutes"` is count 10 of base `:m`.

The base units:

| base | meaning     | example: value of 2024-01-01 at count 1 |
|------|-------------|------------------------------------------|
| `:Y` | year        | 54 (= 1970 + 54)                         |
| `:M` | month       | 650                                      |
| `:W` | week        | 2818                                     |
| `:D` | day         | 19723                                    |
| `:h` | hour        | 473376                                   |
| `:m` | minute      | 28402560                                 |
| `:s` | second      | 1704067200                               |
| `:ms`| millisecond | 1704067200000                            |
| `:us`| microsecond | 1704067200000000                         |
| `:ns`| nanosecond  | 1704067200000000000                      |
| `:ps`, `:fs`, `:as` | pico / femto / atto second | implemented, rarely used |

Note that `:m` is **minute** and `:M` is **month** — the unit letters are
case-sensitive. To avoid confusion, spell months out as `"1 month"`.

The bases split into two groups. The **fixed-length** group (`:W`, `:D`,
`:h`, … `:as`) is an exact number of seconds per tick. The **calendar**
group (`:Y`, `:M`) counts month ordinals — a month has no exact second
count, so the two groups do not inter-convert by a fixed ratio. This
distinction reappears throughout the chapter.

### The resolution descriptor

`dt.unit` returns a `CATime::Resolution` object carrying `count`, `base`,
and `tick_ratio` (seconds per tick for a fixed base, months per tick for a
calendar base):

```ruby
dt = CArray.time_series("2024-01-01", count: 3, unit: "10 minutes")
dt.unit             # => #<CATime::Resolution 10 m>
dt.unit.base        # => :m
dt.unit.count       # => 10
dt.unit.tick_ratio  # => (600/1)     # seconds per tick

CATime::Resolution.parse("3 hours")  # accepts Symbol / String / Resolution
CATime::Resolution.new(3, :h)
```

Everywhere a `unit:` keyword appears, it accepts any of the three spellings:
a Symbol (`:D`), a String (`"10 minutes"` — whitespace required, singular
and plural both fine), or a `Resolution` object.

### Changing the unit: `to_unit`

`to_unit` moves the array to another grid. Changing the resolution is a
**cast** — the same thing `CArray.time` does to its input — not a promise
that the values happen to fit.

Toward a **finer** grid it is exact. A day is 24 whole hours, so every element
lands exactly where it already was and only the tick counting changes:

```ruby
dt = CArray.time_series("2024-06-15", count: 3, unit: :D)

dt.to_unit(:h).ticks     # => the day indices, times 24
dt.to_unit(:h).to_time   # => unchanged instants

dt.to_unit("10 minutes")                            # 1 day = 144 ten-minute ticks
CArray.time("2024-01-01", unit: :Y).to_unit(:M)     # 1 year = 12 whole months
```

Toward a **coarser** grid each instant floors to the head of the tick it falls
in — toward the past, the same direction `CArray.time` and `floor` use, so a
date before 1970 rounds like any other:

```ruby
CArray.time("2024-01-01 05:00", unit: :h).to_unit(:D)   # => 2024-01-01
CArray.time("1969-03-05 12:00", unit: :h).to_unit(:D)   # => 1969-03-05
```

Reach for `floor` / `ceil` / `round` (later in this chapter) when you want a
different boundary; they move the values and leave the storage unit alone, so
pair them with `to_unit` when the storage should change too.

Months and years are not a whole number of days, but a `:M` **time** is still a
real instant — the month's first midnight — so `to_unit` crosses that boundary
as well:

```ruby
m = CArray.time("2024-03-01", unit: :M)
m.to_unit(:D)                                     # => 2024-03-01
CArray.time("2024-03-05", unit: :D).to_unit(:M)   # => 2024-03   (floors)
```

This is how you take a monthly or quarterly series into day-level work: walk
the grid on `:M`, move the storage to `:D`, then add a day offset.

```ruby
q = CArray.time_range("2019-09-01", "2020-06-01", unit: :M, step: "3 months")
q.to_unit(:D) + CATimedelta.wrap(CA_INT64([14]), unit: :D)
# => 2019-09-15, 2019-12-15, 2020-03-15, 2020-06-15
```

Weeks are the exception: a month head is not week-aligned, so `:M` → `:W`
raises rather than move the instant.

`CATimedelta#to_unit` is the duration counterpart, and it differs in two ways.
It truncates **toward zero** (`+30 h` → `+1 D`, `-30 h` → `-1 D`), because a
duration is a magnitude rather than a point on an axis, and it will not cross
the calendar boundary at all — a one-month duration has no length in days.

## Storage and `ticks`

A CATime's storage layout is identical to a plain `int64` array — the time
interpretation adds no bytes. When you really do want the raw tick counts —
to feed a routine that wants plain integers, or to search the storage space
directly — the named accessor is `ticks`:

```ruby
dt = CArray.int64(5) { |i| i * 86400 }.time(unit: :s)
dt.ticks.to_a       # => [0, 86400, 172800, 259200, 345600]
dt.ticks.class      # => CArray  (plain int64, shared storage)
```

Writes through `ticks` reach the same storage as the time array. The same
accessor exists on `CATimedelta`.

## Arithmetic: the algebra of instants and durations

A **CATime** is an instant — a point in time. A **CATimedelta** is a
duration — an amount of elapsed time with no epoch anchor. The algebra is
the everyday one: subtracting two instants gives a duration; adding a
duration to an instant gives another instant; adding two instants is
meaningless and raises.

```ruby
a = CArray.time("2024-06-15", unit: :D)
b = CArray.time("2024-06-20", unit: :D)

gap = b - a          # => CATimedelta  (instant − instant = duration)
gap[0].to_s          # => "5D"
gap[0].to_seconds    # => (432000/1)   exact Rational seconds

wk = CA_INT64([7]).timedelta(unit: :D)
a + wk               # => CATime 2024-06-22  (instant + duration = instant)
a + b                # => raises TypeError
```

The full table:

| operation      | result             | meaning                                     |
|----------------|--------------------|---------------------------------------------|
| `dt + td`      | `CATime`           | instant plus duration                       |
| `dt - td`      | `CATime`           | instant minus duration                      |
| `dt - dt2`     | `CATimedelta`      | difference between two instants             |
| `dt + dt2`     | raises `TypeError` | sum of instants is undefined                |
| `dt + Numeric` | raises `TypeError` | unitless arithmetic on instants is rejected |
| `td + dt`      | `CATime`           | commutative                                 |
| `td + td2`     | `CATimedelta`      |                                             |
| `td - td2`     | `CATimedelta`      |                                             |
| `td * Integer` | `CATimedelta`      | scaling                                     |
| `td / Integer` | `CATimedelta`      | scaling                                     |
| `td / td2`     | `CArray`           | ratio of the raw counts; a plain array      |

### Cross-unit arithmetic

The operands may carry different units; arithmetic reconciles them, so no
manual conversion is needed. The rules:

- **`dt ± td`** (instant ± duration): the instant is the anchor, so the
  result keeps `dt`'s unit and the duration is converted into it. A coarser
  duration widens exactly; a **finer** one is **truncated** to `dt`'s grid.
- **`dt - dt2`** and **`td ± td2`**: the result takes the **finer** of the
  two units (both operands widen exactly).
- **cross-group**: a calendar duration (`:Y` / `:M`) has no fixed ratio to
  seconds, so `dt(:s) + td(:M)` raises — that step is calendar arithmetic;
  use the step system below.
- **overflow**: widening a wide range into a fine unit (a millennium-spanning
  difference resolved to `:ns`) can exceed `int64`; it raises rather than
  silently wrapping.

```ruby
CArray.time("2024-01-01", unit: :h) + CA_INT64([1]).timedelta(unit: :D)
# => an :h instant, advanced 24 hours (the day widens into hours)

CArray.time("2024-01-01", unit: :D) + CA_INT64([30]).timedelta(unit: :h)
# => a :D instant, advanced 1 day    (30 h truncated to the day grid)
```

## Comparisons

The ordering operators work element-wise, like any CArray operator:

```ruby
dt1 < dt2       # => boolean CArray
dt1.eq(dt2)     # => boolean CArray  (element-wise equality)
dt1 <=> dt2     # => CArray of -1 / 0 / 1
```

As on any CArray, element-wise equality is `#eq` / `#ne` — `dt1 == dt2` is
whole-array structural equality returning a single `true` / `false`.
Comparison results are plain `bool` or `int` arrays; they no longer carry
time semantics.

The two operands may carry **different units**. The left-hand side (the
reference) reconciles the right-hand operand into its own unit, losslessly:
a coarser operand widens exactly, and a finer operand is accepted only when
every value lands exactly on the coarser grid. A value that cannot be
aligned without loss raises rather than being silently truncated:

```ruby
dt_s   = CArray.int64(2) { |i| [10, 20][i] }.time(unit: :s)
dt_ms  = CArray.int64(2) { |i| [10000, 20000][i] }.time(unit: :ms)  # 10s, 20s

dt_ms < dt_s     # OK: :s lifted to :ms (coarser → finer is always exact)
dt_s  < dt_ms    # OK: 10000 / 20000 ms are whole seconds

dt_bad = CArray.int64(2) { |i| [10500, 20000][i] }.time(unit: :ms)  # 10.5 s
dt_s < dt_bad    # => raises ArgumentError (not a whole multiple of :s)
```

Because the left operand drives the conversion, a right-hand Ruby `Time` /
`DateTime` / `CATime::Element` is accepted too — `dt < Time.utc(2024, 6, 17)`
lifts the `Time` into `dt`'s unit.

## Elements

Fetching a single cell returns a dedicated `CATime::Element` object rather
than a bare integer:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
s  = dt[2]

s.class        # => CATime::Element
s.value        # => 19891                          (raw int64 tick index)
s.unit         # => #<CATime::Resolution 1 D>
s.to_time      # => 2024-06-17 00:00:00 UTC        (Ruby Time)
s.to_date      # => Ruby Date
s.to_datetime  # => Ruby DateTime (UTC)
s.to_s         # => "2024-06-17"
s.inspect      # => "#<CATime::Element 2024-06-17 (19891D)>"
s < dt[3]      # => true                           (Comparable mixed in)
```

`to_s` is **unit-aware**: a `:Y` element prints `"2024"`, a `:M` element
`"2024-03"`, a `:D` element `"2024-03-01"`, and `:h` and finer print full
ISO 8601 with the time. This keeps the `(value, unit)` pair recoverable from
the printed form — a month and a day element at the same instant print
differently.

Elements compare by **instant** via `Comparable`, reconciling a different
unit — a `:s` and a `:ms` element at the same moment are `==`, and a Ruby
`Time` / `DateTime` operand is accepted. `eql?` / `hash`, by contrast, are
unit-strict (mirroring `1 == 1.0` but `!1.eql?(1.0)`), so those two elements
key a `Hash` separately.

Element arithmetic carries the time semantics:

```ruby
dt[3] - dt[1]        # => CATimedelta::Element "2D"  (elapsed duration)
dt[0] + gap_element  # => CATime::Element            (advance by a duration)
```

A cross-group step on an element (a `:s` instant plus a `:M` duration) raises
— for calendar stepping on a single value, go through `to_date` and Ruby's
`Date#next_month` / `#next_year`.

## Field accessors

The calendar breakdown of every element, as plain numeric arrays:

```ruby
dt = CArray.time_series("2024-06-15", count: 7, unit: :D)
dt.year      # => CArray [2024, 2024, ...]
dt.month     # => CArray [6, 6, ...]
dt.day       # => CArray [15, 16, 17, 18, 19, 20, 21]
dt.hour      # precision follows the array's unit
dt.minute
dt.second
dt.weekday   # => CArray [6, 0, 1, 2, 3, 4, 5]   (Sun=0..Sat=6)
dt.yday      # day of year (1..366)
dt.jd        # Julian Day Number
dt.ajd       # Astronomical Julian Day (Float)
dt.is_leap   # boolean CArray
```

Each accessor returns a plain `Integer`, `Float`, or `bool` CArray — a year
number is no longer a time, so the result does not carry the time type. The
fields are computed by vectorized civil-date algebra directly on the `int64`
storage — no per-cell `Time` object — so they are fast on large arrays and
exact for every unit, including `:M` and `:Y`.

### Truncation to the unit

An instant is stored as an integer tick, so building an array at a given
unit **floors each instant to that unit** — anything finer than the tick is
discarded at construction, not at read time:

```ruby
d = CArray.time("2024-06-15T12:30:45", unit: :D)
d[0].to_time    # => 2024-06-15 00:00:00 UTC   (12:30:45 truncated to the day)
d.hour.to_a     # => [0]                        (the finer part was never stored)

s = CArray.time("2024-06-15T12:30:45", unit: :s)
s[0].to_time    # => 2024-06-15 12:30:45 UTC   (:s keeps the full instant)
```

The cut-off is the storage *tick* (count × base), so a coarser tick drops
more — a `"10 minutes"` array keeps the minute at 10-minute resolution but
zeroes the seconds.

### Whole-array conversion and `strftime`

`to_time` / `to_date` / `to_datetime` convert every element to a Ruby
`Time` / `Date` / `DateTime` (UTC), returned as an object CArray. `strftime`
formats every element into a string array:

```ruby
dt.to_time                      # => CArray(:object) of Ruby Time
dt.strftime("%Y-%m-%d").to_a    # => ["2024-06-15", "2024-06-16", ...]
dt.strftime("%a %b %d, %Y").to_a
# => ["Sat Jun 15, 2024", "Sun Jun 16, 2024", ...]
```

The results are plain object / string arrays — no longer times. The input
mask propagates.

## Reductions

A reduction reports on the array's **own unit**. The order-structure
reductions (`min`, `max`, `minmax`) pick an existing element, so nothing
moves. The centroid, spread and order statistics (`mean`, `median`,
`percentile`, `quantile`, `stddev`, `stddevp`) can land between two ticks,
and they round to the nearest one rather than refining the output on their
own. Precision is declared by the caller, before the reduction, with
`to_unit`.

| reduction                  | result                      | rationale                                |
|----------------------------|-----------------------------|------------------------------------------|
| `dt.min`                   | `CATime::Element`           | earliest instant                         |
| `dt.max`                   | `CATime::Element`           | latest instant                           |
| `dt.minmax`                | `[Element, Element]`        | earliest and latest                      |
| `dt.mean`                  | `Element` at `dt.unit`      | centroid instant                         |
| `dt.median`                | `Element` at `dt.unit`      | median instant                           |
| `dt.percentile(*p)`        | `Element`, or an `Array`    | order statistics                         |
| `dt.quantile`              | `Array` of 5 `Element`      | the five quartiles                       |
| `dt.stddev` / `dt.stddevp` | `CATimedelta::Element`      | spread of the instants, as a duration    |
| `dt.sum`                   | raises `TypeError`          | sum of instants is undefined             |
| `dt.variance` / `variancep`| raises `TypeError`          | squared-time units; no type can hold it  |

```ruby
dt = CArray.time(%w[2024-06-15 2024-06-16], unit: :D)

dt.mean.to_s               # => "2024-06-16"       the day grid (19889.5 -> 19890)
dt.to_unit(:h).mean.to_s   # => "2024-06-15T12:00:00Z"   the hour grid, declared first
```

Because the answer stays on the array's grid, the span an array can hold is
the span its reductions can answer in — a daily series covering 1600–2400
takes a mean, which an output refined to nanoseconds (roughly 1678–2262)
could not.

A spread pays more for the rounding than a centroid, since it is not a
lattice point to begin with. On a coarse unit, widen first:

```ruby
t = CArray.time(%w[2024-01-01 2024-01-02 2024-01-05 2024-01-09], unit: :D)

t.stddev                 # => 4 D    the exact spread is 3.594 days — about 11% high
t.to_unit(:h).stddev     # => 86 h   0.3% off
```

A calendar array (`:M`, `:Y`) stores month or year ordinals, so that is the
space it reduces in: the mean of 2024-01 and 2024-03 is 2024-02, the middle
month. Rebuild the array on the `:D` grid
(`CArray.time(m.to_time, unit: :D)`) when the day-space answer is the one
you want.

Durations reduce by the same rule and also have a well-defined `sum`:
`td.sum`, `td.mean`, `td.median`, `td.stddev` and `td.percentile` all come
back as `CATimedelta::Element` on `td.unit`. The exception is
`td.variance` / `td.variancep`, which stay a plain `Float`: their value is
in *squared* ticks, and no type represents squared time.

## Views keep the time type

The time identity is preserved across every view-creating method — this is
the Face property from [Faces](12_faces.md), and it is what makes a time
array more than a comment on an integer array:

```ruby
dt = CArray.time_series("2024-06-15", count: 12, unit: :D)

dt[2..5]           # slice                => CATime
dt[bool_mask]      # boolean select      => CATime
dt.reshape(3, 4)   #                     => CATime
dt.transpose       #                     => CATime
dt.flip            #                     => CATime
dt.roll(2)         #                     => CATime
dt.sort            # chronological sort  => CATime
dt.copy            # entity copy         => CATime
dt.flatten         #                     => CATime

dt.reshape(3, 4).transpose.flip[0..1].unit.base   # => :D
```

## Ordering, search, and coordinate lookup

A time axis is a natural coordinate, so ordering, binary search, and
interpolation-based lookup all work on it directly.

### Ordering and rank

The value-returning `sort` / `partition` keep the time type (previous
section). The index-returning family returns plain index arrays, comparing
by true chronological order:

```ruby
dt = CArray.time_series("2024-06-17", count: 5, unit: :D)[CA_INT64([2,0,4,1,3])]
# a shuffled time axis

dt.sort_index          # => [1, 3, 0, 4, 2]  (indices that sort it)
dt.order               # => [2, 0, 4, 1, 3]  (each cell's rank, 0 = earliest)
dt.min_index           # => 1                (position of the earliest instant)
dt.max_index           # => 2
dt.partition_index(2)  # partial-sort indices with the 2nd element in place
```

### Search

`bsearch` / `search` take a **time query** and return positions in the
axis. The query may be another time array, a `CATime::Element`, a Ruby
`Time`, or a Ruby `DateTime`:

```ruby
axis = CArray.time_series("2024-06-15", count: 6, unit: :D)

axis.bsearch(Time.utc(2024, 6, 17))   # => 2   (Time lifted into the axis unit)
axis.bsearch(axis[3])                 # => 3   (an Element operand)

q = CArray.time_series("2024-06-17", count: 2, unit: :D)
axis.bsearch(q)                       # => [2, 3]
```

The query may carry a **different unit** — the axis reconciles it into its
own unit with the same lossless rules as comparison:

```ruby
axis_h = CArray.time_series("2024-06-15", count: 72, unit: :h)  # hourly
q_D    = CArray.time_series("2024-06-16", count: 2, unit: :D)   # daily

axis_h.bsearch(q_D)   # => [24, 48]   (:D lifted to :h, ×24)
```

A **bare number is rejected** — a raw integer would touch the hidden storage
epoch, which the axis has no way to read as an instant. If you really want a
storage-space search, be explicit:

```ruby
axis.bsearch(19538)         # => raises TypeError
axis.ticks.bsearch(19538)   # => OK: explicit storage-space search
```

### Coordinate lookup

`locate_addr` and `locate_nearest_addr` compose ordering and search into the
common "match observation times to a reference axis" operation:

```ruby
axis = CArray.time_series("2024-06-15", count: 24, unit: :h)
obs  = axis[CA_INT64([5, 12, 20])]

obs.locate_addr(axis)           # => [5, 12, 20]  (exact matches)
obs.locate_nearest_addr(axis)   # => nearest index for off-grid times
```

Cross-unit observations are reconciled the same way as search.

## The step system: bucketing, matching, grouping

A time axis is, underneath, an integer count since an epoch. The **step
system** leans into that: it re-expresses each instant as the integer *index
of the fixed-width bucket* it falls in, counted from a chosen origin. Once
time is an integer index, bucketing, matching, and grouping all become plain
integer arithmetic — fast, exact, and free of per-cell `Time` objects.

A step is "N of a unit", written the same way as a resolution: a String
(`"3 hours"`, `"1 month"`, `"10 days"`) or a bare Symbol as the count-1
shorthand (`:h`, `:M`). The compact `"3h"` (no space) is rejected, and
unknown words raise.

### `timesteps` — the core primitive

`timesteps(unit:, origin: nil)` returns an `int64` CArray: the index `k` of
the bucket each element falls in, counted from `origin` (default: the
epoch). Everything else in this section is a thin layer on top of it.

```ruby
t0 = "2024-03-10T00:00:00Z"
dt = CArray.time_series(t0, count: 6, unit: :h)   # 00:00 .. 05:00

dt.timesteps(unit: "1 hour",  origin: t0)   # => [0, 1, 2, 3, 4, 5]
dt.timesteps(unit: "3 hours", origin: t0)   # => [0, 0, 0, 1, 1, 1]
```

The index **floors toward the past**, so an element before `origin` gets a
*negative* index — a normal value, never masked:

```ruby
past = CArray.time(CA_OBJECT(["2024-03-09T22:00:00Z"]), unit: :h)
past.timesteps(unit: "3 hours", origin: t0)   # => [-1]
```

`origin` sets the **phase** of the bucket grid (the storage epoch stays
1970-01-01). It accepts a `Time`, an ISO string, or a `CATime::Element`. An
origin that does not land exactly on the grid the buckets are counted on
raises rather than silently shifting the phase, and a bare `Integer` origin
is rejected.

### `floor` / `ceil` / `round` — snap to a bucket head

These return a `CATime` (same unit) at the bucket boundary:

```ruby
dt.floor(unit: "3 hours", origin: t0).strftime("%H:%M").to_a
# => ["00:00", "00:00", "00:00", "03:00", "03:00", "03:00"]

dt.ceil(unit: "3 hours", origin: t0).strftime("%H:%M").to_a
# => ["00:00", "03:00", "03:00", "03:00", "06:00", "06:00"]  (on-boundary keeps itself)

dt.round(unit: "3 hours", origin: t0).strftime("%H:%M").to_a
# => ["00:00", "00:00", "03:00", "03:00", "03:00", "06:00"]  (nearest; ties → future)
```

`floor` is the period-bucket operation (toward the past). `round` picks the
nearest head with ties toward the future, exactly even for odd step widths.
These take keyword arguments, so they do not collide with the argument-less
numeric `CArray#floor` / `#round`.

### `is_righttime` — the on-grid guard

A `timesteps` match means "same bucket", **not** "same instant".
`is_righttime` flags the cells that sit exactly on a bucket head — use it as
an assertion before matching two series, to catch one that is silently
off-grid:

```ruby
dt.is_righttime(unit: "3 hours", origin: t0)   # => [1, 0, 0, 1, 0, 0]
```

### `from_timesteps` — the inverse

`CATime.from_timesteps(k, unit:, origin: nil)` maps a bucket index back to
its head instant. A scalar `k` returns an `Element`; a CArray `k` returns a
`CATime`:

```ruby
k = dt.timesteps(unit: "3 hours", origin: t0)
CATime.from_timesteps(k, unit: "3 hours", origin: t0)
# == dt.floor(unit: "3 hours", origin: t0)

CATime.from_timesteps(2, unit: "3 hours", origin: t0).to_s
# => "2024-03-10T06:00:00Z"
```

The answer is stored on the `unit:` grid, with one exception: a week bucket
answers on `:D`. A week grid counts from the epoch, a Thursday, so it cannot
hold its own bucket head — the head is the ISO Monday, four days off every
week tick. Days hold it exactly, so `unit: :W` names the bucket and the
answer lands on the day grid, matching `floor` cell for cell:

```ruby
dt = CArray.time(%w[2024-06-10 2024-06-15 2024-06-17], unit: :D)   # Mon, Sat, Mon
back = CATime.from_timesteps(dt.timesteps(unit: :W), unit: :W)
back.unit                      # => #<CATime::Resolution 1 D>
back.strftime("%F").to_a       # => ["2024-06-10", "2024-06-10", "2024-06-17"]  (== floor)
```

### Calendar steps — month and year

Months and years are variable-length, but the step system handles them on
day-or-finer storage through vectorized civil-date integer algebra — no
per-cell `Time`, correct for pre-epoch dates too:

```ruby
d = CArray.time(
  CA_OBJECT(["2024-01-15", "2024-02-03", "2024-02-28", "2023-12-31"]), unit: :D)

d.floor(unit: "1 month").strftime("%Y-%m-%d").to_a
# => ["2024-01-01", "2024-02-01", "2024-02-01", "2023-12-01"]

d.timesteps(unit: "1 month")   # months since 1970-01
# => [648, 649, 649, 647]
```

A calendar grid is addressed by month, so its buckets start on the 1st and
nowhere else. The origin has to be a month head — the 1st at 00:00 — and
anything else raises rather than quietly dropping the day. Which month is
up to you, and that makes **fiscal years and quarters** a one-liner: point
the origin at the fiscal start month.

```ruby
fy = CArray.time(CA_OBJECT(["2024-03-01", "2024-08-01", "2025-01-01"]), unit: :D)

# fiscal year starting each July
fy.timesteps(unit: "1 year", origin: "2024-07-01")
# => [-1, 0, 0]   (Mar 2024 is in FY2023; Aug 2024 and Jan 2025 in FY2024)
```

### Weekly buckets (ISO Monday by default)

1970-01-01 is a Thursday, so a naïve week grid from the epoch would be
Thursday-anchored. Instead, a week step defaults its origin to the ISO
Monday 1970-01-05, so `floor(unit: "1 week")` yields Monday-anchored weeks
with no configuration. Anchor on a different weekday by passing an explicit
`origin`:

```ruby
w = CArray.time(CA_OBJECT(["2024-03-13", "2024-03-16", "2024-03-18"]), unit: :D)
w.floor(unit: "1 week").strftime("%a %Y-%m-%d").to_a
# => ["Mon 2024-03-11", "Mon 2024-03-11", "Mon 2024-03-18"]
```

### Which steps are allowed

A timestep is an integer, so a `(step, storage unit)` pair works whenever
one tick is a **whole multiple of the other** — in either direction:

- **Step coarser than the tick** (`"3 hours"` on `:h` storage): the ordinary
  case, several ticks per bucket.
- **Step finer than the tick** (`"1 minute"` on `:h` storage): every element
  already sits on the finer grid, so its timestep is just the tick index
  widened. An hour is 60 whole minutes, so the answer is the hour index
  times 60. `floor` / `ceil` / `round` are the identity here and
  `is_righttime` is all-true — nothing is off-grid, and saying so is the
  honest answer, not a shortcut.
- **Neither a whole multiple of the other** (`"7 minutes"` on `:h` storage,
  or `:h` on `"90 minutes"` storage): no integer timestep exists, so this
  raises `ArgumentError`.

| step unit ↓ \ storage → | `:Y` / `:M`             | `:W`     | `:D` or finer            |
|--------------------------|-------------------------|----------|--------------------------|
| `:Y` / `:M`              | integer ratio (either direction) | raises | civil-date path |
| `:W`                     | raises (no fixed ratio) | integer  | integer (`:W`→`:D` = ×7) |
| `:D` or finer            | raises (no fixed ratio) | integer (a week is 7 whole days) | integer, when either ratio is whole |

The two `raises` cells are the calendar / fixed-length boundary: a month is
not a fixed number of days, so no ratio exists in either direction. Only
the calendar-step-on-day-or-finer corner escapes it, through the civil-date
path.

### Time buckets as categories → grouped aggregation

Compose `floor` with `categorize` (see
[Categories and grouping](24_categories_and_grouping.md)) to turn period
heads into an ordered categorical, ready for grouped aggregation. No new
method is needed — the `floor` result is a `CATime`, and `categorize` puts
its distinct period heads (as ordered `Element` labels) onto a
`CACategorical`:

```ruby
d     = CArray.time(
  CA_OBJECT(["2024-01-15", "2024-02-03", "2024-02-28", "2023-12-31"]), unit: :D)
temps = CA_DOUBLE([1, 2, 3, 4])

cat = d.floor(unit: "1 month").categorize(sort_labels: true)
cat.labels.map { |s| s.to_time.strftime("%Y-%m") }
# => ["2023-12", "2024-01", "2024-02"]

temps.group_by_category(cat).mean   # => [4.0, 1.0, 2.5]  (per-month mean)
```

The categorical's codes are `0..k-1` in label order — this is *not* the same
as `timesteps` (the absolute bucket number). Use `categorize` for group
labels, `timesteps` for matching and addressing.

### Matching two series

Because `timesteps` is an **absolute** integer keyed to `(step, origin)`,
two series projected onto the same `(step, origin)` share one integer index
space. Matching, joining, and dense positional addressing then reduce to
integer operations — no hash join, no per-cell comparison. Aligning
observations to forecast valid-times is the canonical example:

```ruby
oidx = obs_vt.timesteps(unit: "1 hour")    # absolute hour index of each obs
fidx = fcst_vt.timesteps(unit: "1 hour")   # both series share one index space

# guards: obs must sit on the grid, one obs per bucket
raise "obs off grid"  unless obs_vt.is_righttime(unit: "1 hour").all
raise "obs not unique" unless oidx.to_a.uniq.size == oidx.size

# dense addressing — grid over the obs span, forecasts clipped into it
k0, k1  = oidx.min, oidx.max
grid    = CArray.float64(k1 - k0 + 1) { UNDEF }
grid[oidx - k0] = obs_values

inr     = fidx.ge(k0) & fidx.le(k1)
matched = CArray.float64(fidx.size) { UNDEF }
matched[inr] = grid[(fidx - k0)[inr]]   # obs aligned to each forecast valid-time
```

Two caveats make this correct and fast. First, the grid's size is the
observation *span*, not its count — a single stray timestamp (a decade-old
outlier) blows the allocation up. Use dense addressing for regular series;
for irregular point clouds fall back to `oidx.is_in(fidx)` or
`fidx.locate_addr(oidx)`, which work directly on the integer indices.
Second, the scatter must be unique — two observations in one bucket collide
(last write wins); the uniqueness check above catches it.

### Safety: overflow and lossy origin both raise

The step system converts "silently wrong" into a loud error:

- **Overflow.** The fine units (`:us` … `:as`) have a small `int64` span
  (`:as` covers only ±9 seconds around the epoch). If a step, origin, or
  data span would overflow the `int64` arithmetic, the operation raises
  `RangeError` instead of silently wrapping.
- **Lossy origin.** An origin that does not land exactly on the storage
  grid (an `:h` axis with a `00:30` origin) raises, rather than truncating
  the grid phase.

## CATimedelta in detail

`CATimedelta` is structurally identical to `CATime` — `int64` storage plus a
resolution — but with duration semantics rather than an epoch anchor.

```ruby
# construction
td = CATimedelta.new(5, unit: :s)
td = CATimedelta.wrap(int64_raw, unit: :ms)
td = int64_raw.timedelta(unit: :h)

# arithmetic
td + td2     # => CATimedelta
td * 2       # => CATimedelta
td / 2       # => CATimedelta
td.sum       # => CATimedelta::Element
td.mean      # => CATimedelta::Element

# elements
td[2]              # => CATimedelta::Element
td[2].value        # => raw int64
td[2].unit         # => #<CATime::Resolution 1 s>
td[2].to_s         # => "60s"     (with a unit suffix)
td[2].to_seconds   # => Rational (exact)
```

`to_seconds` returns an **exact** Rational for a fixed-length unit but
raises for `:Y` / `:M` — a month has no exact second count. Use
`to_seconds_approx` for a nominal 30.5-day / 365.25-day estimate when an
approximation is acceptable.

Ordering and search work the same as for `CATime` — the reference duration
reconciles a cross-unit operand losslessly. Coverage is narrower, though: a
timedelta axis accepts another timedelta array or a `CATimedelta::Element`,
but **not** a Ruby `Time` or `DateTime`. Those name absolute instants, not
durations, so they raise — a duration has no meaningful conversion from an
instant.

## Masks

The mask travels with the underlying `int64` entity, so everything from
[Masks and missing values](05_masks.md) applies directly:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
dt[2] = UNDEF
dt.is_masked.to_a    # => [false, false, true, false, false]
dt.min.to_s          # => "2024-06-15"    (ignores masked elements)
dt.strip_mask(0)     # => CATime with masked cells filled (0 = the epoch)
```

## Fixed by design

- The epoch is **1970-01-01 UTC**, fixed. Arbitrary reference times — as
  used by NetCDF CF conventions — are the province of external gems; the
  integer bucketing and matching those workflows need is what the step
  system provides in core.
- Non-standard calendars (noleap, 360-day) are likewise out of core.
- Storage is **`int64`**, fixed.
- `sum` and `variance` on instants raise: the sum of dates is nonsense, and
  the variance of instants has squared-time units no type can represent
  (use `stddev`, which is a duration).

## Quick recap

- Time is an integer index on a tick grid: `int64` ticks × a resolution
  (count × base), counted from the 1970-01-01 UTC epoch.
- `CArray.time_series` / `time_range` build regular grids; `CArray.time`
  parses values (strict by default, `on_error: :mask` to soften);
  `raw.time(unit:)` wraps an existing integer array zero-copy, with
  `origin:` to rebase relative indices.
- `CATime` is an instant, `CATimedelta` a duration; the algebra is
  instant − instant = duration, instant ± duration = instant, and
  instant + instant raises.
- Cross-unit operands are reconciled losslessly — exact widening is
  automatic, lossy narrowing raises (except `dt ± td`, where a finer
  duration truncates to the instant's grid).
- Elements (`CATime::Element`) carry `(value, unit)`, print unit-aware,
  compare by instant, and convert via `to_time` / `to_date` / `to_datetime`.
- Field accessors (`year` … `is_leap`) and `strftime` return plain arrays,
  computed by vectorized civil-date algebra.
- Every reduction reports on the array's own unit — `min` / `max` exactly,
  `mean` / `median` / `percentile` / `stddev` rounded to the nearest tick,
  with `to_unit` first when you want a finer answer; `sum` / `variance` raise.
- The step system (`timesteps`, `floor` / `ceil` / `round`,
  `is_righttime`, `from_timesteps`) turns bucketing, calendar periods,
  fiscal years, weekly grids, grouping, and series matching into integer
  arithmetic — and raises loudly instead of being silently wrong.
- `ticks` is the named escape to the raw integer storage; bare numbers are
  otherwise rejected at the time surface.
