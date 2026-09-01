# frozen_string_literal: true
#
# gallery/game_of_life.rb
#
# Conway's Game of Life on a boolean grid. Each generation is one
# expression: a 3x3 window sum gives the neighbour count, then the
# birth-and-survival rule is boolean arithmetic.

require "carray"

# ------------------------------------------------------------
# Initial state: a glider near the top-left corner
# ------------------------------------------------------------
# The glider walks diagonally down-and-right, one cell every four
# generations.
h, w = 20, 60
world = CArray.boolean(h, w)
[ [1, 1], [2, 2], [3, 0], [3, 1], [3, 2] ].each { |i, j| world[i, j] = true }

# ------------------------------------------------------------
# One generation
# ------------------------------------------------------------
# `windows(-1..1, -1..1).sum` sums the 3x3 neighbourhood at every cell,
# with zero-fill outside the grid (open-boundary Life). Subtracting the
# cell itself gives the count of neighbours only.
def step(g)
  n = g.uint8.windows(-1..1, -1..1).sum - g.uint8
  #  A live cell with 2 or 3 neighbours survives; a dead cell with
  #  exactly 3 neighbours is born.
  ( g & ( n.eq(2) | n.eq(3) ) ) | ( ~g & n.eq(3) )
end

# ------------------------------------------------------------
# Render a generation as ASCII
# ------------------------------------------------------------
# The same then_else + slab-reduce idiom used in image_threshold.
def render(g)
  chars = g.then_else(CA_OBJECT("O"), CA_OBJECT("."))
  chars.join(axis: 1).join("\n")
end

# ------------------------------------------------------------
# Play
# ------------------------------------------------------------
generations = 40
generations.times do |gen|
  puts "-- generation #{gen} --"
  puts render(world)
  world = step(world)
end

puts "-- generation #{generations} --"
puts render(world)
puts
puts "live cells at end: #{world.sum}"
