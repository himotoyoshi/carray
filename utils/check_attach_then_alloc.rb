# Lint: a view's attach / allocate slot does not allocate after attaching
# another array.
#
# A slot that attaches its parent and then allocates a buffer of its own
# raises, when the allocation fails, before it has published ca->ptr.
# ca_attach then has no detach slot to call, so the parent stays attached
# for good: it reads the copy it materialised instead of its root, and
# writes into that copy never reach the root.  The slot allocates first and
# attaches afterwards, freeing the buffer if the attach raises:
# ca_alloc_cells_then_attach (carray_internal.h).
#
# This check reads the functions of ext/*.c whose name ends in _func_attach
# or _func_allocate.  After the first attach of another array in one --
#
#   ca_attach(x)  ca_attach_all(  ca_attach_n(      (x not the view itself)
#
# -- it reports an allocation:
#
#   ca_alloc_cells(  xmalloc(  ALLOC(  ALLOC_N(  ALLOCV  ca_axis_dispatch_attach(
#
# unless it carries a note, in a comment on the same line or the line
# above, of the form
#
#   /* attach: <why the parent is not left attached if it raises> */
#
# The check sees only what the slot itself writes: a helper the slot calls
# after the attach is not read.
#
# Run via `rake attach_then_alloc_check`, or
# `ruby utils/check_attach_then_alloc.rb [paths]`.

ROOT   = File.expand_path("..", __dir__)
SLOT   = /_func_(?:attach|allocate)\z/
ATTACH = /\bca_attach(?:_all|_n)?\s*\(\s*(?!(?:ca|ap|\(CArray\s*\*\)\s*ca)\s*\))/
ALLOC  = /\b(?:ca_alloc_cells|xmalloc|ALLOC|ALLOC_N|ALLOCV\w*|ca_axis_dispatch_attach)\s*\(/
NOTE   = /attach:\s*\S/

# The code of a line with comments taken out, and whether a block comment
# is still open at its end.
def strip_comments (line, in_comment)
  out = +""
  i = 0
  while i < line.length
    if in_comment
      close = line.index("*/", i)
      return [out, true] unless close
      in_comment = false
      i = close + 2
    elsif line[i, 2] == "/*"
      in_comment = true
      i += 2
    elsif line[i, 2] == "//"
      break
    else
      out << line[i]
      i += 1
    end
  end
  [out, in_comment]
end

def sites (path)
  found = []
  lines = File.readlines(path, encoding: "UTF-8")
  function = nil
  attached = false
  depth = 0
  in_comment = false
  lines.each_with_index do |line, i|
    code, in_comment = strip_comments(line, in_comment)
    if depth == 0 && line =~ /^([A-Za-z_]\w*)\s*\(/
      function = Regexp.last_match(1)
      attached = false
    end
    if function.to_s =~ SLOT
      if attached && code =~ ALLOC
        noted = line =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
        found << [i + 1, function, line.strip] unless noted
      end
      attached = true if code =~ ATTACH
    end
    depth += code.count("{") - code.count("}")
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
  puts "attach_then_alloc_check: no attach / allocate slot allocates after attaching"
  exit 0
end

offenders.each { |path, line, fn, text| puts "#{path}:#{line}: [#{fn}] #{text}" }
puts
puts "attach_then_alloc_check: #{offenders.size} allocation(s) after an attach in a slot."
puts "Allocate first: ca->ptr = ca_alloc_cells_then_attach(ca, n, parents),"
puts "or say why the parent is not left attached if it raises:"
puts "  /* attach: ... */"
exit 1
