# Lint: a Face is put back on a result only through the parts in
# ext/ca_obj_face.c.
#
# rb_ca_face_template builds the new Face struct.  On its own it carries the
# subclass tail but not the mask of the result nor the state a Ruby Face
# keeps in its own variables (copy_state).  ca_face_lift (for a view) and
# ca_face_relift_entity (for a fresh array) do all of it, so every other
# file calls those instead.  This check finds a direct call anywhere else.
#
# The generated carray_kernels_*.c are not read; their templates in
# ext/mkkernel.rb are.
#
# Run via `rake face_template_check`, or `ruby utils/check_face_template.rb`.

ROOT = File.expand_path("..", __dir__)
CALL = /\brb_ca_face_template\s*\(/
ALLOWED = %w[ca_obj_face.c ca_obj_face.h]

files = Dir[File.join(ROOT, "ext", "*.{c,h}")].reject { |f| File.basename(f).start_with?("carray_kernels_") }
files << File.join(ROOT, "ext", "mkkernel.rb")

found = []
files.each do |path|
  next if ALLOWED.include?(File.basename(path))
  File.readlines(path, mode: "rb").each_with_index do |line, i|
    found << "#{path.sub(ROOT + '/', '')}:#{i + 1}: #{line.strip}" if line =~ CALL
  end
end

if found.empty?
  puts "face_template_check: ok"
else
  warn "face_template_check: rb_ca_face_template called outside ext/ca_obj_face.c;"
  warn "use ca_face_lift (a view) or ca_face_relift_entity (a fresh array):"
  found.each { |l| warn "  #{l}" }
  exit 1
end
