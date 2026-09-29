# Lint: every attach window opened by hand says why it is safe.
#
# Between ca_attach (or ca_allocate) and ca_detach, a raise skips the
# detach and leaves the array attached, with any buffer it materialised.
# A window inside which Ruby can run -- a block, a conversion of the
# caller's value, an object cell's method -- goes through a helper that
# closes it however it is left: ca_attach_window, ca_iter_ensure, or an
# rb_ensure of its own.  This check finds the direct calls
#
#   ca_attach(  ca_allocate(  ca_attach_n(  ca_allocate_n(
#
# and the macros that open one around a block,
#
#   CA_WITH_BUFFER(  CA_WITH_BUFFER_WRITABLE(
#
# and requires each one outside the attach machinery itself to carry a
# note, in a comment on the same line or the line above, of the form
#
#   /* window: <why nothing can leave it open> */
#
# e.g. "window: nothing raises inside" or "window: closed by the rb_ensure
# in foo_run".  Running out of memory is not counted: "nothing raises
# inside" means nothing but a failed allocation.  The machinery is exempt: carray_core.c, which implements
# the windows; the kernel iterator and sweep engines, which close their own
# on the way out; and the operation-table slots of the views
# (*_func_attach, *_func_sync, ...), whose attach is released by the
# matching detach slot.
#
# The generated carray_kernels_*.c are not read; their templates in
# ext/mkkernel.rb are, with the same note (a C comment in the template or a
# Ruby comment next to it).
#
# Run via `rake attach_window_check`, or `ruby utils/check_attach_windows.rb`.

ROOT = File.expand_path("..", __dir__)

CALL = /\b(?:ca_(?:attach|allocate)(?:_n)?|CA_WITH_BUFFER(?:_WRITABLE)?)\s*\(/
NOTE = /window:\s*\S/

EXEMPT_FILES = %w[
  ext/carray_core.c
  ext/ca_kernel_iterator.c
  ext/ca_sweep_engine.c
]

SLOT = /_func_(?:attach|allocate|sync|detach|fill_data|fill_addrs|fill_stride|
                 create_mask|xfer_\w+|copy_data|sync_data)\z/x

# The code of a line with comments and string / character literals taken
# out, and whether a block comment is still open at its end.
def strip_line (line, in_comment)
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
    elsif line[i] == '"' || line[i] == "'"
      q = line[i]
      i += 1
      i += (line[i] == "\\" ? 2 : 1) while i < line.length && line[i] != q
      i += 1
      out << " "
    else
      out << line[i]
      i += 1
    end
  end
  [out, in_comment]
end

def c_sites (path)
  sites = []
  function = nil
  macro    = nil
  depth    = 0
  in_comment = false
  lines = File.readlines(path, encoding: "UTF-8")
  lines.each_with_index do |line, i|
    code, in_comment = strip_line(line, in_comment)
    macro = Regexp.last_match(1) if code =~ /^#\s*define\s+(\w+)/
    in_macro = macro
    macro = nil unless line.rstrip.end_with?("\\")
    function = Regexp.last_match(1) if depth == 0 && code =~ /^([A-Za-z_]\w*)\s*\(/
    if code =~ CALL
      owner = in_macro ? "macro #{in_macro}" : function
      noted = line =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
      sites << [i + 1, owner, line.strip] unless noted || owner.to_s =~ SLOT
    end
    depth += code.count("{") - code.count("}") unless in_macro
  end
  sites
end

def template_sites (path)
  lines = File.readlines(path, encoding: "UTF-8")
  lines.each_with_index.filter_map do |line, i|
    next unless line =~ CALL
    next if line =~ /^\s*#/
    noted = line =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
    [i + 1, "template", line.strip] unless noted
  end
end

offenders = []
Dir.chdir(ROOT) do
  Dir["ext/*.c"].sort.each do |path|
    next if path =~ %r{/carray_kernels_}
    next if EXEMPT_FILES.include?(path)
    c_sites(path).each { |site| offenders << [path, *site] }
  end
  template_sites("ext/mkkernel.rb").each { |site| offenders << ["ext/mkkernel.rb", *site] }
end

if offenders.empty?
  puts "attach_window_check: every hand-opened window carries a note"
  exit 0
end

offenders.each do |path, line, owner, text|
  puts "#{path}:#{line}: [#{owner}] #{text}"
end
puts
puts "attach_window_check: #{offenders.size} window(s) opened without a note."
puts "Run the body through ca_attach_window (or ca_iter_ensure for a kernel"
puts "iterator walk), or, when nothing inside can raise, say so next to the"
puts "call:  /* window: nothing raises inside */"
exit 1
