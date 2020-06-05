# ----------------------------------------------------------------------------
#
#  mkmath.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require 'stringio'

def monfunc (op, name, hash)
  io = StringIO.new
  io.puts
  io.puts "/*----------------------- #{name} --------------------------*/"
  hash.each do |types, expr0|
    if not expr0
      next
    end
    expr0.gsub!(/#/, '*p')
    types.each do |type|
      if type
        expr = expr0.gsub(/<type>/, type)
        omp_ok = ( type != "VALUE" ) ? 1 : 0
        io.print %{
static void
ca_monop_#{name}_#{type} (ca_size_t n, boolean8_t *m, char *ptr1, ca_size_t i1, char *ptr2, ca_size_t i2)
{
  #{type} *q1 = (#{type} *) ptr1, *q2 = (#{type} *) ptr2;
  #{type} *p1 = q1, *p2 = q2;
  ca_size_t k;
  if ( m ) {
    boolean8_t *pm;
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(pm,p1,p2)
    #endif
    for (k=0; k<n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        {
          #{expr} 
        }
      }
    }
  }
  else {
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(p1,p2)
    #endif
    for (k=0; k<n; k++) {
      p1 = q1 + k*i1;
      p2 = q2 + k*i2;
      {
        #{expr}
      }
    }
  }
}
}
      end
    end
  end
  io.puts
  io.puts "ca_monop_func_t"
  io.puts "ca_monop_#{name}[CA_NTYPE] = {"
  ALL_TYPES.each_index do |i|
    type = nil
    hash.each do |types, expr|
      if not expr
        next
      end
      type ||= types[i]
    end
    if type
      io.puts("  ca_monop_#{name}_#{type},")
    else
      io.puts("  ca_monop_not_implement,")
    end
  end
  io.puts "};"
  io.puts
  if hash.has_key?(INT_TYPES) or hash.has_key?(ALL_TYPES)
    io.print %{
static VALUE rb_ca_#{name} (VALUE self)
{ return rb_ca_call_monop(self, ca_monop_#{name}); }
}
  else
    io.print %{
static VALUE rb_ca_#{name} (VALUE self)
{ 
  if ( rb_ca_is_integer_type(self) ) {
    self = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));
  }
  return rb_ca_call_monop(self, ca_monop_#{name}); 
}
}
  end
  io.print %{
static VALUE rb_ca_#{name}_bang (VALUE self)
{ return rb_ca_call_monop_bang(self, ca_monop_#{name}); }
}
  DEFINITIONS << io.string
  if op
    METHODS     << %{
  rb_define_method(rb_cCArray, "#{op}", rb_ca_#{name}, 0);
}
  end
  METHODS     << %{
  rb_define_method(rb_cCArray, "#{name}!", rb_ca_#{name}_bang, 0);
}
  DEFINITIONS << %{
static VALUE rb_cmath_#{name} (VALUE mod, VALUE arg)
{ return ca_math_call(mod, arg, rb_intern("#{name}")); }
}
  METHODS << %{
  rb_define_module_function(rb_mCAMath, "#{name}", rb_cmath_#{name}, 1);
}
end


def monop (op, name, hash)
  io = StringIO.new
  io.puts
  io.puts "/*----------------------- #{name} --------------------------*/"
  hash.each do |types, expr0|
    if not expr0
      next
    end
    expr0.gsub!(/#/, '*p')
    types.each do |type|
      if type
        expr = expr0.gsub(/<type>/, type)
        omp_ok = ( type != "VALUE" ) ? 1 : 0
        io.print %{
static void
ca_monop_#{name}_#{type} (ca_size_t n, boolean8_t *m, char *ptr1, ca_size_t i1, char *ptr2, ca_size_t i2)
{
  #{type} *q1 = (#{type} *) ptr1, *q2 = (#{type} *) ptr2;
  #{type} *p1 = q1, *p2 = q2;
  ca_size_t k;
  if ( m ) {
    boolean8_t *pm;
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(pm,p1,p2)
    #endif
    for (k=0; k<n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        {
          #{expr} 
        }
      }
    }
  }
  else {
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(p1,p2)
    #endif
    for (k=0; k<n; k++) {
      p1 = q1 + k*i1;
      p2 = q2 + k*i2;
      {
        #{expr} 
      }
    }
  }
}
}
      end
    end
  end
  io.puts
  io.puts "ca_monop_func_t"
  io.puts "ca_monop_#{name}[CA_NTYPE] = {"
  ALL_TYPES.each_index do |i|
    type = nil
    hash.each do |types, expr|
      if not expr
        next
      end
      type ||= types[i]
    end
    if type
      io.puts("  ca_monop_#{name}_#{type},")
    else
      io.puts("  ca_monop_not_implement,")
    end
  end
  io.puts "};"
  io.puts
  io.print %{
static VALUE rb_ca_#{name} (VALUE self)
{ return rb_ca_call_monop(self, ca_monop_#{name}); }
static VALUE rb_ca_#{name}_bang (VALUE self)
{ return rb_ca_call_monop_bang(self, ca_monop_#{name}); }
  }
  DEFINITIONS << io.string
  if op
    METHODS     << %{
  rb_define_method(rb_cCArray, "#{op}", rb_ca_#{name}, 0);
}
  end
  METHODS     << %{
  rb_define_method(rb_cCArray, "#{name}!", rb_ca_#{name}_bang, 0);
}

end

def binop (op, name, hash)
  io = StringIO.new
  io.puts
  io.puts "/*----------------------- #{name} --------------------------*/"
  hash.each do |types, expr0|
    if not expr0
      next
    end
    expr0.gsub!(/#/, '*p')
    types.each do |type|
      if type
        expr = expr0.gsub(/<type>/, type)
        omp_ok = ( type != "VALUE" ) ? 1 : 0
        io.print %{
static void
ca_binop_#{name}_#{type} (ca_size_t n, boolean8_t *m, char *ptr1, ca_size_t i1, char *ptr2, ca_size_t i2, char *ptr3, ca_size_t i3)
{
  #{type} *q1 = (#{type} *) ptr1, *q2 = (#{type} *) ptr2, *q3 = (#{type} *) ptr3;
  #{type} *p1 = q1, *p2 = q2, *p3 = q3;
  ca_size_t k;
  if ( m ) {
    boolean8_t *pm;
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(pm,p1,p2,p3)
    #endif
    for (k=0; k<n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        p3 = q3 + k*i3;
        {
          #{expr} 
        }
      }
    }
  }
  else {
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(p1,p2,p3)
    #endif
    for (k=0; k<n; k++) {
      p1 = q1 + k*i1;
      p2 = q2 + k*i2;
      p3 = q3 + k*i3;
      {
        #{expr}
      }
    }
  }
}
}
      end
    end
  end
  io.puts
  io.puts "ca_binop_func_t"
  io.puts "ca_binop_#{name}[CA_NTYPE] = {"
  ALL_TYPES.each_index do |i|
    type = nil
    hash.each do |types, expr|
      if not expr
        next
      end
      type ||= types[i]
    end
    if type
      io.puts("  ca_binop_#{name}_#{type},")
    else
      io.puts("  ca_binop_not_implement,")
    end
  end
  io.puts "};"
  io.puts
  io.print %{
static VALUE rb_ca_#{name} (VALUE self, VALUE other)
{ 
  if ( ! rb_ca_test_castable(other) ) {
    return rb_ca_binop_pass_to_other(self, other, rb_intern("#{op}"));
  }
  return rb_ca_call_binop(self, other, ca_binop_#{name}); 
}
static VALUE rb_ca_#{name}_bang (VALUE self, VALUE other)
{ return rb_ca_call_binop_bang(self, other, ca_binop_#{name}); }
  }
  DEFINITIONS << io.string
  if op
    METHODS     << %{
  rb_define_method(rb_cCArray, "#{op}", rb_ca_#{name}, 1);
}
  end
  METHODS     << %{
  rb_define_method(rb_cCArray, "#{op}!", rb_ca_#{name}_bang, 1);
}

end

def moncmp (op, name, hash)
  io = StringIO.new
  io.puts
  io.puts "/*----------------------- #{name} --------------------------*/"
  hash.each do |types, expr0|
    if not expr0
      next
    end
    expr0.gsub!(/#/, '*p')
    types.each do |type|
      if type
        expr = expr0.gsub(/<type>/, type)
        omp_ok = ( type != "VALUE" ) ? 1 : 0
        io.print %{
static void
ca_moncmp_#{name}_#{type} (ca_size_t n, boolean8_t *m, char *ptr1, ca_size_t i1, boolean8_t *ptr2, ca_size_t i2)
{
  #{type} *q1 = (#{type} *) ptr1;
  #{type} *p1 = q1;
  boolean8_t *q2 = (boolean8_t *) ptr2;
  boolean8_t *p2 = q2;
  ca_size_t k;
  if ( m ) {
    boolean8_t *pm = m;
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(pm,p1,p2)
    #endif
    for (k=0; k<n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        {
          #{expr} 
        }
      }
    }
  }
  else {
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(p1,p2)
    #endif
    for (k=0; k<n; k++) {
      p1=q1+k*i1;
      p2=q2+k*i2;
      {
        #{expr}
      }
    }
  }
}
}
      end
    end
  end
  io.puts
  io.puts "ca_moncmp_func_t"
  io.puts "ca_moncmp_#{name}[CA_NTYPE] = {"
  ALL_TYPES.each_index do |i|
    type = nil
    hash.each do |types, expr|
      if not expr
        next
      end
      type ||= types[i]
    end
    if type
      io.puts("  ca_moncmp_#{name}_#{type},")
    else
      io.puts("  ca_moncmp_not_implement,")
    end
  end
  io.puts "};"
  io.puts
  io.print %{
static VALUE rb_ca_#{name} (VALUE self, VALUE other)
{ return rb_ca_call_moncmp(self, ca_moncmp_#{name}); }
  }
  DEFINITIONS << io.string
  if op
    METHODS     << %{
  rb_define_method(rb_cCArray, "#{op}", rb_ca_#{name}, 0);
}
  end
end

EPSILON = {
  "float32_t" => "FLT_EPSILON",
  "float64_t" => "DBL_EPSILON",
  "float128_t" => "DBL_EPSILON",
}

def bincmp (op, name, hash)
  io = StringIO.new
  io.puts
  io.puts "/*----------------------- #{name} --------------------------*/"
  hash.each do |types, expr0|
    if not expr0
      next
    end
    expr0.gsub!(/#(\d)/, '*p\1')
    types.each do |type|
      if type 
        expr = expr0.clone
        expr.gsub!(/<type>/, type)
        expr.gsub!(/<epsilon>/, EPSILON[type]||"")
        if type != "fixlen"
          omp_ok = ( type != "VALUE" ) ? 1 : 0
          io.print %{
static void
ca_bincmp_#{name}_#{type} (ca_size_t n, boolean8_t *m, 
                           char *ptr1, ca_size_t b1, ca_size_t i1, 
                           char *ptr2, ca_size_t b2, ca_size_t i2, 
                           char *ptr3, ca_size_t b3, ca_size_t i3)
{
  #{type} *q1 = (#{type} *) ptr1, *q2 = (#{type} *) ptr2;
  #{type} *p1 = q1, *p2 = q2;
  boolean8_t *q3 = (boolean8_t *) ptr3;
  boolean8_t *p3 = q3;
  ca_size_t k;
  if ( m ) {
    boolean8_t *pm = m;
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(pm,p1,p2,p3)
    #endif
    for (k=0; k<n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*i1;
        p2 = q2 + k*i2;
        p3 = q3 + k*i3;
        {
          #{expr} 
        }
      }
    }
  }
  else {
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(p1,p2,p3)
    #endif
    for (k=0; k<n; k++) {
      p1=q1+k*i1;
      p2=q2+k*i2;
      p3=q3+k*i3;
      {
        #{expr}
      }
    }
  }
}
}
        else ### fixlen
          omp_ok = 1
          io.print %{
static void
ca_bincmp_#{name}_#{type} (ca_size_t n, boolean8_t *m, 
                           char *ptr1, ca_size_t b1, ca_size_t i1, 
                           char *ptr2, ca_size_t b2, ca_size_t i2, 
                           char *ptr3, ca_size_t b3, ca_size_t i3)
{
  char *q1 = ptr1, *q2 = ptr2;
  char *p1 = q1, *p2 = q2;
  boolean8_t *q3 = (boolean8_t *) ptr3;
  boolean8_t *p3 = q3;
  ca_size_t s1 = b1*i1, s2 = b2*i2, s3 = b3*i3;
  ca_size_t k;
  if ( m ) {
    boolean8_t *pm = m;
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(pm,p1,p2,p3)
    #endif
    for (k=0; k<n; k++) {
      pm = m + k;
      if ( ! *pm ) {
        p1 = q1 + k*s1;
        p2 = q2 + k*s2;
        p3 = q3 + k*s3;
        {
          #{expr} 
        }
      }
    }
  }
  else {
    #if defined(_OPENMP) && #{omp_ok}
    #pragma omp parallel for private(p1,p2,p3)
    #endif
    for (k=0; k<n; k++) {
      p1=q1+k*s1;
      p2=q2+k*s2;
      p3=q3+k*s3;
      {
        #{expr}
      }
    }    
  }
}
} 
        end
      end
    end
  end
  io.puts
  io.puts "ca_bincmp_func_t"
  io.puts "ca_bincmp_#{name}[CA_NTYPE] = {"
  ALL_TYPES.each_index do |i|
    type = nil
    hash.each do |types, expr|
      if not expr
        next
      end
      type ||= types[i]
    end
    if type
      io.puts("  ca_bincmp_#{name}_#{type},")
    else
      io.puts("  ca_bincmp_not_implement,")
    end
  end
  io.puts "};"
  io.puts
  io.print %{
static VALUE rb_ca_#{name} (VALUE self, VALUE other)
{ 
  if ( ! rb_ca_test_castable(other) ) {
    return rb_ca_binop_pass_to_other(self, other, rb_intern("#{op}"));
  }
  return rb_ca_call_bincmp(self, other, ca_bincmp_#{name});
}
  }
  DEFINITIONS << io.string
  if op
    METHODS     << %{
  rb_define_method(rb_cCArray, "#{op}", rb_ca_#{name}, 1);
}
  end
end

def alias_op (op, name)
  METHODS     << %{
  rb_define_alias(rb_cCArray, "#{op}", "#{name}");
}
end

ALL_TYPES = [
  nil,
  nil,
  "int8_t",
  "uint8_t",
  "int16_t",
  "uint16_t",
  "int32_t",
  "uint32_t",
  "int64_t",
  "uint64_t",
  "float32_t",
  "float64_t",
  "float128_t",
  nil,
  nil,
  nil,
  nil,
]

BOOL_TYPES = [
  nil,
  "boolean8_t",
  nil, #"int8_t",
  nil, #"uint8_t",
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
]

INT_TYPES = [
  nil,
  nil,
  "int8_t",
  "uint8_t",
  "int16_t",
  "uint16_t",
  "int32_t",
  "uint32_t",
  "int64_t",
  "uint64_t",
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
]

FLOAT_TYPES = [
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  "float32_t",
  "float64_t",
  "float128_t",
  nil,
  nil,
  nil,
  nil,
]

CMPLX_TYPES = [
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  "cmplx64_t",
  "cmplx128_t",
  "cmplx256_t",
  nil,
]

OBJ_TYPES = [
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  "VALUE",
]

FIXLEN_TYPES = [
  "fixlen",
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
]

begin
  open("carray_config.h") { |io|
    have_complex = false
    while line = io.gets
      if line =~ /HAVE_COMPLEX_H\s+(\d*)\s*/
        have_complex = ($1.to_i == 1)
        break
      end
    end
    HAVE_COMPLEX = have_complex
  }
end

HEADERS     = ""
DEFINITIONS = ""
METHODS     = ""

CODETEXT    = <<HERE
<headers>

#include <math.h>
#include "carray.h"

<definitions>

void
Init_<name> ()
{
  <methods>
}

HERE

def create_code (name, filename)
  code = CODETEXT.clone
  code.sub!("<name>", name)
  code.sub!("<headers>", HEADERS)
  code.sub!("<definitions>", DEFINITIONS)
  code.sub!("<methods>", METHODS)
  open(filename, "w") { |io|
    io.write code
  }
end

