# Check: no method named like `__x__` appears unless it is on the list.
#
# Ruby marks a method internal with `private` / `protected`, not with its
# name.  Underscores around a name hide nothing, and they make a vague name
# look acceptable.  carray keeps such names only where `private` cannot do
# the job and the user allowed it, each named for what it does.  The list is
# utils/dunder_methods.txt; a method that is not on it fails this check, and
# so does a line on it that names no method.
#
# The check loads the built extension and every file under lib/carray, so
# the methods defined on first use (autoload_carray) and the ones generated
# at load time are seen as well.  A method counts when carray adds it: the
# names already present in a plain Ruby process are left out.
#
# Run via `rake dunder_method_check` (after `rake build_ext`), or
#   ruby -Iext -Ilib utils/check_dunder_methods.rb

ROOT = File.expand_path("..", __dir__)
LIST = File.join(ROOT, "utils", "dunder_methods.txt")
NAME = /\A__.+__[?!=]?\z/

def dunder_methods
  found = []
  ObjectSpace.each_object(Module) do |mod|
    owner = mod.name or next
    [[mod, "#"], [mod.singleton_class, "."]].each do |host, sep|
      (host.public_instance_methods(false) +
       host.protected_instance_methods(false) +
       host.private_instance_methods(false)).each do |m|
        found << "#{owner}#{sep}#{m}" if m.to_s.match?(NAME)
      end
    end
  end
  found.uniq
end

before = dunder_methods

require "carray"
unless $LOADED_FEATURES.grep(/carray_ext/).first.to_s.start_with?(ROOT)
  abort "check_dunder_methods: run with -Iext -Ilib from #{ROOT} (loaded #{$LOADED_FEATURES.grep(/carray_ext/).first})"
end
Dir[File.join(ROOT, "lib", "carray", "**", "*.rb")].sort.each do |f|
  next if f.end_with?("/mkmf.rb")
  begin
    require f
  rescue LoadError
    # A file that needs an optional gem; its methods are not checked here.
  end
end

dev_build = CArray.method_defined?(:__attach__)
found = dunder_methods - before

allowed = {}
# A line is "Owner#name" or "Owner.name", then "dev" for a method that only
# a development build defines.  A line starting with "#" is a comment ("#"
# inside a key is the instance-method separator, so comments take a line).
File.foreach(LIST) do |line|
  next if line.strip.empty? || line.lstrip.start_with?("#")
  key, *flags = line.split
  allowed[key] = flags.include?("dev")
end

unlisted = found.reject { |k| allowed.key?(k) }.sort
missing  = allowed.reject { |k, dev| found.include?(k) || (dev && !dev_build) }.keys.sort

unless unlisted.empty? && missing.empty?
  unless unlisted.empty?
    warn "Methods named __x__ that are not on #{File.basename(LIST)}:"
    unlisted.each { |k| warn "  #{k}" }
    warn "Make the method private or protected with an ordinary name.  A name"
    warn "like this is kept only where private cannot hide it, and only once"
    warn "the user has allowed it."
  end
  unless missing.empty?
    warn "Lines on #{File.basename(LIST)} that name no method:"
    missing.each { |k| warn "  #{k}" }
  end
  exit 1
end
puts "dunder methods: #{found.size}, all on #{File.basename(LIST)}"
