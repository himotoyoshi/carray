# ----------------------------------------------------------------------------
#
#  mkkernel.rb -- code generator for kernel_iterator-based reduction kernels
#
#  Sibling generator to mkmath.rb, but targeting the Phase D kernel_iterator
#  surface instead of the legacy eager-materialise operators.  Clean slate:
#  no dependency on carray_config.h, no complex/long-double remnants, no
#  per-cell fetch/store template.
#
#  The DSL describes a kernel once -- per-cell init + reduce expression --
#  and the generator emits:
#    1. one native helper per source data_type using CA_SLAB_REDUCE_T(T_LOAD, ...)
#    2. a dispatcher that switches on ca->data_type
#    3. an optional fallback path for non-standard source data_types
#    4. an Init_carray_kernels() that registers each kernel as a method
#       on rb_cCArray
#
#  Output is on stdout (mkmath.rb convention).  extconf.rb regenerates the
#  .c when this file is touched.
#
#  Usage:
#
#    cd ext && ruby mkkernel.rb > carray_kernels.c
#
#  Adding a new reduction kernel:
#
#    MkKernel.reduce :prod,
#      init:        "1",
#      reduce:      "acc *= v",
#      source:      MkKernel::ALL_NUMERIC,
#      output:      :f64,                # or :preserve (= source data_type)
#      ruby_scalar: :rb_float_new,       # or :auto (derive from output)
#      fallback:    :wrap_to_f64         # or :raise (default)
#
#  ----------------------------------------------------------------------------

require "stringio"

module MkKernel
  # Per-source-data_type attributes used during code emission.  Covers the
  # full numeric span of CArray (CA_BOOLEAN is reduction-special and
  # CA_CMPLX* / CA_OBJECT / CA_FIXLEN are deferred to future dialects).
  # `num2c` is the Ruby VALUE -> C type conversion macro used by
  # value_arg: dispatchers (CF.1) to cast a positional Ruby argument to
  # the kernel's T_IN type.  Signed integers use NUM2LL, unsigned
  # NUM2ULL, floats NUM2DBL, with the dispatcher adding the per-type cast.
  DTYPES = {
    i8:  { c: "int8_t",   ca: "CA_INT8",    ruby: "LL2NUM",  num2c: "NUM2LL",
           limit_hi: "INT8_MAX",   limit_lo: "INT8_MIN" },
    u8:  { c: "uint8_t",  ca: "CA_UINT8",   ruby: "ULL2NUM", num2c: "NUM2ULL",
           limit_hi: "UINT8_MAX",  limit_lo: "0" },
    i16: { c: "int16_t",  ca: "CA_INT16",   ruby: "LL2NUM",  num2c: "NUM2LL",
           limit_hi: "INT16_MAX",  limit_lo: "INT16_MIN" },
    u16: { c: "uint16_t", ca: "CA_UINT16",  ruby: "ULL2NUM", num2c: "NUM2ULL",
           limit_hi: "UINT16_MAX", limit_lo: "0" },
    i32: { c: "int32_t",  ca: "CA_INT32",   ruby: "LL2NUM",  num2c: "NUM2LL",
           limit_hi: "INT32_MAX",  limit_lo: "INT32_MIN" },
    u32: { c: "uint32_t", ca: "CA_UINT32",  ruby: "ULL2NUM", num2c: "NUM2ULL",
           limit_hi: "UINT32_MAX", limit_lo: "0" },
    i64: { c: "int64_t",  ca: "CA_INT64",   ruby: "LL2NUM",  num2c: "NUM2LL",
           limit_hi: "INT64_MAX",  limit_lo: "INT64_MIN" },
    u64: { c: "uint64_t", ca: "CA_UINT64",  ruby: "ULL2NUM", num2c: "NUM2ULL",
           limit_hi: "UINT64_MAX", limit_lo: "0" },
    f32: { c: "float",    ca: "CA_FLOAT32", ruby: "rb_float_new", num2c: "NUM2DBL",
           limit_hi: "INFINITY",   limit_lo: "-INFINITY" },
    f64: { c: "double",   ca: "CA_FLOAT64", ruby: "rb_float_new", num2c: "NUM2DBL",
           limit_hi: "INFINITY",   limit_lo: "-INFINITY" },
    # E.6a (2026-06-03): boolean as a first-class source DTYPE.
    # Intentionally NOT included in ALL_NUMERIC -- kernels opt boolean in
    # explicitly via `source: [..., :bool]` (with a `bool:` body entry
    # since the :numeric family alias does not match :bool).  Boolean
    # participates in arithmetic / reduction / scan / sort / argmin as its
    # 0/1 numeric storage, always returning a numeric result (never bool);
    # the boolean-returning reductions are the logical family all / any /
    # none.  The value-reductions (sum / prod / min / max / minmax / cum*)
    # emit u64 output, the ratio ones (mean / variance / stddev) f64.
    # limit_hi/lo (1 / 0) are the correct extrema for the bounded 0/1
    # domain, so min/max init reuse them directly.
    bool: { c: "boolean8_t", ca: "CA_BOOLEAN", ruby: "INT2NUM",
            limit_hi: "1",   limit_lo: "0" },
    # SO.1 (2026-06-04): ca_size_t output data_type for sort_index_ki etc.
    # CA_SIZE = CA_INT64 on 64-bit, CA_INT32 on 32-bit (platform-dependent).
    # Used as the output data_type of position-returning kernels (= :sort kind).
    # Intentionally NOT in ALL_NUMERIC -- only sort family uses it as output.
    ca_size: { c: "ca_size_t", ca: "CA_SIZE", ruby: "SIZE2NUM",
               limit_hi: "0", limit_lo: "0" },   # limits unused for sort
    # ----- P.5b.1 (mkmath retarget B1): math family DTYPE extensions ------
    # `MkKernel.monop` / `.binop` / `.moncmp` / `.bincmp` emit eager-style
    # kernels matching the existing mkmath calling convention.  For full
    # CA_NTYPE coverage parity with mkmath, mkkernel needs to know the
    # complex and object data_types too.  These entries are NOT included in
    # ALL_NUMERIC; pick up via MATH_TYPES / MATH_NUMERIC aliases.
    cmplx64:  { c: "cmplx64_t",  ca: "CA_CMPLX64",  ruby: "CC2NUM",
                num2c: "NUM2CC",  limit_hi: "0", limit_lo: "0" },
    cmplx128: { c: "cmplx128_t", ca: "CA_CMPLX128", ruby: "CC2NUM",
                num2c: "NUM2CC",  limit_hi: "0", limit_lo: "0" },
    object:   { c: "VALUE",      ca: "CA_OBJECT",   ruby: "(VALUE)",
                num2c: "(VALUE)", limit_hi: "0", limit_lo: "0" },
    # P.5b.4: fixlen for bincmp (= match, eq/ne/gt/lt/ge/le against
    # fixed-byte strings).  The c: type is `char` because fixlen kernels
    # operate on raw byte pointers with explicit `b1` byte-width.  Opt-in
    # via explicit `source: [..., :fixlen]` in bincmp declarations.
    fixlen:   { c: "char",       ca: "CA_FIXLEN",   ruby: "(VALUE)",
                num2c: "(VALUE)", limit_hi: "0", limit_lo: "0" },
  }.freeze

  # Convenience aliases for kernel source: lists.
  ALL_NUMERIC    = %i[i8 u8 i16 u16 i32 u32 i64 u64 f32 f64].freeze
  FLOAT_DTYPES   = %i[f32 f64].freeze
  INT_DTYPES     = %i[i8 u8 i16 u16 i32 u32 i64 u64].freeze

  CMPLX_DTYPES   = %i[cmplx64 cmplx128].freeze
  # MATH_TYPES = bool + numeric + complex + object (= union of mkmath
  # ALL/BOOL/CMPLX/OBJ_TYPES), the default coverage of the math family.
  MATH_TYPES     = (ALL_NUMERIC + CMPLX_DTYPES + [:bool, :object]).freeze
  MATH_NUMERIC   = (ALL_NUMERIC + CMPLX_DTYPES).freeze

  # Fine-grained data_type subsets used by some monop/monfunc declarations.
  SINT_DTYPES        = %i[i8 i16 i32 i64].freeze       # signed integers
  UINT_DTYPES        = %i[u8 u16 u32 u64].freeze       # unsigned integers
  SINT_SMALL_DTYPES  = %i[i8 i16 i32].freeze           # signed <= 32 bit
  SINT64_DTYPES      = [:i64].freeze                   # signed 64 bit only
  BOOL_DTYPES        = [:bool].freeze
  OBJECT_DTYPES      = [:object].freeze

  # OBJ_FLOAT_MATH helper (port of mkmath's OBJ_FLOAT_MATH).  Generates
  # a CA_OBJECT-branch expression that special-cases Float / Integer /
  # Rational by computing in C, and falls back to `rb_funcall(elem,
  # fallback_method)` for other element types.  Used by monfunc
  # declarations (sqrt/exp/log/sin/...) for the :object data_type variant.
  # `<v>` in `double_expr` is replaced with `NUM2DBL(_obj_arg)`.
  def self.obj_float_math(double_expr, fallback_method)
    body = double_expr.gsub('<v>', 'NUM2DBL(_obj_arg)')
    fb = fallback_method.inspect
    <<~SNIPPET
      {
        VALUE _obj_arg = (#1);
        if (RB_FLOAT_TYPE_P(_obj_arg) || RB_INTEGER_TYPE_P(_obj_arg) || RB_TYPE_P(_obj_arg, T_RATIONAL)) {
          (#2) = DBL2NUM(#{body});
        } else {
          (#2) = rb_funcall(_obj_arg, rb_intern(#{fb}), 0);
        }
      }
    SNIPPET
  end

  # CA_NTYPE order from ext/carray.h.  Drives the per-data_type table layout
  # for eager-style monop/binop tables `ca_<form>_<name>[CA_NTYPE]`.
  # `:reserved` slots emit `ca_<form>_not_implement` (= retired holes
  # CA_FLOAT128 / CA_CMPLX256).
  # `:fixlen_slot` is the CA_FIXLEN = 0 slot (placeholder).  When a
  # kernel declares `:fixlen` in `source:`, the table emits its symbol
  # in this slot.  Otherwise the slot is `*_not_implement`.
  CA_NTYPE_ORDER = [
    :fixlen_slot,    # CA_FIXLEN = 0
    :bool,           # CA_BOOLEAN = 1
    :i8, :u8, :i16, :u16, :i32, :u32, :i64, :u64,   # 2..9
    :f32, :f64,      # 10, 11
    :reserved,       # CA_FLOAT128 = 12 (retired)
    :cmplx64, :cmplx128,                            # 13, 14
    :reserved,       # CA_CMPLX256 = 15 (retired)
    :object,         # CA_OBJECT = 16
  ].freeze

  # Returns the C expression for the per-data_type default epsilon, used by
  # search-family kernels for fuzzy float comparison.  Integer data_types get
  # "0" so eps is effectively ignored (exact equality semantics).  Float
  # data_types get FLT_EPSILON / DBL_EPSILON from <float.h> (legacy convention
  # `defeps * fabs(val)`, S.3 PROPOSAL_SEARCH_AXIS).
  def self.eps_default_for(src)
    case src
    when :f32 then "FLT_EPSILON"
    when :f64 then "DBL_EPSILON"
    else            "0"
    end
  end

  def self.float_data_type?(src)
    FLOAT_DTYPES.include?(src)
  end
  SIGNED_NUMERIC = %i[i8 i16 i32 i64 f32 f64].freeze

  KERNELS = []

  # P.5b.5: Arbitrary C code injected at the top of the generated
  # carray_kernels.c, after the standard `#include` block but before
  # the first kernel.  Used for shared macros that multiple kernels
  # reference (e.g. op_powi for the `power` binop).
  HEADER_BLOCKS = []
  def self.header_block(code)
    HEADER_BLOCKS << code
  end

  # ---- DSL ----------------------------------------------------------------

  # Register a reduction kernel.
  #
  # Two forms accepted (the second is a backward-compatibility sugar over
  # the first):
  #
  #   ----- Multi-state form (canonical) -----
  #     state:       { acc: :acc_type, cnt: :int64_t },   # state vars + types
  #     init:        { acc: "0",       cnt: "0" },         # init expressions
  #     reduce:      "acc += v; cnt++",                    # per-cell statement
  #     finish:      "cnt ? acc / (T_OUT) cnt : 0.0",      # post-fold expression
  #
  #   ----- Single-acc form (sugar) -----
  #     init:   "0",            # treated as state: { acc: :acc_type }, init: { acc: "0" }
  #     reduce: "acc += v",     # statement, runs against the implicit `acc`
  #                             # finish defaults to "acc"
  #
  # State variable types: `:acc_type` resolves to T_OUT (the output data_type's
  # C type), `:load_type` resolves to T_LOAD (the source data_type's C type).
  # Any other symbol (`:int64_t`, `:double`, ...) is emitted literally.
  #
  # The first state variable (by insertion order) is the one passed to
  # the CA_SLAB_REDUCE_T macro as its accumulator argument; remaining
  # state vars are declared and initialised by the caller before the
  # macro call.  Convention is to name the first var `acc`, but any
  # name works -- e.g., argmin uses `best_v` as the first var and
  # `best_i` as the secondary (= it's `best_v` that the macro initialises).
  #
  # Inside the REDUCE expression, an implicit `idx` (ca_size_t) variable
  # holds the flat slab-row-major index of the current cell.  Useful for
  # position-sensitive reductions (argmin/argmax).
  # mask_policy: controls how the kernel propagates the input mask to
  # the output cell.  Possible values:
  #   nil          - default: never mask the output (= current behavior).
  #                  All-masked slabs return the accumulator's INIT value
  #                  (= 0 for sum, INFINITY for min, etc.).
  #   :strict      - any masked input cell -> output cell UNDEF
  #                  (NaN-propagation semantics).
  #   :all_masked  - output cell UNDEF only if every input cell is masked.
  #                  Matches stat_proc's `min_count = elements - 1` mode
  #                  (= "produce a value as long as one valid cell exists").
  #   :min_count   - runtime-parameterised: kernel accepts :min_count (Integer)
  #                  and :fill_value options.  Default (no opt or
  #                  min_count: 0) behaves like :all_masked (= legacy
  #                  default).  With min_count: K (K > 0), output cell
  #                  is UNDEF when valid_cnt < K (= "need K valid cells").
  #                  :fill_value substitutes for UNDEF in the result.
  #                  This is the mode required by Phase E migration of
  #                  legacy rb_ca_sum / mean / variance etc.
  #
  # When mask_policy is set, the generator:
  #   - uses CA_SLAB_REDUCE_T_EX so the kernel sees masked_cnt
  #   - lazily allocates an output mask buffer on the first UNDEF cell
  #   - writes the mask bit for the offending output cell
  #   - returns Object::UNDEF for the full-reduction case when the
  #     single output cell is masked, instead of the Ruby scalar.
  # value_arg: (CF.1, count family) -- accept one positional Ruby argument
  # at runtime and bind it to the kernel as a C variable named `value_arg`
  # of type T_IN (the source data_type's C type, per Q5 sparring confirmed).
  #
  # DSL:
  #   value_arg: { target: :T_IN }    # current only supported form
  #
  # Generator effects:
  #   - Native helper signature gains `, T_IN value_arg` at the tail
  #     (after min_count if mask_policy is :min_count).
  #   - Dispatcher pops argv[0] as `rval` BEFORE option parsing, then
  #     casts via DTYPES[src][:num2c] inside each per-src switch case.
  #   - The reduce: body can reference `value_arg` as a plain C identifier.
  #
  # array_arg: (W.1, weighted reduction family) -- accept one positional
  # Ruby CArray argument at runtime as a same-shape second operand
  # (= "weights" for wsum/wmean, future wvariance/wstddev).  Walked in
  # lockstep with the source slab via the CA_SLAB_REDUCE_ARRAY_T_EX
  # macro, exposing the cell value as `w` in the REDUCE expression
  # (alongside `v` for the source cell).
  #
  # DSL:
  #   array_arg: {
  #     name:  :weights,            # informative name (= error msg / docs)
  #     data_type: :promote,        # weights materialized at the f64 computation
  #                                 # type and read as `double` (so a float weight
  #                                 # against an int source is not truncated).
  #                                 # :match_source (legacy) reads the weight at
  #                                 # the source type -- wrong for fractional
  #                                 # weights, kept only for DSL forward-compat.
  #     shape: :rev5_strict,        # W-A1 scalar / W-A2 1-D axis-broadcast / W-A3
  #                                 # same-shape (:match_source = W-A3 only)
  #     mask:  :overlay,            # weights.mask OR'd into self.mask before
  #                                 # kernel call (= legacy parity, Q3 (A))
  #   }
  #
  # Generator effects:
  #   - Native helper signature gains `, CArray *cw` BEFORE the per-src
  #     value_arg / min_count parameters.
  #   - Dispatcher pops argv[0] as weights CArray (rb_ca_wrap_readonly to the
  #     weight storage type = f64 for :promote, ca_check_same_shape, optional
  #     mask overlay, ca_attach), then calls the native helper.
  #   - The reduce: body binds BOTH `v` (source cell, type T_IN) AND `w`
  #     (weights cell, weight storage type = double for :promote) — e.g.
  #     `acc += (double) v * (double) w` for wsum.  The weight cell C type is
  #     the CA_SLAB_REDUCE_ARRAY_T_EX second type param (T_W), decoupled from T.
  #
  # Incompatibilities:
  #   - array_arg + value_arg in the same kernel is rejected (no
  #     customer demand; sparring round 1 confirms wsum/wmean only).
  def self.reduce(name, source:, output:, init: nil,
                  reduce: nil, state: nil, finish: nil,
                  ruby_scalar: :auto, fallback: :raise,
                  mask_policy: nil, value_arg: nil, array_arg: nil,
                  semantics: :fiber_local,
                  public_method: nil, bind_ruby: false,
                  smoke: false,
                  reduction_kind: :none,
                  no_simd_src: nil,
                  fixlen: nil,
                  face_gate: nil,
                  object_escape: nil,
                  identity_on_empty: false,
                  outputs: 1,
                  # Two-pass centred algorithm (variance / stddev family).
                  # When algorithm: :two_pass_centred is set, `state / init /
                  # reduce / finish` are ignored -- a dedicated emitter
                  # walks each slab twice (Pass 1: Σx -> mean, Pass 2:
                  # Σ(x-mean)² -> M2) and produces variance = M2/divisor,
                  # optionally sqrt-clamped for stddev.  Both passes reuse
                  # the existing SL.1.1 CA_SLAB_REDUCE_T_PLUS_EX macro so
                  # SIMD :plus reduction license carries over.  Cancellation-
                  # free even at absolute values >= 1e6 (= the one-pass
                  # Σx² - (Σx)²/n form loses relative precision there and
                  # drops the sign for >= 1e8; two-pass centred stays at
                  # ε-close over the entire f64 range).  Reference:
                  # devel/PROPOSAL_VARIANCE_STABLE_KERNEL.md.
                  # state_from_slab_size: [:cnt, ...]
                  #   Names of state vars whose per-cell increment in REDUCE
                  #   is equivalent to `st.slab_elements - masked_cnt` at
                  #   the end of a slab walk.  Opting in lets the 8-way
                  #   emit path skip the per-cell increment (which can't
                  #   ride the 8-way fixed op) and derive the final value
                  #   outside the loop.  Currently used only by :mean
                  #   ({acc, cnt} where cnt++ per non-masked cell).
                  state_from_slab_size: nil,
                  algorithm: nil,
                  # Two-pass options:
                  #   divisor: :n          -> population (variancep/stddevp)
                  #   divisor: :n_minus_1  -> sample     (variance/stddev)
                  divisor: nil,
                  # Output transform after variance computation.
                  #   nil          -> variance (identity)
                  #   :sqrt_clamp  -> sqrt(fmax(variance, 0.0))  (stddev)
                  # fmax defends against tiny negative values from Pass 2's
                  # SIMD lane reassociation on constant / near-constant slabs.
                  output_transform: nil)
    raise "reduce: unknown semantics #{semantics} (expected :fiber_local or :view_flat)" \
      unless %i[fiber_local view_flat].include?(semantics)
    # face_gate: :strip descends an ORDERABLE Face to its storage at dispatch
    # entry (shared with the sort family gate), so order-structure reductions
    # (min/max/min_index/max_index) run the numeric comparison path instead of
    # the surface-fixlen memcmp branch.  Only order-structure kernels opt in;
    # arithmetic reductions (sum/mean/variance) keep the fixlen gate closed.
    # :strip  -- position-returning kernels (min_index/max_index): descend
    #            only, output (an axis-local index) needs no re-lift.
    # :relift -- value-returning kernels (min/max): descend, then re-lift the
    #            output back into the Face -- a full-reduction scalar via the
    #            registered storage_to_scalar hook, a per-axis CArray via
    #            rb_ca_face_template (carries the subclass tail, e.g. unit).
    raise "reduce: unknown face_gate #{face_gate} (expected nil, :strip, or :relift)" \
      unless [nil, :strip, :relift].include?(face_gate)
    # object_escape: a Symbol naming a Ruby instance method that handles the
    # CA_OBJECT case.  The generated dispatcher intercepts CA_OBJECT source at
    # entry and forwards argc/argv verbatim to that method (= runtime.rb
    # composition), so :object need NOT appear in source:.  Used where a
    # dedicated :object kernel branch is not worth it (weighted reductions:
    # weight-coerce vs CA_OBJECT integration is cleaner as (w*self).sum in Ruby).
    if object_escape
      raise "#{name}: object_escape must be a Symbol" unless object_escape.is_a?(Symbol)
      raise "#{name}: object_escape and source: :object are mutually exclusive" \
        if source.include?(:object)
    end
    raise "duplicate kernel #{name}" if KERNELS.any? { |k| k[:name] == name }
    source.each do |s|
      raise "unknown source data_type #{s}" unless DTYPES.key?(s)
    end
    raise "unknown output #{output}" unless output == :preserve || DTYPES.key?(output) || output.is_a?(Hash)
    raise "unknown fallback #{fallback}" unless %i[raise wrap_to_f64].include?(fallback)
    raise "unknown mask_policy #{mask_policy}" unless [nil, :strict, :all_masked, :min_count].include?(mask_policy)
    # ERI.0: identity_on_empty makes empty / all-masked slabs emit the
    # reduction identity (= acc_init via finish: "acc") instead of UNDEF,
    # for the default min_count (< 0).  Only meaningful for :min_count
    # kernels whose finish returns the accumulator unchanged (sum/prod/
    # count/accumulate/wsum) -- NOT ratio kernels (mean/variance) whose
    # finish divides (0/0 must stay UNDEF).
    if identity_on_empty
      raise "#{name}: identity_on_empty requires mask_policy: :min_count" \
        unless mask_policy == :min_count
      # Structural guard: finish must return the accumulator unchanged, so
      # empty / all-masked (acc == acc_init) yields the identity.  Single-
      # accumulator kernels (state omitted = sugar, or a 1-entry state Hash)
      # satisfy this; multi-state ratio kernels (mean {acc,cnt} / variance
      # {acc,sumsq,cnt} / wmean {sum,den}) and multi-output (minmax) divide
      # or combine in finish and MUST stay UNDEF on empty (0/0 undefined).
      single_acc = state.nil? || (state.is_a?(Hash) && state.size == 1)
      raise "#{name}: identity_on_empty requires a single-accumulator reduction (sum/prod/count/accumulate/wsum); mean/variance/wmean/minmax are excluded" \
        unless single_acc && outputs == 1
    end
    # SL.1.0: reduction_kind: licenses a SIMD-friendly contig-branch macro
    # variant (CA_SLAB_REDUCE_T_{PLUS,MIN,MAX,STAR,VAR}_EX).  default
    # :none keeps the existing CA_SLAB_REDUCE_T_EX path (= unchanged
    # behavior for argmin/argmax/any/all/etc).  Multi-acc variants pass
    # a Hash (= variance: { sum: :plus, sumsq: :plus, cnt: :induction }).
    # See PROPOSAL_REDUCTION_SIMD_LICENSE §2.3.
    unless reduction_kind == :none ||
           %i[plus min max star induction].include?(reduction_kind) ||
           reduction_kind.is_a?(Hash)
      raise "#{name}: unknown reduction_kind #{reduction_kind.inspect} " \
            "(expected :none, :plus, :min, :max, :star, :induction, or Hash)"
    end
    if reduction_kind.is_a?(Hash)
      reduction_kind.each do |k, v|
        unless %i[plus min max star induction none].include?(v)
          raise "#{name}: reduction_kind[#{k.inspect}] = #{v.inspect} invalid"
        end
      end
    end
    if value_arg
      raise "#{name}: value_arg must be a Hash" unless value_arg.is_a?(Hash)
      raise "#{name}: value_arg: target must be :T_IN" unless value_arg[:target] == :T_IN
    end

    # CA_FIXLEN reduce path.  A fixlen cell is a runtime-width byte blob
    # with no scalar C type, so it can't ride CA_SLAB_REDUCE_T (typed on
    # `sizeof(T)`).  `fixlen:` opts a reduce kernel into a bespoke slab walk
    # (emit_reduce_native_fixlen) that orders cells by memcmp -- the same
    # lexicographic total order the sort family gives CA_FIXLEN.  The value
    # selects direction (:min / :max) and output kind:
    #   :min / :max       -> extremum blob, output data_type = CA_FIXLEN
    #   :argmin / :argmax -> position of the extremum, output i64
    # Author must also list :fixlen in source: (parallel to how :object
    # opts in via source: + an :object body).
    if fixlen
      unless %i[min max argmin argmax].include?(fixlen)
        raise "#{name}: fixlen: must be :min / :max / :argmin / :argmax (got #{fixlen.inspect})"
      end
      raise "#{name}: fixlen: requires :fixlen in source:" unless source.include?(:fixlen)
      raise "#{name}: fixlen: requires mask_policy: :min_count" unless mask_policy == :min_count
      raise "#{name}: fixlen: requires outputs: 1" unless outputs == 1
      raise "#{name}: fixlen: does not support value_arg / array_arg" if value_arg || array_arg
    elsif source.include?(:fixlen)
      raise "#{name}: source includes :fixlen but no fixlen: spec given"
    end

    # FM.1 (PROPOSAL_FUSED_MINMAX): multi-output reduce (= fused minmax etc).
    # outputs: 2 is the only non-default form supported.  Compatibility gates:
    #   - finish must be Hash with exactly 2 entries (e.g. {min: "lo", max: "hi"})
    #     — the Hash keys are informational only (= used as Ruby return-shape
    #     placeholders); the values are the per-output finish expressions.
    #   - mask_policy: nil for FM.1.0; mask propagation to multi-output added
    #     in FM.1.5.
    #   - value_arg / array_arg / view_flat: rejected in FM.1.0 (= no demand,
    #     scope creep avoidance per PROPOSAL §2.2).
    #   - reduction_kind: must be :none (= multi-output uses
    #     CA_SLAB_REDUCE_T_EX baseline, SIMD license per reduction is future
    #     work — proposal §8.3).
    raise "#{name}: outputs must be Integer 1 or 2 (got #{outputs.inspect})" \
      unless outputs.is_a?(Integer) && (1..2).include?(outputs)
    if outputs == 2
      raise "#{name}: outputs: 2 requires finish: Hash with exactly 2 entries" \
        unless finish.is_a?(Hash) && finish.size == 2
      raise "#{name}: outputs: 2 with mask_policy supports only nil or :min_count (FM.1.5)" \
        unless [nil, :min_count].include?(mask_policy)
      raise "#{name}: outputs: 2 currently does not support value_arg / array_arg (FM.1.0)" \
        if value_arg || array_arg
      raise "#{name}: outputs: 2 requires semantics: :fiber_local (FM.1.0)" \
        unless semantics == :fiber_local
      raise "#{name}: outputs: 2 requires reduction_kind: :none (FM.1.0)" \
        unless reduction_kind == :none
    end
    if array_arg
      raise "#{name}: array_arg must be a Hash" unless array_arg.is_a?(Hash)
      raise "#{name}: array_arg: name is required" unless array_arg[:name]
      # data_type: :promote (= weights materialized at the kernel's f64
      # computation type, read as `double` in the body) decouples the weight
      # cell C type from the source cell C type.  This is the correct form:
      # the reduce body computes `(double) v * (double) w`, so a float weight
      # against an int source must not be truncated to the source type.
      # :match_source (legacy) reads the weight at the source type -- kept only
      # for forward-compat in the DSL grammar (no production kernel uses it).
      raise "#{name}: array_arg: data_type must be :promote or :match_source" \
        unless [:promote, :match_source].include?(array_arg[:data_type])
      # PROPOSAL_REDUCTION_PER_FIBER_AUX_OPERAND rev1: shape acceptance expanded
      # to W-A1 (scalar) / W-A2 (1-D axis-broadcast) / W-A3 (same shape).
      # :match_source = legacy W-A3 only (kept for forward-compat in DSL).
      # :rev5_strict = W-A1 + W-A2 + W-A3 acceptance (= new default for wsum/wmean).
      raise "#{name}: array_arg: shape must be :match_source or :rev5_strict" \
        unless [:match_source, :rev5_strict].include?(array_arg[:shape])
      raise "#{name}: array_arg: mask must be :overlay (W.1 MVP)" \
        unless array_arg[:mask] == :overlay
      raise "#{name}: array_arg + value_arg in same kernel is not supported (W.1 MVP)" \
        if value_arg
      raise "#{name}: array_arg + :wrap_to_f64 fallback is not supported (W.1 MVP); use :raise" \
        if fallback == :wrap_to_f64
    end

    # algorithm: :two_pass_centred is a self-contained emit path.  state /
    # init / reduce / finish / reduction_kind are supplied internally; any
    # user-supplied values are ignored.  Validate the algorithm-specific
    # kwargs instead.
    if algorithm
      raise "#{name}: algorithm must be :two_pass_centred (got #{algorithm.inspect})" \
        unless algorithm == :two_pass_centred
      raise "#{name}: two_pass_centred requires divisor: :n or :n_minus_1 (got #{divisor.inspect})" \
        unless [:n, :n_minus_1].include?(divisor)
      raise "#{name}: two_pass_centred output_transform must be nil or :sqrt_clamp (got #{output_transform.inspect})" \
        unless [nil, :sqrt_clamp].include?(output_transform)
      raise "#{name}: two_pass_centred is incompatible with array_arg / value_arg / outputs>1 / view_flat / fixlen" \
        if array_arg || value_arg || outputs != 1 || semantics != :fiber_local || fixlen
      # Neutralize downstream pipeline fields.
      state           = { acc: :acc_type }
      init            = { acc: "0" }
      finish          = "acc"
      reduce        ||= "acc += v"
      reduction_kind  = :none
    end

    # Normalise to multi-state form.
    if state.nil?
      # Single-acc sugar: init is a String (or Hash for per-family),
      # no finish.
      raise "#{name}: when state: is omitted, init: must be a String or Hash" \
        unless init.is_a?(String) || init.is_a?(Hash)
      raise "#{name}: finish: not allowed in single-acc form" if finish
      state  = { acc: :acc_type }
      init   = { acc: init }
      finish = "acc"
    else
      raise "#{name}: state must be a Hash"                if !state.is_a?(Hash)
      raise "#{name}: state must be non-empty"             if state.empty?
      raise "#{name}: init must be a Hash"                 if !init.is_a?(Hash)
      raise "#{name}: init keys must match state keys"     if state.keys.sort != init.keys.sort
      if outputs == 1
        finish ||= state.keys.first.to_s   # default: return the first state var
      end
      # outputs == 2: finish is already validated as Hash above
      # No re-ordering: state.keys.first becomes the macro's accumulator
      # argument.  Author controls which var that is by listing order.
    end

    KERNELS << {
      kind:            :reduce,
      name:            name,
      state:           state,
      init:            init,
      reduce:          reduce,
      finish:          finish,
      source:          source,
      output:          output,
      ruby_scalar:     ruby_scalar,
      fallback:        fallback,
      mask_policy:     mask_policy,
      value_arg:       value_arg,
      array_arg:       array_arg,
      semantics:       semantics,
      public_method: public_method,
      bind_ruby:       bind_ruby,
      smoke:           smoke,
      reduction_kind:  reduction_kind,
      no_simd_src:     no_simd_src,
      fixlen:          fixlen,
      face_gate:       face_gate,
      object_escape:   object_escape,
      identity_on_empty: identity_on_empty,
      outputs:         outputs,
      algorithm:       algorithm,
      divisor:         divisor,
      output_transform: output_transform,
      state_from_slab_size: state_from_slab_size,
    }
  end

  # Register a map kernel (element-wise transform: input shape == output
  # shape, one cell at a time).  Each generated helper walks the input
  # and output slabs in lockstep using CA_SLAB_MAP_T(T_LOAD, T_OUT, ...).
  #
  # DSL:
  #   MkKernel.map :name,
  #     source:   MkKernel::ALL_NUMERIC,
  #     output:   :f64 | :preserve,
  #     expr:     "r = sqrt((double) v)",   # binds v (input) + r (output)
  #     fallback: :wrap_to_f64 | :raise
  #
  # Generated method takes no arguments (`a.sqrt_ki` not `a.sqrt_ki(0)`)
  # since the operation is per-cell across the whole array.
  def self.map(name, source:, output:, expr:, fallback: :raise)
    raise "duplicate kernel #{name}" if KERNELS.any? { |k| k[:name] == name }
    source.each do |s|
      raise "unknown source data_type #{s}" unless DTYPES.key?(s)
    end
    raise "unknown output #{output}" unless output == :preserve || DTYPES.key?(output) || output.is_a?(Hash)
    raise "unknown fallback #{fallback}" unless %i[raise wrap_to_f64].include?(fallback)
    if output == :preserve && fallback == :wrap_to_f64
      raise "#{name}: :preserve + :wrap_to_f64 is a semantic conflict " \
            "(fallback path produces f64 output, contradicting :preserve)"
    end

    KERNELS << {
      kind:     :map,
      name:     name,
      source:   source,
      output:   output,
      expr:     expr,
      fallback: fallback,
    }
  end

  # Register a scan kernel (cumulative / prefix-scan: input shape ==
  # output shape, running accumulator along one axis).  The generated
  # method takes exactly one axis argument (e.g., `a.cumsum_ki(0)`).
  #
  # DSL:
  #   MkKernel.scan :name,
  #     source:   MkKernel::ALL_NUMERIC,
  #     output:   :f64 | :preserve,
  #     init:     "0",                   # initial acc value (per fiber)
  #     step:     "acc += v; r = acc",   # binds v (T_LOAD), r (T_OUT), acc
  #     fallback: :wrap_to_f64 | :raise
  #
  # Init supports the same special tokens as reduce: T_LIMIT_HI /
  # T_LIMIT_LO / T_ACC / T_OUT.  Each scan slab (= fiber along the
  # scan axis) starts with acc = INIT independently of other slabs.
  # acc_type:
  #   nil           -> T_OUT (= existing behavior, cumsum/cumprod/...)
  #   :load_type    -> T_LOAD (= source data_type, for adjacent-compare scans
  #                    like uniq_scan where the acc holds the last seen
  #                    INPUT value).  Emits CA_SLAB_SCAN_TA and exposes
  #                    `first` (int, 1 on first unmasked cell) to STEP.
  # axis_default:
  #   nil           -> axis: kwarg is required; nil/omitted raises
  #                    (= scan family default, preserves "multi-axis scan
  #                    is semantically ambiguous" stance for new kernels).
  #   :flatten      -> axis: nil (or omitted) flattens the source and
  #                    scans the resulting 1-D array.  Used by legacy
  #                    cumsum/cumprod/cummax/cummin/cumcount whose pre-3.0
  #                    no-arg form returned a flat cumulative.
  # empty:
  #   nil           -> masked input cells write the running accumulator to
  #                    the output, unmasked (= cumsum / cumprod / cumcount:
  #                    the empty prefix is the identity 0 / 1 / 0, a defined
  #                    value).  Emits CA_SLAB_SCAN_T.
  #   :undef        -> "seen-gated" extremum scan (cummax / cummin): the
  #                    accumulator has no identity, so a fiber's output is
  #                    UNDEF (masked) until its first present cell.  Emits
  #                    CA_SLAB_SCAN_T_GATED and allocates an output mask when
  #                    the input carries one (leading-masked cells are the
  #                    only cells that can go UNDEF, and they exist only when
  #                    the input is masked).  Aligns core cummax / cummin with
  #                    the reduction contract (empty max / min = UNDEF, no
  #                    identity) and the axis-group scan family.
  def self.scan(name, source:, output:, init:, step:, fallback: :raise,
                acc_type: nil, axis_default: nil, empty: nil)
    raise "duplicate kernel #{name}" if KERNELS.any? { |k| k[:name] == name }
    source.each do |s|
      raise "unknown source data_type #{s}" unless DTYPES.key?(s)
    end
    raise "unknown output #{output}" unless output == :preserve || DTYPES.key?(output) || output.is_a?(Hash)
    raise "unknown fallback #{fallback}" unless %i[raise wrap_to_f64].include?(fallback)
    if output == :preserve && fallback == :wrap_to_f64
      raise "#{name}: :preserve + :wrap_to_f64 is a semantic conflict"
    end
    unless acc_type.nil? || acc_type == :load_type
      raise "#{name}: unknown acc_type #{acc_type.inspect} (nil | :load_type)"
    end
    unless axis_default.nil? || axis_default == :flatten
      raise "#{name}: unknown axis_default #{axis_default.inspect} (nil | :flatten)"
    end
    unless empty.nil? || empty == :undef
      raise "#{name}: unknown empty #{empty.inspect} (nil | :undef)"
    end
    if empty == :undef && acc_type == :load_type
      raise "#{name}: empty: :undef is not supported with acc_type: :load_type"
    end

    KERNELS << {
      kind:         :scan,
      name:         name,
      source:       source,
      output:       output,
      init:         init,
      step:         step,
      fallback:     fallback,
      acc_type:     acc_type,
      axis_default: axis_default,
      empty:        empty,
    }
  end

  # Register a sort-family kernel (per-fiber sort returning positions:
  # input shape == output shape, one axis at a time).  Generated method
  # takes exactly one axis argument.
  #
  # Semantics (rev6):
  #   :fiber_local  -> output[cell] in 0..dim[axis]-1 (sort index
  #                    along axis).  Used by sort_index_ki, the user-
  #                    facing sort-index entry.
  #   :view_flat    -> output[cell] = view-flat address (0..elements-1)
  #                    of the original cell.  Suitable for direct feed
  #                    into ca_remap_new (= CARemap.idx contract).  Used
  #                    by sort_addr_ki (internal, bind_ruby: false), the
  #                    underlying kernel for `a.sort(axis: k)`.
  #
  # NaN policy:
  #   :end          -> NaN cells sort to the end (matches existing
  #                    qcmp_f_type in carray_sort.c)
  #
  # Stability is **always guaranteed** by pairing each fiber value with
  # its original fiber-local index and tie-breaking on that index inside
  # the cmp function (= sort_addr.c pattern).  The underlying sort routine
  # is mergesort(3) on macOS/BSD (HAVE_MERGESORT) and qsort() elsewhere
  # (= Linux glibc qsort is msort-based, so stable in practice).
  #
  # Sort kind selection (:quicksort / :mergesort / :stable / :heapsort) is
  # NOT exposed on the Ruby surface in 3.0 (rev5 design decision); add it
  # back via kind_options field if/when demand emerges.
  #
  # bind_ruby:
  #   true (default)  -> rb_define_method(rb_cCArray, "<name>_ki", ...).
  #   false           -> emit rb_ca_<name>_ki C entry but DO NOT bind
  #                      a Ruby method.  Used by sort_addr_ki which is
  #                      consumed only at the C level by the public
  #                      `sort(axis:)` method (= rev6 design, rev3
  #                      defers `sort_addr(axis:)` public form).
  #
  # DSL:
  #   MkKernel.sort :sort_index,
  #     source:     MkKernel::ALL_NUMERIC,
  #     output:     :ca_size,        # ca_size_t / CA_SIZE
  #     semantics:  :fiber_local,    # per-axis sort index
  #     nan_policy: :end,            # only mode in 3.0
  #     fallback:   :raise           # :wrap_to_f64 not meaningful for sort
  #
  #   MkKernel.sort :sort_addr,
  #     source:     MkKernel::ALL_NUMERIC,
  #     output:     :ca_size,
  #     semantics:  :view_flat,      # CARemap.idx direct feed
  #     nan_policy: :end,
  #     fallback:   :raise,
  #     bind_ruby:  false            # internal-only kernel
  #
  # algorithm: (SO.3+, rev8)
  #   :full       (default) -> full stable sort (qsort/mergesort).  Ruby
  #                method takes 1 positional arg (axis).
  #   :partition  -> quickselect: ensures arr[kth] is the kth-smallest;
  #                arr[0..kth-1] <= arr[kth]; arr[kth+1..n-1] >= arr[kth].
  #                Order WITHIN the < and > regions is unspecified.
  #                Ruby method takes 2
  #                positional args (axis, kth).  Used by
  #                partition_index_ki / partition_addr_ki.
  #
  # mask_self: (MASKED_POSITION rev1)
  #   :raise     -> ca_has_mask(self) raises ArgumentError before dispatch;
  #                 the kernel body never sees a masked source.
  #   :skip      -> masked cells are excluded from the sort entirely (used
  #                 by rank_index: a masked cell has no valid-value rank,
  #                 output cell is UNDEF).
  #   :sentinel  -> masked cells are treated as an incomparable sentinel,
  #                 the same role NaN plays for :end nan_policy but runtime-
  #                 selectable and dtype-agnostic.  Per fiber, unmasked
  #                 cells are compacted into a contiguous sub-range and only
  #                 that sub-range is sorted/quickselected; masked cells are
  #                 compacted into the complementary sub-range at the head
  #                 (masked_last: false) or tail (masked_last: true,
  #                 default) of the fiber, in unspecified relative order
  #                 (same "unspecified order within a region" contract as
  #                 :partition's < / > regions).  The generated native
  #                 kernel gains a runtime `int masked_last` parameter; the
  #                 2-arg / 3-arg convenience entries (`_ki`, `_ki_quick`,
  #                 `_ki_stable`) hardcode masked_last=1 (:last) so existing
  #                 C-level callers keep working unchanged on masked input
  #                 instead of raising.  The `masked_position:` kwarg is
  #                 exposed on the public_method: kwarg trampoline; kernels
  #                 with bind_ruby: false additionally get `_mp`-suffixed
  #                 C-callable twins (`_ki_quick_mp` / `_ki_stable_mp` /
  #                 `_ki_mp`) taking an explicit masked_last so cross-file
  #                 callers (carray_sort.c / carray_partition.c) can pass
  #                 the user's choice through.  Position-returning kernels
  #                 (sort_index / sort_addr / partition_index /
  #                 partition_addr) need no output mask handling: the
  #                 payload is a location, and a masked cell's location is
  #                 well-defined regardless of its value.
  def self.sort(name, source:, output:, semantics: :fiber_local,
                nan_policy: :end, fallback: :raise, bind_ruby: true,
                algorithm: :full, mask_self: :raise, public_method: nil,
                c_callable: false)
    raise "duplicate kernel #{name}" if KERNELS.any? { |k| k[:name] == name }
    source.each do |s|
      raise "unknown source data_type #{s}" unless DTYPES.key?(s)
    end
    raise "unknown output #{output}" unless DTYPES.key?(output)
    raise "sort: unknown semantics #{semantics} (expected :fiber_local or :view_flat)" \
      unless %i[fiber_local view_flat].include?(semantics)
    raise "sort: only :end nan_policy supported in 3.0 (got #{nan_policy})" \
      unless nan_policy == :end
    raise "sort: only :raise fallback supported (got #{fallback})" \
      unless fallback == :raise
    raise "sort: unknown algorithm #{algorithm} (expected :full | :partition | :rank)" \
      unless %i[full partition rank].include?(algorithm)
    raise "sort: unknown mask_self #{mask_self} (expected :raise | :skip | :sentinel)" \
      unless %i[raise skip sentinel].include?(mask_self)
    raise "sort: :rank algorithm requires :fiber_local semantics" \
      if algorithm == :rank && semantics != :fiber_local

    KERNELS << {
      kind:            :sort,
      name:            name,
      source:          source,
      output:          output,
      semantics:       semantics,
      nan_policy:      nan_policy,
      fallback:        fallback,
      bind_ruby:       bind_ruby,
      algorithm:       algorithm,
      mask_self:       mask_self,
      public_method: public_method,
      c_callable:      c_callable,
    }
  end

  # Register a search-family kernel (per-(base, query) scalar return:
  # one slab axis on `self`, query broadcast against base_shape with
  # tail-append rule for incompatible shapes).  Generated method takes
  # a `val` argument (scalar or CArray) and `axis:` keyword.
  #
  # Phase S.1 (PROPOSAL_SEARCH_AXIS_S1.md rev2): DSL form only — emit
  # is implemented in S.1.2.  Registering a :search kernel before S.1.2
  # lands will fail at `MkKernel.emit` time (unknown kind in dispatch),
  # which is the intended guard rail.
  #
  # Author surface (Q1=B sparring confirmed): the author writes the
  # inner per-slab kernel body in C, the generator emits the outer
  # (query × base) walk.  This is needed because:
  #   - bsearch family calls libc bsearch() directly
  #   - search family does per-cell eps comparison + early-exit
  #   - search_nearest does full slab scan + distance tracking
  # ... none of which fit a single `match:` expression.  Trading off
  # author convenience (~15 lines of C body) for production flexibility
  # across all 5 families.
  #
  # Broadcast rule (Q2=A sparring confirmed, PROPOSAL_SEARCH_AXIS §2.3):
  #   base_shape = self.shape with axis removed
  #   if val.shape broadcasts against base_shape:
  #     output.shape = broadcast(base_shape, val.shape)
  #   else:
  #     output.shape = (*base_shape, *val.shape)   # query axes appended
  #
  # DSL:
  #   MkKernel.search :find_value_index,
  #     source:   MkKernel::ALL_NUMERIC,
  #     output:   :ca_size,
  #     body:     <<~C,
  #       /* binds:
  #            slab_ptr     (char *)     -- per-slab base pointer
  #            slab_n       (ca_size_t)  -- slab length (= dim[axis])
  #            slab_stride  (ca_size_t)  -- byte stride along slab axis
  #            query_val    (T_LOAD)     -- query value for this output cell
  #            result       (ca_size_t * out, write here)
  #            mask_in      (boolean8_t *, NULL if no mask) -- per-slab mask
  #          author sets *result to no-match sentinel or matched index.
  #       */
  #       *result = -1;
  #       for (ca_size_t i = 0; i < slab_n; i++) {
  #         T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
  #         if (v == query_val) { *result = i; break; }
  #       }
  #     C
  #     mask_self: :raise,             # :raise | :skip | :ignore
  #     fallback:  :raise
  #
  # mask_self semantics (S.1 minimal):
  #   :raise   -> ca_is_any_masked(self) raises RuntimeError (bsearch family)
  #   :skip    -> per-slab mask is forwarded to author via mask_in binding
  #               (search / search_nearest family)
  #   :ignore  -> mask not passed (rare)
  #
  # Output data_type is typically :ca_size (= ca_size_t / CA_SIZE) for index-
  # returning kernels.  Other output data_types are accepted but their semantic
  # is up to the body (= value-returning search variants).
  def self.search(name, source:, output:, body:,
                  no_match: "-1", no_match_check: nil, undef_no_match: false,
                  mask_self: :raise, mask_query: :ignore, runtime_args: nil,
                  fallback: :raise, semantics: :fiber_local)
    raise "search: unknown semantics #{semantics} (expected :fiber_local or :view_flat)" \
      unless %i[fiber_local view_flat].include?(semantics)
    raise "duplicate kernel #{name}" if KERNELS.any? { |k| k[:name] == name }
    source.each do |s|
      raise "unknown source data_type #{s}" unless DTYPES.key?(s)
    end
    raise "unknown output #{output}" unless DTYPES.key?(output)
    raise "search: no_match must be a String" unless no_match.is_a?(String)
    raise "search: unknown mask_self #{mask_self} (expected :raise | :skip | :ignore)" \
      unless %i[raise skip ignore].include?(mask_self)
    # mask_query: what a masked query cell means.  :ignore reads the value
    # under the mask (the historical behaviour).  :undef treats the query as
    # having no answer and marks the corresponding output cell UNDEF, so an
    # undetermined query cannot silently become a determined result.
    raise "search: unknown mask_query #{mask_query} (expected :ignore | :undef)" \
      unless %i[ignore undef].include?(mask_query)
    raise "search: unknown fallback #{fallback} (expected :raise)" \
      unless fallback == :raise

    # body: either String (uniform across data_types) or Hash {int:, float:}
    # for per-data_type-kind branching (= S.3 search family uses Hash form to
    # emit exact-match for ints vs eps-fuzzy compare for floats).
    case body
    when String
      # uniform body
    when Hash
      allowed = %i[int float object fixlen]
      unless (body.keys - allowed).empty? && body.key?(:int) && body.key?(:float)
        raise "search: body Hash must have :int and :float keys (plus optional :object / :fixlen), got #{body.keys.inspect}"
      end
      unless body.values.all? { |v| v.is_a?(String) }
        raise "search: body Hash values must be String"
      end
    else
      raise "search: body must be a String or Hash {int:, float:}, got #{body.class}"
    end

    # runtime_args: optional Array of symbols.  Currently supports :eps
    # for float-fuzzy comparison in the search family.  Each arg becomes
    # an optional positional in the generated Ruby method signature.
    if runtime_args
      raise "search: runtime_args must be an Array" unless runtime_args.is_a?(Array)
      runtime_args.each do |arg|
        raise "search: unknown runtime_arg #{arg.inspect} (expected :eps)" \
          unless arg == :eps
      end
    end

    if no_match_check && ! no_match_check.is_a?(String)
      raise "search: no_match_check must be a String C expression (or nil for default == compare)"
    end

    # undef_no_match: when true, a per-fiber / per-cell no-match (= result ==
    # no_match sentinel) marks the corresponding output cell UNDEF (masked)
    # instead of writing the raw -1 sentinel.  This unifies the "not found"
    # representation with the no-axis flat path, which already returns UNDEF
    # for array queries (PROPOSAL_SEARCH_SEMANTICS_UNIFY S1).  Only valid for
    # the default-sentinel family (no_match_check == nil); the NAN-sentinel
    # interpolation kernels (linear_section / linear_fetch) keep their in-band
    # float sentinel and must not set this flag.
    if undef_no_match && no_match_check
      raise "search: undef_no_match is incompatible with a custom no_match_check (NAN-sentinel kernels keep their in-band sentinel)"
    end

    # CA_FIXLEN cells are runtime-width byte blobs compared with memcmp, so a
    # fixlen source needs its own body branch (no scalar T_LOAD).
    if source.include?(:fixlen) && body.is_a?(Hash) && !body.key?(:fixlen)
      raise "search: source includes :fixlen but body Hash has no :fixlen branch"
    end

    KERNELS << {
      kind:            :search,
      name:            name,
      source:          source,
      output:          output,
      body:            body,
      no_match:        no_match,
      no_match_check:  no_match_check,
      undef_no_match:  undef_no_match,
      mask_self:       mask_self,
      mask_query:      mask_query,
      runtime_args:    runtime_args || [],
      fallback:        fallback,
      semantics:       semantics,
    }
  end

  # ---- P.5b.1 (mkmath retarget B1): math family DSL ----------------------
  #
  # Eager monop: `<op>` is a per-element function `T -> T` (preserve) or
  # `T -> Twider` (widening; widening is handled in carray_math.rb's
  # legacy emit, but we keep the DSL parameter for symmetry).  The
  # emitted kernel signature matches mkmath's calling convention:
  #
  #   void ca_monop_<name>_<ctype>(ca_size_t n, boolean8_t *m,
  #                                char *ptr1, ca_size_t i1,
  #                                char *ptr2, ca_size_t i2);
  #
  # Per-family expressions use the mkmath placeholder convention where
  # `#1` = `*p1` (input cell) and `#2` = `*p2` (output cell).  An expr
  # may be given either as a single string (= same expression for all
  # source data_types in `source:`) or as a Hash keyed by data_type family aliases
  # `:numeric` / `:bool` / `:complex` / `:object` (= matches the mkmath
  # `BOOL_TYPES => ..., ALL_TYPES => ..., CMPLX_TYPES => ..., OBJ_TYPES
  # => ...` form).
  #
  # `bind:` defaults to true (= register CArray#<name> + CArray#<name>!).
  # `op:` defaults to name (= the public method name; some mkmath ops
  # use a different operator name from the kernel suffix, e.g. operator
  # methods).
  def self.monop(name, source:, expr:, op: nil, bind: true, cmath: true,
                 widening: nil, output: :preserve)
    op ||= name
    # widening = true => emit wrapper that auto-casts integer input to
    # CA_FLOAT64 (= mkmath monfunc behavior).  Default: auto-detect based
    # on source — if no integer data_type is in source, the kernel can't
    # accept integer input directly, so the wrapper must auto-cast.
    widening = (source & ALL_NUMERIC.select { |d| d.to_s.start_with?("i", "u") }).empty? if widening.nil?
    # output: :preserve (default, = output data_type == input data_type) or a
    # Hash form { numeric: :preserve, complex: :f64 } (= data_type-family
    # conditional output for monops like abs where complex source
    # demotes to real f64).  Hash form requires the kernel author to
    # write expr that produces output data_type values for each source family
    # (e.g. cabs() for complex returning double).
    raise "#{name}: unknown output #{output}" unless output == :preserve || DTYPES.key?(output) || output.is_a?(Hash)
    KERNELS << {
      kind:     :monop,
      name:     name,
      op:       op,
      source:   source,
      expr:     expr,
      bind:     bind,
      cmath:    cmath,
      widening: widening,
      output:   output,
    }
  end

  # Convenience: `MkKernel.monfunc` is a declarative alias of `.monop`
  # (signalling "this is a math function" for readability).  Auto-cast
  # of integer input to f64 is decided by `monop`'s widening auto-detect
  # based on whether `source:` includes integer data_types — matching mkmath's
  # rule "if no INT_TYPES key, auto-cast; otherwise rely on integer kernel".
  def self.monfunc(name, source:, expr:, op: nil, bind: true, cmath: true)
    monop(name, source: source, expr: expr, op: op, bind: bind, cmath: cmath)
  end

  # Register an alias of an existing monop method under a different
  # Ruby method name.  Used for operator-style aliases like `-@ -> neg`
  # and `~ -> bit_neg`.  No kernel emission, only an `rb_define_alias`
  # entry in Init_carray_kernels.
  def self.alias_monop(op, name)
    KERNELS << { kind: :monop_alias, op: op.to_s, name: name.to_s }
  end

  # ---- P.5b.3: binop DSL ------------------------------------------------
  #
  # Eager binop: per-element function `(T, T) -> T` (preserve data_type).  The
  # emitted kernel signature matches mkmath's calling convention:
  #
  #   void ca_binop_<name>_<ctype>(ca_size_t n, boolean8_t *m,
  #                                 char *ptr1, ca_size_t i1,
  #                                 char *ptr2, ca_size_t i2,
  #                                 char *ptr3, ca_size_t i3);
  #
  # Per-family expressions use `#1` = `*p1` (left input), `#2` = `*p2`
  # (right input), `#3` = `*p3` (output).  Same expr Hash conventions as
  # monop (= family alias or array-of-data_types keys).
  #
  # `op:` is the Ruby operator method name to register (= "+", "*", etc.).
  # When op is nil, only `<name>!` is registered (= internal kernels like
  # `and_i` / `or_i` that get exposed via hand-written boolean-coercing
  # wrappers in ext/carray_math.rb).
  def self.binop(name, source:, expr:, op: :auto, bind: true, kleene: nil)
    # `op: :auto` (default) means "register Ruby method with the same
    # name as the kernel" (mkmath convention: `binop("pmax", "pmax", ...)`).
    # Pass `op: "+"` etc. to use a different operator method name; pass
    # `op: nil` to skip the Ruby method registration entirely (= internal
    # kernels like and_i / or_i / xor_i exposed via hand-written wrappers).
    # `kleene: :and | :or` makes the (non-bang) wrapper apply the boolean
    # three-valued mask fixup after the value kernel (see ca_kleene_bool_fixup).
    op = name.to_s if op == :auto
    KERNELS << {
      kind:   :binop,
      name:   name,
      op:     op,
      source: source,
      expr:   expr,
      bind:   bind,
      kleene: kleene,
    }
  end

  # ---- triop DSL --------------------------------------------------------
  #
  # 3-input / 1-output kernel — same per-data_type mkkernel form as binop but
  # with one more input.  Used for fused 3-operand math primitives like
  # fma (= self*op2 + op3), fms, clip (lo, hi), etc.
  #
  # Expr placeholders:
  #   #1, #2, #3 = inputs (self, op2, op3)
  #   #4         = output
  #
  # No lazy substrate yet: triop kernels run eagerly via the
  # `rb_ca_call_triop` C bridge.  Per-axis / view universality / mask
  # SIMD fast path are inherited from the kernel signature (= same
  # element-stride form as binop).
  def self.triop(name, source:, expr:, op: :auto, bind: true, bang: true)
    op = name.to_s if op == :auto
    KERNELS << {
      kind:   :triop,
      name:   name,
      op:     op,
      source: source,
      expr:   expr,
      bind:   bind,
      bang:   bang,
    }
  end

  # Register an alias of an existing binop method.  Used for operator
  # aliases like `"add" -> "+"`, `"bit_and" -> "&"` etc.
  def self.alias_binop(alias_name, target_name)
    KERNELS << {
      kind:        :binop_alias,
      alias_name:  alias_name.to_s,
      target_name: target_name.to_s,
    }
  end

  # ---- P.5b.4: moncmp DSL ------------------------------------------------
  #
  # Eager moncmp: per-element predicate `T -> bool`.  Kernel signature:
  #
  #   void ca_moncmp_<name>_<ctype>(ca_size_t n, boolean8_t *m,
  #                                  char *ptr1, ca_size_t i1,
  #                                  boolean8_t *ptr2, ca_size_t i2);
  #
  # Output ptr2 is `boolean8_t *` (= 1 byte 0/1).  Public Ruby method
  # registered is `<op>` (default = name; pass `op: nil` to skip).
  # No `<name>!` registration (moncmp is read-only/predicate).
  def self.moncmp(name, source:, expr:, op: :auto)
    op = name.to_s if op == :auto
    KERNELS << {
      kind:   :moncmp,
      name:   name,
      op:     op,
      source: source,
      expr:   expr,
    }
  end

  # ---- P.5b.4: bincmp DSL ------------------------------------------------
  #
  # Eager bincmp: per-element predicate `(T, T) -> bool`.  Kernel
  # signature includes byte-width parameters b1/b2/b3 for FIXLEN cmp:
  #
  #   void ca_bincmp_<name>_<ctype>(ca_size_t n, boolean8_t *m,
  #                                  char *ptr1, ca_size_t b1, ca_size_t i1,
  #                                  char *ptr2, ca_size_t b2, ca_size_t i2,
  #                                  char *ptr3, ca_size_t b3, ca_size_t i3);
  #
  # For non-fixlen kernels b1/b2/b3 are unused (signature kept for
  # uniform dispatch table).  Expr placeholders `<type>` and `<epsilon>`
  # are substituted from DTYPES / EPSILON_FOR.  `<type>` becomes the C
  # type (e.g. "float32_t"), `<epsilon>` becomes "FLT_EPSILON" etc.
  # IC.1: tolerance:true ops (is_close / is_equiv) get an arity-2 Ruby
  # wrapper `rb_ca_<name>(self, other, tol_val)` and reference `tol` in
  # their expr.  Non-tolerance ops are arity 1 `(self, other)` and call
  # rb_ca_call_bincmp with tol=0.0.  Kernel signature is uniform (= the
  # double tol slot exists on every kernel; non-tolerance ops ignore it).
  def self.bincmp(name, source:, expr:, op: :auto, tolerance: false)
    op = name.to_s if op == :auto
    KERNELS << {
      kind:      :bincmp,
      name:      name,
      op:        op,
      source:    source,
      expr:      expr,
      tolerance: tolerance,
    }
  end

  # Register an alias of an existing bincmp method (= rb_define_alias,
  # e.g. ">" alias of "gt").  Same as alias_binop semantically; kept as
  # a separate kind for declarative clarity.
  def self.alias_bincmp(alias_name, target_name)
    KERNELS << {
      kind:        :bincmp_alias,
      alias_name:  alias_name.to_s,
      target_name: target_name.to_s,
    }
  end

  # ---- output data_type resolution -------------------------------------------

  # Returns the data_type info for the accumulator/output of a kernel given a
  # source data_type.  Forms:
  #   :preserve              -> output data_type = source data_type
  #   Symbol (e.g. :f64)     -> fixed output data_type
  #   Hash with family keys  -> data_type-conditional output, e.g.
  #     output: { numeric: :f64, complex: :cmplx128 }
  #     The Hash is scanned in declaration order; the first family alias
  #     matching `src` wins.  An optional `default:` key provides a
  #     fallback when no family matches.  Uses the same family aliases
  #     as monop_expr_family_match? (:numeric / :int / :float / :complex
  #     / :bool / :object).
  # SL.1.1: Resolve the reduce macro suffix for a given kernel entry,
  # driven by reduction_kind.  Returns "" for :none (= legacy
  # CA_SLAB_REDUCE_T_EX), or "_PLUS" / "_MIN" / "_MAX" / "_STAR" to
  # license a SIMD-friendly contig-branch variant.
  #
  # Hash reduction_kind picks the kind of state.keys.first (= the
  # accumulator that becomes the macro's formal `acc` arg).  Other
  # state vars (induction counters, secondary accumulators handled
  # inline by REDUCE) are auto-vectorised by the compiler when
  # appropriate.
  #
  # See PROPOSAL_REDUCTION_SIMD_LICENSE §2.3 + §5 Q2 closure.
  # Horizontal 8-way accumulator split (2026-07-19, extension of the
  # variance/stddev SUM8 fix): eligibility gate for the standard reducer
  # emit path.  Returns true when the caller should emit CA_SLAB_REDUCE_
  # {SUM,MIN,MAX,STAR}8_EX instead of the legacy single-accumulator
  # CA_SLAB_REDUCE_T_{PLUS,MIN,MAX,STAR}_EX.
  #
  # Ineligible:
  #   - suffix == ""  (:object src / no_simd_src override — reduce body
  #     is Ruby callback or dtype-specific, single-accumulator required)
  #   - array_arg (weighted reductions use the ARRAY_T_EX macro family,
  #     which has its own emit path)
  def self.reduce_8way_eligible?(k, src, suffix)
    return false if suffix == ""
    return false if src == :object
    return false if k[:array_arg]
    # Multi-state reducers (e.g. mean: {acc, cnt} with reduce body
    # `(acc += v, cnt++)`) embed the secondary update inside REDUCE.
    # The 8-way macros only replicate the fixed op on the primary
    # accumulator, so secondary state (cnt) would never be touched
    # inside the 8-way inner loop.  Two escape hatches:
    #   - single-state kernel (sum / min / max / prod / accumulate) OK
    #   - all non-primary states are declared in state_from_slab_size:
    #     the emitter derives them from (slab_elements - masked_cnt)
    #     after the 8-way call, so REDUCE's per-cell increment is
    #     safely skipped.  Currently the only user is :mean (cnt).
    if k[:state] && k[:state].size > 1
      derivable = Array(k[:state_from_slab_size])
      secondary = k[:state].keys[1..-1]
      return false unless (secondary - derivable).empty?
    end
    # Complex REDUCE body: 8-way assumes the fixed op (+/*/min/max)
    # applied to a value expression EXPR(v), and cannot honour a
    # predicated increment (count_equal: `if (v==value_arg) acc+=1`),
    # a boolean-only body (count_false: `acc += !v`), or anything
    # else that isn't a plain `acc OP v` shape.  Value-referencing
    # identifiers (value_arg) and conditionals block 8-way; derivable
    # state names (cnt for mean) are exempt from the block (they are
    # handled by the emitter's derivation after the 8-way call).
    reduce_body = pick_family_string(k[:reduce], src, "reduce").to_s
    disallow = /\b(value_arg|if|\?)\b|!\s*\bv\b/
    disallow = Regexp.union(disallow, /\bcnt\b/) \
      unless Array(k[:state_from_slab_size]).include?(:cnt)
    return false if reduce_body =~ disallow
    # Integer min/max: the compiler's SIMD auto-vectorization for
    # `if (v < acc) acc = v` on packed integer lanes (e.g. Apple clang
    # -> smin.4s / smin.16b on arm64, gcc -> vpminsd on AVX2) is
    # already excellent — a manual 8-way scalar split *prevents* that
    # specific packed-min lowering by fragmenting the conditional
    # across 8 independent lanes.  Observed 2026-07-19: M4 int32 min
    # regressed 2.5x (36 -> 90 us) under 8-way while f64 min improved
    # 3.7x (459 -> 123 us) because the compiler wasn't vectorizing FP
    # min in the first place.  Restrict 8-way min/max to floating-point
    # / complex srcs where the auto-vec doesn't fire; keep integer
    # min/max on the legacy _EX path (compiler already SIMD-perfect).
    # (int-guard removed in a3 experiment: ternary form in MIN8/MAX8 macros
    # aims to satisfy both Apple clang (smin.4s) and gcc (vpminsd) auto-vec.
    # If M4 int32 min regresses again, restore the guard.)
    true
  end

  # Emit the reduce slab macro call.  If 8-way eligible, wraps in
  # #define / #undef of a per-kernel/src-unique EXPR macro that casts
  # to the accumulator C type.  Otherwise emits the legacy _EX macro
  # verbatim.  Callers pass the masked_cnt symbol they want (either
  # "masked_cnt" for mask_policy paths or "__sr_throwaway_mc" for
  # unmasked paths — the 8-way macros always require the argument).
  def self.emit_reduce_slab_call(io, k, src, si, oi, suffix, acc_var,
                                 acc_init, reduce_stmt, masked_cnt_var,
                                 indent: "      ")
    unless reduce_8way_eligible?(k, src, suffix)
      io.puts "#{indent}CA_SLAB_REDUCE_T#{suffix}_EX(#{si[:c]}, st, p, m, #{acc_var}, #{acc_init}, #{reduce_stmt}, #{masked_cnt_var});"
      return
    end
    macro8 = case suffix
             when "_PLUS" then "CA_SLAB_REDUCE_SUM8_EX"
             when "_MIN"  then "CA_SLAB_REDUCE_MIN8_EX"
             when "_MAX"  then "CA_SLAB_REDUCE_MAX8_EX"
             when "_STAR" then "CA_SLAB_REDUCE_STAR8_EX"
             end
    acc_c = resolve_state_type(k[:state][acc_var], oi, si, src)
    expr_macro = "__#{k[:name]}_#{src}_EXPR"
    io.puts "#define #{expr_macro}(__x) ((#{acc_c})(__x))"
    io.puts "#{indent}#{macro8}(#{si[:c]}, #{acc_c}, st, p, m, #{acc_var}, #{acc_init}, #{expr_macro}, #{masked_cnt_var});"
    # Derive secondary state vars from the slab-size + mask count.
    # REDUCE's per-cell `cnt++` was skipped (8-way can't replicate it
    # per-lane), so recover cnt = valid element count here.  Works for
    # both mask paths (SUM8_EX zeros masked_cnt if m == NULL).
    Array(k[:state_from_slab_size]).each do |sv|
      io.puts "#{indent}#{sv} = (int64_t)(st.slab_elements - #{masked_cnt_var});"
    end
    io.puts "#undef #{expr_macro}"
  end

  def self.reduce_macro_suffix(k, src = nil)
    # CA_OBJECT cannot ride the SIMD-licensed macros (= _PLUS / _MIN / _MAX
    # / _STAR), which assume C operators (= acc is a VALUE, so
    # #pragma omp simd reduction(+:acc) etc. is malformed, and init turns
    # falsy raising a TypeError). Use the generic CA_SLAB_REDUCE_T_EX
    # (suffix "") to receive an rb_funcall body.
    return "" if src == :object
    # Per-src SIMD opt-out: a src whose reduce body diverges from its
    # reduction_kind (e.g. accumulate's boolean lane uses `acc ^= v` parity,
    # not the `+` its :plus kind implies) must use the generic CA_SLAB_REDUCE_T_EX
    # so its literal body runs instead of the SIMD-licensed operator macro.
    return "" if k[:no_simd_src]&.include?(src)
    rk = k[:reduction_kind] || :none
    primary =
      case rk
      when :none, :plus, :min, :max, :star
        rk
      when Hash
        primary_key = k[:state].keys.first
        rk[primary_key] || :none
      else
        :none
      end
    case primary
    when :plus then "_PLUS"
    when :min  then "_MIN"
    when :max  then "_MAX"
    when :star then "_STAR"
    else            ""
    end
  end

  def self.output_info(kernel, src)
    out = kernel[:output]
    case out
    when :preserve then DTYPES[src]
    when Hash
      out.each do |family, dt|
        next if family == :default
        if monop_expr_family_match?(family, src)
          # Hash value may itself be :preserve (= "same as source for this
          # family") or a data_type symbol like :f64.
          return (dt == :preserve) ? DTYPES[src] : DTYPES[dt]
        end
      end
      raise "#{kernel[:name]}: output Hash has no match for src #{src} and no :default" \
        unless out.key?(:default)
      dt = out[:default]
      (dt == :preserve) ? DTYPES[src] : DTYPES[dt]
    else
      DTYPES[out]
    end
  end

  # Pick a String body from either a literal String (no dispatch) or a
  # Hash keyed by family alias (e.g. :numeric / :complex / :int / :float
  # / :bool / :object).  Used by reduce DSL's init / reduce / finish
  # fields when the kernel author wants per-data_type-family body dispatch.
  # Mirrors the monop / binop expr: Hash form and the output: Hash form
  # landed previously for output data_type dispatch.
  #
  # An optional :default key provides a fallback when no family matches.
  # If src is given as nil, only literal String input is accepted.
  def self.pick_family_string(body, src, label = "expr")
    return body if body.is_a?(String)
    return nil if body.nil?
    raise "#{label}: expected String or Hash, got #{body.class}" unless body.is_a?(Hash)
    raise "#{label}: src is required when body is a Hash" if src.nil?
    body.each do |family, val|
      next if family == :default
      return val if monop_expr_family_match?(family, src)
    end
    return body[:default] if body.key?(:default)
    raise "#{label}: Hash has no match for src #{src} and no :default"
  end

  # Resolve a single init expression per source data_type.  Special tokens:
  #   T_LIMIT_HI  - max value of T_LOAD (INT*_MAX / INFINITY)
  #   T_LIMIT_LO  - min value of T_LOAD (INT*_MIN / -INFINITY)
  #   T_ACC, T_OUT - replaced with the C type name of the accumulator
  # Accepts Hash form per-family body via pick_family_string.
  def self.resolve_init_expr(expr, oi, si, src = nil)
    expr_str = pick_family_string(expr, src, "init")
    case expr_str
    when "T_LIMIT_HI" then si[:limit_hi]
    when "T_LIMIT_LO" then si[:limit_lo]
    else
      expr_str.gsub("T_ACC", oi[:c]).gsub("T_OUT", oi[:c])
    end
  end

  # Resolve a state-variable C type.
  #   :acc_type  -> T_OUT's C type (= the output data_type)
  #   :load_type -> T_LOAD's C type (= the source data_type)
  #   Hash       -> per-family conditional, e.g.
  #                 { numeric: :f64, complex: :cmplx128 }
  #                 picks a data_type key based on the source data_type family
  #                 and returns DTYPES[data_type][:c].  Used by reduce kernels
  #                 where the accumulator's natural type differs from the
  #                 output type (e.g. variance: output=f64 but acc=cmplx128
  #                 for complex source to hold the partial sum).
  #   anything else -> emitted verbatim (e.g., :int64_t, :double)
  def self.resolve_state_type(type_token, oi, si, src = nil)
    case type_token
    when :acc_type  then oi[:c]
    when :load_type then si[:c]
    when Hash
      raise "state type Hash requires src" if src.nil?
      type_token.each do |family, dt|
        next if family == :default
        return DTYPES[dt][:c] if monop_expr_family_match?(family, src)
      end
      return DTYPES[type_token[:default]][:c] if type_token.key?(:default)
      raise "state type Hash has no match for src #{src} and no :default"
    else                 type_token.to_s
    end
  end

  # Resolve a finish or reduce expression: replace T_OUT / T_ACC with
  # the output data_type's C type.  Accepts Hash form per-family body via
  # pick_family_string.
  def self.resolve_expr(expr, oi, src = nil)
    expr_str = pick_family_string(expr, src, "expr")
    expr_str.gsub("T_OUT", oi[:c]).gsub("T_ACC", oi[:c])
  end

  # Ruby-side scalar wrapper for full reduction (= naxes == ndim).
  def self.ruby_scalar(kernel, oi)
    case kernel[:ruby_scalar]
    when :auto then oi[:ruby]
    else            kernel[:ruby_scalar].to_s
    end
  end

  # ---- emitters ----------------------------------------------------------

  # Given a directory, emit one file per kind; given an IO, emit the whole
  # thing as a single stream.
  def self.emit(outdir_or_io = $stdout)
    if outdir_or_io.is_a?(String)
      emit_split(outdir_or_io)
    else
      emit_stream(outdir_or_io)
    end
  end

  # Single-stream form: every kernel plus Init_carray_kernels() into one IO.
  def self.emit_stream(io)
    io.puts header
    KERNELS.each { |k| emit_kernel_dispatch(io, k) }
    emit_init(io)
  end

  # Split form: one file per (kind, subgroup) pair plus an aggregator init.c.
  # The order of KERNELS is preserved within each file, which is what keeps an
  # alias emitted after its target -- inside a kind and inside a reduce
  # sub-group alike.  Every file gets the same header.
  def self.emit_split(outdir)
    require "fileutils"
    FileUtils.mkdir_p(outdir)
    tags = file_tags
    tags.each do |kind, subgroup|
      suffix = file_suffix(kind, subgroup)
      path = File.join(outdir, "carray_kernels_#{suffix}.c")
      File.open(path, "w") do |io|
        io.puts header
        KERNELS.each do |k|
          k_kind, k_sub = file_tag(k)
          next unless k_kind == kind && k_sub == subgroup
          emit_kernel_dispatch(io, k)
        end
        emit_init_for_tag(io, kind, subgroup)
      end
    end
    File.open(File.join(outdir, "carray_kernels_init.c"), "w") do |io|
      emit_aggregator_init(io, tags)
    end
  end

  # Which file a kernel belongs to.  The three alias kinds live with the kind
  # they alias, so that rb_define_alias is emitted after the target's
  # rb_define_method: both end up in the same Init_<kind>, in order.
  def self.kind_of(k)
    case k[:kind]
    when :monop_alias  then :monop
    when :binop_alias  then :binop
    when :bincmp_alias then :bincmp
    else k[:kind]
    end
  end

  # The per-kernel dispatch shared by emit_stream and emit_split.
  def self.emit_kernel_dispatch(io, k)
    case k[:kind]
    when :reduce then emit_reduce(io, k)
    when :map    then emit_map(io, k)
    when :scan   then emit_scan(io, k)
    when :sort   then emit_sort(io, k)
    when :search then emit_search(io, k)
    when :monop  then emit_monop(io, k)
    when :monop_alias then nil   # no kernel emission, init-time only
    when :binop  then emit_binop(io, k)
    when :binop_alias then nil   # no kernel emission, init-time only
    when :triop  then emit_triop(io, k)
    when :moncmp then emit_moncmp(io, k)
    when :bincmp then emit_bincmp(io, k)
    when :bincmp_alias then nil  # init-time only
    else
      raise "unknown kernel kind #{k[:kind]}"
    end
  end

  KINDS = [:reduce, :map, :scan, :sort, :search,
           :monop, :binop, :triop, :moncmp, :bincmp].freeze

  # Sub-split map for the reduce kind.  As one file, reduce accounted for 71%
  # of the total compile time across all kinds (23.18s of 32.62s, measured on
  # an M2 Max), which capped what splitting the other kinds could buy.  Five
  # sub-groups restore the parallelism.  The DSL is untouched -- this is
  # internal mapping only -- and the group boundaries follow the measurement
  # rather than the guess that monop and binop would dominate.  A kernel added
  # later needs an entry here; emit asserts, so a missing one is loud.
  REDUCE_SUB_GROUPS = {
    # aggregate: arithmetic folds (sum / prod / mean and their strict,
    # safe and weighted variants)
    sum: :aggregate, prod: :aggregate, mean: :aggregate,
    sum_strict: :aggregate, mean_safe: :aggregate,
    wsum: :aggregate, wmean: :aggregate,
    # extreme: order-based (min / max, argmin / argmax, minmax)
    min: :extreme, max: :extreme, minmax: :extreme,
    argmin: :extreme, argmax: :extreme,
    argmin_addr: :extreme, argmax_addr: :extreme,
    # cumulative: counter accumulation (the count family and accumulate)
    count: :cumulative, accumulate: :cumulative,
    count_true: :cumulative, count_false: :cumulative,
    count_equal: :cumulative,
    # variance family: multi-state (Chan / Welford), and the one that
    # changes most often
    variancep: :variance, variance: :variance,
    stddevp: :variance, stddev: :variance,
    # boolean fold (all / any / none)
    all: :boolean, any: :boolean, none: :boolean,
  }.freeze

  # The (kind, subgroup) pair for a kernel.  A nil subgroup means the kind has
  # no sub-split and gets one file.  emit_split's inner loop routes on this.
  def self.file_tag(k)
    kind = kind_of(k)
    if kind == :reduce
      sub = REDUCE_SUB_GROUPS[k[:name].to_sym]
      # The three alias kinds can lack k[:name], but there is no alias kind in
      # the reduce family, so it cannot happen here.  An unmapped reduce
      # kernel is therefore one added later without an entry: raise.
      unless sub
        # only reachable from emit_split; emit_stream never asks for a tag
        raise "REDUCE_SUB_GROUPS: unmapped reduce kernel :#{k[:name]} (add to REDUCE_SUB_GROUPS)"
      end
      [kind, sub]
    else
      [kind, nil]
    end
  end

  # File-name suffix for a (kind, subgroup) pair.
  def self.file_suffix(kind, subgroup)
    subgroup ? "#{kind}_#{subgroup}" : kind.to_s
  end

  # Every (kind, subgroup) pair, for emit_split's outer loop and for the
  # aggregator init.c.  KINDS order is kept, with reduce expanded into its
  # sub-groups.
  def self.file_tags
    KINDS.flat_map do |kind|
      if kind == :reduce
        # take the distinct sub-groups in the order their kernels appear in
        # KERNELS, so the file order is stable
        seen = []
        KERNELS.each do |k|
          next unless k[:kind] == :reduce
          sub = REDUCE_SUB_GROUPS[k[:name].to_sym]
          seen << sub if sub && !seen.include?(sub)
        end
        seen.map { |sub| [kind, sub] }
      else
        [[kind, nil]]
      end
    end
  end

  def self.header
    base = <<~C
      /* ---------------------------------------------------------------------------

         carray_kernels.c -- GENERATED by ext/mkkernel.rb -- DO NOT EDIT

         Kernel definitions live in mkkernel.rb (search for `MkKernel.reduce`).
         Regenerate by running:

           cd ext && ruby mkkernel.rb > carray_kernels.c

         extconf.rb regenerates automatically when mkkernel.rb is touched.

         --------------------------------------------------------------------------- */

      #include "carray.h"
      #include "ca_kernel_iterator.h"
      #include "ca_sort_kernels.h"   /* sort kernels: internal, not via the carray.h umbrella */
      #include "carray_internal.h"   /* ca_lazy_arena_*, ca_is_lazy_view (streaming reduce) */
      #include "ca_obj_face.h"       /* rb_ca_strip_face_value (Face ordering gate) */
      #include <math.h>
      #include <stdint.h>
      #include <stdlib.h>   /* qsort, mergesort (HAVE_MERGESORT) -- for :sort kind */

      /* MEMO_REDUCTION_FASTPATH_ENTITY_ONLY_GUARD Tier 2: CAStack identity is
         probed by operation-table function pointer (obj_type is runtime-
         assigned, so no CA_OBJ_STACK compile-time constant exists). */
      extern ca_operation_function_t ca_stack_func;
    C
    base + HEADER_BLOCKS.join("\n")
  end

  def self.emit_reduce(io, k)
    io.puts
    io.puts "/* ===== #{k[:name]}_ki ============================================ */"
    k[:source].each do |src|
      emit_reduce_native(io, k, src)
    end
    emit_reduce_dispatch(io, k)
  end

  def self.emit_reduce_native(io, k, src)
    # FM.1.0: multi-output reduce delegates to dedicated emitter.  outputs:2
    # path is simpler than the single-output path (= no streaming, view_flat,
    # array_arg, mask_policy support yet — gated by reduce DSL validation).
    return emit_reduce_native_multi(io, k, src) if k[:outputs] == 2
    # CA_FIXLEN: runtime-width byte blob, ordered by memcmp.  A bespoke slab
    # walk (no CA_SLAB_REDUCE_T, no scalar accumulator) — see the fixlen:
    # option in MkKernel.reduce.
    return emit_reduce_native_fixlen(io, k, src) if src == :fixlen
    # Two-pass centred algorithm (variance / stddev family): dedicated
    # emitter that walks each slab twice and skips streaming +
    # loop-interchange fast paths (they assume single-pass accumulation).
    return emit_reduce_native_two_pass_centred(io, k, src) \
      if k[:algorithm] == :two_pass_centred

    si        = DTYPES[src]
    oi        = output_info(k, src)
    ruby_wrap = ruby_scalar(k, oi)
    name      = k[:name]

    # Resolve state declarations + initialisations.  The FIRST state var
    # (state.keys.first) is the one passed to CA_SLAB_REDUCE_T and
    # initialised by the macro itself; remaining state vars are
    # caller-initialised before the macro call.
    acc_var = k[:state].keys.first
    state_decls = k[:state].map do |var, type_token|
      c_type = resolve_state_type(type_token, oi, si, src)
      init_e = resolve_init_expr(k[:init][var], oi, si, src)
      if var == acc_var
        ["#{c_type} #{var};", init_e]    # [decl, acc_init_expr_for_macro]
      else
        ["#{c_type} #{var} = #{init_e};", nil]
      end
    end
    acc_init  = state_decls.find { |_, ai| ai }[1]
    decls     = state_decls.map(&:first)

    reduce_stmt = resolve_expr(k[:reduce], oi, src)
    finish_expr = resolve_expr(k[:finish], oi, src)

    # Native helper signature additions:
    #   :min_count mode adds ", ca_size_t min_count"
    #   value_arg: { target: :T_IN } adds ", T_IN value_arg"
    #   array_arg: { ... } adds ", CArray *cw" BEFORE value_arg / min_count
    # Order: argv, cw, value_arg, min_count.  cw comes first among the
    # extras because it is data_type-uniform (CArray *) and matches the
    # dispatcher's attach-then-call flow; value_arg is per-src typed and
    # sits next-to-tail; min_count is universal sentinel at the tail.
    extra_args = ""
    extra_args += ", CArray *cw" if k[:array_arg]
    extra_args += ", #{si[:c]} value_arg" if k[:value_arg]
    extra_args += ", ca_size_t min_count" if k[:mask_policy] == :min_count

    # P.4.5.3b/c: streaming branch emitted before the SRC_ATTACH path.
    # Conditions for streaming:
    #   - flat reduction (naxes == ca->ndim)
    #   - any ndim >= 1 (P.4.5.3c: N-D via outer-axis chunking)
    #   - lazy view source (CAMonOp/CABinOp/CABinCmp/CAMonCmp)
    #   - no mask source — masked operands fall back to SRC_ATTACH
    #   - no array_arg (weighted reductions) — wsum/wmean fall back
    #   - reduce expression doesn't reference `idx` (= argmin/argmax
    #     would need chunk-base offset, deferred to future work)
    streamable = !k[:array_arg] &&
                 !k[:reduce].to_s.include?("idx")

    view_flat = (k[:semantics] == :view_flat)

    io.puts
    io.puts <<~C
      static VALUE
      #{name}_ki_native_#{src} (VALUE self, CArray *ca, int8_t *slab_axes, int8_t naxes, int keep_axis#{extra_args})
      {
    C

    if streamable
      emit_reduce_streaming(io, k, si, oi, ruby_wrap, acc_var, acc_init,
                            decls, reduce_stmt, finish_expr, extra_args)
    end

    # L.1 / L.3 / L.4 (PROPOSAL_REDUCTION_LOOP_INTERCHANGE):
    # Non-innermost single-axis reduce on row-major entity gets a
    # loop-interchange fast path -- contig load, contig output accumulator,
    # SIMD-vectorised inner loop.  L.0 bench shows 4-7x slow vs torch on
    # this case; the interchange recovers parity by reordering iteration
    # so the inner loop walks the contig (innermost) axis instead of the
    # strided reduce axis.
    #
    # Eligible kernels:
    #   L.1: single :plus state (sum / accumulate / count / count_true /
    #        count_false / count_not_masked)
    #   L.3: :plus + :induction (mean) -- induction var (= cnt) is
    #        precomputed as __li_M outside the SIMD loop
    #   L.4: N :plus + 0 or 1 :induction (variance / stddev) -- multi-
    #        buffer path, one out_buf per :plus state
    # Wider coverage in L.5 (min / max), L.6 (prod).  wsum / wmean
    # (array_arg) deferred.
    # Buf-kinds = reduction kinds whose per-cell update is independent
    # across output positions and thus benefit from a per-cell out_buf
    # in the interchange path: :plus (sum), :star (prod), :min, :max.
    # :induction (= cnt) is precomputed as __li_M, not buffered.  Any
    # other kind (e.g. future :variance fused) is currently a guard.
    rk = k[:reduction_kind]
    buf_kinds = %i[plus star min max]
    if buf_kinds.include?(rk)
      buf_count = 1
      induction_count = 0
      other_count = 0
    elsif rk.is_a?(Hash)
      buf_count       = rk.values.count { |kind| buf_kinds.include?(kind) }
      induction_count = rk.values.count(:induction)
      other_count     = rk.values.length - buf_count - induction_count
    else
      buf_count = induction_count = other_count = 0
    end
    # L.5: limit multi-buffer support to single-kind groups (= all bufs
    # are :plus, or single :min, or single :max, or single :star).
    # Mixed :plus + :min (no real kernel today) would need careful
    # finish ordering; reject for now.
    if rk.is_a?(Hash) && buf_count > 1
      kinds_present = rk.values.select { |kind| buf_kinds.include?(kind) }.uniq
      mixed_buf = kinds_present.length > 1
    else
      mixed_buf = false
    end
    li_eligible = !k[:array_arg] && !k[:value_arg] &&
                  buf_count >= 1 && induction_count <= 1 && other_count == 0 &&
                  !mixed_buf
    if li_eligible
      emit_reduce_loop_interchange(io, k, si, oi, ruby_wrap, src,
                                   acc_var, acc_init, reduce_stmt, finish_expr)
    end

    if view_flat
      # :view_flat semantics: kernel writes view-flat addresses
      # (= row-major position in ca's shape, 0..elements-1).  Only
      # naxes == 1 needs transformation; naxes == ca->ndim is identity
      # (slab walks the whole array in view-flat row-major); other
      # naxes are rejected at entry.
      io.puts "  if ( naxes != 1 && naxes != ca->ndim ) {"
      io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: view_flat semantics requires single-axis or full reduction (got naxes=%d for ndim=%d)", (int)naxes, (int)ca->ndim);]
      io.puts "  }"
    end

    io.puts <<~C
        VALUE   vout  = rb_ca_new_reduced(self, slab_axes, naxes, #{oi[:ca]}, keep_axis);
        CArray *co;
        GetCArray(vout, co);
        #{oi[:c]} *op = (#{oi[:c]} *) co->ptr;
        ca_iter_state st;
        int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES,
                                       slab_axes, naxes, 0);
        if ( rc != CA_ITER_OK ) {
          rb_raise(rb_eRuntimeError,
                   "#{name}_ki: kernel_iterator init failed rc=%d", rc);
        }
        char       *p;
        boolean8_t *m;
        ca_size_t   out_i = 0;
    C

    if view_flat
      # Build view-flat stride table + per-slab outer index counter
      # (= same pattern as sort form's :view_flat path, see
      # emit_sort_native).  For naxes == ca->ndim (= identity case),
      # the transform reduces to no-op so we set transform_active = 0
      # to skip the per-slab arithmetic.
      io.puts "      ca_size_t vstride[CA_RANK_MAX];"
      io.puts "      ca_size_t cur_outer_idx[CA_RANK_MAX];"
      io.puts "      ca_size_t axis_vstride = 1;"
      io.puts "      int       transform_active = (naxes == 1);"
      io.puts "      if ( transform_active ) {"
      io.puts "        ca_size_t s = 1;"
      io.puts "        for ( int8_t mm = (int8_t)(ca->ndim - 1); mm >= 0; mm-- ) {"
      io.puts "          vstride[mm] = s;"
      io.puts "          s *= ca->dim[mm];"
      io.puts "        }"
      io.puts "        axis_vstride = vstride[slab_axes[0]];"
      io.puts "        for ( int8_t mm = 0; mm < st.outer_ndim; mm++ ) cur_outer_idx[mm] = 0;"
      io.puts "      }"
    end

    # array_arg: initialize a parallel kernel_iterator on cw with the
    # same slab_axes so both src and weights are walked in lockstep.
    # Each iter handles its own view materialization (= correct even when
    # self is a transpose view and cw is a fresh entity, or vice versa).
    if k[:array_arg]
      io.puts "      ca_iter_state st_w;"
      io.puts "      int rcw = ca_iter_state_init_l2(&st_w, cw, CA_SLAB_AXES,"
      io.puts "                                      slab_axes, naxes, 0);"
      io.puts "      if ( rcw != CA_ITER_OK ) {"
      io.puts "        ca_iter_state_finish(&st);"
      io.puts %Q[        rb_raise(rb_eRuntimeError, "#{name}_ki: weights kernel_iterator init failed rc=%d", rcw);]
      io.puts "      }"
      io.puts "      char *p_w;"
    end

    # Mask policy: prepare output mask buffer lazily.
    if k[:mask_policy]
      io.puts "      boolean8_t *op_mask = NULL;   /* lazily allocated on first UNDEF */"
    end

    if k[:array_arg]
      io.puts "      while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {"
      io.puts "      if ( ! ca_iter_state_next_slab_axes(&st_w, &p_w, NULL) ) {"
      io.puts "        ca_iter_state_finish(&st);"
      io.puts "        ca_iter_state_finish(&st_w);"
      io.puts %Q[        rb_raise(rb_eRuntimeError, "#{name}_ki: weights iter exhausted early (shape invariant violated)");]
      io.puts "      }"
    else
      io.puts "      while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {"
    end
    if view_flat
      io.puts "      ca_size_t outer_off = 0;"
      io.puts "      if ( transform_active ) {"
      io.puts "        for ( int8_t mm = 0; mm < st.outer_ndim; mm++ ) {"
      io.puts "          outer_off += cur_outer_idx[mm] * vstride[st.outer_axes[mm]];"
      io.puts "        }"
      io.puts "      }"
    end
    decls.each { |d| io.puts "      #{d}" }

    if k[:mask_policy]
      io.puts "      ca_size_t masked_cnt = 0;"
      if k[:array_arg]
        # SL.1.4b: array_arg path now dispatches via suffix.  Only :plus
        # variant is implemented at the array level (CA_SLAB_REDUCE_ARRAY_
        # T_PLUS_EX); other kinds fall back to legacy ARRAY_T_EX.
        suffix = MkKernel.reduce_macro_suffix(k, src)
        suffix = "" unless suffix == "_PLUS"   # only PLUS landed for array_arg
        wc = (k[:array_arg][:data_type] == :promote) ? "double" : si[:c]
        io.puts "      CA_SLAB_REDUCE_ARRAY_T#{suffix}_EX(#{si[:c]}, #{wc}, st, p, m, st_w, p_w, #{acc_var}, #{acc_init}, #{reduce_stmt}, masked_cnt);"
      else
        suffix = MkKernel.reduce_macro_suffix(k, src)
        emit_reduce_slab_call(io, k, src, si, oi, suffix, acc_var, acc_init,
                              reduce_stmt, "masked_cnt", indent: "      ")
      end
      trigger = case k[:mask_policy]
                when :strict     then "masked_cnt > 0"
                when :all_masked then "masked_cnt == st.slab_elements"
                when :min_count
                  # min_count < 0 (sentinel) => legacy default (all_masked).
                  # min_count >= 0 => need at least min_count valid cells
                  # (valid_cnt = slab_elements - masked_cnt).
                  #
                  # ERI.0: identity_on_empty kernels do NOT fire UNDEF for the
                  # default (min_count < 0) zero-contribution case; the trigger
                  # is false there, so the else branch writes finish (= acc =
                  # identity) for empty / all-masked slabs.  The explicit
                  # min_count >= 0 opt-in ("require K valid cells") is unchanged.
                  if k[:identity_on_empty]
                    "(min_count < 0 ? 0 " \
                      ": st.slab_elements - masked_cnt < min_count)"
                  else
                    "(min_count < 0 ? masked_cnt == st.slab_elements " \
                      ": st.slab_elements - masked_cnt < min_count)"
                  end
                end
      finish_emit = view_flat \
        ? "(transform_active ? (outer_off + ((ca_size_t)(#{finish_expr})) * axis_vstride) : ((ca_size_t)(#{finish_expr})))" \
        : "(#{finish_expr})"
      io.puts "      if ( #{trigger} ) {"
      io.puts "        if ( ! op_mask ) {"
      io.puts "          ca_create_mask(co);"
      io.puts "          op_mask = (boolean8_t *) co->mask->ptr;"
      io.puts "        }"
      io.puts "        op_mask[out_i] = 1;"
      io.puts "        op[out_i++] = (#{oi[:c]}) 0;   /* sentinel; mask bit is what counts */"
      io.puts "      } else {"
      io.puts "        op[out_i++] = (#{oi[:c]}) #{finish_emit};"
      io.puts "      }"
    else
      if k[:array_arg]
        wc = (k[:array_arg][:data_type] == :promote) ? "double" : si[:c]
        io.puts "      CA_SLAB_REDUCE_ARRAY_T(#{si[:c]}, #{wc}, st, p, m, st_w, p_w, #{acc_var}, #{acc_init}, #{reduce_stmt});"
      else
        suffix = MkKernel.reduce_macro_suffix(k, src)
        # Non-mask_policy path: emit a throwaway masked_cnt for the 8-way
        # macros (which always take one).  Falls through to the legacy
        # non-EX macro when the 8-way path is not eligible (:object src).
        if MkKernel.reduce_8way_eligible?(k, src, suffix)
          io.puts "      ca_size_t __sr_throwaway_mc = 0;"
          emit_reduce_slab_call(io, k, src, si, oi, suffix, acc_var, acc_init,
                                reduce_stmt, "__sr_throwaway_mc",
                                indent: "      ")
          io.puts "      (void) __sr_throwaway_mc;"
        else
          io.puts "      CA_SLAB_REDUCE_T#{suffix}(#{si[:c]}, st, p, m, #{acc_var}, #{acc_init}, #{reduce_stmt});"
        end
      end
      finish_emit = view_flat \
        ? "(transform_active ? (outer_off + ((ca_size_t)(#{finish_expr})) * axis_vstride) : ((ca_size_t)(#{finish_expr})))" \
        : "(#{finish_expr})"
      io.puts "      op[out_i++] = (#{oi[:c]}) #{finish_emit};"
    end
    if view_flat
      io.puts "      if ( transform_active ) {"
      io.puts "        for ( int8_t mm = (int8_t)(st.outer_ndim - 1); mm >= 0; mm-- ) {"
      io.puts "          if ( ++cur_outer_idx[mm] < st.outer_dims[mm] ) break;"
      io.puts "          cur_outer_idx[mm] = 0;"
      io.puts "        }"
      io.puts "      }"
    end

    io.puts "      }"
    io.puts "      ca_iter_state_finish(&st);"
    io.puts "      ca_iter_state_finish(&st_w);" if k[:array_arg]

    if k[:mask_policy]
      # Full reduction: if the sole output cell is masked, return CA_UNDEF.
      # keep_axis: skip the scalar shortcut and return vout (= [1,...,1]
      # entity, with mask bit set on co when masked).
      io.puts "      if ( naxes == ca->ndim && !keep_axis ) {"
      io.puts "        if ( op_mask && op_mask[0] ) return CA_UNDEF;"
      io.puts "        return #{ruby_wrap}(op[0]);"
      io.puts "      }"
    else
      io.puts "      if ( naxes == ca->ndim && !keep_axis ) return #{ruby_wrap}(op[0]);"
    end
    io.puts "      return vout;"
    io.puts "    }"
  end

  # CA_FIXLEN reduce helper.  A fixlen cell is a runtime-width byte blob
  # (K = ca->bytes, uniform across the array), which has no scalar C type
  # and so cannot ride CA_SLAB_REDUCE_T (that macro loads `v` as a typed T
  # and uses sizeof(T) for the contig check).  This is a bespoke slab walk
  # with an index-only accumulator: `best` points at the winning blob so
  # far, `best_i` is its flat slab-row-major position.  Cells are ordered
  # by memcmp over K bytes -- the same lexicographic total order the sort
  # family gives CA_FIXLEN (bit-identical to sort_index).  Strict compare
  # (memcmp < 0 / > 0) makes ties keep the first (lowest-index) cell, which
  # matches the numeric argmin / argmax first-wins convention.
  #
  # The walk mirrors CA_SLAB_REDUCE_T_EX's index semantics: `idx` runs
  # 0..slab_elements-1 in row-major order (innermost slab axis fastest) and
  # increments on every cell regardless of mask, so best_i is comparable to
  # the numeric argmin's best_i.  mask_policy is always :min_count here.
  def self.emit_reduce_native_fixlen(io, k, src)
    name      = k[:name]
    want_max  = %i[max argmax].include?(k[:fixlen])
    index_out = %i[argmin argmax].include?(k[:fixlen])
    cmp       = want_max ? ">" : "<"

    io.puts
    io.puts "static VALUE"
    io.puts "#{name}_ki_native_fixlen (VALUE self, CArray *ca, int8_t *slab_axes, int8_t naxes, int keep_axis, ca_size_t min_count)"
    io.puts "{"
    io.puts "  ca_size_t K = ca->bytes;   /* uniform fixlen byte width */"
    if index_out
      io.puts "  VALUE   vout = rb_ca_new_reduced(self, slab_axes, naxes, CA_INT64, keep_axis);"
    else
      io.puts "  VALUE   vout = rb_ca_new_reduced_bytes(self, slab_axes, naxes, CA_FIXLEN, K, keep_axis);"
    end
    io.puts "  CArray *co;"
    io.puts "  GetCArray(vout, co);"
    io.puts "  char       *op = (char *) co->ptr;"
    io.puts "  ca_iter_state st;"
    io.puts "  int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, slab_axes, naxes, 0);"
    io.puts "  if ( rc != CA_ITER_OK ) {"
    io.puts %Q[    rb_raise(rb_eRuntimeError, "#{name}_ki: kernel_iterator init failed rc=%d", rc);]
    io.puts "  }"
    io.puts "  char       *p;"
    io.puts "  boolean8_t *m;"
    io.puts "  ca_size_t   out_i   = 0;"
    io.puts "  boolean8_t *op_mask = NULL;   /* lazily allocated on first UNDEF */"
    io.puts "  while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {"
    io.puts "    const char *best   = NULL;"
    io.puts "    ca_size_t   best_i = 0;"
    io.puts "    (void) best_i;" unless index_out   # value output ignores the index
    io.puts "    ca_size_t   masked_cnt = 0;"
    io.puts "    int8_t      sndim   = st.slab_ndim;"
    io.puts "    ca_size_t   sidx[CA_RANK_MAX] = { 0 };"
    io.puts "    ca_size_t   total   = st.slab_elements;"
    io.puts "    for ( ca_size_t idx = 0; idx < total; idx++ ) {"
    io.puts "      ca_size_t doff = 0, moff = 0;"
    io.puts "      for ( int8_t sk = 0; sk < sndim; sk++ ) {"
    io.puts "        doff += sidx[sk] * st.slab_strides[sk];"
    io.puts "        moff += sidx[sk] * st.slab_mask_strides[sk];"
    io.puts "      }"
    io.puts "      if ( m != NULL && m[moff] ) {"
    io.puts "        masked_cnt++;"
    io.puts "      }"
    io.puts "      else {"
    io.puts "        const char *q = (const char *) p + doff;"
    io.puts "        if ( best == NULL ) {"
    io.puts "          best = q; best_i = idx;"
    io.puts "        }"
    io.puts "        else if ( memcmp(q, best, (size_t) K) #{cmp} 0 ) {"
    io.puts "          best = q; best_i = idx;"
    io.puts "        }"
    io.puts "      }"
    io.puts "      /* row-major odometer (innermost slab axis fastest) so idx"
    io.puts "         matches CA_SLAB_REDUCE_T's flat slab index. */"
    io.puts "      for ( int8_t sk = (int8_t)(sndim - 1); sk >= 0; sk-- ) {"
    io.puts "        if ( ++sidx[sk] < st.slab_dims[sk] ) break;"
    io.puts "        sidx[sk] = 0;"
    io.puts "      }"
    io.puts "    }"
    io.puts "    if ( min_count < 0 ? masked_cnt == st.slab_elements"
    io.puts "                       : st.slab_elements - masked_cnt < min_count ) {"
    io.puts "      if ( ! op_mask ) {"
    io.puts "        ca_create_mask(co);"
    io.puts "        op_mask = (boolean8_t *) co->mask->ptr;"
    io.puts "      }"
    io.puts "      op_mask[out_i] = 1;"
    if index_out
      io.puts "      ((int64_t *) op)[out_i] = 0;   /* sentinel; mask bit is what counts */"
    else
      io.puts "      memset(op + out_i * K, 0, (size_t) K);   /* sentinel; mask bit is what counts */"
    end
    io.puts "      out_i++;"
    io.puts "    }"
    io.puts "    else {"
    if index_out
      io.puts "      ((int64_t *) op)[out_i] = (int64_t) best_i;"
    else
      io.puts "      memcpy(op + out_i * K, best, (size_t) K);"
    end
    io.puts "      out_i++;"
    io.puts "    }"
    io.puts "  }"
    io.puts "  ca_iter_state_finish(&st);"
    io.puts "  if ( naxes == ca->ndim && !keep_axis ) {"
    io.puts "    if ( op_mask && op_mask[0] ) return CA_UNDEF;"
    if index_out
      io.puts "    return LL2NUM(((int64_t *) op)[0]);"
    else
      io.puts "    return rb_str_new(op, (long) K);"
    end
    io.puts "  }"
    io.puts "  return vout;"
    io.puts "}"
  end

  # L.1 (PROPOSAL_REDUCTION_LOOP_INTERCHANGE): emit the loop-interchange
  # fast-path body inside name_ki_native_<src>.  Runtime-eligible when the
  # source is a row-major entity (no mask, single reduce axis, axis is not
  # the innermost).  Output buffer holds T_OUT accumulators sized to the
  # product of inner contig axes (= dims after the reduce axis).  Outer
  # loop walks the reduce axis, inner SIMD loop accumulates contig into
  # the buffer -- the key inversion vs the default per-output-cell walk.
  #
  # Threshold gate (INNER >= 64 && INNER*M >= 1024) skips the path when
  # the size cannot amortise the alloc + 2-pass init/finish overhead.
  # The curve is L.7's job; initial values are seed estimates.
  # Two-pass centred variance / stddev emitter.
  #
  # Layout per slab:
  #   Pass 1: sum = Σ x_i   via CA_SLAB_REDUCE_T_PLUS_EX (SIMD :plus)
  #           masked_cnt is populated as a side effect.
  #   mask trigger:
  #     min_count < 0  (default) -> UNDEF iff all-masked, OR (for
  #                                 :n_minus_1 divisor) if n_valid < 2.
  #     min_count >= 0           -> UNDEF iff n_valid < min_count.
  #   Pass 2: M2 = Σ (x_i - mean)²  via the same macro with a centred
  #           REDUCE stmt.
  #   Finish: variance = M2 / DIVISOR (n or n-1); stddev variant applies
  #           sqrt(fmax(variance, 0.0)) — the clamp catches ε-level
  #           negatives introduced by SIMD lane reassociation on constant
  #           slabs (mathematically M2 >= 0).
  #
  # Per-src layout (numeric / complex / bool / object):
  #   numeric+bool: sum, mean: double; M2: double.
  #   complex:      sum, mean: double _Complex; M2: double (|d|²).
  #   object:       sum, mean: VALUE; M2: VALUE (Ruby numeric tower).
  #
  # This path bypasses the streaming (lazy-source) and loop-interchange
  # (per-cell out_buf) fast paths — both assume single-pass accumulation
  # and are not straightforward to adapt to two-pass.  PoC (M2 Max, 1M
  # f64) shows 1.75x slowdown vs the SIMD-vectorised one-pass form; the
  # accuracy gain (rel_err 8447x -> 4e-4 at mean=1e9) is the point.
  def self.emit_reduce_native_two_pass_centred(io, k, src)
    name = k[:name]
    si   = DTYPES[src]
    oi   = output_info(k, src)
    ruby_wrap = ruby_scalar(k, oi)

    # Per-src plumbing.
    #   sum_c    : C type of sum / mean
    #   sum_init : init literal for sum
    #   p1_body  : Pass 1 reduce statement (populates `sum`)
    #   mean_c   : declaration+assignment for `mean`
    #   p2_body  : Pass 2 reduce statement (populates `M2`, using `mean`)
    #   var_expr : variance expression (before optional sqrt_clamp)
    #   out_zero : zero value in output C type (for degenerate cnt cases)
    #   out_cast : cast-to-output syntax
    # p1_expr / p2_expr: function-like macro BODIES (parameter __x) for the
    # 8-way-split contig path (CA_SLAB_REDUCE_SUM8_EX).  nil for :object,
    # which keeps the scalar rb_funcall path (CA_SLAB_REDUCE_T_EX).
    p1_expr = p2_expr = nil
    if src == :object
      sum_c    = "VALUE"
      sum_init = "INT2FIX(0)"
      p1_body  = 'sum = rb_funcall(sum, rb_intern("+"), 1, v)'
      # mean = sum / n_valid  (Ruby /)
      mean_setup = 'VALUE mean = rb_funcall(sum, rb_intern("/"), 1, LONG2NUM(n_valid));'
      # d = v - mean; M2 += d * d;  all VALUE arithmetic.
      p2_body = <<~C.chomp
        VALUE __d = rb_funcall(v, rb_intern("-"), 1, mean);
        M2 = rb_funcall(M2, rb_intern("+"), 1, rb_funcall(__d, rb_intern("*"), 1, __d))
      C
      m2_c    = "VALUE"
      m2_init = "INT2FIX(0)"
      # variance = M2 / divisor
      # divisor is int (n_valid or n_valid - 1)
      var_expr = ->(divisor_expr) {
        %Q[rb_funcall(M2, rb_intern("/"), 1, LONG2NUM(#{divisor_expr}))]
      }
      out_zero = "INT2FIX(0)"
    elsif src == :bool
      sum_c    = "double"
      sum_init = "0.0"
      p1_body  = "sum += (double) v"
      p1_expr  = "((double)(__x))"
      mean_setup = "double mean = sum / (double) n_valid;"
      p2_body = "double __d = (double) v - mean; M2 += __d * __d"
      p2_expr = "(((double)(__x) - mean) * ((double)(__x) - mean))"
      m2_c    = "double"
      m2_init = "0.0"
      var_expr = ->(divisor_expr) { "M2 / (double)(#{divisor_expr})" }
      out_zero = "0.0"
    elsif CMPLX_DTYPES.include?(src)
      sum_c    = si[:c]   # cmplx128 / cmplx64
      sum_init = "0"
      p1_body  = "sum += v"
      p1_expr  = "(__x)"
      mean_setup = "#{si[:c]} mean = sum / (#{si[:c]})(double) n_valid;"
      p2_body = <<~C.chomp
        #{si[:c]} __d = v - mean;
        M2 += creal(__d) * creal(__d) + cimag(__d) * cimag(__d)
      C
      p2_expr = "(creal((__x) - mean) * creal((__x) - mean) + " \
                "cimag((__x) - mean) * cimag((__x) - mean))"
      m2_c    = "double"
      m2_init = "0.0"
      var_expr = ->(divisor_expr) { "M2 / (double)(#{divisor_expr})" }
      out_zero = "0.0"
    else
      # numeric integer / float
      sum_c    = "double"
      sum_init = "0.0"
      p1_body  = "sum += (double) v"
      p1_expr  = "((double)(__x))"
      mean_setup = "double mean = sum / (double) n_valid;"
      p2_body = "double __d = (double) v - mean; M2 += __d * __d"
      p2_expr = "(((double)(__x) - mean) * ((double)(__x) - mean))"
      m2_c    = "double"
      m2_init = "0.0"
      var_expr = ->(divisor_expr) { "M2 / (double)(#{divisor_expr})" }
      out_zero = "0.0"
    end

    divisor_expr = (k[:divisor] == :n_minus_1) ? "n_valid - 1" : "n_valid"
    required_min = (k[:divisor] == :n_minus_1) ? 2 : 1

    # Wrap variance expression in sqrt_clamp for stddev.
    inner_var = var_expr.call(divisor_expr)
    finish_expr = if k[:output_transform] == :sqrt_clamp
                    if src == :object
                      # Object stddev outputs f64 (BigMath.sqrt is user's job).
                      "sqrt(fmax(NUM2DBL(#{inner_var}), 0.0))"
                    else
                      "sqrt(fmax(#{inner_var}, 0.0))"
                    end
                  else
                    inner_var
                  end

    # Output C type (:f64 for numeric/complex/bool variance/stddev,
    # :object for object variance, :f64 for object stddev).
    out_c = oi[:c]

    # Zero in the OUTPUT C type -- distinct from sum_init (which lives in
    # the intermediate accumulator type).  Used for degenerate returns
    # (all-masked masked write, n_valid < required_min).  For object
    # output this is INT2FIX(0); for numeric/f64 it's 0.0; for complex 0.
    # A common trap: object stddev has output f64 with source object, so
    # sum_init is INT2FIX(0) but out_zero must be 0.0 -- (double)INT2FIX(0)
    # equals 1.0, not 0.
    out_zero_typed = if out_c == "VALUE"
                       "INT2FIX(0)"
                     elsif out_c == "double" || out_c == "float"
                       "0.0"
                     else
                       "0"
                     end

    # min_count sentinel arg is always present (all four kernels use it).
    extra_args = ", ca_size_t min_count"

    # The default (min_count < 0) trigger fires when all cells are
    # masked; for sample-variance/stddev we also need n_valid >= 2 to
    # avoid division by zero, but the legacy behaviour returned 0
    # (not UNDEF) for n_valid < required_min.  Preserve that: the
    # default trigger only checks the all-masked case; the sub-required
    # case falls through to the "return zero" branch below.
    default_trigger = "masked_cnt == st.slab_elements"

    # Reduce-call plumbing.  :object keeps the scalar rb_funcall loop
    # (CA_SLAB_REDUCE_T_EX).  Every other src uses the 8-way accumulator
    # split (CA_SLAB_REDUCE_SUM8_EX) driven by function-like EXPR macros,
    # defined at file scope with a per-kernel/src-unique name so the P2
    # macro's `mean` reference resolves inside the emitted function and no
    # preprocessor directive lands inside the heredoc body.  This is the
    # variance/stddev AVX2-regression fix (2026-07-18): GCC won't split the
    # pragma-simd FMA reduction into multiple accumulators, so we write the
    # split in source (see the CA_SLAB_REDUCE_SUM8_EX header comment).
    if src == :object
      expr_macro_defs   = ""
      expr_macro_undefs = ""
      p1_reduce_call = "CA_SLAB_REDUCE_T_EX(#{si[:c]}, st, p, m, sum, #{sum_init}, #{p1_body}, masked_cnt);"
      p2_reduce_call = "CA_SLAB_REDUCE_T_EX(#{si[:c]}, st, p, m, M2, #{m2_init}, #{p2_body}, __unused_mc);"
    else
      p1_macro = "__#{name}_#{src}_P1EXPR"
      p2_macro = "__#{name}_#{src}_P2EXPR"
      expr_macro_defs   = "#define #{p1_macro}(__x) #{p1_expr}\n" \
                          "#define #{p2_macro}(__x) #{p2_expr}\n"
      expr_macro_undefs = "#undef #{p1_macro}\n#undef #{p2_macro}\n"
      p1_reduce_call = "CA_SLAB_REDUCE_SUM8_EX(#{si[:c]}, #{sum_c}, st, p, m, sum, #{sum_init}, #{p1_macro}, masked_cnt);"
      p2_reduce_call = "CA_SLAB_REDUCE_SUM8_EX(#{si[:c]}, #{m2_c}, st, p, m, M2, #{m2_init}, #{p2_macro}, __unused_mc);"
    end

    io.puts
    io.print expr_macro_defs
    io.puts <<~C
      static VALUE
      #{name}_ki_native_#{src} (VALUE self, CArray *ca, int8_t *slab_axes, int8_t naxes, int keep_axis#{extra_args})
      {
        VALUE   vout  = rb_ca_new_reduced(self, slab_axes, naxes, #{oi[:ca]}, keep_axis);
        CArray *co;
        GetCArray(vout, co);
        #{out_c} *op = (#{out_c} *) co->ptr;
        ca_iter_state st;
        int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES,
                                       slab_axes, naxes, 0);
        if ( rc != CA_ITER_OK ) {
          rb_raise(rb_eRuntimeError,
                   "#{name}_ki: kernel_iterator init failed rc=%d", rc);
        }
        char       *p;
        boolean8_t *m;
        ca_size_t   out_i = 0;
        boolean8_t *op_mask = NULL;   /* lazily allocated on first UNDEF */
        while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
          /* Pass 1: sum = Σx (+ masked_cnt) */
          #{sum_c} sum = #{sum_init};
          ca_size_t masked_cnt = 0;
          #{p1_reduce_call}
          ca_size_t n_valid = st.slab_elements - masked_cnt;
          int __trigger = (min_count < 0 ? #{default_trigger} : n_valid < min_count);
          if ( __trigger ) {
            if ( ! op_mask ) {
              ca_create_mask(co);
              op_mask = (boolean8_t *) co->mask->ptr;
            }
            op_mask[out_i] = 1;
            op[out_i++] = (#{out_c}) #{out_zero_typed};
          } else if ( n_valid < #{required_min} ) {
            /* Legacy degenerate case (e.g. sample variance with 1 unmasked
               cell): return zero rather than UNDEF, matching pre-migration
               behaviour of `cnt > 1 ? formula : 0`. */
            op[out_i++] = (#{out_c}) #{out_zero_typed};
          } else {
            #{mean_setup}
            /* Pass 2: M2 = Σ (x - mean)² */
            #{m2_c} M2 = #{m2_init};
            ca_size_t __unused_mc = 0;
            #{p2_reduce_call}
            op[out_i++] = (#{out_c})(#{finish_expr});
          }
        }
        ca_iter_state_finish(&st);
        /* Full-reduction scalar shortcut: naxes == ca->ndim and no
           keep_axis means the output is a 1-element CArray; unwrap it to
           the ruby scalar (matches the standard reduce emit path lines
           1811-1817).  Full reduction with all-masked returns CA_UNDEF. */
        if ( naxes == ca->ndim && !keep_axis ) {
          if ( op_mask && op_mask[0] ) return CA_UNDEF;
          return #{ruby_wrap}(op[0]);
        }
        return vout;
      }
    C
    io.print expr_macro_undefs
  end

  def self.emit_reduce_loop_interchange(io, k, si, oi, ruby_wrap, src,
                                        acc_var, acc_init, reduce_stmt, finish_expr)
    # Classify state vars by reduction_kind:
    #   :plus / :star / :min / :max -> per-cell out_buf (one buffer per var)
    #   :induction                  -> precomputed scalar (__li_M), drop ++
    buf_kinds = %i[plus star min max]
    rk = k[:reduction_kind]
    if buf_kinds.include?(rk)
      buf_vars = [k[:state].keys.first]
      induction_var = nil
    else
      buf_vars = k[:state].keys.select { |v| buf_kinds.include?(rk[v]) }
      ind_pair = rk.find { |_, kind| kind == :induction }
      induction_var = ind_pair && ind_pair[0]
    end

    # For each buf var, resolve C type + init expression.
    plus_info = buf_vars.map do |v|
      c_type = resolve_state_type(k[:state][v], oi, si, src)
      init_e = resolve_init_expr(k[:init][v], oi, si, src)
      buf_name = "__li_buf_#{v}"
      { var: v, c_type: c_type, init: init_e, buf: buf_name }
    end

    # Substitute each plus var -> buf_<var>[__j] in reduce + finish.
    reduce_li = reduce_stmt.dup
    finish_li = finish_expr.dup
    plus_info.each do |pi|
      pat = /\b#{Regexp.escape(pi[:var].to_s)}\b/
      reduce_li = reduce_li.gsub(pat, "#{pi[:buf]}[__j]")
      finish_li = finish_li.gsub(pat, "#{pi[:buf]}[__j]")
    end

    if induction_var
      # Drop the induction increment from the inner-loop body -- cnt is
      # precomputed as __li_M outside.  Substitute cnt++ -> 0 to keep
      # comma-expression operands syntactically valid.
      ind_pat = Regexp.escape(induction_var.to_s)
      reduce_li = reduce_li.gsub(/\b#{ind_pat}\+\+/, "0")
                           .gsub(/\+\+\b#{ind_pat}\b/, "0")
      # In finish: cnt -> __li_M (cast to int64_t to match state type).
      finish_li = finish_li.gsub(/\b#{ind_pat}\b/, "((int64_t)__li_M)")
    end

    # L.7: tile INNER into L1d-friendly chunks (TILE = 512 f64 cells =
    # 4 KiB).  Output buffer fits in L1d regardless of INNER size; rows
    # read are streaming (= each iteration's row is a fresh contig read).
    # Buffer always stack-allocated (no heap path), one per :plus state.
    #
    # Why 512: Apple M2 L1d = 64 KiB but shared with code + row reads.
    # 512 cells × 8 B = 4 KiB per buf × (variance has 2 = 8 KiB) +
    # row read 4 KiB streaming = comfortable margin within L1d.
    buf_decls = plus_info.map do |pi|
      "          #{pi[:c_type]}  #{pi[:buf]}[512];\n"
    end.join
    init_loops = plus_info.map do |pi|
      "              for ( ca_size_t __j = 0; __j < __li_tile_len; __j++ ) {\n" \
      "                #{pi[:buf]}[__j] = (#{pi[:c_type]}) (#{pi[:init]});\n" \
      "              }\n"
    end.join

    # The L.7 core (OUTER / INNER-tile / M nested loops): parametrized by
    # the source base pointer, output base pointer, and outer count so it
    # can be emitted once for the Tier 1 single-buffer path (entity / alias
    # view) and once per parent for the Tier 2 CAStack path.  __li_M,
    # __li_INNER, __li_TILE, __li_plane_elems and the buffers are shared
    # C scope, so only the three operands vary.
    core = lambda do |pr, opv, outer|
      <<~C.rstrip
                for ( ca_size_t __li_o = 0; __li_o < #{outer}; __li_o++ ) {
                  const #{si[:c]} *__li_plane = #{pr} + __li_o * __li_plane_elems;
                  for ( ca_size_t __li_tile = 0; __li_tile < __li_INNER; __li_tile += __li_TILE ) {
                    ca_size_t __li_tile_len = (__li_INNER - __li_tile < __li_TILE)
                                              ? (__li_INNER - __li_tile) : __li_TILE;
        #{init_loops.rstrip}
                    for ( ca_size_t __li_i = 0; __li_i < __li_M; __li_i++ ) {
                      const #{si[:c]} *__li_row = __li_plane + __li_i * __li_INNER + __li_tile;
                      _Pragma("omp simd")
                      for ( ca_size_t __j = 0; __j < __li_tile_len; __j++ ) {
                        #{si[:c]} v = __li_row[__j];
                        #{reduce_li};
                        (void) v;
                      }
                    }
                    for ( ca_size_t __j = 0; __j < __li_tile_len; __j++ ) {
                      #{opv}[__li_o * __li_INNER + __li_tile + __j] = (#{oi[:c]}) (#{finish_li});
                    }
                  }
                }
      C
    end

    io.puts <<~C
        /* L.1 / L.7: loop-interchange fast path with inner-tiling
           (PROPOSAL_REDUCTION_LOOP_INTERCHANGE).
           MEMO_REDUCTION_FASTPATH_ENTITY_ONLY_GUARD Tier 1: extend from
           entity-only to any contig row-major buffer.  ca_attach_is_alias
           is true for CA_OBJ_ARRAY and for CAStride-family views whose
           composed strides are row-major contiguous (CARefer reshape,
           contig CABlock, CAFarray, alias CAStride, ...); ca_attach then
           exposes ca->ptr as that buffer at O(1) cost (no materialise). */
        if ( naxes == 1
             && slab_axes[0] != (int8_t)(ca->ndim - 1)
             && ca->mask == NULL
             && ca_attach_is_alias(ca) ) {
          int8_t    __li_ax    = slab_axes[0];
          ca_size_t __li_M     = ca->dim[__li_ax];
          ca_size_t __li_INNER = 1;
          for ( int8_t __k = (int8_t)(__li_ax + 1); __k < ca->ndim; __k++ ) __li_INNER *= ca->dim[__k];
          ca_size_t __li_OUTER = 1;
          for ( int8_t __k = 0; __k < __li_ax; __k++ ) __li_OUTER *= ca->dim[__k];

          /* Threshold gate: skip when too small to amortise alloc + 2-pass overhead. */
          if ( __li_INNER >= 64 && __li_M * __li_INNER >= 1024 ) {
            VALUE   vout = rb_ca_new_reduced(self, slab_axes, naxes, #{oi[:ca]}, keep_axis);
            CArray *co;
            GetCArray(vout, co);
            #{oi[:c]} *op = (#{oi[:c]} *) co->ptr;
            ca_attach(ca);                       /* O(1): entity no-op or alias attach */
            const #{si[:c]} *p_root = (const #{si[:c]} *) ca->ptr;

            /* Per-buffer stack accumulators (one per :plus state, sized
               to L7 TILE = 512 cells regardless of INNER). */
    #{buf_decls.rstrip}

            ca_size_t __li_plane_elems = __li_M * __li_INNER;
            const ca_size_t __li_TILE = 512;
    #{core.call("p_root", "op", "__li_OUTER")}
            ca_detach(ca);

            if ( naxes == ca->ndim && !keep_axis ) return #{ruby_wrap}(op[0]);   /* unreachable: ax != innermost && naxes == 1 < ndim */
            return vout;
          }
        }

        /* MEMO_REDUCTION_FASTPATH_ENTITY_ONLY_GUARD Tier 2: CAStack source.
           view.reduce(axis: ax>=1) is exactly K independent per-parent
           reduces over (ax - 1) of each contiguous parent; output row k
           = parent k's reduced plane.  Run the L.7 core per parent (each
           attach is O(1) for entity parents), no whole-view materialise.

           K.3 (PROPOSAL_CASTACK_K_AXIS, 2026-06-20): gated to k_axis == 0
           because the per-parent output layout in dst assumes K is the
           outermost output axis (= each parent contributes a contiguous
           block of parent_OUTER * parent_INNER cells).  For k_axis != 0
           the parents' outputs are interleaved in dst -- generalising
           the output stride is doable but out of K.3 scope.  The
           dispatch falls through to ca_iter_state_init_l2 SLAB_AXES
           which engages the K.3-generalised tile cache. */
        if ( naxes == 1
             && slab_axes[0] >= 1
             && slab_axes[0] != (int8_t)(ca->ndim - 1)
             && ca->mask == NULL
             && ca_func[ca->obj_type].attach == ca_stack_func.attach
             && ((CAStack *) ca)->k_axis == 0 ) {
          CAStack  *__li_st    = (CAStack *) ca;
          int8_t    __li_ax    = slab_axes[0];
          ca_size_t __li_M     = ca->dim[__li_ax];
          ca_size_t __li_INNER = 1;
          for ( int8_t __k = (int8_t)(__li_ax + 1); __k < ca->ndim; __k++ ) __li_INNER *= ca->dim[__k];
          ca_size_t __li_OUTER = 1;   /* parent outer = dims 1..ax-1 (excludes K = axis 0) */
          for ( int8_t __k = 1; __k < __li_ax; __k++ ) __li_OUTER *= ca->dim[__k];

          /* Bail to the generic path if any parent carries a mask (the
             core reads parent->ptr without mask awareness). */
          int __li_ok = 1;
          for ( int32_t __kk = 0; __kk < __li_st->n_parents; __kk++ ) {
            if ( __li_st->parents[__kk]->mask != NULL ) { __li_ok = 0; break; }
          }

          if ( __li_ok && __li_INNER >= 64 && __li_M * __li_INNER >= 1024 ) {
            VALUE   vout = rb_ca_new_reduced(self, slab_axes, naxes, #{oi[:ca]}, keep_axis);
            CArray *co;
            GetCArray(vout, co);
            #{oi[:c]} *op = (#{oi[:c]} *) co->ptr;

    #{buf_decls.rstrip}

            ca_size_t __li_plane_elems = __li_M * __li_INNER;
            ca_size_t __li_parent_out  = __li_OUTER * __li_INNER;
            const ca_size_t __li_TILE = 512;
            for ( int32_t __kk = 0; __kk < __li_st->n_parents; __kk++ ) {
              ca_attach(__li_st->parents[__kk]);
              const #{si[:c]} *p_root = (const #{si[:c]} *) __li_st->parents[__kk]->ptr;
              #{oi[:c]} *__li_op_k = op + (ca_size_t) __kk * __li_parent_out;
    #{core.call("p_root", "__li_op_k", "__li_OUTER")}
              ca_detach(__li_st->parents[__kk]);
            }

            return vout;
          }
        }

        /* M.1.0 + M.2.0a (PROPOSAL_MKKERNEL_TIER2_K_AXIS_GEN, 2026-06-20):
           Tier 2 fast path for CAStack with k_axis > 0, covering two
           structurally-equivalent cases:

             M.1  ax > k_axis              parent INNER all post-K in output
             M.2a ax < k_axis = ax + 1     parent INNER all post-K in output
                                           (K directly after reduce axis)

           In both cases parent INNER axes remain contig at the output
           tail (j-stride 1 preserved -> SIMD tile write maintained),
           parent PRE axes form a scattered OUTER (per-OUTER output base
           computed via output stride table + carry-increment multi-index).
           The k_axis == 0 branch above stays as the tightest fast path
           (PRE contig in output, no scatter).

           Out of this branch: M.2b (ax < k_axis - 1) where parent INNER
           is split by K in output (= INNER tile write becomes scatter,
           SIMD-impacting).  Falls through to the generic init_l2
           SLAB_AXES path. */
        if ( naxes == 1
             && slab_axes[0] >= 1
             && slab_axes[0] != (int8_t)(ca->ndim - 1)
             && ca->mask == NULL
             && ca_func[ca->obj_type].attach == ca_stack_func.attach
             && ((CAStack *) ca)->k_axis > 0
             && ( slab_axes[0] > ((CAStack *) ca)->k_axis
                  || slab_axes[0] + 1 == ((CAStack *) ca)->k_axis ) ) {
          CAStack  *__li_st    = (CAStack *) ca;
          int8_t    __li_ax    = slab_axes[0];
          int8_t    __li_kax   = (int8_t) __li_st->k_axis;
          CArray   *__li_p0    = __li_st->parents[0];        /* shape representative */
          int8_t    __li_pa    = (__li_ax < __li_kax) ? __li_ax : (int8_t)(__li_ax - 1);
          int8_t    __li_kax_out = (__li_ax < __li_kax) ? (int8_t)(__li_kax - 1) : __li_kax;
          ca_size_t __li_M     = __li_p0->dim[__li_pa];      /* = ca->dim[__li_ax] for ax != kax */
          ca_size_t __li_INNER = 1;
          for ( int8_t __k = (int8_t)(__li_pa + 1); __k < __li_p0->ndim; __k++ ) __li_INNER *= __li_p0->dim[__k];
          ca_size_t __li_OUTER = 1;
          for ( int8_t __k = 0; __k < __li_pa; __k++ ) __li_OUTER *= __li_p0->dim[__k];

          /* Bail to the generic path if any parent carries a mask. */
          int __li_ok = 1;
          for ( int32_t __kk = 0; __kk < __li_st->n_parents; __kk++ ) {
            if ( __li_st->parents[__kk]->mask != NULL ) { __li_ok = 0; break; }
          }

          if ( __li_ok && __li_INNER >= 64 && __li_M * __li_INNER >= 1024 ) {
            VALUE   vout = rb_ca_new_reduced(self, slab_axes, naxes, #{oi[:ca]}, keep_axis);
            CArray *co;
            GetCArray(vout, co);
            #{oi[:c]} *op = (#{oi[:c]} *) co->ptr;

            /* Output row-major stride table (length = ca->ndim - 1).
               Output position vo maps to view position vv = (vo < ax) ? vo : vo + 1. */
            ca_size_t __li_out_stride[CA_RANK_MAX];
            {
              ca_size_t __li_s = 1;
              for ( int8_t __vo = (int8_t)(ca->ndim - 2); __vo >= 0; __vo-- ) {
                int8_t __vv = (__vo < __li_ax) ? __vo : (int8_t)(__vo + 1);
                __li_out_stride[__vo] = __li_s;
                __li_s *= ca->dim[__vv];
              }
            }
            ca_size_t __li_k_stride = __li_out_stride[__li_kax_out];

            /* Per-parent-PRE output strides + dims.  PRE view position
               vp = (pd < kax) ? pd : pd + 1.  PRE output position
               vo = (vp < ax) ? vp : vp - 1.  For M.1 (ax > kax) all PRE
               view pos < ax so vo = vp.  For M.2a (ax < kax = ax+1) all
               PRE pd < ax < kax so vp = pd and vo = pd. */
            ca_size_t __li_pre_out_stride[CA_RANK_MAX];
            ca_size_t __li_pre_dim[CA_RANK_MAX];
            for ( int8_t __pd = 0; __pd < __li_pa; __pd++ ) {
              int8_t __vp = (__pd < __li_kax) ? __pd : (int8_t)(__pd + 1);
              int8_t __vo = (__vp < __li_ax) ? __vp : (int8_t)(__vp - 1);
              __li_pre_out_stride[__pd] = __li_out_stride[__vo];
              __li_pre_dim[__pd] = __li_p0->dim[__pd];
            }

    #{buf_decls.rstrip}

            ca_size_t __li_plane_elems = __li_M * __li_INNER;
            const ca_size_t __li_TILE = 512;
            for ( int32_t __kk = 0; __kk < __li_st->n_parents; __kk++ ) {
              ca_attach(__li_st->parents[__kk]);
              const #{si[:c]} *p_root = (const #{si[:c]} *) __li_st->parents[__kk]->ptr;
              ca_size_t __li_k_base = (ca_size_t) __kk * __li_k_stride;

              ca_size_t __li_idx[CA_RANK_MAX];
              for ( int8_t __pd = 0; __pd < __li_pa; __pd++ ) __li_idx[__pd] = 0;

              for ( ca_size_t __li_o = 0; __li_o < __li_OUTER; __li_o++ ) {
                ca_size_t __li_obase = __li_k_base;
                for ( int8_t __pd = 0; __pd < __li_pa; __pd++ ) {
                  __li_obase += __li_idx[__pd] * __li_pre_out_stride[__pd];
                }
                #{oi[:c]} *__li_op_k = op + __li_obase;
                const #{si[:c]} *__li_plane = p_root + __li_o * __li_plane_elems;
                /* Inline single-OUTER core: j-stride 1 in __li_op_k preserved. */
                for ( ca_size_t __li_tile = 0; __li_tile < __li_INNER; __li_tile += __li_TILE ) {
                  ca_size_t __li_tile_len = (__li_INNER - __li_tile < __li_TILE)
                                            ? (__li_INNER - __li_tile) : __li_TILE;
        #{init_loops.rstrip}
                  for ( ca_size_t __li_i = 0; __li_i < __li_M; __li_i++ ) {
                    const #{si[:c]} *__li_row = __li_plane + __li_i * __li_INNER + __li_tile;
                    _Pragma("omp simd")
                    for ( ca_size_t __j = 0; __j < __li_tile_len; __j++ ) {
                      #{si[:c]} v = __li_row[__j];
                      #{reduce_li};
                      (void) v;
                    }
                  }
                  for ( ca_size_t __j = 0; __j < __li_tile_len; __j++ ) {
                    __li_op_k[__li_tile + __j] = (#{oi[:c]}) (#{finish_li});
                  }
                }
                /* Carry-increment OUTER multi-index (row-major over parent PRE dims). */
                for ( int8_t __pd = (int8_t)(__li_pa - 1); __pd >= 0; __pd-- ) {
                  if ( ++__li_idx[__pd] < __li_pre_dim[__pd] ) break;
                  __li_idx[__pd] = 0;
                }
              }
              ca_detach(__li_st->parents[__kk]);
            }

            return vout;
          }
        }

        /* M.2.0b (PROPOSAL_MKKERNEL_TIER2_K_AXIS_GEN, 2026-06-20):
           Case M.2b (ax < k_axis - 1): parent INNER axes are split by K
           in the output.  Strategy C (effective OUTER expansion): treat
           INNER_pre_K dims (parent dims [pa+1..k_axis-1]) as part of an
           extended effective OUTER, and use effective INNER = parent dims
           [k_axis..pndim-1] (= INNER_post_K, contig at output tail).

           L.7 core variant: M-step stride in parent = full parent INNER
           total (= Π pdim[pa+1..pndim-1]), separate from the tile loop
           bound (= eff_INNER).  Inner read stride 1 in parent + output
           write stride 1 (= contig output tail) both preserved -> SIMD
           tile reduce + write maintained.

           Performance characteristic (deliver-via-view, per the CLAUDE.md
           "deliver the materials" principle): bench (b2 pattern, M=200, K=5, eff_INNER
           =360, INNER_pre_K=16) yields 3674 us vs eager-entity 1545 us
           = 2.38x slow.  Root cause is the multi-parent data layout
           (= 5 separate 9 MB regions instead of one contig 46 MB),
           which costs DRAM/TLB/prefetcher efficiency irrespective of
           strategy.  Strategy A (temp buf + scatter, explored rev1
           sparring round 1) was implemented and benched at 3783 us
           = within noise of Strategy C, confirming the bottleneck is
           structural, NOT cache-stride from this branch.  Strategy C
           is shipped here (= simpler emit, no malloc) per round 2
           sparring decision; the 3.94x win vs generic fallback
           (.copy.sum at 14872 us) justifies landing despite missing
           eager-entity parity.  Strategy A retained in PROPOSAL as
           future-optimization substrate (= multi-level tile-M + tile-
           INNER could reclaim DRAM efficiency if revisited).

           Threshold eff_INNER >= 32 auto-bypasses at = -1 (k_axis =
           pndim -> eff_INNER = 1, fast path skipped, generic path
           handles correctness). */
        if ( naxes == 1
             && slab_axes[0] >= 1
             && slab_axes[0] != (int8_t)(ca->ndim - 1)
             && ca->mask == NULL
             && ca_func[ca->obj_type].attach == ca_stack_func.attach
             && ((CAStack *) ca)->k_axis > 0
             && slab_axes[0] + 1 < ((CAStack *) ca)->k_axis ) {
          CAStack  *__li_st    = (CAStack *) ca;
          int8_t    __li_ax    = slab_axes[0];
          int8_t    __li_kax   = (int8_t) __li_st->k_axis;
          CArray   *__li_p0    = __li_st->parents[0];
          int8_t    __li_pndim = __li_p0->ndim;
          int8_t    __li_pa    = __li_ax;                          /* M.2b: ax < kax -> pa = ax */
          int8_t    __li_kax_out = (int8_t)(__li_kax - 1);

          ca_size_t __li_M = __li_p0->dim[__li_pa];
          ca_size_t __li_eff_INNER = 1;                            /* Π pdim[kax..pndim-1] = INNER_post_K */
          for ( int8_t __k = __li_kax; __k < __li_pndim; __k++ ) __li_eff_INNER *= __li_p0->dim[__k];
          ca_size_t __li_M_stride = 1;                             /* Π pdim[pa+1..pndim-1] = full parent INNER */
          for ( int8_t __k = (int8_t)(__li_pa + 1); __k < __li_pndim; __k++ ) __li_M_stride *= __li_p0->dim[__k];

          /* Bail to the generic path if any parent carries a mask. */
          int __li_ok = 1;
          for ( int32_t __kk = 0; __kk < __li_st->n_parents; __kk++ ) {
            if ( __li_st->parents[__kk]->mask != NULL ) { __li_ok = 0; break; }
          }

          if ( __li_ok && __li_eff_INNER >= 32 && __li_M * __li_eff_INNER >= 1024 ) {
            VALUE   vout = rb_ca_new_reduced(self, slab_axes, naxes, #{oi[:ca]}, keep_axis);
            CArray *co;
            GetCArray(vout, co);
            #{oi[:c]} *op = (#{oi[:c]} *) co->ptr;

            /* Output row-major stride table (length = ca->ndim - 1). */
            ca_size_t __li_out_stride[CA_RANK_MAX];
            {
              ca_size_t __li_s = 1;
              for ( int8_t __vo = (int8_t)(ca->ndim - 2); __vo >= 0; __vo-- ) {
                int8_t __vv = (__vo < __li_ax) ? __vo : (int8_t)(__vo + 1);
                __li_out_stride[__vo] = __li_s;
                __li_s *= ca->dim[__vv];
              }
            }
            ca_size_t __li_k_stride = __li_out_stride[__li_kax_out];

            /* Parent stride table (row-major). */
            ca_size_t __li_pstride[CA_RANK_MAX];
            {
              ca_size_t __li_pss = 1;
              for ( int8_t __k = (int8_t)(__li_pndim - 1); __k >= 0; __k-- ) {
                __li_pstride[__k] = __li_pss;
                __li_pss *= __li_p0->dim[__k];
              }
            }

            /* Effective OUTER dim list: parent dims [0..kax-1] excluding pa.
               PRE = [0..pa-1] + INNER_pre_K = [pa+1..kax-1].  For each, store
               parent dim, parent stride, output stride. */
            int8_t    __li_eo_n = 0;
            ca_size_t __li_eo_dim[CA_RANK_MAX];
            ca_size_t __li_eo_pstride[CA_RANK_MAX];
            ca_size_t __li_eo_ostride[CA_RANK_MAX];
            for ( int8_t __d = 0; __d < __li_kax; __d++ ) {
              if ( __d == __li_pa ) continue;
              int8_t __vp = __d;                       /* M.2b: all eff OUTER d < kax -> vp = d */
              int8_t __vo = (__vp < __li_ax) ? __vp : (int8_t)(__vp - 1);
              __li_eo_dim[__li_eo_n]     = __li_p0->dim[__d];
              __li_eo_pstride[__li_eo_n] = __li_pstride[__d];
              __li_eo_ostride[__li_eo_n] = __li_out_stride[__vo];
              __li_eo_n++;
            }
            ca_size_t __li_OUTER = 1;
            for ( int8_t __k = 0; __k < __li_eo_n; __k++ ) __li_OUTER *= __li_eo_dim[__k];

    #{buf_decls.rstrip}

            const ca_size_t __li_TILE = 512;
            for ( int32_t __kk = 0; __kk < __li_st->n_parents; __kk++ ) {
              ca_attach(__li_st->parents[__kk]);
              const #{si[:c]} *p_root = (const #{si[:c]} *) __li_st->parents[__kk]->ptr;
              ca_size_t __li_k_base = (ca_size_t) __kk * __li_k_stride;

              ca_size_t __li_idx[CA_RANK_MAX];
              for ( int8_t __i = 0; __i < __li_eo_n; __i++ ) __li_idx[__i] = 0;

              for ( ca_size_t __li_o = 0; __li_o < __li_OUTER; __li_o++ ) {
                ca_size_t __li_pbase = 0;
                ca_size_t __li_obase = __li_k_base;
                for ( int8_t __i = 0; __i < __li_eo_n; __i++ ) {
                  __li_pbase += __li_idx[__i] * __li_eo_pstride[__i];
                  __li_obase += __li_idx[__i] * __li_eo_ostride[__i];
                }
                #{oi[:c]} *__li_op_k = op + __li_obase;
                const #{si[:c]} *__li_plane = p_root + __li_pbase;
                /* L.7 core variant: M-step uses __li_M_stride, tile loop uses __li_eff_INNER. */
                for ( ca_size_t __li_tile = 0; __li_tile < __li_eff_INNER; __li_tile += __li_TILE ) {
                  ca_size_t __li_tile_len = (__li_eff_INNER - __li_tile < __li_TILE)
                                            ? (__li_eff_INNER - __li_tile) : __li_TILE;
        #{init_loops.rstrip}
                  for ( ca_size_t __li_i = 0; __li_i < __li_M; __li_i++ ) {
                    const #{si[:c]} *__li_row = __li_plane + __li_i * __li_M_stride + __li_tile;
                    _Pragma("omp simd")
                    for ( ca_size_t __j = 0; __j < __li_tile_len; __j++ ) {
                      #{si[:c]} v = __li_row[__j];
                      #{reduce_li};
                      (void) v;
                    }
                  }
                  for ( ca_size_t __j = 0; __j < __li_tile_len; __j++ ) {
                    __li_op_k[__li_tile + __j] = (#{oi[:c]}) (#{finish_li});
                  }
                }
                /* Carry-increment effective OUTER multi-index. */
                for ( int8_t __i = (int8_t)(__li_eo_n - 1); __i >= 0; __i-- ) {
                  if ( ++__li_idx[__i] < __li_eo_dim[__i] ) break;
                  __li_idx[__i] = 0;
                }
              }
              ca_detach(__li_st->parents[__kk]);
            }

            return vout;
          }
        }
    C
  end

  # FM.1.0/FM.1.5 (PROPOSAL_FUSED_MINMAX): multi-output (outputs: 2) reduce
  # emitter.  Allocates 2 output CArrays, writes both inside the slab loop,
  # returns a Ruby Array [out1, out2] (= Q1 closure: `[min, max]` Array).
  # Scope per PROPOSAL_FUSED_MINMAX:
  #   - 2 outputs only (= asserted by reduce DSL validation)
  #   - mask_policy: nil or :min_count (FM.1.5; the latter propagates the
  #     input mask to both output cells with identical bits since both
  #     reductions consume the same slab)
  #   - no streaming / view_flat / array_arg / value_arg
  #   - reduction_kind: :none only
  # The if-form discipline (CLAUDE.md "write multi-reduction fused kernels
  # in if-form") is enforced by author, not by the generator.
  def self.emit_reduce_native_multi(io, k, src)
    si        = DTYPES[src]
    oi        = output_info(k, src)
    ruby_wrap = ruby_scalar(k, oi)
    name      = k[:name]
    min_count = (k[:mask_policy] == :min_count)
    extra_args = min_count ? ", ca_size_t min_count" : ""

    # outputs: 2 — finish is Hash with exactly 2 entries (= validated).
    finish_pairs = k[:finish].to_a   # [[:min, "lo"], [:max, "hi"]]
    finish_exprs = finish_pairs.map { |(_, expr)| resolve_expr(expr, oi, src) }

    # State decls: same as single-output (= reuse the pattern from
    # emit_reduce_native).
    acc_var = k[:state].keys.first
    state_decls = k[:state].map do |var, type_token|
      c_type = resolve_state_type(type_token, oi, si, src)
      init_e = resolve_init_expr(k[:init][var], oi, si, src)
      if var == acc_var
        ["#{c_type} #{var};", init_e]
      else
        ["#{c_type} #{var} = #{init_e};", nil]
      end
    end
    acc_init  = state_decls.find { |_, ai| ai }[1]
    decls     = state_decls.map(&:first)
    reduce_stmt = resolve_expr(k[:reduce], oi, src)

    io.puts
    io.puts <<~C
      static VALUE
      #{name}_ki_native_#{src} (VALUE self, CArray *ca, int8_t *slab_axes, int8_t naxes, int keep_axis#{extra_args})
      {
        VALUE vout_a = rb_ca_new_reduced(self, slab_axes, naxes, #{oi[:ca]}, keep_axis);
        VALUE vout_b = rb_ca_new_reduced(self, slab_axes, naxes, #{oi[:ca]}, keep_axis);
        CArray *co_a, *co_b;
        GetCArray(vout_a, co_a);
        GetCArray(vout_b, co_b);
        #{oi[:c]} *op_a = (#{oi[:c]} *) co_a->ptr;
        #{oi[:c]} *op_b = (#{oi[:c]} *) co_b->ptr;
        ca_iter_state st;
        int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES,
                                       slab_axes, naxes, 0);
        if ( rc != CA_ITER_OK ) {
          rb_raise(rb_eRuntimeError,
                   "#{name}_ki: kernel_iterator init failed rc=%d", rc);
        }
        char       *p;
        boolean8_t *m;
        ca_size_t   out_i = 0;
    C
    if min_count
      io.puts "      boolean8_t *op_mask_a = NULL;   /* lazily allocated on first UNDEF */"
      io.puts "      boolean8_t *op_mask_b = NULL;"
    end
    io.puts "      while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {"
    decls.each { |d| io.puts "      #{d}" }
    if min_count
      io.puts "      ca_size_t masked_cnt = 0;"
      io.puts "      CA_SLAB_REDUCE_T_EX(#{si[:c]}, st, p, m, #{acc_var}, #{acc_init}, #{reduce_stmt}, masked_cnt);"
      # Same trigger as single-output :min_count: legacy default (all_masked)
      # when min_count < 0, otherwise need at least min_count valid cells.
      trigger = "(min_count < 0 ? masked_cnt == st.slab_elements " \
                ": st.slab_elements - masked_cnt < min_count)"
      io.puts "      if ( #{trigger} ) {"
      io.puts "        if ( ! op_mask_a ) {"
      io.puts "          ca_create_mask(co_a);"
      io.puts "          op_mask_a = (boolean8_t *) co_a->mask->ptr;"
      io.puts "        }"
      io.puts "        if ( ! op_mask_b ) {"
      io.puts "          ca_create_mask(co_b);"
      io.puts "          op_mask_b = (boolean8_t *) co_b->mask->ptr;"
      io.puts "        }"
      io.puts "        op_mask_a[out_i] = 1;"
      io.puts "        op_mask_b[out_i] = 1;"
      # Sentinel value: both outputs share the same masked-out slab so we
      # write 0 to both (the mask bit is the source of truth).
      io.puts "        op_a[out_i] = (#{oi[:c]}) 0;"
      io.puts "        op_b[out_i] = (#{oi[:c]}) 0;"
      io.puts "        out_i++;"
      io.puts "      } else {"
      io.puts "        op_a[out_i] = (#{oi[:c]}) (#{finish_exprs[0]});"
      io.puts "        op_b[out_i] = (#{oi[:c]}) (#{finish_exprs[1]});"
      io.puts "        out_i++;"
      io.puts "      }"
    else
      io.puts "      CA_SLAB_REDUCE_T(#{si[:c]}, st, p, m, #{acc_var}, #{acc_init}, #{reduce_stmt});"
      io.puts "      op_a[out_i] = (#{oi[:c]}) (#{finish_exprs[0]});"
      io.puts "      op_b[out_i] = (#{oi[:c]}) (#{finish_exprs[1]});"
      io.puts "      out_i++;"
    end
    io.puts "      }"
    io.puts "      ca_iter_state_finish(&st);"
    # keep_axis: skip the scalar (assoc-of-scalars) shortcut and return the
    # pair of [1,...,1] entities instead.
    io.puts "      if ( naxes == ca->ndim && !keep_axis ) {"
    if min_count
      # Full reduction: if the sole output cell is masked, return CA_UNDEF.
      # (Both op_mask_a and op_mask_b share the same bit since both
      # reductions consume the same slab, so checking _a is sufficient.)
      io.puts "        if ( op_mask_a && op_mask_a[0] ) return CA_UNDEF;"
    end
    io.puts "        return rb_assoc_new(#{ruby_wrap}(op_a[0]), #{ruby_wrap}(op_b[0]));"
    io.puts "      }"
    io.puts "      return rb_assoc_new(vout_a, vout_b);"
    io.puts "    }"
  end

  # P.4.5.3b/c: streaming chunked reduce path emitter.  Generates an
  # early-return branch at the top of name_ki_native_<src> that pulls
  # the lazy view in fixed-size chunks via ca_xfer_stride instead of
  # full-materialising via SRC_ATTACH.  Falls through to the existing
  # path when conditions aren't met.
  #
  # Strategy: chunk along the outermost axis.  inner = prod(dim[1..]);
  # rows_per_chunk = max(1, target_elems / inner).  1-D is the natural
  # sub-case (inner == 1, rows = target_elems).
  #
  # Memory peak: O(max(target_elems, inner) * sizeof T) instead of O(N).
  # For N-D, this drops the outermost dim from the materialised buffer,
  # which is typically the dominant factor (e.g. 1000x10000 f64 reduction:
  # 80MB -> 80KB).  Wall-clock perf at large N matches or beats
  # SRC_ATTACH because each chunk fits in L1d (or L2 for wide last dims).
  #
  # Restrictions handled by short-circuit checks (= falls through to
  # SRC_ATTACH path):
  #   - axis kwarg (= partial reduction): naxes != ca->ndim
  #     (structural blocker: CABinOp/CABinCmp xfer_stride rebuilds
  #     right_strides from counts, so non-rectangular slab pulls
  #     produce wrong values for the right operand.  See proposal
  #     §future-work / partial streaming blocker.)
  #   - non-lazy source: !ca_is_lazy_view(ca)
  #   - mask present: ca_has_mask(ca)
  def self.emit_reduce_streaming(io, k, si, oi, ruby_wrap, acc_var,
                                  acc_init, decls, reduce_stmt,
                                  finish_expr, extra_args)
    name      = k[:name]
    min_count = (k[:mask_policy] == :min_count)
    has_mp    = !k[:mask_policy].nil?

    io.puts "    /* P.4.5.3b/c streaming chunked reduce: full reduction over lazy unmasked.  */"
    io.puts "    /* P.4.5.3c (N-D): outer-axis chunking, 1-D is the natural sub-case.        */"
    io.puts "    if ( naxes == ca->ndim && ca->ndim >= 1 && !keep_axis &&"
    io.puts "         ca_is_lazy_view(ca) && ! ca_has_mask(ca) ) {"
    io.puts "      ca_size_t __inner = 1;"
    io.puts "      int       __k;"
    io.puts "      for ( __k = 1; __k < ca->ndim; __k++ ) __inner *= ca->dim[__k];"
    io.puts "      ca_size_t __target = 4096;   /* L1d-friendly element budget (32KB for f64) */"
    io.puts "      ca_size_t __rows   = (__inner > 0) ? (__target / __inner) : __target;"
    io.puts "      if ( __rows < 1 ) __rows = 1;       /* at least one row per chunk */"
    io.puts "      ca_size_t __chunk_elems = __rows * __inner;"
    io.puts "      ca_size_t __outer       = ca->dim[0];"
    io.puts "      ca_size_t __starts[CA_RANK_MAX]  = {0};"
    io.puts "      ca_size_t __counts[CA_RANK_MAX];"
    io.puts "      ca_size_t __strides[CA_RANK_MAX];"
    io.puts "      ca_size_t __s = sizeof(#{si[:c]});"
    io.puts "      for ( __k = ca->ndim - 1; __k >= 0; __k-- ) {"
    io.puts "        __strides[__k] = __s;"
    io.puts "        __s *= ca->dim[__k];"
    io.puts "      }"
    io.puts "      for ( __k = 1; __k < ca->ndim; __k++ ) __counts[__k] = ca->dim[__k];"
    io.puts "      ca_size_t __outer_off = 0;"
    decls.each { |d| io.puts "      #{d}" }
    # acc_var requires explicit init (= the macro normally does this).
    # Other state vars in decls already include `= init` per line.
    io.puts "      #{acc_var} = (#{acc_init});"
    if has_mp
      # Mask-policy reductions need masked_cnt to satisfy the macro/
      # finish_expr signature.  On streaming we have no mask, so it's
      # always 0.  Suppressed-unused via the explicit usage below.
      io.puts "      ca_size_t masked_cnt = 0;  /* unused on streaming (no mask) */"
      io.puts "      (void) masked_cnt;"
    end
    io.puts "      ca_lazy_arena_enter();"
    io.puts "      #{si[:c]} *__chunk = (#{si[:c]} *) ca_lazy_arena_acquire(__chunk_elems * sizeof(#{si[:c]}));"
    io.puts "      while ( __outer_off < __outer ) {"
    io.puts "        ca_size_t __r = (__outer - __outer_off < __rows) ? (__outer - __outer_off) : __rows;"
    io.puts "        ca_size_t __n = __r * __inner;"
    io.puts "        __starts[0] = __outer_off;"
    io.puts "        __counts[0] = __r;"
    io.puts "        ca_xfer_stride(ca, __starts, __counts, __strides, __chunk, CA_XFER_GET);"
    io.puts "        ca_size_t __i;"
    io.puts "        for ( __i = 0; __i < __n; __i++ ) {"
    io.puts "          #{si[:c]} v = __chunk[__i];"
    io.puts "          #{reduce_stmt};"
    io.puts "        }"
    io.puts "        __outer_off += __r;"
    io.puts "      }"
    io.puts "      ca_lazy_arena_release(__chunk);"
    io.puts "      ca_lazy_arena_exit();"
    if has_mp
      # Streaming path has no mask source, so masked_cnt is 0; min_count
      # / strict / all_masked triggers all evaluate to false except
      # min_count when explicit > 0 is set on an all-clean source (= no
      # trigger).  Output is the finish expression directly.
      io.puts "      return #{ruby_wrap}((#{oi[:c]}) (#{finish_expr}));"
    else
      io.puts "      return #{ruby_wrap}((#{oi[:c]}) (#{finish_expr}));"
    end
    io.puts "    }"
  end

  def self.emit_reduce_dispatch(io, k)
    name       = k[:name]
    min_count  = (k[:mask_policy] == :min_count)
    has_varg   = !k[:value_arg].nil?
    has_aarg   = !k[:array_arg].nil?
    # Native call extra args go after argv in this order:
    #   cw (array_arg), value_arg, min_count.
    # (See emit_reduce_native for matching prototype order.)
    extra_call = ""
    extra_call += ", cw" if has_aarg
    extra_call += ", value_arg" if has_varg
    extra_call += ", min_count" if min_count

    io.puts
    # Public-linkage dispatcher (no `static`) so other TUs (carray_count.c
    # rb_ca_count, future cross-file callers) can forward-declare and
    # call directly via C entry instead of going through Ruby method
    # dispatch.  Native helpers above remain static (per-src specialised).
    io.puts "VALUE"
    io.puts "rb_ca_#{name}_ki (int argc, VALUE *argv, VALUE self)"
    io.puts "{"
    io.puts "  CArray *src;"
    io.puts "  GetCArray(self, src);"

    if k[:object_escape]
      # CA_OBJECT escape: forward argc/argv (weights + trailing options hash,
      # untouched) to the Ruby composition helper.  Intercept before any arg
      # parsing so the helper owns the full original signature.
      io.puts "  if ( src->data_type == CA_OBJECT ) {"
      io.puts "    return rb_funcallv(self, rb_intern(\"#{k[:object_escape]}\"), argc, argv);"
      io.puts "  }"
    end

    if k[:face_gate]
      # Order-structure reduction (min/max/min_index/max_index family):
      # descend an ORDERABLE Face to storage so the numeric path runs.
      # Without this, a Face (surface data_type CA_FIXLEN) dispatches to the
      # fixlen memcmp branch, which orders int64 storage by little-endian
      # byte order -- wrong for values >= 256 or negative.  ca_is_face gates
      # this so a genuine fixlen array still takes the memcmp branch.  Same
      # ORDERABLE policy as the sort family (emit_sort_face_gate).
      emit_reduce_face_gate(io, name, k[:face_gate] == :relift)
    end

    # API harmonisation A.2 (PROPOSAL_AXIS_KWARG_UNIFICATION.md rev2):
    # pop trailing kwargs hash exactly once.  axis: lives in this hash
    # along with min_count: / fill_value:.  Positional args carry weights
    # (array_arg) and value (value_arg) only.  Variadic axis form is
    # gone (= clean break per sparring D-1).
    io.puts "  volatile VALUE ropt = rb_pop_options(&argc, &argv);"
    # PoC scan-merge: scan every accepted option key in a single
    # rb_scan_options call up front, instead of a second scan in the
    # min_count section below.  Variables for the later sections are
    # declared here and consumed where they are needed.
    if min_count
      io.puts "  volatile VALUE raxis = Qnil, rkeep_axis = Qnil, rmin_count = Qnil, rfval = Qnil;"
      io.puts "  rb_scan_options(ropt, \"axis,keep_axis,min_count,fill_value\", &raxis, &rkeep_axis, &rmin_count, &rfval);"
    else
      io.puts "  volatile VALUE raxis = Qnil, rkeep_axis = Qnil;"
      io.puts "  rb_scan_options(ropt, \"axis,keep_axis\", &raxis, &rkeep_axis);"
    end
    io.puts "  int keep_axis = RTEST(rkeep_axis);"
    io.puts "  int8_t slab_axes[CA_RANK_MAX];"
    io.puts "  int8_t naxes = rb_ca_parse_reduce_axes_kw(raxis, src, slab_axes);"

    if has_aarg
      # Weight storage type: :promote materializes weights at the f64
      # computation type (so a float weight against an int source is not
      # truncated -- the body reads it as `double`); :match_source keeps the
      # legacy source-type storage.  waca is the CA_* constant the three
      # materialization sites (W-A1 / W-A2 / W-A3) allocate/wrap against, and
      # must agree with the T_W the reduce macro reads (double for :promote).
      waca = (k[:array_arg][:data_type] == :promote) ? "CA_FLOAT64" : "src->data_type"
      # PROPOSAL_REDUCTION_PER_FIBER_AUX_OPERAND rev1: weights acceptance
      # expanded to 3 forms (W-A1 scalar / W-A2 1-D axis-broadcast / W-A3
      # full per-element).  W-A1 / W-A2 are materialized to W-A3 form
      # at dispatch (= simple, uniform kernel path).  rev5 strict acceptance
      # mirrors PROPOSAL_LINEAR_INTERP_PER_FIBER_MATCHED rev5 in spirit.
      io.puts "  if ( argc < 1 ) {"
      io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: missing weights argument (1+ required, got 0)");]
      io.puts "  }"
      io.puts "  volatile VALUE rweights = argv[0];"
      io.puts "  argc--; argv++;"
      # rev5 A1: convert a single-element CArray (CScalar / [1] 1-D / all
      # dim==1) to a Ruby Numeric and route it through the scalar path.
      io.puts "  if ( rb_obj_is_carray(rweights) ) {"
      io.puts "    CArray *cv_pre_;"
      io.puts "    GetCArray(rweights, cv_pre_);"
      io.puts "    if ( cv_pre_->elements == 1 ) {"
      io.puts "      rweights = rb_funcall(rweights, rb_intern(\"[]\"), 1, INT2NUM(0));"
      io.puts "    }"
      io.puts "  }"
      io.puts "  volatile VALUE vcw;"
      io.puts "  CArray *cw;"
      io.puts "  if ( ! rb_obj_is_carray(rweights) ) {"
      io.puts "    /* W-A1: Ruby Numeric scalar -> full-shape constant weight CArray */"
      io.puts "    vcw = rb_carray_new(#{waca}, src->ndim, src->dim, 0, NULL);"
      io.puts "    GetCArray(vcw, cw);"
      io.puts "    ca_attach(cw);"
      io.puts "    rb_ca_obj2ptr(vcw, rweights, cw->ptr);  /* fill first cell */"
      io.puts "    /* broadcast first cell to all elements (= constant fill) */"
      io.puts "    {"
      io.puts "      char *p0 = cw->ptr;"
      io.puts "      for ( ca_size_t i = 1; i < cw->elements; i++ ) {"
      io.puts "        memcpy(cw->ptr + i * cw->bytes, p0, cw->bytes);"
      io.puts "      }"
      io.puts "    }"
      io.puts "  }"
      io.puts "  else {"
      io.puts "    /* CArray val: coerce to the weight storage type (f64 for :promote, so a"
      io.puts "       float weight against an int source is not truncated) */"
      io.puts "    vcw = rb_ca_wrap_readonly(rweights, INT2NUM(#{waca}));"
      io.puts "    CArray *cv;"
      io.puts "    GetCArray(vcw, cv);"
      io.puts ""
      io.puts "    /* rev5 form detection: A3 (same ndim) -> A2 (1-D axis-broadcast) -> raise */"
      io.puts "    if ( cv->ndim == src->ndim ) {"
      io.puts "      /* W-A3 commit-or-raise: shape strict match */"
      io.puts "      for ( int8_t i = 0; i < src->ndim; i++ ) {"
      io.puts "        if ( cv->dim[i] != src->dim[i] ) {"
      io.puts %Q[          rb_raise(rb_eArgError, "#{name}_ki: w shape mismatch (W-A3 candidate, dim[%d]=%ld != self.dim[%d]=%ld; expected scalar / [M=self.dim[axes[0]]] / self.shape)", (int)i, (long)cv->dim[i], (int)i, (long)src->dim[i]);]
      io.puts "        }"
      io.puts "      }"
      io.puts "      /* W-A3 path: use cv directly (= existing) */"
      io.puts "      cw = cv;"
      io.puts "      ca_attach(cw);"
      io.puts "    }"
      io.puts "    else if ( naxes == 1 && cv->ndim == 1 && cv->dim[0] == src->dim[slab_axes[0]] ) {"
      io.puts "      /* W-A2: 1-D axis-broadcast -> materialize to full shape */"
      io.puts "      ca_attach(cv);"
      io.puts "      vcw = rb_carray_new(#{waca}, src->ndim, src->dim, 0, NULL);"
      io.puts "      GetCArray(vcw, cw);"
      io.puts "      ca_attach(cw);"
      io.puts "      /* broadcast cv (1-D, length src->dim[slab_axes[0]]) along reduce axis */"
      io.puts "      {"
      io.puts "        int8_t baxis = slab_axes[0];"
      io.puts "        ca_size_t inner_stride = 1;"
      io.puts "        for ( int8_t ii = baxis + 1; ii < src->ndim; ii++ ) inner_stride *= src->dim[ii];"
      io.puts "        ca_size_t axis_n = src->dim[baxis];"
      io.puts "        ca_size_t outer  = src->elements / (axis_n * inner_stride);"
      io.puts "        for ( ca_size_t o = 0; o < outer; o++ ) {"
      io.puts "          for ( ca_size_t a = 0; a < axis_n; a++ ) {"
      io.puts "            for ( ca_size_t in = 0; in < inner_stride; in++ ) {"
      io.puts "              ca_size_t flat = (o * axis_n + a) * inner_stride + in;"
      io.puts "              memcpy(cw->ptr + flat * cw->bytes, cv->ptr + a * cv->bytes, cw->bytes);"
      io.puts "            }"
      io.puts "          }"
      io.puts "        }"
      io.puts "      }"
      io.puts "      /* Propagate cv mask via W-A3 overlay path below (= mask materialize) */"
      io.puts "      if ( ca_has_mask(cv) ) {"
      io.puts "        /* Allocate cw mask + broadcast cv mask along axis */"
      io.puts "        ca_create_mask(cw);"
      io.puts "        boolean8_t *cw_m = (boolean8_t *)cw->mask->ptr;"
      io.puts "        boolean8_t *cv_m = (boolean8_t *)cv->mask->ptr;"
      io.puts "        int8_t baxis = slab_axes[0];"
      io.puts "        ca_size_t inner_stride = 1;"
      io.puts "        for ( int8_t ii = baxis + 1; ii < src->ndim; ii++ ) inner_stride *= src->dim[ii];"
      io.puts "        ca_size_t axis_n = src->dim[baxis];"
      io.puts "        ca_size_t outer  = src->elements / (axis_n * inner_stride);"
      io.puts "        for ( ca_size_t o = 0; o < outer; o++ ) {"
      io.puts "          for ( ca_size_t a = 0; a < axis_n; a++ ) {"
      io.puts "            for ( ca_size_t in = 0; in < inner_stride; in++ ) {"
      io.puts "              ca_size_t flat = (o * axis_n + a) * inner_stride + in;"
      io.puts "              cw_m[flat] = cv_m[a];"
      io.puts "            }"
      io.puts "          }"
      io.puts "        }"
      io.puts "      }"
      io.puts "      ca_detach(cv);"
      io.puts "    }"
      io.puts "    else {"
      io.puts %Q[      rb_raise(rb_eArgError, "#{name}_ki: w shape not accepted (val.ndim=%d, val.dim[0]=%ld; expected scalar / [M=%ld] / self.shape)", (int)cv->ndim, (long)(cv->ndim >= 1 ? cv->dim[0] : 0), (long)(naxes == 1 ? src->dim[slab_axes[0]] : -1));]
      io.puts "    }"
      io.puts "  }"
      # Mask overlay (= legacy W-A3 path; if the materialized cw carries a mask, overlay it)
      io.puts "  volatile VALUE __vsrc_keep = self;   /* GC guard */ (void) __vsrc_keep;"
      io.puts "  if ( ca_has_mask(cw) ) {"
      io.puts "    CArray *src_copy = ca_copy(src);"
      io.puts "    VALUE vsrc_copy = ca_wrap_struct(src_copy);"
      io.puts "    ca_copy_mask_overlay(src_copy, src_copy->elements, 1, cw);"
      io.puts "    src = src_copy;"
      io.puts "    self = vsrc_copy;"
      io.puts "  }"
    end

    if has_varg
      # CF.1 (count family): pop the first positional argument as the
      # runtime value_arg (e.g. `a.count_equal(5, 0)` -- 5 is value_arg,
      # 0 is axis).  Per-src cast happens inside the switch case below.
      io.puts "  if ( argc < 1 ) {"
      io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: missing value argument (1+ required, got 0)");]
      io.puts "  }"
      io.puts "  volatile VALUE rval = argv[0];"
      io.puts "  argc--; argv++;"
    end

    if min_count
      # rmin_count / rfval were scanned up front (PoC scan-merge); here we
      # only interpret them.  Sentinel min_count = -1 means "no opt given"
      # -> :all_masked semantics.
      io.puts "  ca_size_t min_count = -1;"
      io.puts "  if ( ! NIL_P(rmin_count) ) {"
      io.puts "    ca_size_t mc_user = NUM2SIZE(rmin_count);"
      io.puts "    if ( mc_user < 0 ) {"
      io.puts %Q[      rb_raise(rb_eArgError, "#{name}_ki: :min_count must be non-negative, got %lld", (long long) mc_user);]
      io.puts "    }"
      io.puts "    /* :min_count = 0 collapses to legacy default (any 1 valid). */"
      io.puts "    if ( mc_user > 0 ) min_count = mc_user;"
      io.puts "  }"
      io.puts "  VALUE result;"
    elsif has_aarg
      # array_arg without min_count: still need a single exit so we can
      # detach cw before returning.  Use the same `VALUE result; ...; break;`
      # pattern as min_count, then return result after the switch.
      io.puts "  VALUE result;"
    end

    use_result_var = min_count || has_aarg

    # Clean-break enforcement: after consuming weights / value, no positional
    # axis is allowed.  Variadic `a.sum(0, 1)` raises here with a migration
    # hint pointing at the kwarg form.
    io.puts "  if ( argc > 0 ) {"
    io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: positional axis arguments are no longer accepted (got %d); use axis: kwarg, e.g. a.#{name}(axis: 0) or a.#{name}(axis: [0, 1])", argc);]
    io.puts "  }"

    io.puts "  switch ( src->data_type ) {"
    k[:source].each do |s|
      si = DTYPES[s]
      # Per-src value_arg cast: NUM2LL / NUM2ULL / NUM2DBL -> (T_IN).
      varg_decl = has_varg ? "      #{si[:c]} value_arg = (#{si[:c]}) #{si[:num2c]}(rval);\n" : ""
      if use_result_var || has_varg
        io.puts "    case #{si[:ca]}: {"
        io.print varg_decl unless varg_decl.empty?
        if use_result_var
          io.puts "      result = #{name}_ki_native_#{s}(self, src, slab_axes, naxes, keep_axis#{extra_call});"
          io.puts "      break;"
        else
          io.puts "      return #{name}_ki_native_#{s}(self, src, slab_axes, naxes, keep_axis#{extra_call});"
        end
        io.puts "    }"
      else
        io.puts "    case #{si[:ca]}: return #{name}_ki_native_#{s}(self, src, slab_axes, naxes, keep_axis);"
      end
    end
    case k[:fallback]
    when :wrap_to_f64
      io.puts "    default: {"
      io.puts "      /* Phase E: only wrap data_types that have a meaningful float64"
      io.puts "         representation.  Complex / fixlen / object would lose"
      io.puts "         structure (e.g. complex -> float strips imaginary part)"
      io.puts "         so reject explicitly, matching legacy DataTypeError. */"
      io.puts "      switch ( src->data_type ) {"
      io.puts "        case CA_BOOLEAN: break;   /* wrap: count-of-trues semantic */"
      io.puts "        default:"
      io.puts %Q[          rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")}, or boolean)", ca_type_name[src->data_type]);]
      io.puts "      }"
      io.puts "      VALUE   vsrc = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));"
      io.puts "      CArray *casted;"
      io.puts "      GetCArray(vsrc, casted);"
      if has_varg
        # f64 fallback cast: source has been wrapped to float64, so value
        # should also be promoted.
        io.puts "      double value_arg = (double) NUM2DBL(rval);"
      end
      if use_result_var
        io.puts "      result = #{name}_ki_native_f64(vsrc, casted, slab_axes, naxes, keep_axis#{extra_call});"
        io.puts "      break;"
      else
        io.puts "      return #{name}_ki_native_f64(vsrc, casted, slab_axes, naxes, keep_axis#{extra_call});"
      end
      io.puts "    }"
    when :raise
      io.puts "    default:"
      io.puts %Q[      rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")})", ca_type_name[src->data_type]);]
    end
    io.puts "  }"

    if min_count
      # Apply fill_value substitution: CA_UNDEF (full reduction all-masked)
      # or per-axis CArray with mask bits.
      io.puts "  if ( ! NIL_P(rfval) ) {"
      io.puts "    if ( result == CA_UNDEF ) {"
      io.puts "      result = rfval;"
      io.puts "    } else if ( TYPE(result) != T_FLOAT && rb_obj_is_kind_of(result, rb_cCArray) ) {"
      io.puts "      CArray *cr;"
      io.puts "      GetCArray(result, cr);"
      io.puts "      if ( ca_has_mask(cr) ) {"
      io.puts "        result = rb_ca_mask_fill_copy(result, rfval);"
      io.puts "      }"
      io.puts "    }"
      io.puts "  }"
    end

    # array_arg cleanup: detach weights (paired with ca_attach above).
    if has_aarg
      io.puts "  ca_detach(cw);"
    end

    if k[:face_gate] == :relift
      # Descended through emit_reduce_face_gate: re-lift the storage result
      # back into the Face before returning.
      emit_reduce_face_relift(io)
    end

    if use_result_var
      io.puts "  return result;"
    else
      io.puts "  return Qnil;  /* unreachable */"
    end
    io.puts "}"
  end

  # ---- map emitter ------------------------------------------------------

  def self.emit_map(io, k)
    io.puts
    io.puts "/* ===== #{k[:name]}_ki ============================================ */"
    k[:source].each do |src|
      emit_map_native(io, k, src)
    end
    emit_map_dispatch(io, k)
  end

  def self.emit_map_native(io, k, src)
    si   = DTYPES[src]
    oi   = output_info(k, src)
    name = k[:name]
    expr = resolve_expr(k[:expr], oi, src)

    io.puts
    io.puts <<~C
      static VALUE
      #{name}_ki_native_#{src} (VALUE self, CArray *ca)
      {
        VALUE   vout = rb_ca_template_with_type(self, INT2NUM(#{oi[:ca]}),
                                                INT2NUM(sizeof(#{oi[:c]})));
        CArray *co;
        GetCArray(vout, co);

        /* All-axes slab = whole array as one K-D walk via CA_SLAB_AXES.
           CA_SLAB_WHOLE uses the flat next_slab path, which doesn't
           populate slab_dims; CA_SLAB_AXES with naxes == ndim is the
           K-D-walkable form. */
        int8_t slab_axes[CA_RANK_MAX];
        int8_t naxes = ca->ndim;
        for ( int8_t k = 0; k < naxes; k++ ) slab_axes[k] = k;

        ca_iter_state st_in, st_out;
        int rc;
        rc = ca_iter_state_init_l2(&st_in,  ca, CA_SLAB_AXES,
                                   slab_axes, naxes, 0);
        if ( rc != CA_ITER_OK ) {
          rb_raise(rb_eRuntimeError,
                   "#{name}_ki: input init failed rc=%d", rc);
        }
        rc = ca_iter_state_init_l2(&st_out, co, CA_SLAB_AXES,
                                   slab_axes, naxes, CA_KERNEL_WRITE);
        if ( rc != CA_ITER_OK ) {
          ca_iter_state_finish(&st_in);
          rb_raise(rb_eRuntimeError,
                   "#{name}_ki: output init failed rc=%d", rc);
        }

        char       *pi, *po;
        boolean8_t *mi, *mo;
        while ( ca_iter_state_next_slab_axes(&st_in,  &pi, &mi) &&
                ca_iter_state_next_slab_axes(&st_out, &po, &mo) ) {
          CA_SLAB_MAP_T(#{si[:c]}, #{oi[:c]}, st_in, pi, st_out, po, #{expr});
          ca_iter_state_sync_slab(&st_out);
        }
        ca_iter_state_finish(&st_in);
        ca_iter_state_finish(&st_out);
        return vout;
      }
    C
  end

  def self.emit_map_dispatch(io, k)
    name = k[:name]
    io.puts
    io.puts "static VALUE"
    io.puts "rb_ca_#{name}_ki (VALUE self)"
    io.puts "{"
    io.puts "  CArray *src;"
    io.puts "  GetCArray(self, src);"
    io.puts "  switch ( src->data_type ) {"
    k[:source].each do |s|
      si = DTYPES[s]
      io.puts "    case #{si[:ca]}: return #{name}_ki_native_#{s}(self, src);"
    end
    case k[:fallback]
    when :wrap_to_f64
      io.puts "    default: {"
      io.puts "      /* Phase E: only wrap data_types that have a meaningful float64"
      io.puts "         representation.  Complex / fixlen / object would lose"
      io.puts "         structure (e.g. complex -> float strips imaginary part)"
      io.puts "         so reject explicitly, matching legacy DataTypeError. */"
      io.puts "      switch ( src->data_type ) {"
      io.puts "        case CA_BOOLEAN: break;   /* wrap: count-of-trues semantic */"
      io.puts "        default:"
      io.puts %Q[          rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")}, or boolean)", ca_type_name[src->data_type]);]
      io.puts "      }"
      io.puts "      VALUE   vsrc = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));"
      io.puts "      CArray *casted;"
      io.puts "      GetCArray(vsrc, casted);"
      io.puts "      return #{name}_ki_native_f64(vsrc, casted);"
      io.puts "    }"
    when :raise
      io.puts "    default:"
      io.puts %Q[      rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")})", ca_type_name[src->data_type]);]
    end
    io.puts "  }"
    io.puts "  return Qnil;  /* unreachable */"
    io.puts "}"
  end

  # ---- scan emitter -----------------------------------------------------

  def self.emit_scan(io, k)
    io.puts
    io.puts "/* ===== #{k[:name]}_ki ============================================ */"
    k[:source].each do |src|
      emit_scan_native(io, k, src)
    end
    emit_scan_dispatch(io, k)
  end

  def self.emit_scan_native(io, k, src)
    si        = DTYPES[src]
    oi        = output_info(k, src)
    name      = k[:name]
    # acc_type :load_type -> T_ACC = T_LOAD = si[:c]; INIT / STEP need
    # T_ACC tokens to resolve against the source type.  Default (nil) ->
    # T_ACC = T_OUT, resolve against oi (= existing scan behavior).
    acc_ci    = (k[:acc_type] == :load_type) ? si : oi
    init_expr = resolve_init_expr(k[:init], acc_ci, si, src)
    step_stmt = resolve_expr(k[:step], acc_ci, src)
    gated     = (k[:empty] == :undef)

    # empty: :undef -> allocate the output mask up front when the input
    # carries one (a fiber can only go UNDEF on its leading masked cells,
    # which exist only when the input is masked).  co_root / op_mask are the
    # value / mask bases used to derive the per-fiber mask base parallel to
    # the aliased output value slab.
    mask_setup =
      if gated
        "\n" \
        "    boolean8_t *op_mask = NULL;\n" \
        "    char       *co_root = (char *) co->ptr;\n" \
        "    if ( ca_has_mask(ca) ) {\n" \
        "      ca_create_mask(co);\n" \
        "      op_mask = (boolean8_t *) co->mask->ptr;\n" \
        "    }\n"
      else
        ""
      end

    scan_call =
      if k[:acc_type] == :load_type
        "CA_SLAB_SCAN_TA(#{si[:c]}, #{oi[:c]}, #{si[:c]}, st_in, pi, mi,\n" \
        "                         st_out, po, #{init_expr}, #{step_stmt});"
      elsif gated
        "boolean8_t *mo_fiber = op_mask\n" \
        "            ? op_mask + (ca_size_t)(po - co_root) / (ca_size_t) co->bytes\n" \
        "            : NULL;\n" \
        "          CA_SLAB_SCAN_T_GATED(#{si[:c]}, #{oi[:c]}, st_in, pi, mi,\n" \
        "                         st_out, po, mo_fiber, #{init_expr}, #{step_stmt});"
      else
        "CA_SLAB_SCAN_T(#{si[:c]}, #{oi[:c]}, st_in, pi, mi,\n" \
        "                         st_out, po, #{init_expr}, #{step_stmt});"
      end

    io.puts
    io.puts <<~C
      static VALUE
      #{name}_ki_native_#{src} (VALUE self, CArray *ca, int axis)
      {
        VALUE   vout = rb_ca_template_with_type(self, INT2NUM(#{oi[:ca]}),
                                                INT2NUM(sizeof(#{oi[:c]})));
        CArray *co;
        GetCArray(vout, co);

        /* 1-axis scan: slab = the scan axis only.  Each next_slab_axes
           iteration is one "fiber" along that axis with acc reset to
           INIT inside the macro. */
        int8_t slab_axes[CA_RANK_MAX];
        slab_axes[0] = (int8_t) axis;
        ca_iter_state st_in, st_out;
        int rc;
        rc = ca_iter_state_init_l2(&st_in,  ca, CA_SLAB_AXES,
                                   slab_axes, 1, 0);
        if ( rc != CA_ITER_OK ) {
          rb_raise(rb_eRuntimeError,
                   "#{name}_ki: input init failed rc=%d", rc);
        }
        rc = ca_iter_state_init_l2(&st_out, co, CA_SLAB_AXES,
                                   slab_axes, 1, CA_KERNEL_WRITE);
        if ( rc != CA_ITER_OK ) {
          ca_iter_state_finish(&st_in);
          rb_raise(rb_eRuntimeError,
                   "#{name}_ki: output init failed rc=%d", rc);
        }
      #{mask_setup}
        char       *pi, *po;
        boolean8_t *mi, *mo;
        while ( ca_iter_state_next_slab_axes(&st_in,  &pi, &mi) &&
                ca_iter_state_next_slab_axes(&st_out, &po, &mo) ) {
          #{scan_call}
          ca_iter_state_sync_slab(&st_out);
        }
        ca_iter_state_finish(&st_in);
        ca_iter_state_finish(&st_out);
        return vout;
      }
    C
  end

  def self.emit_scan_dispatch(io, k)
    name = k[:name]
    io.puts
    # API harmonisation A.2: scan kernels accept `axis:` kwarg only.
    # Array form is rejected at the caller side (= sparring D-4) because
    # multi-axis scan is semantically ambiguous (flatten-and-cumsum vs
    # 2D prefix sum); users must chain explicitly.  Arity flips from 1
    # (positional Integer axis) to -1 (kwarg dispatcher).
    io.puts "static VALUE"
    io.puts "rb_ca_#{name}_ki (int argc, VALUE *argv, VALUE self)"
    io.puts "{"
    io.puts "  CArray *src;"
    io.puts "  GetCArray(self, src);"
    io.puts "  volatile VALUE ropt = rb_pop_options(&argc, &argv);"
    io.puts "  volatile VALUE raxis = Qnil;"
    io.puts "  rb_scan_options(ropt, \"axis\", &raxis);"
    io.puts "  if ( argc > 0 ) {"
    io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: positional axis is no longer accepted (got %d); use axis: kwarg, e.g. a.#{name}(axis: 0)", argc);]
    io.puts "  }"
    if k[:axis_default] == :flatten
      # Legacy compat: nil/omitted axis: flatten source and scan axis 0.
      # Matches pre-3.0 no-arg cumsum/cumprod/cummax/cummin/cumcount.
      io.puts "  if ( NIL_P(raxis) ) {"
      io.puts %Q[    volatile VALUE vflat = rb_funcall(self, rb_intern("flatten"), 0);]
      io.puts "    CArray *fsrc;"
      io.puts "    GetCArray(vflat, fsrc);"
      io.puts "    switch ( fsrc->data_type ) {"
      k[:source].each do |s|
        si = DTYPES[s]
        io.puts "      case #{si[:ca]}: return #{name}_ki_native_#{s}(vflat, fsrc, 0);"
      end
      case k[:fallback]
      when :wrap_to_f64
        io.puts "      default: {"
        io.puts "        VALUE   vsrc = rb_ca_wrap_readonly(vflat, INT2NUM(CA_FLOAT64));"
        io.puts "        CArray *casted;"
        io.puts "        GetCArray(vsrc, casted);"
        io.puts "        return #{name}_ki_native_f64(vsrc, casted, 0);"
        io.puts "      }"
      when :raise
        io.puts "      default:"
        io.puts %Q[        rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")})", ca_type_name[fsrc->data_type]);]
      end
      io.puts "    }"
      io.puts "  }"
    else
      io.puts "  if ( NIL_P(raxis) ) {"
      io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: axis: kwarg is required (single axis Integer; multi-axis scan is semantically ambiguous)");]
      io.puts "  }"
    end
    io.puts "  if ( TYPE(raxis) == T_ARRAY ) {"
    io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: axis: must be Integer (got Array); multi-axis scan is semantically ambiguous, chain explicitly: a.#{name}(axis: 0).#{name}(axis: 1)");]
    io.puts "  }"
    io.puts "  if ( ! rb_obj_is_kind_of(raxis, rb_cInteger) ) {"
    io.puts %Q[    rb_raise(rb_eTypeError, "#{name}_ki: axis: must be Integer (got %"PRIsVALUE")", rb_obj_class(raxis));]
    io.puts "  }"
    io.puts "  int axis = NUM2INT(raxis);"
    io.puts "  if ( axis < 0 ) axis += src->ndim;"
    io.puts "  if ( axis < 0 || axis >= src->ndim ) {"
    io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: axis %d out of range for ndim %d", NUM2INT(raxis), src->ndim);]
    io.puts "  }"
    io.puts "  switch ( src->data_type ) {"
    k[:source].each do |s|
      si = DTYPES[s]
      io.puts "    case #{si[:ca]}: return #{name}_ki_native_#{s}(self, src, axis);"
    end
    case k[:fallback]
    when :wrap_to_f64
      io.puts "    default: {"
      io.puts "      VALUE   vsrc = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));"
      io.puts "      CArray *casted;"
      io.puts "      GetCArray(vsrc, casted);"
      io.puts "      return #{name}_ki_native_f64(vsrc, casted, axis);"
      io.puts "    }"
    when :raise
      io.puts "    default:"
      io.puts %Q[      rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")})", ca_type_name[src->data_type]);]
    end
    io.puts "  }"
    io.puts "  return Qnil;  /* unreachable */"
    io.puts "}"
  end

  # ---- sort emitter -----------------------------------------------------

  def self.emit_sort(io, k)
    io.puts
    io.puts "/* ===== #{k[:name]}_ki ============================================ */"
    k[:source].each do |src|
      emit_sort_cmp(io, k, src)
      emit_sort_quickselect(io, k, src) if k[:algorithm] == :partition
      emit_sort_native(io, k, src)
    end
    emit_sort_dispatch(io, k)
  end

  # SO.3+ (rev8): per-(kernel, data_type) quickselect on the (value, idx) pair
  # array.  After return: arr[kth] is the kth-smallest by cmp; arr[lo..kth-1]
  # all compare <= arr[kth]; arr[kth+1..hi] all compare >= arr[kth].
  # Median-of-three pivot; small-range insertion sort (n < 8); Hoare
  # partition; recursive only into the side containing kth.
  # Average O(n); worst-case O(n^2) (rare with median-of-three).
  # Stability WITHIN the < and > regions is NOT preserved -- only the
  # kth position is exact.
  def self.emit_sort_quickselect(io, k, src)
    name = k[:name]
    io.puts
    io.puts "/* Quickselect on (value, idx) pair array.  See emit_sort_quickselect"
    io.puts "   in mkkernel.rb for the contract. */"
    io.puts "static void"
    io.puts "#{name}_quickselect_#{src} (#{name}_pair_#{src} *arr,"
    io.puts "                                       ca_size_t lo, ca_size_t hi,"
    io.puts "                                       ca_size_t kth)"
    io.puts "{"
    io.puts "  while ( lo < hi ) {"
    io.puts "    /* Small-range base case: insertion sort. */"
    io.puts "    if ( hi - lo < 8 ) {"
    io.puts "      for ( ca_size_t i = lo + 1; i <= hi; i++ ) {"
    io.puts "        #{name}_pair_#{src} v = arr[i];"
    io.puts "        ca_size_t j = i;"
    io.puts "        while ( j > lo && #{name}_cmp_#{src}(&v, &arr[j-1]) < 0 ) {"
    io.puts "          arr[j] = arr[j-1]; j--;"
    io.puts "        }"
    io.puts "        arr[j] = v;"
    io.puts "      }"
    io.puts "      return;"
    io.puts "    }"
    io.puts "    /* Median-of-three pivot: order arr[lo], arr[mid], arr[hi]. */"
    io.puts "    ca_size_t mid = lo + (hi - lo) / 2;"
    io.puts "    if ( #{name}_cmp_#{src}(&arr[mid], &arr[lo]) < 0 ) {"
    io.puts "      #{name}_pair_#{src} t = arr[mid]; arr[mid] = arr[lo]; arr[lo] = t;"
    io.puts "    }"
    io.puts "    if ( #{name}_cmp_#{src}(&arr[hi],  &arr[lo]) < 0 ) {"
    io.puts "      #{name}_pair_#{src} t = arr[hi];  arr[hi]  = arr[lo]; arr[lo] = t;"
    io.puts "    }"
    io.puts "    if ( #{name}_cmp_#{src}(&arr[hi],  &arr[mid]) < 0 ) {"
    io.puts "      #{name}_pair_#{src} t = arr[hi];  arr[hi]  = arr[mid]; arr[mid] = t;"
    io.puts "    }"
    io.puts "    /* Stash pivot at hi-1 (Hoare partition variant). */"
    io.puts "    {"
    io.puts "      #{name}_pair_#{src} t = arr[mid]; arr[mid] = arr[hi-1]; arr[hi-1] = t;"
    io.puts "    }"
    io.puts "    #{name}_pair_#{src} pivot = arr[hi-1];"
    io.puts "    /* Hoare partition (pivot at hi-1; scan lo..hi-2). */"
    io.puts "    ca_size_t i = lo, j = hi - 1;"
    io.puts "    for (;;) {"
    io.puts "      while ( #{name}_cmp_#{src}(&arr[++i], &pivot) < 0 );"
    io.puts "      while ( #{name}_cmp_#{src}(&arr[--j], &pivot) > 0 );"
    io.puts "      if ( i >= j ) break;"
    io.puts "      #{name}_pair_#{src} t = arr[i]; arr[i] = arr[j]; arr[j] = t;"
    io.puts "    }"
    io.puts "    /* Restore pivot to its final position. */"
    io.puts "    {"
    io.puts "      #{name}_pair_#{src} t = arr[i]; arr[i] = arr[hi-1]; arr[hi-1] = t;"
    io.puts "    }"
    io.puts "    /* Now arr[lo..i-1] <= pivot, arr[i] == pivot, arr[i+1..hi] >= pivot. */"
    io.puts "    if ( kth == i ) return;"
    io.puts "    else if ( kth < i ) hi = i - 1;"
    io.puts "    else lo = i + 1;"
    io.puts "  }"
    io.puts "}"
  end

  # Emit per-(kernel, data_type) cmp helper + (value, idx) struct at file scope.
  # Used by qsort()/mergesort() which require file-scope cmp function pointers.
  # Stability is guaranteed by tie-breaking on the original fiber-local idx.
  def self.emit_sort_cmp(io, k, src)
    si        = DTYPES[src]
    is_fp     = %i[f32 f64].include?(src)
    is_object = (src == :object)
    is_fixlen = (src == :fixlen)
    name      = k[:name]
    if is_fixlen
      # CA_FIXLEN: the cell is a runtime-width byte blob, so the pair holds
      # a pointer to the cell plus its byte width (no scalar `v` slot).
      # Ordering is memcmp lexicographic -- the same total order the fixlen
      # bincmp operators (`<` / `>`) already use.  qsort-routed (like the
      # :object path); stability comes from the index tie-break below.
      io.puts
      io.puts "typedef struct {"
      io.puts "  char     *vp;   /* pointer to the fiber cell (nb bytes wide) */"
      io.puts "  ca_size_t nb;   /* element byte width (= ca->bytes) */"
      io.puts "  ca_size_t i;    /* original fiber-local index (tie-break) */"
      io.puts "} #{name}_pair_#{src};"
      io.puts
      io.puts "static int"
      io.puts "#{name}_cmp_#{src} (const void *a, const void *b)"
      io.puts "{"
      io.puts "  const #{name}_pair_#{src} *pa = (const #{name}_pair_#{src} *) a;"
      io.puts "  const #{name}_pair_#{src} *pb = (const #{name}_pair_#{src} *) b;"
      io.puts "  int c = memcmp(pa->vp, pb->vp, (size_t) pa->nb);"
      io.puts "  if ( c != 0 ) return c;"
      io.puts "  /* Stable tie-break by original fiber-local index. */"
      io.puts "  if ( pa->i < pb->i ) return -1;"
      io.puts "  if ( pa->i > pb->i ) return 1;"
      io.puts "  return 0;"
      io.puts "}"
      return
    end
    io.puts
    io.puts "typedef struct {"
    io.puts "  #{si[:c]} v;"
    io.puts "  ca_size_t i;"
    io.puts "} #{name}_pair_#{src};"
    # The cmp function is referenced only by (a) the :partition quickselect
    # (every src) and (b) the object full-sort qsort route.  Numeric full-sort
    # uses the typed ca_sort_quick_pair / ca_sort_merge_pair helpers, not this
    # comparator, so emitting it for a non-partition numeric kernel is dead
    # code (-Wunused-function).  The pair struct above is still needed (numeric
    # buffer allocation), so skip only the function.
    return if !is_object && k[:algorithm] != :partition
    io.puts
    io.puts "static int"
    io.puts "#{name}_cmp_#{src} (const void *a, const void *b)"
    io.puts "{"
    io.puts "  const #{name}_pair_#{src} *pa = (const #{name}_pair_#{src} *) a;"
    io.puts "  const #{name}_pair_#{src} *pb = (const #{name}_pair_#{src} *) b;"
    if is_object
      # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 2: CA_OBJECT cmp via
      # Ruby Comparable (= `<=>`).  Any Comparable element type (Numeric,
      # String, custom class with <=> defined) works.  Raises Ruby
      # TypeError mid-sort if a cell pair is uncomparable -- consistent
      # with Array#sort behavior.
      io.puts %Q{  VALUE r = rb_funcall(pa->v, rb_intern("<=>"), 1, pb->v);}
      io.puts "  if ( NIL_P(r) ) {"
      io.puts %Q{    rb_raise(rb_eArgError, "#{name}_ki: comparison of %s with %s failed",}
      io.puts "             rb_obj_classname(pa->v), rb_obj_classname(pb->v));"
      io.puts "  }"
      io.puts "  int c = NUM2INT(r);"
      io.puts "  if ( c > 0 ) return 1;"
      io.puts "  if ( c < 0 ) return -1;"
    else
      if is_fp
        # NaN policy :end -- NaN sorts to the end (matches qcmp_f_type in
        # carray_sort.c).
        io.puts "  int nan_a = isnan(pa->v);"
        io.puts "  int nan_b = isnan(pb->v);"
        io.puts "  if ( nan_a && !nan_b ) return 1;"
        io.puts "  if ( nan_b && !nan_a ) return -1;"
      end
      io.puts "  if ( pa->v > pb->v ) return 1;"
      io.puts "  if ( pa->v < pb->v ) return -1;"
    end
    io.puts "  /* Stable tie-break by original fiber-local index. */"
    io.puts "  if ( pa->i < pb->i ) return -1;"
    io.puts "  if ( pa->i > pb->i ) return 1;"
    io.puts "  return 0;"
    io.puts "}"
  end

  # Emit one pair-load statement: buf[dst].v (or .vp/.nb for CA_FIXLEN) =
  # the fiber cell read at source position `kexpr` (does NOT set .i --
  # callers set the index/addr payload separately, since it differs
  # between :fiber_local and :view_flat semantics).  Shared by the plain
  # load loop and the mask_self: :sentinel split-load loops in
  # emit_sort_native.
  def self.emit_sort_pair_load(io, is_fixlen, si, dst, kexpr)
    if is_fixlen
      io.puts "          buf[#{dst}].vp = pi + #{kexpr} * istride; buf[#{dst}].nb = (ca_size_t) ca->bytes;"
    else
      io.puts "          buf[#{dst}].v = *(#{si[:c]} *) (pi + #{kexpr} * istride);"
    end
  end

  # Emit the mask_self: :sentinel split-load: for the current fiber,
  # compact unmasked cells into one contiguous sub-range of `buf` and
  # masked cells into the complementary sub-range, at the head
  # (masked_last false) or tail (masked_last true) per the runtime
  # `masked_last` parameter.  Sets `sort_lo` / `sort_n` to the unmasked
  # sub-range so the downstream sort/quickselect call only ever compares
  # unmasked pairs -- masked cells are an incomparable sentinel, the same
  # role NaN plays for nan_policy: :end, but dtype-agnostic and runtime-
  # selectable.  `payload_expr(k)` computes the `.i` payload (fiber-local
  # index for :fiber_local semantics, view-flat address for :view_flat)
  # given the Ruby string `k` naming the C loop variable.
  def self.emit_sort_mask_split_load(io, is_fixlen, si, payload_expr)
    io.puts "    ca_size_t sort_lo, sort_n;"
    io.puts "    if ( mi ) {"
    io.puts "      ca_size_t mstride = st_in.slab_mask_strides[0];"
    io.puts "      ca_size_t n_valid = 0, n_masked = 0;"
    io.puts "      if ( masked_last ) {"
    io.puts "        for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
    io.puts "          if ( mi[k * mstride] ) continue;"
    emit_sort_pair_load(io, is_fixlen, si, "n_valid", "k")
    io.puts "          buf[n_valid].i = #{payload_expr.call("k")};"
    io.puts "          n_valid++;"
    io.puts "        }"
    io.puts "        for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
    io.puts "          if ( ! mi[k * mstride] ) continue;"
    emit_sort_pair_load(io, is_fixlen, si, "n_valid + n_masked", "k")
    io.puts "          buf[n_valid + n_masked].i = #{payload_expr.call("k")};"
    io.puts "          n_masked++;"
    io.puts "        }"
    io.puts "        sort_lo = 0; sort_n = n_valid;"
    io.puts "      } else {"
    io.puts "        for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
    io.puts "          if ( ! mi[k * mstride] ) continue;"
    emit_sort_pair_load(io, is_fixlen, si, "n_masked", "k")
    io.puts "          buf[n_masked].i = #{payload_expr.call("k")};"
    io.puts "          n_masked++;"
    io.puts "        }"
    io.puts "        for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
    io.puts "          if ( mi[k * mstride] ) continue;"
    emit_sort_pair_load(io, is_fixlen, si, "n_masked + n_valid", "k")
    io.puts "          buf[n_masked + n_valid].i = #{payload_expr.call("k")};"
    io.puts "          n_valid++;"
    io.puts "        }"
    io.puts "        sort_lo = n_masked; sort_n = n_valid;"
    io.puts "      }"
    io.puts "    } else {"
    io.puts "      for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
    emit_sort_pair_load(io, is_fixlen, si, "k", "k")
    io.puts "        buf[k].i = #{payload_expr.call("k")};"
    io.puts "      }"
    io.puts "      sort_lo = 0; sort_n = fiber_n;"
    io.puts "    }"
  end

  def self.emit_sort_native(io, k, src)
    si        = DTYPES[src]
    oi        = output_info(k, src)
    name      = k[:name]
    is_fixlen = (src == :fixlen)
    view_flat = (k[:semantics] == :view_flat)
    partition = (k[:algorithm] == :partition)
    rank      = (k[:algorithm] == :rank)
    mask_skip = (k[:mask_self] == :skip)
    mask_sentinel = (k[:mask_self] == :sentinel)
    # PROPOSAL_PORTABLE_TEXTBOOK_SORT §9.5.2 Option γ: :full and :rank
    # algorithms accept `do_stable` parameter (= 0 for quicksort, 1 for
    # bottom-up mergesort).  :partition has no kind concept (partial sort).
    has_kind  = (k[:algorithm] != :partition)
    extra     = partition ? ", ca_size_t kth" : (has_kind ? ", int do_stable" : "")
    extra    += ", int masked_last" if mask_sentinel
    extra    += ", int dense" if rank
    io.puts
    io.puts "static VALUE"
    io.puts "#{name}_ki_native_#{src} (VALUE self, CArray *ca, int axis#{extra})"
    io.puts "{"
    io.puts "  VALUE   vout = rb_ca_template_with_type(self, INT2NUM(#{oi[:ca]}),"
    io.puts "                                          INT2NUM(0));"
    io.puts "  CArray *co;"
    io.puts "  GetCArray(vout, co);"
    io.puts
    io.puts "  /* 1-axis per-fiber sort: slab = the sort axis only.  Both"
    io.puts "     input and output share the same slab_axes so per-fiber"
    io.puts "     positions align between iterators. */"
    io.puts "  int8_t slab_axes[CA_RANK_MAX];"
    io.puts "  slab_axes[0] = (int8_t) axis;"
    if rank && mask_skip
      io.puts "  /* :rank + mask_self: :skip: create output mask BEFORE iter"
      io.puts "     init so st_out captures the mask buffer (mo retrieved by"
      io.puts "     next_slab_axes will then be non-NULL).  Created up-front"
      io.puts "     when input has any mask. */"
      io.puts "  if ( ca_has_mask(ca) ) ca_create_mask(co);"
    end
    io.puts "  ca_iter_state st_in, st_out;"
    io.puts "  int rc;"
    io.puts "  rc = ca_iter_state_init_l2(&st_in,  ca, CA_SLAB_AXES,"
    io.puts "                             slab_axes, 1, 0);"
    io.puts "  if ( rc != CA_ITER_OK ) {"
    io.puts %Q[    rb_raise(rb_eRuntimeError, "#{name}_ki: input init failed rc=%d", rc);]
    io.puts "  }"
    io.puts "  rc = ca_iter_state_init_l2(&st_out, co, CA_SLAB_AXES,"
    io.puts "                             slab_axes, 1, CA_KERNEL_WRITE);"
    io.puts "  if ( rc != CA_ITER_OK ) {"
    io.puts "    ca_iter_state_finish(&st_in);"
    io.puts %Q[    rb_raise(rb_eRuntimeError, "#{name}_ki: output init failed rc=%d", rc);]
    io.puts "  }"
    io.puts
    io.puts "  ca_size_t fiber_n = st_in.slab_elements;"
    io.puts "  #{name}_pair_#{src} *buf ="
    io.puts "    xmalloc(sizeof(#{name}_pair_#{src}) * (size_t) fiber_n);"
    if has_kind
      # PROPOSAL_PORTABLE_TEXTBOOK_SORT §9.5.2 Option γ: aux pair buffer
      # for ca_sort_merge_pair_<src> (= ping-pong bottom-up mergesort).
      # Allocated once outside the fiber loop, reused across fibers.
      io.puts "  #{name}_pair_#{src} *aux = NULL;"
      io.puts "  if ( do_stable ) {"
      io.puts "    aux = xmalloc(sizeof(#{name}_pair_#{src}) * (size_t) fiber_n);"
      io.puts "  }"
    end

    if view_flat
      io.puts
      io.puts "  /* :view_flat semantics: kernel computes view-flat address"
      io.puts "     (= row-major position in ca's shape, 0..elements-1) for"
      io.puts "     each cell.  Used to feed CARemap.idx directly (= sort"
      io.puts "     method's view-by-default path). */"
      io.puts "  /* Row-major view-flat stride table (in cells): "
      io.puts "       vstride[m] = Π_{m' > m} ca->dim[m']                    */"
      io.puts "  ca_size_t vstride[CA_RANK_MAX];"
      io.puts "  {"
      io.puts "    ca_size_t s = 1;"
      io.puts "    for ( int8_t m = ca->ndim - 1; m >= 0; m-- ) {"
      io.puts "      vstride[m] = s;"
      io.puts "      s *= ca->dim[m];"
      io.puts "    }"
      io.puts "  }"
      io.puts "  ca_size_t axis_vstride = vstride[axis];"
      io.puts "  /* Kernel-local outer index counter.  Required because"
      io.puts "     ca_iter_state.outer_idx advances PAST the current slab"
      io.puts "     before next_slab_axes returns (= post-increment), so we"
      io.puts "     can't read the current slab's outer position from it. */"
      io.puts "  ca_size_t cur_outer_idx[CA_RANK_MAX];"
      io.puts "  for ( int8_t m = 0; m < st_in.outer_ndim; m++ ) cur_outer_idx[m] = 0;"
    end

    io.puts
    io.puts "  char       *pi, *po;"
    io.puts "  boolean8_t *mi, *mo;"
    io.puts "  while ( ca_iter_state_next_slab_axes(&st_in,  &pi, &mi) &&"
    io.puts "          ca_iter_state_next_slab_axes(&st_out, &po, &mo) ) {"
    io.puts "    ca_size_t istride = st_in.slab_strides[0];"
    io.puts "    ca_size_t ostride = st_out.slab_strides[0];"

    if view_flat
      io.puts "    /* Compute current slab's outer offset in view-flat space. */"
      io.puts "    ca_size_t outer_off = 0;"
      io.puts "    for ( int8_t m = 0; m < st_in.outer_ndim; m++ ) {"
      io.puts "      outer_off += cur_outer_idx[m] * vstride[st_in.outer_axes[m]];"
      io.puts "    }"
      payload = ->(kexpr) { "outer_off + #{kexpr} * axis_vstride" }
      if mask_sentinel
        io.puts "    /* Load fiber values + view-flat addresses, split by mask"
        io.puts "       (masked_position policy) -- see emit_sort_mask_split_load"
        io.puts "       in mkkernel.rb. */"
        emit_sort_mask_split_load(io, is_fixlen, si, payload)
      else
        io.puts "    /* Load fiber values + view-flat addresses. */"
        io.puts "    for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
        if is_fixlen
          io.puts "      buf[k].vp = pi + k * istride; buf[k].nb = (ca_size_t) ca->bytes;"
        else
          io.puts "      buf[k].v = *(#{si[:c]} *) (pi + k * istride);"
        end
        io.puts "      buf[k].i = #{payload.call("k")};"
        io.puts "    }"
      end
    elsif rank && mask_skip
      io.puts "    /* Load only UNMASKED (value, axis-local-position) pairs; */"
      io.puts "    /* masked positions are tracked via mi and handled at write time. */"
      io.puts "    ca_size_t mstride = st_in.slab_mask_strides[0];"
      io.puts "    ca_size_t k_unmasked = 0;"
      io.puts "    for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
      io.puts "      if ( mi && mi[k * mstride] ) continue;"
      if is_fixlen
        io.puts "      buf[k_unmasked].vp = pi + k * istride; buf[k_unmasked].nb = (ca_size_t) ca->bytes;"
      else
        io.puts "      buf[k_unmasked].v = *(#{si[:c]} *) (pi + k * istride);"
      end
      io.puts "      buf[k_unmasked].i = k;"
      io.puts "      k_unmasked++;"
      io.puts "    }"
    elsif mask_sentinel
      io.puts "    /* Load fiber values + fiber-local indices, split by mask"
      io.puts "       (masked_position policy) -- see emit_sort_mask_split_load"
      io.puts "       in mkkernel.rb. */"
      emit_sort_mask_split_load(io, is_fixlen, si, ->(kexpr) { kexpr })
    else
      io.puts "    /* Load fiber values + fiber-local indices. */"
      io.puts "    for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
      if is_fixlen
        io.puts "      buf[k].vp = pi + k * istride; buf[k].nb = (ca_size_t) ca->bytes;"
      else
        io.puts "      buf[k].v = *(#{si[:c]} *) (pi + k * istride);"
      end
      io.puts "      buf[k].i = k;"
      io.puts "    }"
    end

    if partition
      io.puts "    /* Quickselect at fiber-local kth -- only that position is"
      io.puts "       guaranteed; order within < and > regions is unspecified. */"
      if mask_sentinel
        io.puts "    /* kth indexes the full [0, fiber_n) arrangement, and the"
        io.puts "       mask split above already placed the masked block at"
        io.puts "       the configured end -- so a kth landing in the masked"
        io.puts "       block needs no selection (order within it is"
        io.puts "       unspecified, same as the < / > regions below); only a"
        io.puts "       kth landing in [sort_lo, sort_lo+sort_n) selects among"
        io.puts "       unmasked values. */"
        io.puts "    if ( kth >= sort_lo && kth < sort_lo + sort_n && sort_n > 1 ) {"
        io.puts "      #{name}_quickselect_#{src}(buf, sort_lo, sort_lo + sort_n - 1, kth);"
        io.puts "    }"
      else
        io.puts "    if ( fiber_n > 1 ) {"
        io.puts "      #{name}_quickselect_#{src}(buf, 0, fiber_n - 1, kth);"
        io.puts "    }"
      end
    else
      sort_n_expr = if mask_sentinel
                      "sort_n"
                    elsif rank && mask_skip
                      "k_unmasked"
                    else
                      "fiber_n"
                    end
      buf_expr     = mask_sentinel ? "(buf + sort_lo)" : "buf"
      is_fp_kernel = %i[f32 f64].include?(src)
      is_object    = (src == :object)
      # bool storage is a 1-byte 0/1, layout-identical to uint8; route the
      # shared ca_pair_/ca_sort_*_pair_ helpers through u8 (the per-kernel
      # #{name}_pair_bool buffer keeps boolean8_t v and casts cleanly).
      pair_src     = (src == :bool) ? :u8 : src
      io.puts "    /* P.4 / §9.5.2 Option γ: portable textbook pair quick or merge"
      io.puts "       sort.  Both forms use the (value, fiber-local index) pair"
      io.puts "       layout (= ca_pair_#{src}) with index tie-break, so both are"
      io.puts "       algorithmically stable; do_stable: 1 selects bottom-up"
      io.puts "       mergesort (= aux ping-pong, sorted-skip merge), do_stable: 0"
      io.puts "       selects introsort with mergesort escape (= AC1 1.88x payoff)."
      if mask_sentinel
        io.puts "       Only the unmasked sub-range [sort_lo, sort_lo+sort_n) is"
        io.puts "       sorted -- see emit_sort_mask_split_load in mkkernel.rb. */"
      else
        io.puts "     */"
      end
      if is_object
        # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 2: CA_OBJECT routes to
        # libc qsort with the emitted _cmp_object (rb_funcall(<=>) based).
        # qsort isn't stable, but our cmp tie-breaks on the original index,
        # so the result is effectively stable.  do_stable is ignored: both
        # paths use the same qsort + cmp here.  NaN partition is skipped
        # (Ruby Float NaN handling deferred -- cells of type Float with NaN
        # would compare via Float#<=> which returns nil for NaN, raising
        # ArgumentError in the cmp helper).
        io.puts "    (void) do_stable;   /* CA_OBJECT: qsort handles both stable / quick */"
        io.puts "    qsort(#{buf_expr}, (size_t) #{sort_n_expr}, sizeof(#{name}_pair_#{src}), #{name}_cmp_#{src});"
      elsif is_fixlen
        io.puts "    /* CA_FIXLEN: libc qsort with the memcmp comparator.  qsort isn't"
        io.puts "       stable, but #{name}_cmp_#{src} tie-breaks on the original index,"
        io.puts "       so the result is effectively stable.  do_stable ignored (same"
        io.puts "       as the CA_OBJECT path -- no typed pair quick/merge helper). */"
        io.puts "    (void) do_stable;"
        io.puts "    qsort(#{buf_expr}, (size_t) #{sort_n_expr}, sizeof(#{name}_pair_#{src}), #{name}_cmp_#{src});"
      elsif is_fp_kernel
        io.puts "    /* P.3/P.4: NaN pre-partition for float argsort -- NaN pairs are"
        io.puts "       pushed to the tail (= NaN-at-end policy, matches sort_copy"
        io.puts "       AC8).  Only the finite slice is sorted. */"
        io.puts "    ca_size_t finite_n = ca_partition_nan_pair_#{src}((ca_pair_#{src} *) #{buf_expr}, (ca_size_t) #{sort_n_expr});"
        io.puts "    if ( do_stable ) {"
        io.puts "      ca_sort_merge_pair_#{src}((ca_pair_#{src} *) #{buf_expr}, (ca_pair_#{src} *) aux, finite_n);"
        io.puts "    } else {"
        io.puts "      ca_sort_quick_pair_#{src}((ca_pair_#{src} *) #{buf_expr}, finite_n);"
        io.puts "    }"
      else
        io.puts "    if ( do_stable ) {"
        io.puts "      ca_sort_merge_pair_#{pair_src}((ca_pair_#{pair_src} *) #{buf_expr}, (ca_pair_#{pair_src} *) aux, (ca_size_t) #{sort_n_expr});"
        io.puts "    } else {"
        io.puts "      ca_sort_quick_pair_#{pair_src}((ca_pair_#{pair_src} *) #{buf_expr}, (ca_size_t) #{sort_n_expr});"
        io.puts "    }"
      end
    end

    if rank
      rank_n = mask_skip ? "k_unmasked" : "fiber_n"
      io.puts "    /* Pre-clear output fiber to 0 (= sentinel at masked positions). */"
      io.puts "    for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
      io.puts "      *(#{oi[:c]} *) (po + k * ostride) = (#{oi[:c]}) 0;"
      io.puts "    }"
      io.puts "    /* Scatter ranks: output[buf[r].i] = out_r for sorted position r."
      io.puts "       ordinal (dense: 0): out_r == r, every cell gets a distinct rank."
      io.puts "       dense (dense: 1): out_r only advances when the value changes from"
      io.puts "       the previous sorted cell, so tied values share one rank -- the"
      io.puts "       gaps ordinal would have spent on the tie are never used, so a"
      io.puts "       later out_r stays <= the ordinal r at that position, preserving"
      io.puts "       both the ascending order and (via the order() method's"
      io.puts "       (n-1)-out_r descending transform) the descending order.  NaN"
      io.puts "       cells never tie with each other under dense (IEEE754 x != x). */"
      io.puts "    ca_size_t out_r = 0;"
      io.puts "    for ( ca_size_t r = 0; r < #{rank_n}; r++ ) {"
      io.puts "      if ( r > 0 ) {"
      io.puts "        if ( dense ) {"
      if is_object
        io.puts "          if ( ! rb_equal(buf[r].v, buf[r - 1].v) ) out_r++;"
      elsif is_fixlen
        io.puts "          if ( memcmp(buf[r].vp, buf[r - 1].vp, (size_t) buf[r].nb) != 0 ) out_r++;"
      else
        io.puts "          if ( buf[r].v != buf[r - 1].v ) out_r++;"
      end
      io.puts "        } else {"
      io.puts "          out_r = r;"
      io.puts "        }"
      io.puts "      }"
      io.puts "      *(#{oi[:c]} *) (po + buf[r].i * ostride) = (#{oi[:c]}) out_r;"
      io.puts "    }"
      if mask_skip
        io.puts "    /* Mirror input mask to output (= UNDEF rank for masked"
        io.puts "       cells).  Write via co->mask->ptr directly with the"
        io.puts "       output slab offset, because the iter's mo isn't"
        io.puts "       populated in CA_KERNEL_WRITE mode (= reduce form's"
        io.puts "       op_mask pattern). */"
        io.puts "    if ( mi && co->mask ) {"
        io.puts "      boolean8_t *omask_base = (boolean8_t *) co->mask->ptr"
        io.puts "                              + ((po - (char *) co->ptr) / (ca_size_t) co->bytes);"
        io.puts "      ca_size_t mostride = st_out.slab_mask_strides[0];"
        io.puts "      for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
        io.puts "        if ( mi[k * mstride] ) omask_base[k * mostride] = 1;"
        io.puts "      }"
        io.puts "    }"
      end
    else
      sort_or_part = partition ? "partitioned" : "sorted"
      payload_desc = view_flat ? "view-flat addresses" : "fiber-local indices"
      io.puts "    /* Write #{sort_or_part} #{payload_desc} to output fiber. */"
      io.puts "    for ( ca_size_t k = 0; k < fiber_n; k++ ) {"
      io.puts "      *(#{oi[:c]} *) (po + k * ostride) = (#{oi[:c]}) buf[k].i;"
      io.puts "    }"
    end
    io.puts "    ca_iter_state_sync_slab(&st_out);"

    if view_flat
      io.puts "    /* Advance kernel-local outer index, row-major (last axis ticks fastest). */"
      io.puts "    for ( int8_t m = st_in.outer_ndim - 1; m >= 0; m-- ) {"
      io.puts "      if ( ++cur_outer_idx[m] < st_in.outer_dims[m] ) break;"
      io.puts "      cur_outer_idx[m] = 0;"
      io.puts "    }"
    end

    io.puts "  }"
    io.puts "  xfree(buf);"
    if has_kind
      io.puts "  if ( aux ) xfree(aux);"
    end
    io.puts "  ca_iter_state_finish(&st_in);"
    io.puts "  ca_iter_state_finish(&st_out);"
    io.puts "  return vout;"
    io.puts "}"
  end

  # Shared sort-family Face gate.  Descends a Face to its storage: a fixlen
  # storage sorts by memcmp (the default order for fixlen, the same as a plain
  # fixlen array -- a struct/record Face gets a deterministic byte order, and
  # opts into a semantic order separately); a numeric storage requires
  # ORDERABLE so the numeric order equals the surface order, else it raises.
  # `src`/`self` are rebound to the stripped storage.
  def self.emit_sort_face_gate(io, name)
    io.puts "  if ( ca_is_face(src) ) {"
    io.puts "    VALUE _face = self;"
    io.puts "    int _orderable = ca_test_flag(src, CA_FLAG_FACE_ORDERABLE_STORAGE);"
    io.puts "    VALUE _st = rb_ca_strip_face_value(self);"
    io.puts "    CArray *_sc;"
    io.puts "    GetCArray(_st, _sc);"
    io.puts "    if ( _sc->data_type != CA_FIXLEN && ! _orderable ) {"
    io.puts %Q[      rb_raise(rb_eArgError,]
    io.puts %Q[               "#{name}_ki: Face-typed input (%s) is not orderable "]
    io.puts %Q[               "by storage; use ca.parent to descend to storage",]
    io.puts %Q[               rb_obj_classname(_face));]
    io.puts "    }"
    io.puts "    self = _st;"
    io.puts "    src = _sc;"
    io.puts "  }"
  end

  # Reduce-family Face gate.  Same ORDERABLE-descent policy as
  # emit_sort_face_gate (fixlen storage -> memcmp default; numeric storage
  # -> ORDERABLE required, else raise), rebinding self/src to storage.  When
  # `relift` is set (value-returning kernels), the original Face is saved to
  # the function-scope `_reduce_face` so the dispatcher can re-lift the output.
  def self.emit_reduce_face_gate(io, name, relift)
    if relift
      io.puts "  volatile VALUE _reduce_face = Qnil;   /* original Face, for output re-lift */"
    end
    io.puts "  if ( ca_is_face(src) ) {"
    io.puts "    VALUE _face = self;"
    io.puts "    int _orderable = ca_test_flag(src, CA_FLAG_FACE_ORDERABLE_STORAGE);"
    io.puts "    VALUE _st = rb_ca_strip_face_value(self);"
    io.puts "    CArray *_sc;"
    io.puts "    GetCArray(_st, _sc);"
    io.puts "    if ( _sc->data_type != CA_FIXLEN && ! _orderable ) {"
    io.puts %Q[      rb_raise(rb_eArgError,]
    io.puts %Q[               "#{name}_ki: Face-typed input (%s) is not orderable "]
    io.puts %Q[               "by storage; use ca.parent to descend to storage",]
    io.puts %Q[               rb_obj_classname(_face));]
    io.puts "    }"
    if relift
      io.puts "    _reduce_face = _face;"
    end
    io.puts "    self = _st;"
    io.puts "    src = _sc;"
    io.puts "  }"
  end

  # Re-lift a value-returning reduction result back into the Face captured by
  # emit_reduce_face_gate.  Full-reduction scalar -> storage_to_scalar hook;
  # per-axis CArray -> rb_ca_face_template (carries the subclass tail).
  # All-masked full reductions leave CA_UNDEF untouched.
  def self.emit_reduce_face_relift(io)
    io.puts "  if ( _reduce_face != Qnil && result != CA_UNDEF && result != Qnil ) {"
    io.puts "    if ( rb_obj_is_kind_of(result, rb_cCArray) ) {"
    io.puts "      /* per-axis: re-lift the storage result as a Face of the same"
    io.puts "         subclass; the template memcpy carries the subclass tail. */"
    io.puts "      CArray *_rca;"
    io.puts "      GetCArray(result, _rca);"
    io.puts "      VALUE _lifted = rb_ca_face_template(_reduce_face, _rca, _rca->dim);"
    io.puts "      rb_ca_set_parent(_lifted, result);  /* pin storage result as GC root */"
    io.puts "      if ( ca_has_mask(_rca) ) {"
    io.puts "        /* rb_ca_face_template resets mask to NULL; carry the reduced"
    io.puts "           mask bits (all-masked slabs) onto the lifted Face. */"
    io.puts "        CArray *_lca;"
    io.puts "        GetCArray(_lifted, _lca);"
    io.puts "        ca_copy_mask(_lca, _rca);"
    io.puts "      }"
    io.puts "      result = _lifted;"
    io.puts "    }"
    io.puts "    else {"
    io.puts "      /* full reduction: decode the scalar via the registered hook. */"
    io.puts "      CArray *_fca;"
    io.puts "      GetCArray(_reduce_face, _fca);"
    io.puts "      CA_FACE_STORAGE_TO_SCALAR_IF_FACE(result, _reduce_face, _fca);"
    io.puts "    }"
    io.puts "  }"
  end

  def self.emit_sort_dispatch(io, k)
    name          = k[:name]
    partition     = (k[:algorithm] == :partition)
    rank          = (k[:algorithm] == :rank)
    has_kind      = !partition   # :full and :rank gain kind: dispatch (Option γ)
    mask_sentinel = (k[:mask_self] == :sentinel)
    # bind_ruby: false kernels are consumed by other .c files at the C
    # level (= rb_ca_sorted_view in carray_order.c calls rb_ca_sort_addr_ki).
    # Emit extern linkage so the symbol is reachable across translation
    # units.  bind_ruby: true kernels stay static (only referenced by
    # Init_carray_kernels in this file).
    #
    # c_callable: true is the third state -- the kernel keeps its Ruby
    # binding (bind_ruby semantics intact) AND gets extern linkage so
    # other .c files can call rb_ca_<name>_ki* directly without going
    # through rb_funcall + kwarg hash building.  Used by sort_index /
    # partition_index / rank_index, which are consumed at the C level
    # by carray_order.c (= ordering helpers like nlargest, order).
    storage = (k[:bind_ruby] == false || k[:c_callable]) ? "" : "static "
    # PROPOSAL_PORTABLE_TEXTBOOK_SORT §9.5.2 Option γ:
    #   For algorithm :full / :rank, dispatch emits THREE C-level entries:
    #     rb_ca_<name>_ki_quick  (self, vaxis)  -> do_stable=0
    #     rb_ca_<name>_ki_stable (self, vaxis)  -> do_stable=1
    #     rb_ca_<name>_ki        (self, vaxis)  -> alias of _ki_quick
    #   All arity 2 (C-level); _ki binds to Ruby at arity 1 -- same as
    #   before.  This structurally avoids the distributed signature mismatch
    #   root cause documented in §9.4 (= the P.6.1 crash).
    #
    #   For algorithm :partition (kth, no kind concept): unchanged,
    #     rb_ca_<name>_ki (self, vaxis, vkth).
    #
    # mask_self: :sentinel kernels additionally thread a `masked_last`
    # runtime parameter through the dispatcher (see MASKED_POSITION rev1
    # doc on MkKernel.sort above).  The 2-/3-arg convenience entries
    # (_ki_quick / _ki_stable / _ki) hardcode masked_last=1 (:last) so
    # existing C-level callers (carray_order.c topk / order) keep their
    # arity and now silently accept masked input instead of raising.
    # bind_ruby: false kernels (sort_addr / partition_addr) additionally
    # get `_mp`-suffixed extern twins taking an explicit masked_last, so
    # the cross-file consumers that expose masked_position: to Ruby
    # (carray_sort.c sort/sort_copy, carray_partition.c partition/
    # partition_copy) can pass the user's choice through.
    if has_kind
      # Internal dispatcher with do_stable (+ masked_last / dense)
      # parameter.  Always static (not bound to Ruby, not called from
      # other .c -- cross-file callers go through the _mp / _dense
      # twins below).
      dispatch_extra  = mask_sentinel ? ", int masked_last" : ""
      dispatch_extra += rank ? ", int dense" : ""
      io.puts
      io.puts "static VALUE"
      io.puts "#{name}_ki_dispatch (VALUE self, VALUE vaxis, int do_stable#{dispatch_extra})"
      io.puts "{"
      io.puts "  CArray *src;"
      io.puts "  GetCArray(self, src);"
      io.puts "  /* Face gate: descend to storage (fixlen -> memcmp default,"
      io.puts "     numeric -> ORDERABLE required).  The strip also makes the"
      io.puts "     switch below and every index/addr template output build on"
      io.puts "     the plain storage, not a face-lifted (NULL-ptr) view. */"
      emit_sort_face_gate(io, name)
      if k[:mask_self] == :raise
        io.puts "  /* sort family rejects masked sources globally (R3 / Q3): "
        io.puts "     masked elements would break the ordering invariant. */"
        io.puts "  if ( ca_has_mask(src) ) {"
        io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: masked input not supported (use ca.value or ca.strip_mask(fill))");]
        io.puts "  }"
      end
      io.puts "  int axis = NUM2INT(vaxis);"
      io.puts "  if ( axis < 0 ) axis += src->ndim;"
      io.puts "  if ( axis < 0 || axis >= src->ndim ) {"
      io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: axis %d out of range for ndim %d", NUM2INT(vaxis), src->ndim);]
      io.puts "  }"
      io.puts "  switch ( src->data_type ) {"
      k[:source].each do |s|
        si = DTYPES[s]
        native_extra  = mask_sentinel ? ", masked_last" : ""
        native_extra += rank ? ", dense" : ""
        io.puts "    case #{si[:ca]}: return #{name}_ki_native_#{s}(self, src, axis, do_stable#{native_extra});"
      end
      io.puts "    default:"
      io.puts %Q[      rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")})", ca_type_name[src->data_type]);]
      io.puts "  }"
      io.puts "  return Qnil;  /* unreachable */"
      io.puts "}"

      # Default extra args for the 2-arg convenience entries: masked_last=1
      # (:last) for mask_self: :sentinel kernels, dense=0 (:ordinal) for
      # :rank -- both preserve pre-existing behavior for callers that
      # don't know about the new parameter (mutually exclusive in
      # practice: no kernel is both mask_self: :sentinel and :rank).
      dispatch_call_last  = mask_sentinel ? ", 1" : ""
      dispatch_call_last += rank ? ", 0" : ""

      # _ki_quick: arity 2 (self, vaxis).  Linkage = storage.
      io.puts
      io.puts "#{storage}VALUE"
      io.puts "rb_ca_#{name}_ki_quick (VALUE self, VALUE vaxis)"
      io.puts "{"
      io.puts "  return #{name}_ki_dispatch(self, vaxis, 0#{dispatch_call_last});"
      io.puts "}"

      # _ki_stable: arity 2 (self, vaxis).  Linkage = storage.
      io.puts
      io.puts "#{storage}VALUE"
      io.puts "rb_ca_#{name}_ki_stable (VALUE self, VALUE vaxis)"
      io.puts "{"
      io.puts "  return #{name}_ki_dispatch(self, vaxis, 1#{dispatch_call_last});"
      io.puts "}"

      # _ki: arity 2 alias of _ki_quick (= preserves existing arity-1
      # Ruby binding and existing C extern callers).
      io.puts
      io.puts "#{storage}VALUE"
      io.puts "rb_ca_#{name}_ki (VALUE self, VALUE vaxis)"
      io.puts "{"
      io.puts "  return rb_ca_#{name}_ki_quick(self, vaxis);"
      io.puts "}"

      if mask_sentinel && k[:bind_ruby] == false
        # _mp twins: explicit masked_last, non-Ruby (plain C int, no
        # rb_scan_args), extern linkage for cross-file consumers
        # (carray_sort.c's `sort` / `sort_copy` masked_position: kwarg).
        io.puts
        io.puts "VALUE"
        io.puts "rb_ca_#{name}_ki_quick_mp (VALUE self, VALUE vaxis, int masked_last)"
        io.puts "{"
        io.puts "  return #{name}_ki_dispatch(self, vaxis, 0, masked_last);"
        io.puts "}"

        io.puts
        io.puts "VALUE"
        io.puts "rb_ca_#{name}_ki_stable_mp (VALUE self, VALUE vaxis, int masked_last)"
        io.puts "{"
        io.puts "  return #{name}_ki_dispatch(self, vaxis, 1, masked_last);"
        io.puts "}"
      end

      if rank
        # _quick_dense: explicit dense (0 :ordinal / 1 :dense), extern for
        # carray_order.c's `order` method: kwarg (order is CA_INT64-family
        # sugar over rank_index, defined in a different file, so it needs
        # a non-static entry point the same way the mask_self: :sentinel
        # kernels' _mp twins do).
        io.puts
        io.puts "VALUE"
        io.puts "rb_ca_#{name}_ki_quick_dense (VALUE self, VALUE vaxis, int dense)"
        io.puts "{"
        io.puts "  return #{name}_ki_dispatch(self, vaxis, 0, dense);"
        io.puts "}"
      end
    else
      # :partition path.  Body now lives in a static #{name}_ki_dispatch
      # helper (+ masked_last for mask_self: :sentinel); rb_ca_<name>_ki
      # keeps its original 3-arg signature (masked_last hardcoded 1) so
      # existing callers/arity are unchanged.
      dispatch_extra = mask_sentinel ? ", int masked_last" : ""
      io.puts
      io.puts "static VALUE"
      io.puts "#{name}_ki_dispatch (VALUE self, VALUE vaxis, VALUE vkth#{dispatch_extra})"
      io.puts "{"
      io.puts "  CArray *src;"
      io.puts "  GetCArray(self, src);"
      io.puts "  /* Face gate (partition): same as the sort dispatcher --"
      io.puts "     fixlen -> memcmp default, numeric -> ORDERABLE required. */"
      emit_sort_face_gate(io, name)
      if k[:mask_self] == :raise
        io.puts "  /* sort family rejects masked sources globally (R3 / Q3): "
        io.puts "     masked elements would break the ordering invariant. */"
        io.puts "  if ( ca_has_mask(src) ) {"
        io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: masked input not supported (use ca.value or ca.strip_mask(fill))");]
        io.puts "  }"
      end
      io.puts "  int axis = NUM2INT(vaxis);"
      io.puts "  if ( axis < 0 ) axis += src->ndim;"
      io.puts "  if ( axis < 0 || axis >= src->ndim ) {"
      io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: axis %d out of range for ndim %d", NUM2INT(vaxis), src->ndim);]
      io.puts "  }"
      io.puts "  ca_size_t kth = NUM2SIZE(vkth);"
      io.puts "  ca_size_t axis_n = src->dim[axis];"
      io.puts "  if ( kth < 0 ) kth += axis_n;"
      io.puts "  if ( kth < 0 || kth >= axis_n ) {"
      io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: kth %lld out of range for axis size %lld", (long long) NUM2SIZE(vkth), (long long) axis_n);]
      io.puts "  }"
      io.puts "  switch ( src->data_type ) {"
      k[:source].each do |s|
        si = DTYPES[s]
        native_extra = mask_sentinel ? ", masked_last" : ""
        io.puts "    case #{si[:ca]}: return #{name}_ki_native_#{s}(self, src, axis, kth#{native_extra});"
      end
      io.puts "    default:"
      io.puts %Q[      rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")})", ca_type_name[src->data_type]);]
      io.puts "  }"
      io.puts "  return Qnil;  /* unreachable */"
      io.puts "}"

      io.puts
      io.puts "#{storage}VALUE"
      io.puts "rb_ca_#{name}_ki (VALUE self, VALUE vaxis, VALUE vkth)"
      io.puts "{"
      io.puts "  return #{name}_ki_dispatch(self, vaxis, vkth#{mask_sentinel ? ", 1" : ""});"
      io.puts "}"

      if mask_sentinel && k[:bind_ruby] == false
        # _mp twin: explicit masked_last, extern for carray_partition.c's
        # `partition` / `partition_copy` masked_position: kwarg.
        io.puts
        io.puts "VALUE"
        io.puts "rb_ca_#{name}_ki_mp (VALUE self, VALUE vaxis, VALUE vkth, int masked_last)"
        io.puts "{"
        io.puts "  return #{name}_ki_dispatch(self, vaxis, vkth, masked_last);"
        io.puts "}"
      end
    end

    # Kwarg trampoline (= the surface that replaces the legacy Ruby
    # wrapper).  When public_method: is set, emit a -1-argc
    # entry that parses `axis:` (and `kind:` for has_kind, and
    # `masked_position:` for mask_self: :sentinel, and `method:` for
    # :rank) kwarg with default 0 / :quick / :last / :ordinal and
    # dispatches to the appropriate positional entry.  For :partition
    # algorithm, kth is accepted as a single positional argument
    # before the kwarg.
    if k[:public_method]
      legacy_name = k[:public_method].to_s
      io.puts
      io.puts "static VALUE"
      io.puts "rb_ca_#{name}_kw (int argc, VALUE *argv, VALUE self)"
      io.puts "{"
      io.puts "  volatile VALUE ropt = rb_pop_options(&argc, &argv);"
      io.puts "  volatile VALUE raxis = Qnil;"
      scan_keys = ["axis"]
      scan_keys << "kind" if has_kind
      scan_keys << "masked_position" if mask_sentinel
      scan_keys << "method" if rank
      if has_kind
        io.puts "  volatile VALUE rkind = Qnil;"
      end
      if mask_sentinel
        io.puts "  volatile VALUE rmasked_position = Qnil;"
      end
      if rank
        io.puts "  volatile VALUE rmethod = Qnil;"
      end
      scan_targets = ["&raxis"]
      scan_targets << "&rkind" if has_kind
      scan_targets << "&rmasked_position" if mask_sentinel
      scan_targets << "&rmethod" if rank
      io.puts "  rb_scan_options(ropt, \"#{scan_keys.join(",")}\", #{scan_targets.join(", ")});"
      io.puts "  if ( NIL_P(raxis) ) raxis = INT2NUM(0);   /* default axis */"
      if rank
        # method: :ordinal (default) / :dense -> dense int.  :ordinal
        # assigns every cell a distinct rank (ties broken by original
        # position); :dense assigns tied values the same rank (no gaps),
        # the standard "dense rank" used to compose rank as a sort_addr
        # priority key without silently dropping lower-priority keys on
        # ties (see MASKED_POSITION's sibling proposal thread).
        io.puts "  int dense = 0;   /* default method: :ordinal */"
        io.puts "  if ( ! NIL_P(rmethod) ) {"
        io.puts "    static ID sym_ordinal = 0, sym_dense = 0;"
        io.puts "    if ( ! sym_ordinal ) sym_ordinal = rb_intern(\"ordinal\");"
        io.puts "    if ( ! sym_dense )   sym_dense   = rb_intern(\"dense\");"
        io.puts "    ID method_id = SYM2ID(rmethod);"
        io.puts "    if      ( method_id == sym_ordinal ) dense = 0;"
        io.puts "    else if ( method_id == sym_dense )   dense = 1;"
        io.puts "    else {"
        io.puts %Q[      rb_raise(rb_eArgError, "#{legacy_name}: unknown method %s (expected :ordinal or :dense)", rb_id2name(method_id));]
        io.puts "    }"
        io.puts "  }"
      end
      if mask_sentinel
        # masked_position: :last (default) / :first -> masked_last int.
        # Shared by both the has_kind and :partition branches below.
        io.puts "  int masked_last = 1;   /* default masked_position: :last */"
        io.puts "  if ( ! NIL_P(rmasked_position) ) {"
        io.puts "    static ID sym_first = 0, sym_last = 0;"
        io.puts "    if ( ! sym_first ) sym_first = rb_intern(\"first\");"
        io.puts "    if ( ! sym_last )  sym_last  = rb_intern(\"last\");"
        io.puts "    ID mp_id = SYM2ID(rmasked_position);"
        io.puts "    if      ( mp_id == sym_last )  masked_last = 1;"
        io.puts "    else if ( mp_id == sym_first ) masked_last = 0;"
        io.puts "    else {"
        io.puts %Q[      rb_raise(rb_eArgError, "#{legacy_name}: unknown masked_position %s (expected :first or :last)", rb_id2name(mp_id));]
        io.puts "    }"
        io.puts "  }"
      end
      if partition
        # partition_index(kth, axis: 0, masked_position: :last) -- kth
        # positional, axis/masked_position kwargs.
        io.puts "  if ( argc != 1 ) {"
        io.puts %Q[    rb_raise(rb_eArgError, "#{legacy_name}: wrong number of positional arguments (given %d, expected 1: kth)", argc);]
        io.puts "  }"
        if mask_sentinel
          io.puts "  return #{name}_ki_dispatch(self, raxis, argv[0], masked_last);"
        else
          io.puts "  return rb_ca_#{name}_ki(self, raxis, argv[0]);"
        end
      else
        # sort_index(axis: 0, kind: :quick, masked_position: :last) --
        # no positional, kwargs only.
        io.puts "  if ( argc != 0 ) {"
        io.puts %Q[    rb_raise(rb_eArgError, "#{legacy_name}: positional args no longer accepted (given %d args); use axis:/kind: kwargs", argc);]
        io.puts "  }"
        # kind: dispatch (:quick default, :stable optional).
        io.puts "  int do_stable = 0;"
        io.puts "  if ( ! NIL_P(rkind) ) {"
        io.puts "    static ID sym_quick = 0, sym_stable = 0;"
        io.puts "    if ( ! sym_quick )  sym_quick  = rb_intern(\"quick\");"
        io.puts "    if ( ! sym_stable ) sym_stable = rb_intern(\"stable\");"
        io.puts "    ID kind_id = SYM2ID(rkind);"
        io.puts "    if      ( kind_id == sym_quick )  do_stable = 0;"
        io.puts "    else if ( kind_id == sym_stable ) do_stable = 1;"
        io.puts "    else {"
        io.puts %Q[      rb_raise(rb_eArgError, "#{legacy_name}: unknown kind %s (expected :quick or :stable)", rb_id2name(kind_id));]
        io.puts "    }"
        io.puts "  }"
        if mask_sentinel
          io.puts "  return #{name}_ki_dispatch(self, raxis, do_stable, masked_last);"
        elsif rank
          io.puts "  return #{name}_ki_dispatch(self, raxis, do_stable, dense);"
        else
          io.puts "  return do_stable ? rb_ca_#{name}_ki_stable(self, raxis)"
          io.puts "                   : rb_ca_#{name}_ki_quick(self, raxis);"
        end
      end
      io.puts "}"
    end
  end

  # ---- search emitter (S.1.2a: case A scalar query) --------------------
  #
  # Case A (= scalar val) only at S.1.2a.  Case B (val.shape append to
  # output tail) and Case C (val.shape == base_shape, per-slice query)
  # land at S.1.2b.
  #
  # Generated signature: rb_ca_<name>_ki(VALUE self, VALUE rval, VALUE raxis)
  # bound as `<name>_ki(val, axis)` (2 positional args).
  #
  # Author body bindings (per the kernel author surface, Q1=B sparring):
  #   slab_ptr    char *           per-slab base pointer (slab axis = search axis)
  #   slab_n      ca_size_t        slab length (= ca->dim[axis])
  #   slab_stride ca_size_t        byte stride along slab axis
  #   query_val   T_LOAD           query value (= rval converted to source data_type)
  #   mask_in     boolean8_t *     per-slab mask base (NULL if no mask), see mask_self:
  #   result      ca_size_t        OUTPUT: write match position or no-match sentinel
  #
  # In the body, T_LOAD is textually substituted with the source data_type's
  # C type (= per-data_type native helper).  T_OUT is substituted with the
  # output data_type's C type.
  #
  # Scalar return path (= self.ndim == 1): if result equals no_match,
  # return Qnil; else SIZE2NUM(result).  Array return: result -1 (or the
  # configured no_match sentinel) is written into the output cell as-is.
  # UNDEF/mask propagation for array no-match cells is deferred to S.1.3
  # (= mask creation cost for the case where the demo kernel is wanted
  # mask-free).
  def self.emit_search(io, k)
    io.puts
    io.puts "/* ===== #{k[:name]}_ki ============================================ */"
    k[:source].each do |src|
      emit_search_native(io, k, src)
    end
    emit_search_dispatch(io, k)
  end

  def self.emit_search_native(io, k, src)
    si        = DTYPES[src]
    oi        = output_info(k, src)
    name      = k[:name]
    no_match  = k[:no_match]
    has_eps   = k[:runtime_args].include?(:eps)
    is_float  = float_data_type?(src)
    is_object = (src == :object)
    is_fixlen = (src == :fixlen)
    # eps / distance arithmetic is ill-defined for both CA_OBJECT and
    # CA_FIXLEN (arbitrary objects / byte blobs), so they share the
    # "no eps" branches below.
    no_eps    = is_object || is_fixlen
    eps_def   = eps_default_for(src) unless is_fixlen

    # body: Hash form picks per-data_type-kind branch (= :int / :float /
    # :object / :fixlen); String form is uniform.
    # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 4: :object branch added for
    # CA_OBJECT (equality via rb_equal, ordering via rb_funcall(<=>)).
    # PROPOSAL_SEARCH_SEMANTICS_UNIFY S2: :fixlen branch added for CA_FIXLEN
    # (the cell is a runtime-width byte blob; comparison is memcmp over
    # ca->bytes, the same total order fixlen bincmp uses).
    body_kind = if is_object then :object
                elsif is_fixlen then :fixlen
                elsif is_float then :float
                else :int
                end
    body_src  = k[:body].is_a?(Hash) ? k[:body][body_kind] : k[:body]
    body      = body_src.gsub("T_LOAD", si[:c]).gsub("T_OUT", oi[:c])
    body_indented_8  = body.each_line.map { |l| "        " + l }.join
    body_indented_10 = body.each_line.map { |l| "          " + l }.join

    # Signature: runtime args (= :eps) become extra params.  reps is the
    # Ruby VALUE (Qnil or Float).  query_eps is the resolved double.
    extra_params      = has_eps ? ", VALUE reps" : ""
    extra_passdown    = has_eps ? ", reps" : ""

    # mask_self: :skip exposes mask_in + slab_mask_stride to body; :raise
    # keeps them but adds (void) suppression for unused-var warnings.
    mask_unused_decl = (k[:mask_self] == :skip) ? "" : "          (void) mask_in;\n          (void) slab_mask_stride;  /* mask_self: :raise rejects upstream */"
    mask_unused_decl_bc = (k[:mask_self] == :skip) ? "" : "            (void) mask_in;\n            (void) slab_mask_stride;  /* mask_self: :raise rejects upstream */"

    # eps resolution boilerplate (only emitted when runtime_args includes :eps)
    # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 4: CA_OBJECT has no
    # meaningful eps semantic (= arbitrary Ruby objects, no scalar
    # multiplier on query_val).  When src == :object, eps is silently
    # treated as 0 (= exact equality only) regardless of user-supplied
    # `reps`.  Casting VALUE to double would be a compile error otherwise.
    eps_setup_a = if has_eps && !no_eps
                    <<~C.chomp
                      int eps_is_default = NIL_P(reps);
                      double user_eps    = eps_is_default ? 0.0 : NUM2DBL(reps);
                      double query_eps   = eps_is_default ? (double)(#{eps_def}) * fabs((double)query_val) : user_eps;
                    C
                  elsif has_eps && no_eps
                    "(void) reps;  /* #{is_fixlen ? "CA_FIXLEN" : "CA_OBJECT"}: eps ignored, exact match only */\n          double query_eps = 0.0; (void) query_eps;"
                  else
                    "double query_eps = 0.0; (void) query_eps;  /* unused in this kernel */"
                  end
    eps_setup_bc = if has_eps && !no_eps
                     "int eps_is_default = NIL_P(reps);\n        double user_eps    = eps_is_default ? 0.0 : NUM2DBL(reps);"
                   elsif has_eps && no_eps
                     "(void) reps;  /* #{is_fixlen ? "CA_FIXLEN" : "CA_OBJECT"}: eps ignored */"
                   else
                     ""
                   end
    eps_percell  = if has_eps && !no_eps
                     "double query_eps = eps_is_default ? (double)(#{eps_def}) * fabs((double)query_val) : user_eps;"
                   else
                     "double query_eps = 0.0; (void) query_eps;"
                   end

    view_flat = (k[:semantics] == :view_flat)

    # case A scalar-query setup.  numeric/object: coerce into a native cell.
    # fixlen: the query is a runtime-width byte blob, so allocate ca->bytes
    # and let rb_ca_obj2ptr pack it; `query_val` is then a char* the memcmp
    # body reads (mirrors the legacy flat bsearch ALLOCA_N path).
    query_setup_a = if is_fixlen
                      "char *query_val = ALLOCA_N(char, ca->bytes);\n" \
                      "          rb_ca_obj2ptr(self, rval, query_val);"
                    else
                      "#{si[:c]} query_val_buf;\n" \
                      "          rb_ca_obj2ptr(self, rval, &query_val_buf);\n" \
                      "          #{si[:c]} query_val = query_val_buf;"
                    end

    # case B/C query coercion.  numeric/object: wrap-readonly to self's
    # data_type when they differ.  fixlen: require a CA_FIXLEN query of the
    # same byte width (no scalar coercion exists for blobs), so the per-cell
    # memcmp width (ca->bytes) matches the query stride (cv->bytes).
    coerce_bc = if is_fixlen
                  <<~C.chomp
                    (void) vsrc_val;  /* fixlen: no wrap-readonly coercion */
                            if ( cv->data_type != CA_FIXLEN || cv->bytes != ca->bytes ) {
                              rb_raise(rb_eArgError,
                                       "#{name}_ki: CA_FIXLEN query must be CA_FIXLEN of the same byte width (= %ld)", (long) ca->bytes);
                            }
                  C
                else
                  <<~C.chomp
                    if ( ca->data_type != cv->data_type ) {
                              vsrc_val = rb_ca_wrap_readonly(rval, INT2NUM(ca->data_type));
                              GetCArray(vsrc_val, cv);
                            }
                  C
                end

    # case B/C per-cell query load.  numeric/object: read a native cell.
    # fixlen: `query_val` is a char* into the query blob (cv->bytes wide,
    # == ca->bytes by the coerce check above); the memcmp body reads it.
    query_load_bc = if is_fixlen
                      "char *query_val = cv->ptr + val_offset;"
                    else
                      "#{si[:c]}   query_val = *(#{si[:c]} *)(cv->ptr + val_offset);"
                    end

    # view_flat: transform `result` (= axis-local position from body) to
    # outer_off + result * axis_vstride before writing to op[].  The
    # no_match sentinel (= -1 typical) is preserved unchanged so the
    # downstream `op[0] == no_match` check still fires the Qnil return.
    write_expr = view_flat \
      ? "(result == (#{oi[:c]})(#{no_match})) ? (#{oi[:c]})(#{no_match}) : (#{oi[:c]})(outer_off + (ca_size_t)result * axis_vstride)" \
      : "result"

    # undef_no_match (PROPOSAL_SEARCH_SEMANTICS_UNIFY S1): a per-fiber /
    # per-cell no-match marks the output cell UNDEF (masked) instead of
    # writing the raw -1 sentinel, unifying "not found" with the no-axis
    # flat array path.  op_mask is lazily allocated on the first no-match.
    undef_nm = k[:undef_no_match]
    nm_cond  = "result == (#{oi[:c]})(#{no_match})"
    # mask_query: :undef -- a masked query cell yields a masked output cell,
    # so an undetermined query cannot be answered from the value that happens
    # to sit under the mask.  Shares op_mask with undef_no_match.
    undef_q  = (k[:mask_query] == :undef)
    # op_mask declaration (only when an output cell can be masked);
    # content-only (the heredoc carries indentation).
    op_mask_decl = (undef_nm || undef_q) \
      ? "boolean8_t *op_mask = NULL;   /* lazily allocated on the first masked output cell */" \
      : "/* (no masked output cell) */"

    # Case A scalar UNDEF query (also reached by the A1 single-element
    # reduction when that element is masked): every output cell is
    # undetermined, so short-circuit before the query is coerced to a number.
    undef_query_a = if undef_q
                      <<~C.chomp
                        if ( rval == CA_UNDEF ) {
                              int8_t  undef_axes[1] = { (int8_t) axis };
                              VALUE   voutu = rb_ca_new_reduced(self, undef_axes, 1, #{oi[:ca]}, 0);
                              CArray *cou;
                              GetCArray(voutu, cou);
                              MEMZERO((#{oi[:c]} *) cou->ptr, #{oi[:c]}, cou->elements);
                              ca_create_mask(cou);
                              memset(cou->mask->ptr, 1, (size_t) cou->elements);
                              if ( ca->ndim == 1 ) { return Qnil; }
                              return voutu;
                            }
                      C
                    else
                      "/* (mask_query: :ignore) */"
                    end

    # Case B/C query mask base.  NULL when the query carries no mask.
    cv_mask_decl_bc = undef_q \
      ? "boolean8_t *cv_mask_base = ca_has_mask(cv) ? (boolean8_t *) cv->mask->ptr : NULL;" \
      : "/* (mask_query: :ignore) */"

    # Per-cell guard wrapping the body + write in case B/C.  A masked query
    # cell skips the body entirely and marks the output cell instead.
    undef_query_open_bc = if undef_q
                            <<~C.chomp
                              if ( cv_mask_base && cv_mask_base[val_offset / cv->bytes] ) {
                                    if ( ! op_mask ) { ca_create_mask(co); op_mask = (boolean8_t *) co->mask->ptr; }
                                    op_mask[flat] = 1;
                                    op[flat] = (#{oi[:c]}) 0;   /* undetermined query; the mask bit is what counts */
                                  } else {
                            C
                          else
                            "/* (mask_query: :ignore) */"
                          end
    undef_query_close_bc = undef_q ? "}" : "/* (mask_query: :ignore) */"

    # Per-cell write block for case A (scalar query).  `out_i` is the output
    # cursor, `co` the output CArray.  When undef_no_match: a no-match masks
    # the cell (UNDEF) instead of writing the raw sentinel.
    case_a_write = if undef_nm
                     "if ( #{nm_cond} ) {\n" \
                     "              if ( ! op_mask ) { ca_create_mask(co); op_mask = (boolean8_t *) co->mask->ptr; }\n" \
                     "              op_mask[out_i] = 1;\n" \
                     "              op[out_i++] = (#{oi[:c]}) 0;   /* sentinel; mask bit is what counts */\n" \
                     "            } else {\n" \
                     "              op[out_i++] = #{write_expr};\n" \
                     "            }"
                   else
                     "op[out_i++] = #{write_expr};"
                   end

    # Per-cell write block for case B/C (CArray query).  `flat` is the output
    # cursor, `co` the output CArray.  Reached only by fiber_local kernels
    # (view_flat raises NotImpError for CArray query), so result is the
    # axis-local position with no view-flat transform.
    case_bc_write = if undef_nm
                      "if ( #{nm_cond} ) {\n" \
                      "            if ( ! op_mask ) { ca_create_mask(co); op_mask = (boolean8_t *) co->mask->ptr; }\n" \
                      "            op_mask[flat] = 1;\n" \
                      "            op[flat] = (#{oi[:c]}) 0;   /* sentinel; mask bit is what counts */\n" \
                      "          } else {\n" \
                      "            op[flat] = result;\n" \
                      "          }"
                    else
                      "op[flat] = result;"
                    end

    # Scalar (ndim == 1) no-match test: with undef_no_match the masked cell
    # carries a 0 sentinel in op[0], so the Qnil decision reads op_mask.
    scalar_nm_check = if undef_nm
                        "op_mask && op_mask[0]"
                      else
                        (k[:no_match_check] || "op[0] == (#{oi[:c]}) (#{no_match})")
                      end

    io.puts
    io.puts <<~C
      static VALUE
      #{name}_ki_native_#{src} (VALUE self, CArray *ca, VALUE rval, int axis#{extra_params})
      {
        /* rev4 A1 via single-element CArray: convert CScalar / [1] 1-D /
           all dim==1 etc. to a Ruby Float and route it through the Case A
           scalar path. The dtype matches ca (= rb_ca_obj2ptr coerces it
           downstream). */
        if ( rb_obj_is_carray(rval) ) {
          CArray *cv_pre_;
          GetCArray(rval, cv_pre_);
          if ( cv_pre_->elements == 1 ) {
            rval = rb_funcall(rval, rb_intern("[]"), 1, INT2NUM(0));
          }
        }
        /* ===== case A: scalar val (= non-CArray Ruby value) ===== */
        if ( ! rb_obj_is_carray(rval) ) {
          #{undef_query_a}
          #{query_setup_a}
          #{eps_setup_a}

          int8_t slab_axes[1] = { (int8_t) axis };
          VALUE   vout = rb_ca_new_reduced(self, slab_axes, 1, #{oi[:ca]}, 0);
          CArray *co;
          GetCArray(vout, co);
          #{oi[:c]} *op = (#{oi[:c]} *) co->ptr;
          #{op_mask_decl}

          ca_iter_state st;
          int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES,
                                         slab_axes, 1, 0);
          if ( rc != CA_ITER_OK ) {
            rb_raise(rb_eRuntimeError,
                     "#{name}_ki: kernel_iterator init failed rc=%d", rc);
          }
    C

    if view_flat
      # view_flat semantics: compute view-flat strides + initialise
      # outer-position counter so each slab can transform fiber-local
      # result -> view-flat addr at write time.
      io.puts <<~C
              ca_size_t vstride[CA_RANK_MAX];
              ca_size_t cur_outer_idx[CA_RANK_MAX];
              {
                ca_size_t s_v = 1;
                for ( int8_t mm = (int8_t)(ca->ndim - 1); mm >= 0; mm-- ) {
                  vstride[mm] = s_v;
                  s_v *= ca->dim[mm];
                }
              }
              ca_size_t axis_vstride = vstride[axis];
              for ( int8_t mm = 0; mm < st.outer_ndim; mm++ ) cur_outer_idx[mm] = 0;
      C
    end

    io.puts <<~C
          char       *p;
          boolean8_t *m;
          ca_size_t   out_i = 0;
          while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
            char       *slab_ptr        = p;
            ca_size_t   slab_n          = st.slab_dims[0];
            ca_size_t   slab_stride     = st.slab_strides[0];
            boolean8_t *mask_in         = m;
            ca_size_t   slab_mask_stride = st.slab_mask_strides[0];
      #{mask_unused_decl}
    C

    if view_flat
      io.puts <<~C
                ca_size_t outer_off = 0;
                for ( int8_t mm = 0; mm < st.outer_ndim; mm++ ) {
                  outer_off += cur_outer_idx[mm] * vstride[st.outer_axes[mm]];
                }
      C
    end

    io.puts <<~C
            #{oi[:c]} result;
            {
      #{body_indented_8.chomp}
            }
            #{case_a_write}
    C

    if view_flat
      io.puts <<~C
                /* Advance kernel-local outer index, row-major (last axis ticks fastest). */
                for ( int8_t mm = (int8_t)(st.outer_ndim - 1); mm >= 0; mm-- ) {
                  if ( ++cur_outer_idx[mm] < st.outer_dims[mm] ) break;
                  cur_outer_idx[mm] = 0;
                }
      C
    end

    io.puts <<~C
          }
          ca_iter_state_finish(&st);

          if ( ca->ndim == 1 ) {
            if ( #{scalar_nm_check} ) return Qnil;
            return #{oi[:ruby]}(op[0]);
          }
          return vout;
        }
    C

    if view_flat
      # view_flat case B/C (CArray val with broadcast) deferred --
      # scalar val covers the common consumer pattern; broadcast path
      # would need per-element outer_off + result * axis_vstride
      # transformation in two more inner loops.
      io.puts <<~C
              /* view_flat semantics + CArray val: NotImpError (deferred). */
              rb_raise(rb_eNotImpError, "#{name}_ki: view_flat semantics with CArray val (broadcast) not yet supported");
      C
    end

    io.puts <<~C
        /* ===== case B/C: CArray val (rev4 strict acceptance) =====
           PROPOSAL_LINEAR_INTERP_PER_FIBER_MATCHED rev4: 5 forms only,
           outer product / implicit broadcast fallback removed.

             A1   scalar / 0-D                 -> handled in Case A above
             A2   1-D length M (shared)        -> axis k replaced by M
             A2.5 N-D base_shape (per-fiber)   -> axis k removed
             A3   N-D self_shape, axis k free  -> axis k replaced by M
             else                              -> raise

           Algorithm priority (= specific first, generic fallback):
             1. val.ndim == self.ndim, non-target axes match -> A3
             2. val.ndim == self.ndim - 1, val.shape == base_shape -> A2.5
             3. val.ndim == 1, length >= 1 -> A2
             4. else -> raise
        */
        CArray *cv;
        GetCArray(rval, cv);
        VALUE   vsrc_val = rval;
        #{coerce_bc}

        /* base_shape = self.shape with axis removed.  base_to_self[bk] =
           self axis index that base axis bk corresponds to. */
        int8_t base_ndim = ca->ndim - 1;
        ca_size_t base_dim[CA_RANK_MAX];
        int8_t    base_to_self[CA_RANK_MAX];
        for ( int8_t i = 0, j = 0; i < ca->ndim; i++ ) {
          if ( i != axis ) { base_dim[j] = ca->dim[i]; base_to_self[j] = i; j++; }
        }

        /* rev5 form detection (= A1 -> A3 -> A2 -> A2.5 priority; preserves
           the §3.1 unified rule across all self.ndim).

           A3 (cv.ndim == ca.ndim): commit on non-target match, raise on mismatch
           A2 (cv.ndim == 1): commit for M >= 1 (= 1-D is unconditionally shared)
           A2.5 (cv.ndim >= 2 AND cv.ndim == base_ndim): commit for
                val.shape == base_shape (= the ndim constraint structurally
                excludes a dispatch collision with a 1-D val)
           else raise

           rev4 -> rev5 priority flip: 1-D val is placed above A2.5. The
           reason is detailed in §3.2 (numerics-side 2026-06-17 feedback,
           preserving the §3.1 unified rule).
        */
        enum { CV_FORM_A3, CV_FORM_A25, CV_FORM_A2 } cv_form;
        int cv_form_set = 0;

        if ( cv->ndim == ca->ndim ) {
          /* A3 commit-or-raise */
          for ( int8_t i = 0; i < ca->ndim; i++ ) {
            if ( i == axis ) continue;
            if ( cv->dim[i] != ca->dim[i] ) {
              rb_raise(rb_eArgError,
                       "#{name}_ki: val shape mismatch (A3 candidate, axis %d non-target dim[%d] = %ld != self.dim[%d] = %ld; expected scalar / [M] / base_shape (ndim>=2) / self.shape with axis dim free)",
                       axis, (int) i, (long) cv->dim[i], (int) i, (long) ca->dim[i]);
            }
          }
          if ( cv->dim[axis] < 1 ) {
            rb_raise(rb_eArgError,
                     "#{name}_ki: empty query (val.dim[%d] = 0)", axis);
          }
          cv_form = CV_FORM_A3;
          cv_form_set = 1;
        }

        if ( ! cv_form_set && cv->ndim == 1 ) {
          /* A2: 1-D shared M-query (M >= 1); placed above A2.5 in rev5 */
          if ( cv->dim[0] < 1 ) {
            rb_raise(rb_eArgError,
                     "#{name}_ki: empty query (val.dim[0] = 0)");
          }
          cv_form = CV_FORM_A2;
          cv_form_set = 1;
        }

        if ( ! cv_form_set && cv->ndim >= 2 && cv->ndim == base_ndim ) {
          /* A2.5: per-fiber scalar query, restricted to ndim>=2. A collision
             with a 1-D val is structurally excluded by cv->ndim >= 2 (rev5). */
          int match = 1;
          for ( int8_t k = 0; k < base_ndim; k++ ) {
            if ( cv->dim[k] != base_dim[k] ) { match = 0; break; }
          }
          if ( match ) {
            cv_form = CV_FORM_A25;
            cv_form_set = 1;
          }
        }

        if ( ! cv_form_set ) {
          rb_raise(rb_eArgError,
                   "#{name}_ki: val shape not accepted (val.ndim = %d; expected scalar / [M] / base_shape (ndim>=2, = %d) / self.shape with axis dim free (ndim = %d))",
                   (int) cv->ndim, (int) base_ndim, (int) ca->ndim);
        }

        /* out_dim build per form */
        int8_t    out_ndim;
        ca_size_t out_dim[CA_RANK_MAX];
        switch ( cv_form ) {
          case CV_FORM_A3:
            out_ndim = ca->ndim;
            for ( int8_t i = 0; i < ca->ndim; i++ ) {
              out_dim[i] = (i == axis) ? cv->dim[axis] : ca->dim[i];
            }
            break;
          case CV_FORM_A25:
            out_ndim = base_ndim;
            for ( int8_t k = 0; k < base_ndim; k++ ) out_dim[k] = base_dim[k];
            break;
          case CV_FORM_A2:
            out_ndim = ca->ndim;
            for ( int8_t i = 0; i < ca->ndim; i++ ) {
              out_dim[i] = (i == axis) ? cv->dim[0] : ca->dim[i];
            }
            break;
        }

        /* out_ndim == 0 is unreachable here (A1 handled above; A2.5 with
           base_ndim == 0 means self is 1-D, but then ca->ndim == 1 routes
           to A3 candidate path, leaving base_ndim path inaccessible). */
        VALUE   vout = rb_carray_new(#{oi[:ca]}, out_ndim, out_dim, 0, NULL);
        CArray *co;
        GetCArray(vout, co);
        #{oi[:c]} *op = (#{oi[:c]} *) co->ptr;
        #{op_mask_decl}

        /* Attach self + val; rev4 uses raw row-major byte addressing. */
        ca_attach(ca);
        ca_attach(cv);

        /* self_byte_stride[j] = bytes to advance along self axis j (row-major). */
        ca_size_t self_byte_stride[CA_RANK_MAX];
        {
          ca_size_t s = ca->bytes;
          for ( int8_t j = ca->ndim - 1; j >= 0; j-- ) {
            self_byte_stride[j] = s;
            s *= ca->dim[j];
          }
        }
        ca_size_t slab_stride = self_byte_stride[axis];
        ca_size_t slab_n      = ca->dim[axis];

        /* val_byte_stride[j] = bytes to advance along val axis j (row-major). */
        ca_size_t val_byte_stride[CA_RANK_MAX];
        {
          ca_size_t s = cv->bytes;
          for ( int8_t j = cv->ndim - 1; j >= 0; j-- ) {
            val_byte_stride[j] = s;
            s *= cv->dim[j];
          }
        }

        /* Mask base pointer + per-axis slab mask stride (in mask elements,
           = bytes since boolean8_t).  mask_self: :skip exposes both to body;
           :raise already rejected upstream so these stay NULL/0 if mask
           absent. */
        boolean8_t *ca_mask_base    = ca_has_mask(ca) ? (boolean8_t *)ca->mask->ptr : NULL;
        ca_size_t   slab_mask_stride = self_byte_stride[axis] / ca->bytes;
        #{cv_mask_decl_bc}

        /* eps runtime arg resolution (only used when runtime_args :eps). */
        #{eps_setup_bc}

        /* Per-output-axis byte contributions to self slab base and val element.
           A2:   self skips axis k (slab base unchanged along axis k iteration),
                 val advances by val.byte_stride[0] only at axis k.
           A2.5: self advances by self.byte_stride[base_to_self[k]] for each out axis,
                 val advances by val.byte_stride[k] (= val matches base 1:1).
           A3:   self skips axis k (slab base unchanged along axis k iteration),
                 val advances by val.byte_stride[i] for each i (= val matches self).
        */
        ca_size_t self_base_strides[CA_RANK_MAX];
        ca_size_t val_strides[CA_RANK_MAX];
        for ( int8_t k = 0; k < out_ndim; k++ ) {
          self_base_strides[k] = 0;
          val_strides[k]       = 0;
        }
        switch ( cv_form ) {
          case CV_FORM_A3:
            for ( int8_t i = 0; i < ca->ndim; i++ ) {
              self_base_strides[i] = (i == axis) ? 0 : self_byte_stride[i];
              val_strides[i]       = val_byte_stride[i];
            }
            break;
          case CV_FORM_A25:
            for ( int8_t k = 0; k < base_ndim; k++ ) {
              self_base_strides[k] = self_byte_stride[base_to_self[k]];
              val_strides[k]       = val_byte_stride[k];
            }
            break;
          case CV_FORM_A2:
            for ( int8_t i = 0; i < ca->ndim; i++ ) {
              self_base_strides[i] = (i == axis) ? 0 : self_byte_stride[i];
              val_strides[i]       = (i == axis) ? val_byte_stride[0] : 0;
            }
            break;
        }

        /* Walk output flat, row-major, computing self_slab_offset + val_offset
           via per-axis accumulation (out_idx tracking). */
        ca_size_t out_idx[CA_RANK_MAX];
        for ( int8_t k = 0; k < out_ndim; k++ ) out_idx[k] = 0;
        ca_size_t out_elements = co->elements;

        for ( ca_size_t flat = 0; flat < out_elements; flat++ ) {
          ca_size_t self_slab_offset = 0;
          ca_size_t val_offset = 0;
          for ( int8_t k = 0; k < out_ndim; k++ ) {
            self_slab_offset += out_idx[k] * self_base_strides[k];
            val_offset       += out_idx[k] * val_strides[k];
          }
          char       *slab_ptr  = ca->ptr + self_slab_offset;
          #{query_load_bc}
          boolean8_t *mask_in   = ca_mask_base ? (ca_mask_base + self_slab_offset / ca->bytes) : NULL;
          #{eps_percell}
      #{mask_unused_decl_bc}
          #{oi[:c]} result;
          #{undef_query_open_bc}
          {
      #{body_indented_10.chomp}
          }
          #{case_bc_write}
          #{undef_query_close_bc}

          /* Increment out_idx row-major (last axis ticks fastest). */
          for ( int8_t k = out_ndim - 1; k >= 0; k-- ) {
            if ( ++out_idx[k] < out_dim[k] ) break;
            out_idx[k] = 0;
          }
        }

        ca_detach(ca);
        ca_detach(cv);
        return vout;
      }
    C
  end

  def self.emit_search_dispatch(io, k)
    name    = k[:name]
    has_eps = k[:runtime_args].include?(:eps)
    extra_arg = has_eps ? ", reps" : ""

    # Non-static linkage so kwarg trampolines in carray_order.c
    # (rb_ca_bsearch_kw etc.) can call these directly without going
    # through Ruby method lookup.
    io.puts
    io.puts "VALUE"
    if has_eps
      io.puts "rb_ca_#{name}_ki (int argc, VALUE *argv, VALUE self)"
    else
      io.puts "rb_ca_#{name}_ki (VALUE self, VALUE rval, VALUE raxis)"
    end
    io.puts "{"
    io.puts "  CArray *src;"
    io.puts "  VALUE self_ref = self;         /* pre-strip Face, for to_comparable */"
    io.puts "  int self_face_comparable = 0;"
    io.puts "  int self_was_face = 0;"
    io.puts "  GetCArray(self, src);"
    io.puts "  /* Face gate (self): descend a Face reference to storage so the"
    io.puts "     search runs on the numeric storage.  ORDERABLE licenses the"
    io.puts "     ordered/searchable descent; COMPARABLE additionally licenses"
    io.puts "     stripping a Face query for direct comparison (see the query"
    io.puts "     gate below).  A unit-bearing Face (CATime) is ORDERABLE"
    io.puts "     but not COMPARABLE, so its query is reconciled by to_comparable"
    io.puts "     -- no per-Face Ruby override needed. */"
    io.puts "  if ( ca_is_face(src) ) {"
    io.puts "    if ( ! ca_test_flag(src, CA_FLAG_FACE_ORDERABLE_STORAGE) ) {"
    io.puts %Q[      rb_raise(rb_eArgError,]
    io.puts %Q[               "#{name}_ki: Face-typed input (%s) is not orderable "]
    io.puts %Q[               "by storage; use ca.parent to descend to storage",]
    io.puts %Q[               rb_obj_classname(self));]
    io.puts "    }"
    io.puts "    self_was_face = 1;"
    io.puts "    self_face_comparable = ca_test_flag(src, CA_FLAG_FACE_COMPARABLE_STORAGE);"
    io.puts "    self = rb_ca_strip_face_value(self);"
    io.puts "    GetCArray(self, src);"
    io.puts "  }"

    if has_eps
      # arity = -1, accept (val, axis) or (val, axis, eps).  eps is the
      # only runtime arg supported in S.3 (PROPOSAL_SEARCH_AXIS §2.6,
      # 3.0 breaking from positional to keyword postponed to S.5).
      io.puts "  rb_check_arity(argc, 2, 3);"
      io.puts "  VALUE rval  = argv[0];"
      io.puts "  VALUE raxis = argv[1];"
      io.puts "  VALUE reps  = (argc >= 3) ? argv[2] : Qnil;"
    end
    io.puts "  /* Query gate (generic, PROPOSAL_FACE_ORDERING_GATE + reference"
    io.puts "     flip PROPOSAL_TO_COMPARABLE_RECEIVER_FLIP): the reference Face"
    io.puts "     reconciles the query into its own space.  A COMPARABLE self is"
    io.puts "     directly comparable -> strip a Face query, take a plain query"
    io.puts "     as-is.  A non-COMPARABLE Face reference calls its own"
    io.puts "     to_comparable(query) for ANY query type (Face CArray, our"
    io.puts "     Scalar, a Ruby Time / DateTime, ...), then strips; the"
    io.puts "     reference raises if it cannot reconcile the query.  Putting the"
    io.puts "     conversion on the reference (always one of our classes) means a"
    io.puts "     foreign query (a core Time) needs no monkey-patch, and a new"
    io.puts "     Face author writes one to_comparable, not one per query type. */"
    io.puts "  {"
    io.puts "    int rval_is_face = 0;"
    io.puts "    if ( rb_obj_is_kind_of(rval, rb_cCArray) ) {"
    io.puts "      CArray *rv_ca;"
    io.puts "      TypedData_Get_Struct(rval, CArray, &carray_data_type, rv_ca);"
    io.puts "      rval_is_face = ca_is_face(rv_ca);"
    io.puts "    }"
    io.puts "    if ( self_face_comparable ) {"
    io.puts "      if ( rval_is_face ) {"
    io.puts "        rval = rb_ca_strip_face_value(rval);"
    io.puts "      }"
    io.puts "    } else if ( self_was_face ) {"
    io.puts "      if ( rb_respond_to(self_ref, rb_intern(\"to_comparable\")) ) {"
    io.puts "        rval = rb_funcall(self_ref, rb_intern(\"to_comparable\"), 1, rval);"
    io.puts "        rval = rb_ca_strip_face_value(rval);"
    io.puts "      } else {"
    io.puts %Q[        rb_raise(rb_eArgError,]
    io.puts %Q[                 "#{name}_ki: non-comparable Face reference (%s) has no "]
    io.puts %Q[                 "to_comparable to reconcile the query; use ca.parent "]
    io.puts %Q[                 "to search the hidden storage explicitly",]
    io.puts %Q[                 rb_obj_classname(self_ref));]
    io.puts "      }"
    io.puts "    }"
    io.puts "  }"

    case k[:mask_self]
    when :raise
      io.puts "  /* mask_self: :raise -- global reject if self has any masked element. */"
      io.puts "  if ( ca_is_any_masked(src) ) {"
      io.puts %Q[    rb_raise(rb_eRuntimeError, "#{name}_ki: self should not have any masked elements");]
      io.puts "  }"
    when :skip, :ignore
      # body handles mask_in or ignores it
    end

    io.puts "  int axis = NUM2INT(raxis);"
    io.puts "  if ( axis < 0 ) axis += src->ndim;"
    io.puts "  if ( axis < 0 || axis >= src->ndim ) {"
    io.puts %Q[    rb_raise(rb_eArgError, "#{name}_ki: axis %d out of range for ndim %d", NUM2INT(raxis), src->ndim);]
    io.puts "  }"
    io.puts "  switch ( src->data_type ) {"
    k[:source].each do |s|
      si = DTYPES[s]
      io.puts "    case #{si[:ca]}: return #{name}_ki_native_#{s}(self, src, rval, axis#{extra_arg});"
    end
    io.puts "    default:"
    io.puts %Q[      rb_raise(rb_eCADataTypeError, "#{name}_ki: source data_type :%s not supported (expected one of: #{k[:source].join(", ")})", ca_type_name[src->data_type]);]
    io.puts "  }"
    io.puts "  return Qnil;  /* unreachable */"
    io.puts "}"
  end

  # ---- P.5b.1 monop emit (mkmath-compatible) ------------------------------

  # Per-data_type suffix used in math family symbol names
  # (`ca_monop_<name>_<suffix>`).  mkmath uses typedef names
  # `float32_t` / `float64_t` here, not the raw C types `float` / `double`,
  # so that `ca_monop_dispatch.c`'s extern references stay ABI-stable.
  # For all other data_types, the suffix matches `DTYPES[src][:c]`.
  def self.math_suffix(src)
    case src
    when :f32 then "float32_t"
    when :f64 then "float64_t"
    when :fixlen then "fixlen"   # symbol suffix differs from c-type "char"
    else DTYPES[src][:c]
    end
  end

  # EPSILON helper: per-float-data_type machine epsilon symbol used by bincmp
  # `feq` (= fuzzy equality).  Returns the C identifier for the epsilon
  # constant from <float.h>.
  EPSILON_FOR = {
    :f32 => "FLT_EPSILON",
    :f64 => "DBL_EPSILON",
  }.freeze


  # Resolve per-(op, data_type) expression for a monop kernel.  Returns the
  # mkmath-style string with `#1` / `#2` placeholders intact (substitution
  # happens later at the inner-loop emit site).  When the kernel's expr
  # is a Hash keyed by family alias (`:bool` / `:numeric` / `:complex` /
  # `:object`), pick the entry that matches `src`.  Returns nil when no
  # entry applies (= data_type slot fills `ca_monop_not_implement`).
  def self.monop_expr_for(k, src)
    expr = k[:expr]
    return expr if expr.is_a?(String)
    return nil unless expr.is_a?(Hash)
    # Two key formats supported:
    # 1. Symbol family alias (:bool / :numeric / :complex / :object /
    #    :int / :float / :default)
    # 2. Array of data_type symbols (= mkmath idiom, e.g. INT_TYPES, etc.)
    # The first matching entry wins (= declaration order matters when
    # arrays overlap, mirroring Ruby Hash iteration order).
    expr.each do |key, val|
      case key
      when Array
        return val if key.include?(src)
      when Symbol
        return val if monop_expr_family_match?(key, src)
      end
    end
    expr[:default]
  end

  def self.monop_expr_family_match?(family, src)
    case family
    when :bool    then src == :bool
    when :numeric then ALL_NUMERIC.include?(src)
    when :int     then ALL_NUMERIC.include?(src) && (src.to_s.start_with?("i") || src.to_s.start_with?("u"))
    when :float   then FLOAT_DTYPES.include?(src)
    when :complex then CMPLX_DTYPES.include?(src)
    when :object  then src == :object
    else false
    end
  end

  def self.emit_monop(io, k)
    io.puts
    io.puts "/* ===== monop #{k[:name]} ============================================ */"
    k[:source].each do |src|
      next if src == :reserved
      next unless monop_expr_for(k, src)
      emit_monop_native(io, k, src)
    end
    emit_monop_table(io, k)
    emit_monop_wrappers(io, k)
  end

  def self.emit_monop_native(io, k, src)
    ty = DTYPES[src]
    c_type_in  = ty[:c]
    # Output data_type: same as input for :preserve / fixed data_type, or family-
    # dispatched via Hash form (= data_type-changing monop like abs cmplx->f64).
    oi         = output_info(k, src)
    c_type_out = oi[:c]
    suffix = math_suffix(src)
    raw = monop_expr_for(k, src)
    expr_body = raw.gsub(/#1/, "*p1").gsub(/#2/, "*p2")
    # Some monops (e.g. zero / one / frac-int) don't read input — emit a leaner
    # body without p1/q1 to avoid -Wunused-but-set-variable on p1.
    uses_input = raw.include?("#1")
    # SL.2.x phase 2 (monop emit substrate hardening, MEMO_MONOP_STRIDED_AUDIT.md):
    # 3-way split (mask / contig / strided) symmetric with binop SL.2.x phase 1.
    # contig branch (i1==1 && i2==1) uses index form + `__restrict__` + `omp simd`.
    # strided branch uses `p += i` increment form (per-iter multiply removed).
    # mask branch unchanged (per-cell predicate, not SIMD-amenable).
    if uses_input
      io.print <<~C

        static void
        ca_monop_#{k[:name]}_#{suffix} (ca_size_t n, boolean8_t *m,
                                         char * __restrict__ ptr1, ca_size_t i1,
                                         char * __restrict__ ptr2, ca_size_t i2)
        {
          #{c_type_in}  * __restrict__ q1 = (#{c_type_in}  *) ptr1;
          #{c_type_out} * __restrict__ q2 = (#{c_type_out} *) ptr2;
          ca_size_t k;
          if ( m ) {
            #{c_type_in}  *p1 = q1;
            #{c_type_out} *p2 = q2;
            boolean8_t *pm;
            for (k=0; k<n; k++) {
              pm = m + k;
              if ( ! *pm ) {
                p1 = q1 + k*i1;
                p2 = q2 + k*i2;
                { #{expr_body} }
              }
            }
          } else if ( i1 == 1 && i2 == 1 ) {
            /* contig branch: SIMD-friendly form.  Index-form `q[k]` exposes
               the unit-stride access to the vectorizer; `__restrict__` on
               q1/q2 promises no aliasing so the omp simd pragma can license
               lane-parallel loads/stores.  Element-wise monop has no
               reassoc, so ε-close numeric contract is unaffected. */
            #{c_type_in}  *p1;
            #{c_type_out} *p2;
            (void)p1; (void)p2;
            #pragma omp simd
            for (k=0; k<n; k++) {
              p1 = q1 + k; p2 = q2 + k;
              { #{expr_body} }
            }
          } else {
            /* strided branch: numo-shape `p += s` increment form. */
            #{c_type_in}  *p1 = q1;
            #{c_type_out} *p2 = q2;
            for (k=0; k<n; k++) {
              { #{expr_body} }
              p1 += i1; p2 += i2;
            }
          }
        }
      C
    else
      io.print <<~C

        static void
        ca_monop_#{k[:name]}_#{suffix} (ca_size_t n, boolean8_t *m,
                                         char * __restrict__ ptr1, ca_size_t i1,
                                         char * __restrict__ ptr2, ca_size_t i2)
        {
          #{c_type_out} * __restrict__ q2 = (#{c_type_out} *) ptr2;
          ca_size_t k;
          (void) ptr1; (void) i1;  /* input ignored by this op */
          if ( m ) {
            #{c_type_out} *p2 = q2;
            boolean8_t *pm;
            for (k=0; k<n; k++) {
              pm = m + k;
              if ( ! *pm ) {
                p2 = q2 + k*i2;
                { #{expr_body} }
              }
            }
          } else if ( i2 == 1 ) {
            /* contig branch: input-free generator (zero/one/etc.) */
            #{c_type_out} *p2;
            (void)p2;
            #pragma omp simd
            for (k=0; k<n; k++) {
              p2 = q2 + k;
              { #{expr_body} }
            }
          } else {
            /* strided branch */
            #{c_type_out} *p2 = q2;
            for (k=0; k<n; k++) {
              { #{expr_body} }
              p2 += i2;
            }
          }
        }
      C
    end
  end

  def self.emit_monop_table(io, k)
    io.puts
    io.puts "ca_monop_func_t"
    io.puts "ca_monop_#{k[:name]}[CA_NTYPE] = {"
    CA_NTYPE_ORDER.each do |dt|
      if dt != :reserved && k[:source].include?(dt) && monop_expr_for(k, dt)
        io.puts "  ca_monop_#{k[:name]}_#{math_suffix(dt)},"
      else
        io.puts "  ca_monop_not_implement,"
      end
    end
    io.puts "};"
    io.puts

    # Per-op output data_type table: only emitted when output is not :preserve
    # (= data_type-changing monop like abs).  Maps input data_type to output
    # data_type (CA_INT8 etc.).  Consumed by rb_ca_call_monop_typed to allocate
    # the right output data_type per input.  -1 = not implemented.
    if k[:output] != :preserve
      io.puts "int8_t ca_monop_#{k[:name]}_out_data_type[CA_NTYPE] = {"
      CA_NTYPE_ORDER.each do |dt|
        if dt != :reserved && k[:source].include?(dt) && monop_expr_for(k, dt)
          oi = output_info(k, dt)
          io.puts "  #{oi[:ca]},"
        else
          io.puts "  -1,"
        end
      end
      io.puts "};"
      io.puts
    end
  end

  def self.emit_monop_wrappers(io, k)
    name = k[:name]
    # P.5b.2: rb_ca_<name> emitted as non-static (= ABI-visible across
    # translation units) so hand-written wrappers in ext/carray_math.c
    # (e.g. rb_ca_abs which dispatches to rb_ca_abs_i) can still link
    # against kernels now living in ext/carray_kernels.c.
    #
    # Dtype-changing (output: Hash form): wrapper dispatches via
    # rb_ca_call_monop_typed with the per-op output data_type table.  No bang
    # form is emitted (= data_type change in-place is ill-defined; user must
    # use the non-bang form which returns a fresh array of new data_type).
    if k[:output].is_a?(Hash)
      io.print <<~C
        VALUE rb_ca_#{name} (VALUE self)
        { return rb_ca_call_monop_typed(self, ca_monop_#{name}, ca_monop_#{name}_out_data_type); }

        /* bang form: legal only when output data_type == input data_type (= the
           current source family resolves to :preserve in the Hash output
           form, e.g. numeric abs).  For source data_types where output data_type
           differs (e.g. complex abs -> f64), raise. */
        VALUE rb_ca_#{name}_bang (VALUE self)
        {
          CArray *ca;
          int8_t  in_dt;
          TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
          in_dt = ca->data_type;
          if ( ca_monop_#{name}_out_data_type[in_dt] != in_dt ) {
            rb_raise(rb_eRuntimeError,
                     "#{name}!: in-place form is not available when output "
                     "data_type differs from input (input data_type %d -> output data_type %d); "
                     "use non-bang form", in_dt, ca_monop_#{name}_out_data_type[in_dt]);
          }
          return rb_ca_call_monop_bang(self, ca_monop_#{name});
        }
      C
    elsif k[:widening]
      io.print <<~C
        VALUE rb_ca_#{name} (VALUE self)
        {
          if ( rb_ca_is_integer_type(self) ) {
            self = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));
          }
          return rb_ca_call_monop(self, ca_monop_#{name});
        }

        VALUE rb_ca_#{name}_bang (VALUE self)
        { return rb_ca_call_monop_bang(self, ca_monop_#{name}); }
      C
    else
      io.print <<~C
        VALUE rb_ca_#{name} (VALUE self)
        { return rb_ca_call_monop(self, ca_monop_#{name}); }

        VALUE rb_ca_#{name}_bang (VALUE self)
        { return rb_ca_call_monop_bang(self, ca_monop_#{name}); }
      C
    end
    if k[:cmath]
      io.print <<~C

        VALUE rb_cmath_#{name} (VALUE mod, VALUE arg)
        { return ca_math_call(mod, arg, rb_intern("#{name}")); }
      C
    end
  end

  # ---- P.5b.3 binop emit (mkmath-compatible) ------------------------------

  def self.emit_binop(io, k)
    io.puts
    io.puts "/* ===== binop #{k[:name]} ============================================ */"
    k[:source].each do |src|
      next if src == :reserved
      next unless monop_expr_for(k, src)   # reuse monop expr resolver
      emit_binop_native(io, k, src)
    end
    emit_binop_table(io, k)
    emit_binop_wrappers(io, k)
  end

  def self.emit_binop_native(io, k, src)
    ty = DTYPES[src]
    c_type = ty[:c]
    suffix = math_suffix(src)
    raw = monop_expr_for(k, src)
    # binop uses #1, #2 for inputs and #3 for output
    # P.5b.5: also substitute <type> placeholder (= mkmath idiom, e.g.
    # `op_powi_<type>` resolves to `op_powi_int8_t` for int8 source).
    # Substitution uses math_suffix (= typedef name, matches the suffix
    # used in op_powi macro instantiations in ca_op_powi.h).
    expr_body = raw.gsub(/#1/, "*p1").gsub(/#2/, "*p2").gsub(/#3/, "*p3").gsub(/<type>/, suffix)
    # Option B+C pilot (binop emit substrate hardening, MEMO_BINOP_STRIDED_AUDIT.md):
    # The no-mask body is split into a contig branch (i1==i2==i3==1) using the
    # `q[k]` index form with `__restrict__`-qualified pointers + `#pragma omp simd`
    # (SL.2.x-style insurance, element-wise has no reassoc -> ε-close unaffected),
    # and a strided branch using `p += i` increment form (numo-shape inner loop).
    # `i1`/`i2`/`i3` remain element units (NOT byte) -- byte-flip is Option A scope.
    # The mask branch is left unchanged: masked binop is not a hot path and
    # branching would not auto-vec under the per-cell mask test anyway.
    io.print <<~C

      static void
      ca_binop_#{k[:name]}_#{suffix} (ca_size_t n, boolean8_t *m,
                                       char * __restrict__ ptr1, ca_size_t i1,
                                       char * __restrict__ ptr2, ca_size_t i2,
                                       char * __restrict__ ptr3, ca_size_t i3)
      {
        #{c_type} * __restrict__ q1 = (#{c_type} *) ptr1;
        #{c_type} * __restrict__ q2 = (#{c_type} *) ptr2;
        #{c_type} * __restrict__ q3 = (#{c_type} *) ptr3;
        ca_size_t k;
        if ( m ) {
          #{c_type} *p1 = q1, *p2 = q2, *p3 = q3;
          boolean8_t *pm;
          for (k=0; k<n; k++) {
            pm = m + k;
            if ( ! *pm ) {
              p1 = q1 + k*i1;
              p2 = q2 + k*i2;
              p3 = q3 + k*i3;
              { #{expr_body} }
            }
          }
        } else if ( i1 == 1 && i2 == 1 && i3 == 1 ) {
          /* contig branch: SIMD-friendly form.  Index-form `q[k]` exposes
             the unit-stride access to the vectorizer; `__restrict__` on
             q1/q2/q3 promises no aliasing so the omp simd pragma can
             license lane-parallel loads/stores.  Element-wise binop has
             no reassoc, so ε-close numeric contract is unaffected. */
          #{c_type} *p1, *p2, *p3;
          (void)p1; (void)p2; (void)p3;
          #pragma omp simd
          for (k=0; k<n; k++) {
            p1 = q1 + k; p2 = q2 + k; p3 = q3 + k;
            { #{expr_body} }
          }
        } else {
          /* strided branch: numo-shape `p += s` increment form. */
          #{c_type} *p1 = q1, *p2 = q2, *p3 = q3;
          for (k=0; k<n; k++) {
            { #{expr_body} }
            p1 += i1; p2 += i2; p3 += i3;
          }
        }
      }
    C
  end

  def self.emit_binop_table(io, k)
    io.puts
    io.puts "ca_binop_func_t"
    io.puts "ca_binop_#{k[:name]}[CA_NTYPE] = {"
    CA_NTYPE_ORDER.each do |dt|
      if dt != :reserved && k[:source].include?(dt) && monop_expr_for(k, dt)
        io.puts "  ca_binop_#{k[:name]}_#{math_suffix(dt)},"
      else
        io.puts "  ca_binop_not_implement,"
      end
    end
    io.puts "};"
    io.puts
  end

  def self.emit_binop_wrappers(io, k)
    name = k[:name]
    op   = k[:op]
    # When op is present, the wrapper falls back to
    # `rb_ca_binop_pass_to_other` for non-castable RHS, allowing Ruby's
    # double dispatch on (e.g.) `Integer#coerce`.  When op is nil
    # (internal kernels like and_i / or_i / xor_i), no pass_to_other
    # path -- the caller is expected to be a coercing wrapper.
    if op
      # Kleene boolean AND/OR wrap the value-kernel result in the three-valued
      # mask fixup (no-op unless the output is boolean with a mask).  The bang
      # variant stays blind: it overwrites self in place, so the original left
      # operand is gone by the time a fixup would run.
      call = "rb_ca_call_binop(self, other, ca_binop_#{name})"
      if k[:kleene]
        call = "ca_kleene_bool_fixup(#{call}, self, other, #{k[:kleene] == :or ? 1 : 0})"
      end
      io.print <<~C
        VALUE rb_ca_#{name} (VALUE self, VALUE other)
        {
          if ( ! rb_ca_test_castable(other) ) {
            return rb_ca_binop_pass_to_other(self, other, rb_intern("#{op}"));
          }
          return #{call};
        }

        VALUE rb_ca_#{name}_bang (VALUE self, VALUE other)
        { return rb_ca_call_binop_bang(self, other, ca_binop_#{name}); }
      C
    else
      io.print <<~C
        VALUE rb_ca_#{name} (VALUE self, VALUE other)
        { return rb_ca_call_binop(self, other, ca_binop_#{name}); }

        VALUE rb_ca_#{name}_bang (VALUE self, VALUE other)
        { return rb_ca_call_binop_bang(self, other, ca_binop_#{name}); }
      C
    end
  end

  # ---- triop emit -------------------------------------------------------

  def self.emit_triop(io, k)
    io.puts
    io.puts "/* ===== triop #{k[:name]} ============================================ */"
    k[:source].each do |src|
      next if src == :reserved
      next unless monop_expr_for(k, src)   # reuse monop expr resolver
      emit_triop_native(io, k, src)
    end
    emit_triop_table(io, k)
    emit_triop_wrappers(io, k)
  end

  def self.emit_triop_native(io, k, src)
    ty = DTYPES[src]
    c_type = ty[:c]
    suffix = math_suffix(src)
    raw = monop_expr_for(k, src)
    expr_body = raw
                  .gsub(/#1/, "*p1").gsub(/#2/, "*p2")
                  .gsub(/#3/, "*p3").gsub(/#4/, "*p4")
                  .gsub(/<type>/, suffix)
    io.print <<~C

      static void
      ca_triop_#{k[:name]}_#{suffix} (ca_size_t n, boolean8_t *m,
                                       char *ptr1, ca_size_t i1,
                                       char *ptr2, ca_size_t i2,
                                       char *ptr3, ca_size_t i3,
                                       char *ptr4, ca_size_t i4)
      {
        #{c_type} *q1 = (#{c_type} *) ptr1, *q2 = (#{c_type} *) ptr2,
                  *q3 = (#{c_type} *) ptr3, *q4 = (#{c_type} *) ptr4;
        #{c_type} *p1 = q1, *p2 = q2, *p3 = q3, *p4 = q4;
        ca_size_t k;
        if ( m ) {
          boolean8_t *pm;
          for (k=0; k<n; k++) {
            pm = m + k;
            if ( ! *pm ) {
              p1 = q1 + k*i1;
              p2 = q2 + k*i2;
              p3 = q3 + k*i3;
              p4 = q4 + k*i4;
              { #{expr_body} }
            }
          }
        } else {
          for (k=0; k<n; k++) {
            p1 = q1 + k*i1;
            p2 = q2 + k*i2;
            p3 = q3 + k*i3;
            p4 = q4 + k*i4;
            { #{expr_body} }
          }
        }
      }
    C
  end

  def self.emit_triop_table(io, k)
    io.puts
    io.puts "ca_triop_func_t"
    io.puts "ca_triop_#{k[:name]}[CA_NTYPE] = {"
    CA_NTYPE_ORDER.each do |dt|
      if dt != :reserved && k[:source].include?(dt) && monop_expr_for(k, dt)
        io.puts "  ca_triop_#{k[:name]}_#{math_suffix(dt)},"
      else
        io.puts "  ca_triop_not_implement,"
      end
    end
    io.puts "};"
    io.puts
  end

  def self.emit_triop_wrappers(io, k)
    name = k[:name]
    io.print <<~C
      VALUE rb_ca_#{name} (VALUE self, VALUE other2, VALUE other3)
      { return rb_ca_call_triop(self, other2, other3, ca_triop_#{name}); }

      VALUE rb_ca_#{name}_bang (VALUE self, VALUE other2, VALUE other3)
      { return rb_ca_call_triop_bang(self, other2, other3, ca_triop_#{name}); }
    C
  end

  # ---- P.5b.4 moncmp / bincmp emit (mkmath-compatible) ---------------------

  # Substitute mkmath placeholders `<type>` and `<epsilon>` for a given
  # source data_type.  Used by feq and any future bincmp using these macros.
  def self.cmp_expr_resolve_placeholders(expr_body, src)
    c_type  = (src == :fixlen) ? "char" : DTYPES[src][:c]
    epsilon = EPSILON_FOR[src] || ""
    expr_body.gsub(/<type>/, c_type).gsub(/<epsilon>/, epsilon)
  end

  def self.emit_moncmp(io, k)
    io.puts
    io.puts "/* ===== moncmp #{k[:name]} ============================================ */"
    k[:source].each do |src|
      next if src == :reserved
      next unless monop_expr_for(k, src)
      emit_moncmp_native(io, k, src)
    end
    emit_moncmp_table(io, k)
    emit_moncmp_wrappers(io, k)
  end

  def self.emit_moncmp_native(io, k, src)
    ty = DTYPES[src]
    c_type = ty[:c]
    suffix = math_suffix(src)
    raw = monop_expr_for(k, src)
    expr_body = cmp_expr_resolve_placeholders(raw, src).gsub(/#1/, "*p1").gsub(/#2/, "*p2")
    io.print <<~C

      static void
      ca_moncmp_#{k[:name]}_#{suffix} (ca_size_t n, boolean8_t *m,
                                        char *ptr1, ca_size_t i1,
                                        boolean8_t *ptr2, ca_size_t i2)
      {
        #{c_type} *q1 = (#{c_type} *) ptr1;
        #{c_type} *p1 = q1;
        boolean8_t *q2 = (boolean8_t *) ptr2;
        boolean8_t *p2 = q2;
        ca_size_t k;
        (void) p1;   /* expr may not reference *p1 (e.g. constant predicate) */
        if ( m ) {
          boolean8_t *pm;
          for (k=0; k<n; k++) {
            pm = m + k;
            if ( ! *pm ) {
              p1 = q1 + k*i1;
              p2 = q2 + k*i2;
              { #{expr_body} }
            }
          }
        } else {
          for (k=0; k<n; k++) {
            p1 = q1 + k*i1;
            p2 = q2 + k*i2;
            { #{expr_body} }
          }
        }
      }
    C
  end

  def self.emit_moncmp_table(io, k)
    io.puts
    io.puts "ca_moncmp_func_t"
    io.puts "ca_moncmp_#{k[:name]}[CA_NTYPE] = {"
    CA_NTYPE_ORDER.each do |dt|
      lookup_dt = (dt == :fixlen_slot) ? :fixlen : dt
      if dt != :reserved && k[:source].include?(lookup_dt) && monop_expr_for(k, lookup_dt)
        io.puts "  ca_moncmp_#{k[:name]}_#{math_suffix(lookup_dt)},"
      else
        io.puts "  ca_moncmp_not_implement,"
      end
    end
    io.puts "};"
    io.puts
  end

  def self.emit_moncmp_wrappers(io, k)
    name = k[:name]
    io.print <<~C
      VALUE rb_ca_#{name} (VALUE self)
      { return rb_ca_call_moncmp(self, ca_moncmp_#{name}); }
    C
  end

  def self.emit_bincmp(io, k)
    io.puts
    io.puts "/* ===== bincmp #{k[:name]} ============================================ */"
    k[:source].each do |src|
      next if src == :reserved
      next unless monop_expr_for(k, src)
      emit_bincmp_native(io, k, src)
    end
    emit_bincmp_table(io, k)
    emit_bincmp_wrappers(io, k)
  end

  def self.emit_bincmp_native(io, k, src)
    suffix = math_suffix(src)
    raw = monop_expr_for(k, src)
    expr_body = cmp_expr_resolve_placeholders(raw, src).gsub(/#1/, "*p1").gsub(/#2/, "*p2").gsub(/#3/, "*p3")
    # IC.1: non-tolerance ops ignore tol via (void) tol; tolerance ops
    # reference it in expr.  Either way the signature is uniform.
    tol_unused = k[:tolerance] ? "" : " (void) tol;"

    if src == :fixlen
      # FIXLEN kernel: operates on raw char* with b1/b2/b3-byte stride.
      io.print <<~C

        static void
        ca_bincmp_#{k[:name]}_#{suffix} (ca_size_t n, boolean8_t *m,
                                          char *ptr1, ca_size_t b1, ca_size_t i1,
                                          char *ptr2, ca_size_t b2, ca_size_t i2,
                                          char *ptr3, ca_size_t b3, ca_size_t i3,
                                          double tol)
        {
          char *q1 = ptr1, *q2 = ptr2;
          char *p1 = q1, *p2 = q2;
          boolean8_t *q3 = (boolean8_t *) ptr3;
          boolean8_t *p3 = q3;
          ca_size_t s1 = b1*i1, s2 = b2*i2, s3 = b3*i3;
          ca_size_t k;
         #{tol_unused}
          if ( m ) {
            boolean8_t *pm;
            for (k=0; k<n; k++) {
              pm = m + k;
              if ( ! *pm ) {
                p1 = q1 + k*s1;
                p2 = q2 + k*s2;
                p3 = q3 + k*s3;
                { #{expr_body} }
              }
            }
          } else {
            for (k=0; k<n; k++) {
              p1 = q1 + k*s1;
              p2 = q2 + k*s2;
              p3 = q3 + k*s3;
              { #{expr_body} }
            }
          }
        }
      C
    else
      c_type = DTYPES[src][:c]
      io.print <<~C

        static void
        ca_bincmp_#{k[:name]}_#{suffix} (ca_size_t n, boolean8_t *m,
                                          char *ptr1, ca_size_t b1, ca_size_t i1,
                                          char *ptr2, ca_size_t b2, ca_size_t i2,
                                          char *ptr3, ca_size_t b3, ca_size_t i3,
                                          double tol)
        {
          #{c_type} *q1 = (#{c_type} *) ptr1, *q2 = (#{c_type} *) ptr2;
          #{c_type} *p1 = q1, *p2 = q2;
          boolean8_t *q3 = (boolean8_t *) ptr3;
          boolean8_t *p3 = q3;
          ca_size_t k;
          (void) b1; (void) b2; (void) b3;  /* unused for non-fixlen kernels */
         #{tol_unused}
          if ( m ) {
            boolean8_t *pm;
            for (k=0; k<n; k++) {
              pm = m + k;
              if ( ! *pm ) {
                p1 = q1 + k*i1;
                p2 = q2 + k*i2;
                p3 = q3 + k*i3;
                { #{expr_body} }
              }
            }
          } else {
            for (k=0; k<n; k++) {
              p1 = q1 + k*i1;
              p2 = q2 + k*i2;
              p3 = q3 + k*i3;
              { #{expr_body} }
            }
          }
        }
      C
    end
  end

  def self.emit_bincmp_table(io, k)
    io.puts
    io.puts "ca_bincmp_func_t"
    io.puts "ca_bincmp_#{k[:name]}[CA_NTYPE] = {"
    CA_NTYPE_ORDER.each do |dt|
      lookup_dt = (dt == :fixlen_slot) ? :fixlen : dt
      if dt != :reserved && k[:source].include?(lookup_dt) && monop_expr_for(k, lookup_dt)
        io.puts "  ca_bincmp_#{k[:name]}_#{math_suffix(lookup_dt)},"
      else
        io.puts "  ca_bincmp_not_implement,"
      end
    end
    io.puts "};"
    io.puts
  end

  def self.emit_bincmp_wrappers(io, k)
    name = k[:name]
    op   = k[:op]
    # Same dispatch pattern as binop: pass_to_other for non-castable RHS.
    op_intern = op || name.to_s
    if k[:tolerance]
      # IC.1: tolerance ops take a positional `tol` argument from Ruby
      # and forward it to rb_ca_call_bincmp.  pass_to_other forwards
      # both other + tol (= 1 + 1 args after self).
      io.print <<~C
        VALUE rb_ca_#{name} (VALUE self, VALUE other, VALUE tol_val)
        {
          double tol = fabs(NUM2DBL(tol_val));
          if ( ! rb_ca_test_castable(other) ) {
            return rb_funcall(other, rb_intern("#{op_intern}"), 2, self, tol_val);
          }
          return rb_ca_call_bincmp(self, other, ca_bincmp_#{name}, tol);
        }
      C
    else
      io.print <<~C
        VALUE rb_ca_#{name} (VALUE self, VALUE other)
        {
          if ( ! rb_ca_test_castable(other) ) {
            return rb_ca_binop_pass_to_other(self, other, rb_intern("#{op_intern}"));
          }
          return rb_ca_call_bincmp(self, other, ca_bincmp_#{name}, 0.0);
        }
      C
    end
  end

  # The Init_carray_kernels_<suffix>(void) inside one split file: the kernels
  # and aliases belonging to that (kind, subgroup), in KERNELS order.
  def self.emit_init_for_tag(io, kind, subgroup)
    suffix = file_suffix(kind, subgroup)
    io.puts
    io.puts "void"
    io.puts "Init_carray_kernels_#{suffix} (void)"
    io.puts "{"
    KERNELS.each do |k|
      k_kind, k_sub = file_tag(k)
      next unless k_kind == kind && k_sub == subgroup
      emit_init_line(io, k)
    end
    io.puts "}"
  end

  # The aggregator init.c, where Init_carray_kernels() calls each per-tag
  # Init_<suffix>() in file_tags order.  No tag depends on another: an alias
  # already sits after its target within its own file.
  def self.emit_aggregator_init(io, tags)
    io.puts "/* GENERATED aggregator: dispatches to per-tag Init_carray_kernels_<tag>() */"
    io.puts "#include \"carray.h\""
    io.puts
    tags.each do |kind, sub|
      io.puts "void Init_carray_kernels_#{file_suffix(kind, sub)} (void);"
    end
    io.puts
    io.puts "void"
    io.puts "Init_carray_kernels (void)"
    io.puts "{"
    tags.each do |kind, sub|
      io.puts "  Init_carray_kernels_#{file_suffix(kind, sub)}();"
    end
    io.puts "}"
  end

  # Single-stream Init_carray_kernels(): every kind emitted in order inside
  # one function.
  def self.emit_init(io)
    io.puts
    io.puts "void"
    io.puts "Init_carray_kernels (void)"
    io.puts "{"
    KERNELS.each { |k| emit_init_line(io, k) }
    io.puts "}"
  end

  # One kernel's registration line, shared by the single-stream and split
  # forms.  `next` inside a method returns nil, which is the same skip the
  # KERNELS.each loop used to express.
  def self.emit_init_line(io, k)
      # P.5b.1: monop kernels register as `<op>` / `<op>!` (= mkmath
      # surface) + optional CAMath module function, NOT as `<name>_ki`.
      if k[:kind] == :monop
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:op]}", rb_ca_#{k[:name]}, 0);] if k[:bind]
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:name]}!", rb_ca_#{k[:name]}_bang, 0);]
        io.puts %Q[  rb_define_module_function(rb_mCAMath, "#{k[:name]}", rb_cmath_#{k[:name]}, 1);] if k[:cmath]
        return
      end
      # P.5b.2: monop alias = rb_define_alias to an existing monop method
      # (e.g. "-@" alias of "neg").  rb_define_alias requires the source
      # method to already be registered, so declarations must order
      # alias_monop AFTER the corresponding monop.
      if k[:kind] == :monop_alias
        io.puts %Q[  rb_define_alias(rb_cCArray, "#{k[:op]}", "#{k[:name]}");]
        return
      end
      # P.5b.3: binop kernel = `<op>` + `<name>!` (= mkmath surface).
      if k[:kind] == :binop
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:op]}", rb_ca_#{k[:name]}, 1);] if k[:op] && k[:bind]
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:name]}!", rb_ca_#{k[:name]}_bang, 1);]
        return
      end
      # triop kernel = `<op>` (arity 2) + `<name>!` (arity 2).  Self is
      # the implicit receiver; the two extra operands are explicit.
      if k[:kind] == :triop
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:op]}", rb_ca_#{k[:name]}, 2);] if k[:op] && k[:bind]
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:name]}!", rb_ca_#{k[:name]}_bang, 2);] if k[:bang] != false
        return
      end
      # P.5b.3: binop alias = rb_define_alias (e.g. "add" alias of "+").
      if k[:kind] == :binop_alias
        io.puts %Q[  rb_define_alias(rb_cCArray, "#{k[:alias_name]}", "#{k[:target_name]}");]
        return
      end
      # P.5b.4: moncmp kernel = `<op>` only (no bang form; predicate).
      if k[:kind] == :moncmp
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:op]}", rb_ca_#{k[:name]}, 0);] if k[:op]
        return
      end
      # P.5b.4: bincmp kernel = `<op>` (no bang form; predicate).
      # IC.1: tolerance ops take 2 args (other + tol).
      if k[:kind] == :bincmp
        bincmp_arity = k[:tolerance] ? 2 : 1
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:op]}", rb_ca_#{k[:name]}, #{bincmp_arity});] if k[:op]
        return
      end
      # P.5b.4: bincmp alias.
      if k[:kind] == :bincmp_alias
        io.puts %Q[  rb_define_alias(rb_cCArray, "#{k[:alias_name]}", "#{k[:target_name]}");]
        return
      end
      arity = case k[:kind]
              when :reduce then -1   # axis: kwarg + optional weights/value positional
              when :map    then  0   # no args
              when :scan   then -1   # axis: kwarg (Integer required)
              when :sort
                # SO.3+ (rev8): :partition algorithm takes (axis, kth) = arity 2
                (k[:algorithm] == :partition) ? 2 : 1
              when :search
                # (val, axis) base; runtime_args adds optional positionals
                # -> variadic argc when any runtime arg is configured.
                k[:runtime_args].empty? ? 2 : -1
              end
      # E.8: reductions no longer expose `<name>_ki` Ruby binding.
      # The 14 reduction _ki names were a transitional surface for
      # bench A/B comparison during Phase E (E.1-E.5); after E.7 they
      # are retired.  Maps and scans keep their `_ki` names because
      # they have no user-facing equivalent yet (cumsum etc. pending
      # rewire per CLAUDE.md "methods awaiting reimplementation").
      #
      # SO.2 rev6 (2026-06-04): sort kernels can opt out of the _ki
      # binding via bind_ruby: false (= internal-only kernels consumed
      # only at the C level).  Used by sort_addr_ki which feeds the
      # public sort(axis:) method without exposing its own surface.
      # bind_ruby resolves per-kind:
      #   reduce: default false (E.8 retire), opt-in via bind_ruby: true
      #           (used by CF.1 count_equal smoke + future kernel testing)
      #   sort:   default true,  opt-out via bind_ruby: false
      #   map/scan: always bound (no opt-out)
      bind = case k[:kind]
             when :reduce then k[:bind_ruby] == true
             when :sort   then k[:bind_ruby] != false
             else true
             end
      # Smoke kernels (e.g. count_equal) expose their _ki binding only
      # in dev builds, gated by CARRAY_DEV_BUILD.  See
      # devel/PROPOSAL_SMOKE_DEV_BUILD_GATE.md.
      io.puts "#ifdef CARRAY_DEV_BUILD" if bind && k[:smoke]
      io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:name]}_ki", rb_ca_#{k[:name]}_ki, #{arity});] if bind
      io.puts "#endif /* CARRAY_DEV_BUILD */" if bind && k[:smoke]
      # Scan kernels with axis_default: :flatten also bind the public
      # name (= same kernel name without the _ki suffix) so the pre-3.0
      # idiom `a.cumsum` / `a.cumsum(axis: k)` reaches rb_ca_<name>_ki
      # directly without a Ruby wrapper.  This is paired with
      # axis_default: :flatten because both express the legacy-compat
      # convenience of these specific scan kernels.
      if k[:kind] == :scan && k[:axis_default] == :flatten
        io.puts %Q[  rb_define_method(rb_cCArray, "#{k[:name]}", rb_ca_#{k[:name]}_ki, #{arity});]
      end
      # Phase E rewire: when this kernel replaces a legacy CArray method,
      # rebind the legacy name to the ki entry.  The legacy rb_ca_<name>
      # function in carray_stat_proc.c was removed in E.7.
      #
      # Sort form uses a kwarg trampoline (_kw) instead of the positional
      # _ki so the public surface is `name(axis: 0)` / `name(kth, axis: 0)`.
      if k[:public_method]
        legacy_name = k[:public_method] == true ? k[:name].to_s : k[:public_method].to_s
        if k[:kind] == :sort
          io.puts %Q[  /* Sort kwarg surface: '#{legacy_name}' dispatches via #{k[:name]}_kw trampoline */]
          io.puts %Q[  rb_define_method(rb_cCArray, "#{legacy_name}", rb_ca_#{k[:name]}_kw, -1);]
        else
          io.puts %Q[  /* Phase E rewire: legacy '#{legacy_name}' now dispatches via #{k[:name]}_ki */]
          io.puts %Q[  rb_define_method(rb_cCArray, "#{legacy_name}", rb_ca_#{k[:name]}_ki, #{arity});]
        end
      end
  end
end

# ---- kernel definitions ------------------------------------------------

# PROPOSAL_BOOLEAN_REDUCE_ACCEPT (2026-06-15): :bool source added with
# u64 output (= count of true).  Restores 2.x idiom `(a > 0).sum`
# (count of true cells).  Comment in DTYPES[:bool] (line ~68)
# is still relevant for min/max/variance — those stay rejected because
# they overlap semantically with .all / .any / Bernoulli-variance which
# users should request explicitly.  sum / mean are the "natural numeric
# extension" cases (= count / proportion).
MkKernel.reduce :sum,
  init:            { numeric: "0", complex: "0", bool: "0",
                     object:  "INT2FIX(0)" },
  reduce:          { numeric: "acc += v", complex: "acc += v", bool: "acc += v",
                     object:  'acc = rb_funcall(acc, rb_intern("+"), 1, v)' },
  reduction_kind:  :plus,     # SL.1.0: DSL wiring verification (stub forward = no behavior change)
  source:          MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:          { numeric: :f64, complex: :cmplx128, bool: :u64,
                     object:  :object },
  ruby_scalar:     :auto,     # per-output-data_type: f64 -> rb_float_new, cmplx128 -> CC2NUM, u64 -> ULL2NUM, object -> (VALUE)
  fallback:        :raise,    # was :wrap_to_f64 (silent NUM2DBL on bool/object); 3.0 breaking
  mask_policy:     :min_count,   # Phase E: accept :min_count / :fill_value opts
  identity_on_empty: true,       # ERI.0: empty / all-masked -> 0 (additive identity), not UNDEF
  public_method: true          # Phase E: rebind "sum" -> rb_ca_sum_ki

MkKernel.reduce :prod,
  init:            { numeric: "1", complex: "1", bool: "1",
                     object:  "INT2FIX(1)" },
  reduce:          { numeric: "acc *= v", complex: "acc *= v", bool: "acc *= v",
                     object:  'acc = rb_funcall(acc, rb_intern("*"), 1, v)' },
  reduction_kind:  :star,        # SL.1.4
  source:          MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:          { numeric: :f64, complex: :cmplx128, bool: :u64, object: :object },
  ruby_scalar:     :auto,
  fallback:        :raise,
  mask_policy:     :min_count,   # Phase E
  identity_on_empty: true,       # ERI.1: empty / all-masked -> 1 (multiplicative identity)
  public_method: true          # Phase E: rebind "prod" -> rb_ca_prod_ki

MkKernel.reduce :min,
  # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 3: :object uses Qundef
  # sentinel + "first cell as init" pattern (Q1 case A).  No identity
  # value exists for arbitrary Comparable; the first reduce() call
  # adopts v as acc.  mask_policy: :min_count ensures masked cells are
  # skipped before reduce() fires, so the sentinel check fires exactly
  # once per slab on the first unmasked cell.  All-masked slabs never
  # reach finish (= min_count trigger writes UNDEF), so the dangling
  # Qundef is safe.
  init:            { numeric: "T_LIMIT_HI", bool: "T_LIMIT_HI", object: "Qundef" },
  # SL.1.2: ternary form (= branchless) lets clang vectorize under
  # `#pragma omp simd reduction(min:acc)`.  The `if (v < acc) acc = v`
  # form is semantically equivalent but clang does not pattern-match
  # it for SIMD reduction; ternary is canonical for the OpenMP min:
  # reduction clause.  NaN behaviour: `(NaN < acc)` is false → acc
  # stays, byte-identical to the `if` form.
  # bool: same ternary on boolean8_t storage (false < true).  Output
  # u64 (not :preserve) so min/max of a bool array return Integer 0/1,
  # not true/false -- boolean participates in reductions as its 0/1
  # numeric storage; the boolean-returning twin is `all` (= bool min).
  reduce:          { numeric: "acc = (v < acc) ? v : acc",
                     # bool acc is u64 (numeric output); cast the boolean8_t
                     # load to match and avoid a signed/unsigned compare.
                     bool:    "acc = ((uint64_t) v < acc) ? (uint64_t) v : acc",
                     object:  'if (acc == Qundef) acc = v; else if (RTEST(rb_funcall(v, rb_intern("<"), 1, acc))) acc = v;' },
  reduction_kind:  :min,     # SL.1.2
  # CA_FIXLEN: memcmp lexicographic min (byte order == the fixlen sort
  # order); the numeric reduce/init above are unused for fixlen (bespoke
  # slab walk, see the fixlen: option in MkKernel.reduce).
  fixlen:          :min,
  source:          MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:          { numeric: :preserve, bool: :u64, object: :preserve },
  ruby_scalar:     :auto,
  fallback:        :raise,
  mask_policy:     :min_count,   # Phase E
  # An ORDERABLE Face descends to numeric storage, then the result is
  # re-lifted into the Face (scalar via storage_to_scalar, per-axis via
  # rb_ca_face_template).  This replaces per-Face lib overrides.
  face_gate:       :relift,
  public_method: true          # Phase E: rebind "min" -> rb_ca_min_ki

MkKernel.reduce :max,
  init:            { numeric: "T_LIMIT_LO", bool: "T_LIMIT_LO", object: "Qundef" },
  # SL.1.2: ternary form for clang OpenMP `reduction(max:acc)`
  # vectorization.  See :min for rationale.  bool: u64 output (Integer
  # 0/1); the boolean-returning twin is `any` (= bool max).
  reduce:          { numeric: "acc = (v > acc) ? v : acc",
                     bool:    "acc = ((uint64_t) v > acc) ? (uint64_t) v : acc",
                     object:  'if (acc == Qundef) acc = v; else if (RTEST(rb_funcall(v, rb_intern(">"), 1, acc))) acc = v;' },
  reduction_kind:  :max,     # SL.1.2
  # CA_FIXLEN: memcmp lexicographic max (byte order == the fixlen sort order).
  fixlen:          :max,
  source:          MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:          { numeric: :preserve, bool: :u64, object: :preserve },
  ruby_scalar:     :auto,
  fallback:        :raise,
  mask_policy:     :min_count,   # Phase E
  face_gate:       :relift,
  public_method: true          # Phase E: rebind "max" -> rb_ca_max_ki

# count_ki — count unmasked elements per slab.  The macro skips masked
# cells, so REDUCE fires only on contributing cells; `acc += 1` ignores
# the value entirely (cast to void to silence unused-variable warnings).
# When the input has no mask the macro takes a faster path that loads
# `v` but our REDUCE doesn't use it -- compiler optimises the load away.
MkKernel.reduce :count,
  init:        "0",
  reduce:      "(void)v; acc += 1",
  reduction_kind: :plus,         # SL.1.4
  source:      MkKernel::ALL_NUMERIC,
  output:      :i64,
  ruby_scalar: :LL2NUM,
  fallback:    :wrap_to_f64

# all / any reduce: bool input -> bool output, axis-aware.  Replaces the
# flat-only hand-written rb_ca_all_equal_p / rb_ca_any_equal_p /
# all_close? / any_close? / all_equiv? / any_equiv? in carray_stat.c
# (the predicate bridge methods were dropped 2026-06-23 as galapagos
# thin wrappers; canonical idiom is `a.eq(v).all` / `a.is_close(v, t).any`).
#
# Mask policy: default (no propagation flag) -- masked input cells are
# simply skipped by CA_SLAB_REDUCE_T's mask-aware branch, so acc keeps
# its identity value (1 for all, 0 for any) for those cells.  An all-
# masked slab returns the identity (all([]) == true, any([]) == false).
#
# Early-break is intentionally NOT implemented; idempotent acc &= v /
# acc |= v is SIMD-friendly and the branch-free form usually wins on
# modern CPUs.  For dramatically lopsided inputs (= mostly-false `all`
# or mostly-true `any`) a profile-driven early-break variant can be
# added later as a separate kernel.
MkKernel.header_block <<~C
  /* BOOL2VAL: bool -> Ruby (Qtrue/Qfalse).  Used as ruby_scalar wrapper
     for the all/any flat-reduction Ruby surface so `a.all` / `a.any`
     return real true/false, not Integer 0/1.  (BOOL2OBJ already exists
     but returns Integer per CArray's boolean-as-int convention.)  */
  #ifndef CARRAY_BOOL2VAL_DEFINED
  #define CARRAY_BOOL2VAL_DEFINED
  static inline VALUE BOOL2VAL (boolean8_t x) { return x ? Qtrue : Qfalse; }
  #endif
C

MkKernel.reduce :all,
  init:            "1",
  reduce:          "acc &= v",
  source:          [:bool],
  output:          :bool,
  ruby_scalar:     :BOOL2VAL,
  fallback:        :raise,
  public_method: :all   # bind public surface `all` to rb_ca_all_ki

MkKernel.reduce :any,
  init:            "0",
  reduce:          "acc |= v",
  source:          [:bool],
  output:          :bool,
  ruby_scalar:     :BOOL2VAL,
  fallback:        :raise,
  public_method: :any   # bind public surface `any` to rb_ca_any_ki

# none: returns true iff no cell is true.  identity = 1 (empty / fully
# masked slab -> true, matching `!any([])` and Ruby Enumerable#none?).
# acc &= !v zeros out once any true cell is seen; SIMD-friendly via the
# same reduction(&:acc) license as :all.  Sibling of :all / :any,
# avoids the per-axis `.not` ping-pong in the none_*? predicate family.
MkKernel.reduce :none,
  init:            "1",
  reduce:          "acc &= !v",
  source:          [:bool],
  output:          :bool,
  ruby_scalar:     :BOOL2VAL,
  fallback:        :raise,
  public_method: :none  # bind public surface `none` to rb_ca_none_ki

# ---- multi-state form (state + finish) ---------------------------------

# mean_ki — sum / count, with mask-aware count.
# REDUCE updates two state vars per cell; finish does the division
# (guarded against empty / all-masked slabs).
# PROPOSAL_BOOLEAN_REDUCE_ACCEPT (2026-06-15): :bool source added with
# f64 output (= proportion of true cells, Bernoulli mean).  Companion
# to bool sum above.
MkKernel.reduce :mean,
  state:           { acc: :acc_type, cnt: :int64_t },
  init:            { acc: { numeric: "0", complex: "0", bool: "0",
                            object:  "INT2FIX(0)" },
                     cnt: "0" },
  reduce:          { numeric: "(acc += v, cnt++)",
                     complex: "(acc += v, cnt++)",
                     bool:    "(acc += v, cnt++)",
                     object:  '(acc = rb_funcall(acc, rb_intern("+"), 1, v), cnt++)' },
  reduction_kind:  { acc: :plus, cnt: :induction },   # SL.1.0: DSL wiring verification
  # 8-way accumulator split follow-up (2026-07-19): mean's cnt is the
  # count of valid (non-masked) cells, which equals slab_elements minus
  # masked_cnt at slab end.  Declaring cnt as state_from_slab_size lets
  # the 8-way emit path drop `cnt++` from the per-cell reduce (which
  # can't ride the fixed-op 8-way loop) and derive cnt from that
  # identity after the SUM8 call.  Predicted i7 win: sum path already
  # ~3.5x from horizontal fix; mean was flat because the multi-state
  # gate excluded it.  This closes that follow-up.
  state_from_slab_size: [:cnt],
  finish:          { numeric: "cnt ? acc / (T_OUT) cnt : 0",
                     complex: "cnt ? acc / (T_OUT) cnt : 0",
                     bool:    "cnt ? acc / (T_OUT) cnt : 0",
                     object:  'cnt ? rb_funcall(acc, rb_intern("/"), 1, LONG2NUM(cnt)) : Qnil' },
  source:          MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:          { numeric: :f64, complex: :cmplx128, bool: :f64, object: :object },
  ruby_scalar:     :auto,
  fallback:        :raise,
  mask_policy:     :min_count,   # Phase E
  public_method: true          # Phase E: rebind "mean" -> rb_ca_mean_ki

# variancep / variance / stddevp / stddev — centred two-pass algorithm.
#
# Pass 1: sum = Σx  (SIMD :plus reduction via CA_SLAB_REDUCE_T_PLUS_EX)
# Pass 2: M2  = Σ(x - mean)²  (same macro, centred REDUCE)
# variance = M2 / n  (population) or M2 / (n-1)  (sample)
# stddev  = sqrt(fmax(variance, 0.0))
#
# Migration rationale (rev1, 2026-07-17): the one-pass sum-of-squares
# form Σx² - (Σx)²/n loses precision catastrophically for large absolute
# values (e.g. mean=1e5 K temperatures with variance 1.0 -> rel_err 1e-2;
# mean >= 1e8 flips the sign of the raw diff and produces sqrt(neg)=NaN
# or values off by orders of magnitude).  Two-pass centred subtracts the
# mean first, so (x - mean) is O(spread) and its square has no
# cancellation.  Both passes use the existing SL.1.1 SIMD :plus macro
# so vectorization is preserved; PoC (M2 Max, 1M f64) shows 1.75x
# slowdown vs the one-pass form -- much smaller than Welford's 31x.
#
# Real:    Var(X) = E[(X-μ)²]                 -- output f64
# Complex: Var(X) = E[|X - μ|²]  (non-negative real) -- output f64
# Object:  same, via Ruby numeric tower (BigDecimal / Rational exact)
#          -- variance keeps :object output, stddev drops to f64 because
#          Integer/Rational lack #sqrt and BigDecimal#sqrt needs a
#          precision arg.  Users needing exact stddev take variance
#          (exact :object) and BigMath.sqrt(var, prec) themselves.
#
# fmax(variance, 0.0) in stddev finish defends against ε-level negatives
# produced by SIMD lane reassociation of the Pass-2 sum on constant /
# near-constant slabs.  Mathematically M2 >= 0.
#
# Legacy degenerate cases preserved:
#   variancep (divisor n): n_valid == 0 => UNDEF (mask_policy default).
#   variance  (divisor n-1): n_valid == 0 => UNDEF; n_valid == 1 => 0
#     (not UNDEF), matching the pre-migration `cnt > 1 ? formula : 0`.

MkKernel.reduce :variancep,
  algorithm:        :two_pass_centred,
  divisor:          :n,
  source:           MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:           { numeric: :f64, complex: :f64, bool: :f64, object: :object },
  ruby_scalar:      :auto,
  fallback:         :raise,
  mask_policy:      :min_count,
  public_method:    true

MkKernel.reduce :variance,
  algorithm:        :two_pass_centred,
  divisor:          :n_minus_1,
  source:           MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:           { numeric: :f64, complex: :f64, bool: :f64, object: :object },
  ruby_scalar:      :auto,
  fallback:         :raise,
  mask_policy:      :min_count,
  public_method:    true

MkKernel.reduce :stddevp,
  algorithm:        :two_pass_centred,
  divisor:          :n,
  output_transform: :sqrt_clamp,
  source:           MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:           :f64,
  ruby_scalar:      :rb_float_new,
  fallback:         :raise,
  mask_policy:      :min_count,
  public_method:    true

MkKernel.reduce :stddev,
  algorithm:        :two_pass_centred,
  divisor:          :n_minus_1,
  output_transform: :sqrt_clamp,
  source:           MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:           :f64,
  ruby_scalar:      :rb_float_new,
  fallback:         :raise,
  mask_policy:      :min_count,
  public_method:    true

# ---- minmax (FM.1.0, PROPOSAL_FUSED_MINMAX) --------------------------

# minmax_ki -- single-pass fused min+max reduction.  Returns Ruby Array
# [min_val, max_val] for flat reduction, [min_ca, max_ca] for per-axis.
#
# PoC (devel/poc_minmax.c) shows i64 1.73x / f64 2.00x speedup over
# `a.min; a.max` separate calls on Apple Silicon M2 (clang -O3 -march=native
# -fopenmp-simd).  The 2x f64 speedup survives SL.1.2's reduction(min/max:)
# vectorizer reject because fminnm + fmaxnm dual-issue on M2's two FP pipes.
#
# if-form discipline (CLAUDE.md "write multi-reduction fused kernels in if-form"):
# the body uses `if (v < lo) lo = v;` etc, NOT ternary `lo = (v < lo) ? v : lo;`.
# DO NOT change to ternary — pragma-less ILP path depends on if-form.
#
# FM.1.0 scope: mask not yet propagated (FM.1.5).  Numeric dtypes only.

MkKernel.reduce :minmax,
  state:           { lo: :load_type, hi: :load_type },
  init:            { lo: { numeric: "T_LIMIT_HI", bool: "T_LIMIT_HI", object: "Qundef" },
                     hi: { numeric: "T_LIMIT_LO", bool: "T_LIMIT_LO", object: "Qundef" } },
  reduce:          { numeric: "if (v < lo) lo = v; if (v > hi) hi = v;",
                     bool:    "if (v < lo) lo = v; if (v > hi) hi = v;",
                     # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 3.5:
                     # CA_OBJECT minmax via Qundef sentinel + first-cell-init.
                     # One sentinel guards both lo + hi (they go Qundef
                     # together on init, get set together on first reduce).
                     object:  'if (lo == Qundef) { lo = v; hi = v; } else { if (RTEST(rb_funcall(v, rb_intern("<"), 1, lo))) lo = v; if (RTEST(rb_funcall(v, rb_intern(">"), 1, hi))) hi = v; }' },
  outputs:         2,
  finish:          { min: "lo", max: "hi" },
  source:          MkKernel::ALL_NUMERIC + [:bool, :object],
  # bool: u64 (Integer 0/1) so minmax returns [0/1, 0/1], not
  # [false/true, ...] -- boolean participates as its numeric storage.
  output:          { bool: :u64, default: :preserve },
  ruby_scalar:     :auto,
  fallback:        :raise,
  mask_policy:     :min_count,   # FM.1.5: match existing min / max behaviour
  public_method: :minmax    # bind public name `minmax` -> rb_ca_minmax_ki
                              # (= surface-name override, no actual legacy)

# ---- argmin / argmax (multi-state + idx binding) ---------------------

# argmin_ki / argmax_ki -- return the flat slab-row-major index of the
# (first) minimum or maximum element.  Two-state walk: the macro's
# accumulator is the running best value (best_v, source data_type); the
# secondary state tracks the index (best_i, int64_t).  The implicit
# `idx` from CA_SLAB_REDUCE_T provides the current cell's position.
#
# When the first state var isn't named `acc`, the generator threads the
# actual name (`best_v` here) through to the macro -- the macro accepts
# any identifier as its accumulator argument.
#
# Exposed as Ruby `min_index` / `max_index` (= naming convention
# "methods returning a position use *_index", see CLAUDE.md "methods
# awaiting reimplementation" table).  These
# replace the legacy `min_addr` / `max_addr` retired in E.7 stat_proc
# retire (commit f5c7ecd).  3.0 breaking: name change from `*_addr` to
# `*_index` is intentional.

MkKernel.reduce :argmin,
  state:           { best_v: :load_type, best_i: :int64_t },
  init:            { best_v: { numeric: "T_LIMIT_HI", bool: "T_LIMIT_HI", object: "Qundef" },
                     best_i: "0" },
  reduce:          { numeric: "if (v < best_v) { best_v = v; best_i = idx; }",
                     bool:    "if (v < best_v) { best_v = v; best_i = idx; }",
                     object:  'if (best_v == Qundef) { best_v = v; best_i = idx; } else if (RTEST(rb_funcall(v, rb_intern("<"), 1, best_v))) { best_v = v; best_i = idx; }' },
  finish:          "best_i",
  # CA_FIXLEN: position of the memcmp-lexicographic min (first-wins on ties).
  fixlen:          :argmin,
  source:          MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:          :i64,
  ruby_scalar:     :LL2NUM,
  fallback:        :raise,
  mask_policy:     :min_count,
  # An ORDERABLE Face descends to its numeric storage (position output needs
  # no re-lift; the axis-local index is identical for Face and storage).
  face_gate:       :strip,
  public_method: :min_index

MkKernel.reduce :argmax,
  state:           { best_v: :load_type, best_i: :int64_t },
  init:            { best_v: { numeric: "T_LIMIT_LO", bool: "T_LIMIT_LO", object: "Qundef" },
                     best_i: "0" },
  reduce:          { numeric: "if (v > best_v) { best_v = v; best_i = idx; }",
                     bool:    "if (v > best_v) { best_v = v; best_i = idx; }",
                     object:  'if (best_v == Qundef) { best_v = v; best_i = idx; } else if (RTEST(rb_funcall(v, rb_intern(">"), 1, best_v))) { best_v = v; best_i = idx; }' },
  finish:          "best_i",
  # CA_FIXLEN: position of the memcmp-lexicographic max (first-wins on ties).
  fixlen:          :argmax,
  source:          MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:          :i64,
  ruby_scalar:     :LL2NUM,
  fallback:        :raise,
  mask_policy:     :min_count,
  face_gate:       :strip,
  public_method: :max_index

# ---- argmin_addr / argmax_addr (view-flat address variants) ---------
#
# Same machinery as argmin / argmax but with :view_flat semantics --
# the kernel transforms the fiber-local best_i into a view-flat
# (row-major) address into self, suitable for direct
# +self.flatten[addrs]+ gather via CARemap M.9 (= no Ruby-side
# axis-local-to-flat-addr round-trip).
#
# Paired with the sort family's sort_addr(axis:) (= already public)
# and partition family's partition_addr_ki (= internal).  Per
# CLAUDE.md "«`_addr` is OK to expose: a per-axis primitive that returns a real flat address»"
# (= "dual API: _index for axis-local position, _addr for view-flat
# address").
#
# Runtime constraints:
#   - naxes == 1 (single-axis reduce): view-flat transform applied
#   - naxes == ca->ndim (full reduce): identity (slab walk ==
#     view-flat row-major), no transform needed
#   - 1 < naxes < ndim: raises ArgumentError (multi-axis partial
#     view_flat would require slab→view-flat decomposition; not
#     implemented in W.1)
#
# Replaces the Ruby-side _argaddr_along_axis helper added in the
# PROPOSAL_TAKE_ALONG_AXIS rev2 follow-up commit (now removed; the
# kernel below is the canonical impl).

MkKernel.reduce :argmin_addr,
  state:           { best_v: :load_type, best_i: :int64_t },
  init:            { best_v: { numeric: "T_LIMIT_HI", bool: "T_LIMIT_HI", object: "Qundef" },
                     best_i: "0" },
  reduce:          { numeric: "if (v < best_v) { best_v = v; best_i = idx; }",
                     bool:    "if (v < best_v) { best_v = v; best_i = idx; }",
                     object:  'if (best_v == Qundef) { best_v = v; best_i = idx; } else if (RTEST(rb_funcall(v, rb_intern("<"), 1, best_v))) { best_v = v; best_i = idx; }' },
  finish:          "best_i",
  source:          MkKernel::ALL_NUMERIC + [:bool, :object],
  output:          :i64,
  ruby_scalar:     :LL2NUM,
  fallback:        :raise,
  mask_policy:     :min_count,
  semantics:       :view_flat,
  face_gate:       :strip,
  public_method: :min_addr

MkKernel.reduce :argmax_addr,
  state:           { best_v: :load_type, best_i: :int64_t },
  init:            { best_v: { numeric: "T_LIMIT_LO", bool: "T_LIMIT_LO", object: "Qundef" },
                     best_i: "0" },
  reduce:          { numeric: "if (v > best_v) { best_v = v; best_i = idx; }",
                     bool:    "if (v > best_v) { best_v = v; best_i = idx; }",
                     object:  'if (best_v == Qundef) { best_v = v; best_i = idx; } else if (RTEST(rb_funcall(v, rb_intern(">"), 1, best_v))) { best_v = v; best_i = idx; }' },
  finish:          "best_i",
  source:          MkKernel::ALL_NUMERIC + [:bool, :object],
  output:          :i64,
  ruby_scalar:     :LL2NUM,
  fallback:        :raise,
  mask_policy:     :min_count,
  semantics:       :view_flat,
  face_gate:       :strip,
  public_method: :max_addr

# ---- mask_policy demos ------------------------------------------------

# sum_strict_ki -- :strict policy.  Any masked input cell makes the
# output cell UNDEF.  Use case: "this is sensor data, any gap invalidates
# the aggregate" (= NaN-propagation semantics).  Sibling of
# sum_ki which silently treats masked as 0.
MkKernel.reduce :sum_strict,
  init:        "0",
  reduce:      "acc += v",
  source:      MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  output:      { numeric: :f64, complex: :cmplx128 },
  ruby_scalar: :auto,
  fallback:    :raise,
  mask_policy: :strict

# mean_safe_ki -- :all_masked policy.  Output UNDEF only when every
# input cell is masked, otherwise mean over visible cells.  Use case:
# "tolerate gaps but flag if nothing is observed".  Sibling of mean_ki
# which returns 0.0 for all-masked slabs.
MkKernel.reduce :mean_safe,
  state:       { acc: :acc_type, cnt: :int64_t },
  init:        { acc: "0",        cnt: "0" },
  reduce:      "(acc += v, cnt++)",
  finish:      "cnt ? acc / (T_OUT) cnt : 0",
  source:      MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  output:      { numeric: :f64, complex: :cmplx128 },
  ruby_scalar: :auto,
  fallback:    :raise,
  mask_policy: :all_masked

# accumulate -- sum that preserves input data_type (legacy rb_ca_accum,
# retired in E.7).  Same machinery as sum_ki but output: :preserve so
# int8 stays int8 (will overflow on long arrays = legacy behaviour).
# Use :sum for the safe widening f64 variant.
#
# Boolean: output: :preserve keeps the result boolean, so the accumulation
# must stay in {0, 1}.  `acc ^= v` (parity / XOR-reduce) is the boolean
# "sum with per-type overflow" (mod 2): the result is whether an odd number
# of trues were seen.  This keeps the boolean type invariant (never emits a
# 2), matching accumulate's contract of overflowing within the input type's
# own width -- here that width is one bit.  It rides the generic reduce macro
# (no_simd_src) since XOR is not the `+` its :plus reduction_kind licenses.
# (For the widening count-of-trues use `sum`, which outputs u64.)
#
# Empty / all-masked -> 0 (additive identity, identity_on_empty), matching
# legacy accumulate.  UNDEF is opt-in via min_count: K.

MkKernel.reduce :accumulate,
  init:            { numeric: "0", complex: "0", bool: "0",
                     object:  "INT2FIX(0)" },
  reduce:          { numeric: "acc += v", complex: "acc += v", bool: "acc ^= v",
                     object:  'acc = rb_funcall(acc, rb_intern("+"), 1, v)' },
  reduction_kind:  :plus,        # SL.1.4c: same mechanism as :sum, output preserve
  no_simd_src:     [:bool],      # boolean lane is XOR, not the `+` :plus implies
  source:          MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:          :preserve,
  ruby_scalar:     :auto,
  fallback:        :raise,
  mask_policy:     :min_count,
  identity_on_empty: true,       # ERI.1: empty / all-masked -> 0 (additive identity)
  public_method: true

# count_true / count_false -- boolean-only reduction (E.6a).
# Per-axis support via the standard mkkernel reduction machinery; flatten
# (= no axis arg) returns Ruby Integer directly via :LL2NUM ruby_scalar.
# Output data_type = :i64, matching count_equal (= count(v) numeric): a
# count is bounded by `elements`, which can exceed INT32_MAX on large
# arrays, so i64 is the safe, family-consistent width.  (Earlier this was
# :i32 for parity with the retired carray_stat.c count_true/false; that
# parity no longer applies.)  count_masked / count_not_masked reduce the
# boolean mask through these kernels and inherit the i64 output.
# public_method: true rebinds Ruby `count_true` / `count_false` from
# the hand-written rb_ca_count_true / rb_ca_count_false in carray_stat.c
# to the kernel_iterator-based implementation generated here.
#
# mask_policy :min_count keeps legacy `(min_count, fill_value)` option
# semantics: masked cells are skipped silently.  A count has identity 0,
# so with no :min_count given an all-masked slab yields 0 (ERI, the count
# over the empty set), not UNDEF; with :min_count: K, slabs with fewer
# than K valid cells yield UNDEF (or fill_value).
#
# Since boolean8_t stores values in {0, 1}, `acc += v` counts trues
# without branching.  count_false counts cells where v == 0 via
# `acc += !v`.

MkKernel.reduce :count_true,
  init:        "0",
  reduce:      "acc += v",
  reduction_kind: :plus,         # SL.1.4c
  source:      [:bool],
  output:      :i64,
  ruby_scalar: :LL2NUM,
  mask_policy: :min_count,
  identity_on_empty: true        # ERI.2: empty / all-masked -> 0 (count over the empty set)
  # CF.7 (2026-06-04): public_method retired -- the new user-facing
  # entry is `a.count(true)` on bool data_type which dispatches to this
  # kernel via rb_ca_count in carray_count.c.  The kernel itself stays
  # bound only for internal C dispatch (no Ruby surface).

MkKernel.reduce :count_false,
  init:        "0",
  reduce:      "acc += !v",
  reduction_kind: :plus,         # SL.1.4c
  source:      [:bool],
  output:      :i64,
  ruby_scalar: :LL2NUM,
  mask_policy: :min_count,
  identity_on_empty: true        # ERI.2: empty / all-masked -> 0 (count over the empty set)
  # CF.7: see count_true above; `a.count(false)` is the user-facing entry.

# count_equal -- CF.1 first user of the value_arg: DSL framework.
# Numeric value-comparison count: counts cells where v == value_arg.
# value_arg is cast to the source data_type at the dispatcher boundary so
# integer == comparisons stay in integer space (no f64 round-trip),
# and the inner loop is a single-state SIMD-friendly counter.
#
# Internal kernel: forwarded to from `a.count(v)` numeric path
# (rb_ca_count_equal_ki call site in carray_count.c).  No Ruby binding;
# the value_arg DSL framework is pinned via test_cf1_count_equal_ki.rb
# through the count(v) surface.
#
# Output data_type = :i64 (large arrays may exceed INT32_MAX matches).

MkKernel.reduce :count_equal,
  init:        "0",
  reduce:      "if (v == value_arg) acc += 1",
  reduction_kind: :plus,         # SL.1.4 (conditional predication; clang predicates safely under reduction(+:acc))
  source:      MkKernel::ALL_NUMERIC,
  output:      :i64,
  ruby_scalar: :LL2NUM,
  fallback:    :raise,
  value_arg:   { target: :T_IN },
  mask_policy: :min_count,
  identity_on_empty: true,       # ERI.2: empty / all-masked -> 0 (count of matches in the empty set)
  bind_ruby:   false  # internal-only; count(v) dispatcher in carray_count.c
                      # is the user-facing entry

# ---- weighted reduction family migration (W.2) -----------------------
#
# W.1 framework smoke (:wsum_smoke + spec_ai/test_w1_array_arg_framework.rb)
# was retired once W.2 :wsum landed -- the production kernel below now
# serves as the sole array_arg DSL contract pin via spec_ai/test_w2_wsum.rb.

# wsum -- W.2 production migration of legacy rb_ca_wsum (carray_stat.c
# proc_wsum macro retired in same commit).  array_arg framework user.
#
# 3.0 breaking semantic changes vs legacy:
#   - **calling convention**: legacy `wsum(weights, min_count, fill_value)`
#     positional only (flatten-only) -> new `wsum(weights, *axes,
#     min_count:, fill_value:)` axes positional + opts keyword.  Legacy
#     `a.wsum(w, 0)` (= min_count: 0) is now `a.wsum(w, min_count: 0)`;
#     the old form now means "reduce axis 0" (= per-axis).
#   - **min_count semantic**: legacy was "max masked tolerable" (count >
#     min_count -> UNDEF), new is "min valid required" (valid_count <
#     min_count -> UNDEF).  Phase E sum/mean precedent (= feature_mask_spec
#     line 371-374 documents the mapping).
#   - **complex / CA_OBJECT dropped**: legacy CMPLX64/CMPLX128/CA_OBJECT
#     paths removed (= ALL_NUMERIC + :raise fallback).  Re-add via demand-
#     driven complex specialization or CA_OBJECT bridge phase.
#   - **per-axis support gained**: `a.wsum(w, 0)`, `a.wsum(w, 0, 1)`, etc.
#     (= original "open per-axis" goal, CLAUDE.md per-axis-for-all principle).
#
# public_method: true rebinds `wsum` from legacy rb_ca_wsum to
# rb_ca_wsum_ki at Init time.

MkKernel.reduce :wsum,
  init:            "0.0",
  reduce:          "acc += (double) v * (double) w",
  reduction_kind:  :plus,        # SL.1.4b: FMA-friendly weighted sum
  source:          MkKernel::ALL_NUMERIC,
  output:          :f64,
  ruby_scalar:     :rb_float_new,
  fallback:        :raise,
  array_arg:       { name: :weights, data_type: :promote,
                     shape: :rev5_strict, mask: :overlay },
  mask_policy:     :min_count,
  identity_on_empty: true,       # ERI.2: empty / all-masked -> 0.0 (weighted sum identity)
  object_escape:   :__wsum_object__,   # CA_OBJECT -> (w*self).sum (runtime.rb)
  bind_ruby:       true,
  public_method: true

# wmean -- W.3 production migration of legacy rb_ca_wmean.  Same array_arg
# framework as wsum, but uses state+finish form (= sum + den) for the
# normalisation `mean = Σv*w / Σw` semantic.
#
# Edge case: if all valid weights sum to zero (= den == 0 but some cells
# valid), finish evaluates 0/0 -> NaN.  Legacy proc_wmean had the same
# undefined behavior (no division check); mkkernel preserves it.
#
# 3.0 breaking semantic changes vs legacy (= identical to wsum W.2):
#   - calling convention positional -> kwargs (axes positional, opts kw)
#   - min_count semantic "max masked" -> "min valid required" (Phase E)
#   - complex (CMPLX64/128) dropped (= ALL_NUMERIC + :raise)
#   - per-axis support gained
# CA_OBJECT is handled via object_escape (runtime.rb __wmean_object__), not
# the numeric kernel: weight-coerce vs object arithmetic is cleaner as a
# (w*self).sum / Σw composition than a dedicated :object kernel branch.

MkKernel.reduce :wmean,
  state:           { sum: :acc_type, den: :acc_type },
  init:            { sum: "0",        den: "0" },
  reduce:          "(sum += (double) v * (double) w, den += (double) w)",
  reduction_kind:  { sum: :plus, den: :plus },     # SL.1.4b
  finish:          "sum / den",
  source:          MkKernel::ALL_NUMERIC,
  output:          :f64,
  ruby_scalar:     :rb_float_new,
  fallback:        :raise,
  array_arg:       { name: :weights, data_type: :promote,
                     shape: :rev5_strict, mask: :overlay },
  mask_policy:     :min_count,
  object_escape:   :__wmean_object__,  # CA_OBJECT -> weighted mean via runtime.rb
  bind_ruby:       true,
  public_method: true

# ---- map kernels (element-wise transforms) ----------------------------

# Float-output transcendentals -- input widens to double inside the
# expression, output is float64.  The :wrap_to_f64 fallback handles
# any other numeric data_type (int16, bool, etc.) by promoting to f64 first.

MkKernel.map :sqrt,
  source:   MkKernel::ALL_NUMERIC,
  output:   :f64,
  expr:     "r = sqrt((double) v)",
  fallback: :wrap_to_f64

MkKernel.map :sin,
  source:   MkKernel::ALL_NUMERIC,
  output:   :f64,
  expr:     "r = sin((double) v)",
  fallback: :wrap_to_f64

MkKernel.map :cos,
  source:   MkKernel::ALL_NUMERIC,
  output:   :f64,
  expr:     "r = cos((double) v)",
  fallback: :wrap_to_f64

MkKernel.map :exp,
  source:   MkKernel::ALL_NUMERIC,
  output:   :f64,
  expr:     "r = exp((double) v)",
  fallback: :wrap_to_f64

MkKernel.map :log,
  source:   MkKernel::ALL_NUMERIC,
  output:   :f64,
  expr:     "r = log((double) v)",
  fallback: :wrap_to_f64

# Source-data_type-preserving transforms -- arithmetic ops that don't need
# floating-point.  Fallback raises rather than silently widening.

MkKernel.map :square,
  source:   MkKernel::ALL_NUMERIC,
  output:   :preserve,
  expr:     "r = v * v",
  fallback: :raise

MkKernel.map :abs,
  # Signed-only: `v < 0` is always false on unsigned types (compiler
  # warning + identity result).  Use `negate` semantics for unsigned
  # only if you genuinely want wrap-around.
  source:   MkKernel::SIGNED_NUMERIC,
  output:   :preserve,
  expr:     "r = (v < 0) ? -v : v",
  fallback: :raise

MkKernel.map :negate,
  # Signed-only: -v on unsigned types wraps (C semantics), which is
  # mathematically wrong for "negate".  If you want bitwise inversion
  # on unsigned, use a different kernel (~v).
  source:   MkKernel::SIGNED_NUMERIC,
  output:   :preserve,
  expr:     "r = -v",
  fallback: :raise

# ---- scan kernels (cumulative / prefix scan along one axis) ----------

# cumsum / cumprod: data_type-conditional output (numeric -> f64 widening,
# complex -> cmplx128 widening).  Matches the pre-Phase E hand-written
# rb_ca_cumsum / rb_ca_cumprod which widened cmplx64/cmplx128 inputs to
# cmplx128 outputs.  Object / bool / fixlen raise explicitly via
# fallback: :raise (3.0 breaking from the old :wrap_to_f64 that silently
# cast everything through NUM2DBL).  Migration for object:
# `a.as_float64.cumsum`; for bool: `a.cumcount` or `a.as_int32.cumsum`.

MkKernel.scan :cumsum,
  source:       MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:       { numeric: :f64, complex: :cmplx128, bool: :u64, object: :object },
  init:         { numeric: "0", complex: "0", bool: "0", object: "INT2FIX(0)" },
  step:         { numeric: "acc += v; r = acc",
                  complex: "acc += v; r = acc",
                  bool:    "acc += v; r = acc",
                  object:  'acc = rb_funcall(acc, rb_intern("+"), 1, v); r = acc' },
  fallback:     :raise,
  axis_default: :flatten

MkKernel.scan :cumprod,
  source:       MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:bool, :object],
  output:       { numeric: :f64, complex: :cmplx128, bool: :u64, object: :object },
  init:         { numeric: "1", complex: "1", bool: "1", object: "INT2FIX(1)" },
  step:         { numeric: "acc *= v; r = acc",
                  complex: "acc *= v; r = acc",
                  bool:    "acc *= v; r = acc",
                  object:  'acc = rb_funcall(acc, rb_intern("*"), 1, v); r = acc' },
  fallback:     :raise,
  axis_default: :flatten

# cummax / cummin: running extremum with no identity.  Until a fiber's
# first present (unmasked) cell, the running extremum is undefined, so the
# output cell is UNDEF (empty: :undef -> seen-gated, CA_SLAB_SCAN_T_GATED).
# This matches the reduction contract (empty max / min = UNDEF) and the
# axis-group scan family.  Numeric init is the type limit (never observed
# in the output: leading cells are masked, not sentinel-filled); the object
# init Qnil is the "no running extremum yet" sentinel, also never leaked
# (unseen cells are masked).  First unmasked cell adopts v as acc;
# subsequent unmasked cells compare via rb_funcall(:>) / rb_funcall(:<).
MkKernel.scan :cummax,
  source:       MkKernel::ALL_NUMERIC + [:bool, :object],
  output:       { bool: :u64, default: :preserve },
  init:         { numeric: "T_LIMIT_LO", bool: "T_LIMIT_LO", object: "Qnil" },
  step:         { numeric: "if (v > acc) acc = v; r = acc",
                  bool:    "if ((uint64_t) v > acc) acc = v; r = acc",
                  object:  'if (acc == Qnil) acc = v; else if (RTEST(rb_funcall(v, rb_intern(">"), 1, acc))) acc = v; r = acc' },
  fallback:     :raise,
  axis_default: :flatten,
  empty:        :undef

MkKernel.scan :cummin,
  source:       MkKernel::ALL_NUMERIC + [:bool, :object],
  output:       { bool: :u64, default: :preserve },
  init:         { numeric: "T_LIMIT_HI", bool: "T_LIMIT_HI", object: "Qnil" },
  step:         { numeric: "if (v < acc) acc = v; r = acc",
                  bool:    "if ((uint64_t) v < acc) acc = v; r = acc",
                  object:  'if (acc == Qnil) acc = v; else if (RTEST(rb_funcall(v, rb_intern("<"), 1, acc))) acc = v; r = acc' },
  fallback:     :raise,
  axis_default: :flatten,
  empty:        :undef

# cumcount: running count of unmasked cells.  Output data_type = int64.
# `(void) v` silences unused-variable warning for the unmasked path
# (compiler DCEs the v load when STEP doesn't reference it).
MkKernel.scan :cumcount,
  source:       MkKernel::ALL_NUMERIC,
  output:       :i64,
  init:         "0",
  step:         "(void) v; r = ++acc",
  fallback:     :wrap_to_f64,
  axis_default: :flatten

# uniq_scan: per-axis adjacent-compare scan returning a boolean
# "is duplicate" flag.  Output[i] = true iff the value at position i
# along the scan axis equals the most recent unmasked value already
# seen (= the "kept" element of the current run).  First unmasked
# cell of each fiber is always kept (r = 0).  Masked input cells are
# skipped: they neither update the accumulator nor produce a "kept"
# decision (output written as 0, which is harmless because the
# downstream pipeline ORs the result into the parent mask whose
# masked positions are already set).
#
# Designed for use AFTER sort_addr(axis:) gather, so equal values
# already cluster together adjacent along the scan axis.  See
# PROPOSAL_UNIQ_AXIS.md §3 for the full pipeline.
#
# acc_type: :load_type -> acc carries T_LOAD (= last seen input value).
# STEP additionally sees `first` (int) marking the first live cell of
# the fiber.  Output data_type = :bool.  No production consumer remains:
# every dtype's mask_duplicates now uses the O(distinct) seen-set hash
# lane (__mask_duplicates__, with boolean riding its uint8 lane), which
# has no sort buffers.  The numeric widths are kept as a standalone scan
# kernel (a sort-path reference oracle in the mask_duplicates tests).
# The :bool source was retired once boolean mask_duplicates moved to the
# hash lane; object / fixlen never rode this scan.
MkKernel.scan :uniq_scan,
  source:   MkKernel::ALL_NUMERIC,
  output:   :bool,
  acc_type: :load_type,
  init:     "0",   # value doesn't matter; `first` guards the first cell
  step:     "if (first) { acc = v; r = 0; } else if (v == acc) { r = 1; } else { acc = v; r = 0; }",
  fallback: :raise

# ---- Sort family kernels (PROPOSAL_SORT_AXIS.md SO.1 / SO.2) -----------
#
# sort_index: per-axis sort index.  Returns CA_SIZE array of fiber-local
# indices (= 0..dim[axis]-1) giving the sorted order along axis k.
# Stability guaranteed via (value, idx) pair
# tie-break inside the cmp function (= sort_addr.c pattern, see
# emit_sort_cmp).  CA_FIXLEN / CA_OBJECT deferred (no demand yet).
MkKernel.sort :sort_index,
  source:          MkKernel::ALL_NUMERIC + [:bool] + [:object] + [:fixlen],
  output:          :ca_size,
  semantics:       :fiber_local,
  nan_policy:      :end,
  fallback:        :raise,
  mask_self:       :sentinel,  # masked cells sort to masked_position: :first/:last (default :last)
  public_method: :sort_index,  # binds public sort_index(axis: 0, masked_position: :last) via _kw trampoline
  c_callable:      true          # extern linkage for carray_order.c (nlargest / order family)

# sort_addr: per-axis argsort returning view-flat addresses (=
# 0..elements-1, row-major position).  Identical machinery to
# sort_index but the kernel writes view-flat addresses instead of
# fiber-local indices, so the output can feed directly into
# ca_remap_new as a CARemap.idx.  Internal-only (bind_ruby: false):
# used by `a.sort(axis: k)` at the C level via rb_ca_sort_addr_ki.
# rev3 of PROPOSAL_SORT_AXIS defers `sort_addr(axis: k)` as a public
# method to a future phase; here we just need the kernel machinery.
MkKernel.sort :sort_addr,
  source:     MkKernel::ALL_NUMERIC + [:bool] + [:object] + [:fixlen],
  output:     :ca_size,
  semantics:  :view_flat,
  nan_policy: :end,
  fallback:   :raise,
  mask_self:  :sentinel,  # masked cells sort to masked_position: :first/:last (default :last)
  bind_ruby:  false

# partition_index: per-axis partition index along axis k.
# Returns CA_SIZE of fiber-local indices such that the kth position
# holds the (fiber-local) index of the kth-smallest value, with all
# positions before it indexing values <= and all after >=.  Order
# WITHIN those regions is unspecified.
# Average O(n) per fiber via quickselect with median-of-three pivot.
# Public Ruby surface: a.partition_index_ki(axis, kth).
MkKernel.sort :partition_index,
  source:          MkKernel::ALL_NUMERIC + [:bool] + [:object] + [:fixlen],
  output:          :ca_size,
  semantics:       :fiber_local,
  nan_policy:      :end,
  fallback:        :raise,
  algorithm:       :partition,
  mask_self:       :sentinel,  # masked cells sort to masked_position: :first/:last (default :last)
  public_method: :partition_index, # binds partition_index(kth, axis: 0, masked_position: :last) via _kw trampoline
  c_callable:      true              # extern linkage for carray_order.c (nlargest / nsmallest)

# partition_addr: view-flat-address variant of partition_index, parallel
# to sort_addr_ki.  Output is suitable for direct feed into ca_remap_new
# (= CARemap.idx).  Internal-only (bind_ruby: false): consumed by the
# public partition(kth, axis: k) Ruby surface in lib/carray/ordering.rb,
# which feeds the addrs into the indexer's M.9 same-shape routing to
# build a CARemap view.
MkKernel.sort :partition_addr,
  source:     MkKernel::ALL_NUMERIC + [:bool] + [:object] + [:fixlen],
  output:     :ca_size,
  semantics:  :view_flat,
  nan_policy: :end,
  fallback:   :raise,
  mask_self:  :sentinel,  # masked cells sort to masked_position: :first/:last (default :last)
  bind_ruby:  false,
  algorithm:  :partition

# ---- rank_index (= per-fiber rank, sort_index ** -1) ----------------------
#
# Per-fiber rank: output[i] = "axis-local rank of self[i] among the
# fiber's unmasked cells" (= scipy.stats.rankdata 'ordinal' style,
# stable for ties).  Output shape == self.shape; output data_type = CA_SIZE.
#
# Mask handling (mask_self: :skip): per-fiber, masked input cells are
# omitted from the sort.  Ranks 0..k-1 fill the unmasked positions in
# value order; masked positions in self produce UNDEF in the output
# (= output mask bit set, value 0 sentinel).
#
# Algorithmic identity: rank = sort_index ** -1 (inverse permutation),
# computed in one pass as "sort by value, then scatter rank at original
# axis-local position".  Saves the second sort_index_ki call the
# previous Ruby implementation of CArray#order made.
MkKernel.sort :rank_index,
  source:          MkKernel::ALL_NUMERIC + [:bool] + [:object] + [:fixlen],
  output:          :ca_size,
  semantics:       :fiber_local,
  nan_policy:      :end,
  fallback:        :raise,
  algorithm:       :rank,
  mask_self:       :skip,
  public_method: :rank_index,  # binds public rank_index(axis: 0) via _kw trampoline
  c_callable:      true          # extern linkage for carray_order.c (order method)

# ---- search family ------------------------------------------------------
#
# Phase S.1 (PROPOSAL_SEARCH_AXIS_S1.md): demo kernel for the search form.
# S.1.2a scope: case A (= scalar query) only.  S.1.2b will extend case B
# (val.shape append to output tail) and case C (val.shape == base_shape).
# S.2-S.4 will land production family kernels (bsearch / search /
# search_nearest) using this same DSL form.
#
# find_value_index_ki: per-slice linear scan returning the first matching
# position (first index where slice == v).  No-match returns
# -1 sentinel (mapped to nil in scalar return path).  mask_self: :raise
# matches bsearch family semantics.
MkKernel.search :find_value_index,
  source:    MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:    :ca_size,
  body:      {
    int: <<~C,
      result = (ca_size_t) -1;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( v == query_val ) { result = i; break; }
      }
    C
    float: <<~C,
      result = (ca_size_t) -1;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( v == query_val ) { result = i; break; }
      }
    C
    object: <<~C,
      result = (ca_size_t) -1;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( rb_equal(v, query_val) ) { result = i; break; }
      }
    C
    fixlen: <<~C,
      /* CA_FIXLEN: cells are ca->bytes-wide blobs; exact match via memcmp. */
      result = (ca_size_t) -1;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        char *v = slab_ptr + i * slab_stride;
        if ( memcmp(v, query_val, (size_t) ca->bytes) == 0 ) { result = i; break; }
      }
    C
  },
  no_match:  "-1",
  undef_no_match: true,
  mask_self: :raise,
  fallback:  :raise

# bsearch_ki: per-slice binary search returning the matching position
# (assumes a sorted slab).  NaN handling: NaN sorts to end; query == NaN
# never matches.  Hand-rolled strided binary search (= libc bsearch()
# requires contig memory; slab_stride may be > sizeof(T_LOAD) for a
# non-innermost search axis).  NaN guards are dead code for integer
# data_types and the compiler optimises them away.  mask_self: :raise
# (= global reject if self has any masked element; the sorted invariant
# assumes no masks).
#
# Source coverage: ALL_NUMERIC + object (rb_funcall <=> ordering) + fixlen
# (memcmp lexicographic).  This is the sole bsearch implementation: the
# no-axis (flat) surface routes here via flatten + axis 0
# (PROPOSAL_SEARCH_SEMANTICS_UNIFY S2/S3; the legacy flat scan was removed).
MkKernel.search :bsearch,
  source:    MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:    :ca_size,
  body:      {
    int: <<~C,
      result = (ca_size_t) -1;
      if ( ! isnan((double) query_val) ) {
        ca_size_t lo = 0;
        ca_size_t hi = slab_n;
        while ( lo < hi ) {
          ca_size_t mid = lo + (hi - lo) / 2;
          T_LOAD v = *(T_LOAD *)(slab_ptr + mid * slab_stride);
          if ( isnan((double) v) ) { hi = mid; continue; }
          if ( v < query_val ) lo = mid + 1;
          else if ( v > query_val ) hi = mid;
          else { result = mid; break; }
        }
      }
    C
    float: <<~C,
      result = (ca_size_t) -1;
      if ( ! isnan((double) query_val) ) {
        ca_size_t lo = 0;
        ca_size_t hi = slab_n;
        while ( lo < hi ) {
          ca_size_t mid = lo + (hi - lo) / 2;
          T_LOAD v = *(T_LOAD *)(slab_ptr + mid * slab_stride);
          if ( isnan((double) v) ) { hi = mid; continue; }
          if ( v < query_val ) lo = mid + 1;
          else if ( v > query_val ) hi = mid;
          else { result = mid; break; }
        }
      }
    C
    object: <<~C,
      /* CA_OBJECT bsearch: ordering via rb_funcall(<=>).  Assumes the
         slab is sorted by the same comparator used to build it.  NaN
         guards skipped (= no float-NaN concept for arbitrary objects;
         a Float-cell NaN would raise from <=>). */
      result = (ca_size_t) -1;
      ca_size_t lo = 0;
      ca_size_t hi = slab_n;
      while ( lo < hi ) {
        ca_size_t mid = lo + (hi - lo) / 2;
        T_LOAD v = *(T_LOAD *)(slab_ptr + mid * slab_stride);
        VALUE r = rb_funcall(v, rb_intern("<=>"), 1, query_val);
        if ( NIL_P(r) ) {
          rb_raise(rb_eArgError, "bsearch: comparison of %s with %s failed",
                   rb_obj_classname(v), rb_obj_classname(query_val));
        }
        int c = NUM2INT(r);
        if ( c < 0 ) lo = mid + 1;
        else if ( c > 0 ) hi = mid;
        else { result = mid; break; }
      }
    C
    fixlen: <<~C,
      /* CA_FIXLEN bsearch: lexicographic ordering via memcmp over ca->bytes
         (= the same total order fixlen bincmp `<`/`>` uses, so the sorted
         invariant the slab must satisfy is consistent with the surface). */
      result = (ca_size_t) -1;
      ca_size_t lo = 0;
      ca_size_t hi = slab_n;
      while ( lo < hi ) {
        ca_size_t mid = lo + (hi - lo) / 2;
        char *v = slab_ptr + mid * slab_stride;
        int c = memcmp(v, query_val, (size_t) ca->bytes);
        if ( c < 0 ) lo = mid + 1;
        else if ( c > 0 ) hi = mid;
        else { result = mid; break; }
      }
    C
  },
  no_match:  "-1",
  undef_no_match: true,
  mask_self: :raise,
  fallback:  :raise

# search_ki: per-slice linear scan returning the first matching position,
# with optional eps tolerance.  mask_self: :skip (= per-slice mask skip;
# masked self cells are passed over).  eps is a positional 3rd arg on the
# kernel (the Ruby surface exposes it positionally too).
#
# Per-data_type body: int uses exact `v == query_val` (eps ignored); float
# uses `fabs(v - query_val) <= query_eps` (eps_default = FLT_EPSILON*|val|
# or DBL_EPSILON*|val|); object uses rb_equal (eps ignored); fixlen uses
# memcmp exact match (eps ignored).  Sole search implementation: the
# no-axis (flat) surface routes here via flatten + axis 0
# (PROPOSAL_SEARCH_SEMANTICS_UNIFY S2/S3; the legacy flat scan was removed).
MkKernel.search :search,
  source:    MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:    :ca_size,
  body:      {
    int: <<~C,
      result = (ca_size_t) -1;
      (void) query_eps;  /* int data_type: exact match, eps ignored */
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( v == query_val ) { result = i; break; }
      }
    C
    float: <<~C,
      result = (ca_size_t) -1;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( fabs((double)(v - query_val)) <= query_eps ) { result = i; break; }
      }
    C
    object: <<~C,
      /* CA_OBJECT search: exact equality via rb_equal.  eps is silently
         ignored (= no meaningful tolerance on arbitrary Ruby objects). */
      result = (ca_size_t) -1;
      (void) query_eps;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( rb_equal(v, query_val) ) { result = i; break; }
      }
    C
    fixlen: <<~C,
      /* CA_FIXLEN search: exact match via memcmp; eps ignored (no scalar
         tolerance on byte blobs). */
      result = (ca_size_t) -1;
      (void) query_eps;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        char *v = slab_ptr + i * slab_stride;
        if ( memcmp(v, query_val, (size_t) ca->bytes) == 0 ) { result = i; break; }
      }
    C
  },
  no_match:     "-1",
  undef_no_match: true,
  mask_self:    :skip,
  runtime_args: %i[eps],
  fallback:     :raise

# search_nearest_ki: per-slice scan returning the position of the slab
# element nearest to query_val.  mask_self: :skip (per-slice mask skip);
# no eps argument (exact distance metric, no fuzzy tolerance).  All-masked
# / all-NaN slab -> no candidate -> UNDEF (S1).
#
# Numeric: minimum of |v - query_val|, both cast to double before
# subtraction (avoids int over/underflow; precision loss above 2^53 is
# acceptable for "nearest").  NaN cells give dist=NaN, never < best_dist,
# so they are skipped.  CA_OBJECT: minimum of query_val.distance(cell)
# compared with `<` (the metric the legacy flat search_nearest used).
# Sole nearest implementation: the no-axis surface routes here via flatten
# + axis 0 (the unification that removed the duplicate code path -- moving
# the object distance metric into _ki let the flat function go).
MkKernel.search :search_nearest,
  source:    MkKernel::ALL_NUMERIC + [:bool, :object],
  output:    :ca_size,
  body:      {
    int: <<~C,
      result = (ca_size_t) -1;
      double best_dist = INFINITY;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        double dist = fabs((double)v - (double)query_val);
        if ( dist < best_dist ) { best_dist = dist; result = i; }
      }
      (void) query_eps;  /* unused: search_nearest has no eps semantics */
    C
    float: <<~C,
      result = (ca_size_t) -1;
      double best_dist = INFINITY;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        double dist = fabs((double)v - (double)query_val);
        if ( dist < best_dist ) { best_dist = dist; result = i; }
      }
      (void) query_eps;  /* unused: search_nearest has no eps semantics */
    C
    object: <<~C,
      /* CA_OBJECT nearest: minimum of query_val.distance(cell), compared
         with `<` (matches the legacy flat proc_nearest_addr_VALUE). */
      result = (ca_size_t) -1;
      VALUE best = Qnil;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        VALUE dist = rb_funcall(query_val, rb_intern("distance"), 1, v);
        if ( NIL_P(best) || RTEST(rb_funcall(dist, rb_intern("<"), 1, best)) ) {
          best = dist; result = i;
        }
      }
      (void) query_eps;  /* unused: search_nearest has no eps semantics */
    C
  },
  no_match:  "-1",
  undef_no_match: true,
  mask_self: :skip,
  fallback:  :raise

# ---- *_addr variants (= :view_flat semantics) ----------------------------
#
# Same kernel bodies as bsearch / search / search_nearest, but the result
# (= axis-local position) is transformed to a view-flat (row-major) address
# into self by the dispatcher.  Paired with the *_index family
# (= bsearch / search / search_nearest already returning axis-local
# positions per the dual `_index` / `_addr` API in CLAUDE.md "`_addr` is
# OK to expose: a per-axis primitive that returns a real flat address").
#
# Scope: scalar val path only (= case A).  CArray val + broadcast
# path (case B/C) raises NotImpError until extended (= the per-element
# inner loops would need the same outer_off + result * axis_vstride
# transform).
MkKernel.search :bsearch_addr,
  source:    MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:    :ca_size,
  body:      {
    int: <<~C,
      result = (ca_size_t) -1;
      if ( ! isnan((double) query_val) ) {
        ca_size_t lo = 0;
        ca_size_t hi = slab_n;
        while ( lo < hi ) {
          ca_size_t mid = lo + (hi - lo) / 2;
          T_LOAD v = *(T_LOAD *)(slab_ptr + mid * slab_stride);
          if ( isnan((double) v) ) { hi = mid; continue; }
          if ( v < query_val ) lo = mid + 1;
          else if ( v > query_val ) hi = mid;
          else { result = mid; break; }
        }
      }
    C
    float: <<~C,
      result = (ca_size_t) -1;
      if ( ! isnan((double) query_val) ) {
        ca_size_t lo = 0;
        ca_size_t hi = slab_n;
        while ( lo < hi ) {
          ca_size_t mid = lo + (hi - lo) / 2;
          T_LOAD v = *(T_LOAD *)(slab_ptr + mid * slab_stride);
          if ( isnan((double) v) ) { hi = mid; continue; }
          if ( v < query_val ) lo = mid + 1;
          else if ( v > query_val ) hi = mid;
          else { result = mid; break; }
        }
      }
    C
    object: <<~C,
      result = (ca_size_t) -1;
      ca_size_t lo = 0;
      ca_size_t hi = slab_n;
      while ( lo < hi ) {
        ca_size_t mid = lo + (hi - lo) / 2;
        T_LOAD v = *(T_LOAD *)(slab_ptr + mid * slab_stride);
        VALUE r = rb_funcall(v, rb_intern("<=>"), 1, query_val);
        if ( NIL_P(r) ) {
          rb_raise(rb_eArgError, "bsearch_addr: comparison of %s with %s failed",
                   rb_obj_classname(v), rb_obj_classname(query_val));
        }
        int c = NUM2INT(r);
        if ( c < 0 ) lo = mid + 1;
        else if ( c > 0 ) hi = mid;
        else { result = mid; break; }
      }
    C
    fixlen: <<~C,
      /* CA_FIXLEN bsearch_addr: lexicographic ordering via memcmp. */
      result = (ca_size_t) -1;
      ca_size_t lo = 0;
      ca_size_t hi = slab_n;
      while ( lo < hi ) {
        ca_size_t mid = lo + (hi - lo) / 2;
        char *v = slab_ptr + mid * slab_stride;
        int c = memcmp(v, query_val, (size_t) ca->bytes);
        if ( c < 0 ) lo = mid + 1;
        else if ( c > 0 ) hi = mid;
        else { result = mid; break; }
      }
    C
  },
  no_match:  "-1",
  undef_no_match: true,
  mask_self: :raise,
  fallback:  :raise,
  semantics: :view_flat

MkKernel.search :search_addr,
  source:    MkKernel::ALL_NUMERIC + [:bool, :object, :fixlen],
  output:    :ca_size,
  body:      {
    int: <<~C,
      result = (ca_size_t) -1;
      (void) query_eps;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( v == query_val ) { result = i; break; }
      }
    C
    float: <<~C,
      result = (ca_size_t) -1;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( fabs((double)v - (double)query_val) <= query_eps ) { result = i; break; }
      }
    C
    object: <<~C,
      result = (ca_size_t) -1;
      (void) query_eps;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        if ( rb_equal(v, query_val) ) { result = i; break; }
      }
    C
    fixlen: <<~C,
      /* CA_FIXLEN search_addr: exact match via memcmp; eps ignored. */
      result = (ca_size_t) -1;
      (void) query_eps;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        char *v = slab_ptr + i * slab_stride;
        if ( memcmp(v, query_val, (size_t) ca->bytes) == 0 ) { result = i; break; }
      }
    C
  },
  no_match:     "-1",
  undef_no_match: true,
  mask_self:    :skip,
  runtime_args: [:eps],
  fallback:     :raise,
  semantics:    :view_flat

MkKernel.search :search_nearest_addr,
  source:    MkKernel::ALL_NUMERIC + [:bool, :object],
  output:    :ca_size,
  body:      {
    int: <<~C,
      result = (ca_size_t) -1;
      double best_dist = INFINITY;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        double dist = fabs((double)v - (double)query_val);
        if ( dist < best_dist ) { best_dist = dist; result = i; }
      }
      (void) query_eps;
    C
    float: <<~C,
      result = (ca_size_t) -1;
      double best_dist = INFINITY;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        double dist = fabs((double)v - (double)query_val);
        if ( dist < best_dist ) { best_dist = dist; result = i; }
      }
      (void) query_eps;
    C
    object: <<~C,
      /* CA_OBJECT nearest (view_flat addr): minimum of
         query_val.distance(cell), compared with `<`. */
      result = (ca_size_t) -1;
      VALUE best = Qnil;
      for ( ca_size_t i = 0; i < slab_n; i++ ) {
        if ( mask_in && mask_in[i * slab_mask_stride] ) continue;
        T_LOAD v = *(T_LOAD *)(slab_ptr + i * slab_stride);
        VALUE dist = rb_funcall(query_val, rb_intern("distance"), 1, v);
        if ( NIL_P(best) || RTEST(rb_funcall(dist, rb_intern("<"), 1, best)) ) {
          best = dist; result = i;
        }
      }
      (void) query_eps;
    C
  },
  no_match:  "-1",
  undef_no_match: true,
  mask_self: :skip,
  fallback:  :raise,
  semantics: :view_flat

# ---- LINEAR_INTERP_AXIS (L.1, PROPOSAL_LINEAR_INTERP_AXIS rev2) ----------
#
# Per-axis 1-D linear interpolation family, replacing legacy section /
# section_linear / vectorized_section{,_linear} / fetch_linear_addr{,_*} /
# find_linear_addr_* (8 methods).  Three kernels:
#
#   linear_section_binary -- sorted self + val -> fractional index,
#                            binary-search backend (= legacy `linear_index`
#                            helper, ext/carray_order.c line 1233)
#   linear_section_linear -- self + val -> fractional index, linear-scan
#                            backend (= legacy `linear_index_linear`, line 1491)
#   linear_fetch          -- self + addr (fractional idx) -> interpolated
#                            value (= legacy `fetch_linear_addr`, line 1684)
#
# All three: data_type = CA_FLOAT64 fixed (source: [:f64], output: :f64).
# Integer self is cast in the Ruby wrapper (lib/carray/ordering.rb).
#
# No-match sentinel = NaN.  Scalar return path uses isnan() detection
# (= via the no_match_check: DSL hook added in L.1) to return Qnil.
# Array return path leaves NaN in the output cell (= matches existing
# search family pattern, no mask creation; future work per §2.6).
#
# SLAB API (= MkKernel.search form) chosen per §3.5 Reject: FIBER catalog
# adoption is out of scope.  F.7 phase (Landed 2026-06-07) confirmed SLAB
# verdict for the same kind of early-break + scalar-output kernels.

MkKernel.search :linear_section_binary,
  source:         [:f64],
  output:         :f64,
  no_match:       "NAN",
  no_match_check: "isnan(op[0])",
  mask_self:      :raise,
  mask_query:     :undef,
  body: <<~C,
    result = NAN;
    if ( slab_n <= 1 ) {
      result = 0.0;
    }
    else {
      double y0 = *(double *)(slab_ptr + 0 * slab_stride);
      double yn = *(double *)(slab_ptr + (slab_n - 1) * slab_stride);
      int ascending = ( yn >= y0 );   /* grid direction (monotonic assumed) */
      ca_size_t x1 = 0;
      int       found = 0;

      /* At or beyond an endpoint -> use the boundary segment.  An exact
       * endpoint yields a valid index (0 or slab_n-1); a query genuinely
       * outside the grid yields an index outside [0, slab_n-1] that the
       * final range check below turns into NaN (no extrapolation).
       * Comparisons are direction-aware so descending grids route
       * interior values into the search below, not into a boundary case. */
      if ( ascending ? (query_val <= y0) : (query_val >= y0) ) {
        x1 = 0; found = 1;
      }
      else if ( ascending ? (query_val >= yn) : (query_val <= yn) ) {
        x1 = slab_n - 2; found = 1;
      }
      else {
        /* equispaced lucky-guess (ratio + bracket test are direction-safe) */
        if ( yn != y0 ) {
          double  gd = (query_val - y0) / (yn - y0) * (double)(slab_n - 1);
          if ( gd >= 0.0 && gd < (double)(slab_n - 1) ) {
            ca_size_t ag = (ca_size_t) gd;
            double yga  = *(double *)(slab_ptr + ag * slab_stride);
            double ygb  = *(double *)(slab_ptr + (ag + 1) * slab_stride);
            if ( (yga - query_val) * (ygb - query_val) <= 0 ) {
              x1 = ag; found = 1;
            }
          }
        }
        if ( ! found ) {
          /* binary section: the bracket test (ya-q)*(yc-q) <= 0 holds for
           * both ascending and descending grids, so no direction handling
           * is needed here.  The query is guaranteed interior (endpoints
           * handled above), hence the bracket always converges. */
          ca_size_t a = 0, b = slab_n - 1;
          double    ya = y0;
          while ( (b - a) > 1 ) {
            ca_size_t c  = (a + b) / 2;
            double    yc = *(double *)(slab_ptr + c * slab_stride);
            if ( (ya - query_val) * (yc - query_val) <= 0 ) { b = c; }
            else { a = c; ya = yc; }
          }
          x1 = a; found = 1;
        }
      }

      if ( found ) {
        double y1 = *(double *)(slab_ptr + x1 * slab_stride);
        double y2 = *(double *)(slab_ptr + (x1 + 1) * slab_stride);
        double rest = (query_val - y1) / (y2 - y1);
        if ( y2 != 0.0 && fabs(y2 - query_val) / fabs(y2) < DBL_EPSILON * 100 ) {
          result = (double)(x1 + 1);
        }
        else if ( y1 != 0.0 && fabs(y1 - query_val) / fabs(y1) < DBL_EPSILON * 100 ) {
          result = (double) x1;
        }
        else {
          result = rest + (double) x1;
        }
      }

      /* Out of range -> no answer (NaN).  linear_section's codomain is
       * [0, slab_n-1]; an index outside it means the query lies beyond
       * the grid.  Keeps :binary and :linear in agreement and matches
       * linear_fetch's valid range.  Extrapolation, if ever needed, is a
       * future opt-in rather than the default. */
      if ( result < 0.0 || result > (double)(slab_n - 1) ) {
        result = NAN;
      }
    }
  C
  fallback: :raise

MkKernel.search :linear_section_linear,
  source:         [:f64],
  output:         :f64,
  no_match:       "NAN",
  no_match_check: "isnan(op[0])",
  mask_self:      :raise,
  mask_query:     :undef,
  body: <<~C,
    result = NAN;
    if ( slab_n <= 1 ) {
      result = 0.0;
    }
    else {
      ca_size_t x1 = 0;
      int       found = 0;
      for ( ca_size_t k = 0; k < slab_n - 1; k++ ) {
        double yk  = *(double *)(slab_ptr + k * slab_stride);
        double yk1 = *(double *)(slab_ptr + (k + 1) * slab_stride);
        if ( (query_val - yk) * (query_val - yk1) <= 0 ) {
          x1 = k; found = 1; break;
        }
      }
      if ( found ) {
        double y1 = *(double *)(slab_ptr + x1 * slab_stride);
        double y2 = *(double *)(slab_ptr + (x1 + 1) * slab_stride);
        result = (query_val - y1) / (y2 - y1) + (double) x1;
      }

      /* Shared family invariant: result is in [0, slab_n-1] or NaN.  The
       * scan above only brackets adjacent pairs, so this never fires for an
       * in-range query; out-of-range queries already left result = NaN.
       * Kept explicit so :binary and :linear share one out-of-range rule. */
      if ( result < 0.0 || result > (double)(slab_n - 1) ) {
        result = NAN;
      }
    }
  C
  fallback: :raise

MkKernel.search :linear_fetch,
  source:         [:f64],
  output:         :f64,
  no_match:       "NAN",
  no_match_check: "isnan(op[0])",
  mask_self:      :raise,
  mask_query:     :undef,
  body: <<~C,
    result = NAN;
    if ( slab_n >= 1 && query_val >= 0.0 && query_val <= (double)(slab_n - 1) ) {
      ca_size_t il = (ca_size_t) floor(query_val);
      ca_size_t iu = (ca_size_t) ceil(query_val);
      double    w  = query_val - floor(query_val);
      double    yl = *(double *)(slab_ptr + il * slab_stride);
      double    yu = *(double *)(slab_ptr + iu * slab_stride);
      result = yu * w + yl * (1.0 - w);
    }
  C
  fallback: :raise

# ---- P.5b.1: math family (monop / monfunc / binop / moncmp / bincmp) ----
#
# Phase 5b B1: migrate eager math kernel declarations from
# ext/carray_math.rb to mkkernel.rb so a single op definition emits both
# the eager surface (= `rb_ca_<name>` + `ca_<form>_<name>[CA_NTYPE]`
# table) AND, via ca_<form>_dispatch.c which extern-references the
# tables, the lazy (CAMonOp / CABinOp / CAMonCmp / CABinCmp) dispatch
# path.  Calling convention preserved (= ABI unchanged).
#
# PoC: zero (= simplest monop).  Subsequent sub-steps migrate the
# remaining 82 declarations.

MkKernel.monop :zero,
  source: MkKernel::MATH_TYPES,
  expr:   {
    bool:    "(#2) = 0;",
    numeric: "(#2) = 0;",
    complex: "(#2) = 0.0;",
    object:  "(#2) = INT2FIX(0);",
  }

MkKernel.monop :one,
  source: MkKernel::MATH_TYPES,
  expr:   {
    bool:    "(#2) = 1;",
    numeric: "(#2) = 1;",
    complex: "(#2) = 1.0;",
    object:  "(#2) = INT2FIX(1);",
  }

MkKernel.monop :frac,
  source: (MkKernel::ALL_NUMERIC + [:object]),
  expr:   {
    int:     "(#2) = 0;",
    float:   "(#2) = ((#1)>0.0) ? (#1)-floor(#1) : ((#1)<0.0) ? (#1)-ceil(#1) : (#1);",
    object:  '(#2) = rb_funcall((#1), rb_intern("frac"), 0);',
  }

MkKernel.monop :neg,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    numeric: "(#2) = -(#1);",
    complex: "(#2) = -(#1);",
    object:  '(#2) = rb_funcall((#1), rb_intern("-@"), 0);',
  }

MkKernel.monop :bit_neg,
  source: (MkKernel::INT_DTYPES + [:bool, :object]),
  expr:   {
    bool:    "(#2) = (#1) ? 0 : 1;",
    int:     "(#2) = ~(#1);",
    object:  '(#2) = rb_funcall((#1), rb_intern("~"), 0);',
  }

MkKernel.alias_monop :"-@", :neg
MkKernel.alias_monop :"~",  :bit_neg

MkKernel.monop :abs_i,
  source: MkKernel::MATH_TYPES,
  expr:   {
    MkKernel::SINT_SMALL_DTYPES => "(#2) = abs(#1);",
    MkKernel::SINT64_DTYPES     => "(#2) = llabs(#1);",
    MkKernel::UINT_DTYPES       => "(#2) = (#1);",
    MkKernel::FLOAT_DTYPES      => "(#2) = fabs((float64_t)#1);",
    MkKernel::CMPLX_DTYPES      => "(#2) = cabs((cmplx128_t)#1);",
    [:object]                   => '(#2) = rb_funcall((#1), rb_intern("abs"), 0);',
  }

# abs: data_type-changing monop (the framework-piece test customer for monop
# Hash output form).  numeric input -> preserve data_type (= int/float abs),
# complex input -> f64 output (= magnitude is real).  Replaces the hand-
# written rb_ca_abs / rb_ca_abs_bang in ext/carray_math.c.  Object data_type
# kept on abs_i (= bind: false on object would need a different output
# rule; deferred).  The abs_i monop above remains the primary kernel for
# Ruby surface that needs cmplx-in/cmplx-out magnitude-with-imag-zero
# (= used by .real chain composition); abs is the user-facing op that
# returns the real-valued magnitude entity.
MkKernel.monop :abs,
  source: MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  output: { numeric: :preserve, complex: :f64 },
  expr:   {
    MkKernel::SINT_SMALL_DTYPES => "(#2) = abs(#1);",
    MkKernel::SINT64_DTYPES     => "(#2) = llabs(#1);",
    MkKernel::UINT_DTYPES       => "(#2) = (#1);",
    MkKernel::FLOAT_DTYPES      => "(#2) = fabs(#1);",
    MkKernel::CMPLX_DTYPES      => "(#2) = cabs(#1);",   # complex -> double (real magnitude)
  }

# abs2: squared magnitude.  For real x this is x*x (identical to :square
# on real inputs); for complex z it is creal(z)^2 + cimag(z)^2 without
# the cabs() sqrt.  Provided as a first-class primitive so that code
# working over either real or complex arrays can use the same idiom, and
# so that "distance squared" style expressions (Mandelbrot escape,
# optics, signal processing) do not pay for a sqrt they immediately
# square away.
#
# Output data_type follows :abs: numeric preserved, complex -> f64.
MkKernel.monop :abs2,
  source: MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  output: { numeric: :preserve, complex: :f64 },
  expr:   {
    numeric: "(#2) = (#1) * (#1);",
    complex: "{ double _r = creal(#1); double _i = cimag(#1); (#2) = _r * _r + _i * _i; }",
  }

MkKernel.monop :conj,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    numeric: "(#2) = (#1);",
    complex: "(#2) = conj(#1);",
    object:  '(#2) = rb_funcall((#1), rb_intern("conj"), 0);',
  }

# arg: data_type-changing monop — phase angle of the complex plane.
# Mathematically `arg(z)` for z = re + im*i is `atan2(im, re)` in
# (-pi, pi].  Real inputs are treated as z = x + 0i, so:
#   x > 0 -> 0
#   x < 0 -> pi
#   x = 0 -> 0 (carg convention; -0.0 gives pi via standard carg)
# Replaces the hand-written rb_ca_arg in ext/carray_numeric.c (which
# was f64-only, float-or-complex parent, also computed `carg`).
#
# Output data_type is always CA_FLOAT64.
# We do NOT use the abs Hash pattern `{numeric: :preserve}` because
# pi does not fit any integer slot — preserving int data_type would
# silently truncate `arg(-1) = pi` to 3.  Float32 input also returns
# f64 since carg itself returns double.
#
# 3.0 breaking (vs hand-written rb_ca_arg):
#   - integer input is now accepted (was a raise).  Returns f64
#     0 / pi by sign via carg semantics.
# sign: element-wise sign (signum) function — mathematically correct
# across all numeric data_types, including complex.  Replaces the
# multi-pass Ruby `def sign` in lib/carray/math.rb which:
#   - did 3-4 passes (zero + lt(0) + gt(0) + is_nan masks)
#   - was incorrect for complex (treated `z < 0` as scalar order, which
#     is undefined for the complex field)
#
# Semantics (mathematical signum):
#   signed int   x > 0 -> 1, x < 0 -> -1, x == 0 -> 0
#   unsigned int x > 0 -> 1,             x == 0 -> 0   (no negatives)
#   bool         true -> 1, false -> 0
#   float        +Inf -> 1, -Inf -> -1, NaN -> NaN, otherwise like int
#   complex      z == 0 -> 0, otherwise z / |z|  (unit vector on
#                                                 the unit circle)
#
# Output data_type preserves the input data_type for all source kinds (= a
# single CArray of the same type holds the result; for complex the
# unit-vector lives in the same complex slot).
MkKernel.monop :sign,
  source: [:bool] + MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  expr:   {
    bool:                          "(#2) = (#1) ? 1 : 0;",
    MkKernel::UINT_DTYPES       => "(#2) = ((#1) > 0) ? 1 : 0;",
    MkKernel::SINT_DTYPES       => "(#2) = ((#1) > 0) - ((#1) < 0);",
    MkKernel::FLOAT_DTYPES      => "(#2) = isnan(#1) ? (#1) : (((#1) > 0) - ((#1) < 0));",
    MkKernel::CMPLX_DTYPES      => "{ double _m = cabs(#1); (#2) = (_m == 0.0) ? 0 : ((#1) / _m); }",
  }

MkKernel.monop :arg,
  source: MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  output: { numeric: :f64, complex: :f64 },
  expr:   {
    numeric: "(#2) = carg((cmplx128_t)(#1));",
    complex: "(#2) = carg(#1);",
  }

# imag_i: data_type-preserving kernel that places the imag part in the
# slot (= cimag for complex stores into the real component since cmplx
# assignment from a double zeros the imag; 0 for non-complex).  Used as
# the first node in the lazy `.imag` chain: numeric returns all-zero,
# complex returns CAMonOp(imag_i) -> CAMonOp(cast_<float>) producing
# the original imaginary as a float array.  Same pattern as abs_i;
# higher-level `.imag` Ruby method (lib/carray/math.rb) keeps the eager
# CAField path for entity parents and uses CAMonOp chains for lazy.
MkKernel.monop :imag_i,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    numeric: "(#2) = 0;",
    complex: "(#2) = cimag(#1);",
    object:  '(#2) = rb_funcall((#1), rb_intern("imaginary"), 0);',
  }

# arg_i: data_type-preserving kernel that writes the complex argument
# (phase angle) into the slot.  For complex input, cassignment from a
# double zeros the imag, so cimag stays 0 (same trick as abs_i / imag_i);
# a chain cast_<float> node then extracts the real part.  For float
# input, the value is written directly.  Used as the first node in the
# lazy `.arg` chain (lib/carray/lazy.rb).
#
# The public data_type-changing `arg` kernel above stays for the eager
# path via rb_ca_call_monop_typed; arg_i is the lazy substrate variant
# that fits CAMonOp's cast-before invariant.
MkKernel.monop :arg_i,
  source: MkKernel::FLOAT_DTYPES + MkKernel::CMPLX_DTYPES,
  expr:   {
    [:f32]      => "(#2) = (float)carg((cmplx128_t)(#1));",
    [:f64]      => "(#2) = carg((cmplx128_t)(#1));",
    [:cmplx64]  => "(#2) = (float)carg((cmplx128_t)(#1));",
    [:cmplx128] => "(#2) = carg(#1);",
  }

MkKernel.monop :not,
  source: [:bool, :object],
  expr:   {
    bool:   "(#2) = (#1) ? 0 : 1;",
    object: "(#2) = (RTEST(#1)) ? Qfalse : Qtrue;",
  }

# ---- monfunc: float-family kernels with automatic integer auto-cast --

MkKernel.monfunc :rad,
  source: MkKernel::FLOAT_DTYPES + [:object],
  expr:   {
    float:  "(#2) = (0.0174532925199433*(#1));",
    object: MkKernel.obj_float_math("0.0174532925199433 * (<v>)", "rad"),
  }

MkKernel.monfunc :deg,
  source: MkKernel::FLOAT_DTYPES + [:object],
  expr:   {
    float:  "(#2) = (57.2957795130823*(#1));",
    object: MkKernel.obj_float_math("57.2957795130823 * (<v>)", "deg"),
  }

MkKernel.monfunc :ceil,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#2) = (#1);",
    float:  "(#2) = ceil(#1);",
    object: '(#2) = rb_funcall((#1), rb_intern("ceil"), 0);',
  }

MkKernel.monfunc :floor,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#2) = (#1);",
    float:  "(#2) = floor(#1);",
    object: '(#2) = rb_funcall((#1), rb_intern("floor"), 0);',
  }

MkKernel.monfunc :round,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#2) = (#1);",
    float:  "(#2) = ((#1)>0.0) ? floor((#1)+0.5) : ((#1)<0.0) ? ceil((#1)-0.5) : (#1);",
    object: '(#2) = rb_funcall((#1), rb_intern("round"), 0);',
  }

MkKernel.monfunc :rcp,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "if ((#1)==0) {ca_zerodiv();}; (#2) = 1/(#1);",
    float:   "(#2) = 1/(#1);",
    complex: "(#2) = 1/(#1);",
    object:  '(#2) = rb_funcall(INT2NUM(1), rb_intern("/"), 1, (#1));',
  }

# ---- transcendental family: float + complex + object via OBJ_FLOAT_MATH

{
  sqrt:  "sqrt",
  exp:   "exp",
  log:   "log",
  sin:   "sin",
  cos:   "cos",
  tan:   "tan",
  asin:  "asin",
  acos:  "acos",
  atan:  "atan",
}.each do |op, c_fn|
  MkKernel.monfunc op,
    source: MkKernel::FLOAT_DTYPES + MkKernel::CMPLX_DTYPES + [:object],
    expr:   {
      float:   "(#2) = #{c_fn}(#1);",
      complex: "(#2) = c#{c_fn}(#1);",
      object:  MkKernel.obj_float_math("#{c_fn}(<v>)", c_fn),
    }
end

# exp2 special case: complex variant uses cpow(2, x), not cexp2 (which
# isn't standardized in C99/POSIX).
MkKernel.monfunc :exp2,
  source: MkKernel::FLOAT_DTYPES + MkKernel::CMPLX_DTYPES + [:object],
  expr:   {
    float:   "(#2) = exp2(#1);",
    complex: "(#2) = cpow(2, (#1));",
    object:  MkKernel.obj_float_math("exp2(<v>)", "exp2"),
  }

# log10, log2, logb: no complex variant in the original mkmath emit
{
  log10: "log10",
  log2:  "log2",
  logb:  "logb",
}.each do |op, c_fn|
  MkKernel.monfunc op,
    source: MkKernel::FLOAT_DTYPES + [:object],
    expr:   {
      float:  "(#2) = #{c_fn}(#1);",
      object: MkKernel.obj_float_math("#{c_fn}(<v>)", c_fn),
    }
end

# exp10: special object expr (= bypass OBJ_FLOAT_MATH for the
# non-numeric branch which uses INT2NUM(10) ** arg).
MkKernel.monfunc :exp10,
  source: MkKernel::FLOAT_DTYPES + MkKernel::CMPLX_DTYPES + [:object],
  expr:   {
    float:   "(#2) = pow(10, (#1));",
    complex: "(#2) = cpow(10, (#1));",
    object:  <<~SNIPPET,
      {
        VALUE _obj_arg = (#1);
        if (RB_FLOAT_TYPE_P(_obj_arg) || RB_INTEGER_TYPE_P(_obj_arg) || RB_TYPE_P(_obj_arg, T_RATIONAL)) {
          (#2) = DBL2NUM(pow(10, NUM2DBL(_obj_arg)));
        } else {
          (#2) = rb_funcall(INT2NUM(10), rb_intern("**"), 1, _obj_arg);
        }
      }
    SNIPPET
  }

# Hyperbolic family: complex variant uses the real-typed C function
# (matches original mkmath emit, which doesn't prefix `c`).
{
  sinh:  "sinh",
  cosh:  "cosh",
  tanh:  "tanh",
  asinh: "asinh",
  acosh: "acosh",
  atanh: "atanh",
}.each do |op, c_fn|
  MkKernel.monfunc op,
    source: MkKernel::FLOAT_DTYPES + MkKernel::CMPLX_DTYPES + [:object],
    expr:   {
      float:   "(#2) = #{c_fn}(#1);",
      complex: "(#2) = #{c_fn}(#1);",
      object:  MkKernel.obj_float_math("#{c_fn}(<v>)", c_fn),
    }
end

# ---- M.1 (PyTorch alignment): additional monfunc / monop ------------------

# expm1, log1p: float + object only (C99 doesn't standardise complex
# variants).  Widening monfunc — integer input auto-casts to f64.
{
  expm1: "expm1",
  log1p: "log1p",
}.each do |op, c_fn|
  MkKernel.monfunc op,
    source: MkKernel::FLOAT_DTYPES + [:object],
    expr:   {
      float:  "(#2) = #{c_fn}(#1);",
      object: MkKernel.obj_float_math("#{c_fn}(<v>)", c_fn),
    }
end

# rsqrt: 1 / sqrt(x).  float + complex + object (complex via 1.0 / csqrt).
MkKernel.monfunc :rsqrt,
  source: MkKernel::FLOAT_DTYPES + MkKernel::CMPLX_DTYPES + [:object],
  expr:   {
    float:   "(#2) = 1.0 / sqrt(#1);",
    complex: "(#2) = 1.0 / csqrt(#1);",
    object:  MkKernel.obj_float_math("1.0 / sqrt(<v>)", "rsqrt"),
  }

# trunc: toward-zero rounding.  Preserve-data_type form like ceil / floor /
# round — int branch is identity, float branch uses C99 trunc, object
# delegates to #truncate (Ruby's standard name).
MkKernel.monfunc :trunc,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#2) = (#1);",
    float:  "(#2) = trunc(#1);",
    object: '(#2) = rb_funcall((#1), rb_intern("truncate"), 0);',
  }

# square: x * x.  Preserve-data_type monop, all numeric (including
# complex which has natural * semantics).
MkKernel.monop :square,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    numeric: "(#2) = (#1) * (#1);",
    complex: "(#2) = (#1) * (#1);",
    object:  '(#2) = rb_funcall((#1), rb_intern("*"), 1, (#1));',
  }

# ---- M.4: angle normalisation migration from carray_mathfunc.c -----------
#
# deg_360 / deg_180 / rad_2pi / rad_pi: fold an angle into a half-open
# canonical range.  These were hand-written in ext/carray_mathfunc.c
# with f64-forced input/output via ca_call_cfunc_1_1; the mkkernel form
# preserves the same numeric behaviour but rides the lazy substrate +
# kernel_iterator engine.  Widening monfunc: integer input auto-casts
# to f64, float input preserves dtype.

# deg_360: fold into [0, 360).  Use double-typed local for the fold
# computation regardless of input precision (matches legacy hand-written
# semantic; f32 input widens to double via assignment).
MkKernel.monfunc :deg_360,
  source: MkKernel::FLOAT_DTYPES + [:object],
  expr:   {
    float:  <<~C,
      {
        double _a = (double)(#1);
        double _fa = _a / 360.0;
        (#2) = (_a >= 0)
                 ? (_fa - floor(_fa)) * 360.0
                 : (_fa - ceil(_fa) + 1.0) * 360.0;
      }
    C
    object: <<~SNIPPET,
      {
        VALUE _obj_arg = (#1);
        if (RB_FLOAT_TYPE_P(_obj_arg) || RB_INTEGER_TYPE_P(_obj_arg) || RB_TYPE_P(_obj_arg, T_RATIONAL)) {
          double _a = NUM2DBL(_obj_arg);
          double _fa = _a / 360.0;
          (#2) = DBL2NUM((_a >= 0) ? (_fa - floor(_fa)) * 360.0
                                    : (_fa - ceil(_fa) + 1.0) * 360.0);
        } else {
          (#2) = rb_funcall(_obj_arg, rb_intern("deg_360"), 0);
        }
      }
    SNIPPET
  }

# deg_180: fold into [-180, 180).  Preserves trailing `if (b <= -180)
# b += 360` guard from the legacy implementation.
MkKernel.monfunc :deg_180,
  source: MkKernel::FLOAT_DTYPES + [:object],
  expr:   {
    float:  <<~C,
      {
        double _a = (double)(#1);
        double _fa = (_a + 180.0) / 360.0;
        double _b = (_a >= 0)
                      ? (_fa - floor(_fa)) * 360.0 - 180.0
                      : (_fa - ceil(_fa))  * 360.0 - 180.0;
        if (_b <= -180.0) _b += 360.0;
        (#2) = _b;
      }
    C
    object: <<~SNIPPET,
      {
        VALUE _obj_arg = (#1);
        if (RB_FLOAT_TYPE_P(_obj_arg) || RB_INTEGER_TYPE_P(_obj_arg) || RB_TYPE_P(_obj_arg, T_RATIONAL)) {
          double _a = NUM2DBL(_obj_arg);
          double _fa = (_a + 180.0) / 360.0;
          double _b = (_a >= 0) ? (_fa - floor(_fa)) * 360.0 - 180.0
                                : (_fa - ceil(_fa))  * 360.0 - 180.0;
          if (_b <= -180.0) _b += 360.0;
          (#2) = DBL2NUM(_b);
        } else {
          (#2) = rb_funcall(_obj_arg, rb_intern("deg_180"), 0);
        }
      }
    SNIPPET
  }

# rad_2pi: fold into [0, 2pi).
MkKernel.monfunc :rad_2pi,
  source: MkKernel::FLOAT_DTYPES + [:object],
  expr:   {
    float:  <<~C,
      {
        double _two_pi = 2.0 * M_PI;
        double _a = (double)(#1);
        double _fa = _a / _two_pi;
        (#2) = (_a >= 0)
                 ? (_fa - floor(_fa)) * _two_pi
                 : (_fa - ceil(_fa) + 1.0) * _two_pi;
      }
    C
    object: <<~SNIPPET,
      {
        VALUE _obj_arg = (#1);
        if (RB_FLOAT_TYPE_P(_obj_arg) || RB_INTEGER_TYPE_P(_obj_arg) || RB_TYPE_P(_obj_arg, T_RATIONAL)) {
          double _two_pi = 2.0 * M_PI;
          double _a = NUM2DBL(_obj_arg);
          double _fa = _a / _two_pi;
          (#2) = DBL2NUM((_a >= 0) ? (_fa - floor(_fa)) * _two_pi
                                    : (_fa - ceil(_fa) + 1.0) * _two_pi);
        } else {
          (#2) = rb_funcall(_obj_arg, rb_intern("rad_2pi"), 0);
        }
      }
    SNIPPET
  }

# rad_pi: fold into [-pi, pi).
MkKernel.monfunc :rad_pi,
  source: MkKernel::FLOAT_DTYPES + [:object],
  expr:   {
    float:  <<~C,
      {
        double _two_pi = 2.0 * M_PI;
        double _a = (double)(#1);
        double _fa = (_a + M_PI) / _two_pi;
        double _b = (_a >= 0)
                      ? (_fa - floor(_fa)) * _two_pi - M_PI
                      : (_fa - ceil(_fa))  * _two_pi - M_PI;
        if (_b <= -M_PI) _b += _two_pi;
        (#2) = _b;
      }
    C
    object: <<~SNIPPET,
      {
        VALUE _obj_arg = (#1);
        if (RB_FLOAT_TYPE_P(_obj_arg) || RB_INTEGER_TYPE_P(_obj_arg) || RB_TYPE_P(_obj_arg, T_RATIONAL)) {
          double _two_pi = 2.0 * M_PI;
          double _a = NUM2DBL(_obj_arg);
          double _fa = (_a + M_PI) / _two_pi;
          double _b = (_a >= 0) ? (_fa - floor(_fa)) * _two_pi - M_PI
                                : (_fa - ceil(_fa))  * _two_pi - M_PI;
          if (_b <= -M_PI) _b += _two_pi;
          (#2) = DBL2NUM(_b);
        } else {
          (#2) = rb_funcall(_obj_arg, rb_intern("rad_pi"), 0);
        }
      }
    SNIPPET
  }

# ---- P.5b.3: binop family --------------------------------------------------

# Pair-wise max / min — three flavours:
#
#   pmax / pmin      CArray legacy names (kept for backwards compat),
#                    NaN-skip semantics via C99 fmax / fmin.
#   fmax / fmin      Ruby-level aliases of pmax / pmin (= same kernel,
#                    same NaN-skip behaviour).  Matches the C99 library
#                    function of the same name.
#   maximum / minimum  NaN-propagate semantics: if either operand is
#                    NaN the result is NaN.  Distinct kernel — cannot be
#                    aliased onto pmax.
#
# Integer / object branches are identical across all three (no NaN
# concept).  Only the float branch differs.
MkKernel.binop :pmax,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#3) = (#1) > (#2) ? (#1) : (#2);",
    float:  "(#3) = fmax(#1, #2);",
    object: '(#3) = rb_funcall(rb_assoc_new((#1),(#2)), rb_intern("max"), 0);',
  }

MkKernel.binop :pmin,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#3) = (#1) < (#2) ? (#1) : (#2);",
    float:  "(#3) = fmin(#1, #2);",
    object: '(#3) = rb_funcall(rb_assoc_new((#1),(#2)), rb_intern("min"), 0);',
  }

# NaN-propagate variants.  Float
# branch tests both operands for NaN and short-circuits to NaN; non-
# float branches reuse the comparison form.
MkKernel.binop :maximum,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#3) = (#1) > (#2) ? (#1) : (#2);",
    float:  "(#3) = isnan(#1) ? (#1) : (isnan(#2) ? (#2) : ((#1) > (#2) ? (#1) : (#2)));",
    object: '(#3) = rb_funcall(rb_assoc_new((#1),(#2)), rb_intern("max"), 0);',
  }

MkKernel.binop :minimum,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#3) = (#1) < (#2) ? (#1) : (#2);",
    float:  "(#3) = isnan(#1) ? (#1) : (isnan(#2) ? (#2) : ((#1) < (#2) ? (#1) : (#2)));",
    object: '(#3) = rb_funcall(rb_assoc_new((#1),(#2)), rb_intern("min"), 0);',
  }

# +, -, * use the same generic expression across all numeric data_types.
{
  add: ["+", "+", '"+"'],
  sub: ["-", "-", '"-"'],
  mul: ["*", "*", '"*"'],
}.each do |name, (op, c_op, _ruby_op)|
  MkKernel.binop name,
    op:     op,
    source: MkKernel::MATH_NUMERIC + [:object],
    expr:   {
      numeric: "(#3) = (#1) #{c_op} (#2);",
      complex: "(#3) = (#1) #{c_op} (#2);",
      object:  %{(#3) = rb_funcall((#1), rb_intern("#{op}"), 1, (#2));},
    }
end

MkKernel.binop :div,
  op:     "/",
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "if ((#2)==0) {ca_zerodiv();}; (#3) = (#1) / (#2);",
    float:   "(#3) = (#1) / (#2);",
    complex: "(#3) = (#1) / (#2);",
    object:  '(#3) = rb_funcall((#1), rb_intern("/"), 1, (#2));',
  }

# quo_i (op:nil but registered as method "quo_i" via its name; rb_define
# emits "<name>!" only when op==nil, so we keep "quo_i" callable by
# setting op = "quo_i" explicitly).  Source: OBJ_TYPES only.
MkKernel.binop :quo_i,
  op:     "quo_i",
  source: [:object],
  expr:   {
    object: '(#3) = rb_funcall((#1), rb_intern("quo"), 1, (#2));',
  }

MkKernel.binop :rcp_mul,
  op:     "rcp_mul",
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "if ((#1)==0) {ca_zerodiv();}; (#3) = (#2) / (#1);",
    float:   "(#3) = (#2) / (#1);",
    complex: "(#3) = (#2) / (#1);",
    object:  '(#3) = rb_funcall((#2), rb_intern("/"), 1, (#1));',
  }

MkKernel.binop :mod,
  op:     "%",
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "if ((#2)==0) {ca_zerodiv();}; (#3) = (#1) % (#2);",
    float:  "(#3) = fmod(#1, #2);",
    object: '(#3) = rb_funcall((#1), rb_intern("%"), 1, (#2));',
  }

MkKernel.binop :reminder,
  op:     "reminder",
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "if ((#2)==0) {ca_zerodiv();}; (#3) = (#1) % (#2);",
    float:  "(#3) = remainder(#1, #2);",
    object: '(#3) = rb_funcall((#1), rb_intern("%"), 1, (#2));',
  }

MkKernel.binop :bit_and_i,
  op:     "&",
  kleene: :and,
  source: MkKernel::INT_DTYPES + [:bool, :object],
  expr:   {
    bool:   "(#3) = (#1) & (#2);",
    int:    "(#3) = (#1) & (#2);",
    object: '(#3) = rb_funcall((#1), rb_intern("&"), 1, (#2));',
  }

MkKernel.binop :bit_or_i,
  op:     "|",
  kleene: :or,
  source: MkKernel::INT_DTYPES + [:bool, :object],
  expr:   {
    bool:   "(#3) = (#1) | (#2);",
    int:    "(#3) = (#1) | (#2);",
    object: '(#3) = rb_funcall((#1), rb_intern("|"), 1, (#2));',
  }

MkKernel.binop :bit_xor_i,
  op:     "^",
  source: MkKernel::INT_DTYPES + [:bool, :object],
  expr:   {
    bool:   "(#3) = ((#1) != (#2)) ? 1 : 0;",
    int:    "(#3) = (#1) ^ (#2);",
    object: '(#3) = rb_funcall((#1), rb_intern("^"), 1, (#2));',
  }

MkKernel.binop :bit_lshift,
  op:     "<<",
  source: MkKernel::INT_DTYPES + [:object],
  expr:   {
    int:    "(#3) = (#1) << (#2);",
    object: '(#3) = rb_funcall((#1), rb_intern("<<"), 1, (#2));',
  }

MkKernel.binop :bit_rshift,
  op:     ">>",
  source: MkKernel::INT_DTYPES + [:object],
  expr:   {
    int:    "(#3) = (#1) >> (#2);",
    object: '(#3) = rb_funcall((#1), rb_intern(">>"), 1, (#2));',
  }

# Boolean binops (= direct bind, no Ruby-level coercion).  3.0 breaking:
# the old hand-written rb_ca_and / rb_ca_or / rb_ca_xor wrappers in
# ext/carray_math.c implicitly coerced non-bool operands to boolean
# (via rb_ca_wrap_readonly with CA_BOOLEAN); that auto-coercion is
# removed.  Users now pass boolean CArrays explicitly:
#   a.and(b.as_boolean)   # was: a.and(b) with implicit coerce
# Rationale: CArray's general convention is explicit data_type handling
# (= sum on complex requires explicit cast); auto-coercion on bool ops
# alone was asymmetric and surprising.
MkKernel.binop :and,
  op:     "and",
  source: [:bool, :object],
  expr:   {
    bool:   "(#3) = (#1) && (#2);",
    object: '(#3) = ((RTEST(#1)!=0) && (RTEST(#2)!=0)) ? Qtrue : Qfalse;',
  }

MkKernel.binop :or,
  op:     "or",
  source: [:bool, :object],
  expr:   {
    bool:   "(#3) = (#1) || (#2);",
    object: '(#3) = ((RTEST(#1)!=0) || (RTEST(#2)!=0)) ? Qtrue : Qfalse;',
  }

MkKernel.binop :xor,
  op:     "xor",
  source: [:bool, :object],
  expr:   {
    bool:   "(#3) = (((#1)==0) == ((#2)==0)) ? 0 : 1;",
    object: '(#3) = ((RTEST(#1)) == (RTEST(#2))) ? Qfalse : Qtrue;',
  }

# Binop aliases (= rb_define_alias of the Ruby operator method).
# `fmax` / `fmin` — Ruby-level aliases of `pmax` / `pmin`.  Same
# kernel, same NaN-skip semantics.  Provides a name that C-stdlib
# users will recognise (= `<math.h>` `fmax`).
# NaN-propagate variants are the separate `maximum` / `minimum`
# kernels registered above.
MkKernel.alias_binop :fmax,        :pmax
MkKernel.alias_binop :fmin,        :pmin

MkKernel.alias_binop :add,         :"+"
MkKernel.alias_binop :sub,         :"-"
MkKernel.alias_binop :mul,         :"*"
MkKernel.alias_binop :div,         :"/"
MkKernel.alias_binop :mod,         :"%"
MkKernel.alias_binop :bit_and,     :"&"
MkKernel.alias_binop :bit_or,      :"|"
MkKernel.alias_binop :bit_xor,     :"^"
MkKernel.alias_binop :bit_lshift,  :"<<"
MkKernel.alias_binop :bit_rshift,  :">>"

# P.5b.5: power binop.  Integer variants use `op_powi_<type>` from
# ca_op_powi.h (binary exponentiation, O(log p)).  Float / complex use
# pow / cpow.  Object uses Ruby's `**`.
MkKernel.header_block <<~C
  #include "ca_op_powi.h"
C

# ---- triop family ---------------------------------------------------------

# fma: fused multiply-add — `self * op2 + op3` in a single rounding step
# (= C99 `fma(x, y, z)` and HW FMA3/FMA4 / ARM FMA instructions).  More
# accurate than the equivalent two-op `a*b + c` expression which rounds
# twice.  Used in Horner evaluation, linear interpolation, dot product,
# Newton iteration.
MkKernel.triop :fma,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "(#4) = (#1) * (#2) + (#3);",
    float:   "(#4) = fma((#1), (#2), (#3));",
    complex: "(#4) = (#1) * (#2) + (#3);",
    object:  '(#4) = rb_funcall(rb_funcall((#1), rb_intern("*"), 1, (#2)), rb_intern("+"), 1, (#3));',
  }

# fms: fused multiply-subtract — `self * op2 - op3` in a single rounding.
# Useful in cross products and complex multiplication primitives.
MkKernel.triop :fms,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "(#4) = (#1) * (#2) - (#3);",
    # fma(a, b, -c) = a*b - c with single rounding (= C99 / IEEE 754 hint).
    float:   "(#4) = fma((#1), (#2), -(#3));",
    complex: "(#4) = (#1) * (#2) - (#3);",
    object:  '(#4) = rb_funcall(rb_funcall((#1), rb_intern("*"), 1, (#2)), rb_intern("-"), 1, (#3));',
  }

# clip: per-element clamp into [lo, hi].  3.0 migration: was a hand-
# written eager-only method in ext/carray_generate.c that only accepted
# Numeric scalar bounds; now a proper triop kernel that also accepts
# CArray bounds (= per-element variable lo / hi).
#
# 3.0 breaking notes:
#   - Existing scalar usage `a.clip(0.0, 1.0)` keeps working byte-identically.
#   - NEW: `a.clip(lo_array, hi_array)` (per-element bounds) now supported.
#   - The `fill_value` 3rd positional arg of the old `rb_ca_clip` is
#     NOT carried over (= use `a.clip(lo, hi)[mask] = fill` idiom; the
#     UNDEF-fill case can now be expressed as `out = a.clip(lo, hi);
#     out[a.lt(lo) | a.gt(hi)] = UNDEF`).  Pinned in test.
#
# Bound at the C level as `__clip_ki__` (private kernel entry).  The
# public `CArray#clip` is a Ruby wrapper in lib/carray/math.rb that
# restores the rich pre-3.0 API surface (nil-bound one-sided clip +
# optional fill).  `clip!` is retired in 3.0 (view-by-default
# convention) so the bang form is suppressed via `bang: false`.
MkKernel.triop :clip,
  op:     "__clip_ki__",
  bang:   false,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    int:    "(#4) = ((#1) < (#2)) ? (#2) : (((#1) > (#3)) ? (#3) : (#1));",
    # Float branch uses `fmax / fmin` so the compiler can autovectorise
    # the inner loop to SIMD max / min instructions.  The leading
    # isnan(#1) guard preserves NaN; without it fmin/fmax would silently
    # turn NaN into lo or hi (= C99 fmin/fmax skip NaN).  Branchless
    # besides the NaN check, so a
    # NaN-free hot loop still vectorises.
    float:  "(#4) = isnan(#1) ? (#1) : fmin(fmax((#1), (#2)), (#3));",
    object: '{ VALUE _v=(#1); ' \
            'if (rb_funcall(_v, rb_intern("<"), 1, (#2))) _v=(#2); ' \
            'else if (rb_funcall(_v, rb_intern(">"), 1, (#3))) _v=(#3); ' \
            '(#4) = _v; }',
  }

MkKernel.binop :power,
  op:     :power,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "(#3) = op_powi_<type>((#1), (#2));",
    float:   "(#3) = pow((#1), (#2));",
    complex: "(#3) = cpow((#1), (#2));",
    object:  '(#3) = rb_funcall((#1), rb_intern("**"), 1, (#2));',
  }

# ---- M.2 + M.3 (PyTorch alignment): float-only binop family --------------
#
# These C99 / POSIX library binops have no complex counterpart and no
# meaningful integer semantic — integer input is rejected at the kernel
# table layer (= caller must cast to f64 explicitly).  Method-form on
# CArray follows PyTorch's tensor-method convention (= y.atan2(x) for
# atan2's y-first math convention; symmetric ops are unambiguous).  The
# `CAMath.<op>(...)` module-function form is registered in
# carray_math.rb.

{
  copysign:  ["copysign",  "copysign"],
  logaddexp: [nil,         nil],          # custom expr — see below
  nextafter: ["nextafter", "nextafter"],
  fmod:      ["fmod",      "fmod"],
  atan2:     ["atan2",     "atan2"],
  hypot:     ["hypot",     "hypot"],
}.each do |op_name, (c_fn, ruby_fb)|
  next if c_fn.nil?  # logaddexp handled separately
  MkKernel.binop op_name,
    source: MkKernel::FLOAT_DTYPES + [:object],
    expr:   {
      float:  "(#3) = #{c_fn}((#1), (#2));",
      object: <<~SNIPPET,
        {
          VALUE _l = (#1);
          VALUE _r = (#2);
          if ((RB_FLOAT_TYPE_P(_l) || RB_INTEGER_TYPE_P(_l) || RB_TYPE_P(_l, T_RATIONAL)) &&
              (RB_FLOAT_TYPE_P(_r) || RB_INTEGER_TYPE_P(_r) || RB_TYPE_P(_r, T_RATIONAL))) {
            (#3) = DBL2NUM(#{c_fn}(NUM2DBL(_l), NUM2DBL(_r)));
          } else {
            (#3) = rb_funcall(_l, rb_intern(#{ruby_fb.inspect}), 1, _r);
          }
        }
      SNIPPET
    }
end

# logaddexp: log(exp(x) + exp(y)).  Numerically stable form:
#   max(x, y) + log1p(exp(-|x - y|))
# avoids overflow when x or y is large.
MkKernel.binop :logaddexp,
  source: MkKernel::FLOAT_DTYPES + [:object],
  expr:   {
    float:  "(#3) = fmax((#1), (#2)) + log1p(exp(-fabs((#1) - (#2))));",
    object: <<~SNIPPET,
      {
        VALUE _l = (#1);
        VALUE _r = (#2);
        if ((RB_FLOAT_TYPE_P(_l) || RB_INTEGER_TYPE_P(_l) || RB_TYPE_P(_l, T_RATIONAL)) &&
            (RB_FLOAT_TYPE_P(_r) || RB_INTEGER_TYPE_P(_r) || RB_TYPE_P(_r, T_RATIONAL))) {
          double _lx = NUM2DBL(_l), _rx = NUM2DBL(_r);
          double _mx = (_lx > _rx) ? _lx : _rx;
          double _df = fabs(_lx - _rx);
          (#3) = DBL2NUM(_mx + log1p(exp(-_df)));
        } else {
          (#3) = rb_funcall(_l, rb_intern("logaddexp"), 1, _r);
        }
      }
    SNIPPET
  }

# ---- P.5b.4: moncmp family (predicates returning bool) ----------------

MkKernel.moncmp :is_nan,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "(#2) = 0;",
    float:   "(#2) = isnan(#1);",
    complex: "(#2) = (isnan(creal(#1)) || isnan(cimag(#1)));",
    object:  '(#2) = rb_funcall((#1), rb_intern("nan?"), 0);',
  }

MkKernel.moncmp :is_inf,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "(#2) = 0;",
    float:   "(#2) = isinf(#1);",
    complex: "(#2) = (isinf(creal(#1)) || isinf(cimag(#1)));",
    object:  '(#2) = rb_funcall((#1), rb_intern("infinite?"), 0);',
  }

MkKernel.moncmp :is_finite,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    int:     "(#2) = 1;",
    float:   "(#2) = isfinite(#1);",
    complex: "(#2) = (isfinite(creal(#1)) && isfinite(cimag(#1)));",
    object:  '(#2) = rb_funcall((#1), rb_intern("finite?"), 0);',
  }

# is_invalid = !is_finite (MS.1 mask SET family redesign): NaN or Inf
# predicate. For integer / bool data_types always false (mirrors is_finite
# always true).  Object delegates to ! finite?.  bool included to
# preserve legacy hand-written rb_ca_is_invalid coverage (= ALL_NUMERIC
# alone misses :bool).
MkKernel.moncmp :is_invalid,
  source: [:bool] + MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    bool:    "(#2) = 0;",
    int:     "(#2) = 0;",
    float:   "(#2) = (!isfinite(#1));",
    complex: "(#2) = (!isfinite(creal(#1)) || !isfinite(cimag(#1)));",
    object:  '(#2) = (RTEST(rb_funcall((#1), rb_intern("finite?"), 0)) ? 0 : 1);',
  }

# M.1: signbit — sign-bit test, true for negative values (including
# -0.0).  Integer branch: sint = (#1) < 0, uint = always 0.  Float branch
# uses C99 signbit (handles -0.0 / NaN sign correctly).  No complex
# variant (signbit on a complex is ambiguous; rejected at this layer).
# `:sint` / `:uint` aren't family aliases — use array-of-dtypes form.
MkKernel.moncmp :signbit,
  source: MkKernel::SINT_DTYPES + MkKernel::UINT_DTYPES +
          MkKernel::FLOAT_DTYPES + [:object],
  expr:   {
    MkKernel::SINT_DTYPES => "(#2) = ((#1) < 0);",
    MkKernel::UINT_DTYPES => "(#2) = 0;",
    float:  "(#2) = signbit(#1);",
    object: '(#2) = (RTEST(rb_funcall((#1), rb_intern("negative?"), 0)) ? 1 : 0);',
  }

# ---- P.5b.4: bincmp family (predicates returning bool) ----------------

# feq: float-only fuzzy equality using <epsilon> placeholder.
MkKernel.bincmp :feq,
  source: MkKernel::FLOAT_DTYPES,
  expr:   {
    float: %{
      <type> f1a = fabs((float64_t) #1);
      <type> f2a = fabs((float64_t) #2);
      <type> fmax = (f1a > f2a) ? f1a : f2a;
      (#3) = ( fabs(((float64_t) #1)-( (float64_t) #2)) <= fmax * <epsilon> ) ? 1 : 0;
    },
  }

# eq, ne, gt, lt, ge, le: support fixlen (= byte-comparison) + bool + numeric
# + complex + object.  The shared structure makes a metaprogramming loop
# the natural form.
{
  eq: {
    op: "eq",
    fixlen: "(#3) = ( b1 == b2 && (! memcmp(p1, p2, b1)) );",
    bool_numeric: "(#3) = ( (#1) == (#2) );",
    complex: "(#3) = (#1) == (#2);",
    object: '(#3) = RTEST(rb_funcall((#1), rb_intern("=="), 1, (#2))) ? 1 : 0;',
  },
  ne: {
    op: "ne",
    fixlen: "(#3) = ( b1 != b2 || memcmp(p1, p2, b1) );",
    bool_numeric: "(#3) = ( (#1) != (#2) );",
    complex: "(#3) = (#1) != (#2);",
    object: '(#3) = RTEST(rb_funcall((#1), rb_intern("=="), 1, (#2))) ? 0 : 1;',
  },
  gt: {
    op: "gt",
    fixlen: %{
      int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2);
      (#3) = ( cmp > 0 || ( cmp == 0 && b1 > b2 ) );
    },
    bool_numeric: "(#3) = ( (#1) > (#2) );",
    object: '(#3) = RTEST(rb_funcall((#1), rb_intern(">"), 1, (#2))) ? 1 : 0;',
  },
  lt: {
    op: "lt",
    fixlen: %{
      int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2);
      (#3) = ( cmp < 0 || ( cmp == 0 && b1 < b2 ) );
    },
    bool_numeric: "(#3) = ( (#1) < (#2) );",
    object: '(#3) = RTEST(rb_funcall((#1), rb_intern("<"), 1, (#2))) ? 1 : 0;',
  },
  ge: {
    op: "ge",
    fixlen: %{
      int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2);
      (#3) = ( cmp > 0 || ( cmp == 0 && b1 >= b2 ) );
    },
    bool_numeric: "(#3) = ( (#1) >= (#2) );",
    object: '(#3) = RTEST(rb_funcall((#1), rb_intern(">="), 1, (#2))) ? 1 : 0;',
  },
  le: {
    op: "le",
    fixlen: %{
      int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2);
      (#3) = ( cmp < 0 || ( cmp == 0 && b1 <= b2 ) );
    },
    bool_numeric: "(#3) = ( (#1) <= (#2) );",
    object: '(#3) = RTEST(rb_funcall((#1), rb_intern("<="), 1, (#2))) ? 1 : 0;',
  },
}.each do |name, spec|
  source = [:fixlen, :bool] + MkKernel::ALL_NUMERIC + [:object]
  source += MkKernel::CMPLX_DTYPES if spec[:complex]
  expr = {
    [:fixlen]                          => spec[:fixlen],
    ([:bool] + MkKernel::ALL_NUMERIC)  => spec[:bool_numeric],
  }
  expr[MkKernel::CMPLX_DTYPES] = spec[:complex] if spec[:complex]
  expr[[:object]] = spec[:object]
  MkKernel.bincmp name, op: spec[:op], source: source, expr: expr
end

# match: regex match for fixlen and object.  Fixlen expr uses
# rb_str_new(p1, b1) to construct a Ruby String from the byte buffer.
MkKernel.bincmp :match,
  source: [:fixlen, :object],
  expr:   {
    [:fixlen] => %{
      (#3) = RTEST(rb_funcall(rb_str_new(p1,b1), rb_intern("=~"), 1, (#2)));
    },
    [:object] => '(#3) = RTEST(rb_funcall((#1), rb_intern("=~"), 1, (#2)));',
  }

# is_kind_of: Object-only, uses rb_obj_is_kind_of.
MkKernel.bincmp :is_kind_of,
  source: [:object],
  expr:   {
    [:object] => '(#3) = RTEST(rb_obj_is_kind_of((#1), (#2)));',
  }

# ---- bincmp aliases ----------------------------------------------------
MkKernel.alias_bincmp :">",  :gt
MkKernel.alias_bincmp :"<",  :lt
MkKernel.alias_bincmp :">=", :ge
MkKernel.alias_bincmp :"<=", :le
MkKernel.alias_bincmp :"=~", :match

# ---- IC.2: tolerance bincmp family (= is_close / is_equiv) -----------
#
# Migrated from carray_stat.c hand-written rb_ca_is_close / rb_ca_is_equiv
# to bincmp form (kernel_iterator + lazy fuse).  Runtime tol slot is
# passed via the new `double tol` arg added uniformly in IC.1.
#
# is_close: |a - b| <= tol (absolute tolerance)
# is_equiv: |a - b| / max(|a|, |b|) <= tol (relative tolerance),
#           NaN-safe via (#1) == (#2) short-circuit for identical values
#           including 0 / 0 (= legacy semantics).
#
# Integer ops cast through double to avoid unsigned wrap on subtract.
# Complex ops use cabs() consistent with legacy hand-written behavior.

MkKernel.bincmp :is_close,
  source:    MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  tolerance: true,
  expr: {
    int:     "(#3) = (fabs((double)(#1) - (double)(#2)) <= tol) ? 1 : 0;",
    float:   "(#3) = (fabs((#1) - (#2)) <= tol) ? 1 : 0;",
    complex: "(#3) = (cabs((#1) - (#2)) <= tol) ? 1 : 0;",
  }

MkKernel.bincmp :is_equiv,
  source:    MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  tolerance: true,
  expr: {
    int:     %{
      double a = (double)(#1), b = (double)(#2);
      double aa = fabs(a), ab = fabs(b);
      double m = (aa > ab) ? aa : ab;
      (#3) = ( (#1) == (#2) || (m > 0 && fabs(a - b) / m <= tol) ) ? 1 : 0;
    },
    float:   %{
      <type> aa = fabs((#1)), ab = fabs((#2));
      <type> m = (aa > ab) ? aa : ab;
      (#3) = ( (#1) == (#2) || (m > 0 && fabs((#1) - (#2)) / m <= tol) ) ? 1 : 0;
    },
    complex: %{
      double aa = cabs((#1)), ab = cabs((#2));
      double m = (aa > ab) ? aa : ab;
      (#3) = ( m > 0 && cabs((#1) - (#2)) / m <= tol ) ? 1 : 0;
    },
  }

# CLI entry.  No argument: the single-stream form on stdout.  With a
# directory: the split form, writing carray_kernels_<tag>.c plus
# carray_kernels_init.c into it.
if __FILE__ == $PROGRAM_NAME
  if ARGV[0]
    MkKernel.emit(ARGV[0])
  else
    MkKernel.emit
  end
end
