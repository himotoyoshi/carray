Gem::Specification::new do |s|

  version = "1.4.0"

  files = Dir.glob("**/*") - [ 
                               Dir.glob("carray-*.gem"), 
                               Dir.glob("ext/**/{Makefile,mkmf.log}"),
                               Dir.glob("**/*.{o,so,bundle}"),
                               Dir.glob("**/*~"),
                               Dir.glob("doc/**/*"),
                             ].flatten

  s.platform    = Gem::Platform::RUBY
  s.name        = "carray"
  s.summary     = "Multi-dimesional array class"
  s.description = <<-HERE
    CArray is a uniform multi-dimensional rectangular array class.
    It provides the various types of sub-arrays and references
    pointing the data elements of original array (slice, grid, selection ...).
    Element-wise masking and mathematical operations are natively supported.
  HERE
  s.version     = version
  s.author      = "Hiroki Motoyoshi"
  s.email       = ""
  s.homepage    = 'https://github.com/himotoyoshi/carray'
  s.files       = files
  s.extensions  = [ "extconf.rb" ] + 
                     Dir["ext/*/extconf.rb"].select{|f| File.exist?(f) }
  s.rdoc_options = [
		"-m rdoc_main.rb", 
		"rdoc_main.rb", 
		"rdoc_ext.rb",
		"rdoc_math.rb", 
		"rdoc_stat.rb", 
		Dir.glob("lib/carray/**/*.rb"),
	].flatten
  s.required_ruby_version = ">= 1.8.1"
end

