Gem::Specification::new do |s|

  version = "1.5.0"

  files = Dir.glob("**/*") - [ 
                               Dir.glob("carray-*.gem"), 
                               Dir.glob("ext/**/{Makefile,mkmf.log}"),
                               Dir.glob("**/*.{o,so,bundle}"),
                               Dir.glob("**/*~"),
                               Dir.glob("doc/**/*"),
                             ].flatten

  s.platform    = Gem::Platform::RUBY
  s.name        = "carray"
  s.summary     = "Multi-dimesional array class for Ruby"
  s.description = <<-HERE
    CArray is a uniform multi-dimensional rectangular array class.
    It provides the various types of sub-arrays and references
    pointing the data elements of original array (slice, grid, selection ...).
    Element-wise masking and mathematical operations are natively supported.
  HERE
  s.version     = version
  s.author      = "Hiroki Motoyoshi"
  s.email       = ""
  s.licenses    = ['MIT']
  s.homepage    = 'https://github.com/himotoyoshi/carray'
  s.files       = files
  s.extensions  = [ "extconf.rb" ] 
  s.required_ruby_version = ">= 2.4.0"
end

