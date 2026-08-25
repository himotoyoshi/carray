#  Standalone example: CAObject backed by nested Ruby Arrays
#  (e.g. [[1.0, 2.0], [3.0, 4.0]]).  Demonstrates the full CAObject
#  template (fetch_index / store_index / each_index / etc).
#
#  Run with:
#    ruby -Iext -Ilib samples/caobject/nested.rb
#
#  Copy this file into your own project to use the pattern.  Not shipped
#  as part of the CArray gem since 3.0.

require "carray"

#
# CANestedArray
#
#   A CAObject that represents a multi-dimensional Float64 array stored as
#   nested Ruby Arrays (e.g. [[1.0, 2.0], [3.0, 4.0]]).
#
#   It defines the full CAObject template set so that every access path works:
#
#     fetch_index / store_index   per-element by multi-index  [i, j, ...]
#     fetch_addr  / store_addr    per-element by flat address  (row-major)
#     copy_data                   bulk read  (view  -> CArray)
#     sync_data                   bulk write (CArray -> view)
#     fill_data                   broadcast a scalar to every cell
#     create_mask                 mask support (no-op, per requirement)
#
#   The backing nested array is the authoritative store; the CArray side is a
#   materialised snapshot delivered/synced through the templates above.
#
#   Example:
#
#     a = CANestedArray.new([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
#     a.dim            #=> [2, 3]
#     a[1, 2]          #=> 6.0
#     a.copy           #=> CArray.float64(2, 3) snapshot
#     a[0, 0] = 9.0    # store_index
#     a.nested         #=> [[9.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
#
class CANestedArray < CAObject

  def initialize (nested)
    @nested = nested
    super(CA_FLOAT64, CANestedArray.guess_dim(nested))
  end

  # Authoritative nested-array store.
  attr_reader :nested

  # Derive the shape by walking the nesting depth (assumes a rectangular array).
  def self.guess_dim (nested)
    dim  = []
    node = nested
    while node.is_a?(Array)
      dim << node.size
      node = node[0]
    end
    dim.empty? ? [1] : dim
  end

  private

  # ---- per-element by multi-index --------------------------------------

  def fetch_index (idx)
    node = @nested
    idx.each { |i| node = node[i] }
    Float(node)
  end

  def store_index (idx, val)
    node = @nested
    idx[0...-1].each { |i| node = node[i] }
    node[idx[-1]] = Float(val)
  end

  # ---- per-element by flat (row-major) address -------------------------

  def fetch_addr (addr)
    fetch_index(addr2index(addr))
  end

  def store_addr (addr, val)
    store_index(addr2index(addr), val)
  end

  # ---- bulk ------------------------------------------------------------

  # data is the internal CArray snapshot (shape == self.dim).  Filling it with
  # the row-major flattened nested array delivers the whole view in one pass.
  def copy_data (data)
    data[] = @nested.flatten
  end

  # Read the snapshot back into the nested store (row-major).
  def sync_data (data)
    flat = data.flatten.to_a
    flat.each_with_index { |v, addr| store_addr(addr, v) }
  end

  # Broadcast a scalar to every cell of the nested store.
  def fill_data (val)
    v = Float(val)
    elements.times { |addr| store_addr(addr, v) }
  end

  # ---- mask ------------------------------------------------------------

  # Required override for masking (per requirement, no-op).
  def create_mask
  end

  # ---- helper ----------------------------------------------------------

  # flat row-major address -> multi-index [i, j, ...]
  def addr2index (addr)
    d   = dim
    idx = Array.new(ndim)
    (ndim - 1).downto(0) do |k|
      idx[k] = addr % d[k]
      addr  /= d[k]
    end
    idx
  end

end
