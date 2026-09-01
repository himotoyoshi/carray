# frozen_string_literal: true
#
# gallery/histogram_ascii.rb
#
# Bin samples into a histogram and render the result as an ASCII bell.
# The same bin edges are used across three distributions so the shapes
# are directly comparable.

require "carray"

# ------------------------------------------------------------
# One vertical ASCII histogram
# ------------------------------------------------------------
# `histogram1d(edges:)` places each sample in the half-open bin whose
# interval contains it and returns a small object whose `.counts` is a
# 1-D CArray of length nbins.
#
# The vertical bell is drawn without a per-cell character loop:
#   * `heights` — bar height in rows for each bin, as one CArray
#     expression;
#   * `levels`  — a column vector of row indices from top down;
#   * broadcasting `heights >= levels` gives a (rows, bins) boolean
#     grid marking which cells belong to the bar;
#   * the `then_else` + `chars.join(axis: 1)` idiom prints
#     the whole grid as ASCII, exactly as image_threshold's `show`.
def bell(sample, edges, rows: 12)
  counts  = sample.histogram1d(edges: edges).counts
  heights = ( counts * rows / counts.max.to_f ).round.int32
  levels  = CArray.int32(rows, 1).seq(rows, -1)
  grid    = heights[:_, nil] >= levels
  grid.then_else(CA_OBJECT("#"), CA_OBJECT(" ")).join(axis: 1).join("\n")
end

# ------------------------------------------------------------
# Three distributions sampled with the same n and edges
# ------------------------------------------------------------
n     = 5000
edges = CArray.float64(41).span(-4.0..4.0)   #  40 bins over [-4, 4]
srand(1)

samples = {
  "normal"  => CArray.float64(n).randomn,
  "uniform" => CArray.float64(n).random(-4.0, 4.0),
  "bimodal" => CArray.float64(n).randomn +
               CArray.int32(n).random(0..1) * 4 - 2,
}

samples.each do |name, sample|
  puts format("-- %-8s (mean=%+.3f, stddev=%.3f) --",
              name, sample.mean, sample.stddev)
  puts bell(sample, edges)
  puts "-" * (edges.elements - 1)
  puts
end
