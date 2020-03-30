require "numo/narray"

class CArray

  CARRAY2NUMO = {
    CA_INT8     => Numo::Int8,
    CA_UINT8    => Numo::UInt8,
    CA_INT16    => Numo::Int16,
    CA_UINT16   => Numo::UInt16,
    CA_INT32    => Numo::Int32,
    CA_UINT32   => Numo::UInt32,
    CA_INT64    => Numo::Int64,
    CA_UINT64   => Numo::UInt64,
    CA_INT64    => Numo::Int64,
    CA_UINT64   => Numo::UInt64,
    CA_FLOAT32  => Numo::SFloat,
    CA_FLOAT64  => Numo::DFloat,
  }
  
  def to_numo
    narray = CARRAY2NUMO[data_type].new(*dim)
    narray.store_binary(to_s)
    return narray
  end
  
end

module Numo

  class NArray

    NUMO2CARRAY = {
      Numo::Int8   => CA_INT8,     
      Numo::UInt8  => CA_UINT8,    
      Numo::Int16  => CA_INT16 ,   
      Numo::UInt16 => CA_UINT16 ,  
      Numo::Int32  => CA_INT32   , 
      Numo::UInt32 => CA_UINT32,   
      Numo::Int64  => CA_INT64 ,   
      Numo::UInt64 => CA_UINT64,   
      Numo::Int64  => CA_INT64 ,   
      Numo::UInt64 => CA_UINT64,   
      Numo::SFloat => CA_FLOAT32,  
      Numo::DFloat => CA_FLOAT64,  
    }
    
    def to_ca
      return CArray.new(NUMO2CARRAY[self.class], self.shape).load_binary(to_binary)
    end
    
  end
end
