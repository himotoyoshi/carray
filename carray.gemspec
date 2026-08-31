Gem::Specification.new do |s|
  s.name        = "carray"
  s.version     = "3.0.1"
  s.authors      = ["himotoyoshi"]
  s.email       = ["himotoyoshi@users.noreply.github.com"]
  s.summary     = "Multi-dimensional numerical array class for Ruby"
  s.description = <<-HERE
    Ruby/CArray adds multi-dimensional numerical arrays to Ruby. Elements are held
    in a single flat memory block, so whole-array work -- element-wise arithmetic,
    reductions along any axis, sorting, searching -- runs in C. Slicing, transposing,
    reshaping, and selecting by a boolean condition all return views that share
    storage with the original array and can be chained freely; nothing is copied
    until you ask for a copy. Any array, view included, can carry a mask marking
    individual elements as undefined, and arrays are exchanged with other numerical
    libraries without copying through Ruby's MemoryView protocol.
  HERE
  s.homepage    = "https://github.com/himotoyoshi/carray"
  s.license     = "MIT"
  s.platform    = Gem::Platform::RUBY
  s.required_ruby_version = ">= 3.0"
  s.files       = [
    *Dir.glob("lib/**/*.rb"),
    *Dir.glob("yard-stubs/**/*.rb"),
    *(Dir.glob("ext/*.c") - %w[ext/carray_kernels.c ext/carray_cast_func.c ext/carray_math.c]),
    *Dir.glob("ext/*.h"),
    *Dir.glob("ext/*.rb"),
    "LICENSE",
    "README.md",
    "CHANGELOG.1.0-2.0.md",
    "CHANGELOG.md",
    ".yardopts",
    "carray.gemspec",
  ].select { |f| File.file?(f) }
  s.extensions  = ["ext/extconf.rb"]
  s.require_paths = ["lib", "ext"]
end
