require 'test/unit'
require 'carray'

# A value written into the masked cells of a Face through a view that is not
# contiguous reaches the root, and the cells lose their mask.
class TestFaceUnmaskThroughView < Test::Unit::TestCase

  VIEWS = {
    "transpose"   => ->(x) { x.transpose },
    "block"       => ->(x) { x[1..2, 1..3] },
    "index array" => ->(x) { x[nil, CA_INT([0, 2, 1, 4, 3])] },
  }

  FACES = {
    "time"      => ->(r) { r.time(unit: :s) },
    "timedelta" => ->(r) { r.timedelta(unit: :s) },
  }

  def root
    r = CArray.int64(4, 5).seq!
    r[1, 1] = UNDEF
    r[2, 2] = UNDEF
    r
  end

  def test_unmask_with_a_value
    FACES.each do |fname, face|
      VIEWS.each do |vname, view|
        r = root
        e = r.copy
        view.call(face.call(r)).unmask(99)
        view.call(e).unmask(99)
        assert_equal e.to_a, r.to_a, "#{fname} #{vname}"
      end
    end
  end

  def test_unmask_by_method
    VIEWS.each do |vname, view|
      r = root
      e = r.copy
      view.call(r.time(unit: :s)).unmask(method: :forward, axis: 0)
      view.call(e).unmask(method: :forward, axis: 0)
      assert_equal e.to_a, r.to_a, vname
    end
  end
end
