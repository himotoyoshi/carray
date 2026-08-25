# CAFrame — a DataFrame whose columns are real CArrays.
#
# Thin loader. The frame is a small Ruby layer over CArray: columns are
# genuine CArrays, so every CArray operation (mask / view / Face /
# memory_view) is reachable by escaping to a column. See
# devel/MEMO_DATAFRAME_ON_CARRAY.md for the design.

require 'carray/frame/frame'
require 'carray/frame/verbs'
require 'carray/frame/convert'
require 'carray/frame/io'
require 'carray/frame/records'
require 'carray/frame/group'
require 'carray/frame/join'
require 'carray/frame/concat'
require 'carray/frame/sort'
