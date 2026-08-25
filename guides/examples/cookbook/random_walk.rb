# frozen_string_literal: true
#
# cookbook/random_walk.rb
#
# 500 independent one-dimensional random walkers, run for 400 steps in
# one CArray expression. The whole point of doing it this way is that
# the second axis of the trajectories array becomes an ordinary
# per-row cumsum, and the per-step statistics fall out as reductions
# along axis 0.

require "carray"

n_walkers = 500
n_steps   = 400
srand(1)

# ------------------------------------------------------------
# Steps and trajectories
# ------------------------------------------------------------
# Each cell of `steps` is +1 or -1 — an unbiased Bernoulli step.
# `cumsum(axis: 1)` walks the second axis, so row i of `positions` is
# the trajectory of walker i. One expression, no time loop.
steps     = CArray.int32(n_walkers, n_steps).random(0..1) * 2 - 1
positions = steps.cumsum(axis: 1)

# ------------------------------------------------------------
# Per-step statistics, along axis 0
# ------------------------------------------------------------
# `mean(axis: 0)` and `stddev(axis: 0)` collapse the walker axis and
# leave one value per time step. Both are 1-D arrays of length n_steps.
mean_t   = positions.mean(axis: 0)
stddev_t = positions.stddev(axis: 0)

# ------------------------------------------------------------
# Draw a ±2σ envelope over time as ASCII
# ------------------------------------------------------------
# Downsample the two envelope curves to the render width using a gather
# with an integer index array, scale to rows, then use the same
# broadcast + then_else + slab-reduce idiom as wave_1d.
def envelope_plot(top, bot, width: 70, height: 21)
  n_steps = top.elements
  mid     = height / 2
  scale   = mid / top.max

  # `seq * (n_steps - 1) / (width - 1)` is the endpoints-hit integer
  # idiom: `width` sample positions from 0 to n_steps-1, both ends
  # exact. (Integer arithmetic — `.span` is float-only for exactly the
  # reason that "N evenly-spaced integers" is ambiguous.)
  idx = CArray.int32(width).seq * (n_steps - 1) / (width - 1)
  top_row = ( mid - top[idx] * scale ).round.clip(0, height - 1).int32
  bot_row = ( mid - bot[idx] * scale ).round.clip(0, height - 1).int32

  rows = CArray.int32(height, 1).seq
  grid = rows.ge(top_row[:_, nil]) & rows.le(bot_row[:_, nil])
  grid.then_else(CA_OBJECT("#"), CA_OBJECT(" ")).join(axis: 1).join("\n")
end

puts "±2σ envelope over #{n_steps} steps, #{n_walkers} walkers:"
puts envelope_plot(mean_t + 2 * stddev_t, mean_t - 2 * stddev_t)

# ------------------------------------------------------------
# Endpoint distribution as an ASCII bell
# ------------------------------------------------------------
# The final column of `positions` is the endpoint of every walker. By
# the central limit theorem its distribution should be close to
# Gaussian with standard deviation √n_steps. `histogram1d` + the
# `heights >= levels` broadcast render it directly, reusing the
# recipe from `histogram_ascii`.
finals = positions[nil, -1]

def bell(sample, edges, rows: 10)
  counts  = sample.histogram1d(edges: edges).counts
  heights = ( counts * rows / counts.max.to_f ).round.int32
  levels  = CArray.int32(rows, 1).seq(rows, -1)
  grid    = heights[:_, nil] >= levels
  grid.then_else(CA_OBJECT("#"), CA_OBJECT(" ")).join(axis: 1).join("\n")
end

edges = CArray.float64(31).span(-60.0..60.0)
puts
puts "endpoint distribution:"
puts bell(finals, edges)

# ------------------------------------------------------------
# Numbers to compare against theory
# ------------------------------------------------------------
puts
puts "endpoints: mean = #{finals.mean.round(3)}   " \
     "(theory: 0)"
puts "endpoints: stddev = #{finals.stddev.round(3)}   " \
     "(theory: sqrt(n_steps) = #{Math.sqrt(n_steps).round(3)})"
