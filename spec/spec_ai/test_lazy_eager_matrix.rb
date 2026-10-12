require "test/unit"
require "carray"

# A lazy expression answers what the eager expression answers: the same
# values, data type and mask, or the same error class.  Every operation the
# lazy tables register is walked over every data type, with and without a
# masked cell, against an array or a scalar operand, so an operation added
# to a table is checked without an edit here.

class TestLazyEagerMatrix < Test::Unit::TestCase

  TYPES = %i[boolean int8 uint8 int32 int64 uint64 float32 float64 cmplx128 object]

  def arr (t, masked, vals = [3, -2, 0, 5])
    vals = [true, false, true, false] if t == :boolean
    vals = vals.map(&:abs) if t.to_s.start_with?("u")
    a = CArray.new(t, [4])
    a[] = vals
    a[2] = UNDEF if masked
    a
  end

  def nan_free (v)
    case v
    when Float   then v.nan? ? :nan : v
    when Complex then [nan_free(v.real), nan_free(v.imag)]
    else v
    end
  end

  def outcome
    x = yield
    x = x.copy if x.is_a?(CArray)
    case x
    when CArray then [x.data_type_name, x.to_a.map { |v| nan_free(v) },
                      x.has_mask? ? x.is_masked.to_a : nil]
    else nan_free(x)
    end
  rescue StandardError => e
    e.class
  end

  def scalar_for (t)
    { boolean: true, object: 2 }[t] || (t.to_s =~ /float|cmplx/ ? 1.5 : 2)
  end

  def differences
    out = []
    unary  = CArray::LAZY_MONOP_OP_IDS.keys + CArray::LAZY_MONCMP_OP_IDS.keys
    binary = CArray::LAZY_BINOP_OP_IDS.keys + CArray::LAZY_BINCMP_OP_IDS.keys
    TYPES.each do |t|
      [false, true].each do |m|
        a = arr(t, m)
        unary.each do |op|
          next unless a.respond_to?(op)
          e = outcome { a.public_send(op) }
          l = outcome { a.lazy.public_send(op) }
          out << "#{t}#{m ? '(masked)' : ''}.#{op}: #{e.inspect} vs #{l.inspect}" if e != l
        end
        TYPES.each do |u|
          b = arr(u, false)
          operands = [b]
          operands << scalar_for(t) if u == t
          binary.each do |op|
            operands.each do |o|
              e = outcome { a.public_send(op, o) }
              l = outcome { a.lazy.public_send(op, o.is_a?(CArray) ? o.lazy : o) }
              out << "#{t}#{m ? '(masked)' : ''} #{op} #{o.is_a?(CArray) ? u : o.inspect}: " \
                     "#{e.inspect} vs #{l.inspect}" if e != l
            end
          end
          y = arr(u, false, [1, 1, 2, 2])
          z = arr(u, false, [4, 0, 1, 3])
          { fma: ->(p, q, r) { p.fma(q, r) }, fms: ->(p, q, r) { p.fms(q, r) },
            clip: ->(p, q, r) { p.clip(q, r) } }.each do |name, f|
            e = outcome { f.(a, y, z) }
            l = outcome { f.(a.lazy, y.lazy, z.lazy) }
            out << "#{t}#{m ? '(masked)' : ''}.#{name}(#{u}): #{e.inspect} vs #{l.inspect}" if e != l
          end
        end
      end
    end
    out
  end

  def test_every_registered_operation_answers_as_eager
    diffs = differences
    assert diffs.empty?, "#{diffs.size} differences:\n" + diffs.first(20).join("\n")
  end
end
