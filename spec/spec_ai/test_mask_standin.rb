require 'test/unit'
require 'carray'

# A view whose mask covers a parent that has none reads an all-false
# stand-in there: asking about the mask, or writing nothing but false into
# it, gives the parent no mask.  The stand-in gives way to the parent's
# own mask once the parent has one, or once a true is written into it.
#
# Each case is answered twice: over a parent with no mask, and over the
# same parent given an all-false mask first.  The two must agree.
class TestMaskStandin < Test::Unit::TestCase

  VIEWS = {
    "grid with holes" => ->(p) { p[CA_INT64([0, UNDEF, 2]), nil] },
    "window"          => ->(p) { p.window(-1..2, nil, fill_value: UNDEF) },
    "shift"           => ->(p) { p.shift(1, 0, fill_value: UNDEF) },
    "stack"           => ->(p) { CArray.stack([p, masked_other]) },
    "meld"            => ->(p) { CArray.meld(p, masked_other) },
  }

  # A view cell that reads the parent's cell [1, 1].
  CELL = {
    "grid with holes" => [2, 1], "window" => [2, 1], "shift" => [2, 1],
    "stack" => [0, 1, 1], "meld" => [1, 1],
  }

  def self.masked_other
    o = CArray.float64(3, 4).seq!
    o[0, 0] = UNDEF
    o
  end

  def parent (premask)
    a = CArray.float64(3, 4).seq!
    a.mask = 0 if premask
    a
  end

  # Reads of the view and its mask taken after the parent is given a mask.
  READS = {
    "mask.to_a"      => ->(v, m) { m.to_a },
    "mask.copy"      => ->(v, m) { m.copy.to_a },
    "mask.where"     => ->(v, m) { m.where.to_a },
    "mask.sum"       => ->(v, m) { m.sum },
    "mask.sum(axis)" => ->(v, m) { m.sum(axis: 0).to_a },
    "mask.each"      => ->(v, m) { r = []; m.each { |x| r << x }; r },
    "mask[i]"        => ->(v, m) { m[*CELL_OF[v]] },
    "view.to_a"      => ->(v, m) { v.to_a },
    "view.copy"      => ->(v, m) { v.copy.is_masked.to_a },
    "count_masked"   => ->(v, m) { v.count_masked },
  }
  CELL_OF = {}

  def answer (view_name, premask)
    a = parent(premask)
    v = VIEWS[view_name].call(a)
    CELL_OF[v] = CELL[view_name]
    [a, v, yield(a, v)]
  ensure
    CELL_OF.clear
  end

  def test_the_mask_follows_a_mask_the_parent_is_given_later
    wrong = []
    VIEWS.each_key do |vn|
      READS.each do |rn, read|
        got, ref = [false, true].map do |premask|
          answer(vn, premask) do |a, v|
            m = v.mask
            a[1, 1] = UNDEF
            read.call(v, m)
          end.last
        end
        wrong << "#{vn}: #{rn}" unless got == ref
      end
    end
    assert_equal [], wrong
  end

  def test_a_copy_of_the_mask_follows_too
    VIEWS.each_key do |vn|
      got, ref = [false, true].map do |premask|
        answer(vn, premask) do |a, v|
          d = v.mask.dup
          a[1, 1] = UNDEF
          d.to_a
        end.last
      end
      assert_equal ref, got, vn
    end
  end

  # Writes that put nothing but false into the stand-in.
  FALSE_WRITES = {
    "view[i] = value"     => ->(v, c) { v[*c] = 1.0 },
    "view[] = view.copy"  => ->(v, c) { v[] = v.copy },
    "mask[i] = false"     => ->(v, c) { v.mask[*c] = false },
    "mask[] = false"      => ->(v, c) { v.mask[] = false },
    "mask.map! { false }" => ->(v, c) { m = v.mask; m.map! { |x| false } },
  }

  def test_writing_only_false_gives_the_parent_no_mask
    wrong = []
    VIEWS.each_key do |vn|
      FALSE_WRITES.each do |wn, write|
        a, v, _ = answer(vn, false) { |a, v| write.call(v, CELL[vn]) }
        _, ref, _ = answer(vn, true) { |a, v| write.call(v, CELL[vn]) }
        wrong << "#{vn}: #{wn} gave the parent a mask" if a.has_mask?
        wrong << "#{vn}: #{wn}" unless ref.is_masked.to_a == v.is_masked.to_a
      end
    end
    assert_equal [], wrong
  end

  # Writes that put a true into the part of the mask over the parent.
  TRUE_WRITES = {
    "view[i] = UNDEF"    => ->(v, c) { v[*c] = UNDEF },
    "mask[i] = true"     => ->(v, c) { v.mask[*c] = true },
    "mask[] = array"     => ->(v, c) { m = v.mask; b = m.copy; b[*c] = true; m[] = b },
    "mask.map! { true }" => ->(v, c) { m = v.mask; m.map! { |x| true } },
  }

  def test_writing_a_true_gives_the_parent_its_mask
    VIEWS.each_key do |vn|
      TRUE_WRITES.each do |wn, write|
        a, v, _ = answer(vn, false) { |a, v| write.call(v, CELL[vn]) }
        r, ref, _ = answer(vn, true) { |a, v| write.call(v, CELL[vn]) }
        assert_equal true, a.has_mask?, "#{vn}: #{wn}"
        assert_equal r.is_masked.to_a, a.is_masked.to_a, "#{vn}: #{wn}"
        assert_equal ref.is_masked.to_a, v.is_masked.to_a, "#{vn}: #{wn}"
      end
    end
  end

  def test_asking_gives_the_parent_no_mask
    VIEWS.each_key do |vn|
      a, v, _ = answer(vn, false) do |a, v|
        v.has_mask?; v.count_masked; v.mask.to_a; v.mask.sum(axis: 0)
        v.copy; v.is_masked; v.mask.dup.to_a
      end
      assert_equal false, a.has_mask?, vn
    end
  end
  # Every method of the mask that takes no argument, after the parent is
  # given a mask, answers as over a parent that had one all along.  The
  # methods are found, not listed, so a new reader is covered as it lands.
  # Left out: answers that depend on the object rather than its cells, and
  # the attach lifecycle (__attach__ and the like, dev build), which opens a
  # window the reader would leave open.
  IDENTITY = %i[object_id hash singleton_class random shuffle to_frame
                display tap then yield_self itself freeze dup clone
                attach attach!].freeze

  def self.normalize (x)
    case x
    when CArray      then [x.class.name.sub(/Mask\z/, ""), x.data_type, x.shape, x.to_a]
    when Array       then x.map { |e| normalize(e) }
    when Enumerator  then :enumerator
    when Float       then x.nan? ? :nan : x
    else x
    end
  end

  def test_every_reader_of_the_mask_follows_the_parent
    readers = CArray.public_instance_methods(true).select { |m|
      [0, -1].include?(CArray.instance_method(m).arity)
    }.reject { |m|
      m.to_s.end_with?("!", "=") || m.start_with?("__", "pretty_") ||
        IDENTITY.include?(m)
    }
    wrong = []
    VIEWS.each do |vn, make|
      readers.each do |m|
        got, ref = [false, true].map do |premask|
          a = parent(premask)
          mask = make.call(a).mask
          a[1, 1] = UNDEF
          begin
            self.class.normalize(mask.public_send(m))
          rescue StandardError, NotImplementedError => e
            e.class
          end
        end
        wrong << "#{vn}: #{m}" unless got == ref
      end
    end
    assert_equal [], wrong
  end

  # The views above are every view that keeps stand-ins: a file in ext/
  # that makes one must have its views here.
  STANDIN_FILES = {
    "ca_obj_grid.c"   => ["grid with holes"],
    "ca_obj_window.c" => ["window", "shift"],
    "ca_obj_stack.c"  => ["stack"],
    "ca_obj_meld.c"   => ["meld"],
  }

  def test_every_view_that_keeps_stand_ins_is_here
    ext = File.expand_path("../../ext", __dir__)
    omit "no ext/ sources" unless File.directory?(ext)
    found = Dir[File.join(ext, "*.c")].select { |path|
      next false if File.basename(path) =~ /\Acarray_mask\.c\z|\Acarray_kernels_/
      File.read(path, encoding: "UTF-8") =~ /\bca_mask_standin_new\s*\(|\bca_multi_parent_mask\s*\(/
    }.map { |path| File.basename(path) }.sort
    assert_equal STANDIN_FILES.keys.sort, found
    assert_equal VIEWS.keys.sort, STANDIN_FILES.values.flatten.sort
  end
end
