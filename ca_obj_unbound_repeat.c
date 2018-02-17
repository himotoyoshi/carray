/* ---------------------------------------------------------------------------

  ca_obj_unbound_repeat.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

VALUE rb_cCAUnboundRepeat;

/* rdoc:
  class CAUnboundRepeat < CArray 
  end
*/

int
ca_ubrep_setup (CAUnboundRepeat *ca, CArray *parent,
                int32_t rep_rank, ca_size_t *rep_dim)
{
  int8_t data_type, rank;
  ca_size_t bytes, elements;

  /* check arguments */

  CA_CHECK_RANK(rep_rank);

  data_type = parent->data_type;
  bytes     = parent->bytes;
  rank      = parent->rank;
  elements  = parent->elements;

  ca->obj_type  = CA_OBJ_UNBOUND_REPEAT;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->rank      = rank;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(ca_size_t, rank);

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->rep_rank  = rep_rank;
  ca->rep_dim   = ALLOC_N(ca_size_t, rep_rank);

  memcpy(ca->dim, parent->dim, rank * sizeof(ca_size_t));
  memcpy(ca->rep_dim, rep_dim, rep_rank * sizeof(ca_size_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CAUnboundRepeat *
ca_ubrep_new (CArray *parent, int32_t rep_rank, ca_size_t *rep_dim)
{
  CAUnboundRepeat *ca = ALLOC(CAUnboundRepeat);
  ca_ubrep_setup(ca, parent, rep_rank, rep_dim);
  return ca;
}

static void
free_ca_ubrep (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca->rep_dim);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_ubrep_func_clone (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  return ca_ubrep_new(ca->parent, ca->rep_rank, ca->rep_dim);
}

static char *
ca_ubrep_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  return ca_ptr_at_addr(ca->parent, addr);
}

static char *
ca_ubrep_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  return ca_ptr_at_index(ca->parent, idx);
}

static void
ca_ubrep_func_fetch_addr (void *ap, ca_size_t addr, void *ptr)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_fetch_addr(ca->parent, addr, ptr);
}

static void
ca_ubrep_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_fetch_index(ca->parent, idx, ptr);
}

static void
ca_ubrep_func_store_addr (void *ap, ca_size_t addr, void *ptr)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_store_addr(ca->parent, addr, ptr);
}

static void
ca_ubrep_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_store_index(ca->parent, idx, ptr);
}

static void
ca_ubrep_func_allocate (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_allocate(ca->parent);
  ca->ptr = ca->parent->ptr;
}

static void
ca_ubrep_func_attach (void *ap)
{
  void ca_ubrep_attach (CAUnboundRepeat *cb);
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr;
  return;
}

static void
ca_ubrep_func_sync (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_sync(ca->parent);
  return;
}

static void
ca_ubrep_func_detach (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca->ptr = NULL;
  ca_detach(ca->parent);
  return;
}

static void
ca_ubrep_func_copy_data (void *ap, void *ptr)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  if ( ptr != ca->ptr ) {
    ca_attach(ca->parent);
    memmove(ptr, ca->parent->ptr, ca_length(ca));
    ca_detach(ca->parent);
  }
}

static void
ca_ubrep_func_sync_data (void *ap, void *ptr)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  if ( ptr != ca->ptr ) {
    ca_allocate(ca->parent);
    memmove(ptr, ca->parent->ptr, ca_length(ca));
    ca_sync(ca->parent);
    ca_detach(ca->parent);
  }
}

static void
ca_ubrep_func_fill_data (void *ap, void *ptr)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  if ( ptr != ca->ptr ) {
    ca_allocate(ca->parent);
    ca_func[CA_OBJ_ARRAY].fill_data(ca->parent, ptr);
    ca_sync(ca->parent);
    ca_detach(ca->parent);
  }
}

static void
ca_ubrep_func_create_mask (void *ap)
{
  CAUnboundRepeat *ca = (CAUnboundRepeat *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask =
    (CArray *) ca_ubrep_new(ca->parent->mask, ca->rep_rank, ca->rep_dim);
}

ca_operation_function_t ca_ubrep_func = {
  -1, /* CA_OBJ_UNBOUND_REPEAT */
  CA_VIRTUAL_ARRAY,
  free_ca_ubrep,
  ca_ubrep_func_clone,
  ca_ubrep_func_ptr_at_addr,
  ca_ubrep_func_ptr_at_index,
  ca_ubrep_func_fetch_addr,
  ca_ubrep_func_fetch_index,
  ca_ubrep_func_store_addr,
  ca_ubrep_func_store_index,
  ca_ubrep_func_allocate,
  ca_ubrep_func_attach,
  ca_ubrep_func_sync,
  ca_ubrep_func_detach,
  ca_ubrep_func_copy_data,
  ca_ubrep_func_sync_data,
  ca_ubrep_func_fill_data,
  ca_ubrep_func_create_mask,
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_ubrep_new (VALUE cary, int32_t rep_rank, ca_size_t *rep_dim)
{
  volatile VALUE obj;
  CArray *parent;
  CAUnboundRepeat *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_ubrep_new(parent, rep_rank, rep_dim);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

VALUE
rb_ca_unbound_repeat (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  ca_size_t rank, dim[CA_RANK_MAX];
  int32_t rep_rank;
  ca_size_t rep_dim[CA_RANK_MAX];
  ca_size_t count, i;

  Data_Get_Struct(self, CArray, ca);

  if ( argc == 1 && argv[0] == ID2SYM(rb_intern("*")) ) {
    CAUnboundRepeat *cr = (CAUnboundRepeat *) ca;
    volatile VALUE args;
    int repeatable = 0;
    args = rb_ary_new();
    if ( rb_obj_is_kind_of(self, rb_cCAUnboundRepeat) ) {
      repeatable = 1;
      for (i=0; i<cr->rep_rank; i++) {
        if ( cr->rep_dim[i] == 1 ) {
          rb_ary_push(args, ID2SYM(rb_intern("*")));
          repeatable = 1;
        }
        else if ( cr->rep_dim[i] > 1 ) {
          rb_ary_push(args, Qnil);
        }
        else {
          rb_ary_push(args, ID2SYM(rb_intern("*")));
        }
      }
    }
    else {
      for (i=0; i<ca->rank; i++) {
        if ( ca->dim[i] == 1 ) {
          rb_ary_push(args, ID2SYM(rb_intern("*")));
          repeatable = 1;
        }
        else {
          rb_ary_push(args, Qnil);
        }
      }
    }
    if ( ! repeatable ) {
      return self;
    }
    else {
      return rb_ca_unbound_repeat((int)RARRAY_LEN(args), RARRAY_PTR(args), self);
    }
  }
  else if ( argc == 2 && 
            argv[0] == ID2SYM(rb_intern("*")) && 
            rb_obj_is_carray(argv[1]) ) {
    volatile VALUE args, obj;
    args = ID2SYM(rb_intern("*"));
    obj  = rb_ca_unbound_repeat(1, (VALUE*)&args, self);
    return ca_ubrep_bind_with(obj, argv[1]);
  } 
  else if ( argc == 2 && 
            argv[1] == ID2SYM(rb_intern("*")) && 
            rb_obj_is_carray(argv[0]) ) {
    volatile VALUE args, obj;
    args = ID2SYM(rb_intern("*"));
    obj  = rb_ca_unbound_repeat(1, (VALUE*)&args, self);
    return ca_ubrep_bind_with(obj, argv[0]);
  }    

  rep_rank = argc;

  count = 0;
  rank = 0;

  for (i=0; i<rep_rank; i++) {
    if ( rb_obj_is_kind_of(argv[i], rb_cSymbol) ) {
      if ( argv[i] == ID2SYM(rb_intern("*")) ) {
        rep_dim[i] = 0;
        if ( ca->dim[count] == 1 ) {
          count++;
        }
      }
      else {
        rb_raise(rb_eArgError, "unknown symbol (!= ':*') in arguments");
      }
    }
    else {
      if ( ! NIL_P(argv[i]) ) {
        rb_raise(rb_eArgError, "invalid argument");
      }
      rep_dim[i] = ca->dim[count];
      dim[rank] = ca->dim[count];
      count++; rank++;
    }
  }

  if ( count != ca->rank ) {
    rb_raise(rb_eRuntimeError, "too small # of nil");
  }

  if ( rank != ca->rank ) {
    volatile VALUE par, obj;
    par = rb_ca_refer_new(self, ca->data_type, rank, dim, ca->bytes, 0);
    obj = rb_ca_ubrep_new(par, rep_rank, rep_dim);
    rb_ivar_set(obj, rb_intern("__real_parent__"), par);
    rb_ca_set_parent(obj, self);
    return obj;
  }
  else {
    return rb_ca_ubrep_new(self, rep_rank, rep_dim);
  }
}

static VALUE
rb_ca_ubrep_s_allocate (VALUE klass)
{
  CAUnboundRepeat *ca;
  return Data_Make_Struct(klass, CAUnboundRepeat, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_ubrep_initialize_copy (VALUE self, VALUE other)
{
  CAUnboundRepeat *ca, *cs;

  Data_Get_Struct(self,  CAUnboundRepeat, ca);
  Data_Get_Struct(other, CAUnboundRepeat, cs);

  ca_ubrep_setup(ca, cs->parent, cs->rep_rank, cs->rep_dim);

  return self;
}

/*
static CARepeat *
ca_ubrep_bind (CAUnboundRepeat *ca, int32_t new_rank, ca_size_t *new_dim)
{
  ca_size_t rep_spec[CA_RANK_MAX];
  int i;
  if ( ca->rep_rank != new_rank ) {
    rb_raise(rb_eArgError, "invalid new_rank");
  }
  for (i=0; i<new_rank; i++) {
    if ( ca->rep_dim[i] == 0 ) {
      rep_spec[i] = new_dim[i];
    }
    else {
      rep_spec[i] = 0;
    }
  }
  return ca_repeat_new((CArray*)ca, new_rank, rep_spec);
}
*/

VALUE
ca_ubrep_bind2 (VALUE self, int32_t new_rank, ca_size_t *new_dim)
{
  CAUnboundRepeat *ca;
  ca_size_t rep_spec[CA_RANK_MAX];
  ca_size_t upr_spec[CA_RANK_MAX];
  ca_size_t srp_spec[CA_RANK_MAX];
  int uprep = 0, srp_rank;
  int i;

  Data_Get_Struct(self, CAUnboundRepeat, ca);

  if ( ca->rep_rank != new_rank ) {
    rb_raise(rb_eArgError, "invalid new_rank (%i <-> %i)",
                           ca->rep_rank, new_rank);
  }

  srp_rank = 0;
  for (i=0; i<new_rank; i++) {
    if ( ca->rep_dim[i] == 0 ) {
      if ( new_dim[i] == 0 ) {
        uprep = 1;
      }
      else {
        srp_spec[srp_rank++] = new_dim[i];
      }
      rep_spec[i] = new_dim[i];
      upr_spec[i] = new_dim[i];
    }
    else {
      rep_spec[i] = 0;
      srp_spec[srp_rank++] = 0;
      upr_spec[i] = ca->rep_dim[i];
    }
  }
  if ( uprep ) {
    volatile VALUE rep;
    if ( srp_rank >= ca->rank ) {
      rep = rb_ca_repeat_new(rb_ca_parent(self), srp_rank, srp_spec);
    }
    else {
      rep = rb_ca_parent(self);
    }
    return rb_ca_ubrep_new(rep, new_rank, upr_spec);
  }
  else {
    return rb_ca_repeat_new(self, new_rank, rep_spec);
  }
}

/* rdoc:
  class CAUnboundRepeat
    def bind_with(other)
    end
  end
*/

VALUE
ca_ubrep_bind_with (VALUE self, VALUE other)
{
  CAUnboundRepeat *ca, *cup;
  CArray *co;

  rb_check_carray_object(other);

  Data_Get_Struct(self, CAUnboundRepeat, ca);
  Data_Get_Struct(other, CArray, co);

  if ( co->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    Data_Get_Struct(other, CAUnboundRepeat, cup);
    return ca_ubrep_bind2(self, cup->rep_rank, cup->rep_dim);
  }
  else if ( ca_is_scalar(co) ) {
    return self;
  }
  else {
    return ca_ubrep_bind2(self, co->rank, co->dim);
  }
}

/* rdoc:
  class CAUnboundRepeat
    def bind(*index)
    end
  end
*/

static VALUE
rb_ca_ubrep_bind (int argc, VALUE *argv, VALUE self)
{
  CAUnboundRepeat *ca;
  ca_size_t rep_spec[CA_RANK_MAX];
  int i;

  Data_Get_Struct(self, CAUnboundRepeat, ca);

  if ( ca->rep_rank != argc ) {
    rb_raise(rb_eArgError, "invalid new_rank");
  }
  for (i=0; i<argc; i++) {
    if ( ca->rep_dim[i] == 0 ) {
      rep_spec[i] = NUM2SIZE(argv[i]);
    }
    else {
      rep_spec[i] = 0;
    }
  }

  return rb_ca_repeat_new(self, argc, rep_spec);
}

static VALUE
rb_ca_ubrep_spec (VALUE self)
{
  volatile VALUE spec;
  CAUnboundRepeat *ca;
  int i;

  Data_Get_Struct(self, CAUnboundRepeat, ca);

  spec = rb_ary_new2(ca->rep_rank);
  for (i=0; i<ca->rep_rank; i++) {
    if ( ca->rep_dim[i] ) {
      rb_ary_store(spec, i, SIZE2NUM(ca->rep_dim[i]));
    }
    else {
      rb_ary_store(spec, i, ID2SYM(rb_intern("*")));
    }
  }

  return spec;
}

void
Init_ca_obj_unbound_repeat ()
{
  /* rb_cCAUnboudRepeat, CA_OBJ_UNBOUND_REPEAT are defined in rb_carray.c */

  rb_define_const(rb_cObject, "CA_OBJ_UNBOUND_REPEAT", INT2NUM(CA_OBJ_UNBOUND_REPEAT));

  rb_define_method(rb_cCArray, "unbound_repeat", rb_ca_unbound_repeat, -1);

  rb_define_alloc_func(rb_cCAUnboundRepeat, rb_ca_ubrep_s_allocate);
  rb_define_method(rb_cCAUnboundRepeat, "initialize_copy",
                                      rb_ca_ubrep_initialize_copy, 1);

  rb_define_method(rb_cCAUnboundRepeat, "bind", rb_ca_ubrep_bind, -1);
  rb_define_method(rb_cCAUnboundRepeat, "bind_with", ca_ubrep_bind_with, 1);
  rb_define_method(rb_cCAUnboundRepeat, "spec", rb_ca_ubrep_spec, 0);

}

