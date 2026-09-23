# spec_ai/test_autoload_stub.rb
#
# `autoload_method "name", "library"` installs a stub that requires the library
# on first call and then forwards to the real definition the library installs.
# If the library installs none, forwarding lands back on the stub, which
# requires the (already loaded) library and forwards again -- until the stack
# gives out, naming neither the method nor the library. A registration whose
# method does not exist is easy to leave behind when the method is removed, and
# `CArray.load_from_file` was one: registered, defined nowhere, documented
# nowhere, and answering SystemStackError.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "tmpdir"
require "carray"

class TestAutoloadStub < Test::Unit::TestCase

  STUB_FILE = File.expand_path("../../lib/carray/autoload_method_extension.rb", __dir__)

  def stub_methods
    found = []
    ObjectSpace.each_object(Class).each do |k|
      next if k.name.nil?     # the throwaway class the next test builds
      next unless (k.singleton_class.include?(AutoloadMethodExtension) rescue false)
      pairs = k.singleton_class.instance_methods(false).map { |m| [k.singleton_class, m, "#{k}.#{m}"] }
      pairs += k.instance_methods(false).map { |m| [k, m, "#{k}##{m}"] }
      pairs.each do |owner, m, label|
        loc = (owner.instance_method(m).source_location rescue nil)
        found << label if loc && File.expand_path(loc[0]) == STUB_FILE
      end
    end
    found
  end

  def test_every_registration_has_something_to_load
    # load everything, then look for a stub still standing: that is a
    # registration whose library never defined the method
    Dir[File.expand_path("../../lib/carray/**/*.rb", __dir__)].sort.each do |f|
      begin
        require f
      rescue Exception                      # a companion gem may be absent
      end
    end
    assert_equal [], stub_methods,
                 "an autoload stub survived loading every library -- its " \
                 "registration names a method the library does not define"
  end

  def test_a_registration_with_nothing_behind_it_says_so
    # the stub cannot know in advance, so it checks after the require: the
    # point is that it names the method and the library rather than recursing
    klass = Class.new do
      extend AutoloadMethodExtension
      autoload_method "self.never_defined", "carray/serialize"
      autoload_method "also_never_defined", "carray/serialize"
    end

    e = assert_raise(NoMethodError) { klass.never_defined }
    assert_match(/self\.never_defined/, e.message)
    assert_match(%r{carray/serialize}, e.message)

    e = assert_raise(NoMethodError) { klass.new.also_never_defined }
    assert_match(/also_never_defined/, e.message)
  end

  def test_a_registration_with_something_behind_it_still_forwards
    assert_equal [1, 2, 3], CArray.load(save_roundtrip).to_a
  end

  def save_roundtrip
    path = File.join(Dir.tmpdir, "carray_autoload_stub_test.ca")
    CArray.save(CA_INT32([1, 2, 3]), path)
    path
  end
end
