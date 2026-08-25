require "mkmf"

unless have_header("ruby/memory_view.h")
  raise "ruby/memory_view.h not found"
end

create_makefile("mv_borrower")
