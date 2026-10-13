# Lint: a view's setup does not ask its parent for a mask.
#
# Asking whether an array has a mask, or making it, runs Ruby when the
# array is a CAObject, and the answer can raise.  A view's setup runs on a
# struct that no Ruby object owns yet, so a raise there loses the struct
# and everything the setup allocated.  The constructor asks afterwards,
# under ca_fill_or_free: ca_view_inherit_mask (carray_internal.h).
#
# This check reads the functions of ext/*.c whose name ends in
# _setup, _setup_view or _setup_i and reports a call of
#
#   ca_has_mask(   ca_create_mask(   ca_update_mask(   ca_setup_mask(
#
# unless it carries a note, in a comment on the same line or the line
# above, of the form
#
#   /* mask: <why nothing is lost if it raises> */
#
# e.g. "mask: checked before the struct is allocated".
#
# Run via `rake view_setup_mask_check`, or
# `ruby utils/check_view_setup_mask.rb [paths]`.

ROOT = File.expand_path("..", __dir__)
CALL = /\bca_(?:has|create|update|setup)_mask\s*\(/
NOTE = /mask:\s*\S/
SETUP = /\A\w+_setup(?:_view|_i)?\z/

def sites (path)
  found = []
  lines = File.readlines(path, encoding: "UTF-8")
  function = nil
  depth = 0
  lines.each_with_index do |line, i|
    function = Regexp.last_match(1) if depth == 0 && line =~ /^([A-Za-z_]\w*)\s*\(/
    if function.to_s =~ SETUP && line =~ CALL && line !~ %r{^\s*(?:/\*|//|\*(?:\s|/|$))}
      noted = line =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
      found << [i + 1, function, line.strip] unless noted
    end
    depth += line.count("{") - line.count("}")
  end
  found
end

paths =
  if ARGV.empty?
    Dir[File.join(ROOT, "ext", "*.c")].sort.reject { |p| p =~ %r{/carray_kernels_} }
  else
    ARGV.flat_map { |a| File.directory?(a) ? Dir[File.join(a, "**", "*.c")].sort : [a] }
  end

offenders = paths.flat_map { |p| sites(p).map { |s| [p.sub("#{ROOT}/", ""), *s] } }

if offenders.empty?
  puts "view_setup_mask_check: no view setup asks its parent for a mask"
  exit 0
end

offenders.each { |path, line, fn, text| puts "#{path}:#{line}: [#{fn}] #{text}" }
puts
puts "view_setup_mask_check: #{offenders.size} call(s) in a view setup."
puts "Ask after the setup, in the constructor, under ca_fill_or_free"
puts "(ca_view_inherit_mask), or say why nothing is lost if it raises:"
puts "  /* mask: checked before the struct is allocated */"
exit 1
