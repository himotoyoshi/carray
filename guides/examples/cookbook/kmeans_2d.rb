# frozen_string_literal: true
#
# cookbook/kmeans_2d.rb
#
# Lloyd's algorithm for k-means on a 2-D point cloud. Assignment is one
# broadcast distance expression; the centroid update reuses
# `group_by_category(cat).mean`; the whole thing renders on an ASCII
# grid via `scatter_replace!` + `.lookup(palette)`.

require "carray"

# ------------------------------------------------------------
# A point cloud in three clusters
# ------------------------------------------------------------
# 30 points around each of three true centres, plus uniform noise.
# The true labels are only used to place the points; the algorithm
# rediscovers them from the data.
n_per = 30
k     = 3
n     = n_per * k

true_centres_x = CA_DOUBLE([ 10.0, 30.0, 50.0 ])
true_centres_y = CA_DOUBLE([ 15.0,  6.0, 15.0 ])
true_label     = CArray.int32(n).seq / n_per   #  0, 0, ..., 1, 1, ..., 2, 2, ...

srand(1)
pts_x = true_label.lookup(true_centres_x) + CArray.float64(n).random(-5.0, 5.0)
pts_y = true_label.lookup(true_centres_y) + CArray.float64(n).random(-3.0, 3.0)

# ------------------------------------------------------------
# Lloyd's algorithm
# ------------------------------------------------------------
# Seed the centroids from the first k points, then iterate:
#   1. distance^2 from every point to every centroid, in one broadcast
#      expression of shape (n, k);
#   2. `min_index(axis: 1)` picks the closest centroid per point;
#   3. `group_by_category(cat).mean` recomputes each centroid as the
#      mean of the points that were assigned to it.
c_x = pts_x[0...k].copy
c_y = pts_y[0...k].copy

10.times do
  d2   = ( pts_x[nil, :_] - c_x[:_, nil] ).abs2 +
         ( pts_y[nil, :_] - c_y[:_, nil] ).abs2
  code = d2.min_index(axis: 1)
  cat  = code.categorize(labels: (0...k).to_a)
  c_x  = pts_x.group_by_category(cat).mean
  c_y  = pts_y.group_by_category(cat).mean
end

# ------------------------------------------------------------
# Render the final state as ASCII
# ------------------------------------------------------------
# The grid holds a uint8 code per cell: 0 = empty, 1..k = point of that
# cluster, k+1 = centroid. `.lookup(palette)` turns the codes into the
# characters we want to print. scatter_replace! writes many cells at
# once given a flat address; points go in first, then centroids
# overwrite so the centroid marker wins when they overlap.
grid_h, grid_w = 22, 60
grid = CArray.uint8(grid_h, grid_w)

x_max = pts_x.max
y_max = pts_y.max
col_anchors = CArray.float64(grid_w).span(0.0..x_max)
row_anchors = CArray.float64(grid_h).span(0.0..y_max)
pt_col = pts_x.locate_nearest_addr(col_anchors)
pt_row = pts_y.locate_nearest_addr(row_anchors)
c_col  = c_x.locate_nearest_addr(col_anchors)
c_row  = c_y.locate_nearest_addr(row_anchors)

d2_final = ( pts_x[nil, :_] - c_x[:_, nil] ).abs2 +
           ( pts_y[nil, :_] - c_y[:_, nil] ).abs2
final_code = d2_final.min_index(axis: 1)

palette = CA_OBJECT([ ".", "a", "b", "c", "*" ])   #  size k + 2
grid.scatter_replace!( pt_row * grid_w + pt_col, ( final_code + 1 ).uint8 )
grid.scatter_replace!( c_row  * grid_w + c_col,  palette.elements - 1 )

puts "final centroids:"
k.times { |c| puts format("  %s at (%6.2f, %6.2f)", palette[c + 1], c_x[c], c_y[c]) }
puts
puts grid.lookup(palette).join(axis: 1).join("\n")
