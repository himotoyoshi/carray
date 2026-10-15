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
  MESSAGE = /\A(?<name>[\w.!?#]+): ndim (?<n>\d+) exceeds CA_RANK_MAX #{MAX}\z/

  # Run `code` in a child; return its last line of output, or the signal.
  def child (code)
    script = "require 'carray'\nbegin\n#{code}\nputs :ok\n" \
             "rescue Exception => e\nputs \"\#{e.class}: \#{e.message}\"\nend\n"
    out = IO.popen([RbConfig.ruby, *$LOAD_PATH.grep(/carray/).flat_map { |p| ["-I", p] },
                    "-e", script], err: File::NULL, &:read)
    st = $?
    st.signaled? ? "signal #{Signal.signame(st.termsig)}" : out.lines.last.to_s.chomp
  end

  # `name` nil: the entry is a Ruby method over a C one, and the message names
  # the C one (guess_array_shape, initialize) -- the general naming of such
  # entries is its own rule, so only the form and the rank are held here.
  def assert_refused (name, n, line)
    m = MESSAGE.match(line.sub(/\AArgumentError: /, ""))
    assert line.start_with?("ArgumentError: "), "#{name}: #{line}"
    assert m, "#{name}: #{line}"
    assert_equal name, m[:name], line if name
    assert_equal n, m[:n].to_i, line
  end

  def test_a_nested_array_one_level_too_deep
    deep = "v = 1; #{MAX + 1}.times { v = [v] }"
    assert_refused nil, MAX + 1, child("#{deep}; CA_INT32(v)")
    assert_refused nil, MAX + 1, child("#{deep}; v.to_ca")
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
      nil               => [MAX + 1, -> { CArray.int32(*[1] * (MAX + 1)) }],
      "reshape"         => [MAX + 1, -> { a1.reshape(*[1] * (MAX + 1)) }],
      "insert_axis"     => [MAX + 1, -> { a16.insert_axis(0) }],
      "broadcast_to"    => [MAX + 1, -> { a1.broadcast_to(*[1] * (MAX + 1)) }],
      "sliding_windows" => [18,      -> { a9.sliding_windows(*[1] * 9) }],
      "block_view"      => [18,      -> { a9.block_view(*[1] * 9) }],
    }.each do |name, (n, call)|
      e = assert_raise(ArgumentError, name.to_s) { call.() }
      assert_refused name, n, "ArgumentError: #{e.message}"
    end
  end

end
