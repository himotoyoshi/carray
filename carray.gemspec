Gem::Specification::new do |s|

  version = "1.5.4"

  files = Dir.glob("**/*") + [".yardopts"] -
                             [ 
                               Dir.glob("carray-*.gem"), 
                               Dir.glob("ext/**/{Makefile,mkmf.log}"),
                               Dir.glob("**/*.{o,so,bundle}"),
                               Dir.glob("**/*~"),
                               Dir.glob("doc/**/*"),
                               Dir.glob("test/**/*"),
                             ].flatten

  s.platform    = Gem::Platform::RUBY
  s.name        = "carray"
  s.summary     = "Multi-dimesional array class for Ruby"
  s.description = <<-HERE
    Ruby/CArray is an extension library for the multi-dimensional numerical array
    class. The name "CArray" comes from the meaning of a wrapper to a numerical array
    handled by the C language. CArray stores integers or floating-point numbers in
    memory block and treats them collectively to ensure efficient performance.
    Therefore, Ruby/CArray is suitable for numerical computation and data analysis.
  HERE
  s.version     = version
  s.author      = "Hiroki Motoyoshi"
  s.email       = ""
  s.license     = 'MIT'
  s.homepage    = 'https://github.com/himotoyoshi/carray'
  s.files       = files
  s.extensions  = [ "ext/extconf.rb" ] 
  s.required_ruby_version = ">= 2.4.0"
end

