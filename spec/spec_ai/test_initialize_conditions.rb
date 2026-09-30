# spec_ai/test_initialize_conditions.rb
#
# ca_check_uninitialized refuses a second `initialize` / `initialize_copy`
# by reading the struct's dim: NULL means the struct owns nothing yet.
# That reading is right only while every array class keeps three
# conditions (stated at the helper in ext/carray_test.c).  Two of them are
# properties of the C source, so they are checked here by reading it; the
# third is checked by running (test_reinitialize_refused.rb).
#
#   1. The allocator zero-fills the struct: it is TypedData_Make_Struct,
#      or it refuses to allocate.  An allocator that left the struct as
#      malloc returned it would make `new` raise at random.
#   2. Every `initialize` / `initialize_copy` of an array class calls
#      ca_check_uninitialized on self's struct before it takes the pool,
#      allocates, or runs a setup.
#
# A new array class is picked up by the scan; nothing has to be added here.

require "test/unit"

class TestInitializeConditions < Test::Unit::TestCase

  EXT = File.expand_path("../../ext", __dir__)

  SOURCES = Dir[File.join(EXT, "*.c")]
              .reject { |f| File.basename(f).start_with?("carray_kernels_") }
              .to_h { |f| [File.basename(f), File.read(f, encoding: "UTF-8").scrub] }

  # `initialize` of classes that are not arrays: their struct is not a
  # CArray and has no dim.
  NOT_ARRAYS = {
    "rb_ca_time_element_initialize"      => "CATime::Element, a scalar value object",
    "rb_ca_timedelta_element_initialize" => "CATimedelta::Element, a scalar value object",
    "rb_ca_struct_initialize"            => "a CAStruct record, backed by a CScalar it builds",
    "rb_ca_rng_initialize"               => "CARng, a generator state",
  }

  # The body of the function +name+ defined in +text+ (from its opening
  # brace to the closing brace in column 0).
  def function_body (text, name)
    m = text.match(/^#{Regexp.escape(name)} \([^)]*\)\n\{\n(.*?)^\}\n/m)
    m && m[1]
  end

  def each_registration (pattern)
    SOURCES.each do |file, text|
      text.scan(pattern) { yield file, text, Regexp.last_match }
    end
  end

  def test_allocators_zero_fill_or_refuse
    seen = 0
    each_registration(/rb_define_alloc_func\(\s*\w+,\s*(\w+)\s*\)/) do |file, text, m|
      name = m[1]
      body = function_body(text, name)
      assert_not_nil body, "#{file}: cannot find the allocator #{name}"
      seen += 1
      zero_filled = body.include?("TypedData_Make_Struct")
      refuses     = body.include?("rb_raise") && !body.match?(/ALLOC|xmalloc/)
      assert zero_filled || refuses,
             "#{file}: #{name} neither builds its struct with " \
             "TypedData_Make_Struct nor refuses to allocate"
    end
    assert_operator seen, :>=, 30, "the scan found too few allocators to be trusted"
  end

  TAKES = /ca_array_pool_alloc|\bALLOC(?:_N|V_N)?\s*\(|xmalloc|\w+_setup\w*\s*\(/

  def test_initialize_checks_before_it_takes_anything
    seen = 0
    each_registration(/rb_define_method\(\s*\w+,\s*"initialize(?:_copy)?",\s*(\w+)\s*,/) do |file, text, m|
      name = m[1]
      next if NOT_ARRAYS.key?(name)
      body = function_body(text, name)
      assert_not_nil body, "#{file}: cannot find #{name}"
      seen += 1
      check = body.index(/ca_check_uninitialized\s*\(/)
      assert_not_nil check, "#{file}: #{name} does not call ca_check_uninitialized"
      takes = body.index(TAKES)
      assert takes.nil? || check < takes,
             "#{file}: #{name} takes memory or runs a setup before ca_check_uninitialized"
    end
    assert_operator seen, :>=, 40, "the scan found too few initializers to be trusted"
  end

  def test_the_exempt_list_names_real_functions
    all = SOURCES.values.join
    NOT_ARRAYS.each_key do |name|
      assert_match(/^#{name} \(/, all, "#{name} is exempted but no longer exists")
    end
  end

end
