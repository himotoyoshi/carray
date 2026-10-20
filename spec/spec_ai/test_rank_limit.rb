# frozen_string_literal: true
#
# An array has at most CA_RANK_MAX axes, and every dim[] in the library is
# that long.  A shape given or a rank computed past it is refused with
# ArgumentError, "<method>: ndim <n> exceeds CA_RANK_MAX <max>", before a
# single dim is written.
#
# Two entries wrote past it.  A Ruby Array nested one level deeper than
# CA_RANK_MAX was measured into a dim[] one short, over the stack, and the
# process aborted.  CArray.stack of arrays already at CA_RANK_MAX built a
# CAStack of CA_RANK_MAX + 1 axes, which an index or #inspect then read past
# its arrays.  Both run in a child process, so a regression fails this file
# rather than killing the run.  The other entries refused already, each in
# its own words.

require "test/unit"
require "rbconfig"
require "carray"

class TestRankLimit < Test::Unit::TestCase

  MAX = CA_RANK_MAX
  MESSAGE = /\A(?<name>[\w.!?#\[\]]+): ndim (?<n>\d+) exceeds CA_RANK_MAX #{MAX}\z/

  # Run `code` in a child; return its last line of output, or the signal.
  def child (code)
    script = "require 'carray'\nbegin\n#{code}\nputs :ok\n" \
             "rescue Exception => e\nputs \"\#{e.class}: \#{e.message}\"\nend\n"
    out = IO.popen([RbConfig.ruby, *$LOAD_PATH.grep(/carray/).flat_map { |p| ["-I", p] },
                    "-e", script], err: File::NULL, &:read)
    st = $?
    st.signaled? ? "signal #{Signal.signame(st.termsig)}" : out.lines.last.to_s.chomp
  end

  def assert_refused (name, n, line)
    m = MESSAGE.match(line.sub(/\AArgumentError: /, ""))
    assert line.start_with?("ArgumentError: "), "#{name}: #{line}"
    assert m, "#{name}: #{line}"
    assert_equal name, m[:name], line
    assert_equal n, m[:n].to_i, line
  end

  def test_a_nested_array_one_level_too_deep
    deep = "v = 1; #{MAX + 1}.times { v = [v] }"
    assert_refused "CA_INT32", MAX + 1, child("#{deep}; CA_INT32(v)")
    assert_refused "to_ca", MAX + 1, child("#{deep}; v.to_ca")
    assert_equal "ok", child("v = 1; #{MAX}.times { v = [v] }; raise unless CA_INT32(v).ndim == #{MAX}")
  end

  def test_stack_of_arrays_at_the_limit
    full = "a = CArray.int32(*[1] * #{MAX})"
    assert_refused "stack", MAX + 1, child("#{full}; CArray.stack([a, a])")
    assert_refused "stack", MAX + 1, child("#{full}; CArray.stack([a, a], axis: -1)")
    assert_equal "ok", child("a = CArray.int32(*[1] * #{MAX - 1}); raise unless CArray.stack([a, a]).ndim == #{MAX}")
  end

  # The entries that refused already, now in one form.
  def test_every_entry_says_it_the_same_way
    a16 = CArray.int32(*[1] * MAX)
    a9  = CArray.int32(*[1] * 9)
    a1  = CA_INT32([1])
    {
      "int32"           => [MAX + 1, -> { CArray.int32(*[1] * (MAX + 1)) }],
      "reshape"         => [MAX + 1, -> { a1.reshape(*[1] * (MAX + 1)) }],
      "insert_axis"     => [MAX + 1, -> { a16.insert_axis(0) }],
      "broadcast_to"    => [MAX + 1, -> { a1.broadcast_to(*[1] * (MAX + 1)) }],
      "sliding_windows" => [18,      -> { a9.sliding_windows(*[1] * 9) }],
      "block_view"      => [18,      -> { a9.block_view(*[1] * 9) }],
    }.each do |name, (n, call)|
      e = assert_raise(ArgumentError, name) { call.() }
      assert_refused name, n, "ArgumentError: #{e.message}"
    end
  end

  # A bit view adds an axis to its parent.
  def test_bitarray_of_an_array_at_the_limit
    assert_refused "bitarray", MAX + 1,
                   child("b = CArray.uint8(*[1] * #{MAX}).bitarray; b.transpose")
    assert_equal "ok", child("b = CArray.uint8(*[1] * #{MAX - 1}).bitarray; raise unless b.ndim == #{MAX}")
  end

  # A field taken through a template has the array's axes and the template's.
  def test_field_through_a_template_past_the_limit
    assert_refused "field", 2 * MAX,
                   child("CArray.fixlen(*[1] * #{MAX}, bytes: 1).field(0, CArray.int8(*[1] * #{MAX}))")
  end

  # Reading a wider type as a narrower one at the limit: the view keeps the
  # rank asked for, and its mask has one cell per narrow element.
  def test_narrowing_refer_of_a_masked_array_at_the_limit
    code = <<~RUBY
      a = CArray.int32(*([1] * #{MAX - 1} + [2])).seq
      a[0, *[0] * #{MAX - 1}] = UNDEF   # the first int32
      v = a.refer(:int8, [1] * #{MAX - 1} + [8])
      raise "ndim" unless v.ndim == #{MAX}
      raise v.is_masked.to_a.flatten.inspect unless v.is_masked.to_a.flatten == [true] * 4 + [false] * 4
    RUBY
    assert_equal "ok", child(code)
  end

  # The result of :_ has the base's axes and one for each :_; the rank is
  # checked before any of them is written.
  def test_newaxis_past_the_limit
    assert_refused "[]", MAX + 1, child("CArray.int32(*[1] * #{MAX})[:_, *[nil] * #{MAX}]")
    assert_refused "[]", 201, child("CArray.int32(1)[*[:_] * 200, nil]")
    assert_refused "[]", 40, child("CArray.int32(1)[*[:_] * 40, 0]")
    assert_equal "ok", child("raise unless CArray.int32(1)[*[:_] * #{MAX - 1}, nil].ndim == #{MAX}")
  end

end
