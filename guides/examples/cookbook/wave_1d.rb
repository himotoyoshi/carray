# frozen_string_literal: true
#
# cookbook/wave_1d.rb
#
# The one-dimensional wave equation on a fixed-end string. A Gaussian
# pulse in the middle splits into two traveling waves, hits the ends,
# reflects with a sign change, and comes back. Everything runs as
# CArray expressions — no per-cell time loop, no Ruby-side maths.

require "carray"

# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
# The leapfrog scheme for u_tt = c^2 * u_xx is
#
#   u_next = 2 * u - u_prev + r^2 * ( u.shift(1) - 2 * u + u.shift(-1) )
#
# where r = c * dt / dx. r <= 1 keeps the scheme stable (the CFL
# condition); r = 0.5 gives a well-behaved simulation.
n     = 80
r2    = 0.5 ** 2   #  ( c * dt / dx )^2

# Initial displacement: a Gaussian bump centred in the string. Start at
# rest by making u_prev identical to u (zero initial velocity).
x      = CArray.float64(n).seq
u      = ( - ( ( x - n / 2.0 ) / 5.0 ) ** 2 ).exp
u_prev = u.copy

# ------------------------------------------------------------
# One frame as ASCII
# ------------------------------------------------------------
# The amplitude row for each column is drawn as a filled bar between
# the baseline row and the row that matches the amplitude. Same
# broadcast-and-then-else idiom used elsewhere in the cookbook.
def render(u, height: 11)
  mid     = height / 2
  scaled  = ( u.clip(-1.0, 1.0) * mid ).round.int32
  row_idx = mid - scaled
  lo      = row_idx.pmin(mid)
  hi      = row_idx.pmax(mid)
  rows    = CArray.int32(height, 1).seq
  grid    = rows.ge(lo[:_, nil]) & rows.le(hi[:_, nil])
  grid.then_else(CA_OBJECT("#"), CA_OBJECT(" ")).join(axis: 1).join("\n")
end

# ------------------------------------------------------------
# Run and print a few frames
# ------------------------------------------------------------
show_at = [ 0, 15, 30, 45, 60, 75, 90 ]
steps   = show_at.max + 1

steps.times do |t|
  if show_at.include?(t)
    puts "-- t = #{t} --"
    puts render(u)
    puts
  end

  #  Laplacian via two shifted views; fixed-end (Dirichlet) boundaries
  #  are re-imposed after each step so the ends stay pinned at zero.
  lap    = u.shift(-1) - 2 * u + u.shift(1)
  u_next = 2 * u - u_prev + r2 * lap
  u_next[0]  = 0.0
  u_next[-1] = 0.0

  u_prev = u
  u      = u_next
end
