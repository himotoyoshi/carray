# frozen_string_literal: true
#
# 01_basics/01_creation.rb
#
# Constructing arrays. The basic constructor plus the common idioms for
# filling in values: generator block, seq, span, and conversion from a
# Ruby Array.
#
# See also: guides/users/01_creating_arrays.md

require "carray"

# ------------------------------------------------------------
# By shape and data type
# ------------------------------------------------------------
# The basic constructor is a class method named after the data type. It
# takes the shape (one integer per axis) and, without a block, fills the
# array with zeros.

a = CArray.float64(3)
p a
#  => <CArray.float64(3): elem=3 mem=24b
#     [ 0.0, 0.0, 0.0 ]>

b = CArray.int32(2, 3)
p b.shape
#  => [2, 3]
p b
#  => <CArray.int32(2,3): elem=6 mem=24b
#     [ [ 0, 0, 0 ],
#       [ 0, 0, 0 ] ]>

# ------------------------------------------------------------
# Filling with a block
# ------------------------------------------------------------
# If a block is given, it is called once per element and its return value
# becomes that element. The block receives the indices of the element.

c = CArray.int32(5) { |i| i * i }
p c
#  => <CArray.int32(5): elem=5 mem=20b
#     [ 0, 1, 4, 9, 16 ]>

d = CArray.float64(2, 3) { |i, j| i * 10.0 + j }
p d
#  => <CArray.float64(2,3): elem=6 mem=48b
#     [ [ 0.0, 1.0, 2.0 ],
#       [ 10.0, 11.0, 12.0 ] ]>

# A block that takes no arguments is a shorthand for filling every cell
# with the same value. The block is evaluated once and broadcast.

same = CArray.int32(5) { 7 }
p same
#  => <CArray.int32(5): elem=5 mem=20b
#     [ 7, 7, 7, 7, 7 ]>

# ------------------------------------------------------------
# seq: arithmetic progression
# ------------------------------------------------------------
# seq writes an arithmetic progression into an existing array and returns
# it. Without arguments the progression starts at 0 with step 1.

p CArray.float64(5).seq
#  => <CArray.float64(5): elem=5 mem=40b
#     [ 0.0, 1.0, 2.0, 3.0, 4.0 ]>

p CArray.int32(5).seq(10, 3)
#  => <CArray.int32(5): elem=5 mem=20b
#     [ 10, 13, 16, 19, 22 ]>

# ------------------------------------------------------------
# span: evenly spaced values across a range
# ------------------------------------------------------------
# span divides the given range into equal steps, including both endpoints.

p CArray.float64(5).span(0.0..1.0)
#  => <CArray.float64(5): elem=5 mem=40b
#     [ 0.0, 0.25, 0.5, 0.75, 1.0 ]>

# ------------------------------------------------------------
# random: uniform samples
# ------------------------------------------------------------
# random writes uniform samples in [0, 1) into an existing array. Two
# forms are available: random! mutates the receiver in place, while
# random returns a new array of the same shape and leaves the receiver
# alone. Ruby's srand controls the sequence.

srand(1)
p CArray.float64(5).random
#  => <CArray.float64(5): elem=5 mem=40b
#     [ 0.417022004702574, 0.7203244934421581, 0.00011437481734488664, ..., 0.14675589081711304 ]>

# random(low, high) draws directly from [low, high) — floats and
# integers both work. No composition with * and - needed on the
# receiver side.
srand(1)
p CArray.float64(5).random(-1.0, 1.0)
#  => <CArray.float64(5): elem=5 mem=40b
#     [ -0.165955990594852, 0.4406489868843162, -0.9997712503653102, ..., -0.7064882183657739 ]>

# Once an array is around, `.random` on it gives another array of the
# same shape filled with samples. This is the idiomatic way to say
# "a random array like this one".
s = CArray.float64(5).seq
noise = s.random
p noise.shape
#  => [5]

# randomn / randomn! draw from the standard normal distribution.
srand(1)
p CArray.float64(5).randomn
#  => <CArray.float64(5): elem=5 mem=40b
#     [ -0.24517851535942076, -1.2996615230957085, -1.3758166332833228, ..., 1.638498075279306 ]>

# ------------------------------------------------------------
# From a Ruby Array
# ------------------------------------------------------------
# CA_DOUBLE, CA_FLOAT, CA_INT (and the other type shortcuts) build a
# CArray of the named data type from a Ruby Array.

p CA_DOUBLE([1.0, 2.0, 3.0])
#  => <CArray.float64(3): elem=3 mem=24b
#     [ 1.0, 2.0, 3.0 ]>

p CA_INT([1, 2, 3])
#  => <CArray.int32(3): elem=3 mem=12b
#     [ 1, 2, 3 ]>

# Array#to_ca converts a Ruby Array without picking a numeric type; the
# result is an object-typed CArray that stores the Ruby values as-is.
# Use one of the CA_* shortcuts when a specific numeric type is wanted.

p [1.0, 2.0, 3.0].to_ca.data_type_name
#  => "object"
