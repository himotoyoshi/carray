#  Numo / NumPy-style factory class methods, gathered here as a
#  best-effort soft compatibility layer.
#
#  Rationale (the apology this file owes the rest of carray):
#
#  carray's native idiom for building arrays is the typed
#  constructor (CArray.float64(3, 3) { 0 }, CA_INT([1, 2, 3]), and
#  friends).  The methods below -- zeros / ones / eye / identity /
#  linspace / arange / full / meshgrid -- duplicate that
#  functionality with NumPy / Numo-flavoured names.  They exist
#  for one specific reason: when a user is porting a NumPy or Numo
#  example program over to carray, the first thing they hit is
#  the array-creation entry point, and "I have to learn a whole
#  different API just to call zeros" is the worst place to lose
#  someone.  Having these helpers means a paste from
#
#     np.zeros((3, 3))            -> CArray.zeros([3, 3])
#     np.full((3, 3), 7)          -> CArray.full([3, 3], 7)
#     np.linspace(0.0, 1.0, 5)    -> CArray.linspace(0.0, 1.0, 5)
#     Numo::DFloat.zeros(3, 3)    -> CArray::Float64.zeros(3, 3)
#
#  works with minimal rewriting.  Both the splat-shape carray-ish
#  form (CArray.zeros(3, 3)) and the array-shape NumPy-ish form
#  (CArray.zeros([3, 3])) are accepted by the shape-taking
#  factories.
#
#  The methods land on CArray itself and on every typed class
#  (CArray::Int32, CArray::Float64, etc.) via the
#  DataTypeExtension module declared (empty) in
#  lib/carray/construct.rb.  Required AFTER construct.rb in
#  lib/carray.rb so the module exists -- the extends in construct
#  see this file's method additions transparently.
#
#  meshgrid was previously in this file; it is now in
#  lib/carray/methods/meshgrid.rb (autoloaded on first call).
#
#  These helpers are not the "main" carray API.  When writing new
#  carray-flavoured code, prefer the typed constructors.  Use
#  these when porting external code or when a NumPy / Numo
#  spelling reads more naturally to the audience.

class CArray

  module DataTypeExtension

    def guess_data_type_from_values (*values)
      if values.all? {|v| v == true || v == false }
        CA_BOOLEAN
      elsif values.all? { |v| v.is_a?(Integer) }
        CA_INT64
      elsif values.all? { |v| v.is_a?(Float) }
        CA_FLOAT64
      elsif values.all? { |v| v.is_a?(Complex) }
        CA_CMPLX128
      else
        CA_OBJECT
      end
    end

    private :guess_data_type_from_values

    # Normalize a shape argument list: accept both
    #
    #   foo(3, 4)     # splat (carray-style)
    #   foo([3, 4])   # Array (NumPy-style: foo((3, 4)))
    #
    # so users can paste NumPy / Numo example code with minimal
    # rewriting.
    def normalize_shape (args)
      if args.size == 1 && args.first.is_a?(Array)
        args.first
      else
        args
      end
    end

    private :normalize_shape

    # @overload zeros(*shape)
    #   Returns a new CArray of the given shape filled with zeros.
    #   Shape accepts both splat Integers and a single Array. When
    #   called on a typed class the `data_type` is taken from the
    #   class; otherwise it defaults to `CA_FLOAT64`.
    #   @param shape [Array<Integer>, Array<Array<Integer>>] shape
    #     of the result.
    #   @return [CArray]
    def zeros (*args)
      CArray.new(self::DataType || CA_FLOAT64, normalize_shape(args)).zero
    end

    # @overload ones(*shape)
    #   Returns a new CArray of the given shape filled with ones.
    #   Same shape and `data_type` rules as {#zeros}.
    #   @param shape [Array<Integer>, Array<Array<Integer>>]
    #   @return [CArray]
    def ones (*args)
      CArray.new(self::DataType || CA_FLOAT64, normalize_shape(args)).one
    end

    # @overload eye(n, m = n, k = 0)
    #   Returns a 2-D CArray with ones on the `k`-th diagonal and
    #   zeros elsewhere.
    #   @param n [Integer] number of rows.
    #   @param m [Integer] number of columns; defaults to `n`.
    #   @param k [Integer] diagonal offset (positive above the main
    #     diagonal, negative below).
    #   @return [CArray] shape `(n, m)`.
    def eye (n, m = nil, k = 0)
      m ||= n
      mat = CArray.new(self::DataType || CA_FLOAT64, [n, m])
      if k >= 0
        count = [n, m - k].min
        start = k
      else
        count = [n + k, m].min
        start = (-k) * m
      end
      if count > 0
        mat[[start, count, m+1]] = 1
      end
      mat
    end

    # @overload identity(n)
    #   Returns the `n` by `n` identity matrix.
    #   @param n [Integer] matrix size.
    #   @return [CArray] shape `(n, n)`.
    def identity (n)
      mat = CArray.new(self::DataType || CA_FLOAT64, [n, n])
      mat[[nil,n+1]] = 1
      mat
    end

    # @overload linspace(x1, x2, n = 100)
    #   Returns a 1-D CArray of `n` values evenly spaced from `x1`
    #   to `x2` inclusive, matching NumPy's `linspace`. For an integer
    #   target `data_type`, values are computed in float64 with the
    #   linspace step `(x2 - x1) / (n - 1)`, then floored to the target
    #   type — the rule `np.linspace(x1, x2, n, dtype=int)` uses (round
    #   toward -infinity, not toward zero). Both endpoints are hit
    #   exactly for integer output when `x1` and `x2` are
    #   integer-valued.
    #
    #   Called on `CArray` itself (module method) integer inputs promote
    #   to `CA_FLOAT64` and the result is a float array. Called via an
    #   integer subclass (`CArray::Int32.linspace(...)`), the result is
    #   an integer array with floor semantics.
    #
    #   @param x1 [Numeric] first value.
    #   @param x2 [Numeric] last value.
    #   @param n [Integer] number of samples.
    #   @return [CArray]
    def linspace (x1, x2, n = 100)
      data_type = self::DataType
      unless data_type
        guess = guess_data_type_from_values(x1, x2)
        guess = CA_FLOAT64 if guess == CA_INT64
        data_type = guess
      end
      #  span is float-only ("N evenly-spaced integers" is ambiguous —
      #  see basics.rb).  Route non-float targets through a float64
      #  span, then floor + cast; this matches np.linspace(dtype=int)
      #  bit for bit (floor rounds toward -infinity so negative
      #  midpoints go the same way as numpy's integer linspace).
      float_out = CArray.new(CA_FLOAT64, [n]).span(x1.to_f..x2.to_f)
      return float_out if data_type == CA_FLOAT64
      float_out.floor.to_type(data_type)
    end

    # @overload arange(stop)
    #   Returns a 1-D CArray with values `0, 1, ..., stop - 1`.
    #   @param stop [Numeric] exclusive upper bound.
    #   @return [CArray]
    # @overload arange(start, stop)
    #   Returns `start, start + 1, ..., stop - 1`.
    #   @param start [Numeric] inclusive lower bound.
    #   @param stop [Numeric] exclusive upper bound.
    #   @return [CArray]
    # @overload arange(start, stop, step)
    #   Returns values from `start` to `stop` (exclusive) stepping
    #   by `step`.
    #   @param start [Numeric] inclusive lower bound.
    #   @param stop [Numeric] exclusive upper bound.
    #   @param step [Numeric] spacing.
    #   @return [CArray]
    def arange (*args)
      case args.size
      when 3
        start, stop, step = *args
      when 2
        start, stop = *args
        step = 1
      when 1
        start = 0
        stop, = *args
        step = 1
      else
        raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 1..3)"
      end
      raise ArgumentError, "step must not be 0" if step == 0
      data_type = self::DataType
      data_type ||= guess_data_type_from_values(start, stop, step)
      #  Element count comes from the arguments as given, not from the
      #  target data type: CArray::Int32.arange(0, 1, 0.25) counts four
      #  elements from the float step and truncates them on store.
      #  Integer arguments count exactly (divmod) so that a step dividing
      #  the span evenly does not gain a spurious element through float
      #  rounding.
      span = stop - start
      if span.is_a?(Integer) && step.is_a?(Integer)
        q, r = span.divmod(step)
        n = r.zero? ? q : q + 1
      else
        n = (span.to_f / step).ceil
      end
      n = 0 if n < 0
      CArray.new(data_type, [n]).seq(start, step)
    end

    # @overload full(shape, fill_value)
    #   Returns a new CArray of the given shape filled with
    #   `fill_value`. `shape` accepts an Integer or an Array of
    #   Integers. The `data_type` is inferred from `fill_value`
    #   when the receiver is not a typed class.
    #   @param shape [Integer, Array<Integer>]
    #   @param fill_value [Object] value used to fill the array.
    #   @return [CArray]
    def full (shape, fill_value)
      data_type = self::DataType
      data_type ||= guess_data_type_from_values(fill_value)
      shape = [shape] unless shape.is_a?(Array)
      CArray.new(data_type, shape).fill(fill_value)
    end

    # @overload empty(*shape)
    #   Returns a new CArray of the given shape whose contents are
    #   **uninitialised**. The caller must overwrite the array
    #   before reading from it. `CA_OBJECT` silently falls back to
    #   a zero-VALUE init required for GC safety.
    #   @param shape [Array<Integer>, Array<Array<Integer>>]
    #   @return [CArray]
    def empty (*args)
      CArray.__alloc_uninit__(self::DataType || CA_FLOAT64,
                              normalize_shape(args))
    end

  end

end

