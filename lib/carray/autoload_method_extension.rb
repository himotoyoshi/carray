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

# @private
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
    stub = nil
    target.define_method(name) do |*args, **kwargs, &block|
      begin
        require library
      rescue LoadError
        raise "error in autoloading '#{library}' hooked by method " \
              "'#{original_spec}', check gem installation."
      end
      # The require is supposed to have replaced this stub with the real
      # definition. If it has not, the method does not exist anywhere, and
      # forwarding would land straight back here and keep doing so until the
      # stack gave out -- naming neither the method nor the library. Say
      # which, once.
      if target.instance_method(name) == stub
        raise NoMethodError,
              "'#{original_spec}' is registered for autoload from " \
              "'#{library}', but that library defines no such method"
      end
      send(name, *args, **kwargs, &block)
    end
    stub = target.instance_method(name)
    # The library replaces the stub with a plain `def`, which `ruby -w`
    # reports as a redefinition.  Replacing is what the stub is for, so mark
    # it as aliased: Ruby does not warn when the old definition has an alias.
    tmp = :"__autoload_stub_#{name}__"
    target.send(:alias_method, tmp, name)
    target.send(:remove_method, tmp)
  end
end
