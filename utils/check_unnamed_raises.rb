# Lint: an error opens with the method the user called, "<method>: ...".
# The name comes from ca_calling_method_name() (or a literal, for a method
# that names itself), as the first "%s" of the format.
#
# Many raises in ext/ do not open that way yet -- a few hundred, most of them
# guards a user cannot reach (smoke tests, internal invariants) -- so this is
# a ratchet: it records how many each file has and fails when a file gains
# one.  A new raise opens with "%s: " and ca_calling_method_name(); a file
# that loses some lowers its count.
#
# Run via `rake unnamed_raise_check`, or `ruby utils/check_unnamed_raises.rb`.
# `ruby utils/check_unnamed_raises.rb --counts` prints the table below.

ROOT = File.expand_path("..", __dir__)
NAMED = /\A(%s|[A-Za-z_][\w.#!?\[\]=]*(\(\))?: )/

def unnamed_counts
  counts = Hash.new(0)
  Dir[File.join(ROOT, "ext", "*.c")].sort.each do |path|
    base = File.basename(path)
    next if base.start_with?("carray_kernels_")
    File.read(path, encoding: "UTF-8")
        .scan(/rb_raise\s*\(\s*\w+\s*,\s*"((?:[^"\\]|\\.)*)"/m) do
      counts[base] += 1 unless $1.match?(NAMED)
    end
  end
  counts
end

COUNTS = {
  "ca_compare.c"                     => 1,
  "ca_kernel_iterator.c"             => 22,
  "ca_obj_array.c"                   => 6,
  "ca_obj_bincmp.c"                  => 4,
  "ca_obj_binop.c"                   => 5,
  "ca_obj_bitarray.c"                => 2,
  "ca_obj_bitfield.c"                => 7,
  "ca_obj_block.c"                   => 2,
  "ca_obj_byte_swap.c"               => 2,
  "ca_obj_const_string.c"            => 2,
  "ca_obj_face.c"                    => 1,
  "ca_obj_field.c"                   => 4,
  "ca_obj_fixlen_string.c"           => 1,
  "ca_obj_grid.c"                    => 7,
  "ca_obj_meld.c"                    => 10,
  "ca_obj_moncmp.c"                  => 4,
  "ca_obj_monop.c"                   => 6,
  "ca_obj_object.c"                  => 7,
  "ca_obj_record.c"                  => 10,
  "ca_obj_reduce.c"                  => 1,
  "ca_obj_refer.c"                   => 9,
  "ca_obj_repeat.c"                  => 6,
  "ca_obj_select.c"                  => 1,
  "ca_obj_select_axis.c"             => 2,
  "ca_obj_shift.c"                   => 2,
  "ca_obj_source.c"                  => 1,
  "ca_obj_stack.c"                   => 11,
  "ca_obj_stride.c"                  => 5,
  "ca_obj_string.c"                  => 1,
  "ca_obj_tile.c"                    => 2,
  "ca_obj_time.c"                    => 3,
  "ca_obj_timedelta.c"               => 1,
  "ca_obj_transpose.c"               => 3,
  "ca_obj_triop.c"                   => 5,
  "ca_obj_window.c"                  => 9,
  "ca_op_byte_swap.c"                => 1,
  "ca_op_ipower.c"                   => 2,
  "ca_sweep_engine.c"                => 2,
  "carray_access.c"                  => 32,
  "carray_address_basis.c"           => 12,
  "carray_attribute.c"               => 1,
  "carray_cast.c"                    => 26,
  "carray_cast_func.c"               => 54,
  "carray_conversion.c"              => 9,
  "carray_copy.c"                    => 2,
  "carray_core.c"                    => 27,
  "carray_count.c"                   => 5,
  "carray_data_type.c"               => 1,
  "carray_element.c"                 => 8,
  "carray_factorize.c"               => 6,
  "carray_generate.c"                => 2,
  "carray_histogram.c"               => 1,
  "carray_index_classifier.c"        => 17,
  "carray_lazy.c"                    => 3,
  "carray_mask.c"                    => 12,
  "carray_mathfunc.c"                => 2,
  "carray_memory_view.c"             => 10,
  "carray_operator.c"                => 14,
  "carray_random.c"                  => 5,
  "carray_slab.c"                    => 1,
  "carray_sort.c"                    => 2,
  "carray_struct.c"                  => 20,
  "carray_test.c"                    => 15,
  "carray_time_text.c"               => 6,
  "carray_undef.c"                   => 2,
  "carray_utils.c"                   => 18,
}.freeze

if ARGV.include?("--counts")
  unnamed_counts.each { |f, n| puts "  %-34s => %d," % [f.inspect, n] }
  exit
end

found = unnamed_counts
over  = found.select { |f, n| n > COUNTS.fetch(f, 0) }
under = COUNTS.select { |f, n| found[f] < n }
if over.empty? && under.empty?
  puts "unnamed_raise_check: ok"
else
  over.each do |f, n|
    warn "unnamed_raise_check: ext/#{f} has #{n} raises that do not name the method " \
         "(allowed #{COUNTS.fetch(f, 0)}): open the message with \"%s: \" and ca_calling_method_name()"
  end
  under.each do |f, n|
    warn "unnamed_raise_check: ext/#{f} has #{found[f]}, fewer than #{n}: lower its count"
  end
  exit 1
end
