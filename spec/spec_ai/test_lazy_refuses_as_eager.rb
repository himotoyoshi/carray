# frozen_string_literal: true
#
# A lazy operator refuses as the eager one does.  An operator with no kernel
# for the type it would run in is refused when the node is built, by the
# part the eager operators use (ca_op_refuse_unimplemented): the same class
# and the same message, "<op>: not defined for data_type <type>", naming the
# type eager looks in (a boolean read as int64, an integer taken to float64).
# A refusal that can only come from the cells (comparing an object with a
# number) waits for the evaluation, so it has the eager class and names the
# method that evaluated it.
#
# Before, the lazy builders and the kernel tables' stubs said "invalid
# data_type for binop (not implemented)" and the like, naming neither the
# operator nor the type, in 643 pairs of operator and type; the lazy abs and
# arg of a boolean gave a type code ("input data_type 1").  The operators
# were made by define_method, whose frames carry no name, so once the part
# was shared they named the builder (__build__); they are defs now.

require "test/unit"
require "carray"

class TestLazyRefusesAsEager < Test::Unit::TestCase

  TYPES = {
    int8:    -> { CA_INT8([1, -2]) },
    uint8:   -> { CA_UINT8([1, 2]) },
    int32:   -> { CA_INT32([1, -2]) },
    float64: -> { CA_DOUBLE([1.5, -2.0]) },
    cmplx:   -> { CA_DCOMPLEX([1 + 1i, 2]) },
    bool:    -> { CA_BOOLEAN([1, 0]) },
    object:  -> { CA_OBJECT([1, "a"]) },
  }.freeze

  MONOPS = (CArray::LAZY_MONOP_OP_IDS.keys + %i[abs real imag arg] +
            CArray::LAZY_MONCMP_OP_IDS.keys).uniq.freeze
  BINOPS = (CArray::LAZY_BINOP_OP_IDS.keys + CArray::LAZY_BINCMP_OP_IDS.keys + [:**]).uniq.freeze

  def outcome
    [:ok, yield]
  rescue => e
    [e.class, e.message]
  end

  # [where, class, message]: where the lazy form refused, :build or :eval
  def lazy_outcome
    node = begin
      yield
    rescue => e
      return [:build, e.class, e.message]
    end
    begin
      node.to_ca
      [:ok, nil, nil]
    rescue => e
      [:eval, e.class, e.message]
    end
  end

  def check (label, eager, lazy)
    e_class, e_msg = eager
    where, l_class, l_msg = lazy
    if e_class == :ok
      assert_equal :ok, where, "#{label}: eager answers, lazy refused (#{l_msg})"
      return
    end
    assert_equal e_class, l_class, "#{label}: #{e_msg} / #{l_msg}"
    assert_equal e_msg, l_msg, label if where == :build
  end

  def test_every_unary_operator
    TYPES.each do |tn, mk|
      MONOPS.each do |op|
        next unless mk.().respond_to?(op)
        check("#{tn}.#{op}", outcome { mk.().public_send(op) },
              lazy_outcome { mk.().lazy.public_send(op) })
      end
    end
  end

  def test_every_binary_operator
    TYPES.each do |tn, mk|
      TYPES.each do |tn2, mk2|
        BINOPS.each do |op|
          check("#{tn}.#{op}(#{tn2})", outcome { mk.().public_send(op, mk2.()) },
                lazy_outcome { mk.().lazy.public_send(op, mk2.()) })
        end
      end
    end
  end

  def test_the_message_names_the_operator_and_the_type
    e = assert_raise(CArray::DataTypeError) { CA_INT8([1]).lazy.atan2(CA_INT8([1])) }
    assert_equal "atan2: not defined for data_type int8", e.message
    e = assert_raise(CArray::DataTypeError) { CA_BOOLEAN([1]).lazy.abs }
    assert_equal "abs: not defined for data_type boolean", e.message
  end

end
