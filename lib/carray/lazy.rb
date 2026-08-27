# ---------------------------------------------------------------------------
#
# Per-op lazy-or-eager method redefinition on CArray.
#
# For each of the monop/monfunc methods, alias the existing eager
# implementation as `__<name>_eager__` and redefine `<name>` to dispatch:
#
#   - if self.__lazy_view__? → CAMonOp.__build__(self, OP_<NAME>)
#     (cast node insertion handled in C if data_type mismatch)
#   - else                   → __<name>_eager__
#
# CAREFUL: the redefinition must run once at load time AFTER the eager
# methods are bound by Init_carray_math.  carray_ext.bundle Init order
# guarantees this file loads after ext-level binding.
#
# The lazy branch sits at the entry of CArray#<op> and does only a cheap
# type check, so the pure-eager path is essentially unaffected.
# ---------------------------------------------------------------------------

class CArray
  # op_name => CAMonOp::OP_<NAME>
  LAZY_MONOP_OP_IDS = {
    # Preserve-data_type monop (8)
    zero:    CAMonOp::OP_ZERO,
    one:     CAMonOp::OP_ONE,
    frac:    CAMonOp::OP_FRAC,
    neg:     CAMonOp::OP_NEG,
    bit_neg: CAMonOp::OP_BIT_NEG,
    abs_i:   CAMonOp::OP_ABS_I,
    conj:    CAMonOp::OP_CONJ,
    not:     CAMonOp::OP_NOT,

    # Preserve-data_type monfunc (4)
    ceil:    CAMonOp::OP_CEIL,
    floor:   CAMonOp::OP_FLOOR,
    round:   CAMonOp::OP_ROUND,
    rcp:     CAMonOp::OP_RCP,

    # Widening monfunc (22)
    rad:     CAMonOp::OP_RAD,
    deg:     CAMonOp::OP_DEG,
    sqrt:    CAMonOp::OP_SQRT,
    exp:     CAMonOp::OP_EXP,
    exp2:    CAMonOp::OP_EXP2,
    exp10:   CAMonOp::OP_EXP10,
    log:     CAMonOp::OP_LOG,
    log10:   CAMonOp::OP_LOG10,
    log2:    CAMonOp::OP_LOG2,
    logb:    CAMonOp::OP_LOGB,
    sin:     CAMonOp::OP_SIN,
    cos:     CAMonOp::OP_COS,
    tan:     CAMonOp::OP_TAN,
    asin:    CAMonOp::OP_ASIN,
    acos:    CAMonOp::OP_ACOS,
    atan:    CAMonOp::OP_ATAN,
    sinh:    CAMonOp::OP_SINH,
    cosh:    CAMonOp::OP_COSH,
    tanh:    CAMonOp::OP_TANH,
    asinh:   CAMonOp::OP_ASINH,
    acosh:   CAMonOp::OP_ACOSH,
    atanh:   CAMonOp::OP_ATANH,

    # Additional monfunc
    expm1:   CAMonOp::OP_EXPM1,
    log1p:   CAMonOp::OP_LOG1P,
    rsqrt:   CAMonOp::OP_RSQRT,
    trunc:   CAMonOp::OP_TRUNC,
    square:  CAMonOp::OP_SQUARE,

    # Angle normalisation
    deg_360: CAMonOp::OP_DEG_360,
    deg_180: CAMonOp::OP_DEG_180,
    rad_2pi: CAMonOp::OP_RAD_2PI,
    rad_pi:  CAMonOp::OP_RAD_PI,

    # Sign function (preserves the data type).  bool/uint → 0/1, sint → -1/0/1,
    # float → -1/0/1 NaN-preserving, complex → unit vector or 0.
    sign:    CAMonOp::OP_SIGN,

    # imag_i: type-preserving primitive (0 for numeric, cimag for complex
    # in the real slot).  Primarily consumed by the `imag` special case
    # below but also directly callable via `a.lazy.imag_i`; entry here
    # so the direct call fuses instead of falling to eager.
    imag_i:  CAMonOp::OP_IMAG_I,
  }.freeze

  LAZY_MONOP_OP_IDS.each do |name, op_id|
    eager_alias = :"__#{name}_eager__"
    # Preserve the existing eager method under a hidden alias.
    alias_method(eager_alias, name)
    # Capture the eager UnboundMethod for fast direct dispatch (avoids
    # Ruby method-lookup overhead of `__send__` on the hot eager path).
    eager_um = instance_method(eager_alias)
    # Redefine as lazy-or-eager dispatch.
    define_method(name) do
      if __lazy_view__?
        CAMonOp.__build__(self, op_id)
      else
        eager_um.bind_call(self)
      end
    end
  end

  # Operator aliases (`~` -> bit_neg, `-@` -> neg) were installed by
  # rb_define_alias at Init time (see MkKernel.alias_monop in
  # ext/carray_kernels_monop.c) BEFORE this file redefines the target
  # methods.  rb_define_alias snapshots the method entry, so the operator
  # form still points at the original eager C function and skips the
  # lazy dispatch above — `~a` / `-a` on a lazy view materialise instead
  # of building a CAMonOp node.  Re-alias here so the operator form
  # follows the redefined lazy-or-eager dispatch.
  alias_method :"~",  :bit_neg
  alias_method :"-@", :neg

  # ---------------------------------------------------------------------------
  # abs lazy fuse (post-IC follow-up): the hand-written rb_ca_abs in
  # ext/carray_math.c is NOT in LAZY_MONOP_OP_IDS because it does
  # complex-specific dispatch (= magnitude as float).  Re-express that
  # dispatch via chain composition over existing lazy ops so abs rides
  # the lazy substrate fully:
  #   numeric parent: CAMonOp(OP_ABS_I)                        (1 node)
  #   complex parent: CAMonOp(cast_f64) ∘ CAMonOp(OP_ABS_I)    (2 nodes)
  # The complex chain works because ca_monop_abs_i for cmplx128 stores
  # |z| in the real slot with imag=0, then cast cmplx128->f64 picks up
  # the real part — semantically identical to rb_ca_abs (= abs_i + .real
  # + copy).  No new C kernel, no new op_id required.
  # ---------------------------------------------------------------------------

  alias_method :__abs_eager__, :abs
  __abs_eager_um__ = instance_method(:__abs_eager__)
  define_method(:abs) do
    if __lazy_view__?
      abs_i_node = CAMonOp.__build__(self, CAMonOp::OP_ABS_I)
      if complex?
        # CA_FLOAT64 is a Symbol; convert via data_type_code so the cast
        # op_id can be computed by Integer arithmetic.
        CAMonOp.__build__(abs_i_node,
                          CAMonOp::CAST_BASE + CArray.data_type_code(CA_FLOAT64))
      else
        abs_i_node
      end
    else
      __abs_eager_um__.bind_call(self)
    end
  end

  # ---------------------------------------------------------------------------
  # real / imag lazy fuse (post-IC follow-up):
  #
  # Eager `real`/`imag` in lib/carray/math.rb return CAField views
  # (zero-copy, mutable byte-offset access into complex storage) or
  # fresh template entities for non-complex.  Both break a lazy chain
  # when applied to a lazy parent (CAField materialises the parent into
  # an entity to byte-offset into).  For lazy parents we re-express via
  # chain composition so the chain stays fused:
  #
  #   complex parent .real → CAMonOp(cast_<float>)
  #     (cmplx128→f64 / cmplx64→f32 casts pick up the real part —
  #      verified equivalent to existing CAField path for read-only
  #      consumption)
  #
  #   complex parent .imag → CAMonOp(cast_<float>) ∘ CAMonOp(imag_i)
  #     (imag_i puts cimag in the real component of a same-data_type slot,
  #      cast then extracts it as float — same trick as abs)
  #
  #   non-complex parent .real → self (= pass-through, chain unchanged)
  #
  #   non-complex parent .imag → CAMonOp(imag_i) (= same-shape lazy zero)
  #
  # Eager parents fall through to the existing math.rb implementation
  # (= CAField for complex, CARefer/template for non-complex) so the
  # mutable-setter use cases (`.real = val` / `.imag = val`) remain
  # supported.  Lazy views are inherently read-only so the loss of
  # mutability on the lazy path is not a regression.
  # ---------------------------------------------------------------------------

  alias_method :__real_eager__, :real
  __real_eager_um__ = instance_method(:__real_eager__)
  define_method(:real) do
    if __lazy_view__?
      if complex?
        float_dt = (data_type == CA_CMPLX64) ? CA_FLOAT32 : CA_FLOAT64
        # float_dt is a Symbol; convert via data_type_code for kernel
        # op_id arithmetic.
        CAMonOp.__build__(self,
                          CAMonOp::CAST_BASE + CArray.data_type_code(float_dt))
      else
        # `real` of a real array is the array itself; preserve the lazy
        # chain unchanged (eager returns self[] = CARefer wrap, but for
        # lazy chain consumption returning self keeps streaming intact).
        self
      end
    else
      __real_eager_um__.bind_call(self)
    end
  end

  # @!visibility private
  alias_method :__imag_eager__, :imag
  __imag_eager_um__ = instance_method(:__imag_eager__)
  define_method(:imag) do
    if __lazy_view__?
      imag_i_node = CAMonOp.__build__(self, CAMonOp::OP_IMAG_I)
      if complex?
        float_dt = (data_type == CA_CMPLX64) ? CA_FLOAT32 : CA_FLOAT64
        # float_dt is a Symbol; convert via data_type_code for kernel
        # op_id arithmetic.
        CAMonOp.__build__(imag_i_node,
                          CAMonOp::CAST_BASE + CArray.data_type_code(float_dt))
      else
        imag_i_node
      end
    else
      __imag_eager_um__.bind_call(self)
    end
  end

  # ---------------------------------------------------------------------------
  # arg lazy fuse: eager `arg` always returns f64 regardless of input
  # data type (data_type-changing monop; see MkKernel.monop :arg output rule).
  # CAMonOp's cast-before invariant requires input data type == output data type
  # at each in-place step, so `arg` can't sit directly in the substrate.
  # Chain compose via the type-preserving `arg_i` primitive:
  #
  #   integer / bool parent → cast_f64 ∘ arg_i (result f64)
  #   float parent         → arg_i             (result same float)
  #   complex parent       → cast_<float> ∘ arg_i   (arg_i writes real
  #                          component of complex slot; cast extracts
  #                          the real part, same trick as abs / imag)
  #
  # Note: eager `arg` always widens to f64.  The lazy path preserves
  # the operand's float / complex width (f32 → f32, cmplx64 → f32)
  # rather than always going to f64 — matches the general lazy-substrate
  # rule "scalar keeps operand's precision" (see ca_lazy_wrap_scalar
  # header).  A user needing exact eager-parity can wrap with
  # `.to_type(:float64)` before / after.
  # ---------------------------------------------------------------------------

  alias_method :__arg_eager__, :arg
  __arg_eager_um__ = instance_method(:__arg_eager__)
  define_method(:arg) do
    if __lazy_view__?
      parent = self
      if integer? || boolean?
        parent = CAMonOp.__build__(parent,
                                   CAMonOp::CAST_BASE +
                                   CArray.data_type_code(CA_FLOAT64))
      end
      arg_i_node = CAMonOp.__build__(parent, CAMonOp::OP_ARG_I)
      if complex?
        float_dt = (data_type == CA_CMPLX64) ? CA_FLOAT32 : CA_FLOAT64
        CAMonOp.__build__(arg_i_node,
                          CAMonOp::CAST_BASE + CArray.data_type_code(float_dt))
      else
        arg_i_node
      end
    else
      __arg_eager_um__.bind_call(self)
    end
  end

  # ---------------------------------------------------------------------------
  # Binop dispatch.  Operator entries are redefined so a lazy operand on
  # either side routes into CABinOp.__build__.  Op scope:
  #   - 5 arithmetic: + - * / **
  #   - 3 bitwise:    & | ^
  #   - 2 shifts:     << >>
  #   - 2 misc:       %, rcp_mul
  # ---------------------------------------------------------------------------

  LAZY_BINOP_OP_IDS = {
    :+         => CABinOp::OP_ADD,
    :-         => CABinOp::OP_SUB,
    :*         => CABinOp::OP_MUL,
    :/         => CABinOp::OP_DIV,
    :**        => CABinOp::OP_POW,
    :&         => CABinOp::OP_BIT_AND,
    :|         => CABinOp::OP_BIT_OR,
    :^         => CABinOp::OP_BIT_XOR,
    :<<        => CABinOp::OP_BIT_LSHIFT,
    :>>        => CABinOp::OP_BIT_RSHIFT,
    :%         => CABinOp::OP_MOD,
    :rcp_mul   => CABinOp::OP_RCP_MUL,

    # Float-only binops registered eagerly by mkkernel; the lazy entries
    # here pick them up so `a.lazy.hypot(b)` etc. ride the substrate.
    :copysign  => CABinOp::OP_COPYSIGN,
    :logaddexp => CABinOp::OP_LOGADDEXP,
    :nextafter => CABinOp::OP_NEXTAFTER,
    :fmod      => CABinOp::OP_FMOD,
    :atan2     => CABinOp::OP_ATAN2,
    :hypot     => CABinOp::OP_HYPOT,

    # Pair-wise max / min (NaN-skip via C99 fmax/fmin on float branch).
    :pmax      => CABinOp::OP_PMAX,
    :pmin      => CABinOp::OP_PMIN,

    # Pair-wise max / min, NaN-propagate variant.
    :maximum   => CABinOp::OP_MAXIMUM,
    :minimum   => CABinOp::OP_MINIMUM,

    # Boolean word forms (bool + object; plain mask propagation, no
    # Kleene fixup — see the CA_BINOP_AND note in ca_binop_dispatch.h).
    :and       => CABinOp::OP_AND,
    :or        => CABinOp::OP_OR,
    :xor       => CABinOp::OP_XOR,

    # IEEE 754 remainder (distinct semantics from `%` / `mod`: float
    # branch uses C99 `remainder`, round-half-to-even).
    :reminder  => CABinOp::OP_REMINDER,
  }.freeze

  LAZY_BINOP_OP_IDS.each do |method_name, op_id|
    eager_alias = :"__#{method_name}_eager__"
    alias_method(eager_alias, method_name)
    eager_um = instance_method(eager_alias)
    define_method(method_name) do |other|
      if __lazy_view__? || (other.is_a?(CArray) && other.__lazy_view__?)
        CABinOp.__build__(self, other, op_id)
      else
        eager_um.bind_call(self, other)
      end
    end
  end

  # Binop word aliases (`add` -> `+`, `mul` -> `*`, `bit_and` -> `&`, …) were
  # installed by rb_define_alias at Init time (see MkKernel.alias_binop in
  # ext/carray_kernels_*.c) BEFORE the redefinitions above.  The C alias
  # snapshots the original eager method entry, so the word form still points
  # at the original C function and skips lazy dispatch — `a.lazy.add(1)`
  # materialises instead of building a CABinOp node.  Re-alias here so the
  # word form follows the redefined operator method.
  {
    add:        :+,
    sub:        :-,
    mul:        :*,
    div:        :/,
    mod:        :%,
    bit_and:    :&,
    bit_or:     :|,
    bit_xor:    :^,
    bit_lshift: :<<,
    bit_rshift: :>>,
  }.each do |word, op|
    alias_method(word, op)
  end

  # `pow` is the canonical C method (defined by rb_define_method in
  # ext/ca_op_ipower.c) that `**` is rb_define_alias'd to.  The `**`
  # override in this file (with the ipower Integer-exponent fast path)
  # does not propagate to `pow` through the C alias, so `a.lazy.pow(2)`
  # falls to eager.  Re-alias so `pow` follows the redefined `**`.
  alias_method :pow, :**

  # `fmax` / `fmin` are rb_define_alias'd to `pmax` / `pmin` at Init
  # time (same C-alias-snapshot trap).  Re-alias so the C99-familiar
  # spellings follow the redefined lazy dispatch above.
  alias_method :fmax, :pmax
  alias_method :fmin, :pmin

  # ---------------------------------------------------------------------------
  # Triop dispatch (fma / fms / clip).  CATriOp is the CABinOp analog for
  # three-operand element-wise ops.  Each Ruby method redefined below
  # dispatches to CATriOp.__build__ when any of self / op2 / op3 is a
  # lazy view, and falls to the eager C method otherwise.
  #
  # `clip` is the strict-clamp entry (`__clip_ki__`, called by the
  # lib/carray/basics.rb `clip` wrapper's both-bounds-present path).  The
  # nil-bound one-sided cases route through the wrapper's `pmax` / `pmin`
  # calls, which themselves lazy-fuse via LAZY_BINOP_OP_IDS above — so
  # `a.lazy.clip(nil, hi)` and `a.lazy.clip(lo, nil)` fuse without a
  # dedicated triop entry.
  # ---------------------------------------------------------------------------

  LAZY_TRIOP_OP_IDS = {
    fma:         CATriOp::OP_FMA,
    fms:         CATriOp::OP_FMS,
    __clip_ki__: CATriOp::OP_CLIP,
  }.freeze

  LAZY_TRIOP_OP_IDS.each do |method_name, op_id|
    eager_alias = :"__#{method_name}_eager_triop__"
    alias_method(eager_alias, method_name)
    eager_um = instance_method(eager_alias)
    define_method(method_name) do |op2, op3|
      lazy_receiver = __lazy_view__? ||
                      (op2.is_a?(CArray) && op2.__lazy_view__?) ||
                      (op3.is_a?(CArray) && op3.__lazy_view__?)
      if lazy_receiver
        CATriOp.__build__(self, op2, op3, op_id)
      else
        eager_um.bind_call(self, op2, op3)
      end
    end
  end

  # `**` integer-exponent lazy fast path.
  #
  # The default OP_POW path above goes through the `power` binop kernel,
  # which uses `pow(x, p)` / `cpow(x, p)` (transcendental, ~20-50 ns/cell)
  # for float / complex parents.  When `other` is an Integer, the eager
  # `rb_ca_pow` dispatches to `rb_ca_ipower` (= binary exponentiation via
  # `op_powi_<type>`, ~1-3 mul/cell, 3-5x faster than the transcendental
  # form).  Mirror that dispatch here so `a.lazy ** 2` rides the same
  # fast path.
  #
  # Routing rule (matches eager `rb_ca_pow`):
  #   - lazy parent + Integer exponent + Float/Complex parent data_type
  #     -> wrap exponent as CScalar.int64 + CABinOp(OP_IPOWER)
  #   - lazy parent (other cases) -> CABinOp(OP_POW)  [existing]
  #   - else -> eager (which itself dispatches to ipower internally)
  #
  # Integer parents intentionally stay on OP_POW: the mkkernel-generated
  # `power` binop kernel already uses `op_powi_<type>` for integer data_types
  # via the `int:` expr in MkKernel.binop :power, so OP_POW + int parent
  # is already fast.  The lazy-substrate gap was Float/Complex only.
  __pow_eager_um__ = instance_method(:"__**_eager__")
  define_method(:**) do |other|
    if other.is_a?(Integer) && (float? || complex?) &&
       (__lazy_view__? || (other.is_a?(CArray) && other.__lazy_view__?))
      CABinOp.__build__(self, CScalar.int64.tap { |s| s[0] = other },
                        CABinOp::OP_IPOWER)
    elsif __lazy_view__? || (other.is_a?(CArray) && other.__lazy_view__?)
      CABinOp.__build__(self, other, CABinOp::OP_POW)
    else
      __pow_eager_um__.bind_call(self, other)
    end
  end

  # coerce: when self is a lazy view and the scalar appears on the LEFT
  # (e.g. `2 * a.lazy`), Ruby's Numeric#* calls a.lazy.coerce(2).  The
  # default coerce would unwrap the lazy-ness via eager scalar promotion;
  # here we keep it lazy by returning [scalar_as_cscalar, self], so the
  # subsequent operator call ends up with a lazy receiver and triggers
  # the CABinOp builder.
  # ---------------------------------------------------------------------------
  # bincmp / moncmp dispatch.
  #
  # Comparison output is always boolean8_t, so it cannot reuse the CABinOp
  # in-place trick.  CABinCmp pulls both operands into operand-data_type
  # scratches and writes boolean to the output buffer.  Integer is_nan /
  # is_inf / is_finite use existing per-data_type kernels (which handle the
  # integer const-false/true result and mask skip).
  #
  # Scope: 7 bincmp + 3 moncmp + operator aliases (`<` / `>` / `<=` / `>=`)
  # for canonical Ruby comparison syntax.  Note: `==` / `eql?` are NOT
  # comparison ops — eager `CArray#==` (rb_ca_equal) is array-level
  # equality returning bool, not element-wise.  Element-wise equality is
  # `eq` / `feq`.
  #
  # `feq` is arity 1 in eager (compile-time FLT_EPSILON / DBL_EPSILON);
  # we mirror that here.  Runtime eps is a future extension (struct field
  # already reserved).
  # ---------------------------------------------------------------------------

  LAZY_BINCMP_OP_IDS = {
    # Canonical method names + operator aliases (rb_define_alias in C
    # creates separate dispatch entries, so we override both).
    :lt  => CABinCmp::OP_LT,
    :<   => CABinCmp::OP_LT,
    :gt  => CABinCmp::OP_GT,
    :>   => CABinCmp::OP_GT,
    :le  => CABinCmp::OP_LE,
    :<=  => CABinCmp::OP_LE,
    :ge  => CABinCmp::OP_GE,
    :>=  => CABinCmp::OP_GE,
    :eq  => CABinCmp::OP_EQ,
    :ne  => CABinCmp::OP_NE,
    :feq => CABinCmp::OP_FEQ,
  }.freeze

  LAZY_BINCMP_OP_IDS.each do |method_name, op_id|
    eager_alias = :"__#{method_name}_eager_bincmp__"
    alias_method(eager_alias, method_name)
    eager_um = instance_method(eager_alias)
    define_method(method_name) do |other|
      if __lazy_view__? || (other.is_a?(CArray) && other.__lazy_view__?)
        CABinCmp.__build__(self, other, op_id)
      else
        eager_um.bind_call(self, other)
      end
    end
  end

  # tolerance-bearing bincmp ops (= is_close / is_equiv) use the same
  # CABinCmp dispatch but with a 2nd `tol` positional arg.  Kept in a
  # separate dict because the LAZY_BINCMP_OP_IDS define_method block above
  # uses arity 1 (|other|); these need arity 2 (|other, tol|).
  LAZY_BINCMP_TOL_OP_IDS = {
    :is_close => CABinCmp::OP_IS_CLOSE,
    :is_equiv => CABinCmp::OP_IS_EQUIV,
  }.freeze

  LAZY_BINCMP_TOL_OP_IDS.each do |method_name, op_id|
    eager_alias = :"__#{method_name}_eager_bincmp_tol__"
    alias_method(eager_alias, method_name)
    eager_um = instance_method(eager_alias)
    define_method(method_name) do |other, tol|
      if __lazy_view__? || (other.is_a?(CArray) && other.__lazy_view__?)
        CABinCmp.__build__(self, other, op_id, tol.to_f.abs)
      else
        eager_um.bind_call(self, other, tol)
      end
    end
  end

  # @!visibility private
  LAZY_MONCMP_OP_IDS = {
    is_nan:     CAMonCmp::OP_IS_NAN,
    is_inf:     CAMonCmp::OP_IS_INF,
    is_finite:  CAMonCmp::OP_IS_FINITE,
    is_invalid: CAMonCmp::OP_IS_INVALID,
    signbit:    CAMonCmp::OP_SIGNBIT,
  }.freeze

  LAZY_MONCMP_OP_IDS.each do |name, op_id|
    eager_alias = :"__#{name}_eager_moncmp__"
    alias_method(eager_alias, name)
    eager_um = instance_method(eager_alias)
    define_method(name) do
      if __lazy_view__?
        CAMonCmp.__build__(self, op_id)
      else
        eager_um.bind_call(self)
      end
    end
  end

  # @!visibility private
  alias_method :__coerce_eager__, :coerce
  coerce_um = instance_method(:__coerce_eager__)
  define_method(:coerce) do |other|
    if __lazy_view__?
      dt_name = data_type_name
      if CScalar.respond_to?(dt_name)
        s = CScalar.send(dt_name)
        s[0] = other
        [s, self]
      else
        coerce_um.bind_call(self, other)
      end
    else
      coerce_um.bind_call(self, other)
    end
  end
end

# ---------------------------------------------------------------------------
# CAMonOp / CALazyMarker surface methods.
#
# Materialise-on-first-touch for Enumerable receivers, MV export reject,
# inspect/dump_tree summary that does NOT materialise.
# ---------------------------------------------------------------------------

class CAMonOp
  # op_id => :name reverse lookup
  OP_NAMES = CArray::LAZY_MONOP_OP_IDS.invert.freeze

  # --- inspect / dump_tree (no materialise) ----------------------------

  def op_label
    op_id = __op_id__
    if op_id >= CAMonOp::CAST_BASE
      "cast_#{CArray.data_type_name(op_id - CAMonOp::CAST_BASE)}"
    else
      (OP_NAMES[op_id] || "op_#{op_id}").to_s
    end
  end
  private :op_label

  # @overload inspect
  #   Returns a short summary of the lazy chain without
  #   materialising.
  #   @return [String]
  def inspect
    "#<CAMonOp #{op_label}(#{parent.inspect})>"
  end

  # @overload to_s
  #   Alias of {#inspect}.
  #   @return [String]
  def to_s
    inspect
  end

  # @overload dump_tree(indent = 0)
  #   Returns an ASCII summary of the lazy expression tree.
  #   Does not materialise.
  #   @param indent [Integer] leading indentation depth.
  #   @return [String]
  def dump_tree(indent = 0)
    pad = "  " * indent
    out = +"#{pad}#{op_label}\n"
    out << if parent.is_a?(CAMonOp)
             parent.dump_tree(indent + 1)
           else
             "#{"  " * (indent + 1)}#{parent.class}(#{parent.data_type_name}, #{parent.shape.inspect})\n"
           end
    out
  end

  # @overload each { |value| ... }
  #   Materialises `self` and yields each element of the resulting
  #   entity.
  #   @yieldparam value [Object]
  #   @return [Object]
  def each(&block)
    to_ca.each(&block)
  end

  # @overload to_a
  #   Materialises `self` and returns the resulting Array.
  #   @return [Array]
  def to_a
    to_ca.to_a
  end

  # @overload sort(*args, **kwargs)
  #   Materialises `self` into a copy and returns
  #   `entity.sort(*args, **kwargs)`.
  #   @return [CArray]
  def sort(*args, **kwargs)
    copy.sort(*args, **kwargs)
  end

  # --- MemoryView export → TypeError + .copy recommendation -----------

  # bulk-memory-view / Numo / Apache Arrow consumers go through the MV
  # protocol, which requires a contiguous backing buffer.  Lazy views
  # have no backing buffer until materialised; raise with a clear hint.
  #
  # MemoryView is consulted via to_memory_view_internal on the receiver
  # in some setups; the safest cross-cutting hook is the to_memory_view
  # method (defined by carray_memory_view producer).  We override to
  # raise.  Importers that probe via `rb_memory_view_get` will hit the
  # producer slot, which we DON'T currently override at C-level — but
  # the MV producer for CAView rejects backing-bufferless views by
  # default; tests below verify both Ruby-level and C-level reject.
  # @overload to_memory_view
  #   Not supported: a lazy view has no backing buffer.
  #   @return [void]
  #   @raise [TypeError] always; call `.copy` first.
  def to_memory_view
    raise TypeError,
          "lazy view (CAMonOp) has no backing buffer; call `.copy` " \
          "first to materialise into an entity before exporting via " \
          "MemoryView."
  end
end

# Lazy element-wise view of a binary operation on two operands.  Nothing is
# computed until the chain is forced, so a composed expression evaluates in
# one pass instead of materialising an intermediate per operator.
#
# Produced by an operator on `.lazy` operands or inside `CArray.fuse`, not
# constructed directly.
class CABinOp
  # op_id => :name reverse lookup
  OP_NAMES = CArray::LAZY_BINOP_OP_IDS.invert.merge(
    OP_IPOWER => :ipow,
  ).freeze

  def op_label
    op_id = __op_id__
    (OP_NAMES[op_id] || "op_#{op_id}").to_s
  end
  private :op_label

  # @overload inspect
  #   Returns a summary of the binop chain without materialising.
  #   @return [String]
  def inspect
    "#<CABinOp #{op_label}(#{parent.inspect}, #{__binop_right__.inspect})>"
  end

  # @overload to_s
  #   Alias of {#inspect}.
  #   @return [String]
  def to_s
    inspect
  end

  # @overload dump_tree(indent = 0)
  #   Returns an ASCII summary of the lazy expression tree, walking
  #   both children. Does not materialise.
  #   @return [String]
  def dump_tree(indent = 0)
    pad = "  " * indent
    out = +"#{pad}#{op_label}\n"
    [parent, __binop_right__].each do |child|
      out << if child.is_a?(CAMonOp) || child.is_a?(CABinOp)
               child.dump_tree(indent + 1)
             else
               "#{"  " * (indent + 1)}#{child.class}(#{child.data_type_name}, #{child.shape.inspect})\n"
             end
    end
    out
  end

  # @overload each { |value| ... }
  #   Materialises `self` and yields each element.
  #   @return [Object]
  def each(&block)
    to_ca.each(&block)
  end

  # @overload to_a
  #   Materialises `self` and returns the resulting Array.
  #   @return [Array]
  def to_a
    to_ca.to_a
  end

  # @overload sort(*args, **kwargs)
  #   Materialises `self` and sorts the resulting entity.
  #   @return [CArray]
  def sort(*args, **kwargs)
    to_ca.sort(*args, **kwargs)
  end

  # @overload to_memory_view
  #   Not supported for lazy binops.
  #   @raise [TypeError] always.
  def to_memory_view
    raise TypeError,
          "lazy view (CABinOp) has no backing buffer; call `.to_ca` " \
          "first to materialise into an entity before exporting via " \
          "MemoryView."
  end
end

class CALazyMarker
  # @overload inspect
  #   Returns a short summary showing the wrapped entity.
  #   @return [String]
  def inspect
    "#<CALazyMarker over #{parent.inspect}>"
  end

  # @overload to_s
  #   Alias of {#inspect}.
  #   @return [String]
  def to_s
    inspect
  end

  # @overload dump_tree(indent = 0)
  #   Returns an ASCII summary of the marker and its parent entity.
  #   @return [String]
  def dump_tree(indent = 0)
    pad = "  " * indent
    "#{pad}lazy(marker)\n" \
      "#{"  " * (indent + 1)}#{parent.class}(#{parent.data_type_name}, #{parent.shape.inspect})\n"
  end

  # @overload each { |value| ... }
  #   Yields each element of the wrapped entity (no materialise
  #   needed).
  #   @return [Object]
  def each(&block)
    parent.each(&block)
  end

  # @overload to_a
  #   Returns the wrapped entity's Array.
  #   @return [Array]
  def to_a
    parent.to_a
  end

  # @overload to_memory_view
  #   Not supported: markers do not own a backing buffer.
  #   @raise [TypeError] always; call `.copy` first.
  def to_memory_view
    raise TypeError,
          "lazy marker (CALazyMarker) has no backing buffer; call " \
          "`.copy` first to materialise into an entity before " \
          "exporting via MemoryView."
  end
end

# ---------------------------------------------------------------------------
# Lazy views override `to_ca` to force evaluation.
#
# `CArray#to_ca` returns `self` (a concrete-backed CArray — entity or data
# view — is already a CArray, no copy needed).  A lazy view has no data until
# evaluated, so `to_ca` must produce it: it materialises into a new entity,
# matching the Ruby `Enumerable#to_a` / lazy `force` convention.  (`copy` is
# the materialise path; on a lazy view it evaluates the expression.)
#
# That entity is detached from the operands, so writes to it reach nothing:
# `writable: true` is refused rather than answered with a result that would
# swallow them.
# ---------------------------------------------------------------------------
[CAMonOp, CABinOp, CATriOp, CAMonCmp, CABinCmp, CALazyMarker].each do |klass|
  klass.class_eval do
    def to_ca(writable: false)
      if writable
        raise "#{self.class}#to_ca evaluates into a new entity; " \
              "it can't satisfy `writable: true'"
      end
      copy
    end
  end
end

# ---------------------------------------------------------------------------
# CArray.fuse
#
# Transient lazy-fusion scope: wraps each CArray argument with `.lazy`,
# yields the wrappers (and any non-CArray args pass-through unchanged)
# to the block, then on block exit auto-materialises a bare lazy view
# return value into an entity.  Non-lazy return values (Numeric, plain
# CArray, Array, nil, etc.) pass through as-is.
#
# Design notes:
#   - Non-CArray args pass through eager (= polymorphic numeric helper
#     idiom: `magnus(25.0)` → Float and `magnus(arr)` → CArray carried by
#     a single helper definition, combined with the `CArray::CoreExtensions`
#     refinement which gives Float/Integer/Rational the same postfix math
#     API as CArray instances).
#   - Shadow args are read-only (CA_FLAG_READ_ONLY via `.lazy`), so
#     destructive ops on them raise naturally.
#   - A nested fuse materialises at its own inner exit.
#   - A bare lazy return auto-materialises; escaping the lazy view (e.g.
#     stashing it in an Array) is the user's responsibility.
# ---------------------------------------------------------------------------
class << CArray
  # @overload fuse(*args) { |*shadows| ... }
  #   Runs a transient lazy-fusion scope: wraps each CArray argument
  #   with `.lazy`, yields the wrappers (and any non-CArray args)
  #   to the block, then auto-materialises a bare lazy return value
  #   into an entity. Non-lazy returns pass through as-is.
  #   @param args [Array<CArray, Object>] operands.
  #   @yieldparam shadows [Array<CArray, Object>] lazy wrappers
  #     paired with pass-through non-CArray operands.
  #   @return [Object]
  #   @raise [LocalJumpError] when no block is given.
  def fuse(*args)
    raise LocalJumpError, "CArray.fuse requires a block" unless block_given?
    shadows = args.map { |a| a.is_a?(CArray) ? a.lazy : a }
    result = yield(*shadows)
    case result
    when CAMonOp, CABinOp, CAMonCmp, CABinCmp, CALazyMarker
      result.to_ca
    else
      result
    end
  end

  # CArray.lazy(*args) { |lazies| ... }  —  dual of fuse
  #
  # Like `fuse`, wraps each CArray argument with `.lazy` and yields it to
  # the block, but **does not auto-materialise at block exit** (= returns
  # the lazy structure as-is). If the block return is non-lazy (= Numeric
  # / entity CArray / Array etc.) it's pass-through (= same polymorphic
  # semantics as fuse).
  #
  # Use cases:
  #   - Passing a chain between functions: build the lazy expression
  #     inside the function and materialise at the caller
  #     (= `.to_ca` / `.sum` / `.mean(axis:)` etc.)
  #   - Reusable expressions: apply the same expr to multiple datasets
  #   - debug / dump_tree: observe the lazy structure as-is
  #   - Pick the materialise form later: full materialise or reduction
  #
  # Example:
  #   expr = CArray.lazy(a, b) { |s, o| (s + o) * 2 }
  #   expr.class           #=> CABinOp (lazy view)
  #   expr.to_ca           # full materialise
  #   expr.sum             # reduction (= chain + reduce in 1 pass)
  #
  # Polymorphic semantics (= symmetric with fuse):
  #   CArray.lazy(25.0, b) { |s, o| s + o }   # s=25.0 Float pass-through
  #   CArray.lazy(arr, b)  { |s, o| s + o }   # s=arr.lazy
  # @overload lazy(*args) { |*shadows| ... }
  #   Like {.fuse} but does not auto-materialise: returns whatever
  #   the block yields (typically a lazy view) so the expression
  #   can be materialised later via `.to_ca`, `.sum`, `.mean`, etc.
  #   @param args [Array<CArray, Object>] operands.
  #   @yieldparam shadows [Array<CArray, Object>] lazy wrappers.
  #   @return [Object]
  #   @raise [LocalJumpError] when no block is given.
  def lazy(*args)
    raise LocalJumpError, "CArray.lazy requires a block" unless block_given?
    shadows = args.map { |a| a.is_a?(CArray) ? a.lazy : a }
    yield(*shadows)
  end
end
