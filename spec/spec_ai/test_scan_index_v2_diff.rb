# I.3a-I.4 differential test for rb_ca_scan_index v2.
#
# Compares CArray.scan_index (v1) vs CArray._scan_index_v2 (v2 dev surface).
# For each input pattern: byte-parity of (type, index) returned, or for
# error paths byte-parity of (exception_class, message).
#
# Coverage: I.3a (POINT / ALL / ADDRESS / BLOCK + rubber-dim).
# I.3b/c/d/e expand coverage; tests for not-yet-implemented kinds are
# `omit`-marked and flipped as handlers come online.

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

class TestScanIndexV2Diff < Test::Unit::TestCase
  def cmp(dim, idx, label: nil)
    label ||= "dim=#{dim.inspect} idx=#{idx.inspect}"

    v1_result = nil; v1_err = nil
    v2_result = nil; v2_err = nil

    begin
      info = CArray.scan_index(dim, idx)
      v1_result = [info.type, info.index]
    rescue => e
      v1_err = [e.class, e.message]
    end

    begin
      v2_result = CArray._scan_index_v2(dim, idx)
    rescue NotImplementedError => e
      omit "v2 not yet implemented for #{label}: #{e.message}"
    rescue => e
      v2_err = [e.class, e.message]
    end

    if v1_err && v2_err
      assert_equal v1_err, v2_err, "#{label} (error path)"
    elsif v1_err
      flunk "#{label}: v1 raised #{v1_err.inspect} but v2 returned #{v2_result.inspect}"
    elsif v2_err
      flunk "#{label}: v1 returned #{v1_result.inspect} but v2 raised #{v2_err.inspect}"
    else
      assert_equal v1_result, v2_result, label
    end
  end

  # ============== ALL ==============
  def test_all_empty_argc
    cmp [3, 3], []
    cmp [10], []
    cmp [2, 3, 4], []
  end

  def test_all_qfalse_argc1
    cmp [3, 3], [false]
    cmp [10], [false]
  end

  # ============== POINT ==============
  def test_point_fast_path_argc_eq_ndim
    cmp [3, 3], [0, 0]
    cmp [3, 3], [2, 2]
    cmp [3, 3], [1, 1]
    cmp [2, 3, 4], [1, 1, 1]
    cmp [10], [5]
    cmp [3, 3, 3], [-1, -1, -1]   # negative index normalization
  end

  def test_point_fast_path_out_of_range
    cmp [3, 3], [3, 0]    # IndexError
    cmp [3, 3], [-4, 0]   # IndexError after normalization
    cmp [3, 3], [0, 3]
  end

  def test_point_1d_via_main_loop
    # argc=1, ndim=1, Fixnum → POINT 1-D
    cmp [10], [5]
    cmp [10], [-1]
  end

  # ============== ADDRESS ==============
  def test_address_fast_path
    cmp [3, 3], [5]
    cmp [3, 3], [8]
    cmp [3, 3], [-1]
    cmp [2, 3, 4], [13]
  end

  def test_address_out_of_range
    cmp [3, 3], [10]
    cmp [3, 3], [-100]
  end

  # ============== BLOCK ==============
  def test_block_range
    cmp [3, 3], [1..2, nil]
    cmp [5, 5], [0..4, 0..2]
    cmp [5, 5], [1...3, nil]   # exclusive
    cmp [5, 5], [0..-1, nil]
    cmp [5, 5], [0...0, nil]   # start==end exclusive (count=0)
  end

  def test_block_full_axis
    cmp [3, 3], [nil, nil]
    cmp [2, 3, 4], [nil, nil, nil]
  end

  def test_block_mixed_scalar
    cmp [3, 3], [1, nil]
    cmp [3, 3], [nil, 2]
    cmp [3, 3], [0..-1, 1]
  end

  def test_block_arithseq
    cmp [5, 5], [(0..4).step(2), nil]
    cmp [5, 5], [(0...5).step(2), nil]
    cmp [5, 5], [(4..0).step(-1), nil]
  end

  def test_block_array_form
    cmp [5, 5], [[1, 2, 1], nil]    # [start, count, step]
    cmp [5, 5], [[1, 2], nil]       # [start, count]
    cmp [5, 5], [[nil, 2], nil]     # [nil, step]
    cmp [5, 5], [[0..3, 2], nil]    # [Range, step]
    cmp [5, 5], [[2], nil]          # [Integer]
    cmp [5, 5], [[nil], nil]        # [nil]
    cmp [5, 5], [[0..3], nil]       # [Range]
  end

  def test_block_array_step_zero
    cmp [5, 5], [[1, 2, 0], nil]
    cmp [5, 5], [[nil, 0], nil]
    cmp [5, 5], [[0..3, 0], nil]
  end

  def test_block_array_invalid_len
    cmp [5, 5], [[1, 2, 3, 4], nil]   # IndexError
    cmp [5, 5], [[], nil]
  end

  # ============== Rubber dim (false) ==============
  def test_rubber_dim_basic
    cmp [3, 3, 3, 3, 3], [false]                # all-ALL
    cmp [3, 3, 3, 3, 3], [0, false]
    cmp [3, 3, 3, 3, 3], [false, 0]
    cmp [3, 3, 3, 3, 3], [0, false, 0]
  end

  def test_rubber_dim_with_blocks
    cmp [3, 3, 3, 3, 3], [0..1, false]
    cmp [3, 3, 3, 3, 3], [false, 0..1]
    cmp [3, 3, 3, 3, 3], [0..1, false, 0..1]
  end

  def test_rubber_dim_with_nil
    cmp [3, 3, 3, 3, 3], [nil, false]
    cmp [3, 3, 3, 3, 3], [false, nil]
  end

  def test_rubber_dim_overflow
    cmp [3, 3], [0, 0, 0, 0, 0, 0, false]    # IndexError
  end

  # ============== argc mismatch (no rubber) ==============
  def test_argc_mismatch
    cmp [3, 3], [0, 0, 0]    # too many
    cmp [3, 3], [0]          # too few (= ADDRESS 路、これは ndim>1 で別 path)
    cmp [3, 3, 3], [0, 0]    # too few
  end

  # ============== Negative index normalization ==============
  def test_negative_index
    cmp [3, 3], [-1, -1]
    cmp [3, 3], [-3, -3]
    cmp [3, 3], [-4, -1]    # out of range
  end

  # ============== Bignum on Integer slow path ==============
  def test_bignum_axis
    # 2D POINT slow path with Bignum (FIXNUM_P false → slow path)
    cmp [3, 3], [2**40, 0]   # IndexError out of range
    cmp [10, 10], [-(2**40), 0]
  end

  # ============== ITERATOR contraction reservation (PROPOSAL §1.6) ==============
  def test_contraction_reserved_alphabet
    # v1 raises IndexError "use :_ instead".
    # v2 raises NotImplementedError "reserved for future contraction notation".
    # The two differ deliberately; here we assert v2's behavior directly
    # rather than via differential cmp.
    [:i, :j, :k, :a, :z, :A, :Z].each do |sym|
      assert_raise(NotImplementedError) do
        CArray._scan_index_v2([3, 3], [sym, sym])
      end
      e = assert_raise(NotImplementedError) do
        CArray._scan_index_v2([3, 3], [sym, sym])
      end
      assert_match(/reserved for future contraction notation/, e.message)
    end
  end

  def test_iterator_gt_sigil_works
    # SI.2: :> is the slab-axis (iterator) marker.
    cmp [3, 3], [:>, :>]
    cmp [3, 3], [0, :>]
  end

  def test_two_char_symbol_raises_indexerror
    # `:ij` (2+ char) at axis i>0 raises IndexError in v1; v2 should match.
    cmp [3, 3], [0, :ij]
  end

  # ============== I.3b: METHOD_CALL / MEMBER / ATTRIBUTE / FLATTEN ==============

  def test_method_call
    cmp [3, 3], [:method_name]
    cmp [3, 3], [:foo, 0, 1]
    cmp [10], [:sum]
  end

  def test_member
    cmp [10], ["field_name"]
    cmp [10], ["x"]
  end

  def test_attribute
    cmp [10], ["@attr"]
    cmp [10], ["@name"]
  end

  def test_flatten
    cmp [3, 3], [nil]       # ndim>1 single nil → FLATTEN
    cmp [2, 3, 4], [nil]
    # argc=1 ndim=1 nil falls through to main loop as ALL axis → POINT? No,
    # it's BLOCK (single ALL axis).  Covered separately:
    cmp [10], [nil]
  end

  # ============== I.3c: SELECT / GRID / MAPPING ==============

  def test_grid_1d
    # argc==1 with integer 1-D CArray on a 1-D target → GRID
    g = CArray.int(3).seq!
    cmp [10], [g]
  end

  def test_mapping
    # argc==1 with integer N-D CArray (any other shape combo) → MAPPING
    m = CArray.int(3, 3).seq!
    cmp [10], [m]
    m2 = CArray.int(5).seq!
    cmp [3, 4], [m2]    # 1-D mapper on 2-D target
  end

  def test_select
    a = CArray.int(3, 3).seq!
    mask = a.eq(4)
    cmp [3, 3], [mask]
  end

  def test_select_size_mismatch
    a = CArray.int(3, 3).seq!
    mask = a.eq(4)
    cmp [3, 4], [mask]    # RuntimeError mismatch
  end

  def test_carray_invalid_data_type
    f = CArray.float64(5).seq!
    cmp [10], [f]    # IndexError data_type ... invalid
  end

  # ============== I.3d: REPEAT ==============

  def test_repeat_pre_scan
    # `:%` at any position triggers REPEAT
    cmp [3, 3], [:%, :%, 2]
    cmp [3, 3], [nil, :%]
    cmp [3, 3], [1, :%, 2]
  end

  def test_repeat_preempts_validation
    # v1 lets :% preempt the argc != ndim validation; v2 must match
    cmp [3], [1, 2, :%]      # argc=3, ndim=1, would normally raise; :% wins
  end

  # ============== I.3e: ADDRESS_COMPLEX ==============
  # argc==1, ndim>1, argv[0] is Range / ArithSeq / T_ARRAY → ADDRESS_COMPLEX.
  # info.index is built by re-scanning argv against flat dim=[elements].

  def test_address_complex_range
    cmp [3, 3], [1..2]      # → [[1, 2, 1]]
    cmp [2, 3], [0..4]      # → [[0, 5, 1]]
    cmp [3, 3], [1...3]     # exclusive → [[1, 2, 1]]
  end

  def test_address_complex_arithseq
    cmp [4, 4], [(0..15).step(2)]
  end

  def test_address_complex_array_form
    cmp [3, 3], [[1, 4, 2]]   # [[1,4,2]]
    cmp [3, 3], [[1..3, 2]]
  end

  # ============== Acceptance criterion #1 mirror ==============
  # spec/Features/feature_index_spec.rb:38-61 "scan_index" example mirror.
  # Verifies v2 byte-parity with the values the public test pins for v1.

  def test_feature_spec_mirror
    cmp [3, 3], []
    cmp [3, 3], [1]
    cmp [3, 3], [1..2]
    cmp [3, 3], [1, 1]
    cmp [3, 3], [1, nil]
    a = CArray.int(3, 3).seq!
    i = CArray.int(3).seq!
    cmp [3, 3], [a.eq(4)]
    cmp [3, 3], [a]
    cmp [3, 3], [i, i]
    cmp [3, 3], [:%, :%, 2]
  end

  # Multi-arg GRID via axis-position CArray (= main loop short-circuit).
  def test_grid_multi_arg_main_loop
    i = CArray.int(3).seq!
    cmp [3, 3], [i, nil]
    cmp [3, 3], [nil, i]
    cmp [3, 3, 3], [i, i, i]
  end

  # ============== I.4: NetCDF hyperslab pattern matrix ==============
  # PROPOSAL_INDEXER_REDESIGN.md §1.0 + §6.5 — production consumer
  # (NetCDF Variable wrapper et al) が `var[...]` 内部 dispatch に使う
  # 9 pattern を named test として明示的に pin。後続 phase で REG
  # 形式が触られた場合の検知 anchor。

  # Pattern 1: scalar element fetch
  def test_netcdf_scalar_fetch
    cmp [100], [42], label: "var[i] 1-D"
    cmp [100, 50, 30], [10, 20, 5], label: "var[i,j,k] N-D"
  end

  # Pattern 2: contiguous slab with Range
  def test_netcdf_range_slab
    cmp [100, 50], [10..19, nil], label: "var[i..j, nil]"
    cmp [100, 50], [10..19, 5..14], label: "var[i..j, k..l]"
    cmp [100, 50], [10...20, 5...15], label: "exclusive Range"
  end

  # Pattern 3: strided slab via ArithSeq (= NetCDF stride != 1 hyperslab)
  def test_netcdf_strided_slab
    cmp [100, 50], [(0..99).step(2), nil], label: "var[i..j:s, nil]"
    cmp [100, 50], [(0..49).step(5), (0..49).step(2)],
        label: "both axes strided"
  end

  # Pattern 4: full-axis nil selectors (CF coord pick)
  def test_netcdf_full_axis_pick
    cmp [10, 100, 50], [nil, 50, nil], label: "var[nil, k, nil]"
    cmp [10, 100, 50], [5, nil, nil],   label: "var[k, nil, nil]"
    cmp [10, 100, 50], [nil, nil, 25],  label: "var[nil, nil, k]"
  end

  # Pattern 5: explicit tuple form [start, count, step] (NetCDF-style)
  def test_netcdf_tuple_form
    cmp [100, 50], [[10, 20, 2], nil], label: "[start,count,step]"
    cmp [100, 50], [[5, 10], nil],     label: "[start,count]"
    cmp [100, 50], [[nil, 3], nil],    label: "[nil,step] all-axis strided"
  end

  # Pattern 6: rubber dim for variable-ndim wrappers
  def test_netcdf_rubber_dim
    cmp [100, 50, 30], [10, false],    label: "var[i, false] = i, nil, nil"
    cmp [100, 50, 30], [false, 5],     label: "var[false, k] = nil, nil, k"
    cmp [100, 50, 30], [10..20, false], label: "var[i..j, false] mixed"
  end

  # Pattern 7: flat-address (ADDRESS) for 1-D walk over N-D variable
  def test_netcdf_flat_address
    cmp [100, 50], [4999],  label: "var[flat_addr]"
    cmp [100, 50], [2**32], label: "Bignum flat_addr (out-of-range raise)"
  end

  # Pattern 8: ADDRESS_COMPLEX for 1-D walk with Range
  def test_netcdf_address_complex_range
    cmp [10, 10], [10..49], label: "var[range_on_flat]"
    cmp [10, 10], [(0..99).step(3)], label: "strided range on flat"
  end

  # Pattern 9: FLATTEN (= explicit single-nil 1-D view trigger)
  def test_netcdf_flatten
    cmp [10, 10], [nil],    label: "var[nil] = FLATTEN"
    cmp [10, 5, 3], [nil],  label: "FLATTEN 3-D"
  end

  # ============== I.4: error message format byte-parity ==============
  # decision-tree §5 で列挙した 15 raise condition のうち、まだ explicit
  # に named test 化していない format-string を網羅。v1 から byte-copy
  # した format specifier (= `%i-dim` vs `%d-dim`、空白、`(0..%lld)` vs
  # `( %lld <=> 0..%lld )` 等) の細部一致を保証。

  def test_error_msg_axis_out_of_range
    # "index out of range at %i-dim ( %lld <=> 0..%lld )"
    e1 = (CArray.scan_index([3, 3], [5, 0]) rescue $!)
    e2 = (CArray._scan_index_v2([3, 3], [5, 0]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/index out of range at 0-dim \( 5 <=> 0\.\.2 \)/, e2.message)
  end

  def test_error_msg_last_out_of_range
    # "index %lld is out of range (0..%lld) at %i-dim"
    e1 = (CArray.scan_index([3, 3], [0..5, nil]) rescue $!)
    e2 = (CArray._scan_index_v2([3, 3], [0..5, nil]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/index 5 is out of range \(0\.\.2\) at 0-dim/, e2.message)
  end

  def test_error_msg_step_zero
    # "step in index equals to 0 in block reference"
    e1 = (CArray.scan_index([5], [[0, 3, 0]]) rescue $!)
    e2 = (CArray._scan_index_v2([5], [[0, 3, 0]]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_equal RuntimeError, e2.class
  end

  def test_error_msg_invalid_form
    # "invalid form of index range at %i-dim (should be ...)"
    e1 = (CArray.scan_index([5, 5], [[1, 2, 3, 4], nil]) rescue $!)
    e2 = (CArray._scan_index_v2([5, 5], [[1, 2, 3, 4], nil]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/invalid form of index range at 0-dim/, e2.message)
  end

  def test_error_msg_argc_exceeds_ndim
    # "number of indices exceeds the ndim of carray (%i > %i)"
    e1 = (CArray.scan_index([3], [0, 0]) rescue $!)
    e2 = (CArray._scan_index_v2([3], [0, 0]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/number of indices exceeds the ndim of carray \(2 > 1\)/,
                 e2.message)
  end

  def test_error_msg_rubber_overflow
    # "index specification exceeds the ndim of carray (%i)"
    e1 = (CArray.scan_index([3, 3], [0, 0, 0, 0, false]) rescue $!)
    e2 = (CArray._scan_index_v2([3, 3], [0, 0, 0, 0, false]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/index specification exceeds the ndim of carray \(2\)/,
                 e2.message)
  end

  def test_error_msg_symbol_use_underscore
    # SI.2: "symbol :%s is invalid as the index for slab iterator (use :> instead)"
    # NOTE: v2 reserves single-char alphabet (= :ij is 2 char so falls to v1 path)
    e1 = (CArray.scan_index([3, 3], [0, :ij]) rescue $!)
    e2 = (CArray._scan_index_v2([3, 3], [0, :ij]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/symbol :ij is invalid.*use :> instead/, e2.message)
  end

  def test_error_msg_select_mismatch
    # "mismatch of # of elements ( %lld <=> %lld ) in reference by selection"
    a = CArray.int(3, 3).seq!
    mask = a.eq(4)   # 9 elements
    e1 = (CArray.scan_index([3, 4], [mask]) rescue $!)   # 12 elements
    e2 = (CArray._scan_index_v2([3, 4], [mask]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_equal RuntimeError, e2.class
    assert_match(/mismatch of # of elements/, e2.message)
  end

  def test_error_msg_carray_invalid_data_type
    # "data_type %s is invalid for reference by selection/mapping..."
    f = CArray.float64(9).seq!
    e1 = (CArray.scan_index([3, 3], [f]) rescue $!)
    e2 = (CArray._scan_index_v2([3, 3], [f]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/data_type .* is invalid for reference by selection\/mapping/,
                 e2.message)
  end

  def test_error_msg_gridding_invalid_data_type
    # "data_type %s is invalid for reference by gridding at %i-dim..."
    f = CArray.float64(3).seq!
    e1 = (CArray.scan_index([3, 3], [f, nil]) rescue $!)
    e2 = (CArray._scan_index_v2([3, 3], [f, nil]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/data_type .* is invalid for reference by gridding at 0-dim/,
                 e2.message)
  end

  # ============== I.5: ITERATOR post-pass + contraction matrix + rubber/neg-idx edges ==============

  # decision-tree §3.4.5 — when REG=ITERATOR, every CA_IDX_SCALAR axis is
  # rewritten to BLOCK {start, count=1, step=1}.  Easy to miss in source
  # audit; pin it here explicitly so future v2 / v3 refactor cannot drop it.
  def test_iterator_post_pass_scalar_to_block
    # Plain SCALAR + :>
    cmp [3, 3], [0, :>],   label: "ITERATOR post-pass [0, :>]"
    cmp [3, 3], [2, :>],   label: "ITERATOR post-pass [2, :>]"
    # Negative index pre-normalized then post-pass
    cmp [3, 3], [-1, :>],  label: "ITERATOR post-pass [-1, :>] (normalize then expand)"
    # Multi :> with SCALAR mix
    cmp [3, 3, 3], [1, :>, :>], label: "ITERATOR mixed [1, :>, :>]"
    cmp [3, 3, 3], [:>, 1, :>], label: "ITERATOR mixed [:>, 1, :>]"
    cmp [3, 3, 3], [:>, :>, 1], label: "ITERATOR mixed [:>, :>, 1]"
    # All :>
    cmp [3, 3], [:>, :>],       label: "ITERATOR all-iterator [:>, :>]"
  end

  # ============== I.5: contraction notation reservation full alphabet ==============

  RESERVED_CONTRACTION_SYMBOLS = ("a".."z").to_a.map(&:to_sym) +
                                 ("A".."Z").to_a.map(&:to_sym)

  def test_contraction_all_lowercase_alphabet
    RESERVED_CONTRACTION_SYMBOLS.each do |sym|
      next if sym == :_       # not in this set anyway
      e = assert_raise(NotImplementedError, "axis-position :#{sym}") do
        CArray._scan_index_v2([3, 3], [sym, sym])
      end
      assert_match(/reserved for future contraction notation/, e.message,
                   "axis-position :#{sym} message format")
    end
  end

  def test_contraction_at_argv0_method_call_takes_precedence
    # `:foo` (multi-char Symbol) at argv[0] → METHOD_CALL via top-level
    # dispatch (= unchanged from v1).  Single-char alphabet at argv[0]
    # falls through the strlen>1 gate and hits the axis loop, where it
    # then triggers the contraction-reserved raise.
    assert_raise(NotImplementedError) do
      CArray._scan_index_v2([3, 3], [:i, :>])   # :i at axis 0
    end
    # METHOD_CALL preserved for multi-char Symbol at argv[0]
    cmp [3, 3], [:ij_method], label: ":ij_method (METHOD_CALL)"
  end

  def test_contraction_single_char_non_alpha_still_indexerror
    # `:0`, `:+` etc. single char, non-alphabet — NOT in reservation set,
    # must raise IndexError (v1-compatible) not NotImplementedError.
    [:"0", :"+", :"!", :"?"].each do |sym|
      e1 = (CArray.scan_index([3, 3], [0, sym]) rescue $!)
      e2 = (CArray._scan_index_v2([3, 3], [0, sym]) rescue $!)
      assert_equal e1.class, e2.class, "axis :#{sym}: classes"
      assert_equal e1.message, e2.message, "axis :#{sym}: message"
      assert_equal IndexError, e2.class, "axis :#{sym}: should be IndexError"
    end
  end

  def test_slab_sigil_gt_is_iterator
    # SI.2: `:>` is the slab-axis (iterator) marker, NOT contraction-reserved.
    info = CArray._scan_index_v2([3, 3], [:>, :>])
    assert_equal CA_REG_ITERATOR, info[0]
  end

  def test_underscore_rejected_in_scan_index
    # SI.1/SI.2: :_ is newaxis, handled at the [] / []= level; it is not a
    # classifier concept and raises if it reaches scan_index directly.
    e = assert_raise(IndexError) { CArray._scan_index_v2([3, 3], [:_, nil]) }
    assert_match(/newaxis/, e.message)
  end

  # ============== I.5: rubber dim 5-D corner cases ==============

  def test_rubber_5d_all_combos
    # All single-Qfalse positions on a 5-D target with mixed args around.
    cmp [3, 3, 3, 3, 3], [0, 1, 2, 0, 1]               # no rubber (POINT)
    cmp [3, 3, 3, 3, 3], [false]                       # full rubber expansion
    cmp [3, 3, 3, 3, 3], [0, false]                    # rubber at i=1
    cmp [3, 3, 3, 3, 3], [0, 1, false]
    cmp [3, 3, 3, 3, 3], [0, 1, 2, false]
    cmp [3, 3, 3, 3, 3], [0, 1, 2, 3, false]           # rubber at end, rndim=1
    cmp [3, 3, 3, 3, 3], [false, 0]                    # rubber at start
    cmp [3, 3, 3, 3, 3], [false, 0, 1]
    cmp [3, 3, 3, 3, 3], [false, 0, 1, 2]
    cmp [3, 3, 3, 3, 3], [false, 0, 1, 2, 3]
    cmp [3, 3, 3, 3, 3], [0..1, false, 0..1, 0..1]     # rubber w/ blocks
    cmp [3, 3, 3, 3, 3], [0..1, nil, false, nil, 0..1] # rubber middle w/ nils
  end

  def test_rubber_argc_equal_ndim_plus_one_edge
    # argc = ndim + 1 with rubber at any position is the maximum permitted;
    # rndim = 0 expansion case (rubber consumes nothing).
    cmp [3, 3], [false, 0, 1]   # rndim = 0, rubber consumes nothing
    cmp [3, 3], [0, false, 1]   # rndim = 0
    cmp [3, 3], [0, 1, false]   # rndim = 0
  end

  # ============== I.5: negative index normalization edges ==============

  def test_negative_index_boundary
    cmp [5, 5], [-5, -5]    # -dim wraps to 0
    cmp [5, 5], [-6, 0]     # -dim - 1 out of range
    cmp [5, 5], [0, -6]     # other axis out of range
  end

  def test_negative_index_in_range
    # ndim==1 falls through main loop; ensure neg idx normalize works
    cmp [10], [-1]    # POINT 1-D
    cmp [10], [-10]   # POINT 1-D edge
    cmp [10], [-11]   # out of range
  end

  def test_error_msg_unknown_object
    # "object '%s' is invalid for the index for reference at %i-dim"
    # v1 calls rb_inspect; reproduce with a non-recognized arg
    bad = Object.new
    e1 = (CArray.scan_index([3, 3], [0, bad]) rescue $!)
    e2 = (CArray._scan_index_v2([3, 3], [0, bad]) rescue $!)
    assert_equal e1.class, e2.class
    assert_equal e1.message, e2.message
    assert_match(/is invalid for the index for reference at 1-dim/, e2.message)
  end
end
