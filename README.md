Ruby/CArray
===========

Ruby/CArray is an extension library for the multi-dimensional array class.

Features
--------

* Collection class for multidimensional array storing the value with uniform data type
* Element-wise mathematical operations and functions
* Statistical operation for the elements
* Various methods for referencing data elements
* Internally included element-wise mask to handle missing values
* Indirect data manipulation to referent by virtual array 
* Special iterators (dimension, block, window, categorical)
* User-defined array class with same multi-dimensional interfaces as CArray
* Accessing the partial data in fixed length data via data_class interface
* Wrapping the memory block owned by the other object (such as NArray).

Requirements
------------

* Ruby 2.4.0 or later
* C compiler 
  + IEEE754 floating point number
  + C99 complex number

What is Ruby/CArray 
------------------

Ruby/CArray is an extension library for the multi-dimensional numerical array class. The name "CArray" comes from the meaning of a wrapper to a numerical array handled by the C language. CArray stores integers or floating-point numbers in memory block and treats them collectively to ensure efficient performance. Therefore, Ruby/CArray is suitable for numerical computation and data analysis. 

#### Multi-dimensional uniform array ####

CArray is a collection class that can store the array of values with a uniform data type of one of fixed-width integer (8,16,32,64bits), floating-point number (32,64bits), complex number (64,128bits), fixed-length string, ruby object. These values are stored in memory block as binary data. CArray has multi-dimensional interfaces for the array to access their values. The multi-dimensional array has the attributes of the dimension size (1,2,3,...) and the shape of dimension ([dim0], [dim0,dim1], [dim0,dim1,dim2],...) which define the size of array. 

#### Collective mathematical operations ####

CArray supports the collective calculation for the element-wise arithmetic operations and mathematical elementary functions. Additionally, some basic statistical summarization along specific dimensions are also provided.

#### Referencing data and virtual arrays ####

CArray provides various methods for referencing data, such as addressing, slicing, selection by condition, address mapping, grid reference, transposing, shifting, rolling, data type conversion, reshaping, and so on. These data referencing are realized by the creation of virtual arrays, so-called 'view'. The virtual array doesn't have its data and retrieves the data from the referent only on-demand, including dereferencing, copying, or calculation. Since virtual array classes are sub-class of CArray, it has the same interfaces to access data as CArray. The changes in a virtual array by storing data are also reflected in the referent (if not a read_only array). Multiple heterogeneous chains of reference are also allowed, although the trade-offs with performance must be carefully considered.

#### Built-in element-wise mask handling ####

CArray possesses masked states about each element (so-called "element-wise mask"). By referring the element-wise mask, CArray can perform mathematical and statistical calculations on the data with missing values by appropriate handling of masked elements. , which include the propagation of mask state to result in element-wise arithmetics and ignoring the masked elements in a statistical calculation, and so on.

#### User-defined array ####

User can define new virtual array class in Ruby level or C-extension level with TemplateMethod pattern. They are defined as subclass of CAObject in Ruby level and as subclass of CAVirtual in C-extension level. In particular, at the Ruby level, you can easily define a CArray-like class by implementing just a few template methods.

License
-------

MIT (after version 1.5.0)
