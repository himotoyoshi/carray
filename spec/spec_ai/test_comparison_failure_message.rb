require "test/unit"
require "carray"

# A pair of object cells `<=>` cannot order raises "<method>: comparison of A
# with B failed", naming the method the caller called, from every method and
# every iterator -- not a method it is made of (median used to say
# "partition_index:", mode "sort:", a categorical cummax
# "__scan_by_axis_groups__:"), and not without a name (min, max and the running
# extrema used to give Ruby's bare message).

class TestComparisonFailureMessage < Test::Unit::TestCase

  def unordered
    CA_OBJECT([Object.new, Object.new, Object.new, Object.new]).reshape(2, 2)
  end

  def test_every_order_statistic_reports_the_pair_as_ruby_does
    lab = CArray.object(4) { |i| %w[a b][i % 2] }.categorize
    o = unordered
    targets = { "array" => o, "axis" => [o, { axis: 1 }],
                "category" => o.flatten.copy.group_by_category(lab),
                "segments" => o.flatten.copy.segments(lengths: [2, 2]),
                "slab" => o[nil, :>], "blocks" => o.blocks(1, 2) }
    ops = %i[min max minmax median percentile quantile sort sort_index sort_addr
             rank_index partition_copy min_index max_index mode cummax cummin]
    args = { partition_copy: [0], percentile: [50] }
    targets.each do |name, t|
      obj, kw = t.is_a?(Array) ? t : [t, {}]
      ops.each do |op|
        next unless obj.respond_to?(op)
        begin
          obj.public_send(op, *(args[op] || []), **kw)
        rescue NotImplementedError
          next
        rescue ArgumentError => e
          next if e.message.start_with?("unknown keyword")
          assert_equal "#{op}: comparison of Object with Object failed", e.message, "#{name} #{op}"
        end
      end
    end
    assert_raise_message("bsearch: comparison of Object with Object failed") { o.flatten.bsearch(Object.new) }
  end

  def test_locate_addr_names_itself_for_a_reference_that_is_not_an_array
    e = assert_raise(TypeError) { CA_FLOAT64([1]).locate_addr("x") }
    assert_match(/\Alocate_addr:/, e.message)
  end
end
