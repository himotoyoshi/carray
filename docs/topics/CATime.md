# CATime and CATimedelta

`CATime` and `CATimedelta` are CArray subclasses that give an
ordinary `int64` array a time interpretation. The core idea is that
**time is an integer index on a step grid**: each stored value is the
k-th tick of a chosen resolution counted from the Unix epoch. The
resolution is `count × base` — a *tick* of `"10 minutes"`, `"3 hours"`,
`:D`, `:ns`, … — held in an attached {CATime::Resolution} descriptor
(see §3). So the same `int64` storage can hold a 10-minute grid, a daily
grid, or a nanosecond grid, and which one is a property of the array.

The time semantics are layered on top of plain `int64` storage:
numerical kernels see a regular `int64` array, while user-facing
operations see a time-aware array that survives slicing, reshaping,
masking, and the other view-creating methods. The storage layout is
identical to a plain `int64` array — §16 covers the internal
representation.

The epoch is fixed at **1970-01-01 UTC** and the calendar is proleptic
Gregorian; parsing is UTC by default and does not depend on the Ruby
`DateTime` class (it uses `Date._parse` plus an internal civil-date
kernel). Reference-time calendars (NetCDF CF conventions and the like)
are left to external gems. CATime is its own type — an integer index
on a tick grid, with its own vocabulary; the appendix gives a correspondence table
for migrating existing time code.

---

## 1. Quick start

```ruby
require 'carray'

dt = CArray.time_series("2024-06-15", count: 7, unit: :D)
# => 7-element CATime, unit: :D

dt.year       # => CArray [2024, 2024, 2024, 2024, 2024, 2024, 2024]
dt.month      # => CArray [6, 6, 6, 6, 6, 6, 6]
dt.day        # => CArray [15, 16, 17, 18, 19, 20, 21]
dt.weekday    # => CArray [6, 0, 1, 2, 3, 4, 5]   # Sun=0..Sat=6

dt[2]            # => CATime::Element 2024-06-17T00:00:00Z
dt[2].to_time    # => 2024-06-17 00:00:00 UTC

td = CArray.int64(7) {|i| i + 1}.timedelta(unit: :D)
dt + td       # => CATime, advanced by td
dt - dt       # => CATimedelta (all zero)

dt.min        # => CATime::Element 2024-06-15
dt.max        # => CATime::Element 2024-06-21
dt.mean       # => CATime::Element 2024-06-18T00:00:00.000000000Z  (midpoint)
dt.sum        # => raises TypeError (sum of datetimes is undefined)

dt.flip       # => CATime (reversed)
dt[2..5]      # => CATime
```

---

## 2. Construction

### 2.1 Allocating a new array

```ruby
# Allocate a fresh int64 entity with a time interpretation
dt = CATime.new(10, unit: :ns)     # 10 elements, all zero (= 1970-01-01)
dt = CATime.new(3, 4, unit: :D)    # multi-dimensional

# Wrap an existing int64 CArray (zero-copy)
raw = CArray.int64(5) {|i| i * 86400}
dt  = CATime.wrap(raw, unit: :s)

# Instance-method sugar for the above
dt  = raw.time(unit: :s)
```

An `int64` receiver of `#time` (and `#timedelta`) is wrapped zero-copy
(int64 is the storage type). A narrower integer type is widened to `int64`
first — a copy, but lossless. A `Float` or other non-integer type raises
`TypeError`; cast it explicitly (`arr.int64.time(unit: :s)`) if the
truncation is intended.

### 2.2 Generators

`unit:` is a {CATime::Resolution} spec — a Symbol (`:D`), a String
(`"10 minutes"`, whitespace required), or a `Resolution` object — and
sets the storage tick. A regular series lands directly on that grid.

```ruby
# A count of consecutive ticks from a start instant
CArray.time_series("2024-06-15", count: 7, unit: :D)
CArray.time_series("2024-06-15T12:00:00", count: 24, unit: :h)
CArray.time_series("2024-06-15", count: 144, unit: "10 minutes")  # N×base grid

# `unit:` is the grid the result is stored on, `step:` is the spacing. They
# differ when you want a coarse sampling kept on a fine grid — here, one
# instant per day carried on an hourly axis. Omitting `step:` means one tick.
CArray.time_series("2024-06-15", count: 7, unit: :h, step: "1 day")
CArray.time_series("2024-01-01", count: 5, unit: :M, step: "1 year")

# An inclusive range between two instants on the unit grid (off-grid
# endpoints floor to their bucket head). `step:` works here too — the phase
# is anchored at `start`, and `last` is a bound rather than a member, so the
# series stops at the last step at or before it.
CArray.time_range("2024-06-15T10:00", "2024-06-16T00:00", unit: "10 minutes")
CArray.time_range("2024-06-15", "2024-06-18", unit: :h, step: "1 day")

# Build from a value or a collection of values (Strings / Times / DateTimes /
# Unix-seconds Integers). A single literal gives a 1-element result; a Ruby
# Array or a CArray gives a same-shape result parsed per cell.
CArray.time("2024-06-15", unit: :D)                  # 1-element
CArray.time(%w[2024-01-15 2024-02-15 2024-03-15], unit: :D)   # Ruby Array
CArray.time(CA_OBJECT(%w[2024-01-15 2024-02-15]), unit: :D)   # CArray
CArray.time(%w[15/01/2024 20/06/2024], format: "%d/%m/%Y", unit: :D)
```

`CArray.time` is **strict by default**: an unparseable value raises.
Pass `on_error: :mask` to turn parse failures into UNDEF cells instead
(a masked / `nil` *input* cell is a missing value, not a parse failure, and
always becomes UNDEF regardless):

```ruby
CArray.time(CA_OBJECT(["2024-01-01", "oops"]), unit: :D)               # raises
CArray.time(CA_OBJECT(["2024-01-01", "oops"]), unit: :D, on_error: :mask)
# => [2024-01-01, UNDEF]
```

All generators interpret naive strings as **UTC** by default. An
explicit timezone suffix such as `"+09:00"` is respected.

Parsing uses Ruby's own date parser under the hood — `Date._parse` for
the flexible default and `Date._strptime` when you pass `format:` — so
any string `Date.parse` / `Time.strptime` accepts works here, and
`Time` / `DateTime` / Unix-seconds `Integer` values are taken directly.
Passing `format:` switches from the flexible heuristic to strict pattern
matching against that `strftime`-style template (e.g. `"%d/%m/%Y"`) —
what you want for an unambiguous day/month order or a non-ISO layout.

Two departures from `Date._parse`. A **year-month** (`"2019-09"`) and a
**bare year** (`"2019"`) are read as such — Ruby's parser reads neither as
a date — so the form a `:M` / `:Y` element prints comes back in, and a
missing finer field names the head of that period (`"2019-09"` on `:s` is
`2019-09-01T00:00:00Z`). And a **field out of range raises** rather than
rolling over into another date: `"2019-02-31"` is refused instead of
becoming 2019-03-03. Note that `"201909"` is a valid **YYMMDD** to Ruby
(2020-19-09), so it is refused too — name the layout with
`format: "%Y%m"` for a compact year-month.

### 2.3 Rebasing relative indices (`origin:`)

`CArray#time` takes an `origin:` for the common "index relative to a
base instant" pattern (e.g. a forecast lead-time axis): the array's
values are counted from `origin` and rebased to the epoch. With `origin`
omitted the values are already epoch-anchored (zero-copy).

```ruby
lead = CArray.int64(4) {|i| i}                 # lead-time steps 0..3
lead.time(unit: "3 hours", origin: "2022-01-01T09:00")
# => instants 2022-01-01 09:00, 12:00, 15:00, 18:00 (UTC)
```

`dt.timesteps(unit:, origin:)` (§11) is the inverse — it recovers the
relative index.

---

## 3. Units (resolution = count × base)

A resolution is a **base unit** times an integer **count**. The stored
`int64` value is the count of *ticks* (a tick = `count × base`) since the
fixed epoch **1970-01-01 UTC**. A bare base (`:D`) is count-1; `"10
minutes"` is count 10 of base `:m`. The base units:

| base | meaning   | example (value of 2024-01-01, count 1)      |
|------|-----------|---------------------------------------------|
| `:Y` | year      | 54 (= 1970 + 54)                            |
| `:M` | month     | 650                                         |
| `:W` | week      | 2818                                        |
| `:D` | day       | 19723                                       |
| `:h` | hour      | 473376                                      |
| `:m` | minute    | 28402560                                    |
| `:s` | second    | 1704067200                                  |
| `:ms`| millisec  | 1704067200000                               |
| `:us`| microsec  | 1704067200000000                            |
| `:ns`| nanosec   | 1704067200000000000                         |
| `:ps`, `:fs`, `:as` | pico / femto / atto sec | implemented, rarely used |

Bases split into two groups: **fixed-length** (`:W`/`:D`/`:h`/…/`:as`,
an exact number of seconds) and **calendar** (`:Y`/`:M`, month-ordinal
linear). A calendar base takes only integer counts; the two groups do
not inter-convert by a fixed ratio (a month has no exact second count).

### 3.1 The resolution descriptor

`dt.unit` returns a {CATime::Resolution} — `count`, `base`, and
`tick_ratio` (seconds/tick for a fixed base, months/tick for a calendar
base):

```ruby
dt = CArray.time_series("2024-01-01", count: 3, unit: "10 minutes")
dt.unit            # => #<CATime::Resolution 10 m>
dt.unit.base       # => :m
dt.unit.count      # => 10
dt.unit.tick_ratio # => (600/1)   # seconds per tick

CATime::Resolution.parse("3 hours")   # Symbol / String / Resolution
CATime::Resolution.new(3, :h)
```

### 3.2 Changing the unit — `to_unit`

`to_unit(unit)` returns the same instants stored on the `unit` grid — a new
`CATime` (a `CATimedelta` for a duration). Changing the resolution is a
**cast**, the same relation `CArray.time` has to its input, not an assertion
that the values happen to fit.

A **finer** target is exact: every instant lands on the new grid unchanged.

```ruby
dt = CArray.time_series("2024-06-15", count: 3, unit: :D)

dt.to_unit(:h).ticks        # => day index × 24
dt.to_unit(:h).to_time      # unchanged instants
dt.to_unit("10 minutes")    # 1 day = 144 whole ten-minute ticks
CArray.time(["2024-01-01"], unit: :Y).to_unit(:M)   # 1 year = 12 whole months
```

A **coarser** target floors each instant to the head of the tick it falls in —
**toward the past**, the direction `CArray.time` and `floor` already use, so a
pre-epoch instant rounds the same way a later one does:

```ruby
CArray.time(["2024-01-01 05:00"], unit: :h).to_unit(:D)   # => 2024-01-01
CArray.time(["1969-03-05 12:00"], unit: :h).to_unit(:D)   # => 1969-03-05
```

Reach for `ceil` / `round` (§11.3) first when a different boundary is wanted;
they move the values and keep the storage unit, so pair them with `to_unit`
when the storage should change too.

#### Crossing the calendar / fixed-length boundary

`:Y` / `:M` and `:D`-or-finer have no fixed ratio (§11.7), but a `:M` **time**
is a real instant — the month's first midnight — so the two grids are still
connected, through civil-date algebra rather than a ratio:

```ruby
m = CArray.time(["2024-03-01"], unit: :M)
m.to_unit(:D)                                       # => 2024-03-01
m.to_unit(:s)                                       # => 2024-03-01T00:00:00Z
CArray.time(["2024-03-05"], unit: :D).to_unit(:M)   # => 2024-03   (floors)
```

This is the route from a calendar series into day-level work: walk a quarterly
grid on `:M`, move the storage to `:D`, then add a day offset.

```ruby
q = CArray.time_range("2019-09-01", "2020-06-01", unit: :M, step: "3 months")
q.to_unit(:D) + CATimedelta.wrap(CA_INT64([14]), unit: :D)
# => 2019-09-15, 2019-12-15, 2020-03-15, 2020-06-15
```

`:Y` / `:M` → `:W` is the one refusal: a month head is not week-aligned, so
widening would move the instant.

A **duration** behaves differently. `CATimedelta#to_unit` truncates **toward
zero** (`+30 h` → `+1 D`, `-30 h` → `-1 D`), because a duration is a magnitude
rather than a point on an axis, and it refuses to cross the calendar boundary
at all — a one-month duration has no length in days.

Widening a wide span into a very fine unit raises `RangeError` rather than
wrapping `int64` (§11.11).

---

## 4. Storage

CATime's storage layout is identical to a plain `int64` array — the
time interpretation adds no bytes (see §16 for the internals).

```
CATime  (identity + unit; no value transformation)
   ↓ parent =
CArray int64  (actual storage, same bytes)
```

- `dt.data_type == CA_INT64`
- `dt.bytes == 8`
- `dt.ticks` returns the underlying `int64` tick indices — the
  named accessor for storage-space work. (`dt.parent` is the same array
  as a raw internal view; prefer the named method.)
- No value conversion happens on the way into a numerical kernel; kernels
  operate on the `int64` storage directly.

```ruby
dt = CArray.int64(5) {|i| i * 86400}.time(unit: :s)
dt.ticks   # => [0, 86400, 172800, 259200, 345600]   int64 ticks
dt.to_a          # => [CATime::Element, ...]          element-wise wrap
dt.ticks.class  # => CArray
```

---

## 5. Operators

Two companion types are in play. A **CATime** is an *instant* — a point
in time (a value on the tick grid). A **CATimedelta** is a *duration* — an
amount of elapsed time, an `int64` count of some unit with no epoch anchor
(§13 covers it in full). No prior time-library knowledge is assumed: the
algebra is the everyday one — subtracting two instants gives a duration, and
adding a duration to an instant gives another instant.

```ruby
a = CArray.time("2024-06-15", unit: :D)
b = CArray.time("2024-06-20", unit: :D)

gap = b - a          # => CATimedelta   (instant − instant = duration)
gap[0]               # => CATimedelta::Element 5D
gap[0].to_seconds    # => (432000/1)    exact Rational seconds

wk = CA_INT64([7]).timedelta(unit: :D)            # a 7-day duration
a + wk               # => CATime    2024-06-22  (instant + duration = instant)
```

### 5.1 Algebra of datetimes and timedeltas

| operation       | result              | meaning                                    |
|-----------------|---------------------|--------------------------------------------|
| `dt + td`       | `CATime`      | instant plus duration                      |
| `dt - td`       | `CATime`      | instant minus duration                     |
| `dt - dt`       | `CATimedelta`       | difference between two instants            |
| `dt + dt`       | raises `TypeError`  | sum of instants is undefined               |
| `dt + Numeric`  | raises `TypeError`  | unitless arithmetic on instants is rejected|
| `td + dt`       | `CATime`      | commutative                                |
| `td + td`       | `CATimedelta`       |                                            |
| `td - td`       | `CATimedelta`       |                                            |
| `td * Integer`  | `CATimedelta`       | scaling                                    |
| `td / Integer`  | `CATimedelta`       | scaling                                    |
| `td / td`       | `CArray` (Float)    | ratio; a plain Float array                 |

### 5.2 Cross-unit arithmetic

Arithmetic reconciles operands that carry different units (the same lossless
machinery as comparison and search, §5.3 / §10.3) — no manual conversion:

- **`dt ± td`** (time ± duration): the time is the anchor, so the
  result keeps `dt`'s unit and the duration is converted into it. A coarser
  duration widens exactly; a **finer** one is **truncated** to `dt`'s grid (a
  `:D` time + a 5 h duration is + 0 days; + 30 h is + 1 day).
- **`dt - dt2`** and **`td ± td2`**: a duration at the **finer** of the two
  units (both widen exactly).
- **cross-group** (a fixed unit with a calendar `:Y`/`:M` one): a calendar
  duration has no fixed ratio to seconds, so `dt(:s) + td(:M)` and
  `td(:M) + td(:s)` **raise** — that step is calendar arithmetic (§11).
- **overflow**: widening a wide range into a fine unit (e.g. a millennium-
  spanning difference resolved to `:ns`) can exceed `int64`; it **raises**
  rather than silently wrapping.

```ruby
CArray.time("2024-01-01", unit: :h) + CA_INT64([1]).timedelta(unit: :D)
# => a :h time, + 24 h  (the day widens into hours)

CArray.time("2024-01-01", unit: :D) + CA_INT64([30]).timedelta(unit: :h)
# => a :D time, + 1 day  (30 h truncated to the day grid)
```

### 5.3 Comparisons

```ruby
dt1 <  dt2      # => boolean CArray  (element-wise, like any CArray operator)
dt1.eq(dt2)     # => boolean CArray  (element-wise equality)
dt1 <=> dt2     # => CArray of -1 / 0 / 1
```

Element-wise equality is `#eq` / `#ne`, not `==` / `!=`: as on any
CArray, `dt1 == dt2` is whole-array structural equality returning a
single `true` / `false` (and `dt1.equal?(dt2)` is identity). Only the
ordering operators (`< <= > >=`), `<=>`, and `#eq` / `#ne` are the
element-wise, boolean-CArray-returning comparisons.

Comparison results are plain `bool` or `int` CArrays — they no longer
carry time semantics.

The two operands may carry **different units**. The left-hand side (the
reference) reconciles the right-hand operand into its own unit through
`to_comparable` — the same lossless-cast rule as cross-unit search (§10.3) —
so a value that does not land exactly on the left operand's grid raises rather
than being silently truncated. `<=>` is composed from `<` and `>`, so it
inherits the same behaviour. Because the left operand drives the conversion, a
right-hand `Time` / `DateTime` / `Element` is accepted too (`dt < Time.utc(…)`),
lifted into the left operand's unit.

### 5.4 Cross-unit comparison

```ruby
dt_s  = CArray.int64(2) {|i| [10, 20][i] }.time(unit: :s)
dt_ms = CArray.int64(2) {|i| [10000, 20000][i] }.time(unit: :ms)  # 10s, 20s

dt_ms < dt_s      # OK: :s lifted to :ms (coarser → finer is always exact)
dt_s  < dt_ms     # OK: 10000/20000 ms are whole seconds

dt_bad = CArray.int64(2) {|i| [10500, 20000][i] }.time(unit: :ms)  # 10.5s
dt_s < dt_bad
# => ArgumentError: cannot align time unit :ms to :s without loss
```

Comparison, search, and arithmetic all **reconcile** cross-unit operands
(arithmetic converts a duration into the time's unit — §5.2 / §10.3).

---

## 6. Element (`CATime::Element`)

Fetching a single element returns a dedicated `Element` object rather
than a bare integer:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
s  = dt[2]

s.class       # => CATime::Element
s.value       # => 19725             (raw int64 tick index)
s.unit        # => #<CATime::Resolution 1 D>   (.base => :D, .count => 1)
s.to_time     # => Ruby Time, UTC     (midnight of the day, for a :D scalar)
s.to_date     # => Ruby Date
s.to_datetime # => Ruby DateTime, UTC
s.to_s        # => "2024-06-17"       (unit-aware: a :D prints a date)
s.inspect     # => "#<CATime::Element 2024-06-17 (19725D)>"
s <=> dt[3]  # => -1
s < dt[3]    # => true              (Comparable mixed in)
```

The surface of `CATime::Element`:

- `value`, `unit` (`attr_reader`)
- `to_time` / `to_datetime` — UTC `Time` / `DateTime` (the granule's first
  instant; a `:M` scalar decodes to midnight of the 1st via `Date#next_month`,
  exactly — no 30.5-day drift)
- `to_date` — UTC `Date` (sub-day units floor to the day)
- `to_s` — **unit-aware**: `:Y` → `"2024"`, `:M` → `"2024-03"`, `:D` →
  `"2024-03-01"`, `:h` and finer → ISO 8601 with time. This keeps
  `(value, unit)` recoverable (a `:M` and a `:D` scalar print differently).
- `inspect` — `to_s` plus the raw `(value, unit)`
- `<=>` / `==` (via `Comparable`) compare by **instant**, reconciling a
  different unit — so a `:s` and a `:ms` scalar at the same moment are `==`, and
  a `Time` / `DateTime` operand is accepted. `eql?` / `hash`, by contrast, are
  unit-strict (mirroring `1 == 1.0` but `!1.eql?(1.0)`), so those two scalars
  key a `Hash` separately.
- arithmetic that carries the unit semantic `Time` drops: `s - s2` →
  `CATimedelta::Element` (elapsed duration, in the finer unit — or the fixed
  unit across the calendar boundary), and `s ± td` → `CATime::Element`
  (advance by a duration, keeping the time's unit — a finer duration is
  truncated to it). A cross-group step (`:s` time + `:M` duration) is
  calendar arithmetic — use `to_date` + `Date#next_month` / `#next_year`.

Calendar breakdown is delegated to Ruby `Date` / `Time` rather than
reimplemented — a single scalar pays one object's cost, so the vectorized
civil-date path (used by the array accessors, §7) is not needed here.

`CATimedelta::Element` is analogous, with `value`, `unit`, `to_s`, `<=>`, `==`,
arithmetic (`td + td` / `td - td` promote to the finer unit, `td * Integer`,
`td / Integer`, `td / td` → `Rational` ratio; a cross-group operand raises), and
`to_seconds` — which returns an **exact** `Rational` for a fixed-length unit but
**raises** for `:Y` / `:M` (a month / year has no exact second count); use
`to_seconds_approx` for a nominal 30.5-day / 365.25-day estimate.

---

## 7. Field accessors

```ruby
dt = CArray.time_series("2024-06-15", count: 7, unit: :D)
dt.year      # => CArray [2024, 2024, ...]
dt.month     # => CArray [6, 6, ...]
dt.day       # => CArray [15, 16, 17, 18, 19, 20, 21]
dt.hour      # precision follows the array's unit
dt.minute
dt.second
dt.weekday   # => CArray [6, 0, 1, 2, 3, 4, 5]   (Sun=0..Sat=6)
dt.yday      # => CArray [167, 168, ...]         (1..366)
dt.jd        # Julian Day Number
dt.ajd       # Astronomical Julian Day (Float)
dt.is_leap   # boolean CArray
```

Each accessor returns a plain `Integer`, `Float`, or `bool` CArray —
the result no longer carries time semantics.

The fields (`year` … `is_leap`) are computed by **vectorized civil-date
algebra** directly on the `int64` storage — no per-cell `Time` object — so they
are fast on large arrays and exact for every unit, including `:M` and `:Y`.
`jd` / `ajd` / `to_time` / `to_datetime` / `strftime`
still build Ruby `Date` / `Time` objects, since their result *is* such an
object.

### 7.1 Truncation to the unit

A time is stored as an integer tick, so building one at a given unit
**floors the instant to that unit** — anything finer than the tick is
discarded at construction, not at read time. A `:D` array keeps only the
day; the time of day in the source string is gone:

```ruby
d = CArray.time("2024-06-15T12:30:45", unit: :D)
d[0].to_time     # => 2024-06-15 00:00:00 UTC   (12:30:45 truncated to the day)

s = CArray.time("2024-06-15T12:30:45", unit: :s)
s[0].to_time     # => 2024-06-15 12:30:45 UTC   (:s keeps the full instant)
```

Because the finer part was never stored, a field finer than the unit reads
back as `0`: `d.hour` is `0` on the `:D` array above, `.second` is `0` on a
`:m` array, and so on. The cut-off is the storage *tick* (`count × base`),
so a coarser tick drops more — a `"10 minutes"` array keeps the minute at
10-minute resolution but zeroes the seconds.

### 7.2 Whole-array Time / Date / DateTime conversion

`to_time` / `to_date` / `to_datetime` convert every element to a Ruby
`Time` / `Date` / `DateTime` (UTC), returned as an object CArray — the
array-level counterparts to the `Element` conversions (§6). `to_date`
floors a sub-day unit to its day.

```ruby
dt.to_time      # => CArray(:object) of Ruby Time     (UTC)
dt.to_date      # => CArray(:object) of Ruby Date     (day-floored)
dt.to_datetime  # => CArray(:object) of Ruby DateTime (UTC)
```

---

## 8. Reductions

**A reduction reports on the array's own unit.** Whatever the answer is —
a centroid, a median, a spread — it comes back on the grid the array is
stored on, rounded to the nearest tick. Precision is something the caller
declares, before the reduction, with `to_unit`:

```ruby
t = CArray.time(%w[2024-06-15 2024-06-16], unit: :D)

t.mean                # => 2024-06-16       the day grid; 19889.5 rounds to 19890
t.to_unit(:h).mean    # => 2024-06-15 12:00 the hour grid, declared first
```

That is the same rule `linear_fetch` follows (§10.3), and it means the
range an array can hold is the range its reductions can answer in: a
daily series covering 1600–2400 takes a mean, which a rule that refined
the output to nanoseconds could not (`:ns` spans about 1678–2262).

Rounding is to the **nearest** tick, never toward zero — a truncating
round would pull pre-epoch answers later and post-epoch answers earlier.

Reductions dispatch by meaning. The **order-structure** ones
(`min` / `max` / `minmax`, and the index-returning `min_index` / `max_index`,
§10.1) descend to the `int64` storage and re-lift the extremum: they pick an
actual element, so no rounding happens at all. The **centroid / spread /
order-statistic** ones can land between ticks and round.

| reduction                | result                        | rationale                                             |
|--------------------------|-------------------------------|-------------------------------------------------------|
| `t.min` / `t.max`        | `CATime::Element`             | earliest / latest instant (exact)                     |
| `t.minmax`               | `[Element, Element]`          | both, as a `[min, max]` pair                          |
| `t.mean`                 | `CATime::Element`             | centroid instant, on `t`'s unit                       |
| `t.median`               | `CATime::Element`             | median instant (an odd full reduction is exact)       |
| `t.percentile(*p)`       | `Element`, or an `Array`      | order statistics, on `t`'s unit                       |
| `t.quantile`             | `Array` of 5 `Element`        | `percentile(0, 25, 50, 75, 100)`                      |
| `t.stddev` / `t.stddevp` | `CATimedelta::Element`        | spread of the instants, as a duration                 |
| `t.sum`                  | raises `TypeError`            | a sum of instants is undefined (use `mean`)           |
| `t.variance` / `variancep` | raises `TypeError`          | squared-time units, which no type represents          |

With `axis:` the same members return a `CATime` (or `CATimedelta` for a
spread) instead of an `Element`, and the multi-`p` forms return an `Array`
of those — the shapes plain `CArray` uses.

### Spreads and the price of the rule

A spread is not a lattice point, so it pays more for the rounding than a
centroid does. On a coarse unit the answer can be several percent off, and
this is where declaring the grid first earns its keep:

```ruby
t = CArray.time(%w[2024-01-01 2024-01-02 2024-01-05 2024-01-09], unit: :D)

t.ticks.stddev          # => 3.5939...   the exact spread, in days
t.stddev                # => 4 D         the day grid — about 11% high
t.to_unit(:h).stddev    # => 86 h        the hour grid — 86.25 h, 0.3% off
```

The rule has no exceptions: a spread does not quietly refine itself, because
then the rule you have to remember stops being one rule. `to_unit` is the
one place precision gets decided, for every member.

### Calendar arrays reduce in month ordinals

A `:M` or `:Y` array stores month (or year) ordinals, so that is the space
it reduces in — no drop into day space happens behind your back:

```ruby
m = CArray.time(%w[2024-01-01 2024-03-01], unit: :M)   # ticks 648, 650

m.mean                                 # => 2024-02      (648 + 650) / 2 = 649
m.to_unit(:D).mean                     # => 2024-01-31   the day-space answer
```

The two answers differ because months have different lengths; neither is
more correct than the other, so the array's own unit decides. Declaring the
day grid with `to_unit` (§3.2) is how a caller asks for the other one.

### CATimedelta

Durations reduce by the same rule, on the array's own unit, and they also
have a well-defined `sum`:

```ruby
td.sum        # => CATimedelta::Element
td.mean       # => CATimedelta::Element
td.median     # => CATimedelta::Element
td.stddev     # => CATimedelta::Element
td.percentile(25, 75)  # => [Element, Element]
```

`variance` / `variancep` are the one pair in the family that come back as a
plain `Float`: their value is in *squared* ticks of `td.unit`, and no type
represents squared time. (`CATime` refuses them outright instead — a squared
instant is not a quantity at all, while a squared duration is.) Take
`stddev` when you want a typed answer.

---

## 9. View algebra

The CATime identity is preserved across every view-creating method
(see §16):

```ruby
dt = CArray.time_series("2024-06-15", count: 12, unit: :D)

# All of these return CATime, carrying the unit through
dt[2..5]                # slice
dt[mask_bool]           # boolean select
dt.reshape(3, 4)
dt.transpose
dt.flip                 # or dt.reverse
dt.roll(2)
dt.sort                 # chronological sort
dt.copy                 # entity copy
dt.strip_mask(0)
dt.flatten
dt.window(0..3)
dt.shift(1)
```

The time type survives arbitrary chains:

```ruby
dt.reshape(3, 4).transpose.flip[0..1].unit.base
# => :D
```

---

## 10. Ordering, search, and interpolation

A time axis is a natural coordinate, so ordering, binary search, and
linear interpolation all work on it directly — on the `int64` storage under
the hood. This is the opt-in ordering gate described in
[`FaceOrderingSearch.md`](../authoring/FaceOrderingSearch.md); the short version is that
`CATime` declares itself **ORDERABLE** and defines a
`to_comparable(operand)` method — the **reference axis** reconciles the
operand into its own unit — and everything below follows without any
time-specific search code.

### 10.1 Ordering and rank

The value-returning `sort` / `partition` (in §9) keep the time type. The
**index-returning** family returns plain index arrays:

```ruby
dt = CArray.time_series("2024-06-17", count: 5, unit: :D)[CA_INT64([2,0,4,1,3])]
# a shuffled time axis

dt.sort_index          # => [1, 3, 0, 4, 2]   (indices that sort it)
dt.sort_addr           # => [1, 3, 0, 4, 2]   (flat addresses; same here for 1-D)
dt.partition_index(2)  # => partial-sort indices with the 2nd element in place
dt.order               # => [2, 0, 4, 1, 3]   (each cell's rank position, 0 = earliest)
dt.order(descending: true)  # => [2, 4, 0, 3, 1]   (rank from latest)
dt.min_index           # => index of the earliest instant
dt.max_index           # => index of the latest instant

dt.rank_index          # => [2, 0, 4, 1, 3]   (the lower-level rank primitive
                       #                        that `order` is sugar over)
```

`min_index` / `max_index` (and their `min_addr` / `max_addr` flat-address
forms) are order-structure reductions: like `sort_index`, they descend to
the `int64` storage and return a plain index, so they compare by the true
chronological order rather than the raw byte layout.

### 10.2 Search

`bsearch` / `search` / `bsearch_addr` take a **time query** and return
positions in the axis:

```ruby
axis = CArray.time_series("2024-06-15", count: 6, unit: :D)
q    = CArray.time_series("2024-06-17", count: 2, unit: :D)

axis.bsearch(q)   # => [2, 3]
axis.search(q)    # => [2, 3]
```

The query may be another time array **or a single instant the axis knows
how to convert** — a `CATime::Element` (e.g. `axis[i]`), a Ruby `Time`,
or a Ruby `DateTime` (both absolute, UTC, Unix epoch). It may **not** be a bare
number, which would touch the hidden storage — see §16.2.

```ruby
require "time"
axis.bsearch(Time.utc(2024, 6, 17))   # => 2     (Time lifted into the axis unit)
axis.bsearch(axis[3])                 # => 3     (a Element operand)
```

(A timedelta axis is narrower: it accepts a timedelta array or
`CATimedelta::Element`, but **not** `Time` / `DateTime` — those are absolute
instants, not durations. Coverage is per-type; see §13.)

### 10.3 Cross-unit queries (`to_comparable`)

`to_comparable` is the single reconciliation step behind the whole search
family (§10.2) and the comparison operators (§5.3): before any `bsearch` /
`search` / `<` compares a query against the axis, the axis converts the query
into its own unit through it — which is why it is documented here, at the
base of §10.

The operand may carry a **different unit** from the axis. The reference axis
brings it into its own unit, losslessly:

```ruby
axis_h = CArray.time_series("2024-06-15", count: 72, unit: :h)  # hourly
q_D    = CArray.time_series("2024-06-16", count: 2, unit: :D)    # daily

axis_h.bsearch(q_D)          # => [24, 48]   (:D lifted to :h, x24)
axis_h.to_comparable(q_D)    # => the operand as a :h CATime
```

Note the receiver: `to_comparable` is called on the **axis (reference)** with
the operand as the argument — the axis owns the conversion, so a foreign
operand like a `Time` needs no method of its own.

The cast rules (operand → axis unit):

- **coarser → finer** (`:D` → `:h`, `:s` → `:ns`, `:Y` → `:M`): always exact
  (integer multiply).
- **finer → coarser** (`:ns` → `:s`): allowed only when every value lands
  exactly on the coarser grid; a sub-unit remainder **raises** (it is not
  silently truncated).
- **calendar ↔ fixed-length** (`:Y`/`:M` ↔ `:D`/`:h`/`:s`/…): unlike a
  *duration*, a *time* has a well-defined instant, so a cross-group cast IS
  possible via civil-date algebra (`convert_instant!`) — the same asymmetry a
  duration lacks (a `:M` time casts to `:s`, a `:M` duration cannot):
  - `:Y`/`:M` **widen** exactly to `:D` and finer (a month decodes to its first
    midnight).
  - a fixed operand **coarsens** to `:Y`/`:M` only when it lands exactly on the
    calendar boundary (midnight of the 1st), else raises.
  - `:W` is the one exception both ways: month / year starts are not aligned to
    a week grid, so `:Y`/`:M` ↔ `:W` raises.

A `:ns` query whose value is half a second past an `:s` grid point cannot be
aligned to `:s` without dropping precision, so it raises rather than silently
truncating. (This is the search / comparison gate; `dt ± td` arithmetic converts the
duration into the time's unit — §5.2.)

### 10.4 Coordinate lookup — `locate_addr` and `locate_nearest_addr`

These compose ordering + search into the common "match observation times to a
reference axis" operation:

```ruby
# reference time axis (may be unsorted)
axis  = CArray.time_series("2024-06-15", count: 24, unit: :h)
# observation times to place on the axis (here: the 5th, 12th, 20th hour)
obs   = axis[CA_INT64([5, 12, 20])]

obs.locate_addr(axis)          # => [5, 12, 20]   (exact matches)
obs.locate_nearest_addr(axis)  # => nearest index for off-grid times
```

`locate_nearest_addr` uses `linear_section` internally, so an off-grid
observation snaps to the nearest reference index (`:round` / `:floor` /
`:ceil`). Cross-unit obs are reconciled the same way as search.

### 10.5 Interpolation — `linear_section` and `linear_fetch`

The interpolation pair works on a time axis, and each half returns the kind of
thing its direction implies:

```ruby
t = CArray.time_series("2024-06-15T00:00", count: 7, unit: "2 hours")

t.linear_section(CArray.time(["2024-06-15T04:00"], unit: :h))
# => 2.0          a fractional *position* -- a plain float, like any axis

t.linear_fetch(CA_FLOAT64([0.0, 2.5]))
# => CATime (unit: 2 h)   a *value* off the axis -- so the time type comes back
```

The query side needs nothing special: `linear_section` accepts a `CATime`, an
`Element`, a Ruby `Time` or `DateTime` and reconciles the unit through
`to_comparable` (§10.3), exactly as search does. Reconciliation is lossless,
though, so a query at a *finer* resolution than the axis has to land on the
axis's grid — `05:00` against a `2 h` axis raises rather than sit between two
ticks. Widen the axis first, and both halves then work on the fine grid:

```ruby
tf = t.to_unit(:h)
tf.linear_section(CArray.time(["2024-06-15T05:00"], unit: :h))   # => 2.5
```

`linear_fetch` returns times, so it returns a `CATime` **on the same unit as
the axis**. The array's unit is its grid, so an interpolated instant landing
between two ticks is rounded to the nearest tick. Widen the grid first when
the interpolation needs sub-tick precision — `to_unit` (§3.2) is exact in that
direction, so nothing moves:

```ruby
t.linear_fetch(CA_FLOAT64([0.0, 0.25]))
# => 00:00, 00:00           the 2-hour grid cannot hold the 30-minute offset

t.to_unit(:ms).linear_fetch(CA_FLOAT64([0.0, 0.25]))
# => 00:00:00.000, 00:30:00.000
```

This is the same rule the reductions follow (§8): the array's grid is the
output grid, and `to_unit` is where a caller declares that it wants a finer
one. Declaring the grid you want is the one thing to plan for.

An out-of-range address comes back **UNDEF** rather than the NaN a plain float
axis returns — `int64` tick storage has no NaN to spare for a sentinel — and a
masked address stays UNDEF. Both are ordinary missing cells (`is_masked`,
`strip_mask`, …).

Because both halves read the same storage grid, the round trip holds, calendar
units included — there is no separate "interpolate in days" space to pick:

```ruby
t.linear_fetch(t.linear_section(query))   # == query
```

`CATimedelta#linear_fetch` is symmetric (a duration on its own unit), and
`CAFrame#fill(col, :linear)` interpolates a time column into a time column on
that column's unit. The upshot is that a regrid can treat every axis alike —
`axis.linear_fetch(idx)` returns something of the same kind, on the same grid,
whether the axis is a float coordinate or a time. See
[`LinearInterpolation.md`](LinearInterpolation.md) for the pair in general.

---

## 11. The step system (bucketing, matching, grouping)

A time axis is, underneath, an integer count since an epoch. The **step
system** leans into that: it re-expresses each instant as the integer *index of
the fixed-width bucket* it falls in, counted from a chosen origin. Once time is
an integer index, **bucketing, matching, and grouping all become plain integer
arithmetic** — fast, exact, and free of per-cell `Time` objects.

Everything here is vectorized `int64` on the storage and mask-propagating. This
targets the **standard proleptic-Gregorian calendar, UTC** only — non-standard
calendars (noleap / 360-day) are out of core.

### 11.1 Step specs

A step is "N of a unit". Write it as a **String** (the human surface) or a bare
**Symbol** (the count-1 shorthand over the unit letters):

```ruby
"3 hours"    # => 3 × :h
"1 month"    # => 1 × :M
"10 days"    # => 10 × :D
:h           # shorthand for "1 hour"
:M           # shorthand for "1 month"
```

Singular and plural are both accepted (`"1 day"` / `"3 days"`); the compact
`"3h"` (no space) is rejected, and unknown words raise. Internally a spec
becomes a frozen `CATime::Step` value object — value-equal and hashable,
so it can serve as a hash / group key.

Note `:m` is **minute** and `:M` is **month** (the unit letters are
case-sensitive). To avoid confusion, spell months out: `"1 month"`.

### 11.2 `timesteps` — the core primitive

`timesteps(unit:, origin: nil)` returns an `int64` CArray: the index `k` of the
bucket each element falls in, counted from `origin` (default: the epoch).
With no `unit` the bucket is the storage resolution itself, so the result is a
copy of the raw tick indices since the epoch (the values behind
`ticks`, §16.2). Everything else in this section is a thin layer on
top of it.

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
past.timesteps(unit: "3 hours", origin: t0)   # => [-1]   (2h before t0 → bucket −1)
```

`origin` is the **phase** of the bucket grid (not the storage epoch, which stays
1970-01-01). It accepts a `Time`, an ISO string, or a `CATime::Element`.
An origin that does not land exactly on the grid the buckets are counted on
**raises** rather than silently shifting the phase (§11.11), and a bare
`Integer` origin is rejected (it is epoch-dependent and ambiguous).

### 11.3 `floor` / `ceil` / `round` — snap to a bucket head

These return a `CATime` (same unit) at the bucket boundary:

```ruby
dt.floor(unit: "3 hours", origin: t0).strftime("%H:%M")
# => ["00:00", "00:00", "00:00", "03:00", "03:00", "03:00"]

dt.ceil(unit: "3 hours", origin: t0).strftime("%H:%M")
# => ["00:00", "03:00", "03:00", "03:00", "06:00", "06:00"]   (on-boundary keeps itself)

dt.round(unit: "3 hours", origin: t0).strftime("%H:%M")
# => ["00:00", "00:00", "03:00", "03:00", "03:00", "06:00"]   (nearest; ties → future)
```

`floor` is the period-bucket operation (toward the past). `round` picks the
nearest head with ties toward the future, and is exact even for odd step widths
(no half-tick loss). These take an argument, so they do **not** collide with the
argument-less numeric `CArray#floor` / `#round`.

### 11.4 `is_righttime` — the on-grid guard

A `timesteps` match means "same bucket", **not** "same instant". `is_righttime`
flags the cells that sit exactly on a bucket head — use it as an assertion
before matching two series, to catch a series that is silently off-grid:

```ruby
dt.is_righttime(unit: "3 hours", origin: t0)   # => [1, 0, 0, 1, 0, 0]   (1 = lands on a bucket head)
```

### 11.5 `from_timesteps` — the inverse

`CATime.from_timesteps(k, unit:, origin: nil)` maps a bucket index
back to its head time. A scalar `k` returns a `Element`; a CArray `k`
returns a `CATime`. Use it to relabel a `group_by(timesteps)` result,
generate a regular grid, or round-trip a `timesteps`:

```ruby
k = dt.timesteps(unit: "3 hours", origin: t0)
CATime.from_timesteps(k, unit: "3 hours", origin: t0)  # == dt.floor(unit: "3 hours", origin: t0)

CATime.from_timesteps(2, unit: "3 hours", origin: t0).to_s
# => "2024-03-10T06:00:00Z"
```

### 11.6 Calendar steps — month and year

Months and years are variable-length, but the step system handles them on
day-or-finer storage through **civil-date integer algebra** (vectorized, no
per-cell `Time`, correct for pre-epoch dates):

```ruby
dt = CArray.time(
  CA_OBJECT(["2024-01-15", "2024-02-03", "2024-02-28", "2023-12-31"]), unit: :D)

dt.floor(unit: "1 month").strftime("%Y-%m-%d")
# => ["2024-01-01", "2024-02-01", "2024-02-01", "2023-12-01"]

dt.floor(unit: "1 year").strftime("%Y-%m-%d")
# => ["2024-01-01", "2024-01-01", "2024-01-01", "2023-01-01"]

dt.timesteps(unit: "1 month")   # months since 1970-01
# => [648, 649, 649, 647]
```

A calendar grid is addressed by **month ordinal**, so its bucket heads are
month heads and nothing else. The origin therefore has to be **the 1st at
00:00**; anywhere else names a bucket that does not exist and raises, the same
way a lossy origin does on a fixed-length grid (§11.11). Which month it is
remains free, and that makes **fiscal years / quarters** a one-liner: point the
origin at the fiscal start month.

```ruby
fy = CArray.time(CA_OBJECT(["2024-03-01", "2024-08-01", "2025-01-01"]), unit: :D)

# fiscal year starting each July
fy.timesteps(unit: "1 year", origin: "2024-07-01")
# => [-1, 0, 0]   (Mar 2024 is in FY2023, Aug 2024 and Jan 2025 in FY2024)

fy.floor(unit: "1 year", origin: "2024-07-01").strftime("%Y-%m-%d")
# => ["2023-07-01", "2024-07-01", "2024-07-01"]
```

### 11.7 Which steps are allowed

A timestep is an integer, so a `(step, storage-unit)` pair works whenever one
tick is a **whole multiple of the other** — in either direction:

- **Step coarser than the tick** (`"3 hours"` on `:h` storage): the ordinary
  case, several ticks per bucket.
- **Step finer than the tick** (`"1 minute"` on `:h` storage): every element
  already sits on the finer grid, so its timestep is just the tick index
  widened — an hour is 60 whole minutes, so `timesteps(unit: "1 minute")` is
  the hour index times 60. `floor` / `ceil` / `round` are the identity here and
  `is_righttime` is all-true, which is the honest answer: nothing is off-grid.
- **Neither a whole multiple of the other** (`"7 minutes"` on `:h` storage, or
  `:h` on `"90 minutes"` storage): there is no integer timestep, so this raises
  `ArgumentError`.

| step unit ↓ \ storage `su` → | `:Y` / `:M`             | `:W`                | `:D` or finer            |
|------------------------------|-------------------------|---------------------|--------------------------|
| `:Y` / `:M`                  | integer (`"1 year"` on `:M` = ×12; `"1 month"` on `:Y` = ×12 the other way) | **raises** (month heads aren't on a week grid) | civil path (§11.6) |
| `:W`                         | raises (no fixed ratio) | integer            | integer (`:W`→`:D` = ×7) |
| `:D` or finer                | raises (no fixed ratio) | integer (a week is 7 whole days) | integer, when either ratio is whole |

The two `raises` cells are the calendar / fixed-length boundary: a month is not
a fixed number of days, so no ratio exists in either direction (§5.2). Only the
calendar-step-on-day-or-finer corner escapes it, via the civil path.

### 11.8 Weekly buckets (ISO Monday by default)

`1970-01-01` is a Thursday, so a naïve week grid from the epoch would be
Thursday-anchored. Instead, a **week step defaults its origin to the ISO Monday
`1970-01-05`**, so `floor("1 week")` yields Monday-anchored weeks with no extra
configuration. Anchor on a different weekday by passing an explicit `origin`.

```ruby
w = CArray.time(CA_OBJECT(["2024-03-13", "2024-03-16", "2024-03-18"]), unit: :D)
w.floor(unit: "1 week").strftime("%a %Y-%m-%d")
# => ["Mon 2024-03-11", "Mon 2024-03-11", "Mon 2024-03-18"]
```

### 11.9 Time-bucket categoricals → `group_by`

Compose `floor` with `categorize` to turn period heads into an ordered
categorical, ready for grouped aggregation. No new method is needed — the
`floor` result is a `CATime`, and `categorize` puts its distinct
period-heads (as ordered `Element` labels) onto a `CACategorical`:

```ruby
temps = CA_DOUBLE([1, 2, 3, 4])
cat   = dt.floor(unit: "1 month").categorize(sort_labels: true)

cat.labels.map { |s| s.to_time.strftime("%Y-%m") }   # => ["2023-12", "2024-01", "2024-02"]
temps.group_by_category(cat).mean               # => [4.0, 1.0, 2.5]   (per-month mean)
```

The categorical's **codes** are `0..k-1` in label order — this is *not* the same
as `timesteps` (the absolute bucket number). Use `categorize` for group labels,
`timesteps` for matching / addressing (§11.10).

### 11.10 Matching two series

Because `timesteps` is an **absolute** integer keyed to `(step, origin)` (and,
for a fixed origin, keyed to nothing but the epoch), two series projected onto
the *same* `(step, origin)` share one integer index space. Matching, joining,
and dense positional addressing then reduce to integer ops — no hash join, no
per-cell comparison. A meteorological obs-vs-forecast alignment is the canonical
example:

```ruby
obs_vt  = obs_frame.index                 # observation valid-times (hourly)
fcst_vt = fcst_init + fcst_ft             # forecast valid-times = init + lead time

oidx = obs_vt.timesteps(unit: "1 hour")        # default origin (epoch): absolute hour index
fidx = fcst_vt.timesteps(unit: "1 hour")       # both series share the same index space

raise "obs off grid" unless obs_vt.is_righttime(unit: "1 hour").all       # §11.4 on-grid guard
raise "obs not unique" unless oidx.to_a.uniq.size == oidx.size  # one obs per bucket

# dense addressing — the grid domain is the SCATTER (obs) range; the gather
# (forecast) is clipped into it and out-of-range cells stay UNDEF.  O(N), no hash.
k0, k1  = oidx.min, oidx.max
grid    = CArray.float64(k1 - k0 + 1) { UNDEF }
grid[oidx - k0] = obs_values

inr     = fidx.ge(k0) & fidx.le(k1)
matched = CArray.float64(fidx.size) { UNDEF }
matched[inr] = grid[(fidx - k0)[inr]]     # obs aligned to each forecast valid-time
```

Two things make dense addressing correct and fast, and both deserve a check:

- **It fits a *regular* grid.** `grid` has `oidx.max - oidx.min + 1` cells, so the
  cost is the observation *span*, not its count. A single stray timestamp
  (a decade-old outlier) blows the allocation up — exactly the failure the
  calendar path avoids in §11.6. Use it for regular series (a fixed cadence);
  for irregular point clouds fall back to `oidx.is_in(fidx)` /
  `fidx.locate_addr(oidx)` (§10.4), which work directly on the integer indices.
- **The scatter must be unique.** Two observations in one bucket collide in
  `grid[...] =` (last write wins). The uniqueness check above catches it — pair
  it with the `is_righttime` guard.

`origin:` is optional here: with the default (epoch) both `timesteps` results are
already absolute and comparable. Pass an explicit `origin` only to shift the
bucket grid's phase (e.g. fiscal quarters, §11.6).

### 11.11 Safety: overflow and lossy origin both raise

The step system converts "silently wrong" into a loud error:

- **Overflow.** The fine units (`:us` … `:as`) have a small `int64` span
  (`:as` covers only ±9 seconds around the epoch). If a step, origin, or data
  span would overflow the `int64` arithmetic, the op raises `RangeError` instead
  of silently wrapping. Coarse units (`:s` / `:h` / `:D` / `:M` …) cannot
  overflow for any realistic time, so they pay no check.
- **Lossy origin.** `origin` is the head of bucket 0, so it has to be a bucket
  head. One that does not land on the grid the buckets are counted on (an `:h`
  axis bucketed by the hour, with a `00:30` origin) raises, rather than
  truncating the grid phase. A bare `Integer` origin is rejected outright.
  When the bucket is finer than the storage tick the grid is the *bucket*
  grid, so a `00:30` origin is fine against a `"1 minute"` bucket — it is
  exactly 30 buckets. On a calendar grid the rule reads as “the 1st at
  00:00” (§11.6), and a `:Y` tick additionally starts in January.

```ruby
CA_INT64([0]).time(unit: :h).timesteps(unit: "1 hour", origin: "2024-01-01T00:30:00Z")
# => ArgumentError (origin not representable in :h without loss)

CA_INT64([0]).time(unit: :h).timesteps(unit: "1 minute", origin: "1970-01-01T00:30:00Z")
# => [-30]   (the minute grid does carry that phase)

CA_INT64([0]).time(unit: :as).timesteps(unit: "1 hour")
# => RangeError (1 hour in attoseconds overflows int64)
```

## 12. `strftime` and string output

```ruby
dt = CArray.time_series("2024-06-15", count: 3, unit: :D)

dt.strftime("%Y-%m-%d")
# => ["2024-06-15", "2024-06-16", "2024-06-17"]

dt.strftime("%a %b %d, %Y")
# => ["Sat Jun 15, 2024", "Sun Jun 16, 2024", "Mon Jun 17, 2024"]

dt[0].to_s
# => "2024-06-15T00:00:00Z"   # ISO 8601
```

`strftime` returns a {CAString} (a mutable string array over object
storage) — the result is a plain string array, no longer a time. The
input mask propagates.

---

## 13. CATimedelta

CATimedelta is structurally identical to CATime (an `int64`
storage plus a unit tail), but with duration semantics rather than
absolute time.

```ruby
# construction
td = CATimedelta.new(5, unit: :s)
td = CATimedelta.wrap(int64_raw, unit: :ms)
td = int64_raw.timedelta(unit: :h)

# arithmetic
td + td      # => CATimedelta
td * 2       # => CATimedelta
td / 2       # => CATimedelta
td / td2     # => CArray of Float (ratio; plain Float array)
td.sum       # => CATimedelta::Element
td.mean      # => CATimedelta::Element

# scalar
td[2]              # => CATimedelta::Element
td[2].value        # => raw int64
td[2].unit         # => #<CATime::Resolution 1 s>   (.base => :s)
td[2].to_seconds   # => Rational (exact); raises for :Y / :M (use to_seconds_approx)
td[2].to_s         # => "60s", ...   (with unit suffix)
```

Ordering and search work the same as for CATime (§10) — the reference
duration reconciles a cross-unit operand via `to_comparable`. Coverage is
narrower, though: a timedelta axis accepts another timedelta array or a
`CATimedelta::Element`, but **not** a `Time` or `DateTime`. Those name absolute
instants, not durations, so they raise (`TypeError`): a duration has no
meaningful conversion from an instant.

---

## 14. Masks

The mask travels with the parent `int64` entity, so masking works
exactly as on a plain CArray:

```ruby
dt = CArray.time_series("2024-06-15", count: 5, unit: :D)
dt[2] = UNDEF                 # mask element 2
dt.to_a                       # => [s0, s1, UNDEF, s3, s4]
dt[2]                         # => UNDEF
dt.is_masked.to_a             # => [false, false, true, false, false]
dt.min                        # ignores masked elements
dt.strip_mask(0)              # => CATime with masked cells filled with 0
```

Gap-fill (`unmask` / `strip_mask` with `method:`) works too, and returns a
`CATime` on the same unit:

```ruby
dt.strip_mask(method: :forward)   # carry the last valid instant forward
dt.strip_mask(method: :linear)    # interpolate the gap from its neighbours
dt.unmask(method: :linear)        # same, in place
```

`:forward` / `:backward` copy an instant, so they are always exact. `:linear`
interpolates, so it lands on the array's grid the same way `linear_fetch` does
(§10.5) — widen the unit first with `to_unit` if the gap needs sub-tick
precision. Leading / trailing cells with nothing to interpolate between stay
UNDEF.

---

## 15. Limitations

### 15.1 Current limitations

- `variance` raises: the variance of instants has squared-time units,
  which no type can represent — it is genuinely ill-defined, like `sum`.

### 15.2 Fixed by design

- The epoch is **1970-01-01 UTC**, fixed.
  Arbitrary reference times — as used by NetCDF CF conventions — are
  delegated to external gems. (Integer bucketing / matching against a grid
  is provided in core by the step system, §11; only non-standard calendars
  stay external.)
- Storage is **`int64`**, fixed. The parent's `data_type` must match.
  The *surface* is `CA_FIXLEN` for both classes (the NonNumeric gate), so
  the numeric kernels do not dispatch on them: `sqrt(dur)` and a variance
  in squared ticks raise, while the operations that are meaningful on
  instants and durations are defined by the classes themselves. A plain
  number comes from `#ticks` (or `#to_unit(u).ticks` to pick the grid).

---

## 16. Internal representation (advanced)

These are the mechanisms behind the scalar surface and the raw storage —
most code never needs them.

### 16.1 The `storage_to_scalar` / `scalar_to_storage` convention

Reading a cell decodes the storage integer into a `Element`; storing a
cell encodes a surface instant back into the storage unit. Both happen
through a matched pair of methods on the Face class (see
[`CAFace.md`](CAFace.md) §6.1–6.2):

```ruby
class CATime
  def storage_to_scalar(raw)      # read:  storage int -> Element
    Element.new(raw, unit)
  end
  def scalar_to_storage(surface)  # write: instant -> storage int (this unit)
    to_comparable(surface).parent[0]
  end
end
```

`storage_to_scalar` covers every scalar-returning path — `dt[i, j, k]`,
`dt.fetch_index`, `dt.fetch_addr`, `dt.to_a`, and so on — without
overriding `[]` in Ruby.

`scalar_to_storage` covers the store paths — `dt[i] = instant`,
`dt[mask] = instant`, `dt[i..j] = instant`, `dt.fill(instant)` — so a
`Element` / `Time` / `DateTime` is converted into this Face's unit
before it lands in storage (a `Time` at 02:00 stored into a `:h` axis
becomes the hour count, not raw seconds). The two are inverse, so a
fetched cell stores back unchanged:

```ruby
dt[0] = dt[2]
dt[0] == dt[2]     # => true
```

A bare `Integer` is *not* converted — it is written to storage raw, the
deliberate storage-space escape (§16.2). A value the unit algebra
cannot convert (a cross-group instant) raises rather than mis-storing.

---

### 16.2 The storage escape — `ticks`

A **bare number is rejected** — you should not search the hidden int64 epoch
by a raw value (the reference has no way to read it as an instant, so
`to_comparable` raises):

```ruby
axis.bsearch(19538)     # => TypeError (a bare int would touch the storage directly)
axis.ticks.bsearch(19538)   # => OK: explicit storage-space search
```

`ticks` is the named accessor for the raw `int64` tick indices —
use it (not the internal `.parent`) when you really do want to operate on
the storage. A `Time` / `DateTime` / `Element` is *not* a bare number —
it carries an absolute instant the axis converts (§10.2), so it is accepted.

---

---

## 17. See also

- [`CAFace.md`](CAFace.md) — Face mechanism (structure, conventions,
  implementation paths).
- [`FaceOrderingSearch.md`](../authoring/FaceOrderingSearch.md) — the ORDERABLE /
  COMPARABLE flags and `to_comparable` behind §10 (developer-facing).
- [`LinearInterpolation.md`](LinearInterpolation.md) — `linear_section` /
  `linear_fetch` / `locate_*` on plain arrays.
- [`MemoryView.md`](../interop/MemoryView.md) — MemoryView interop.

---

## Appendix — Migration map (numpy / pandas)

CATime is **not** derived from numpy or pandas — its surface,
vocabulary, and especially its construction API are its own (a
resolution is `count × base`, a value is an integer tick index, and the
generators, the timestep family, and the scalar type have no numpy
counterpart). This table is only a convenience for readers who already
know `numpy.datetime64` / `pandas.Timestamp`: it points a familiar
operation to the (often quite different) CArray way of doing it.

| numpy / pandas                                | CArray                                                       |
|-----------------------------------------------|--------------------------------------------------------------|
| `np.datetime64('2024-01-01')`                 | `CArray.time("2024-01-01", unit: :D)`                  |
| `np.datetime64('2024-01-01', 's')`            | `CArray.time("2024-01-01", unit: :s)`                  |
| `pd.Timestamp('2024-01-01')`                  | same as above                                                |
| `np.timedelta64(60, 's')`                     | `CA_INT64([60]).timedelta(unit: :s)`                 |
| `pd.date_range('2024-01-01', periods=10, freq='D')` | `CArray.time_series("2024-01-01", count: 10, unit: :D)` |
| `pd.to_datetime(strings)`                     | `CArray.time(strings)`                             |
| `pd.to_datetime(s, format='%d/%m/%Y')`        | `CArray.time(s, format: "%d/%m/%Y")`               |
| `arr.dt.year`                                 | `dt.year`                                                    |
| `arr.dt.month`                                | `dt.month`                                                   |
| `arr.dt.day`                                  | `dt.day`                                                     |
| `arr.dt.dayofweek`                            | `dt.weekday`  (Sun=0..Sat=6)                                 |
| `arr.dt.strftime('%Y-%m-%d')`                 | `dt.strftime("%Y-%m-%d")`                                    |
| `arr.dt.is_leap_year`                         | `dt.is_leap`                                                 |
| `arr.min()`                                   | `dt.min`  (returns `CATime::Element`)                   |
| `arr.mean()`                                  | `dt.mean`                                                    |
| `arr1 - arr2`  (time − time)          | `dt1 - dt2`  (returns `CATimedelta`)                         |
| `arr + np.timedelta64(1, 'D')`                | `dt + td`  (array: units must match)                         |
| `np.datetime64('2024-03','M') == np.datetime64('2024-03-01','s')` | `dtM[0] == dtS[0]`  (scalar `==` by instant, cross-unit — §6) |
| `dt64_s - dt64_s`  (scalar)                   | `dt[i] - dt[j]`  → `CATimedelta::Element` (finer unit; §6)     |
| `dt64_s + td64_s`  (scalar)                   | `dt[i] + td[j]`  (same group, promotes to finer; §6)         |
| `x.astype('datetime64[s]')`  (from `[M]`)     | rides `to_comparable` / search — `:M` widens to `:s` (§10.3) |
| `arr.tolist()`                                | `dt.to_a`  (array of `Element`)                               |
| `arr[i].timestamp()`                          | `dt[i].to_time.to_i`                                         |
| `str(np.datetime64('2024-03','M'))` → `'2024-03'` | `dt[i].to_s`  (unit-aware: a `:M` prints `"2024-03"` — §6) |
| `s.dt.floor('3h')`                            | `dt.floor(unit: "3 hours")`  (§11.3)                               |
| `s.dt.ceil('D')` / `s.dt.round('h')`          | `dt.ceil(unit: :D)` / `dt.round(unit: :h)`                               |
| `s.dt.to_period('M')` (period bucket)         | `dt.floor(unit: "1 month")` → `CATime` (§11.6)               |
| `s.groupby(s.dt.to_period('M'))`              | `vals.group_by_category(dt.floor(unit: "1 month").categorize(sort_labels: true))` (§11.9) |
| `df.resample('D')` (regular bucketing)        | `dt.timesteps(unit: "1 day", origin:)` + `group_by` (§11.10); true reindexing = `time_series` + `align` |

Features that have no direct numpy / pandas equivalent:

- `dt.copy` and `dt.to_ca` produce an entity copy that still carries
  the Face — the CATime identity is preserved across
  materialisation (see §9).
- Masks are integrated uniformly across all derived view classes, so
  `dt[mask_array]` and `dt[2] = UNDEF` interoperate naturally.
- The view algebra composes freely: `dt.reshape(3, 4).transpose.flip`
  retains both the unit and the class identity.

---
