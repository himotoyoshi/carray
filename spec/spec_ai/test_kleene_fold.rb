# §8 of PROPOSAL_KLEENE_BOOLEAN_LOGIC: the `skip_masked:` keyword on the
# boolean folds all / any / none.  Default (skip_masked: true) is the existing
# available-case (skipna) behavior; skip_masked: false gives the three-valued
# (Kleene) fold, consistent with element-wise `|` / `&`.

require "test/unit"
require "carray"

class TestKleeneFold < Test::Unit::TestCase

  # build a 1-D boolean array from tokens: "T" / "F" / "U"
  def ba (*toks)
    a = CArray.boolean(toks.size)
    toks.each_with_index { |t, i| a[i] = (t == "U" ? UNDEF : (t == "T" ? 1 : 0)) }
    a
  end

  def cell (x)
    x == UNDEF ? "U" : (x ? "T" : "F")
  end

  def test_flat_any_kleene
    assert_equal "T", cell(ba("T", "U").any(skip_masked: false))  # T settles
    assert_equal "U", cell(ba("F", "U").any(skip_masked: false))  # F|U undetermined
    assert_equal "U", cell(ba("U", "U").any(skip_masked: false))
    assert_equal "F", cell(ba("F", "F").any(skip_masked: false))
    assert_equal "T", cell(ba("T", "F").any(skip_masked: false))
  end

  def test_flat_all_kleene
    assert_equal "U", cell(ba("T", "U").all(skip_masked: false))  # T&U undetermined
    assert_equal "F", cell(ba("F", "U").all(skip_masked: false))  # F settles
    assert_equal "U", cell(ba("U", "U").all(skip_masked: false))
    assert_equal "T", cell(ba("T", "T").all(skip_masked: false))
    assert_equal "F", cell(ba("T", "F").all(skip_masked: false))
  end

  def test_flat_none_is_not_any
    # none = not any (Kleene): not U = U
    assert_equal "F", cell(ba("T", "U").none(skip_masked: false))
    assert_equal "U", cell(ba("F", "U").none(skip_masked: false))
    assert_equal "T", cell(ba("F", "F").none(skip_masked: false))
  end

  def test_default_is_skipna_unchanged
    # masked cells ignored (available-case), always true/false
    m = ba("T", "U")
    assert_equal true,  m.any                     # default skip_masked: true
    assert_equal true,  m.all                     # U ignored -> all of {T}
    assert_equal false, m.none
    assert_equal true,  m.any(skip_masked: true)
  end

  def test_no_mask_matches_both
    m = ba("T", "F", "T")
    assert_equal m.any, m.any(skip_masked: false)
    assert_equal m.all, m.all(skip_masked: false)
  end

  def test_per_axis_kleene
    # row0 = [U, F, T] -> any T (T settles), all F (F settles)
    # row1 = [F, F, F] -> any F, all F
    m = CArray.boolean(2, 3) { |i, j| [[1, 0, 1], [0, 0, 0]][i][j] }
    m[0, 0] = UNDEF
    any1 = m.any(axis: 1, skip_masked: false)
    all1 = m.all(axis: 1, skip_masked: false)
    assert_equal [true, false], any1.to_a                       # [T, F]
    assert_equal [false, false], all1.to_a                       # [F, F]
    assert_equal false, any1.has_mask?                    # both rows determined
  end

  def test_per_axis_undetermined_is_masked
    # row0 = [F, U] -> any U (undetermined), row1 = [T, U] -> any T
    m = CArray.boolean(2, 2) { |i, j| [[0, 0], [1, 0]][i][j] }
    m[0, 1] = UNDEF
    m[1, 1] = UNDEF
    any1 = m.any(axis: 1, skip_masked: false)
    assert_equal true, any1.is_masked[0]                  # row0 undetermined
    assert_equal false, any1.is_masked[1]                 # row1 = T
    assert_equal true, any1[1]
  end

  def test_keep_axis_with_kleene
    m = CArray.boolean(2, 3) { 1 }
    m[0, 0] = UNDEF
    assert_equal [2, 1], m.all(axis: 1, keep_axis: true, skip_masked: false).shape
  end

end
