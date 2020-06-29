# ----------------------------------------------------------------------------
#
#  carray/autoload.rb
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
      begin
        require "#{library}"
      rescue LoadError
        raise "error in autoloading '#{library}' hooked by method '#{method}', check gem installation."
      end
      #{method}(*argv, &block)
    end
  }
end

class Class
  def autoload_method (method, library)
    class_eval %{
      def #{method} (*argv, &block)
        begin
          require "#{library}"
        rescue LoadError
          raise "error in autoloading '#{library}' hooked by method '#{method}', check gem installation."
        end
        #{method}(*argv, &block)
      end
    }
  end
end

class Module
  def autoload_method (method, library)
    class_eval %{
      def #{method} (*argv, &block)
        begin
          require "#{library}"
        rescue LoadError
          raise "error in autoloading '#{library}' hooked by method '#{method}', check gem installation."
        end
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
        begin
          require "#{library}"
        rescue LoadError
          raise "error in autoloading '#{library}' hooked by method '#{method}', check gem installation."
        end
        #{method}(*argv, &block)
      end
    }
  end
end

module CA

  def self.each_load_path (name) # :nodoc:
    autoload_dirs = $:.clone
    if defined? Gem
      autoload_dirs.push File.expand_path(File.join(__FILE__,"..","..",".."))
      accounted = {}
      Gem::Specification.each do |spec|
        if accounted.has_key?(spec.name)
          next
        end
        if spec.name =~ /carray\-/
          spec.require_paths.each do |path|
            if path !~ /^\//
              path = File.join(spec.full_gem_path, path)
            end
            autoload_dirs.push(path)                
          end
          accounted[spec.name] = true
        end
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

__END__
names = {"carray" => true}
Gem.path.each do |path|
  gems = File.join(path, "gems")
  if File.directory?(gems)
    Dir.chdir(gems) {
      Dir["carray-*"].sort.reverse.each do |dir|
        name = dir.sub(/\-\d+\.\d+\.\d+\z/, '')
        next if names[name]
        lib = File.join(dir, "lib")
        if File.directory?(lib)
          Dir.chdir(lib) {
            Dir["carray/autoload/autoload_*"].each do |loader|
              begin
                load File.expand_path(File.join(gems, dir, lib, loader.sub(/\.rb\z/, "")))
              rescue LoadError
              end
            end
          }
        end
        names[name] = true
      end
    }
  end
end

__END__
CA.each_load_path("carray/autoload") {
  Dir["autoload_*.rb"].each do |basename|
    if basename =~ /\A(autoload_.+)\.rb\Z/
      begin
        require "carray/autoload/" + $1
      rescue LoadError
      end
    end
  end
}

