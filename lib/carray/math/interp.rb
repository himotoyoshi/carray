# ----------------------------------------------------------------------------
#
#  carray/math/interp.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require "carray"

class CA::Interp

  ADAPTERS = {}

  def initialize (type, scales, value, options={})
    adapter_class = ADAPTERS[type]
    if adapter_class
      @type    = type
      @adapter = adapter_class.new(scales, value, options)
    else
      raise RuntimeError, "unknown interp adapter <#{type}>"
    end
  end

  def [] (*args)
    return @adapter.evaluate(*args)
  end

  def method_missing (id, *args)
    return @adapter.send(id, *args)
  end

end

class CA::Interp::Adapter # :nodoc:

  def self.install_adapter (name)
    CA::Interp::ADAPTERS[name] = self
  end
  
end

def CA.interp (*argv)
  return CA::Interp.new(*argv)
end

CA.each_load_path("carray/math/interp") {
  Dir["adapter_*.rb"].each do |basename|
    if basename =~ /\A(adapter_.+)\.rb\Z/
      require "carray/math/interp/" + $1
    end
  end
}
