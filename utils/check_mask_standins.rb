# Lint: a mask stand-in is made, read and settled only through the parts.
#
# A view whose mask covers a parent with no mask reads an all-false
# stand-in there instead of giving the parent one (a grid with holes, a
# window or shift that masks its out-of-range cells, a stack or meld with
# parts that have no mask).  The rule lives in three parts in
# ext/carray_mask.c, declared in ext/carray_internal.h:
#
#   ca_mask_standin_new      makes the stand-in
#   ca_mask_standin_current  what the mask reads now (gives way to the
#                            parent's own mask once there is one)
#   ca_mask_standin_settle   after a write: a true in the stand-in goes on
#                            to the parent's mask
#
# (ca_multi_parent_mask / _refresh / _settle apply them to each part of a
# stack or meld.)  The three copies these replaced had drifted apart, and
# two of the drifts answered wrongly.  This check refuses, outside
# ext/carray_mask.c:
#
#   - an all-false boolean array made by hand in a create_mask function
#     (carray_new(CA_BOOLEAN, ...) followed by MEMZERO)
#   - a stand-in field assigned anything but ca_mask_standin_new, NULL or
#     the array that holds a stack's stand-ins
#   - a mask view switched to its parent's mask by hand
#     (m->parent = o->parent->mask)
#   - a file that keeps stand-ins but never asks ca_mask_standin_current
#     (or ca_multi_parent_mask_refresh), or never settles
#
# Run via `rake mask_standin_check`, or `ruby utils/check_mask_standins.rb`.

ROOT = File.expand_path("..", __dir__)

STANDIN_FIELD = /\bmask_standins?\b/
ASSIGN        = /\bmask_standins?\b(\[[^\]]*\])?\s*=(?!=)\s*(.*)$/
ALLOWED_RHS   = /\A(ca_mask_standin_new\b|NULL\b|ALLOC_N\(CArray \*)/
HAND_GIVE_WAY = /->parent\s*=\s*\w+->parent->mask\b/
FUNCTION_HEAD = /\A([a-z_][a-z0-9_]*)\s*\(/
COMMENT       = %r{\A\s*(?:/\*|//|\*(?:\s|/|$))}

offenders = []
Dir.chdir(ROOT) do
  Dir["ext/*.c"].sort.each do |path|
    next if path =~ %r{/carray_kernels_|/carray_mask\.c\z}
    lines = File.readlines(path, encoding: "UTF-8")
    function = nil
    new_boolean_at = nil
    lines.each_with_index do |line, i|
      if line =~ FUNCTION_HEAD
        function = $1
        new_boolean_at = nil
      end
      next if line =~ COMMENT
      if function.to_s.include?("create_mask")
        new_boolean_at = i if line =~ /carray_new\s*\(\s*CA_BOOLEAN/
        if new_boolean_at && line =~ /\bMEMZERO\s*\(/ && i - new_boolean_at <= 3
          offenders << [path, i + 1, "an all-false mask made by hand (use ca_mask_standin_new)"]
          new_boolean_at = nil
        end
      end
      if line =~ ASSIGN && $2.strip !~ ALLOWED_RHS
        offenders << [path, i + 1, "a stand-in assigned by hand: #{line.strip}"]
      end
      if line =~ HAND_GIVE_WAY
        offenders << [path, i + 1, "a mask switched to its parent's mask by hand (use ca_mask_standin_current)"]
      end
    end
    text = lines.join
    if text =~ STANDIN_FIELD && text =~ /\bca_mask_standin_new\b|\bca_multi_parent_mask\b/
      unless text =~ /\bca_mask_standin_current\b|\bca_multi_parent_mask_refresh\b/
        offenders << [path, 1, "keeps stand-ins but never asks ca_mask_standin_current"]
      end
      unless text =~ /\bca_mask_standin_settle\b|\bca_multi_parent_mask_settle\b/
        offenders << [path, 1, "keeps stand-ins but never settles a write (ca_mask_standin_settle)"]
      end
    end
  end
end

if offenders.empty?
  puts "mask_standin_check: every mask stand-in goes through the parts"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "mask_standin_check: #{offenders.size} place(s) handle a mask stand-in by hand."
puts "Use ca_mask_standin_new / ca_mask_standin_current / ca_mask_standin_settle"
puts "(ext/carray_internal.h)."
exit 1
