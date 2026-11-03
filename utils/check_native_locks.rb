# Lint: a native lock is waited for without the GVL, and nothing allocates
# or runs Ruby while it is held unless a note says why that is safe.
#
# The tables CArray shares between Ractors are guarded by native locks.  A
# Ractor that waits for one while it holds its GVL cannot stop for a GC, so
# a holder that allocates (and so may start a GC) waits for it, and it for
# the lock.  A GC run while the lock is held can also reach code that takes
# the same lock (a view's free), which then waits on its own thread.
#
# This check finds
#
#   - a lock taken directly, with rb_native_mutex_lock /
#     rb_nativethread_lock_lock / pthread_mutex_lock, rather than through
#     ca_native_lock_without_gvl (carray_internal.h);
#   - between taking a lock and releasing it in the same function, a call
#     that can allocate or run Ruby (rb_*, st_insert and the other st_*
#     calls that grow a table, xmalloc, ALLOC);
#
# and requires each to carry a note, in a comment on the same line or the
# line above, of the form
#
#   /* lock: <why this cannot deadlock> */
#
# The generated carray_kernels_*.c are not read.
#
# Run via `rake native_lock_check`, or `ruby utils/check_native_locks.rb`.
# Given paths (files, or directories searched for *.c), it checks those
# instead.

ROOT = File.expand_path("..", __dir__)

DIRECT  = /\b(?:rb_native_mutex_lock|rb_nativethread_lock_lock|pthread_mutex_lock)\s*\(/
TAKE    = /\b(?:ca_native_lock_without_gvl|rb_native_mutex_trylock|rb_native_mutex_lock|rb_nativethread_lock_lock|pthread_mutex_lock)\s*\(\s*&?\s*(\w+)\s*\)/
RELEASE = /\b(?:rb_native_mutex_unlock|rb_nativethread_lock_unlock|pthread_mutex_unlock)\s*\(\s*&?\s*(\w+)\s*\)/
WORK    = /\b(?:rb_\w+|st_(?:insert|add_direct|update|init\w*)|xmalloc\w*|xcalloc|xrealloc\w*|ruby_xmalloc\w*|ALLOC\w*)\s*\(/
QUIET   = /\b(?:rb_native_mutex_\w+|rb_nativethread_lock_\w+)\s*\(/
NOTE    = /lock:\s*\S/

def noted? (lines, i)
  lines[i] =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
end

def comment? (line)
  line =~ %r{^\s*(?:/\*|//|\*(?:\s|/|$))}
end

def sites (path)
  lines = File.readlines(path, encoding: "UTF-8")
  found = []
  held  = nil                      # [lock name, line index it was taken]
  lines.each_with_index do |line, i|
    next if comment?(line)
    held = nil if line =~ /^\}/
    if line =~ DIRECT && !noted?(lines, i)
      found << [i + 1, "taken with the GVL held: #{line.strip}"]
    end
    if (m = line.match(TAKE))
      held = [m[1], i]
      next
    end
    if held && (m = line.match(RELEASE)) && m[1] == held[0]
      held = nil
      next
    end
    next unless held
    if line.gsub(QUIET, "") =~ WORK && !noted?(lines, i) && !noted?(lines, held[1])
      found << [i + 1, "under #{held[0]}: #{line.strip}"]
    end
  end
  found
end

paths =
  if ARGV.empty?
    Dir.chdir(ROOT) { Dir["ext/*.c"].sort.reject { |p| p =~ %r{/carray_kernels_} } }
       .map { |p| File.join(ROOT, p) }
  else
    ARGV.flat_map { |arg| File.directory?(arg) ? Dir[File.join(arg, "**", "*.c")].sort : [arg] }
  end

offenders = paths.flat_map { |path| sites(path).map { |site| [path.sub("#{ROOT}/", ""), *site] } }

if offenders.empty?
  puts "native_lock_check: every native lock is waited for without the GVL, and what runs under it says why"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "native_lock_check: #{offenders.size} place(s) where a native lock can deadlock with a GC."
puts "Take the lock with ca_native_lock_without_gvl, and move allocation and Ruby"
puts "calls out of the locked stretch, or say why they cannot deadlock:"
puts "  /* lock: a GC run here does not take this lock */"
exit 1
