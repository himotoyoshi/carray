# PROPOSAL_STRING_FACE_TRIO.md P.1 — CAString (identity Face over CA_OBJECT
# storage) working-class test matrix.
#
# Pins the §1.6 common surface contract for CAString, minus the deferred
# str_* / conversion rows.  Regression sweep is `rake spec_ai`.

require "test/unit"
require "carray"

class TestCAString < Test::Unit::TestCase

  WORDS = ["banana", "apple", "cherry", "apple"].freeze

  # ---- construction ------------------------------------------------------

  def test_construct_array_form
    s = CArray.string(WORDS)
    assert_kind_of CAString, s
    assert_equal :object, s.data_type      # surface == storage (no gate)
    assert_equal 4, s.elements
    assert_equal WORDS, s.to_a
  end

  def test_construct_block_form
    s = CArray.string(3) { |i| "item#{i}" }
    assert_equal ["item0", "item1", "item2"], s.to_a
  end

  def test_construct_block_arity0_broadcast
    s = CArray.string(3) { "x" }
    assert_equal ["x", "x", "x"], s.to_a
  end

  def test_construct_nil_masks
    s = CArray.string(["a", nil, "c"])
    assert_equal true, s.has_mask?
    assert_equal [false, true, false], s.is_masked.to_a
    assert_equal UNDEF, s[1]
  end

  def test_wrap_zero_copy
    o = CArray.object(2)
    o[0] = "p"; o[1] = "q"
    s = CAString.wrap(o)
    s[0] = "P"
    assert_equal "P", o[0]                  # write-through to parent
  end

  def test_wrap_rejects_non_object_storage
    assert_raise(TypeError) { CAString.wrap(CArray.int32(3)) }
  end

  # ---- Face identity -----------------------------------------------------

  def test_face_hierarchy
    s = CArray.string(WORDS)
    assert_equal true, s.face?
    [CAFace, CAView, CArray].each { |k| assert_kind_of k, s }
    assert_operator s.class.ancestors.index(CAFace), :<, s.class.ancestors.index(CArray)
  end

  def test_view_chain_lift
    s = CArray.string(WORDS)
    assert_kind_of CAString, s[1..2]
    assert_equal ["apple", "cherry"], s[1..2].to_a
    assert_kind_of CAString, s.reshape(2, 2)
  end

  # ---- per-cell ----------------------------------------------------------

  def test_fetch_returns_string
    s = CArray.string(WORDS)
    assert_kind_of String, s[0]
    assert_equal "banana", s[0]
  end

  def test_store_string
    s = CArray.string(WORDS)
    s[0] = "zzz"
    assert_equal "zzz", s[0]
  end

  # ---- ordering (ORDERABLE -> :object <=> kernel, free) ------------------

  def test_sort_index
    s = CArray.string(WORDS)
    assert_equal [1, 3, 0, 2], s.sort_index.to_a
  end

  def test_min_max
    s = CArray.string(WORDS)
    assert_equal "apple", s.min
    assert_equal "cherry", s.max
  end

  # ---- copy / dup --------------------------------------------------------

  def test_copy_materializes
    s = CArray.string(WORDS)
    c = s.copy
    assert_kind_of CAString, c
    assert_equal WORDS, c.to_a
    c[0] = "X"
    assert_equal "banana", s[0]             # copy is independent
  end

  def test_dup_is_castring
    s = CArray.string(WORDS)
    assert_kind_of CAString, s.dup
  end

  # ---- N-D ---------------------------------------------------------------

  def test_ndim
    s = CArray.string(6) { |i| i.to_s }.reshape(2, 3)
    assert_equal 2, s.ndim
    assert_equal [2, 3], s.shape
    assert_equal "4", s[1, 1]
  end

  # The String operators and the picks by order give text, so they give a
  # CAString back, as the String methods and the bang forms do.  The
  # receiver decides: an object array's operator stays an object array.
  def test_operators_give_castring
    s = CArray.string(["a", nil])
    o = CA_OBJECT(["c", "d"])
    [s + s, s + "x", s.add("x"), s * 2, s.mul(2), s % "x", s.mod("x"),
     s + o, s + o.lazy, s.pmax("m"), s.pmin(o), s.maximum(o), s.minimum(o),
     s.fmax(o), s.fmin(o)].each do |r|
      assert_kind_of CAString, r
      assert_equal true, r.is_masked[1]
    end
    assert_equal ["ac", UNDEF], (s + o).to_a
    assert_equal ["aa", UNDEF], (s * 2).to_a
    assert_equal ["A", UNDEF], (s + "").upcase.to_a
    assert_equal CArray, (o + s).class
    assert_raise(TypeError) { s + 1 }
  end

  # A cell of a CAString is a String, through every way in: the builders,
  # CAString.wrap, and a store.  UNDEF masks a cell; nil does so only in the
  # builder from Ruby values.
  def test_cells_are_strings
    assert_raise(TypeError) { CArray.string(["a", 1]) }
    assert_raise(TypeError) { CArray.string([:a]) }
    assert_raise_message(/CA_OBJECT/) { CArray.string([["a", "b"], ["c", "d"]]) }
    assert_raise(TypeError) { CArray.string(2) { |i| i } }
    assert_raise(TypeError) { CArray.string(CA_OBJECT(["a", nil])) }
    assert_raise(TypeError) { CAString.wrap(CA_OBJECT([1])) }
    o = CA_OBJECT(["a", 5])
    o[1] = UNDEF
    assert_equal ["a", UNDEF], CArray.string(o).to_a
    assert_equal [2, 2], CArray.string(CA_OBJECT([["a", "b"], ["c", "d"]])).shape
    assert_equal ["a", UNDEF], CArray.string(["a", nil]).to_a

    fresh = -> { CArray.string(["a", "b"]) }
    [->(s) { s[0] = 1 }, ->(s) { s[0] = nil }, ->(s) { s[] = :x },
     ->(s) { s.fill(1) }, ->(s) { s[] = [3, 4] }, ->(s) { s[] = CA_OBJECT([1, 2]) },
     ->(s) { s[] = CA_INT32([1, 2]) }, ->(s) { s[CA_BOOLEAN([1, 0])] = 3 }].each do |store|
      assert_raise(TypeError) { store.(fresh.()) }
    end
    s = fresh.()
    s[0] = UNDEF
    assert_equal [UNDEF, "b"], s.to_a
    s = fresh.()
    s[] = ["x", UNDEF]
    assert_equal ["x", UNDEF], s.to_a
    s = fresh.()
    s[] = CArray.const_string(["p", "q"])
    assert_equal ["p", "q"], s.to_a
    assert_equal ["-", "a"], fresh.().shift(1, fill_value: "-").to_a
  end

  # A CAString beside an object array of Strings is refused, as any Face
  # beside a plain array is, and the refusal names the builder that makes
  # the object array a CAString.
  def test_mix_with_object_array_names_the_builder
    s = CArray.string(["a"])
    o = CA_OBJECT(["b"])
    [-> { CArray.concatenate([s, o]) }, -> { CArray.meld(o, s) },
     -> { CA_BOOLEAN([1]).then_else(s, o) }].each do |mix|
      assert_raise_message(/CArray\.string\(a\)/) { mix.() }
    end
    assert_equal ["a", "b"], CArray.concatenate([s, CArray.string(o)]).to_a
  end


  # A cell a verb makes without being given a value (a fresh template, the
  # cells shift and window bring in, the cells resize adds) is the blank
  # String, as a fixlen string's is "", and never the object storage's 0.
  def test_cells_made_without_a_value_are_blank_strings
    s = CArray.string(["a", "b", "c"])
    t = s.template
    assert_kind_of CAString, t
    assert_equal ["", "", ""], t.to_a
    assert t[0].frozen?
    assert_equal ["", "a", "b"], s.shift(1).to_a
    assert_equal ["b", "c", ""], s.shift(-1).to_a
    assert_equal ["", "a", "b", "c", ""], s.window(-1..3).to_a
    assert_equal ["a", "b", "c", "", ""], s.resize(5).to_a
    assert_equal [UNDEF, "a", "b"], s.shift(1, fill_value: UNDEF).to_a
    assert_equal [UNDEF, "a", "b", "c", UNDEF], s.window(-1..3, fill_value: UNDEF).to_a
    assert_equal ["-", "a", "b", "c", "-"], s.window(-1..3, fill_value: "-").to_a
    assert_equal [0, 0, 0], s.template(:int32).to_a
  end

  # The values a block or a progression gives go in as any stored value does.
  def test_template_block_and_seq_store_strings_only
    s = CArray.string(["a", "b", "c"])
    assert_equal ["x0", "x1", "x2"], s.template { |i| "x#{i}" }.to_a
    assert_equal ["y", "y", "y"], s.template { "y" }.to_a
    assert_raise(TypeError) { s.template { 5 } }
    assert_raise(TypeError) { s.template { |i| i } }
    assert_raise(TypeError) { s.window(-1..1, fill_value: 5) }
    assert_equal ["p", "q", "r"], s.copy.seq!("p", :succ).to_a
    [-> (x) { x.seq! }, -> (x) { x.seq!(1.5) }, -> (x) { x.seq!(axis: 0) }].each do |seq|
      x = s.copy
      assert_raise(TypeError) { seq.(x) }
      assert_equal ["a", "b", "c"], x.to_a
    end
  end

  def test_one_cell_does_not_take_an_array
    [->(x) { x[1] = ["q"] }, ->(x) { x[1] = [["q", "r"]] },
     ->(x) { CArray.stack([x, x])[0, 1] = ["q"] },
     ->(x) { CArray.meld(x, x)[1] = ["q"] }].each do |store|
      x = CArray.string(%w[a b c d])
      assert_raise(TypeError) { store.(x) }
      assert_equal %w[a b c d], x.to_a
    end
  end

  def test_an_object_array_source_is_stored_by_its_shape
    x = CArray.string(%w[a b c d])
    x[] = CA_OBJECT([["p"], ["q"], ["r"], ["s"]])
    assert_equal %w[p q r s], x.parent.to_a
    m = CA_OBJECT(%w[p q r s])
    m[1] = UNDEF
    x[] = m
    assert_equal ["p", UNDEF, "r", "s"], x.to_a
    assert_raise(TypeError) { x[] = CA_OBJECT(["p", 1, "r", "s"]) }
    assert_raise(ArgumentError) { x[] = CA_OBJECT(%w[p q r]) }
  end

  # A Face that is not text has storage that is not its text: a CATime's
  # cells are ticks, a categorical's are codes.
  def test_a_face_that_is_not_text_is_refused
    t = CArray.time(["2024-01-01"], unit: :D)
    c = CA_OBJECT(%w[a b a]).categorize
    [t, t - t, c].each do |f|
      %i[string const_string fixlen_string].each do |m|
        e = assert_raise(TypeError) { CArray.send(m, f) }
        assert_match(/CArray.#{m}: a #{f.class} is not text/, e.message)
      end
    end
    assert_equal %w[a b], CArray.string(CArray.string(%w[a b]).to_const_string).to_a
  end

end
