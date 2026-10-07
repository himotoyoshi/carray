require "test/unit"
require "carray"

# A generated kernel's refusal names the method that was called and lists
# the data types by their CArray names.
class TestKernelErrorWording < Test::Unit::TestCase

  def message
    yield
    flunk "no exception"
  rescue ArgumentError, CArray::DataTypeError => e
    e.message
  end

  def test_names_the_called_method
    assert_match(/\Acumsum: positional axis/, message { CA_FLOAT64([1]).cumsum(0) })
    assert_match(/\Asum: positional axis/,    message { CA_FLOAT64([1]).sum(0) })
    assert_match(/\Amin: Face-typed input/,   message { CA_OBJECT(%w[b a]).categorize.min })
    refute_match(/_ki\b/, message { CA_CMPLX128([1]).sort })
  end

  def test_lists_data_types_by_name
    m = message { CA_CMPLX128([1, 2]).sort }
    assert_match(/expected one of: int8, uint8, .*float64/, m)
    refute_match(/\bi8\b|\bf64\b/, m)
  end
end
