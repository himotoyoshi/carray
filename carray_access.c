/* ---------------------------------------------------------------------------

  carray_access.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

#if RUBY_VERSION_CODE >= 190
#define RANGE_BEG(r) (RSTRUCT(r)->as.ary[0])
#define RANGE_END(r) (RSTRUCT(r)->as.ary[1])
#define RANGE_EXCL(r) (RSTRUCT(r)->as.ary[2])
#else
static ID id_beg, id_end, id_excl;
#define RANGE_BEG(r) (rb_ivar_get(r, id_beg))
#define RANGE_END(r) (rb_ivar_get(r, id_end))
#define RANGE_EXCL(r) (rb_ivar_get(r, id_excl))
#endif

static ID id_ca, id_to_ca;
static VALUE sym_star, sym_perc;
static VALUE S_CAInfo;

VALUE
rb_ca_store_index (VALUE self, int32_t *idx, VALUE rval)
{
  CArray *ca;
  boolean8_t zero = 0, one = 1;

  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_empty(ca) ) {
    return rval;
  }

  if ( rval == CA_UNDEF ) { /* set mask at the element */
    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    ca_store_index(ca->mask, idx, &one);
  }
  else {                   /* unset mask and set value at the element */

    /* unset mask */
    ca_update_mask(ca);
    if ( ca->mask ) {
      ca_store_index(ca->mask, idx, &zero);
    }

    /* store value */
    if ( ca->bytes <= 32) {
      char v[32];
      rb_ca_obj2ptr(self, rval, v);
      ca_store_index(ca, idx, v);
    }
    else {
      char *v = malloc_with_check(ca->bytes);
      rb_ca_obj2ptr(self, rval, v);
      ca_store_index(ca, idx, v);
      free(v);
    }
  }

  return rval;
}

VALUE
rb_ca_fetch_index (VALUE self, int32_t *idx)
{
  volatile VALUE out;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_empty(ca) ) {
    return Qnil;
  }

  /* fetch value from the element */
  if ( ca->bytes <= 32) {
    char v[32];
    ca_fetch_index(ca, idx, v);
    out = rb_ca_ptr2obj(self, v);
  }
  else {
    char *v = malloc_with_check(ca->bytes);
    ca_fetch_index(ca, idx, v);
    out = rb_ca_ptr2obj(self, v);
    free(v);
  }

  /* check if the element is masked */
  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t mval;
    ca_fetch_index(ca->mask, idx, &mval);
    if ( mval ) {
      return CA_UNDEF; /* the element is masked */
    }
  }

  return out;
}

VALUE
rb_ca_store_addr (VALUE self, int32_t addr, VALUE rval)
{
  CArray *ca;
  boolean8_t zero = 0, one = 1;

  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_empty(ca) ) {
    return rval;
  }

  if ( rval == CA_UNDEF ) { /* set mask at the element */
    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    ca_store_addr(ca->mask, addr, &one);
  }
  else {                   /* set value at the element */
    ca_update_mask(ca);
    if ( ca->mask ) {
      ca_store_addr(ca->mask, addr, &zero); /* unset mask */
    }

    /* store value */
    if ( ca->bytes <= 32) {
      char v[32];
      rb_ca_obj2ptr(self, rval, v);
      ca_store_addr(ca, addr, v);
    }
    else {
      char *v = malloc_with_check(ca->bytes);
      rb_ca_obj2ptr(self, rval, v);
      ca_store_addr(ca, addr, v);
      free(v);
    }
  }

  return rval;
}

VALUE
rb_ca_fetch_addr (VALUE self, int32_t addr)
{
  volatile VALUE out;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_empty(ca) ) {
    return Qnil;
  }

  /* fetch value from the element */
  if ( ca->bytes <= 32) {
    char v[32];
    ca_fetch_addr(ca, addr, v);
    out = rb_ca_ptr2obj(self, v);
  }
  else {
    char *v = malloc_with_check(ca->bytes);
    ca_fetch_addr(ca, addr, v);
    out = rb_ca_ptr2obj(self, v);
    free(v);
  }

  /* check if the element is masked */
  ca_update_mask(ca);
  if ( ca->mask ) {
    boolean8_t mval;
    ca_fetch_addr(ca->mask, addr, &mval);
    if ( mval ) {
      return CA_UNDEF; /* the element is masked */
    }
  }

  return out;
}

/* rdoc:
  class CArray
    def fill
    end
    def fill_copy
    end
  end
*/

VALUE
rb_ca_fill (VALUE self, VALUE rval)
{
  CArray *ca;

  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_empty(ca) ) {
    return rval;
  }

  if ( rval == CA_UNDEF ) {
    boolean8_t one = 1;
    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    ca_fill(ca->mask, &one);
  }
  else {
    char *fval = malloc_with_check(ca->bytes);
    boolean8_t zero = 0;
    rb_ca_obj2ptr(self, rval, fval);
    if ( ca_has_mask(ca) ) {
      ca_fill(ca->mask, &zero);
    }
    ca_fill(ca, fval);
    free(fval);
  }

  return self;
}

VALUE
rb_ca_fill_copy (VALUE self, VALUE rval)
{
  volatile VALUE out = rb_ca_template(self);
  return rb_ca_fill(out, rval);
}

/* -------------------------------------------------------------------- */

static void
ary_guess_shape (VALUE ary, int level, int *max_level, int32_t *dim)
{
  volatile VALUE ary0;
  if ( level > CA_RANK_MAX ) {
    rb_raise(rb_eRuntimeError, "too deep level array for conversion to carray");
  }

  if ( TYPE(ary) == T_ARRAY ) {
    if ( RARRAY_LEN(ary) == 0 && level == 0 ) {
      *max_level = level;
      dim[level] = 0;
    }
    else if ( RARRAY_LEN(ary) > 0 ) {
      *max_level = level;
      dim[level] = RARRAY_LEN(ary);
      ary0 = rb_ary_entry(ary, 0);
      if ( TYPE(ary0) == T_ARRAY ) {
        int32_t dim0 = RARRAY_LEN(ary0);
        int32_t i;
        int flag = 0;
        for (i=0; i<dim[level]; i++) {
          VALUE x = rb_ary_entry(ary, i);
          flag = flag || ( TYPE(x) != T_ARRAY ) || ( dim0 != RARRAY_LEN(x) );
        }
        if ( ! flag ) {
          ary_guess_shape(ary0, level+1, max_level, dim);
        }
      }
    }
  }
}

/* rdoc:
  def CArray.guess_array_shape (arg)
  end
*/  

static VALUE
rb_ca_s_guess_array_shape (VALUE self, VALUE ary)
{
  volatile VALUE out;
  int32_t dim[CA_RANK_MAX];
  int max_level = -1;
  int i;
  ary_guess_shape(ary, 0, &max_level, dim);
  out = rb_ary_new2(max_level);
  for (i=0; i<max_level+1; i++) {
    rb_ary_store(out, i, INT2NUM(dim[i]));
  }
  return out;
}

static void
ary_flatten_upto_level (VALUE ary, int max_level, int level,
                        VALUE out, int *len)
{
  int32_t i;

  if ( TYPE(ary) != T_ARRAY ) {
    rb_raise(rb_eRuntimeError, "invalid shape array for conversion to carray");
  }

  if ( level == max_level ) {
    *len += RARRAY_LEN(ary);
    for (i=0; i<RARRAY_LEN(ary); i++) {
      rb_ary_push(out, rb_ary_entry(ary, i));
    }
  }
  else {
    for (i=0; i<RARRAY_LEN(ary); i++) {
      VALUE x = rb_ary_entry(ary, i);
      ary_flatten_upto_level(x, max_level, level+1, out, len);
    }
  }
}

static VALUE
rb_ary_flatten_for_elements (VALUE ary, int32_t elements, void *ap)
{
  CArray *ca = (CArray *) ap;
  int32_t dim[CA_RANK_MAX];
  int32_t total;
  int max_level = -1, level = -1;
  int same_shape, is_object = ( ca_is_object_type(ca) );
  int i;

  ary_guess_shape(ary, 0, &max_level, dim);

  if ( max_level == -1 ) {
    return Qnil;
  }

  if ( ! ca_is_object_type(ca) ) {
    total = 1;
    for (i=0; i<max_level+1; i++) {
      total *= dim[i];
      level = i;
      if ( is_object && total == elements ) {
        break;
      }
    }

    if ( total != ca->elements ) {
      rb_raise(rb_eRuntimeError, "invalid shape array for conversion to carray");
    }
    else {
      VALUE out = rb_ary_new2(elements);
      int len = 0;
      ary_flatten_upto_level(ary, max_level, 0, out, &len);
      if ( len != elements ) {
        return Qnil;
      }
      else {
        return out;
      }
    }
  }
  else {
    same_shape = 1;
    if ( max_level+1 < ca->rank ) {
      same_shape = 0;
    }
    else {
      for (i=0; i<ca->rank; i++) {
        if ( ca->dim[i] != dim[i] ) {
          same_shape = 0;
          break;
        }
      }
    }

    if ( same_shape ) {
      VALUE out = rb_ary_new2(elements);
      int len = 0;
      ary_flatten_upto_level(ary, ca->rank-1, 0, out, &len);

      if ( len != elements ) {
        return Qnil;
      }
      else {
        return out;
      }
    }
    else {
      total = 1;
      for (i=0; i<max_level+1; i++) {
        total *= dim[i];
        level = i;
        if ( is_object && total == elements ) {
          break;
        }
      }

      if ( level >= 0 ) {
        VALUE out = rb_ary_new2(elements);
        int len = 0;
        ary_flatten_upto_level(ary, level, 0, out, &len);
        if ( len != elements ) {
          return Qnil;
        }
        else {
          return out;
        }
      }
      else {
        return Qnil;
      }
    }
  }
}

#define CA_CHECK_INDEX_AT(index, dim, i)                                \
  if ( index < 0 ) {                                                    \
    index += (dim);                                                     \
  }                                                                     \
  if ( index < 0 || index >= (dim) ) {                                  \
    rb_raise(rb_eIndexError,                                            \
             "index out of range at %i-dim ( %i <=> 0..%i )",        \
             i, index, dim-1);                                          \
  }

void
rb_ca_scan_index (int ca_rank, int32_t *ca_dim, int32_t ca_elements,
                  int argc, VALUE *argv, CAIndexInfo *info)
{
  int32_t i;

  info->rank   = 0;
  info->select = NULL;

  if ( argc == 0 ) { /* ca[] -> CA_REG_ALL */
    info->type = CA_REG_ALL;
    return;
  }

  /* ca[:method, ...] -> CA_REG_METHOD_CALL
     ca[:i, ...]      -> CA_REG_ITERATOR     */
  if ( TYPE(argv[0]) == T_SYMBOL ) {
    const char *symstr = rb_id2name(SYM2ID(argv[0]));
    if ( strlen(symstr) > 1 ) { /* ca[:method, ...] -> CA_REG_METHOD_CALL */
      info->type   = CA_REG_METHOD_CALL;
      info->symbol = argv[0];
      return;
    }
  }

  if ( argc == 1 ) {

    volatile VALUE arg = argv[0];

    if ( arg == Qfalse ) { /* ca[false] -> CA_REG_ALL */
      info->type = CA_REG_ALL;
      return;
    }

    if ( rb_obj_is_carray(arg) ) {
      CArray *cs;
      Data_Get_Struct(arg, CArray, cs);
      if ( ca_is_integer_type(cs) ) { 
        #if 0
        if ( ca_rank == 1 && cs->rank == 1 ) { /* ca[g] -> CA_REG_GRID (1d) */
          info->type = CA_REG_GRID;
        }
        else {                             /* ca[m] -> CA_REG_MAPPER (2d...) */
          info->type = CA_REG_MAPPING;
        }
        #endif
        info->type = CA_REG_MAPPING;
        return;
      }
      else if ( ca_is_boolean_type(cs) ) {
                                         /* ca[selector] -> CA_REG_SELECT */
        if ( ca_elements != cs->elements ) {
          rb_raise(rb_eRuntimeError,
           "mismatch of # of elements ( %i <=> %i ) in reference by selection",
                   cs->elements, ca_elements);
        }
        info->type   = CA_REG_SELECT;
        info->select = cs;
        return;
      }
      else {
        rb_raise(rb_eIndexError,
                 "data_type %s is invalid for reference by selection/mapping"  \
                 "(should be boolean or integer)",
                 ca_type_name[cs->data_type]);
      }
    }

    if ( TYPE(arg) == T_STRING ) {  /* ca["field"] -> CA_REG_MEMBER */
      info->type   = CA_REG_MEMBER;
      info->symbol = ID2SYM(rb_intern(StringValuePtr(arg)));
      return;
    }

    if ( arg == sym_star ) {        /* ca[:*] -> CA_REG_UNBOUND_REPEAT */
      info->type   = CA_REG_UNBOUND_REPEAT;
      return;
    }

    if ( ca_rank > 1 ) { /* ca.rank > 1 */
      if ( rb_obj_is_kind_of(arg, rb_cInteger) ) { /* ca[n] -> CA_REG_ADDRESS */
        int32_t addr;
        info->type = CA_REG_ADDRESS;
        info->rank = 1;
        addr = NUM2INT(arg);
        CA_CHECK_INDEX(addr, ca_elements);
        info->index[0].scalar = addr;
        return;
      }
      else if ( arg == Qnil ) {
        info->type = CA_REG_FLATTEN;
        return;	
      }
      else { /* ca[i..j] -> CA_REG_ADDRESS_COMPLEX */
        info->type = CA_REG_ADDRESS_COMPLEX;
        return;
      }
    }
  }

  /* continue to next section */

  if ( argc >= 1 ) {
    int32_t is_point = 0, is_all = 0, is_iterator = 0, is_repeat=0, is_grid=0;
    int32_t has_rubber = 0;
    int32_t *index_type = info->index_type;
    CAIndex *index = info->index;

    for (i=0; i<argc; i++) {
      if ( argv[i] == sym_perc ) {
        is_repeat = 1;
        goto loop_exit; /* ca[--,:%,--] -> CA_REG_REPEAT */
      }

      if ( argv[i] == sym_star ) {
        is_repeat = 2;
        goto loop_exit; /* ca[--,:*,--] -> CA_REG_UNBOUND_REPEAT */
      }

      if ( argv[i] == Qfalse ) { /* ca[--,false,--] (rubber dimension) */
        has_rubber = 1;
        if ( argc > ca_rank + 1 ) {
          rb_raise(rb_eIndexError,
                   "index specification exceeds the rank of carray (%i)", 
                   ca_rank);
        }
      }
    }

    if ( ! has_rubber && ca_rank != argc ) {
      rb_raise(rb_eIndexError,
               "number of indices exceeds the rank of carray (%i > %i)",
               argc, ca_rank);
    }

    info->rank = argc;

    for (i=0; i<argc; i++) {
      volatile VALUE arg = argv[i];

    retry:

      if ( rb_obj_is_kind_of(arg, rb_cInteger) ) { /* ca[--,i,--] */
        int32_t scalar;
        index_type[i] = CA_IDX_SCALAR;
        scalar = NUM2INT(arg);
        CA_CHECK_INDEX_AT(scalar, ca_dim[i], i);
        index[i].scalar = scalar;
      }
      else if ( NIL_P(arg) ) { /* ca[--,nil,--] */
        index_type[i] = CA_IDX_ALL;
      }
      else if ( arg == Qfalse ) { /* ca[--,false,--] */
        int32_t rrank = ca_rank - argc + 1;
        int32_t j;
        for (j=0; j<rrank; j++) {
          index_type[i+j] = CA_IDX_ALL;
        }
        i += rrank-1;
        argv -= rrank-1;
        argc  = ca_rank;
        info->rank = ca_rank;
      }
      else if ( rb_obj_is_kind_of(arg, rb_cRange) ) { /* ca[--,i..j,--] */
        int32_t first, last, excl, count, step;
        volatile VALUE iv_beg, iv_end, iv_excl;
        iv_beg  = RANGE_BEG(arg);
        iv_end  = RANGE_END(arg);
        iv_excl = RANGE_EXCL(arg);
        index_type[i] = CA_IDX_BLOCK; /* convert to block */
        first = NUM2INT(iv_beg);
        last  = NUM2INT(iv_end);
        excl  = RTEST(iv_excl);
        CA_CHECK_INDEX_AT(first, ca_dim[i], i);

        if ( last < 0 ) { /* don't use CA_CHECK_INDEX for excl */
          last += ca_dim[i];
        }
        if ( excl && ( first == last ) ) {
          index[i].block.start = first;
          index[i].block.count = 0;
          index[i].block.step  = 1;
        }
        else {
          if ( excl ) {
            last += ( (last>=first) ? -1 : 1 );
          }
          if ( last < 0 || last >= ca_dim[i] ) {
            rb_raise(rb_eIndexError,
                     "index %i is out of range (0..%i) at %i-dim",
                     last, ca_dim[i]-1, i);
          }
          index[i].block.start = first;
          index[i].block.count = count = abs(last - first) + 1;
          index[i].block.step  = step  = ( last >= first ) ? 1 : -1;
        }
      }
      else if ( TYPE(arg) == T_ARRAY ) { /* ca[--,[array],--] */
        if ( RARRAY_LEN(arg) == 1 ) {
          VALUE arg0 = rb_ary_entry(arg, 0);
          if ( NIL_P(arg0) ) {           /* ca[--,[nil],--]*/
            index_type[i] = CA_IDX_ALL;
          }
          else if ( rb_obj_is_kind_of(arg0, rb_cRange) ) {
                                         /* ca[--,[i..j],--] */
            arg = arg0;
            goto retry;
          }
          else {                         /* ca[--,[i],--]*/
            int32_t start;
            start = NUM2INT(arg0);
            CA_CHECK_INDEX_AT(start, ca_dim[i], i);
            index_type[i] = CA_IDX_BLOCK;
            index[i].block.start = start;
            index[i].block.count = 1;
            index[i].block.step  = 1;
          }
        }
        else if ( RARRAY_LEN(arg) == 2 ) {
          VALUE arg0 = rb_ary_entry(arg, 0);
          VALUE arg1 = rb_ary_entry(arg, 1);
          if ( NIL_P(arg0) ) {              /* ca[--,[nil,k],--]*/
            int32_t start, last, count, step, bound;
            step  = NUM2INT(arg1);
            if ( step == 0 ) {
              rb_raise(rb_eRuntimeError, 
                       "step in index equals to 0 in block reference");
            }
            start = 0;
            last  = ca_dim[i]-1;
            if ( step < 0 ) {
              count = 1;
            }
            else {
              count = last/step + 1;
            }
            bound = start + (count - 1)*step;
            CA_CHECK_INDEX_AT(bound, ca_dim[i], i);
            index_type[i] = CA_IDX_BLOCK;
            index[i].block.start = start;
            index[i].block.count = count;
            index[i].block.step  = step;
          }
          else if ( rb_obj_is_kind_of(arg0, rb_cRange) ) { /* ca[--,[i..j,k],--]*/
            int32_t start, last, excl, count, step, bound;
            start = NUM2INT(RANGE_BEG(arg0));
            last  = NUM2INT(RANGE_END(arg0));
            excl  = RTEST(RANGE_EXCL(arg0));
            step  = NUM2INT(arg1);
            if ( step == 0 ) {
              rb_raise(rb_eRuntimeError, 
                       "step in index equals to 0 in block reference");
            }
            index_type[i] = CA_IDX_BLOCK;
            CA_CHECK_INDEX_AT(start, ca_dim[i], i);
            if ( last < 0 ) {
              last += ca_dim[i];
            }
            if ( excl && ( start == last ) ) {
              index[i].block.start = start;
              index[i].block.count = 0;
              index[i].block.step  = 1;
            }
            else {
              if ( excl ) {
                last += ( (last>=start) ? -1 : 1 );
              }
              if ( last < 0 || last >= ca_dim[i] ) {
                rb_raise(rb_eIndexError,
                         "index %i is out of range (0..%i) at %i-dim",
                         last, ca_dim[i]-1, i);
              }
              if ( (last - start) * step < 0 ) {
                count = 1;
              }
              else {
                count = abs(last - start)/abs(step) + 1;
              }
              bound = start + (count - 1)*step;
              CA_CHECK_INDEX_AT(bound, ca_dim[i], i);
              index[i].block.start = start;
              index[i].block.count = count;
              index[i].block.step  = step;
            }
          }
          else {                            /* ca[--,[i,j],--]*/
            int32_t start, count, bound;
            start = NUM2INT(arg0);
            count = NUM2INT(arg1);
            bound = start + (count - 1);
            CA_CHECK_INDEX_AT(start, ca_dim[i], i);
            CA_CHECK_INDEX_AT(bound, ca_dim[i], i);
            index_type[i] = CA_IDX_BLOCK;
            index[i].block.start = start;
            index[i].block.count = count;
            index[i].block.step  = 1;
          }
        }
        else if ( RARRAY_LEN(arg) == 3 ) { /* ca[--,[i,j,k],--]*/
          int32_t start, count, step, bound;
          start = NUM2INT(rb_ary_entry(arg, 0));
          count = NUM2INT(rb_ary_entry(arg, 1));
          step  = NUM2INT(rb_ary_entry(arg, 2));
          if ( step == 0 ) {
            rb_raise(rb_eRuntimeError, 
                     "step in index equals to 0 in block reference");
          }
          bound = start + (count - 1)*step;
          CA_CHECK_INDEX_AT(start, ca_dim[i], i);
          CA_CHECK_INDEX_AT(bound, ca_dim[i], i);
          index_type[i] = CA_IDX_BLOCK;
          index[i].block.start = start;
          index[i].block.count = count;
          index[i].block.step  = step;
        }
        else {
          rb_raise(rb_eIndexError,
                   "invalid form of index range at %i-dim "\
                   "(should be [start[,count[,step]]], [range, step])",
                   i);
        }
      }
      else if ( rb_obj_is_kind_of(arg, rb_cSymbol) ) { /* ca[--,:i,--] */
        if ( strlen(rb_id2name(SYM2ID(arg))) != 1 ) {
          rb_raise(rb_eIndexError,
                   "symbol :%s is invalid as the index for dimension iterator "\
                   "(should be :a, :b, ... :z)",
                   rb_id2name(SYM2ID(arg)));
        }
        index_type[i] = CA_IDX_SYMBOL;
        index[i].symbol.id   = SYM2ID(arg);
        index[i].symbol.spec = Qnil;
      }
      else if ( rb_obj_is_carray(arg) ) {              /* ca[--,ca,--] */
        CArray *ci;
        Data_Get_Struct(arg, CArray, ci);
        if ( ca_is_boolean_type(ci) || ca_is_integer_type(ci) ) {
          is_grid = 1;
          goto loop_exit;
        }
        else {
          rb_raise(rb_eIndexError,
               "data_type %s is invalid for reference by gridding at %i-dim "\
                   "(should be boolean or integer)",
                   ca_type_name[ci->data_type], i);
        }
      }
      else {
        VALUE inspect = rb_inspect(arg);
        rb_raise(rb_eIndexError,
                 "object '%s' is invalid for the index for reference at %i-dim",
                 StringValuePtr(inspect), i);
      }
    }

    if ( ca_rank != info->rank ) {
      rb_raise(rb_eIndexError,
               "number of indices does not equal to the rank (%i != %i)",
               info->rank, ca_rank);
    }

    is_point     = 1;
    is_all       = 1;
    is_iterator  = 0;
    is_grid      = 0;

    for (i=0; i<info->rank; i++) {
      switch ( info->index_type[i] ) {
      case CA_IDX_SCALAR:
        is_all   = 0;
        continue;
      case CA_IDX_ALL:
        is_point = 0;
        continue;
      case CA_IDX_SYMBOL:
        is_iterator = 1;
        goto loop_exit;
      default:
        is_point = 0;
        is_all   = 0;
      }
    }

   loop_exit:

    if ( is_repeat == 1 ) {
      info->type = CA_REG_REPEAT;
    }
    else if ( is_repeat == 2 ) {
      info->type = CA_REG_UNBOUND_REPEAT;
    }
    else if ( is_grid ) {
      info->type = CA_REG_GRID;
    }
    else if ( is_iterator ) {
      info->type = CA_REG_ITERATOR;
    }
    else if ( is_point ) {
      info->type = CA_REG_POINT;
    }
    else if ( is_all ) {
      info->type = CA_REG_BLOCK;
    }
    else {
      info->type = CA_REG_BLOCK;
    }

    if ( info->type == CA_REG_ITERATOR ) {
      for (i=0; i<info->rank; i++) {
        if ( info->index_type[i] == CA_IDX_SCALAR ) {
          int32_t start = info->index[i].scalar;
          info->index_type[i] = CA_IDX_BLOCK;
          info->index[i].block.start = start;
          info->index[i].block.step  = 1;
          info->index[i].block.count = 1;
        }
      }
    }

    return;
  }
}

/* ----------------------------------------------------------------------- */

static VALUE
rb_ca_ref_address (VALUE self, CAIndexInfo *info)
{
  CArray *ca;
  int32_t addr;
  Data_Get_Struct(self, CArray, ca);
  addr = info->index[0].scalar;
  return rb_ca_fetch_addr(self, addr);
}

static VALUE
rb_ca_store_address (VALUE self, CAIndexInfo *info, volatile VALUE rval)
{
  CArray *ca;
  int32_t addr;
  Data_Get_Struct(self, CArray, ca);
  addr = info->index[0].scalar;
  if ( rb_obj_is_cscalar(rval) ) {
    rval = rb_ca_fetch_addr(rval, 0);
  }
  rb_ca_store_addr(self, addr, rval);
  return rval;
}

static VALUE
rb_ca_ref_point (VALUE self, CAIndexInfo *info)
{
  CArray *ca;
  int32_t idx[CA_RANK_MAX];
  int32_t i;
  Data_Get_Struct(self, CArray, ca);
  for (i=0; i<ca->rank; i++) {
    idx[i] = info->index[i].scalar;
  }
  return rb_ca_fetch_index(self, idx);
}

static VALUE
rb_ca_store_point (VALUE self, CAIndexInfo *info, volatile VALUE val)
{
  CArray *ca;
  int32_t idx[CA_RANK_MAX];
  int32_t i;
  Data_Get_Struct(self, CArray, ca);
  for (i=0; i<ca->rank; i++) {
    idx[i] = info->index[i].scalar;
  }
  if ( rb_obj_is_cscalar(val) ) {
    val = rb_ca_fetch_addr(val, 0);
  }
  rb_ca_store_index(self, idx, val);
  return val;
}

static VALUE
rb_ca_ref_all (VALUE self, CAIndexInfo *info)
{
  return rb_funcall(self, rb_intern("refer"), 0);
}

VALUE
rb_ca_store_all (VALUE self, VALUE rval)
{
  CArray *ca;

  rb_ca_modify(self);

  if ( self == rval || rb_ca_is_empty(self) ) {
    return rval;
  }
  
  if ( rb_obj_is_cscalar(rval) ) {
    rval = rb_ca_fetch_addr(rval, 0);
  }

  Data_Get_Struct(self, CArray, ca);

 retry:

  if ( rb_obj_is_carray(rval) ) {
    CArray *cv;
    Data_Get_Struct(rval, CArray, cv);

    if ( cv->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
      rval = ca_ubrep_bind_with(rval, self);
      Data_Get_Struct(rval, CArray, cv);
    }

    if ( ca->elements != cv->elements ) {
      rb_raise(rb_eRuntimeError,
               "mismatch in data size (%i <-> %i) for storing to carray", 
               ca->elements, cv->elements);
    }

    ca_attach(cv);
    if ( ca->data_type != cv->data_type ) {
      ca_allocate(ca);
      ca_copy_mask_overwrite(ca, ca->elements, 1, cv);
      if ( ca->mask ) {
        ca_cast_block_with_mask(ca->elements, cv, cv->ptr, ca, ca->ptr, 
                                (boolean8_t*)ca->mask->ptr);
      }
      else {
        ca_cast_block(ca->elements, cv, cv->ptr, ca, ca->ptr);
      }
      ca_sync(ca);
      ca_detach(ca);
    }
    else {
      ca_copy_mask_overwrite(ca, ca->elements, 1, cv);
      ca_sync_data(ca, cv->ptr);
    }
    ca_detach(cv);
  }
  else if ( TYPE(rval) == T_ARRAY ) {
    volatile VALUE list =
                 rb_ary_flatten_for_elements(rval, ca->elements, ca);
    int32_t i;
    if ( NIL_P(list) ) {
      rb_raise(rb_eRuntimeError,
               "failed to guess data size of given array");
    }
    else {
      int has_mask = 0;
      CArray ico;
      ico.data_type = CA_OBJECT;
      ico.bytes     = ca_sizeof[CA_OBJECT];
      for (i=0; i<ca->elements; i++) {
        if ( rb_ary_entry(list,i) == CA_UNDEF ) {
          has_mask = 1;
          ca_create_mask(ca);
          break;
        }
      }
      ca_allocate(ca);        
      if ( has_mask ) {
        boolean8_t *m;
        m = (boolean8_t *)ca->mask->ptr;
        for (i=0; i<ca->elements; i++) {
          if ( rb_ary_entry(list,i) == CA_UNDEF ) {
            *m = 1;
          }
          else {
            *m = 0;
          }
          m++;
        }
        ca_cast_block_with_mask(ca->elements, &ico, RARRAY_PTR(list),
                                ca, ca->ptr, 
                                (boolean8_t*)ca->mask->ptr);
      }
      else {
        ca_cast_block(ca->elements, &ico, RARRAY_PTR(list), ca, ca->ptr);
      }
      ca_sync(ca);
      ca_detach(ca);
    }
  }
  else if ( rb_respond_to(rval, id_ca) ) {
    rval = rb_funcall(rval, id_ca, 0);
    goto retry;
  }
  else if ( rb_respond_to(rval, id_to_ca) ) {
    rval = rb_funcall(rval, id_to_ca, 0);
    goto retry;
  }
  else {
    rb_ca_fill(self, rval);
  }

  return rval;
}

static void
rb_ca_index_restruct_block (int16_t *rankp, int32_t *shrink, int32_t *dim,
                            int32_t *start, int32_t *step, int32_t *count,
                            int32_t *offsetp)
{
  int32_t dim0[CA_RANK_MAX];
  int32_t start0[CA_RANK_MAX];
  int32_t step0[CA_RANK_MAX];
  int32_t count0[CA_RANK_MAX];
  int32_t idx[CA_RANK_MAX];
  int16_t rank0, rank;
  int32_t offset0, offset, length;
  int32_t k, n;
  int32_t i, j, m;

  rank0   = *rankp;
  offset0 = *offsetp;

  /* store original start, step, count to start0, step0, count0 */
  memcpy(dim0,   dim,   sizeof(int32_t) * rank0);
  memcpy(start0, start, sizeof(int32_t) * rank0);
  memcpy(step0,  step,  sizeof(int32_t) * rank0);
  memcpy(count0, count, sizeof(int32_t) * rank0);

  /* classify and calc rank */
  n = -1;
  for (i=0; i<rank0; i++) {
    if ( ! shrink[i] ) {
      n += 1;
    }
    idx[i] = n;
  }
  rank = n + 1;

  *rankp = rank;

  /* calc offset */

  offset = 0;

  if ( idx[0] == -1 ) {
    j = 0;
    while ( idx[++j] ) {
      ;
    }

    offset = start0[0];
    for (i=1; i<j; i++) {
      offset = offset * dim0[i] + start0[i];
    }

    length = 1;
    for (i=j; i<rank0; i++) {
      length *= dim0[i];
    }

    offset *= length;
  }

  *offsetp = offset0 + offset;

  /* calc dim, start, step, count */

  for (i=0; i<rank0; i++) {
    n = idx[i];
    if ( n == -1) {
      continue;
    }

    for (j=i+1, m=i; j<rank0 && (idx[j] == n); j++) {
      ;
    }

    dim[n] = 1;
    for (k=m; k<j; k++) {
      dim[n] *= dim0[k];
    }

    start[n] = start0[m];
    step[n]  = step0[m];
    count[n] = count0[m];
    for (k=m+1; k<j; k++) {
      start[n] = start[n] * dim0[k] + start0[k];
      step[n]  = step[n]  * dim0[k];
      count[n] = count[n] * count0[k];
    }

    i = j - 1;
  }

}

VALUE
rb_ca_ref_block (VALUE self, CAIndexInfo *info)
{
  volatile VALUE refer;
  CArray *ca;
  int32_t dim[CA_RANK_MAX];
  int32_t start[CA_RANK_MAX];
  int32_t step[CA_RANK_MAX];
  int32_t count[CA_RANK_MAX];
  int32_t shrink[CA_RANK_MAX];
  int16_t rank = 0;
  int32_t offset = 0;
  int32_t flag = 0;
  int32_t elements;
  int32_t i;

  Data_Get_Struct(self, CArray, ca);

  rank = info->rank;

  elements = 1;
  for (i=0; i<info->rank; i++) {
    dim[i] = ca->dim[i];
    switch ( info->index_type[i] ) {
    case CA_IDX_SCALAR:
      elements *= 1;
      break;
    case CA_IDX_ALL:
      elements *= ca->dim[i];
      break;
    case CA_IDX_BLOCK:
      elements *= info->index[i].block.count;
      break;
    default:
      rb_raise(rb_eIndexError, "invalid index for block reference");
    }
  }

  for (i=0; i<info->rank; i++) {
    switch ( info->index_type[i] ) {
    case CA_IDX_SCALAR:
      start[i]  = info->index[i].scalar;
      step[i]   = 1;
      count[i]  = 1;
      shrink[i] = 1;
      break;
    case CA_IDX_ALL:
      start[i]  = 0;
      step[i]   = 1;
      count[i]  = ca->dim[i];
      shrink[i] = 0;
      break;
    case CA_IDX_BLOCK:
      start[i]  = info->index[i].block.start;
      step[i]   = info->index[i].block.step;
      count[i]  = info->index[i].block.count;
      shrink[i] = 0;
      break;
    }
  }

  for (i=0; i<rank; i++) {
    if ( shrink[i] ) {
      flag = 1;
      break;
    }
  }

  refer = self;
  rank  = ca->rank;

  offset = 0;

  if ( flag ) {
    rb_ca_index_restruct_block(&rank, shrink,
                              dim, start, step, count, &offset);
  }

  return rb_ca_block_new(refer, rank, dim, start, step, count, offset);
}

static VALUE
rb_ca_refer_new_flatten (VALUE self)
{
  CArray *ca;
  int32_t dim0;

  Data_Get_Struct(self, CArray, ca);
  dim0 = ca->elements;
  return rb_ca_refer_new(self, ca->data_type, 1, &dim0, ca->bytes, 0);
}

/* rdoc:
  class CArray
    def [] (*spec)
    end
  end
*/

static VALUE
rb_ca_fetch_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj = Qnil;
  CArray *ca;
  CAIndexInfo info;

 retry:

  Data_Get_Struct(self, CArray, ca);
  rb_ca_scan_index(ca->rank, ca->dim, ca->elements, argc, argv, &info);

  switch ( info.type ) {
  case CA_REG_ADDRESS_COMPLEX:
    self = rb_ca_refer_new_flatten(self);
    goto retry;
  case CA_REG_ADDRESS:
    obj = rb_ca_ref_address(self, &info);
    break;
  case CA_REG_FLATTEN:
    obj = rb_ca_refer_new_flatten(self);
    break;
  case CA_REG_POINT:
    obj = rb_ca_ref_point(self, &info);
    break;
  case CA_REG_ALL:
    obj = rb_ca_ref_all(self, &info);
    break;
  case CA_REG_BLOCK:
    obj = rb_ca_ref_block(self, &info);
    break;
  case CA_REG_SELECT:
    obj = rb_ca_select_new(self, argv[0]);
    break;
  case CA_REG_ITERATOR:
    obj = rb_dim_iter_new(self, &info);
    break;
  case CA_REG_REPEAT:
    obj = rb_ca_repeat(argc, argv, self);
    break;
  case CA_REG_UNBOUND_REPEAT:
    obj = rb_funcall2(self, rb_intern("unbound_repeat"), argc, argv);
    break;
  case CA_REG_MAPPING:
    obj = rb_ca_mapping(argc, argv, self);
    break;
  case CA_REG_GRID:
    obj = rb_ca_grid(argc, argv, self);
    break;
  case CA_REG_METHOD_CALL: {
    volatile VALUE idx;
    idx = rb_funcall2(self, SYM2ID(info.symbol), argc-1, argv+1);
    obj = rb_ca_fetch(self, idx);
    break;
  }
  case CA_REG_MEMBER: {
    volatile VALUE data_class = rb_ca_data_class(self);
    if ( ! NIL_P(data_class) ) {
      obj = rb_ca_field_as_member(self, info.symbol);
      break;
    }
    else {
      rb_raise(rb_eIndexError, 
               "can't refer member of carray doesn't have data_class");
    }
    break;
  }
  default:
    rb_raise(rb_eIndexError, "invalid index specified");
  }

  return obj;
}

/* rdoc:
  class CArray
    def []= (*spec)
    end
  end
*/

static VALUE
rb_ca_store_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj = Qnil, rval;
  CArray *ca;
  CAIndexInfo info;

  rb_ca_modify(self);

  obj = rval = argv[argc-1];
  argc -= 1;

 retry:

  Data_Get_Struct(self, CArray, ca);

  rb_ca_scan_index(ca->rank, ca->dim, ca->elements, argc, argv, &info);

  switch ( info.type ) {
  case CA_REG_ADDRESS_COMPLEX:
    self = rb_ca_refer_new_flatten(self);
    goto retry;
  case CA_REG_ADDRESS:
    obj = rb_ca_store_address(self, &info, rval);
    break;
  case CA_REG_FLATTEN:
    self = rb_ca_refer_new_flatten(self);
    obj = rb_ca_store_all(self, rval);
    break;
  case CA_REG_POINT:
    obj = rb_ca_store_point(self, &info, rval);
    break;
  case CA_REG_ALL:
    obj = rb_ca_store_all(self, rval);
    break;
  case CA_REG_BLOCK: {
    volatile VALUE block;
    block = rb_ca_ref_block(self, &info);
    obj   = rb_ca_store_all(block, rval); 
    break;
  }
  case CA_REG_SELECT: {
    obj = rb_ca_select_new(self, argv[0]);
    obj = rb_ca_store_all(obj, rval);
    break;
  }
  case CA_REG_ITERATOR: {
    obj = rb_dim_iter_new(self, &info);
    obj = rb_funcall(obj, rb_intern("asign!"), 1, rval);
    break;
  }
  case CA_REG_REPEAT: {
    obj = rb_ca_repeat(argc, argv, self);
    obj = rb_ca_store_all(obj, rval);
    break;
  }
  case CA_REG_UNBOUND_REPEAT:
    obj = rb_funcall2(self, rb_intern("unbound_repeat"), argc, argv);
    obj = rb_ca_store_all(obj, rval);
    break;
  case CA_REG_MAPPING: {
    obj = rb_ca_mapping(argc, argv, self);
    obj = rb_ca_store_all(obj, rval);
    break;
  }
  case CA_REG_GRID: {
    obj = rb_ca_grid(argc, argv, self);
    obj = rb_ca_store_all(obj, rval);
    break;
  }
  case CA_REG_METHOD_CALL: {
    volatile VALUE idx;
    Data_Get_Struct(self, CArray, ca);
    ca_attach(ca);
    idx = rb_funcall2(self, SYM2ID(info.symbol), argc-1, argv+1);
    obj = rb_ca_store(self, idx, rval);
    ca_detach(ca);
    break;
  }
  case CA_REG_MEMBER: {
    volatile VALUE data_class = rb_ca_data_class(self);
    if ( ! NIL_P(data_class) ) {
      obj = rb_ca_field_as_member(self, info.symbol);
      obj = rb_ca_store_all(obj, rval);
    }
    else {
      rb_raise(rb_eIndexError, 
               "can't store member of carray doesn't have data_class");
    }
    break;
  }
  }
  return obj;
}

VALUE
rb_ca_fetch (VALUE self, VALUE index)
{
  switch ( TYPE(index) ) {
  case T_ARRAY:
    return rb_ca_fetch_method(RARRAY_LEN(index), RARRAY_PTR(index), self);
  default:
    return rb_ca_fetch_method(1, &index, self);
  }
}

VALUE
rb_ca_fetch2 (VALUE self, int n, VALUE *rindex)
{
  return rb_ca_fetch_method(n, rindex, self);
}

VALUE
rb_ca_store (VALUE self, VALUE index, VALUE rval)
{
  switch ( TYPE(index) ) {
  case T_ARRAY:
    index = rb_obj_clone(index);
    rb_ary_push(index, rval);
    return rb_ca_store_method(RARRAY_LEN(index), RARRAY_PTR(index), self);
  default: {
    VALUE rindex[2] = { index, rval };
    return rb_ca_store_method(2, rindex, self);
  }
  }
}

VALUE
rb_ca_store2 (VALUE self, int n, VALUE *rindex, VALUE rval)
{
  VALUE index = rb_ary_new4(n, rindex);
  rb_ary_push(index, rval);
  return rb_ca_store_method(RARRAY_LEN(index), RARRAY_PTR(index), self);
}

/* rdoc:
  def CArray.scan_index(dim, idx)
  end
*/

static VALUE
rb_ca_s_scan_index (VALUE self, VALUE rdim, VALUE ridx)
{
  volatile VALUE rtype, rrank, rindex;
  CAIndexInfo info;
  int     rank;
  int32_t dim[CA_RANK_MAX];
  int32_t elements;
  int i;

  Check_Type(rdim, T_ARRAY);
  Check_Type(ridx, T_ARRAY);

  elements = 1;
  rank = RARRAY_LEN(rdim);
  for (i=0; i<rank; i++) {
    dim[i] = NUM2LONG(rb_ary_entry(rdim, i));
    elements *= dim[i];
  }

  CA_CHECK_RANK(rank);
  CA_CHECK_DIM(rank, dim);

  rb_ca_scan_index(rank, dim, elements,
                   RARRAY_LEN(ridx), RARRAY_PTR(ridx), &info);

  rtype  = INT2NUM(info.type);
  rrank  = INT2NUM(info.rank);
  rindex = rb_ary_new2(info.rank);

  switch ( info.type ) {
  case CA_REG_NONE:
  case CA_REG_ALL:
    break;
  case CA_REG_ADDRESS:
    rb_ary_store(rindex, 0, LONG2NUM(info.index[0].scalar));
    break;
  case CA_REG_ADDRESS_COMPLEX: {
    volatile VALUE rinfo;
    int32_t elements = 1;
    for (i=0; i<rank; i++) {
      elements *= dim[i];
    }
    rinfo = rb_ca_s_scan_index(self, rb_ary_new3(1, LONG2NUM(elements)), ridx);
    rtype = LONG2NUM(CA_REG_ADDRESS_COMPLEX);
    rindex = rb_struct_aref(rinfo, rb_str_new2("index"));
    break;
  }
  case CA_REG_POINT:
    for (i=0; i<rank; i++) {
      rb_ary_store(rindex, i, LONG2NUM(info.index[i].scalar));
    }
    break;
  case CA_REG_SELECT:
    break;
  case CA_REG_BLOCK:
  case CA_REG_ITERATOR:
    for (i=0; i<rank; i++) {
      switch ( info.index_type[i] ) {
      case CA_IDX_SCALAR:
        rb_ary_store(rindex, i, LONG2NUM(info.index[i].scalar));
        break;
      case CA_IDX_ALL:
        rb_ary_store(rindex, i,
                     rb_ary_new3(3,
                                 LONG2NUM(0),
                                 rb_ary_entry(rdim, i),
                                 LONG2NUM(1)));
        break;
      case CA_IDX_BLOCK:
        rb_ary_store(rindex, i,
                     rb_ary_new3(3,
                                 LONG2NUM(info.index[i].block.start),
                                 LONG2NUM(info.index[i].block.count),
                                 LONG2NUM(info.index[i].block.step)));
        break;
      case CA_IDX_SYMBOL:
        rb_ary_store(rindex, i,
                     rb_ary_new3(2,
                                 ID2SYM(info.index[i].symbol.id),
                                 info.index[i].symbol.spec));
        break;
      default:
        rb_raise(rb_eRuntimeError, "unknown index spec");
      }
    }
    break;
  case CA_REG_REPEAT:
  case CA_REG_GRID:
  case CA_REG_MAPPING:
  case CA_REG_METHOD_CALL:
  case CA_REG_UNBOUND_REPEAT:
  case CA_REG_MEMBER:  
    break;
  default:
    rb_raise(rb_eArgError, "unknown index specification");
  }

  return rb_struct_new(S_CAInfo, rtype, rindex);
}

/* rdoc:
  class CArray
    def normalize_index (idx)
    end
  end
*/

static VALUE
rb_ca_normalize_index (VALUE self, VALUE ridx)
{
  volatile VALUE rindex;
  CArray *ca;
  CAIndexInfo info;
  int i;

  Data_Get_Struct(self, CArray, ca);
  Check_Type(ridx, T_ARRAY);

  rb_ca_scan_index(ca->rank, ca->dim, ca->elements,
                   RARRAY_LEN(ridx), RARRAY_PTR(ridx), &info);

  switch ( info.type ) {
  case CA_REG_ALL:
  case CA_REG_SELECT:
  case CA_REG_ADDRESS:
    rindex = rb_ary_new2(info.rank);
    rb_ary_store(rindex, 0, LONG2NUM(info.index[0].scalar));
    return rindex;
  case CA_REG_POINT:
    rindex = rb_ary_new2(info.rank);
    for (i=0; i<ca->rank; i++) {
      rb_ary_store(rindex, i, LONG2NUM(info.index[i].scalar));
    }
    return rindex;
  case CA_REG_BLOCK:
  case CA_REG_ITERATOR:
    rindex = rb_ary_new2(info.rank);
    for (i=0; i<ca->rank; i++) {
      switch ( info.index_type[i] ) {
      case CA_IDX_SCALAR:
        rb_ary_store(rindex, i, LONG2NUM(info.index[i].scalar));
        break;
      case CA_IDX_ALL:
        rb_ary_store(rindex, i, Qnil);
        break;
      case CA_IDX_BLOCK:
        rb_ary_store(rindex, i,
                     rb_ary_new3(3,
                                 LONG2NUM(info.index[i].block.start),
                                 LONG2NUM(info.index[i].block.count),
                                 LONG2NUM(info.index[i].block.step)));
        break;
      case CA_IDX_SYMBOL:
        rb_ary_store(rindex, i, ID2SYM(info.index[i].symbol.id));
        break;
      default:
        rb_raise(rb_eRuntimeError, "unknown index spec");
      }
    }
    return rindex;
  case CA_REG_ADDRESS_COMPLEX:
  case CA_REG_FLATTEN:
    self = rb_ca_refer_new_flatten(self);
    return rb_ca_normalize_index(self, ridx);
  default:
    rb_raise(rb_eArgError, "unknown index specification");
  }
  rb_raise(rb_eArgError, "fail to normalize index");
}

/* ------------------------------------------------------------------- */

/* rdoc:
  class CArray
    # converts addr to index
    def addr2index (addr)
    end
  end
*/

VALUE
rb_ca_addr2index (VALUE self, VALUE raddr)
{
  volatile VALUE out;
  CArray *ca;
  int32_t *dim;
  int32_t addr;
  int i;

  Data_Get_Struct(self, CArray, ca);

  addr = NUM2INT(raddr);
  if ( addr < 0 || addr >= ca->elements ) {
    rb_raise(rb_eArgError,
             "address %i is out of range (0..%i)",
             addr, ca->elements-1);
  }
  dim = ca->dim;
  out = rb_ary_new2(ca->rank);
  for (i=ca->rank-1; i>=0; i--) { /* in descending order */
    rb_ary_store(out, i, LONG2NUM(addr % dim[i]));
    addr /= dim[i];
  }

  return out;
}

/* rdoc:
  class CArray
    def index2addr (*index)
    end
  end
*/

VALUE
rb_ca_index2addr (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  CArray  *ca, *co, *cidx[CA_RANK_MAX];
  int32_t *q, *p[CA_RANK_MAX], s[CA_RANK_MAX];
  int32_t *dim;
  int32_t addr, elements = 0;
  int32_t i, k, n;
  boolean8_t *m;
  int     all_number = 1;

  Data_Get_Struct(self, CArray, ca);

  if ( argc != ca->rank ) {
    rb_raise(rb_eRuntimeError, "invalid rank of index");
  }

  for (i=0; i<ca->rank; i++) {
    if ( ! rb_obj_is_kind_of(argv[i], rb_cInteger) ) {
      all_number = 0;
      break;
    }
  }

  if ( all_number ) {
    dim = ca->dim;
    addr = 0;
    for (i=0; i<ca->rank; i++) {
      k = NUM2INT(argv[i]);
      CA_CHECK_INDEX(k, dim[i]);
      addr = dim[i] * addr + k;
    }
    return LONG2NUM(addr);
  }

  elements = 1;
  for (i=0; i<ca->rank; i++) {
    cidx[i] = ca_wrap_readonly(argv[i], CA_INT32);
    if ( ! ca_is_scalar(cidx[i]) ) {
      if ( elements == 1 ) {
        elements = cidx[i]->elements;
      }
      else if ( elements != cidx[i]->elements ) {
        rb_raise(rb_eRuntimeError, "mismatch in # of elements");
      }
    }
  }

  for (i=0; i<ca->rank; i++) {
    ca_attach(cidx[i]);
    ca_set_iterator(1, cidx[i], &p[i], &s[i]);
  }

  obj = rb_carray_new(CA_INT32, 1, &elements, 0, NULL);
  Data_Get_Struct(obj, CArray, co);

  q = (int32_t *) co->ptr;

  ca_copy_mask_overwrite_n(co, elements, ca->rank, cidx);
  m = ( co->mask ) ? (boolean8_t *) co->mask->ptr : NULL;

  dim = ca->dim;

  if ( m ) {
    n = elements;  
    while ( n-- ) {
      if ( !*m ) {
        addr = 0;
        for (i=0; i<ca->rank; i++) {
          k = *(p[i]);
          p[i]+=s[i];
          CA_CHECK_INDEX(k, dim[i]);
          addr = dim[i] * addr + k;
        }
        *q = addr;
      }
      else {
        for (i=0; i<ca->rank; i++) {
          p[i]+=s[i];
        }
      }
      m++; q++;
    }
  }
  else {
    n = elements;  
    while ( n-- ) {
      addr = 0;
      for (i=0; i<ca->rank; i++) {
        k = *(p[i]);
        p[i]+=s[i];
        CA_CHECK_INDEX(k, dim[i]);
        addr = dim[i] * addr + k;
      }
      *q = addr;
      q++;
    }
  }

  for (i=0; i<ca->rank; i++) {
    ca_detach(cidx[i]);
  }

  return obj;
}


void
Init_carray_access ()
{

#if RUBY_VERSION_CODE >= 190
#else
  id_beg   = rb_intern("begin");
  id_end   = rb_intern("end");
  id_excl  = rb_intern("excl");
#endif

  id_ca    = rb_intern("ca");
  id_to_ca = rb_intern("to_ca");
  sym_star = ID2SYM(rb_intern("*"));
  sym_perc = ID2SYM(rb_intern("%"));

  rb_define_method(rb_cCArray, "[]", rb_ca_fetch_method, -1);
  rb_define_method(rb_cCArray, "[]=", rb_ca_store_method, -1);

  rb_define_method(rb_cCArray, "fill", rb_ca_fill, 1);
  rb_define_method(rb_cCArray, "fill_copy", rb_ca_fill_copy, 1);

  S_CAInfo = rb_struct_define("CAIndexInfo", "type", "index", NULL);

  rb_define_singleton_method(rb_cCArray, "guess_array_shape",
                                          rb_ca_s_guess_array_shape, 1);
  rb_define_singleton_method(rb_cCArray, "scan_index", rb_ca_s_scan_index, 2);
  rb_define_method(rb_cCArray, "normalize_index", rb_ca_normalize_index, 1);

  rb_define_method(rb_cCArray, "index2addr", rb_ca_index2addr, -1);
  rb_define_method(rb_cCArray, "addr2index", rb_ca_addr2index, 1);

  rb_define_const(rb_cObject, "CA_REG_NONE",     INT2NUM(CA_REG_NONE));
  rb_define_const(rb_cObject, "CA_REG_ALL",      INT2NUM(CA_REG_ALL));
  rb_define_const(rb_cObject, "CA_REG_ADDRESS",  INT2NUM(CA_REG_ADDRESS));
  rb_define_const(rb_cObject, "CA_REG_FLATTEN",  INT2NUM(CA_REG_FLATTEN));
  rb_define_const(rb_cObject, "CA_REG_ADDRESS_COMPLEX",
                                                 INT2NUM(CA_REG_ADDRESS_COMPLEX));
  rb_define_const(rb_cObject, "CA_REG_POINT",    INT2NUM(CA_REG_POINT));
  rb_define_const(rb_cObject, "CA_REG_BLOCK",    INT2NUM(CA_REG_BLOCK));
  rb_define_const(rb_cObject, "CA_REG_SELECT",   INT2NUM(CA_REG_SELECT));
  rb_define_const(rb_cObject, "CA_REG_ITERATOR", INT2NUM(CA_REG_ITERATOR));
  rb_define_const(rb_cObject, "CA_REG_REPEAT",   INT2NUM(CA_REG_REPEAT));
  rb_define_const(rb_cObject, "CA_REG_GRID",     INT2NUM(CA_REG_GRID));
  rb_define_const(rb_cObject, "CA_REG_MAPPING",  INT2NUM(CA_REG_MAPPING));
  rb_define_const(rb_cObject, "CA_REG_METHOD_CALL",
                                                 INT2NUM(CA_REG_METHOD_CALL));
  rb_define_const(rb_cObject, "CA_REG_UNBOUND_REPEAT",
                                                 INT2NUM(CA_REG_UNBOUND_REPEAT));
  rb_define_const(rb_cObject, "CA_REG_MEMBER",   INT2NUM(CA_REG_MEMBER));

}

