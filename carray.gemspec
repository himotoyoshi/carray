Gem::Specification.new do |s|
  s.name        = "carray"
  s.version     = "3.0.0"
  s.authors      = ["himotoyoshi"]
  s.email       = ["himotoyoshi@users.noreply.github.com"]
  s.summary     = "Multi-dimesional array class for Ruby"
  s.description = <<-HERE
    Ruby/CArray is an extension library for the multi-dimensional numerical array
    class. The name "CArray" comes from the meaning of a wrapper to a numerical array
    handled by the C language. CArray stores integers or floating-point numbers in
    memory block and treats them collectively to ensure efficient performance.
    Therefore, Ruby/CArray is suitable for numerical computation and data analysis.
  HERE
  s.homepage    = "https://github.com/himotoyoshi/carray"
  s.license     = "MIT"
  s.platform    = Gem::Platform::RUBY
  s.required_ruby_version = ">= 3.0"
  s.files       = [
    *Dir.glob("lib/**/*.rb"),
    *(Dir.glob("ext/*.c") - %w[ext/carray_kernels.c ext/carray_cast_func.c ext/carray_math.c]),
    *Dir.glob("ext/*.h"),
    *Dir.glob("ext/*.rb"),
    "LICENSE",
    "README.md",
    "NEWS.md",
    "CHANGELOG.md",
    ".yardopts",
    "carray.gemspec",
  ].select { |f| File.file?(f) }
  s.extensions  = ["ext/extconf.rb"]
  s.require_paths = ["lib", "ext"]
end
