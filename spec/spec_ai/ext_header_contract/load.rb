# spec_ai/ext_header_contract/load.rb
#
# Loads the header_contract extension, which calls the public C surface
# of carray.h from outside the carray build.

require "carray"
ext_dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
require "header_contract"
