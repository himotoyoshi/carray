# spec_ai/ext_xfer_smoke/load.rb
#
# Helper that test / bench files require to pull in the xfer_smoke
# extension.  The bundle lives outside ext/ so the main carray_ext
# bundle stays free of test instrumentation; this file centralises the
# carray load + $LOAD_PATH + require so consumers can just
# `require_relative`.

require "carray"   # ensure carray_ext symbols are loaded before xfer_smoke
ext_dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
require "xfer_smoke"
