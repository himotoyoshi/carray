# Long and wide tables

The same figures can be laid out two ways. `sales` is **long**: one row per shop and day, with the shop named in a column. A **wide** table has one row per day and one column per shop. The long layout is easier to filter, group and add to; the wide one is easier to read and to compare across shops. `pivot` turns long into wide, and `melt` turns wide into long.

```ruby
require "carray"
sales = CAFrame.read_csv("sales.csv", missing: ["-1", "n/a"])
```

## Long to wide — `pivot`

`pivot` takes three columns: the one whose values become the rows (`index:`), the one whose values become the columns (`columns:`), and the one whose values fill the cells (`values:`):

```ruby
wide = sales.pivot(index: "date", columns: "shop", values: "revenue")
p wide
# #<CAFrame nrow=8 columns=[central:float64, north:float64, south:float64] index="date">
# date        central    north    south
# ----------  -------  -------  -------
# 2024-03-04   3038.0  2121.39  1391.47
# 2024-03-05  2717.54   2235.1  1632.61
# 2024-03-06  3078.67  2285.32   1479.8
# 2024-03-07  3060.93  2681.38  1561.34
# 2024-03-08        _   3323.2  2192.97
# 2024-03-09   3939.6   3974.7  2724.34
# 2024-03-10  3270.26  4112.58  2785.04
# 2024-03-11  3008.01  2261.26   1525.1
```

- The rows and the columns are each sorted: dates in time order, shop names alphabetically.
- The `index:` column becomes the index of the result, so `wide.at("2024-03-08")` finds a day.
- A cell no row fills is missing, and so is a cell whose value was missing — the central shop's 8 March revenue here.
- The result is a new table; changing it does not change `sales`.

Each column is now one shop's series, so comparing shops is column arithmetic:

```ruby
(wide["north"] / wide["south"]).to_a.map { |v| v == UNDEF ? v : v.round(2) }
# => [1.52, 1.37, 1.54, 1.72, 1.52, 1.46, 1.48, 1.48]
```

### Several value columns

With an Array of value columns, each is spread out, and the new columns are named `"<value>_<column>"`:

```ruby
both = sales.pivot(index: "date", columns: "shop", values: ["visitors", "revenue"])
both.column_names
# => ["visitors_central", "visitors_north", "visitors_south", "revenue_central", "revenue_north", "revenue_south"]
```

### Several rows for one cell — `aggregate:`

`pivot` places values; it does not combine them. If two rows have the same `index:` and `columns:` values, it raises an error rather than choose one. Give `aggregate:` to combine them with a summary. Revenue per week and shop, from daily rows:

```ruby
weekly = sales.select("date", "shop", "revenue").copy
weekly["week"] = weekly["date"].floor(unit: :W)
p weekly.pivot(index: "week", columns: "shop", values: "revenue", aggregate: :sum)
# #<CAFrame nrow=2 columns=[central:float64, north:float64, south:float64] index="week">
# week        central     north     south
# ----------  -------  --------  --------
# 2024-03-04  19105.0  20733.67  13767.57
# 2024-03-11  3008.01   2261.26    1525.1
```

Any summary name works: `:mean`, `:max`, `:count`, `:median`, and so on. A cell that no row fills stays missing even with `aggregate: :count`, so "counted zero" and "no such combination" remain different.

## The same cells as one array — `pivot_grid`

When the next step is arithmetic on the whole table rather than on named columns, `pivot_grid` gives the cells as a single two-dimensional array, with the row and column labels:

```ruby
grid, days, shops = sales.pivot_grid(index: "date", columns: "shop", values: "visitors")
grid.shape             # => [8, 3]
shops.to_a             # => ["central", "north", "south"]
grid.mean(axis: 0).to_a.map { |v| v.round(1) }   # => [334.4, 233.8, 129.9]
grid.max(axis: 1).to_a # => [310, 295, 305, 322, 388, 402, 355, 298]
```

`axis: 0` summarises down the days (one value per shop); `axis: 1` across the shops (one value per day). Missing values stay missing in the grid, and summaries leave them out.

## Wide to long — `melt`

`melt` does the reverse of `pivot`. It stacks a set of columns into one, with a column saying which column each value came from:

```ruby
long = wide.reset_index.melt(id: "date", var_name: "shop", value_name: "revenue")
p long.head(4)
# #<CAFrame nrow=4 columns=[date:CATime[D], shop:CAString, revenue:float64]>
# date        shop     revenue
# ----------  -------  -------
# 2024-03-04  central   3038.0
# 2024-03-05  central  2717.54
# 2024-03-06  central  3078.67
# 2024-03-07  central  3060.93
```

- `id:` names the columns to repeat on every row — here the date.
- Every other column is stacked, unless `value_columns:` names the ones to stack.
- `var_name:` and `value_name:` name the two new columns (`"variable"` and `"value"` by default).
- If the table has an index, it is kept as an id column.

The result's value column is a view of the stacked columns: no data is copied, and writing to the long table writes to the wide one. Use `copy` for a table of its own. Number columns of different types — counts and amounts, say — meet at their common type and stay a view, when that type holds every value exactly; a value it would change, or text or time columns stacked with numbers, raise, so `cast` those to one type first.

`melt` then `pivot` on the same columns gives back the wide table's values.
