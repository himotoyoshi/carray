# Lint: a caller-caused error never raises RuntimeError.  RuntimeError is for
# an internal invariant (reached only through a bug in CArray), a write to a
# read-only array and a to_ca(writable: true) refusal; everything a caller can
# get wrong raises ArgumentError, TypeError, IndexError, RangeError or
# CArray::DataTypeError (guides/devel/15a_common_idioms.md).
#
# The sites that remain were each found to be one of the three allowed kinds,
# so this lint is a ratchet: it records how many rb_eRuntimeError raises each
# file has and fails when a file gains one.  A new one is either the wrong
# class, or an allowed kind -- then raise the count below and say which kind
# in the commit.  A file that loses one should lower its count.
#
# Only tracked files are read, so a generated .c is checked through its
# generator.
#
# Run via `rake runtime_error_check`, or `ruby utils/check_runtime_errors.rb`.

ROOT = File.expand_path("..", __dir__)

COUNTS = {
  "carray_cast_func.rb" => 3,
  "ca_kernel_iterator.c" => 6,
  "ca_obj_array.c" => 3,
  "ca_obj_meld.c" => 1,
  "ca_obj_monop.c" => 1,
  "ca_obj_reduce.c" => 1,
  "ca_obj_select.c" => 1,
  "ca_obj_select_axis.c" => 1,
  "ca_obj_stack.c" => 1,
  "ca_op_byte_swap.c" => 1,
  "ca_op_ipower.c" => 1,
  "ca_sweep_engine.c" => 2,
  "carray.h" => 2,
  "carray_address_basis.c" => 1,
  "carray_cast.c" => 3,
  "carray_conversion.c" => 1,
  "carray_copy.c" => 2,
  "carray_core.c" => 12,
  "carray_count.c" => 1,
  "carray_data_type.c" => 1,
  "carray_factorize.c" => 17,
  "carray_histogram.c" => 4,
  "carray_hold.c" => 3,
  "carray_lazy.c" => 1,
  "carray_mathfunc.c" => 2,
  "carray_memory_view.c" => 2,
  "carray_operator.c" => 5,
  "carray_slab.c" => 4,
  "carray_sort.c" => 1,
  "carray_struct.c" => 8,
  "carray_test.c" => 1,
  "mkkernel.rb" => 11,
}.freeze

failures = []
# The tracked sources: a generated .c (carray_kernels_*.c, carray_cast_func.c)
# is not tracked, and its generator .rb is.
files = Dir.chdir(ROOT) { `git ls-files -- 'ext/*.c' 'ext/*.h' 'ext/*.rb'`.split("\n") }
files.map! { |f| File.join(ROOT, f) }
files.sort.each do |path|
  name = File.basename(path)
  n = File.read(path, encoding: "UTF-8").scrub.scan(/\brb_eRuntimeError\b/).size
  allowed = COUNTS.fetch(name, 0)
  if n > allowed
    failures << "#{name}: #{n} rb_eRuntimeError (allowed #{allowed}); a caller-caused error raises ArgumentError, TypeError, IndexError, RangeError or CArray::DataTypeError"
  elsif n < allowed
    failures << "#{name}: #{n} rb_eRuntimeError, fewer than the #{allowed} recorded; lower the count in #{File.basename(__FILE__)}"
  end
end

if failures.empty?
  puts "runtime_error_check: ok"
else
  puts failures
  exit 1
end
