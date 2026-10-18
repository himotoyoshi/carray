# The kernel iterator hands a kernel the cells of a source, and on WRITE
# takes what the kernel wrote back to the root.  Whichever route it picks
# for a source, the kernel must receive the cells and mask flags of the
# view's materialised copy, in the view's row-major order, and a write must
# land on the root cells the view covers and nowhere else.
#
# The matrix is parents x views x masked/unmasked x four ways of walking
# (L1 whole, one slab axis, one contiguous fiber, two slab axes: the given
# one and the last), read, write of every cell and write of some cells.  The whole walk's cells are compared
# joined.  The expected answers are built without the iterator: the read
# from the view's copy, the write by storing the same values through the
# same view of an unmasked copy of the root.
#
# rake spec_ai, spec_ai_general and spec_ai_transfer run it with
# CARRAY_GENERAL_PATH unset, 1 and 2.  With 2 every source takes the
# transfer walk, so the three runs compare the iterator's other routes
# with that one.

require "test/unit"
require "carray"
require_relative "iter_delivery_cases"

ext_dir = File.expand_path("ext_iter_write", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_write"
rescue LoadError
  warn "Skipping test_iter_delivery_matrix: iter_write not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestIterDeliveryMatrix < Test::Unit::TestCase

  include IterDeliveryCases

  def test_read_delivers_the_cells_of_the_copy
    cases = 0
    [false, true].each do |masked|
      PARENTS.each_key do |pn|
        READ_VIEWS.each do |vn, view|
          built = build(pn, view, masked) or next
          v = built[1]
          copy  = v.copy
          vals  = copy.value.to_a.flatten
          flags = copy.has_mask? ? copy.mask.to_a.flatten : []
          cells = vals.each_with_index.map { |x, i| flags[i] ? nil : x.to_f }
          walks(v).each do |mode, ax, name|
            exp = slab_addresses(v.shape, mode, ax).map { |s| s.map { |a| cells[a] } }
            got = CArray.iw_read_cells(v, mode, ax)
            got = [got.flatten(1)] if mode == 0
            assert_equal exp, got, "#{vn} of #{pn} masked=#{masked}: #{name} axis #{ax}"
            cases += 1
          end
        end
      end
    end
    assert_operator cases, :>=, 1000
  end

  def test_write_lands_where_a_store_through_the_view_lands
    cases = 0
    [false, true].each do |masked|
      PARENTS.each do |pn, (_, _, parent)|
        VIEWS.each do |vn, view|
          probe = build(pn, view, masked) or next
          walks(probe[1]).each do |mode, ax, name|
            r, v = build(pn, view, masked)
            vals = Array.new(v.elements)
            slab_addresses(v.shape, mode, ax).each_with_index do |s, k|
              s.each_with_index { |a, i| vals[a] = 1000.0 * (k + 1) + i }
            end
            ref   = r.value.copy
            ref_v = view.call(parent.call(ref))
            ref_v[] = CA_FLOAT64(vals).reshape(*v.shape)
            flags = r.has_mask? ? r.mask.to_a : nil

            CArray.iw_write_cells(v, mode, ax)

            label = "#{vn} of #{pn} masked=#{masked}: #{name} axis #{ax}"
            assert_equal ref.to_a, r.value.to_a, label
            assert_equal flags, (r.has_mask? ? r.mask.to_a : nil), "#{label} mask"
            cases += 1
          end
        end
      end
    end
    assert_operator cases, :>=, 1000
  end

  # A kernel that writes some cells only: the cells it wrote land as a
  # store of those cells through the view lands, and the cells it left
  # alone are unchanged -- on a conversion that does not bring every
  # value back and on a view that shows a root cell twice as well.  The
  # cells written are those whose row-major address in the view is a
  # multiple of 3 (the two copies of a repeated row are 20 apart, so at
  # most one of them is written).
  def test_a_partial_write_changes_only_the_cells_written
    cases = 0
    [false, true].each do |masked|
      PARENTS.each do |pn, (_, _, parent)|
        VIEWS.each do |vn, view|
          probe = build(pn, view, masked) or next
          walks(probe[1]).each do |mode, ax, name|
            r, v  = build(pn, view, masked)
            order = slab_addresses(v.shape, mode, ax)
            which = order.flatten.map { |a| a % 3 == 0 }
            ref   = r.value.copy
            ref_v = view.call(parent.call(ref)).reshape(v.elements)
            pos = 0
            order.each_with_index do |s, k|
              s.each_with_index do |a, i|
                if which[pos]
                  ref_v[a] = mode == 0 ? 1000.0 + pos : 1000.0 * (k + 1) + i
                end
                pos += 1
              end
            end
            flags = r.has_mask? ? r.mask.to_a : nil

            CArray.iw_write_some_cells(v, mode, ax, which)

            label = "#{vn} of #{pn} masked=#{masked}: #{name} axis #{ax}"
            assert_equal ref.to_a, r.value.to_a, label
            assert_equal flags, (r.has_mask? ? r.mask.to_a : nil), "#{label} mask"
            cases += 1
          end
        end
      end
    end
    assert_operator cases, :>=, 1000
  end

end
