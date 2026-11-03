# Lint: a VALUE whose CArray * is taken stays alive while the pointer is used.
#
# GetCArray (or TypedData_Get_Struct) gives a pointer into an object the GC
# owns.  When the VALUE is not used again, the compiler need not keep it, and
# a collection run by a later allocation or Ruby call can free the array
# while the pointer is still read.  This check finds, in each function, a
# VALUE that is assigned there and read with GetCArray, whose pointer is used
# after the VALUE's last appearance with a call in between that can allocate
# or run Ruby.  Such a VALUE is declared `volatile VALUE`, or guarded with
# RB_GC_GUARD after the pointer's last use, or carries a note, in a comment
# on the GetCArray line or the line above, of the form
#
#   /* gc: <what holds the array> */
#
# e.g. "gc: held by the caller's frame" or "gc: in the cols Array".  The
# receiver and the arguments of a method Ruby calls are on the VM stack and
# are not checked; a parameter of any other C function is, since its caller
# may have passed a VALUE it made and holds nowhere.
#
# The generated carray_kernels_*.c are not read.
#
# Run via `rake gc_hold_check`, or `ruby utils/check_gc_holds.rb`.  Given
# paths (files, or directories searched for *.c), it checks those instead --
# a C extension built on carray can run it on its own sources.

require "set"

ROOT = File.expand_path("..", __dir__)

GET  = /\b(?:GetCArray|TypedData_Get_Struct|Data_Get_Struct)\s*\(\s*(\w+)\s*,\s*(?:\w+\s*,\s*[^,]+,\s*)?(\w+)(?:\s*\[[^\]]*\])?\s*\)/
# A method Ruby calls has its arguments on the VM stack; a plain C function
# can be handed a VALUE that nothing else holds.
DEFINE = /\brb_define_(?:\w+_)?(?:method|function)\w*\s*\([^;]*?,\s*"[^"]*"\s*,\s*(?:RUBY_METHOD_FUNC\s*\()?\s*(\w+)/
CALL = /\b(?:rb_\w+|ca_\w+|xmalloc\w*|xcalloc|xrealloc\w*|ALLOC\w*|ruby_xmalloc\w*)\s*\(/
NOGC = /\b(?:rb_raise|rb_bug|ca_is_\w+|ca_test_flag|ca_has_\w+|ca_length|RB_GC_GUARD)\b/
NOTE = /gc:\s*\S/

def blank (text)
  text.gsub(/[^\n]/, " ")
end

# Comments and string contents blanked out, offsets kept.
def code_of (src)
  src.gsub(%r{/\*.*?\*/}m) { |c| blank(c) }
     .gsub(%r{//[^\n]*}) { |c| blank(c) }
     .gsub(/"(?:\\.|[^"\\])*"/) { |c| '"' + " " * (c.size - 2) + '"' }
end

# [name, start, finish] of each top-level brace block that follows a
# parameter list.
def functions (code)
  out = []
  depth = 0
  start = nil
  code.each_char.with_index do |ch, i|
    if ch == "{"
      start = i if depth == 0
      depth += 1
    elsif ch == "}"
      depth -= 1
      if depth == 0 && start
        name = code[[0, start - 300].max...start][/(\w+)\s*\([^;{}]*\)\s*\z/m, 1]
        out << [name, start, i] if name
        start = nil
      end
    end
  end
  out
end

# Whether text declares v volatile, alone or in a list such as
# `volatile VALUE a, v = x, b;`.
def volatile_decl? (text, v)
  text.scan(/\bvolatile\s+VALUE\s+([^;{}]*)/m).any? do |(list)|
    depth = 0
    parts = [+""]
    list.each_char do |ch|
      depth += 1 if ch == "("
      depth -= 1 if ch == ")"
      break if depth < 0
      if ch == "," && depth == 0 then parts << +"" else parts[-1] << ch end
    end
    parts.any? { |d| d =~ /\A\s*(?:volatile\s+)?(?:VALUE\s+)?\**#{v}\b/ }
  end
end

def sites (path, methods)
  src   = File.read(path, encoding: "UTF-8").scrub
  code  = code_of(src)
  lines = src.lines
  found = []
  functions(code).each do |name, s, e|
    body   = code[s..e]
    params = code[[0, s - 300].max...s][/\b#{name}\s*\((.*)\)\s*\z/m, 1].to_s
    body.scan(GET) do |v, p|
      at = $~.begin(0)
      next if v == "self" && params =~ /\bVALUE\s+self\b/
      next if methods.include?(name) && params =~ /\bVALUE\s+\**#{v}\b/
      next unless body =~ /\b#{v}\s*=(?!=)/ || params =~ /\bVALUE\s+\**#{v}\b/
      next if volatile_decl?(body, v) || volatile_decl?(params, v) || body =~ /RB_GC_GUARD\s*\(\s*#{v}\s*\)/
      last_v = body.enum_for(:scan, /\b#{v}\b/).map { $~.begin(0) }.max
      last_p = body.enum_for(:scan, /\b#{p}\b/).map { $~.begin(0) }.max
      # A pointer stored into a struct is used through it until the end.
      last_p = body.size - 1 if body =~ /[\w\]](?:\.|->)\w+\s*=\s*&?#{p}\b/
      next unless last_p && last_p > last_v
      next unless body[last_v...last_p].gsub(NOGC, "") =~ CALL
      line = src[0, s + at].count("\n") + 1
      next if lines[line - 1] =~ NOTE || (line > 1 && lines[line - 2] =~ NOTE)
      found << [line, "#{name}: #{v} -> #{p}"]
    end
  end
  found.uniq
end

paths =
  if ARGV.empty?
    Dir.chdir(ROOT) { Dir["ext/*.c"].sort.reject { |p| p =~ %r{/carray_kernels_} } }
       .map { |p| File.join(ROOT, p) }
  else
    ARGV.flat_map { |arg| File.directory?(arg) ? Dir[File.join(arg, "**", "*.c")].sort : [arg] }
  end

methods = Dir[File.join(ROOT, "ext", "*.c")].flat_map { |f|
  File.read(f, encoding: "UTF-8").scrub.scan(DEFINE).flatten
}.to_set
offenders = paths.flat_map { |path| sites(path, methods).map { |site| [path.sub("#{ROOT}/", ""), *site] } }

if offenders.empty?
  puts "gc_hold_check: every VALUE read into a CArray * is held while the pointer is used"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "gc_hold_check: #{offenders.size} VALUE(s) may be collected while their CArray * is still used."
puts "Declare the VALUE volatile, put RB_GC_GUARD(v) after the pointer's last use,"
puts "or say what holds the array:"
puts "  /* gc: held by the caller's frame */"
exit 1
