# Finding the method for a task

The chapters are arranged in the order an analysis usually goes. This index is arranged by what you want to do. Each entry gives the method and the chapter that explains it.

## Getting data in

| I want to… | use | chapter |
|---|---|---|
| make a frame from arrays I have | `CAFrame.new` | 2 |
| give columns particular types as the frame is built | `CAFrame.new(..., types:)` | 2 |
| see an array I have as a table, without copying | `array.to_frame` | 2, 15 |
| read parsed JSON (an Array of objects) | `CAFrame.from_records` | 2 |
| read a CSV file | `CAFrame.from_csv` | 3 |
| read CSV text I already have in a String | `CAFrame.from_csv(StringIO.new(text))` | 3 |
| have the column types worked out | `from_csv` (by default) | 3 |
| read every column as text | `from_csv(types: :string)` | 3 |
| see the types that would be chosen, before converting | `infer_types` | 3 |
| treat `-1`, `NA` or another code as missing | `from_csv(missing: [...])` | 3 |
| be told about cells that cannot be read | `from_csv(on_error: :warn)` | 3 |
| read a file with title or unit lines | `from_csv(header:, data:, attrs:)` | 3 |
| read only some columns of a wide file | `from_csv(columns:)` | 3 |
| read a file that is not UTF-8 | `from_csv(encoding: "Windows-1252:UTF-8")` | 3 |

## Looking

| I want to… | use | chapter |
|---|---|---|
| glance at a frame | `p df` | 4 |
| print every row | `puts df`, `to_table(rows: nil)` | 4 |
| check every column's type, missing count and range | `describe` | 4 |
| pick the columns of a kind (numbers, text, times) | `select(:numeric)`, `drop(:string)` | 5 |
| one summary of every column, as one row | `df.mean`, `df.max("x", "y")` | 4 |
| running totals or ranks down the rows | `df.cumsum("x")`, `df.order("x")` | 15 |
| the same computation on several columns | `transform("a".."c") { \|col\| ... }` | 7 |
| know the size, the column names, the types | `nrow`, `column_names`, `data_types` | 4 |
| see the distinct values of a column and their counts | `value_counts` | 4 |
| find the rows with missing values | `df[df["x"].is_masked]` | 4, 8 |

## Columns and rows

| I want to… | use | chapter |
|---|---|---|
| take a column as an array | `df["revenue"]` | 5 |
| take several columns | `a, b = df["a", "b"]` | 5 |
| keep a frame of some columns, or reorder them | `select` | 5 |
| leave out some columns | `drop` | 5, 7 |
| look at one row | `df[i]` | 5 |
| look up a row by its label | `at` | 9 |
| take the first or last rows | `head`, `tail` | 5 |
| take rows by position | `df[2..5]`, `df[CA_INT64([...])]` | 5 |

## Choosing and ordering rows

| I want to… | use | chapter |
|---|---|---|
| keep the rows where a condition holds | `filter { \|f\| ... }` | 6 |
| keep rows whose value is one of several | `is_in([...])` | 6 |
| keep rows in a range of values or dates | `is_between(lo, hi)` | 6 |
| keep weekend days | `f["date"].weekday.is_in([0, 6])` | 6 |
| keep rows whose condition could not be decided | `filter(keep_masked: true)` | 6 |
| check rows against rules | `verify` | 6 |
| sort by columns | `sort_by_key` | 6 |
| sort by a computed value | `sort_by { \|f\| ... }` | 6 |
| take the top few rows | `nlargest(n, "x")`, `nsmallest` | 6 |
| take the top few rows of each group | `group_by(...).nlargest(n, "x")` | 10, 18 |
| remove repeated rows | `df[df.is_duplicate.not]` | 6 |
| keep groups that pass a test | `group_by(...).filter { \|g\| ... }` | 10 |

## Preparing columns

| I want to… | use | chapter |
|---|---|---|
| add a computed column | `df["x"] = ...` or `append` | 7 |
| choose between two values by a condition | `cond.then_else(a, b)` | 7 |
| rename columns | `rename` | 7 |
| convert text to numbers, or change a type | `cast` | 7 |
| round values to a number of decimal places | `round(2)` | 1 |
| make every column one type | `promote` | 7 |
| store repeated text compactly | `cast("x" => :categorical)` | 7 |
| tidy text: trim, change case, replace | `strip!`, `upcase!`, `gsub!` | 7 |
| take a number out of a text | `extract` | 7 |
| split a text column into several | `split_column` | 7 |
| make 0/1 columns from a category column | `contrast_columns` | 7 |
| correct values in some rows | `df["x"][rows] = value` | 7 |
| delete rows from the frame | `df[rows] = nil` | 7 |
| replace a span of rows | `df[span] = other` | 7 |

## Missing values

| I want to… | use | chapter |
|---|---|---|
| count missing cells | `count_masked`, `describe` | 8 |
| make a code such as `-1` missing | `mask_eq` | 8 |
| make cells matching a condition missing | `df["x"][cond] = UNDEF` | 8 |
| mark whole rows as missing | `df[rows] = UNDEF` | 8 |
| fill gaps with the previous or next value | `fill(name, :ffill)`, `:bfill` | 8 |
| fill gaps within each group only | `group_by(...).fill(...)` | 8, 10 |
| interpolate gaps along dates | `set_index` then `fill(name, :linear)` | 9, 11 |
| interpolate gaps within each group | `group_by(...).fill(name, :linear)` | 10, 11 |
| keep the original and add a filled copy | `strip_mask` | 8 |
| a filled copy of the whole frame | `df.strip_mask(value)`, `df.strip_mask(method: ...)` | 8 |
| refuse a summary with too few values | `min_count:` | 8, 10 |
| drop rows with missing values | `drop_masked`, `drop_masked("x", "y")` | 8 |

## Labels

| I want to… | use | chapter |
|---|---|---|
| make a column the row labels | `set_index` | 9 |
| turn the labels back into a column | `reset_index` | 9 |
| choose rows by a range of labels | `filter { \|f\| f.index.is_between(...) }` | 9 |

## Summarising

| I want to… | use | chapter |
|---|---|---|
| a total or average per group | `group_by(...).sum`, `.mean` | 10 |
| different summaries for different columns, with names | `aggregate` | 10 |
| a result per group that uses several columns | `aggregate { \|g\| ... }` | 10 |
| any Ruby computation on each group's rows | `table { \|g\| ... }` | 10 |
| a percentile or median per group | `grouped.percentile(90, "x")` | 10 |
| a group's figure on every row | `keep_rows: true` | 10 |
| each value's share of its group | `x / grouped.sum("x", keep_rows: true)` | 10 |
| the previous value within each group | `lag` | 10, 11 |
| a rank or running total within each group | `order`, `cumsum` | 10 |
| totals per hour, day, week or month | `resample` | 11 |
| totals per period for each shop (or other group) | `resample(..., by:)` | 11 |
| a row for every period, including empty ones | `resample(..., fill: true)` | 11 |
| a moving average over a span of time | `windows(on:, before:)` | 11 |
| one column per group, rows per date | `pivot` | 13 |

## Time

| I want to… | use | chapter |
|---|---|---|
| turn date text into times | `parse_to_time` | 11 |
| find which layout a date column is written in | `infer_time_format` | 11 |
| turn counts of seconds or days into times | `to_time` | 11 |
| the hour, weekday, month of each time | `hour`, `weekday`, `month` | 11 |
| round times down to the hour or week | `floor(unit:)` | 11 |
| put a series on a complete list of dates | `align` with `CArray.time_range` | 11 |
| match each row with the latest entry of another table | `join_asof` | 11 |

## Combining

| I want to… | use | chapter |
|---|---|---|
| add columns from another table by a key | `join` | 12 |
| join on a key named differently in the other table | `join(other, on: { "shop" => "code" })` | 12 |
| keep only rows found in both tables | `join(how: :inner)` | 12 |
| keep rows whose key is, or is not, in another table | `join(how: :semi)`, `:anti` | 12 |
| make sure every member of a list has a row | `align` | 12 |
| put tables one after another | `CAFrame.concatenate`, `CAFrame.meld` | 12 |
| put tables with the same rows side by side | `paste` | 12 |

## Reshaping

| I want to… | use | chapter |
|---|---|---|
| spread a column's values into columns | `pivot` | 13 |
| combine repeated rows while spreading | `pivot(aggregate:)` | 13 |
| get the spread table as one array | `pivot_grid` | 13 |
| turn columns back into rows | `melt` | 13 |
| make several columns one column of several values | `stack_columns` | 14 |
| make each group's rows one row | `stack_rows` | 14 |
| lay tables of the same shape on top of each other | `CAFrame.stack` | 14 |

## Arrays

| I want to… | use | chapter |
|---|---|---|
| the frame as one matrix | `to_ca` | 15 |
| a matrix as a frame | `to_frame` | 15 |
| a histogram of a column | `histogram1d(edges:)` | 15 |

## Sharing and safety

| I want to… | use | chapter |
|---|---|---|
| work on part of a frame without changing the original | `copy` | 16 |
| know whether a result shares cells with its source | the tables in chapter 16 | 16 |
| hand a frame to code that should only read it | `protect` | 16 |

## Writing out

| I want to… | use | chapter |
|---|---|---|
| a CSV file | `to_csv(path)` | 17 |
| CSV with another separator or a missing-value code | `to_csv(sep:, missing:)` | 17 |
| JSON | `JSON.generate(df.to_records)` | 17 |
| rows as Ruby Arrays | `df.to_a` | 17 |
| a text table for a report | `to_table(rows: nil)` | 17 |
