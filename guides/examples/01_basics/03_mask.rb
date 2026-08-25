# frozen_string_literal: true
#
# 01_basics/03_mask.rb
#
# Missing values. Every CArray, whether an entity or a view, can carry a
# mask that marks individual cells as missing. Reductions and arithmetic
# treat masked cells as absent (they are skipped rather than propagated
# as NaN).
#
# See also: guides/users/05_masks.md

require "carray"

a = CArray.float64(6) { |i| i.to_f }
p a
#  => <CArray.float64(6): elem=6 mem=48b
#     [ 0.0, 1.0, 2.0, 3.0, 4.0, 5.0 ]>

# ------------------------------------------------------------
# Assigning UNDEF marks a cell as missing
# ------------------------------------------------------------
a[2] = UNDEF
a[4] = UNDEF
p a
#  => <CArray.float64(6): elem=6 mask=2 mem=48b
#     [ 0.0, 1.0, _, 3.0, _, 5.0 ]>
#
# The inspect header adds `mask=2` — two cells are masked. The underscore
# in the value block shows a masked cell. Reductions and arithmetic
# ignore those cells.

# ------------------------------------------------------------
# Inspecting the mask
# ------------------------------------------------------------
p a.has_mask?
#  => true
p a.count_masked
#  => 2
p a.count_not_masked
#  => 4
p a.is_masked
#  => <CArray.boolean(6): elem=6 mem=6b
#     [ 0, 0, 1, 0, 1, 0 ]>

# ------------------------------------------------------------
# Reductions skip masked cells
# ------------------------------------------------------------
# The mean and sum below are taken over the four unmasked values
# (0.0, 1.0, 3.0, 5.0).

p a.mean
#  => 2.25
p a.sum
#  => 9.0

# ------------------------------------------------------------
# Arithmetic propagates the mask
# ------------------------------------------------------------
# A cell that was masked in an operand stays masked in the result.

p a * 2
#  => <CArray.float64(6): elem=6 mask=2 mem=48b
#     [ 0.0, 2.0, _, 6.0, _, 10.0 ]>

# ------------------------------------------------------------
# Removing the mask
# ------------------------------------------------------------
# strip_mask returns a copy in which the mask is cleared and each
# formerly masked cell is filled with the given value.

p a.strip_mask(-1.0)
#  => <CArray.float64(6): elem=6 mem=48b
#     [ 0.0, 1.0, -1.0, 3.0, -1.0, 5.0 ]>

# ------------------------------------------------------------
# Masking by a condition
# ------------------------------------------------------------
# mask_eq(v) returns a copy in which cells equal to v are marked as
# missing.

b = CArray.float64(5) { |i| [ 1.0, 2.0, 3.0, 2.0, 5.0 ][i] }
p b.mask_eq(2.0)
#  => <CArray.float64(5): elem=5 mask=2 mem=40b
#     [ 1.0, _, 3.0, _, 5.0 ]>

# mask_invalid is the common idiom for handling NaN and infinity in
# floating-point data.

c = CArray.float64(5) { |i| [ 1.0, 2.0, Float::NAN, 4.0, 5.0 ][i] }
p c.mask_invalid
#  => <CArray.float64(5): elem=5 mask=1 mem=40b
#     [ 1.0, 2.0, _, 4.0, 5.0 ]>
p c.mask_invalid.mean
#  => 3.0

# is_invalid returns a boolean array that is true for cells that are
# NaN, infinite, or already masked.

p c.is_invalid
#  => <CArray.boolean(5): elem=5 mem=5b
#     [ 0, 0, 1, 0, 0 ]>

# ------------------------------------------------------------
# Setting a mask in place through the indexer
# ------------------------------------------------------------
# The canonical way to mark cells that match a condition is to assign
# UNDEF through an indexer.

d = CArray.float64(5).seq
d[:gt, 2.0] = UNDEF
p d
#  => <CArray.float64(5): elem=5 mask=2 mem=40b
#     [ 0.0, 1.0, 2.0, _, _ ]>
