# ----------------------------------------------------------------------------
#
#  carray_cast_func.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------


data_type = []
%w[
  CA_FIXLEN
  CA_BOOLEAN
  CA_INT8
  CA_UINT8
  CA_INT16
  CA_UINT16
  CA_INT32
  CA_UINT32
  CA_INT64
  CA_UINT64
  CA_FLOAT32
  CA_FLOAT64
  CA_FLOAT128
  CA_CMPLX64
  CA_CMPLX128
  CA_CMPLX256
  CA_OBJECT
].each_with_index do |name, i|
  eval("#{name} = #{i}")
  data_type.push(i)
end

ctype = {
  CA_FIXLEN   => "fixlen",
  CA_BOOLEAN  => "boolean8_t",
  CA_INT8     => "int8_t",
  CA_UINT8    => "uint8_t",
  CA_INT16    => "int16_t",
  CA_UINT16   => "uint16_t",
  CA_INT32    => "int32_t",
  CA_UINT32   => "uint32_t",
  CA_INT64    => "int64_t",
  CA_UINT64   => "uint64_t",
  CA_FLOAT32  => "float32_t",
  CA_FLOAT64  => "float64_t",
  CA_FLOAT128 => "float128_t",
  CA_CMPLX64  => "cmplx64_t",
  CA_CMPLX128 => "cmplx128_t",
  CA_CMPLX256 => "cmplx256_t",
  CA_OBJECT   => "VALUE"
}

obj2cval = {
  CA_FIXLEN   => nil,
  CA_BOOLEAN  => "OBJ2BOOL",
  CA_INT8     => "OBJ2LONG",
  CA_UINT8    => "OBJ2ULONG",
  CA_INT16    => "OBJ2LONG",
  CA_UINT16   => "OBJ2ULONG",
  CA_INT32    => "OBJ2LONG",
  CA_UINT32   => "OBJ2ULONG",
  CA_INT64    => "OBJ2LL",
  CA_UINT64   => "OBJ2ULL",
  CA_FLOAT32  => "OBJ2DBL",
  CA_FLOAT64  => "OBJ2DBL",
  CA_FLOAT128 => "OBJ2DBL", ### upcast
  CA_CMPLX64  => "NUM2CC",
  CA_CMPLX128 => "NUM2CC",
  CA_CMPLX256 => "NUM2CC", ### upcast
  CA_OBJECT   => ""
}

cval2obj = {
  CA_FIXLEN   => nil,
  CA_BOOLEAN  => "BOOL2OBJ",
  CA_INT8     => "LONG2NUM",
  CA_UINT8    => "ULONG2NUM",
  CA_INT16    => "LONG2NUM",
  CA_UINT16   => "ULONG2NUM",
  CA_INT32    => "LONG2NUM",
  CA_UINT32   => "ULONG2NUM",
  CA_INT64    => "LL2NUM",
  CA_UINT64   => "ULL2NUM",
  CA_FLOAT32  => "rb_float_new",
  CA_FLOAT64  => "rb_float_new",
  CA_FLOAT128 => "rb_float_new", ### downcast
  CA_CMPLX64  => "rb_ccomplex_new",
  CA_CMPLX128 => "rb_ccomplex_new",
  CA_CMPLX256 => "rb_ccomplex_new", ### downcast
  CA_OBJECT   => ""
}

NUMERIC = [
  CA_INT8     ,
  CA_UINT8    ,
  CA_INT16    ,
  CA_UINT16   ,
  CA_INT32    ,
  CA_UINT32   ,
  CA_INT64    ,
  CA_UINT64   ,
  CA_FLOAT32  ,
  CA_FLOAT64  ,
  CA_FLOAT128 ,
  CA_CMPLX64  ,
  CA_CMPLX128 ,
  CA_CMPLX256 ,
]

INTEGER = [
  CA_INT8     ,
  CA_UINT8    ,
  CA_INT16    ,
  CA_UINT16   ,
  CA_INT32    ,
  CA_UINT32   ,
  CA_INT64    ,
  CA_UINT64   ,
]

BOOLEAN = [
  CA_BOOLEAN
]

FIXLEN = [
  CA_FIXLEN
]

OBJECT = [
  CA_OBJECT
]

CA_CAST_TABLE = {}
data_type.each do |type1|
  CA_CAST_TABLE[type1] = Hash.new("ca_cast_not_implemented")
end

data_type.each do |type1|
  data_type.each do |type2|
    ctype1 = ctype[type1]
    ctype2 = ctype[type2]
  end
end

#
#
#

puts %{
/* ---------------------------------------------------------------------------

  carray_cast_func.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby\'s licence.

  This file is automatically generated from carray_math.rb.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

static void
ca_cast_not_implemented(int32_t n, CArray *a1, void *ptr1, CArray *a2, void *ptr2, boolean8_t *m)
{
  rb_raise(rb_eCADataTypeError, 
           "can not cast data type from <%s> to <%s>",
           ca_type_name[a1->data_type], ca_type_name[a2->data_type]);
}

}

puts "/* ------------------ FIXLEN -> FIXLEN ------------------------ */"
puts
FIXLEN.each do |type1|
  FIXLEN.each do |type2|
    ctype1 = ctype[type1]
    ctype2 = ctype[type2]
    CA_CAST_TABLE[type1][type2] = "ca_cast_#{ctype1}_#{ctype2}"
    puts <<-END_DEF  .gsub(/^ {6}/, '')
      static void
      ca_cast_#{ctype1}_#{ctype2}(int32_t n, CArray *a1, void *ptr1, CArray *a2, void *ptr2, boolean8_t *m)
      {
         char *p1 = ptr1;
         int32_t bytes1;
         char *p2 = ptr2;
         int32_t bytes2;
         if ( a1 == NULL || a2 == NULL ) {
           rb_raise(rb_eRuntimeError, "[BUG] failed to cast fixlen -> fixlen");
         }
         bytes1 = a1->bytes;
         bytes2 = a2->bytes;
         if ( m ) {
           while ( n-- ) {
             if ( !*m ) {
               if ( bytes2 <= bytes1 ) {
                 memcpy(p2, p1, bytes2);
               }
               else {
                 memset(p2, 0, bytes2);
                 memcpy(p2, p1, bytes1);
               }
             }
             p1+=bytes1; p2+=bytes2; m++;
           }
         }
         else {
           while ( n-- ) {
             if ( bytes2 <= bytes1 ) {
               memcpy(p2, p1, bytes2);
             }
             else {
               memset(p2, 0, bytes2);
               memcpy(p2, p1, bytes1);
             }
             p1+=bytes1; p2+=bytes2;
           }
         }
         return;
      }
    END_DEF
    puts
  end
end

puts "/* ------------------ FIXLEN -> OBJECT ------------------------ */"
puts
FIXLEN.each do |type1|
  OBJECT.each do |type2|
    ctype1 = ctype[type1]
    ctype2 = ctype[type2]
    CA_CAST_TABLE[type1][type2] = "ca_cast_#{ctype1}_#{ctype2}"
    puts <<-END_DEF  .gsub(/^ {6}/, '')
      static void
      ca_cast_#{ctype1}_#{ctype2}(int32_t n, CArray *a1, void *ptr1, CArray *a2, void *ptr2, boolean8_t *m)
      {
         char  *p1 = ptr1;
         int32_t bytes;
         VALUE *p2 = ptr2;
         if ( a1 == NULL ) {
           rb_raise(rb_eRuntimeError, "[BUG] failed to cast fixlen -> object");
         }
         bytes = a1->bytes;
         if ( m ) {
           while ( n-- ) {
             if ( !*m ) { *p2 = rb_str_new(p1, bytes); OBJ_TAINT(*p2); }
             p1+=bytes; p2++; m++;
           }
         }
         else {
           while ( n-- ) {
             *p2 = rb_str_new(p1, bytes); 
             OBJ_TAINT(*p2); 
             p1+=bytes; p2++;
           }
         }
         return;
      }
    END_DEF
    puts
  end
end

puts "/* ------------------ BOOLEAN+INTEGER -> BOOLEAN ------------------------ */"
puts
(BOOLEAN+INTEGER).each do |type1|
  BOOLEAN.each do |type2|
    ctype1 = ctype[type1]
    ctype2 = ctype[type2]
    CA_CAST_TABLE[type1][type2] = "ca_cast_#{ctype1}_#{ctype2}"
    puts <<-END_DEF  .gsub(/^ {6}/, '')
      static void
      ca_cast_#{ctype1}_#{ctype2}(int32_t n, CArray *a1, void *ptr1, CArray *a2, void *ptr2, boolean8_t *m)
      {
         #{ctype1} *p1 = ptr1;
         #{ctype2} *p2 = ptr2;
         #{ctype1} q;
         if ( m ) {
           while ( n-- ) { 
             if ( !*m ) { 
               q = *p1;
               if ( q == 0 || q == 1 ) {
                 *p2 = q;
               }
               else {
                 rb_raise(rb_eRuntimeError, "out of range to cast to boolean (0 or 1)");
               }
             }
             p1++; p2++; m++;
           }
         }
         else {
           while ( n-- ) { 
             q = *p1;
             if ( q == 0 || q == 1 ) {
               *p2 = q;
             }
             else {
               rb_raise(rb_eRuntimeError, "out of range to cast to boolean (0 or 1)");
             }
             p1++; p2++; 
           }
         }
         return;
      }
    END_DEF
    puts
  end
end

puts "/* ------------------ BOOLEAN+NUMERIC -> NUMERIC ------------------------ */"
puts
(BOOLEAN+NUMERIC).each do |type1|
  NUMERIC.each do |type2|
    ctype1 = ctype[type1]
    ctype2 = ctype[type2]
    CA_CAST_TABLE[type1][type2] = "ca_cast_#{ctype1}_#{ctype2}"
    puts <<-END_DEF  .gsub(/^ {6}/, '')
      static void
      ca_cast_#{ctype1}_#{ctype2}(int32_t n, CArray *a1, void *ptr1, CArray *a2, void *ptr2, boolean8_t *m)
      {
         #{ctype1} *q1 = ptr1;
         #{ctype1} *p1 = q1;
         #{ctype2} *q2 = ptr2;
         #{ctype2} *p2 = q2;
         int32_t k;
         if ( m ) {
           boolean8_t *pm = m;
           #ifdef _OPENMP
           #pragma omp parallel for private(pm,p1,p2)
           #endif
           for (k=0; k<n; k++) {
             pm = m + k;
             if ( ! *pm ) { 
               p1 = q1 + k;
               p2 = q2 + k;
               *p2 = (#{ctype2}) *p1;
             }
           }
         }
         else {
           #ifdef _OPENMP
           #pragma omp parallel for private(p1,p2)
           #endif
           for (k=0; k<n; k++) {
             p1 = q1 + k;
             p2 = q2 + k;
             *p2 = (#{ctype2}) *p1;
           }
         }
         return;
      }
    END_DEF
    puts
  end
end

puts "/* ------------------ BOOLEAN+NUMERIC -> OBJECT ------------------------ */"
puts
(BOOLEAN+NUMERIC).each do |type1|
  OBJECT.each do |type2|
    ctype1 = ctype[type1]
    ctype2 = ctype[type2]
    unless conv = cval2obj[type1]
      next
    end
    CA_CAST_TABLE[type1][type2] = "ca_cast_#{ctype1}_#{ctype2}"
    puts <<-END_DEF  .gsub(/^ {6}/, '')
      static void
      ca_cast_#{ctype1}_#{ctype2}(int32_t n, CArray *a1, void *ptr1, CArray *a2, void *ptr2, boolean8_t *m)
      {
         #{ctype1} *p1 = ptr1;
         VALUE *p2 = ptr2;
         if ( m ) {
           while ( n-- ) { 
             if ( !*m ) { *p2 = #{conv}(*p1); } 
             p1++; p2++; m++;
           }
         }
         else {
           while ( n-- ) { *p2 = #{conv}(*p1); p1++; p2++; }
         }
         return;
      }
    END_DEF
    puts
  end
end

puts "/* ------------------ OBJECT -> FIXLEN ------------------------ */"
puts
OBJECT.each do |type1|
  FIXLEN.each do |type2|
    ctype1 = ctype[type1]
    ctype2 = ctype[type2]
    CA_CAST_TABLE[type1][type2] = "ca_cast_#{ctype1}_#{ctype2}"
    puts <<-END_DEF  .gsub(/^ {6}/, '')
      static void
      ca_cast_#{ctype1}_#{ctype2}(int32_t n, CArray *a1, void *ptr1, CArray *a2, void *ptr2, boolean8_t *m)
      {
         VALUE *p1 = ptr1;
         char *p2 = ptr2;
         int32_t bytes;
         if ( a2 == NULL ) {
           rb_raise(rb_eRuntimeError, "[BUG] failed to cast object -> fixlen");
         }
         bytes = a2->bytes;
         if ( m ) {
           while ( n-- ) {
             if ( !*m ) {
               VALUE str = *p1;
               Check_Type(str, T_STRING);
               if ( bytes <= RSTRING_LEN(str) ) {
                 memcpy(p2, StringValuePtr(str), bytes);
               }
               else {
                 memset(p2, 0, bytes);
                 memcpy(p2, StringValuePtr(str), RSTRING_LEN(str));
               }
             }
             p1++; p2+=bytes; m++;
           }
         }
         else {
         while ( n-- ) {
           VALUE str = *p1;
           Check_Type(str, T_STRING);
           if ( bytes <= RSTRING_LEN(str) ) {
             memcpy(p2, StringValuePtr(str), bytes);
           }
           else {
             memset(p2, 0, bytes);
             memcpy(p2, StringValuePtr(str), RSTRING_LEN(str));
           }
           p1++; p2+=bytes;
         }
         }
         return;
      }
    END_DEF
    puts
  end
end


puts "/* ------------------ OBJECT -> BOOLEAN+NUMERIC+OBJECT ------------------------ */"
puts
OBJECT.each do |type1|
  (BOOLEAN+NUMERIC+OBJECT).each do |type2|
    ctype1 = ctype[type1]
    ctype2 = ctype[type2]
    unless conv = obj2cval[type2]
      next
    end
    CA_CAST_TABLE[type1][type2] = "ca_cast_#{ctype1}_#{ctype2}"
    puts <<-END_DEF  .gsub(/^ {6}/, '')
      static void
      ca_cast_#{ctype1}_#{ctype2}(int32_t n, CArray *a1, void *ptr1, CArray *a2, void *ptr2, boolean8_t *m)
      {
         VALUE *p1 = ptr1;
         #{ctype2} *p2 = ptr2;
         if ( m ) {
           while ( n-- ) { 
             if ( !*m ) { *p2 = #{conv}(*p1); }
             p1++; p2++; m++;
           }
         }
         else {
           while ( n-- ) { *p2 = #{conv}(*p1); p1++; p2++; }
         }
         return;
      }
    END_DEF
    puts
  end
end

puts "/* ------------------ ca_cast_func_table ------------------------ */"
puts
puts "ca_cast_func_t"
puts "ca_cast_func_table[CA_NTYPE][CA_NTYPE] = {"
test = data_type.map { |type1|
  list = data_type.map { |type2| "    " + CA_CAST_TABLE[type1][type2] }
  "  {\n" + list.join(",\n") + "\n  }"
}.join(",\n")
puts test
puts "};"

puts

