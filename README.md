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

Directories
-----------

    .         - Ruby/CArray extension source codes
    lib       - Ruby/CArray standard library in Ruby
    test      - some unit tests (incomplete)
    spec      - some rspec (incomplete)
    utils     - support tools for development.

Licenses
--------

MIT (after version 1.5.0)
