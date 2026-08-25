# frozen_string_literal: true
#
# cookbook/moving_average.rb
#
# Smoothing a noisy signal with a moving average. A one-liner using
# windows, without writing an explicit for-loop over the array.

require "carray"

# ------------------------------------------------------------
# A noisy signal
# ------------------------------------------------------------
# A sine wave with uniform noise added to each sample. seq fills the
# array with 0, 1, 2, ...; s.random(low, high) returns a new array of
# the same shape filled with uniform samples in [low, high).
srand(1)
n = 40
s      = CArray.float64(n).seq
signal = (s * 0.3).sin + s.random(-0.3, 0.3)

# ------------------------------------------------------------
# Moving average with a window of five samples
# ------------------------------------------------------------
# windows(-2..2) is a view in which each cell carries the five-sample
# window centred on that position. Calling mean on it returns the
# moving average as an array of the same shape as the input.
smoothed = signal.windows(-2..2).mean

# ------------------------------------------------------------
# Print the two side by side as an ASCII plot
# ------------------------------------------------------------
# `locate_nearest_addr(anchors)` returns the index of the closest
# anchor for each value — exactly what we need to place a value on an
# ASCII column. The anchors are `width` points evenly spanning the
# expected signal range; the rendering loop that follows only assembles
# the output string.
width       = 40
anchors     = CArray.float64(width).span(-2.0..2.0)
raw_cols    = signal.locate_nearest_addr(anchors)
smooth_cols = smoothed.locate_nearest_addr(anchors)

puts "  raw     smoothed"
n.times do |i|
  line = " " * width
  line[raw_cols[i]]    = "."
  line[smooth_cols[i]] = "o"
  puts line
end

# ------------------------------------------------------------
# Wider window, same idiom
# ------------------------------------------------------------
wider = signal.windows(-5..5).mean

# ------------------------------------------------------------
# Weighted moving average
# ------------------------------------------------------------
# `.mean` weights every sample in the window equally. `.wmean(w)` takes
# a 1-D CArray of weights along the window axis and returns the
# per-cell weighted mean. Gaussian weights let nearby samples
# contribute more than distant ones, so peaks and troughs stay closer
# to where the signal actually put them.
gauss_w  = CA_DOUBLE([0.06, 0.24, 0.4, 0.5, 0.4, 0.24, 0.06])
gaussian = signal.windows(-3..3).wmean(gauss_w)

puts "\nfirst five values (rounded to 3 decimals for readability):"
puts "  signal:                #{signal[0..4].to_a.map   { _1.round(3) }.inspect}"
puts "  uniform, window 5:     #{smoothed[0..4].to_a.map { _1.round(3) }.inspect}"
puts "  uniform, window 11:    #{wider[0..4].to_a.map    { _1.round(3) }.inspect}"
puts "  gaussian, window 7:    #{gaussian[0..4].to_a.map { _1.round(3) }.inspect}"

# ------------------------------------------------------------
# Behaviour at the edges
# ------------------------------------------------------------
# At the edges of the array the window would extend past the end. By
# default the parts that fall outside are simply left out of the mean,
# so the boundary values remain meaningful.

edge = CArray.float64(5).seq
p edge.windows(-1..1).mean.to_a
#  => [ 0.5, 1.0, 2.0, 3.0, 3.5 ]
# The first cell averages the two samples that are present (0 and 1);
# the last cell averages (3 and 4).
