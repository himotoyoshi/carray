# Lint: an index out of range is checked and reported by the parts in
# ext/carray_internal.h -- ca_index_in_range / ca_index_in_range_at, which
# count a negative index from the end and raise IndexError naming the method
# the user called, or ca_index_out_of_range(_at) for a bound checked another
# way (the end of a Range).
#
# The rb_eIndexError raises that remain are each something else (an index of
# the wrong form, a reserved symbol) or a door a later round will move.
# CA_CHECK_INDEX in the public header raises through the part as well.  This lint is a ratchet: it
# records how many each tracked file has and fails when a file gains one.
# A new one is a hand-written bound check -- call the part -- or another kind
# of index error; then raise the count below.
#
# Run via `rake index_error_check`, or `ruby utils/check_index_errors.rb`.

ROOT = File.expand_path("..", __dir__)

COUNTS = {
  "ca_obj_bitfield.c" => 4,
  "ca_obj_block.c" => 1,
  "ca_obj_const_string.c" => 2,
  "ca_obj_meld.c" => 1,
  "ca_obj_select_axis.c" => 5,
  "ca_obj_stack.c" => 1,
  "ca_obj_stride.c" => 1,
  "ca_obj_tile.c" => 1,
  "ca_obj_window.c" => 1,
  "carray_access.c" => 18,
  "carray_element.c" => 1,
  "carray_index_classifier.c" => 13,
  "carray_test.c" => 1,
  "carray_utils.c" => 3,
}.freeze

failures = []
files = Dir.chdir(ROOT) { `git ls-files -- 'ext/*.c' 'ext/*.h' 'ext/*.rb'`.split("\n") }
files.sort.each do |rel|
  name = File.basename(rel)
  n = File.read(File.join(ROOT, rel), encoding: "UTF-8").scrub.scan(/\brb_eIndexError\b/).size
  allowed = COUNTS.fetch(name, 0)
  if n > allowed
    failures << "#{name}: #{n} rb_eIndexError (allowed #{allowed}); check an index with ca_index_in_range(_at) in carray_internal.h"
  elsif n < allowed
    failures << "#{name}: #{n} rb_eIndexError, fewer than the #{allowed} recorded; lower the count in #{File.basename(__FILE__)}"
  end
end

if failures.empty?
  puts "index_error_check: ok"
else
  puts failures
  exit 1
end
