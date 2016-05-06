# ----------------------------------------------------------------------------
#
#  version.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

def carray_version

  io = open(File.join(File.dirname(__FILE__), "version.h"))
  while line = io.gets
    case line 
    when /^#define CA_VERSION (.*)$/
      ca_version = $1.strip[1..-2]
    when /^#define CA_VERSION_CODE (.*)$/
      ca_version_code = $1.to_i
    when /^#define CA_VERSION_MAJOR (.*)$/
      ca_version_major = $1.to_i
    when /^#define CA_VERSION_MINOR (.*)$/
      ca_version_minor = $1.to_i
    when /^#define CA_VERSION_TEENY (.*)$/
      ca_version_teeny = $1.to_i
    when /^#define CA_VERSION_DATE (.*)$/
      ca_version_date = $1.strip[1..-2]
    end
  end
  io.close

  ca_version2 = format("%i.%i.%i", 
                       ca_version_major, ca_version_minor, ca_version_teeny)
  ca_version_code2 = 
            100 * ca_version_major + 10*ca_version_minor + ca_version_teeny

  if ca_version != ca_version2 or ca_version_code != ca_version_code2
    raise "invalid version.h"
  end
  
  return [ca_version, ca_version_date]
end


if __FILE__ == $0
  
  version, date = carray_version()
  puts version
  
end


