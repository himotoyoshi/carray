# frozen_string_literal: true
#
# cookbook/daily_activity.rb
#
# A year of daily counts, aggregated two ways: by month and by day of
# week. CATime supplies the calendar (`.month`, `.weekday`), a lookup
# table turns integers into readable labels, and CACategorical plus
# `group_by_category` do the per-group reduction in one call.

require "carray"

# ------------------------------------------------------------
# A daily time index
# ------------------------------------------------------------
# 365 daily ticks starting on 1 January. `.month`, `.weekday`, and
# friends are integer arrays of the same shape.
n  = 365
dt = CArray.time_series("2024-01-01", count: n, unit: :D)

# ------------------------------------------------------------
# A synthetic activity series
# ------------------------------------------------------------
# One value per day, assembled as three CArray expressions:
#   * a full-year swing (sine),
#   * a weekday bump (weekdays > weekends),
#   * Gaussian noise.
# clipped to [0, 200] and rounded to integers to look like a counter.
seasonal    = ( CArray.float64(n).seq * Math::PI * 2 / n ).sin * 40 + 60
weekday     = ( dt.weekday.ge(1) & dt.weekday.le(5) )   #  Mon..Fri
weekday_bump = weekday.int32 * 20
srand(1)
noise  = CArray.float64(n).randomn * 8
values = ( seasonal + weekday_bump + noise ).clip(0, 200).round.int32

# ------------------------------------------------------------
# Group by month
# ------------------------------------------------------------
# `.month` returns 1..12 as an integer array. A lookup table turns
# those integers into short month labels, and `.categorize(labels: ...)`
# fixes the vocabulary so aggregates come out in calendar order.
month_names = CA_OBJECT(%w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec])
month_cat   = ( dt.month - 1 ).lookup(month_names).categorize(labels: month_names.to_a)

by_month = values.group_by_category(month_cat).mean
puts "mean daily activity by month:"
scale = 50.0 / by_month.max
month_cat.labels.each_with_index do |name, i|
  bar = "#" * ( by_month[i] * scale ).round
  puts format("  %s | %-50s %6.1f", name, bar, by_month[i])
end

# ------------------------------------------------------------
# Group by day of week
# ------------------------------------------------------------
# `.weekday` is 0..6 with Sunday = 0. Same lookup + categorize pattern.
weekday_names = CA_OBJECT(%w[Sun Mon Tue Wed Thu Fri Sat])
weekday_cat   = dt.weekday.lookup(weekday_names).categorize(labels: weekday_names.to_a)

by_weekday = values.group_by_category(weekday_cat).mean
puts
puts "mean daily activity by day of week:"
scale = 50.0 / by_weekday.max
weekday_cat.labels.each_with_index do |name, i|
  bar = "#" * ( by_weekday[i] * scale ).round
  puts format("  %s | %-50s %6.1f", name, bar, by_weekday[i])
end
