# ca_iter_ensure finishes every walk it opened, even when finishing one of
# them raises.
#
# A WRITE walk whose root is a view syncs that root when it finishes, and
# the sync goes through the view's slots, which can raise.  The walks are
# finished in reverse order of their slots; a raise from one finish must not
# leave the walks before it open.
#
# No view in carray reaches this: a walk attaches a view as its root only
# when the view has no xfer_stride slot, and every view in carray has one.
# The fixture's CAIterOffsetNoXfer is a view installed from outside without
# that slot, whose sync can be made to raise -- the case a companion gem
# can produce.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_iter_source_kind", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_source_kind"
rescue LoadError
  warn "Skipping test_iter_ensure_close: iter_source_kind not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestIterEnsureClose < Test::Unit::TestCase

  def setup
    omit "needs a development build" unless CArray.respond_to?(:__attached_views__)
    CAIterOffsetNoXfer.fail_sync = false
  end

  def teardown
    CAIterOffsetNoXfer.fail_sync = false
  end

  def views
    r = CAIterOffsetNoXfer.wrap(CArray.int32(3, 4).seq!, 10)
    w = CAIterOffsetNoXfer.wrap(CArray.int32(3, 4).seq!, 10)
    [r, w]
  end

  def test_both_walks_close_when_nothing_raises
    r, w = views
    before = CArray.__attached_views__
    CAIterOffsetNoXfer.ensure_walks(r.transpose, w.transpose)
    assert_equal before, CArray.__attached_views__
    assert_equal false, r.attached?
    assert_equal [0] * 12, w.to_a.flatten
  end

  def test_a_raising_finish_does_not_leave_the_other_walk_open
    r, w = views
    CAIterOffsetNoXfer.fail_sync = true
    before = CArray.__attached_views__
    err = assert_raise(RuntimeError) do
      CAIterOffsetNoXfer.ensure_walks(r.transpose, w.transpose)
    end
    assert_equal "CAIterOffsetNoXfer: sync failed", err.message
    assert_equal false, r.attached?
    assert_equal false, w.attached?
    assert_equal before, CArray.__attached_views__
  end

end
