Ruby/CArray
===========

Ruby/CArray is an extension library for the multi-dimensional array class.

Features
--------

* Multidimensional array for storing uniform data
* Various ways to access data elements
* Masks for each element to handle missing values
* Element-wise operations and mathematical functions
* Statistical functions for the elements
* Indirect data manipulation for original array by virtual array 
* Special iterators (dimension, block, window, categorical)
* User-defined array
* Storing fixed length data with data_class
* Memory sharing with other objects (Experimental)

Requirements
------------

* Ruby 2.4.0 or later
* C compiler 
  + IEEE754 floating point number
  + C99 complex number

What is Ruby/CArray 
------------------

Ruby/CArray is an extension library for the multi-dimensional numerical array class. CArray stores integers or floating point numbers in memory block and treats them collectively to ensure the effecient performance. Therefore, Ruby/CArray is suitable for numerical computation and data analysis. Ruby/CArray has different features from other multidimensional array libraries (narray, numo-narray, nmatrix) for Ruby, such as element-wise masks, creation of reference arrays that can reflect changes to the referent, the ability to access memory block that the other object has, user-defined arrays, and so on.

#### Multi-dimensional uniform array ####

CArray is a collection class which can stores the array of values with uniform  data type of one of fixed width integer (8,16,32,64bits), floating point number (32,64bits), complex number (64,128bits), fixed-length string, ruby object. These values are stored in memory block as binary data. CArray has multi-dimensional array interface to access their values. The multi-dimensional array has the attributes of the dimension size (1,2,3,...) and the shape of dimension ([dim0], [dim0,dim1], [dim0,dim1,dim2],...) which define the size of array. 

#### Collective mathematical operations ####

CArray supports the collective calculation for the element-wise arithmetic operations and elemental mathematical functions. Additionally, some basic statistical summarization along specific dimensions are also provided.

#### Referencing data and virtual arrays ####

CArray provides various method for referencing data, such as adressing, slicing, conditional selection, adrress mapping, grid reference, transposing, shifting, rolling, data type conversion, reshaping, and so on. These data referencing are realized by creation of virtual arrays, so-called 'view'. The virtual array doesn’t have its own data and retrieves the data from the referent only on demand including dereferencing, copying or caluculation. Since a virtual array classes is a sub-class of CArray, it has the same interfaces to access data as CArray. The changes in the virtual array by storing data are refleted to the referent if permitted (if not a read_only array). Multiple heterogeneous chains of reference are also allowed, although the trade-offs with performance must be carefully considered.

#### Built-in Element-wise Mask Handling ####

CArray has its own masked state for each element (so-called element-wise mask).
By referring the element-wise mask, CArray can perform appropriate mathematical and statistical calculations on the data with missing values, as well as propagation of the mask state in operations.
Licenses
--------

MIT (after version 1.5.0)
