# ----------------------------------------------------------------------------
#
#  carray/core_extensions.rb
#
#  Refinement that restores the carray-flavoured monkey patches on
#  Float / Integer / Rational / Numeric / TrueClass / FalseClass
#  for files that opt in with `using CArray::CoreExtensions`.
#
#  Provides:
#    - Postfix math on Float/Integer/Rational (sqrt, exp, log, sin, ...)
#      enabling scalar/CArray polymorphism: the same expression
#      `(0.0415*(t-218.8)).tanh` works whether t is a Float or a CArray.
#    - The same postfix math on Complex, so an expression written for a
#      complex CArray still reads for a single cell taken out of it.
#    - Angle normalisation on Numeric (deg_360 / deg_180 / rad_2pi / rad_pi).
#    - Comparison helpers on Numeric (#eq / #ne) for symmetric usage:
#      `5.eq(ca)` dispatches to `ca.eq(5)`.
#    - Symmetric bitwise operators on Integer / TrueClass / FalseClass
#      so that `5 | bool_ca`, `0xff & flag_ca`, `1 << position_ca` work
#      without writing CA_INT(5) on the left.
#
#  None of these are loaded by default `require "carray"`. Each file
#  that wants any of them must opt in:
#
#      using CArray::CoreExtensions
#
#  Refinements are lexically scoped to the file (or class/module body)
#  where `using` is written. Methods defined in that scope resolve
#  the refined methods at call time regardless of who is calling.
#
#  This file is auto-loaded on first reference to CArray::CoreExtensions.
#
# ----------------------------------------------------------------------------

class CArray
  # Refinement carrying the carray-flavoured additions to Float / Integer /
  # Rational / Numeric / TrueClass / FalseClass, for files that opt in with
  # `using CArray::CoreExtensions`.
  #
  # It provides postfix math on scalars (so `(0.0415*(t-218.8)).tanh` reads
  # the same whether `t` is a Float, a Complex or a CArray), angle
  # normalisation, and comparison helpers.  Being a refinement, it is
  # lexically scoped: nothing changes for code that does not opt in.
  module CoreExtensions

    # @!visibility private
    MATH_METHODS = %i[
      sqrt exp log log10
      sin cos tan sinh cosh tanh
      asin acos atan asinh acosh atanh
    ].freeze

    [Float, Integer, Rational].each do |klass|
      refine(klass) do
        MATH_METHODS.each do |m|
          module_eval <<~RUBY, __FILE__, __LINE__ + 1
            def #{m}
              Math.#{m}(self)
            end
          RUBY
        end
        def rad
          self.to_f * Math::PI / 180.0
        end
        def deg
          self.to_f * 180.0 / Math::PI
        end
        def distance(other)
          (self.to_f - other.to_f).abs
        end
        # M.1 (PyTorch alignment) scalar polymorphism additions.
        # `trunc` is left to Ruby's built-in semantics (Float#truncate
        # returns Integer when arg=0) — its CArray counterpart preserves
        # data type, so scalar-side use should call .to_f.trunc explicitly.
        # Math.expm1 / Math.log1p don't exist in stdlib; hand-roll.
        def expm1
          Math.exp(self) - 1.0
        end
        def log1p
          Math.log(1.0 + self)
        end
        def rsqrt
          1.0 / Math.sqrt(self)
        end
        def square
          self * self
        end
        def signbit
          self.negative?
        end
      end
    end

    # The subset of MATH_METHODS that CArray's complex kernels implement,
    # plus the two elementwise helpers that also accept complex input.
    #
    # Absent, because a complex CArray raises CArray::DataTypeError for
    # them: log10 (C99 has no clog10) and expm1 / log1p (no complex form
    # in C99 either).  Leaving them undefined on Complex keeps the scalar
    # side failing wherever the array side fails.  rad / deg / distance /
    # signbit are absent for the same reason from the other direction:
    # they go through #to_f, which Complex does not have.
    #
    # @!visibility private
    COMPLEX_MATH_METHODS = %i[
      sqrt exp log
      sin cos tan sinh cosh tanh
      asin acos atan asinh acosh atanh
      square rsqrt
    ].freeze

    # Complex is not handled the way Float / Integer / Rational are.
    # Math.tanh(Complex(1,2)) raises RangeError -- of the stdlib Math
    # methods only Math.sqrt accepts a Complex -- so the complex forms
    # need their own implementation.
    #
    # Each one runs the value through a one-element cmplx128 CScalar, so
    # the answer comes from the very kernel the array form would have
    # used.  That is the point: the branch cuts of csqrt / clog / casin /
    # cacosh / catanh, and the sign of a zero on either side of them, are
    # whatever the platform's C99 complex.h says they are, and they are
    # not the same everywhere.  On this machine, for instance,
    # catanh(-1+0i) yields -Infinity+(pi/4)i where C99 Annex G describes
    # -Infinity+0i.  A hand-written Complex implementation would have to
    # reproduce each such quirk to agree with the array form, and would
    # stop agreeing on the next platform; delegating agrees by
    # construction on all of them.  The cost is one CScalar per call
    # (~0.4 microseconds), which is the right trade for a scalar
    # convenience whose whole purpose is to read the same as the array.
    #
    # `square` is delegated rather than written as `self * self`: Ruby's
    # Complex multiplication and C's `double _Complex` multiplication part
    # ways on infinities (Complex(1, Inf) squared gives -Inf+Inf*i in Ruby
    # and -Inf+NaN*i in C).
    refine Complex do
      COMPLEX_MATH_METHODS.each do |m|
        module_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{m}
            CA_CMPLX128(self).#{m}[0]
          end
        RUBY
      end
    end

    refine Numeric do
      def deg_360
        a = self.to_f
        fa = a / 360.0
        if a >= 0
          (fa - fa.floor) * 360.0
        else
          (fa - fa.ceil + 1) * 360.0
        end
      end

      def deg_180
        a = self.to_f
        fa = (a + 180.0) / 360.0
        b = if a >= 0
              (fa - fa.floor) * 360.0 - 180.0
            else
              (fa - fa.ceil) * 360.0 - 180.0
            end
        b += 360.0 if b <= -180.0
        b
      end

      def rad_2pi
        a = self.to_f
        two_pi = 2 * Math::PI
        fa = a / two_pi
        if a >= 0
          (fa - fa.floor) * two_pi
        else
          (fa - fa.ceil + 1) * two_pi
        end
      end

      def rad_pi
        a = self.to_f
        two_pi = 2 * Math::PI
        fa = (a + Math::PI) / two_pi
        b = if a >= 0
              (fa - fa.floor) * two_pi - Math::PI
            else
              (fa - fa.ceil) * two_pi - Math::PI
            end
        b += two_pi if b <= -Math::PI
        b
      end

      def eq(other)
        if CArray === other
          other.eq(self)
        else
          self == other
        end
      end

      def ne(other)
        if CArray === other
          other.ne(self)
        else
          self != other
        end
      end
    end

    refine Integer do
      def |(other)
        if CArray === other
          if other.boolean?
            other.bit_or(self)
          else
            l, r = other.coerce(self)
            l | r
          end
        else
          super
        end
      end

      def &(other)
        if CArray === other
          if other.boolean?
            other.bit_and(self)
          else
            l, r = other.coerce(self)
            l & r
          end
        else
          super
        end
      end

      def ^(other)
        if CArray === other
          if other.boolean?
            other.bit_xor(self)
          else
            l, r = other.coerce(self)
            l ^ r
          end
        else
          super
        end
      end

      def <<(other)
        if CArray === other
          l, r = other.coerce(self)
          l << r
        else
          super
        end
      end

      def >>(other)
        if CArray === other
          l, r = other.coerce(self)
          l >> r
        else
          super
        end
      end
    end

    [TrueClass, FalseClass].each do |klass|
      refine(klass) do
        def |(other)
          if CArray === other && other.boolean?
            other.bit_or(self)
          else
            super
          end
        end

        def &(other)
          if CArray === other && other.boolean?
            other.bit_and(self)
          else
            super
          end
        end

        def ^(other)
          if CArray === other && other.boolean?
            other.bit_xor(self)
          else
            super
          end
        end
      end
    end

  end # module CoreExtensions
end # class CArray
