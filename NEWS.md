ChangeLog of Ruby/CArray
========================

1.5.1 -> 1.5.2
--------------

* [New] Add new method 'CArray#sorted_with'
* [New] Add new method 'CArray#sort_with'
* [New] Add new method 'CArray#max_with'
* [New] Add new method 'CArray#min_with'
* [New] Add new method 'CArray.broadcast'
* [New] Add new method 'CArray#broadcast_to', 'CScalar#broadcast_to'
* [Fix] Modify 'CArray#linspace' to return float64 array for integer arguments
* [Fix] Add support for Integer (same as for Fixnum, Bignum)

1.5.0 -> 1.5.1
--------------

* [New] Add data type classes like 'Float64' ... to provide the methods like 'CArray::Float64.linspace'
* [Mod] Modify 'CArray.float64' ... without aruguments to return the corresponding data type class 
* [Fix] Move C extension files into 'ext/'
* [Fix] Rename member 'rank' to 'ndim' in struct CArray in C extension
* [Fix] Remove 'CArray#shuffle' (gone to 'carray-random' gem)
* [Fix] Remove dependencies on 'rb_secure()' and 'rb_safe_level()'
* [Fix] Modify 'CArray#span' to handle fractional step for integer array
* [Obsolete] Set obsolete flag to 'CAIterator#sort_with'

1.4.0 -> 1.5.0
--------------

* [Mod] Remove 'Carray#random!' (gon..x/e to 'carray-random' gem)
* [Mod] Relocate file 'lib/carray/io/table.rb' to 'lib/carray/table.rb'
* [Mod] Rename class 'CA::TableMethods' to 'CArray::TableMethods'
* [Mod] Rename method 'CArray#cast_other' to 'CArray#cast_with'
* [Mod] Change license from "Ruby's" to "MIT"
* [Mod] Remove files 'COPYING', 'LEGAL'(for MT), 'GPL'
* [Fix] Fix bug lib/carray/struct.rb
