/* ---------------------------------------------------------------------------

  Block-based iteration entry points: each / each_addr / each_index /
  each_with_addr / each_with_index and their map! / collect! siblings.
  Pure per-cell Ruby callback paths (= no kernel_iterator); used when
  the caller wants Ruby block semantics over flat addresses or
  multi-dim indices.  Bound at the bottom by Init_carray_loop.

  User-facing docs live in yard-stubs/carray_loop.rb.

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

/* CArray.each_index(*shape) -- class method.  Walks the cartesian
   product of `0...d` for each `d` in `shape` and yields the index
   tuple via rb_yield_splat (= block receives |i, j, ...| individual
   args).  Independent of any CArray instance. */
static VALUE
rb_ca_s_each_index (int ndim, VALUE *dim, VALUE self)
{
  volatile VALUE ridx = rb_ary_new2(ndim);
  RETURN_ENUMERATOR(self, ndim, dim);
  return rb_ca_s_each_index_internal(ndim, dim, 0, ridx);
}

/* ------------------------------------------------------------------- */

/* CArray#each {|elem| ... } -- yield each cell value in flat-address
   order via rb_ca_fetch_addr (per-cell Ruby callback). */
static VALUE
rb_ca_each (VALUE self)
{
  volatile VALUE ret = Qnil;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
  RETURN_ENUMERATOR(self, 0, 0);
  for (i=0; i<elements; i++) {
    ret = rb_yield(rb_ca_fetch_addr(self, i));
  }
  return ret;
}

/* CArray#each_with_addr {|elem, addr| ... } -- yield (value, flat
   address) pairs in flat-address order. */
static VALUE
rb_ca_each_with_addr (VALUE self)
{
  volatile VALUE ret = Qnil;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
  RETURN_ENUMERATOR(self, 0, 0);
  for (i=0; i<elements; i++) {
    ret = rb_yield_values(2, rb_ca_fetch_addr(self, i), SIZE2NUM(i));
  }
  return ret;
}

/* CArray#each_addr {|addr| ... } -- yield each flat address
   `0...self.elements` in order; does not fetch the value. */
static VALUE
rb_ca_each_addr (VALUE self)
{
  volatile VALUE ret = Qnil;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
  RETURN_ENUMERATOR(self, 0, 0);
  for (i=0; i<elements; i++) {
    ret = rb_yield(SIZE2NUM(i));
  }
  return ret;
}

/* Unified recursive walk over all multi-dimensional indices.  mode
   selects the per-cell action, so each_index / each_with_index /
   map_index! / map_with_index! share this single recursion:
     CA_LOOP_WITH_VALUE -- yield the element value alongside the index
     CA_LOOP_STORE      -- store the block result back (map! family)
   Construction-block sugar in rb_ca_initialize also reuses this walk
   in CA_LOOP_STORE mode (= map_index! semantics).

   Called by rb_ca_each_index / _each_with_index / _map_index_bang /
   _map_with_index_bang here, and by rb_ca_initialize in
   ext/ca_obj_array.c. */
VALUE
rb_ca_index_walk (VALUE self, CArray *ca, int8_t level,
                  ca_size_t *idx, VALUE ridx, int mode)
{
  volatile VALUE ret = Qnil;
  ca_size_t i;
  if ( level == ca->ndim - 1 ) {
    for (i=0; i<ca->dim[level]; i++) {
      volatile VALUE obj;
      idx[level] = i;
      rb_ary_store(ridx, level, SIZE2NUM(i));
      /* CAREFUL: the subscript is yielded as individual arguments
         (rb_yield_values2), not as a single Array.  This lets |i, j|
         work uniformly in 1-D and N-D; the single-Array form forced
         1-D users to write |(i)| or |i,| and silently stored the
         wrapping Array into integer cells when omitted.  Block forms
         that want the whole subscript should write |*idx|. */
      if ( mode & CA_LOOP_WITH_VALUE ) {
        int argc = (int)ca->ndim + 1;
        VALUE *argv = ALLOCA_N(VALUE, argc);
        argv[0] = rb_ca_fetch_index(self, idx);
        MEMCPY(argv + 1, RARRAY_CONST_PTR(ridx), VALUE, ca->ndim);
        obj = rb_yield_values2(argc, argv);
      }
      else {
        obj = rb_yield_values2((int)ca->ndim, RARRAY_CONST_PTR(ridx));
      }
      if ( mode & CA_LOOP_STORE ) {
        rb_ca_store_index(self, idx, obj);
      }
      ret = obj;
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ridx, level, SIZE2NUM(i));
      ret = rb_ca_index_walk(self, ca, level+1, idx, ridx, mode);
    }
  }
  return ret;
}

/* CArray#each_index {|i, j, ...| ... } -- yield each multi-dim index
   of self in row-major order via rb_ca_index_walk. */
static VALUE
rb_ca_each_index (VALUE self)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  volatile VALUE ridx;
  RETURN_ENUMERATOR(self, 0, 0);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ridx = rb_ary_new2(ca->ndim);
  return rb_ca_index_walk(self, ca, 0, idx, ridx, 0);
}

/* CArray#map! {|elem| ... } -- yield each cell value, store the
   block's return back at the same flat address.  Mutates self;
   attach / sync / detach around the loop for view-safety. */
static VALUE
rb_ca_map_bang (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
  RETURN_ENUMERATOR(self, 0, 0);
  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_attach(ca);
  for (i=0; i<elements; i++) {
    obj = rb_yield(rb_ca_fetch_addr(self, i));
    rb_ca_store_addr(self, i, obj);
  }
  ca_sync(ca);
  ca_detach(ca);
  return self;
}

/* CArray#each_with_index {|elem, i, j, ...| ... } -- yield each cell
   value followed by its multi-dim index components (individual args;
   see rb_ca_index_walk header). */
static VALUE
rb_ca_each_with_index (VALUE self)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  volatile VALUE ridx;
  RETURN_ENUMERATOR(self, 0, 0);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ridx = rb_ary_new2(ca->ndim);
  return rb_ca_index_walk(self, ca, 0, idx, ridx, CA_LOOP_WITH_VALUE);
}


/* CArray#map_with_index! {|elem, i, j, ...| ... } -- yield each cell
   value with its multi-dim index components, store the block's
   return back.  Mutates self. */
static VALUE
rb_ca_map_with_index_bang (VALUE self)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  volatile VALUE ridx;
  RETURN_ENUMERATOR(self, 0, 0);
  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_attach(ca);
  ridx = rb_ary_new2(ca->ndim);
  rb_ca_index_walk(self, ca, 0, idx, ridx, CA_LOOP_WITH_VALUE | CA_LOOP_STORE);
  ca_sync(ca);
  ca_detach(ca);
  return self;
}


/* CArray#map_index! {|i, j, ...| ... } -- yield each multi-dim index
   (no value), store the block's return back at that cell.  Used by
   the construction-block sugar in CArray.new (rb_ca_initialize). */
static VALUE
rb_ca_map_index_bang (VALUE self)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  volatile VALUE ridx;
  RETURN_ENUMERATOR(self, 0, 0);
  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_attach(ca);
  ridx = rb_ary_new2(ca->ndim);
  rb_ca_index_walk(self, ca, 0, idx, ridx, CA_LOOP_STORE);
  ca_sync(ca);
  ca_detach(ca);
  return self;
}

/* CArray#map_with_addr! {|elem, addr| ... } -- yield (value, flat
   address), store the block's return at that address. */
static VALUE
rb_ca_map_with_addr_bang (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
  RETURN_ENUMERATOR(self, 0, 0);
  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_attach(ca);
  for (i=0; i<elements; i++) {
    obj = rb_yield_values(2, rb_ca_fetch_addr(self, i), SIZE2NUM(i));
    rb_ca_store_addr(self, i, obj);
  }
  ca_sync(ca);
  ca_detach(ca);
  return self;
}


/* CArray#map_addr! {|addr| ... } -- yield each flat address (no
   value), store the block's return at that address. */
static VALUE
rb_ca_map_addr_bang (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t elements = NUM2SIZE(rb_ca_elements(self));
  ca_size_t i;
  RETURN_ENUMERATOR(self, 0, 0);
  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
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
Init_carray_loop (void)
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
