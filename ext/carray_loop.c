/* ---------------------------------------------------------------------------

  carray_loop.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

static VALUE
rb_ca_s_each_index_internal (int ndim, VALUE *dim, uint8_t indim, VALUE ridx)
{
  volatile VALUE ret = Qnil;
  int32_t is_leaf = (indim == ndim - 1);
  ca_size_t i;

  if ( NIL_P(dim[indim]) ) {
    rb_ary_store(ridx, indim, Qnil);
    if ( is_leaf ) {
      ret = rb_yield_splat(rb_obj_clone(ridx));
    }
    else {
      ret = rb_ca_s_each_index_internal(ndim, dim, indim+1, ridx);
    }
  }
  else {
    for (i=0; i<NUM2SIZE(dim[indim]); i++) {
      rb_ary_store(ridx, indim, SIZE2NUM(i));
      if ( is_leaf ) {
        ret = rb_yield_splat(rb_obj_clone(ridx));
      }
      else {
        ret = rb_ca_s_each_index_internal(ndim, dim, indim+1, ridx);
      }
    }
  }

  return ret;
}

/* rdoc:
  #  Iterates with the multi-dimensional indeces for the given
  #  dimension numbers.
  #
  #     CArray.each_index(3,2){|i,j| print "(#{i} #{j}) " }
  #
  #  produces:
  #
  #     (0 0) (0 1) (1 0) (1 1) (2 0) (2 1) (3 0) (3 1)
  #
  def CArray.each_index(*argv) # :yields: i0, i1, ...
  end
*/

static VALUE
rb_ca_s_each_index (int ndim, VALUE *dim, VALUE self)
{
  volatile VALUE ridx = rb_ary_new2(ndim);
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, ndim, dim);
#endif
  return rb_ca_s_each_index_internal(ndim, dim, 0, ridx);
}

/* ------------------------------------------------------------------- */

/* rdoc:
  class CArray
    #
    def each # :yields: v
    end
  end
*/

static VALUE
rb_ca_each (VALUE self)
{
  volatile VALUE ret = Qnil;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  for (i=0; i<elements; i++) {
    ret = rb_yield(rb_ca_fetch_addr(self, i));
  }
  return ret;
}

/* rdoc:
  class CArray
    #
    def each_with_addr # :yields: v, addr
    end
  end
*/

static VALUE
rb_ca_each_with_addr (VALUE self)
{
  volatile VALUE ret = Qnil;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  for (i=0; i<elements; i++) {
    ret = rb_yield_values(2, rb_ca_fetch_addr(self, i), SIZE2NUM(i));
  }
  return ret;
}

/* rdoc:
  class CArray
    #
    def each_addr() # :yields: addr
    end
  end
*/

static VALUE
rb_ca_each_addr (VALUE self)
{
  volatile VALUE ret = Qnil;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  for (i=0; i<elements; i++) {
    ret = rb_yield(SIZE2NUM(i));
  }
  return ret;
}

static VALUE
rb_ca_each_index_internal (VALUE self, int8_t level, VALUE ridx)
{
  volatile VALUE ret = Qnil;
  CArray *ca;
  ca_size_t i;
  Data_Get_Struct(self, CArray, ca);
  if ( level == ca->ndim - 1 ) {
    for (i=0; i<ca->dim[level]; i++) {
      rb_ary_store(ridx, level, SIZE2NUM(i));
      ret = rb_yield_splat(rb_obj_clone(ridx));
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      rb_ary_store(ridx, level, SIZE2NUM(i));
      ret = rb_ca_each_index_internal(self, level+1, ridx);
    }
  }
  return ret;
}

/* rdoc:
  class CArray
    # Iterates with the multi-dimensional indeces for the dimension of <i>ca</i>.
    #
    #    CArray.int(3,2).each_index(){|i,j| print "(#{i} #{j}) " }
    #
    #  <em>produces:</em>
    #
    #     (0 0) (0 1) (1 0) (1 1) (2 0) (2 1) (3 0) (3 1)
    #
    def each_index # :yields: i0, i1, ...
    end
  end
*/

static VALUE
rb_ca_each_index (VALUE self)
{
  volatile VALUE ridx;
  int8_t ndim = NUM2INT(rb_ca_ndim(self));
  ridx = rb_ary_new2(ndim);
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  return rb_ca_each_index_internal(self, 0, ridx);
}

/* rdoc:
  class CArray
    #
    def map! # :yields: v
    end
  end
*/

static VALUE
rb_ca_map_bang (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);
  ca_attach(ca);
  for (i=0; i<elements; i++) {
    obj = rb_yield(rb_ca_fetch_addr(self, i));
    rb_ca_store_addr(self, i, obj);
  }
  ca_sync(ca);
  ca_detach(ca);
  return self;
}

static VALUE
rb_ca_each_with_index_internal (VALUE self,
                                int8_t level, ca_size_t *idx, VALUE ridx)
{
  volatile VALUE ret = Qnil;
  CArray *ca;
  ca_size_t i;
  Data_Get_Struct(self, CArray, ca);
  if ( level == ca->ndim - 1 ) {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ridx, level, SIZE2NUM(i));
      ret = rb_yield_values(2, rb_ca_fetch_index(self, idx),
                               rb_obj_clone(ridx));
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ridx, level, SIZE2NUM(i));
      ret = rb_ca_each_with_index_internal(self, level+1, idx, ridx);
    }
  }
  return ret;
}

/* rdoc:
  class CArray
    # 
    def each_with_index # :yields: v, idx 
    end
  end
*/

static VALUE
rb_ca_each_with_index (VALUE self)
{
  volatile VALUE ridx, ret;
  ca_size_t idx[CA_RANK_MAX];
  int8_t  ndim = NUM2INT(rb_ca_ndim(self));
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  rb_ca_modify(self);
  ridx = rb_ary_new2(ndim);
  ret  = rb_ca_each_with_index_internal(self, 0, idx, ridx);
  return ret;
}


static void
rb_ca_map_with_index_bang_internal (VALUE self,
                                    int8_t level, ca_size_t *idx, VALUE ridx)
{
  CArray *ca;
  ca_size_t i;
  Data_Get_Struct(self, CArray, ca);
  if ( level == ca->ndim - 1 ) {
    volatile VALUE obj;
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ridx, level, SIZE2NUM(i));
      obj = rb_yield_values(2, rb_ca_fetch_index(self, idx),
                               rb_obj_clone(ridx));
      rb_ca_store_index(self, idx, obj);
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ridx, level, SIZE2NUM(i));
      rb_ca_map_with_index_bang_internal(self, level+1, idx, ridx);
    }
  }
}

/* rdoc:
  class CArray
    #
    def map_with_index! # :yields: v, idx
    end
  end
*/

static VALUE
rb_ca_map_with_index_bang (VALUE self)
{
  volatile VALUE ridx;
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  int8_t  ndim = NUM2INT(rb_ca_ndim(self));
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);
  ca_attach(ca);
  ridx = rb_ary_new2(ndim);
  rb_ca_map_with_index_bang_internal(self, 0, idx, ridx);
  ca_sync(ca);
  ca_detach(ca);
  return self;
}


static void
rb_ca_map_index_bang_internal (VALUE self,
                               int8_t level, ca_size_t *idx, VALUE ridx)
{
  CArray *ca;
  ca_size_t i;
  Data_Get_Struct(self, CArray, ca);
  if ( level == ca->ndim - 1 ) {
    volatile VALUE obj;
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ridx, level, SIZE2NUM(i));
      obj = rb_yield_splat(rb_obj_clone(ridx));
      rb_ca_store_index(self, idx, obj);
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ridx, level, SIZE2NUM(i));
      rb_ca_map_index_bang_internal(self, level+1, idx, ridx);
    }
  }
}

/* rdoc:
  class CArray
    #
    def map_index! # :yields: i0, i1, ...
    end
  end
*/

static VALUE
rb_ca_map_index_bang (VALUE self)
{
  volatile VALUE ridx;
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  int8_t  ndim = NUM2INT(rb_ca_ndim(self));
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);
  ca_attach(ca);
  ridx = rb_ary_new2(ndim);
  rb_ca_map_index_bang_internal(self, 0, idx, ridx);
  ca_sync(ca);
  ca_detach(ca);
  return self;
}

/* rdoc:
  class CArray
    #
    def map_with_addr! # :yields: v, addr
    end
  end
*/

static VALUE
rb_ca_map_with_addr_bang (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);
  ca_attach(ca);
  for (i=0; i<elements; i++) {
    obj = rb_yield_values(2, rb_ca_fetch_addr(self, i), SIZE2NUM(i));
    rb_ca_store_addr(self, i, obj);
  }
  ca_sync(ca);
  ca_detach(ca);
  return self;
}


/* rdoc:
  class CArray
    #
    def map_addr! # :yields: addr
    end
  end
*/

static VALUE
rb_ca_map_addr_bang (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
#if RUBY_VERSION_CODE >= 190
  RETURN_ENUMERATOR(self, 0, 0);
#endif
  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);
  ca_attach(ca);
  for (i=0; i<elements; i++) {
    obj = rb_yield(SIZE2NUM(i));
    rb_ca_store_addr(self, i, obj);
  }
  ca_sync(ca);
  ca_detach(ca);
  return self;
}


void
Init_carray_loop ()
{
  rb_define_singleton_method(rb_cCArray, "each_index", rb_ca_s_each_index, -1);

  rb_define_method(rb_cCArray, "each", rb_ca_each, 0);
  rb_define_method(rb_cCArray, "each_addr", rb_ca_each_addr, 0);
  rb_define_method(rb_cCArray, "each_index", rb_ca_each_index, 0);
  rb_define_method(rb_cCArray, "each_with_addr", rb_ca_each_with_addr, 0);
  rb_define_method(rb_cCArray, "each_with_index", rb_ca_each_with_index, 0);

  rb_define_method(rb_cCArray, "map!", rb_ca_map_bang, 0);
  rb_define_method(rb_cCArray, "map_addr!", rb_ca_map_addr_bang, 0);
  rb_define_method(rb_cCArray, "map_index!", rb_ca_map_index_bang, 0);
  rb_define_method(rb_cCArray, "map_with_addr!", rb_ca_map_with_addr_bang, 0);
  rb_define_method(rb_cCArray, "map_with_index!", rb_ca_map_with_index_bang, 0);

  rb_define_method(rb_cCArray, "collect!", rb_ca_map_bang, 0);
  rb_define_method(rb_cCArray, "collect_addr!", rb_ca_map_addr_bang, 0);
  rb_define_method(rb_cCArray, "collect_index!", rb_ca_map_index_bang, 0);
  rb_define_method(rb_cCArray, "collect_with_addr!", rb_ca_map_with_addr_bang, 0);
  rb_define_method(rb_cCArray, "collect_with_index!", rb_ca_map_with_index_bang, 0);
}
