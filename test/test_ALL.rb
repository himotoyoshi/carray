$:.unshift(File.dirname(__FILE__))
$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

load 'test_CComplex.rb' if CArray::HAVE_COMPLEX
#
load 'test_CABitfield.rb'
load 'test_CABlock.rb'
load 'test_CAField.rb'
load 'test_CAGrid.rb'
load 'test_CAMapping.rb'
load 'test_CAMmap.rb'
load 'test_CARefer.rb'
load 'test_CARepeat.rb'
load 'test_CASelect.rb'
load 'test_CAShift.rb'
load 'test_CATranspose.rb'
load 'test_CAWindow.rb'
load 'test_CAWrap.rb'
load 'test_CAVirtual.rb'
load 'test_CArray.rb'
load 'test_CScalar.rb'
#
load 'test_attribute.rb'
load 'test_block_iterator.rb'
load 'test_boolean.rb'
load 'test_cast.rb'
load 'test_class.rb'
load 'test_complex.rb' if CArray::HAVE_COMPLEX
load 'test_composite.rb'
load 'test_convert.rb'
load 'test_copy.rb'
load 'test_element.rb'
load 'test_extream.rb'
load 'test_generate.rb'
load 'test_index.rb'
load 'test_mask.rb'
#load 'test_math.rb'
load 'test_narray.rb' if defined?(CArray::HAVE_NARRAY)
load 'test_order.rb'
load 'test_random.rb'
load 'test_ref_store.rb'
load 'test_stat.rb'
load 'test_struct.rb'
load 'test_virtual.rb'
#
load 'test_creation.rb'
#
