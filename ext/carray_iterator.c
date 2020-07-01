/* ---------------------------------------------------------------------------

  carray_iterator.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

VALUE rb_cCAIterator;

int8_t
ca_iter_ndim (VALUE self)
{
  int8_t ndim;
  if ( TYPE(self) == T_DATA ) {
    CAIterator *it;
    Data_Get_Struct(self, CAIterator, it);
    ndim = it->ndim;
  }
  else {
    VALUE rndim = rb_ivar_get(self, rb_intern("@ndim"));
    ndim = (int8_t) NUM2LONG(rndim);
  }
  return ndim;
}

void
ca_iter_dim (VALUE self, ca_size_t *dim)
{
  int i;
  if ( TYPE(self) == T_DATA ) {
    CAIterator *it;
    Data_Get_Struct(self, CAIterator, it);
    for (i=0; i<it->ndim; i++) {
      dim[i] = it->dim[i];
    }
  }
  else {
    VALUE rndim = rb_ivar_get(self, rb_intern("@ndim"));
    VALUE rdim  = rb_ivar_get(self, rb_intern("@dim"));
    int8_t ndim;
    ndim = (int8_t) NUM2INT(rndim);
    for (i=0; i<ndim; i++) {
      dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
    }
  }
}

ca_size_t
ca_iter_elements (VALUE self)
{
  int i, elements;
  if ( TYPE(self) == T_DATA ) {
    CAIterator *it;
    Data_Get_Struct(self, CAIterator, it);
    elements = 1;
    for (i=0; i<it->ndim; i++) {
      elements *= it->dim[i];
    }
  }
  else {
    VALUE rndim = rb_ivar_get(self, rb_intern("@ndim"));
    VALUE rdim  = rb_ivar_get(self, rb_intern("@dim"));
    int8_t ndim = (int8_t) NUM2INT(rndim);
    elements = 1;
    for (i=0; i<ndim; i++) {
      elements *= NUM2SIZE(rb_ary_entry(rdim, i));
    }
  }
  return elements;
}

VALUE
ca_iter_reference (VALUE self)
{
  return rb_ivar_get(self, rb_intern("@reference"));
}

VALUE
ca_iter_kernel_at_addr (VALUE self, ca_size_t addr, VALUE rref)
{
  volatile VALUE rker;
  if ( TYPE(self) == T_DATA ) {
    CAIterator *it;
    CArray *ref, *ker;
    Data_Get_Struct(self, CAIterator, it);
    Data_Get_Struct(rref, CArray, ref);
    ker = it->kernel_at_addr(it, addr, ref);
    rker = ca_wrap_struct(ker);
    rb_ca_data_type_inherit(rker, rref);
    rb_ca_set_parent(rker, rref);
  }
  else {
    rker = rb_funcall(self, rb_intern("kernel_at_addr"), 2,
                      SIZE2NUM(addr), rref);
  }
  return rker;
}

VALUE
ca_iter_kernel_at_index (VALUE self, ca_size_t *idx, VALUE rref)
{
  VALUE rker;
  if ( TYPE(self) == T_DATA ) {
    CAIterator *it;
    CArray *ref, *ker;
    Data_Get_Struct(self, CAIterator, it);
    Data_Get_Struct(rref, CArray, ref);
    ker = it->kernel_at_index(it, idx, ref);
    rker = ca_wrap_struct(ker);
    rb_ca_data_type_inherit(rker, rref);
    rb_ca_set_parent(rker, rref);
  }
  else {
    VALUE vidx;
    int8_t ndim = ca_iter_ndim(self);
    int i;
    vidx = rb_ary_new2(ndim);
    for (i=0; i<ndim; i++) {
      rb_ary_store(vidx, i, SIZE2NUM(idx[i]));
    }
    rker = rb_funcall(self, rb_intern("kernel_at_index"), 2,
                      vidx, rref);
  }
  return rker;
}

VALUE
ca_iter_kernel_move_to_addr (VALUE self, ca_size_t addr, VALUE rref)
{
  if ( TYPE(self) == T_DATA ) {
    CAIterator *it;
    CArray *ker;
    Data_Get_Struct(self, CAIterator, it);
    Data_Get_Struct(rref, CArray, ker);
    it->kernel_move_to_addr(it, addr, ker);
  }
  else {
    rb_funcall(self, rb_intern("kernel_move_to_addr"), 2,
                      SIZE2NUM(addr), rref);
  }
  return rref;
}

VALUE
ca_iter_kernel_move_to_index (VALUE self, ca_size_t *idx, VALUE rref)
{
  VALUE rker;
  if ( TYPE(self) == T_DATA ) {
    CAIterator *it;
    CArray *ker;
    Data_Get_Struct(self, CAIterator, it);
    Data_Get_Struct(rref, CArray, ker);
    it->kernel_move_to_index(it, idx, ker);
  }
  else {
    VALUE vidx;
    int8_t ndim = ca_iter_ndim(self);
    int i;
    vidx = rb_ary_new2(ndim);
    for (i=0; i<ndim; i++) {
      rb_ary_store(vidx, i, SIZE2NUM(idx[i]));
    }
    rker = rb_funcall(self, rb_intern("kernel_move_to_index"), 2,
                      vidx, rref);
  }
  return rref;
}


VALUE
ca_iter_prepare_output (VALUE self, VALUE rtype, VALUE rbytes)
{
  volatile VALUE obj;
  CArray *co;
  int8_t data_type;
  ca_size_t bytes;
  int i;

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

  if ( TYPE(self) == T_DATA ) {
    CAIterator *it;
    Data_Get_Struct(self, CAIterator, it);
    co = carray_new_safe(data_type, it->ndim, it->dim, bytes, NULL);
  }
  else {
    VALUE rndim = rb_ivar_get(self, rb_intern("@ndim"));
    VALUE rdim  = rb_ivar_get(self, rb_intern("@dim"));
    int8_t ndim = NUM2LONG(rndim);
    ca_size_t dim[CA_RANK_MAX];
    for (i=0; i<ndim; i++) {
      dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
    }
    co = carray_new_safe(data_type, ndim, dim, bytes, NULL);
  }

  obj = ca_wrap_struct(co);
  rb_ca_data_type_import(obj, rtype);

  return obj;
}

/* -------------------------------------------------------------------- */

/* rdoc:
  class CAIterator
    def ndim
    end
  end
*/


VALUE
rb_ca_iter_ndim (VALUE self)
{
  return LONG2NUM(ca_iter_ndim(self));
}

/* rdoc:
  class CAIterator
    def dim
    end
  end
*/

VALUE
rb_ca_iter_dim (VALUE self)
{
  VALUE rdim;
  ca_size_t dim[CA_RANK_MAX];
  int8_t ndim = ca_iter_ndim(self);
  int i;
  ca_iter_dim(self, dim);
  rdim = rb_ary_new2(ndim);
  for (i=0; i<ndim; i++) {
    rb_ary_store(rdim, i, SIZE2NUM(dim[i]));
  }
  return rdim;
}

/* rdoc:
  class CAIterator
    def elements
    end
  end
*/

VALUE
rb_ca_iter_elements (VALUE self)
{
  return SIZE2NUM(ca_iter_elements(self));
}

/* rdoc:
  class CAIterator
    def reference
    end
  end
*/

VALUE
rb_ca_iter_reference (VALUE self)
{
  return ca_iter_reference(self);
}

/* rdoc:
  class CAIterator
    def kernel_at_addr
    end
  end
*/

VALUE
rb_ca_iter_kernel_at_addr (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE raddr, rcarray;
  rb_scan_args(argc, argv, "11", (VALUE *) &raddr, (VALUE *) &rcarray);
  if ( NIL_P(rcarray) ) {
    rcarray = rb_ca_iter_reference(self);
  }
  return ca_iter_kernel_at_addr(self, NUM2SIZE(raddr), rcarray);
}

/* rdoc:
  class CAIterator
    def kernel_at_index
    end
  end
*/

VALUE
rb_ca_iter_kernel_at_index (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rindex, rcarray;
  ca_size_t idx[CA_RANK_MAX];
  int8_t  ndim = ca_iter_ndim(self);
  int i;

  rb_scan_args(argc, argv, "11", (VALUE *) &rindex, (VALUE *) &rcarray);

  if ( NIL_P(rcarray) ) {
    rcarray = rb_ca_iter_reference(self);
  }

  for (i=0; i<ndim; i++) {
    idx[i] = NUM2SIZE(rb_ary_entry(rindex, i));
  }

  return ca_iter_kernel_at_index(self, idx, rcarray);
}

/* rdoc:
  class CAIterator
    def kernel_move_to_addr
    end
  end
*/

VALUE
rb_ca_iter_kernel_move_to_addr (VALUE self, VALUE raddr, VALUE rker)
{
  return ca_iter_kernel_move_to_addr(self, NUM2SIZE(raddr), rker);
}

/* rdoc:
  class CAIterator
    def kernel_move_to_index
    end
  end
*/

VALUE
rb_ca_iter_kernel_move_to_index (VALUE self, VALUE rindex, VALUE rker)
{
  ca_size_t idx[CA_RANK_MAX];
  int8_t  ndim = ca_iter_ndim(self);
  int i;

  for (i=0; i<ndim; i++) {
    idx[i] = NUM2SIZE(rb_ary_entry(rindex, i));
  }

  return ca_iter_kernel_move_to_index(self, idx, rker);
}

/* rdoc:
  class CAIterator
    def prepare_output
    end
  end
*/

VALUE
rb_ca_iter_prepare_output (int argc, VALUE *argv, VALUE self)
{
  VALUE rtype, ropt, rbytes = Qnil;

  rb_scan_args(argc, argv, "11", &rtype, &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  return ca_iter_prepare_output(self, rtype, rbytes);
}

/* -------------------------------------------------------------------- */

/* rdoc:
  class CAIterator
    def calculate
    end
  end
*/

VALUE
rb_ca_iter_calculate (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rtype, rbytes, routput, rref, rker, rout;
  CArray *co, *cr, *ck;
  ca_size_t elements;
  int8_t data_type;
  ca_size_t bytes;
  int i;

  if ( argc < 1 ) {
    rb_raise(rb_eArgError, "invalid # of arguments");
  }

  elements = ca_iter_elements(self);

  rref     = ca_iter_reference(self);
  Data_Get_Struct(rref, CArray, cr);
  
  if ( NIL_P(argv[0]) ) {
    rtype = INT2NUM(cr->data_type);
    rbytes = SIZE2NUM(cr->bytes);
  }
  else {
    rb_ca_guess_type_and_bytes(argv[0], Qnil, &data_type, &bytes);
    rtype = INT2NUM(data_type);
    rbytes = SIZE2NUM(bytes);
  }
  argc--;
  argv++;

  routput = ca_iter_prepare_output(self, rtype, rbytes);
  Data_Get_Struct(routput, CArray, co);

  ca_attach(cr);

  if ( rb_const_get(CLASS_OF(self), rb_intern("UNIFORM_KERNEL")) ) {

    rker = ca_iter_kernel_at_addr(self, 0, rref);

    Data_Get_Struct(rker, CArray, ck);
    ca_attach(ck);

    if ( rb_block_given_p() ) {
      for (i=0; i<elements; i++) {
        ca_iter_kernel_move_to_addr(self, i, rker);
        ca_update(ck);
        rout = rb_yield(rker);
        rb_ca_store_addr(routput, i, rout);
      }
    }
    else {
      if ( argc < 1 ) {
        rb_raise(rb_eArgError, "invalid # of arguments");
      }
      for (i=0; i<elements; i++) {
        ca_iter_kernel_move_to_addr(self, i, rker);
        ca_update(ck);
        rout = rb_funcall2(rker, SYM2ID(argv[0]), argc-1, &argv[1]);
        rb_ca_store_addr(routput, i, rout);
      }
    }

    ca_detach(ck);
  }
  else {
    
    if ( rb_block_given_p() ) {
      for (i=0; i<elements; i++) {
        rker = ca_iter_kernel_at_addr(self, i, rref);
        rout = rb_yield(rker);
        rb_ca_store_addr(routput, i, rout);
      }
    }
    else {
      if ( argc < 1 ) {
        rb_raise(rb_eArgError, "invalid # of arguments");
      }
      for (i=0; i<elements; i++) {
        rker = ca_iter_kernel_at_addr(self, i, rref);
        rout = rb_funcall2(rker, SYM2ID(argv[0]), argc-1, &argv[1]);
        rb_ca_store_addr(routput, i, rout);
      }
    }
    
  }

  ca_detach(cr);

  return routput;
}

/* rdoc:
  class CAIterator
    def filter
    end
  end
*/

VALUE
rb_ca_iter_filter (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE routput, rref, rker, rout;
  CArray *co, *cr, *ck, *cq;
  ca_size_t elements;
  int8_t data_type;
  int i;

  if ( argc < 2 ) {
    rb_raise(rb_eArgError, "invalid # of arguments");
  }

  elements = ca_iter_elements(self);
  rref = ca_iter_reference(self);

  Data_Get_Struct(rref, CArray, cr);

  /* FIXME: check data_type validity */

  data_type = NIL_P(argv[0]) ? cr->data_type : rb_ca_guess_type(argv[0]);
  argc--;
  argv++;

  co = carray_new(data_type, cr->ndim, cr->dim, 0, NULL);
  routput = ca_wrap_struct(co);

  if ( NIL_P(argv[0]) ) {
    rb_ca_data_type_inherit(routput, rref);
  }

  ca_attach(cr);

  if ( rb_const_get(CLASS_OF(self), rb_intern("UNIFORM_KERNEL")) ) {

    rker = ca_iter_kernel_at_addr(self, 0, rref);
    Data_Get_Struct(rker, CArray, ck);
    ca_allocate(ck);

    rout = ca_iter_kernel_at_addr(self, 0, routput);
    Data_Get_Struct(rker, CArray, cq);
    ca_allocate(cq);

    for (i=0; i<elements; i++) {
      ca_iter_kernel_move_to_addr(self, i, rker);
      ca_iter_kernel_move_to_addr(self, i, rout);
      ca_update(ck);
      rb_funcall(rout, rb_intern("[]="), 1,
        rb_funcall2(rker, SYM2ID(argv[0]), argc-1, &argv[1]));
      ca_sync(cq);
    }

    ca_detach_n(2, ck, cq);

  }
  else {

    for (i=0; i<elements; i++) {
      rker = ca_iter_kernel_at_addr(self, i, rref);
      rout = ca_iter_kernel_at_addr(self, i, routput);
      rb_funcall(rout, rb_intern("[]="), 1,
        rb_funcall2(rker, SYM2ID(argv[0]), argc-1, &argv[1]));
    }

  }

  ca_detach(cr);
  return routput;
}

/* rdoc:
  class CAIterator
    def evaluate
    end
  end
*/

VALUE
rb_ca_iter_evaluate (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rref, rker;
  CArray *cr, *ck;
  ca_size_t elements;
  int i;

  elements = ca_iter_elements(self);
  rref  = ca_iter_reference(self);

  Data_Get_Struct(rref, CArray, cr);

  ca_attach(cr);

  if ( rb_const_get(CLASS_OF(self), rb_intern("UNIFORM_KERNEL")) ) {

    rker = ca_iter_kernel_at_addr(self, 0, rref);

    Data_Get_Struct(rker, CArray, ck);

    ca_attach(ck);

    for (i=0; i<elements; i++) {
      ca_iter_kernel_move_to_addr(self, i, rker);
      ca_update(ck);
      rb_funcall2(rker, SYM2ID(argv[0]), argc-1, &argv[1]);
    }

    ca_detach(ck);
  }
  else {    

    for (i=0; i<elements; i++) {
      rker = ca_iter_kernel_at_addr(self, i, rref);
      rb_funcall2(rker, SYM2ID(argv[0]), argc-1, &argv[1]);
    }

  }

  ca_sync(cr);
  ca_detach(cr);

  return self;
}


void
Init_carray_iterator ()
{
  rb_cCAIterator = rb_define_class("CAIterator", rb_cObject);

  rb_define_method(rb_cCAIterator, "ndim",      rb_ca_iter_ndim,      0);
  rb_define_method(rb_cCAIterator, "rank",      rb_ca_iter_ndim,      0); /* alias */
  rb_define_method(rb_cCAIterator, "dim",       rb_ca_iter_dim,       0);
  rb_define_method(rb_cCAIterator, "shape",     rb_ca_iter_dim,       0); /* alias */
  rb_define_method(rb_cCAIterator, "elements",  rb_ca_iter_elements,  0);
  rb_define_method(rb_cCAIterator, "reference", rb_ca_iter_reference, 0);

  rb_define_method(rb_cCAIterator, "kernel_at_addr",
                       rb_ca_iter_kernel_at_addr, -1);
  rb_define_method(rb_cCAIterator, "kernel_at_index",
                       rb_ca_iter_kernel_at_index, -1);
  rb_define_method(rb_cCAIterator, "kernel_move_to_addr",
                       rb_ca_iter_kernel_move_to_addr, 2);
  rb_define_method(rb_cCAIterator, "kernel_move_to_index",
                       rb_ca_iter_kernel_move_to_index, 2);
  rb_define_method(rb_cCAIterator, "prepare_output",
                       rb_ca_iter_prepare_output, -1);

  rb_define_method(rb_cCAIterator, "calculate",     rb_ca_iter_calculate,     -1);
  rb_define_method(rb_cCAIterator, "filter",   rb_ca_iter_filter,   -1);
  rb_define_method(rb_cCAIterator, "evaluate", rb_ca_iter_evaluate, -1);

}


