# CAKeyWindowIterator — windows bounded by a key (`windows(on:)`)

`value.windows(on: key, before: ..., after: ...)` returns a
**`CAKeyWindowIterator`**: a moving window per value whose extent is a width of
a **key** (a time, a duration or a number), not a count of cells. The window of
a value whose key is t holds the values whose key lies between `t - before` and
`t + after`.

[`windows(-2..0)`](CAWindowIterator.md) counts cells: on a series with a gap
it reaches back past the gap and mixes in old values. A window bounded by the
key holds fewer values after a gap, and none from before it.

```ruby
require "carray"

time = CArray.time(["2024-01-01 00:00", "2024-01-01 00:10", "2024-01-01 00:20",
                    "2024-01-01 01:30", "2024-01-01 01:40"], unit: :m)
temp = CA_FLOAT64([10, 12, 14, 20, 22])

temp.windows(on: time, before: "30 minutes").mean
#=> [10.0, 11.0, 12.0, 20.0, 21.0]     (01:30 holds itself only)

temp.windows(-2..0).mean               # three cells back, across the gap
#=> [10.0, 11.0, 12.0, 15.33..., 18.67...]
```

## The window

| keyword | meaning |
|---|---|
| `on:` | the key, one per value: a `CATime`, a `CATimedelta` or a real number array |
| `before:` | how far the window reaches back from the key (default 0) |
| `after:` | how far it reaches forward (default 0); give `before:`, `after:` or both |
| `exclude:` | the end left out: `:lower` (default), `:upper`, `:both` or `nil`, as `is_between` takes it |
| `by:` | an array (or an Array of them) that must match exactly: each window holds only the values with the same `by:` keys |
| `interval:` | the key's grid step, for `is_complete` |

The default `exclude: :lower` makes the window `(t - before, t + after]`. For a
value that stands for the period ending at its time (a 10-minute rainfall
labelled 01:00 is the rain from 00:50 to 01:00), `before: "1 hour"` then adds
up exactly the hour ending at t.

A width is the same kind of quantity as the key: a duration for a time key
(`"1 hour"`, `"90 minutes"`, or a `CATimedelta` value; a bare number is
refused, since its length would depend on the unit the key is stored in), and
a number for a numeric key. A month or a year has no fixed length, so it
measures only a key stored in months or years.

**Rows and masks.** The keys need not be sorted; the answers come in the
order of the values. A value whose key (or `by:` key) is masked, or a NaN, is
in no window and has no window: its answers are `UNDEF`. A masked value is in
the windows but, as in any reduction, takes no part in the reductions.

## What each window covered

Besides the reductions, the iterator says what each window actually held, so
that you can check the window is what you meant:

| method | answer, one per value |
|---|---|
| `first_addr` / `last_addr` | the first / last value of the window (its position in the array) |
| `first_key` / `last_key` | their keys |
| `elements` | the number of values in the window, masked values included |
| `bounds` | `[key - before, key + after]`, the range the window was asked to cover |
| `is_complete` | with `interval:`, whether the window holds exactly the keys of that grid |

```ruby
w = temp.windows(on: time, before: "30 minutes", interval: "10 minutes")
w.first_key       # where each window really starts
w.is_complete     #=> [false, false, true, false, false]
w.mean.mask_where(w.is_complete.not)    # UNDEF where a window is short
```

`is_complete` lays the grid of `interval:` from each value's own key and asks
that the window hold every point of it and nothing off it. A key repeated on
several values counts once, and a key off the grid (00:25 on a 10-minute grid)
makes the window incomplete, so the answer is not fooled by a count that
happens to match. `before:` and `after:` must be whole numbers of `interval:`.
The interval is given, not guessed from the data: a guess from data with gaps
would make the check unreliable exactly where it matters.

## Reductions

The iterator has the reductions of the [iterator family](IteratorFamily.md):
`sum` `accumulate` `prod` `mean` `min` `max` `minmax` `variance` `stddev`
`variancep` `stddevp` `median` `percentile` `quantile` `first` `last`
`nunique` `count` `count_not_masked` `count_masked` `all` `any` `wsum`
`wmean` `min_index` `max_index` `min_addr` `max_addr`, and `each` / `reduce`.
Each answers as the core reduction does over each window, `min_count:` and
`fill_value:` included. The windows overlap, so the per-value operations of
the partition members (`map`, the running scans, `lag`, `order`,
`strip_mask(method:)`) are not offered.

The value is one-dimensional, one value per key.

## In a CAFrame

```ruby
w = df.windows(on: "time", before: "1 hour", by: "station")
w.mean("temp")     # => CArray, one value per row
w.mean             # => frame of the windowed mean of every column that has one
w["temp"]          # => the CAKeyWindowIterator of one column
w.elements         # => the number of rows in each window
```

The window is worked out once and shared by the columns.
