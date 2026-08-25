require 'carray'
require "rspec-power_assert"

# 3.0 breaking: CArray.span retired in commit 372e353 (2026-06-09).
# Migration: CA_<TYPE>(range, step) via the cast Range branch.
describe "CA_FLOAT32(range, step)" do

  # 2020-07-22 (migrated 2026-06-10)
  example "span via cast" do
    a = CA_FLOAT32(0..2, 0.5)
    is_asserted_by { a == CA_FLOAT32([0, 0.5, 1, 1.5, 2]) }
    a = CA_FLOAT32(0...2, 0.5)
    is_asserted_by { a == CA_FLOAT32([0, 0.5, 1, 1.5]) }
  end

end
