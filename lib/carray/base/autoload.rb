# ----------------------------------------------------------------------------
#
#  carray/base/autoload.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005-2010  Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

def autoload_method (method, library)
  eval %{
    def #{method} (*argv, &block)
      require "#{library}"
      #{method}(*argv, &block)
    end
  }
end

class Class
  def autoload_method (method, library)
    class_eval %{
      def #{method} (*argv, &block)
        require "#{library}"
        #{method}(*argv, &block)
      end
    }
  end
end

class Module
  def autoload_method (method, library)
    class_eval %{
      def #{method} (*argv, &block)
        require "#{library}"
        #{method}(*argv, &block)
      end
    }
  end
end

class Module
  def autoload_module_function (method, library)
    class_eval %{
      module_function
      def #{method} (*argv, &block)
        require "#{library}"
        #{method}(*argv, &block)
      end
    }
  end
end

module CA

  def self.each_load_path (name) # :nodoc:
    autoload_dirs = $:.clone
    if defined? Gem
      if Gem::VERSION >= "1.7.0"
        begin
          Gem::Specification.each do |spec|
            if spec.name =~ /carray/
              autoload_dirs.push(spec.full_gem_path)
            end
          end
        rescue Gem::LoadError
        end
      else
        autoload_dirs.push(*Gem.all_load_paths.grep(/carray/))
      end
    end
    autoload_dirs.each do |path|
      dir = File.join(path, name)
      if File.directory?(dir)
        Dir.chdir(dir) {
          yield
        }
      end
    end
  end

end

CA.each_load_path("carray/autoload") {
  Dir["autoload_*.rb"].each do |basename|
    if basename =~ /\A(autoload_.+)\.rb\Z/
      require "carray/autoload/" + $1
    end
  end
}

undef autoload_method
