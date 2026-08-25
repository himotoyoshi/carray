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
  # the same whether `t` is a Float or a CArray), angle normalisation, and
  # comparison helpers.  Being a refinement, it is lexically scoped: nothing
  # changes for code that does not opt in.
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
          define_method(m) { Math.send(m, self) }
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
        # dtype, so scalar-side use should call .to_f.trunc explicitly.
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
