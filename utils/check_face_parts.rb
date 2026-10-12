# Lint: the rules that decide how a Face meets another array live in one
# place, ext/ca_obj_face.c, and every other file calls the parts there.
#
# - A Face is put back on a result only through ca_face_lift (a view) or
#   ca_face_relift_entity (a fresh array).  rb_ca_face_template on its own
#   carries the subclass tail but not the mask of the result nor the state a
#   Ruby Face keeps in its own variables (copy_state).
# - An operand is brought into a Face's storage space only through
#   ca_face_reconcile_operand, which decides for every family which operands
#   a Face takes (its own record class, a COMPARABLE Face, its to_comparable)
#   and refuses the rest.  A direct to_comparable call or
#   ca_face_operand_descend elsewhere is a second copy of that rule; Ruby
#   reaches the part through __reconcile_operand__.
# - The storage under a Face is found by ca_strip_face (C) or
#   __face_storage__ (Ruby).  A loop of its own that walks the parents is a
#   second copy, and the first place one goes wrong when a Face gains a
#   wrapper of a different kind.
# - In Ruby, an empty array of a Face's kind is __blank_like__, and a value is
#   written into a Face by storing the Face, not by writing its storage.
#
# The generated carray_kernels_*.c are not read; their templates in
# ext/mkkernel.rb are.
#
# Run via `rake face_parts_check`, or `ruby utils/check_face_parts.rb`.

ROOT = File.expand_path("..", __dir__)
ALLOWED = %w[ca_obj_face.c ca_obj_face.h]

RULES = [
  [/\brb_ca_face_template\s*\(/,
   "rb_ca_face_template: use ca_face_lift (a view) or ca_face_relift_entity (a fresh array)"],
  [/\bca_face_operand_descend\s*\(/,
   "ca_face_operand_descend: use ca_face_reconcile_operand"],
  [/\brb_funcall\w*\s*\([^;]*?"to_comparable"/m,
   "to_comparable called directly: use ca_face_reconcile_operand"],
  [/\bwhile\s*\(\s*\w+\s*&&\s*ca_is_face\s*\(\s*\w+\s*\)\s*\)|\bwhile\s*\(\s*ca_face_safe_check\s*\(/,
   "a hand loop down to the storage: use ca_strip_face"],
]

RUBY_RULES = [
  [/\.parent\s+while\s+\w+\.face\?/,
   "a hand loop down to the storage: use __face_storage__"],
  [/CArray\.new\([^)]*\)\s*\.face_lift\(/m,
   "a blank Face built by hand: use __blank_like__"],
  [/(?:\.|\b)parent(\.value)?\[[^\]]*\]\s*=(?!=)/,
   "a write into a Face's storage: store the Face (a Face of its own class is taken as it is)"],
]

files = Dir[File.join(ROOT, "ext", "*.{c,h}")].reject { |f| File.basename(f).start_with?("carray_kernels_") }
files << File.join(ROOT, "ext", "mkkernel.rb")

found = []
files.each do |path|
  next if ALLOWED.include?(File.basename(path))
  text = File.binread(path)
  RULES.each do |re, hint|
    text.scan(re) do
      pos = Regexp.last_match.begin(0)
      line = text[0, pos].count("\n") + 1
      found << "#{path.sub(ROOT + '/', '')}:#{line}: #{hint}"
    end
  end
end

Dir[File.join(ROOT, "lib", "**", "*.rb")].each do |path|
  text = File.binread(path)
  RUBY_RULES.each do |re, hint|
    text.scan(re) do
      pos = Regexp.last_match.begin(0)
      line = text[0, pos].count("\n") + 1
      found << "#{path.sub(ROOT + '/', '')}:#{line}: #{hint}"
    end
  end
end

if found.empty?
  puts "face_parts_check: ok"
else
  warn "face_parts_check: a Face rule written outside ext/ca_obj_face.c:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
