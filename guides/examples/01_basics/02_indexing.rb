# frozen_string_literal: true
#
# 01_basics/02_indexing.rb
#
# Element access. Scalar access, slicing, boolean selection, and
# assignment. The full set of index forms is described in
# docs/topics/Indexer_decision_tree.md; this file covers the ones needed
# in day-to-day use.
#
# See also: guides/users/02_indexing_and_slicing.md

require "carray"

# A 3-by-4 array with values that make the row and column easy to read.
a = CArray.int32(3, 4) { |i, j| i * 10 + j }
p a
#  => <CArray.int32(3,4): elem=12 mem=48b
#     [ [ 0, 1, 2, 3 ],
#       [ 10, 11, 12, 13 ],
#       [ 20, 21, 22, 23 ] ]>

# ------------------------------------------------------------
# Scalar access
# ------------------------------------------------------------
# One integer per axis returns a single element.

p a[1, 2]
#  => 12

# Negative indices count from the end, the same as in Ruby's Array.
p a[-1, -1]
#  => 23

# ------------------------------------------------------------
# Slicing
# ------------------------------------------------------------
# nil in an axis means "the whole axis". A Range picks a sub-range. The
# inspect header shows CABlock rather than CArray — slices return a
# view onto the original array (see guides/users/06_views.md).

p a[nil, 2]               #  column 2, all rows
#  => <CABlock.int32(3): elem=3 mem=12b
#     [ 2, 12, 22 ]>

p a[0, nil]               #  row 0, all columns
#  => <CABlock.int32(4): elem=4 mem=16b
#     [ 0, 1, 2, 3 ]>

p a[nil, 1..2]            #  columns 1..2, all rows
#  => <CABlock.int32(3,2): elem=6 mem=24b
#     [ [ 1, 2 ],
#       [ 11, 12 ],
#       [ 21, 22 ] ]>

p a[0..1, 1..2]           #  a 2-by-2 sub-rectangle
#  => <CABlock.int32(2,2): elem=4 mem=16b
#     [ [ 1, 2 ],
#       [ 11, 12 ] ]>

# ------------------------------------------------------------
# Boolean selection
# ------------------------------------------------------------
# A comparison returns a boolean array of the same shape. Boolean
# arrays print their cells as 0 / 1 in the inspect header.

mask = ( a > 15 )
p mask
#  => <CArray.boolean(3,4): elem=12 mem=12b
#     [ [ 0, 0, 0, 0 ],
#       [ 0, 0, 0, 0 ],
#       [ 1, 1, 1, 1 ] ]>

# Passing a boolean array as the index selects the cells where it is
# true, returning them as a 1-D view of values (CASelect).

p a[a > 15]
#  => <CASelect.int32(4): elem=4 mem=16b
#     [ 20, 21, 22, 23 ]>

# ------------------------------------------------------------
# Assignment
# ------------------------------------------------------------
# Take a copy first so the original stays intact.
b = a.copy

# Scalar assignment.
b[0, 0] = 99
p b[0, 0]
#  => 99

# A slice on the left-hand side, a scalar on the right: the scalar is
# broadcast into every selected cell.
b[nil, 0] = 0
p b[nil, 0]
#  => <CABlock.int32(3): elem=3 mem=12b
#     [ 0, 0, 0 ]>

# A boolean array on the left-hand side updates only the true cells.
b[b > 15] = -1
p b
#  => <CArray.int32(3,4): elem=12 mem=48b
#     [ [ 0, 1, 2, 3 ],
#       [ 0, 11, 12, 13 ],
#       [ 0, -1, -1, -1 ] ]>

# ------------------------------------------------------------
# Shape and size
# ------------------------------------------------------------
p a.shape
#  => [3, 4]
p a.ndim
#  => 2
p a.elements
#  => 12
