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

    lib       - Ruby sorce codes
    ext       - C extension source codes
    utils     - support tools for development
    spec      - rspec files
    misc      - misc files

Licenses
--------

MIT (after version 1.5.0)
