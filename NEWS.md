ChangeLog of Ruby/CArray
========================

1.5.8 -> 1.5.9
--------------

* [New] Add new method 'CArray#vectorized_find_linear_addr'
* [Fix] Fixed invalid return value type in CArray##stddev 

1.5.7 -> 1.5.8
--------------

* [New] Add new method 'CArray#vectorized_section'
* [New] Add new method 'CArray#fetch_linear_addr'
* [New] Add new method 'CArray#vectorized_fetch_linear_addr'
* [New] Add new method 'CArray#str_format'
* [Fix] Fixed SEGV in loading binary data from the piped input in CArray#load_binary

1.5.6 -> 1.5.7
--------------

* [Mod] Modify the methods 'CArray#first' and 'CArray#last' to return nil when the number of elements is zero
* [Fix] Add check of having ArithmeticSeuqence in ruby_carray.c

1.5.5 -> 1.5.6
--------------

* [Mod] Modify CArray access methods to accept Enumerator::ArithmeticSequence for index, address
* [Mod] Remove some gem autoloading (io_csv, io_sqlite3, rmagick, cairo, opencv, ffi)
* [Mod] Modify 'CArray#valid_index?' and 'CArray#valid_addr?' to accept negative integers
* [Mod] Modify the methods 'CArray#double' etc not to raise error for invalid string in conversion into float

1.5.4 -> 1.5.5
--------------

* [Fix] Fix recognition of "atan2", ... in "math.h"
* [Fix] Fix serialize.rb of keyword parameters for Ruby2.7

1.5.3 -> 1.5.4
--------------

* [New] Import method 'CArray#section' from gem 'carray-calculus'
* [New] Add new method 'CArray#pull', 'CArray#pulled'
* [New] Add new option 'expand_scalar' to 'CArray.broadcast'
* [Mod] Modify the method 'CArray.broadcast' to accept block.
* [Mod] Modify the method 'CArray.meshgrid' to accept block.
* [Mod] Modify 'CScalar#broadcast_to' to return CArray
* [Mod] Modify 'CScalar#is_masked' and 'CScalar#is_masked' to return CScalar
* [Fix] Fix order of repetitive dimensions in 'CArray#meshgrid'
* [Fix] Fix errors in installing on MinGW+msys2

1.5.2 -> 1.5.3
--------------

* [New] Add new method 'CArray#exp2'
* [New] Add new method 'CArray#log2'
* [New] Add new method 'CArray#logb'
* [New] Add new method 'CArray#remainder'
* [New] Add new method 'CArray.guard_undef'
* [New] Add new method 'CArray#data_class='
* [New] Add new method 'CArray.data_class?'
* [Mod] Modify 'CArray#pmax' to use 'fmax' for float type
* [Mod] Modify 'CArray#pmin' to use 'fmin' for float type
* [Mod] Remove method 'Object#undef?'
* [Mod] Remove method '::nan', '::inf'
* [Mod] Remove method 'TrueClass#*', 'FalseClass#*' (unknown origin)
* [Fix] Fix invalid access for CAUnboundRepeat using index
* [Fix] Fix treatment of extra :* in operation between CAUnboundRepeat objects
* [Fix] Fix to accept Symbol for the name of data_class member
* [Fix] Fix 'CArray#uniq' to accept the array with the dimension more than 2.
* [Fix] Fix for CArray serialization to include data_class
* [Fix] Fix data_class inheritance in some methods in which new CArray is created.
* [Fix] Fix 'CArray#broadcast_to' to accept the case of dimension extension.

1.5.1 -> 1.5.2
--------------

* [New] Add new method 'CArray#sorted_with'
* [New] Add new method 'CArray#sort_with'
* [New] Add new method 'CArray#max_with'
* [New] Add new method 'CArray#min_with'
* [New] Add new method 'CArray.broadcast'
* [New] Add new method 'CArray#broadcast_to', 'CScalar#broadcast_to'
* [New] Add new API function `rb_ca_wrap_new`
* [Mod] Modify 'CArray#linspace' to return float64 array for integer arguments
* [Mod] Modify CAUnboundRepeat to have `ndim` same as the bounded array (before `ndim` same as parent array)
* [Mod] Remove the obsolete mothod 'CArray#dump'.
* [Mod] Remove the obsolete mothod 'CArray#load'.
* [Mod] Modify CArray.wrap_readonly to wrap string as array.
* [Fix] Add support for Integer (same as for Fixnum, Bignum)

1.5.0 -> 1.5.1
--------------

* [New] Add data type classes like 'Float64' ... to provide the methods like 'CArray::Float64.linspace'
* [Mod] Modify 'CArray.float64' ... without aruguments to return the corresponding data type class 
* [Mod] Set obsolete flag to 'CAIterator#sort_with'
* [Fix] Move C extension files into 'ext/'
* [Fix] Rename member 'rank' to 'ndim' in struct CArray in C extension
* [Fix] Remove 'CArray#shuffle' (gone to 'carray-random' gem)
* [Fix] Remove dependencies on 'rb_secure()' and 'rb_safe_level()'
* [Fix] Modify 'CArray#span' to handle fractional step for integer array

1.4.0 -> 1.5.0
--------------

* [Mod] Remove 'Carray#random!' (gone to 'carray-random' gem)
* [Mod] Relocate file 'lib/carray/io/table.rb' to 'lib/carray/table.rb'
* [Mod] Rename class 'CA::TableMethods' to 'CArray::TableMethods'
* [Mod] Rename method 'CArray#cast_other' to 'CArray#cast_with'
* [Mod] Change license from "Ruby's" to "MIT"
* [Mod] Remove files 'COPYING', 'LEGAL'(for MT), 'GPL'
* [Fix] Fix bug lib/carray/struct.rb
