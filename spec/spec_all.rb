dirname = File.dirname(__FILE__)
# Absolute, and ext/ as well as lib/: a relative entry breaks under the
# Dir.chdir below, and without ext/ the `require` resolves against whatever
# carray gem is installed, which can drift far behind the working tree.
$:.unshift(File.expand_path(File.join(dirname, "..", "ext")))
$:.unshift(File.expand_path(File.join(dirname, "..", "lib")))

require "carray"
# Without the runner the `describe` blocks below are only registered, and this
# script exits 0 having tested nothing.
require "rspec/autorun"
  
Dir.chdir(File.dirname(__FILE__)) {
  Dir["**/*_spec.rb"].sort.each do |file|
    load(file)
  end
}