# A raise inside an attach window that leaves an array answering wrongly.
#
# MOST OF THE ASSERTIONS BELOW PIN BEHAVIOUR THAT IS WRONG.  Each one goes
# through assert_broken, which names the correct outcome.  When a fix makes
# one fail, rewrite that test to assert the outcome it names rather than
# deleting it.

require "test/unit"
require "carray"

class TestAttachWindowRaiseValues < Test::Unit::TestCase

  def assert_broken (actual, broken, fixed)
    assert_equal broken, actual,
                 "no longer broken -- rewrite this test to assert #{fixed}"
  end

  # map! raises part way through a selection.  The selection stays attached
  # to the buffer it materialised, so reads that go through the buffer see
  # the values from before the parent changed, while a single-element read
  # goes to the parent and sees the new one.
  def test_selection_reads_a_stale_buffer_after_map_bang_raises
    b = CArray.int32(3, 4).seq
    v = b[b > 3]
    assert_raise(RuntimeError) { v.map! { |x| x == 10 ? raise("block") : x * 100 } }
    b[1, 0] = -7
    assert_equal(-7, v[0])
    assert_broken [v.to_a[0, 3], v[0..2].sum], [[400, 500, 600], 1500.0],
                  "[[-7, 500, 600], 1093.0], the parent's values"
  end

  # A store that fails converting the value leaves the cycle check on, and
  # every later access reports a cyclic reference.
  def test_failed_object_store_leaves_the_cycle_check_on
    f = CArray.int32(3).fake(CA_OBJECT)
    assert_raise(ArgumentError) { f[0] = "zz" }
    e = (f[1] rescue $!)
    assert_broken e.is_a?(RuntimeError) && e.message.include?("cyclic reference"),
                  true, "that f[1] answers 1"
  end

end
