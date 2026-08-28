# Mixin that adds a small `autoload_method` DSL to a class:
#
#   class Foo
#     extend AutoloadMethodExtension
#     autoload_method "self.bar", "libfoo"   # singleton method stub
#     autoload_method "baz",      "libfoo"   # instance method stub
#   end
#
# Each stub requires `library` on first call; after the require, the
# real definition (which the library must install) replaces the stub
# and the original call is forwarded.
#
# Defined at the top level instead of nested under CArray so companion
# gems can extend their own classes with the same DSL.  Module-wide
# monkey patching is avoided -- only classes that explicitly `extend
# AutoloadMethodExtension` gain the method.

module AutoloadMethodExtension
  # @!visibility private
  def autoload_method (method, library)
    if method.to_s =~ /\Aself\.(.+)\z/
      name   = $1.to_sym
      target = singleton_class
    else
      name   = method.to_sym
      target = self
    end
    autoload_define(target, name, library, method)
  end

  private

  def autoload_define (target, name, library, original_spec)
    target.define_method(name) do |*args, **kwargs, &block|
      begin
        require library
      rescue LoadError
        raise "error in autoloading '#{library}' hooked by method " \
              "'#{original_spec}', check gem installation."
      end
      send(name, *args, **kwargs, &block)
    end
  end
end
