Gem::Specification::new do |s|

  version = "1.5.2"

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
    Ruby/CArray is an extension library for the multi-dimensional array class.
    CArray can store integers and floating point numbers to perform calculations
    efficiently. Therefore, Ruby/CArray is suitable for numerical computation and data
    analysis. Ruby/CArray has different features from other multidimensional array
    libraries (narray, numo-narray, nmatrix), such as element-wise masks, 
    creation of reference arrays that can reflect changes to the referent, 
    the ability to access memory pointers of other objects, user-defined arrays,
    and so on.
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

