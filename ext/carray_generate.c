/* ---------------------------------------------------------------------------

  Population helpers that fill a CArray in place: #where (collect flat
  addresses of non-zero / true cells) and the #seq / #seq! family
  (arithmetic / object-method progressions).  User-facing docs live in
  yard-stubs/carray_generate.rb.

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"

/* ----------------------------------------------------------------- */

/* CArray#where -- collect the flat addresses of all non-zero (or
   true) cells in self into a fresh 1-D CA_SIZE array.  Non-boolean
   inputs are first coerced to boolean via rb_ca_to_boolean.  Masked
   cells are excluded.

   Also used internally by ext/ca_obj_grid.c when it needs to extract
   the addresses of true cells from a boolean axis selector. */
VALUE
rb_ca_where (VALUE self)
{
  volatile VALUE bool0, obj;
  CArray *ca, *co;
  boolean8_t *p, *m;
  ca_size_t *q;
  ca_size_t i, count;

  bool0 = ( ! rb_ca_is_boolean_type(self) ) ? rb_ca_to_boolean(self) : self;

  TypedData_Get_Struct(bool0, CArray, &carray_data_type, ca);

  ca_attach(ca);

  /* calculate elements of output array */
  p = (boolean8_t *) ca->ptr;
  m = ca_mask_ptr(ca);
  count = 0;
  if ( m ) {
    for (i=0; i<ca->elements; i++) {
      if ( ( ! *m ) && ( *p ) ) { count++; }    /* not-masked && true */
      m++; p++;
    }
  }
  else {
    for (i=0; i<ca->elements; i++) {
      if ( *p ) { count++; }                    /* true */ 
      p++;
    }
  }

  /* create output array */
  obj = rb_carray_new(CA_SIZE, 1, &count, 0, NULL);
  TypedData_Get_Struct(obj, CArray, &carray_data_type, co);

  /* store address which elements is true to output array */
  p = (boolean8_t *) ca->ptr;
  q = (ca_size_t *) co->ptr;
  m = ca_mask_ptr(ca);
  if ( m )  {
    for (i=0; i<ca->elements; i++) {  /* not-masked && true */
      if ( ( ! *m ) && ( *p ) ) { *q = i; q++; }
      m++; p++; 
    }
  }
  else {                              /* true */
    for (i=0; i<ca->elements; i++) {
      if ( *p ) { *q = i; q++; }
      p++;
    }
  }

  ca_detach(ca);

  return obj;
}

/* ----------------------------------------------------------------- */

/* Fill the whole array in row-major order with `step*i + offset`. */
#define proc_seq_bang(type, from, to)       \
  {                                         \
    type *p = (type *)ca->ptr;              \
    ca_size_t i;                              \
    if ( NIL_P(roffset) && NIL_P(rstep) ) { \
      for (i=0; i<ca->elements; i++) {    \
        *p++ = (type) to(i);                     \
      }                                   \
    }                                     \
    else if ( rb_obj_is_kind_of(rstep, rb_cFloat) ||              \
              rb_obj_is_kind_of(roffset, rb_cFloat) ) {            \
      type offset = (NIL_P(roffset)) ? (type) 0 : (type) from(roffset);  \
      double step = (NIL_P(rstep)) ? 1 : NUM2DBL(rstep);          \
      for (i=0; i<ca->elements; i++) {    \
        *p++ = (type) to(step*i+offset);         \
      }                                   \
    }                                     \
    else {                                \
      type offset = (NIL_P(roffset)) ? (type) 0 : (type) from(roffset); \
      type step   = (NIL_P(rstep)) ? (type) 1 : (type) from(rstep);     \
      for (i=0; i<ca->elements; i++) {    \
        *p++ = (type) to(step*i+offset);         \
      }                                   \
    }                                     \
  }

/* Per-axis fill: the value depends only on the coordinate along the seq
   axis, so it is constant over the `inner_size` cells inside that axis
   and repeats for each of the `outer_size` blocks outside it.  Writing
   these as contiguous constant runs keeps the sweep fully streaming
   (memset-class); when the seq axis is innermost, inner_size collapses
   to 1 and this degenerates to a ramp.  `len`, `inner_size`,
   `outer_size` come from the enclosing scope (ca_seq_geometry). */
#define proc_seq_bang_axis(type, from, to)                              \
  {                                                                     \
    type *p = (type *)ca->ptr;                                          \
    ca_size_t o, k, in;                                                 \
    if ( rb_obj_is_kind_of(rstep, rb_cFloat) ||                         \
         rb_obj_is_kind_of(roffset, rb_cFloat) ) {                      \
      type offset = (NIL_P(roffset)) ? (type) 0 : (type) from(roffset); \
      double step = (NIL_P(rstep)) ? 1 : NUM2DBL(rstep);                \
      for (o=0; o<outer_size; o++) {                                    \
        for (k=0; k<len; k++) {                                         \
          type v = (type) to(step*k+offset);                           \
          for (in=0; in<inner_size; in++) { *p++ = v; }                 \
        }                                                               \
      }                                                                 \
    }                                                                   \
    else {                                                              \
      type offset = (NIL_P(roffset)) ? (type) 0 : (type) from(roffset); \
      type step   = (NIL_P(rstep)) ? (type) 1 : (type) from(rstep);     \
      for (o=0; o<outer_size; o++) {                                    \
        for (k=0; k<len; k++) {                                         \
          type v = (type) to(step*k+offset);                           \
          for (in=0; in<inner_size; in++) { *p++ = v; }                 \
        }                                                               \
      }                                                                 \
    }                                                                   \
  }

#ifdef HAVE_COMPLEX_H
#define seq_complex_cases(PROC)                                    \
  case CA_CMPLX64:  PROC(cmplx64_t, (cmplx64_t) NUM2CC, ); break;  \
  case CA_CMPLX128: PROC(cmplx128_t, NUM2CC, );           break;
#else
#define seq_complex_cases(PROC)
#endif

/* Dispatch `PROC` (proc_seq_bang or proc_seq_bang_axis) over the numeric
   data types. */
#define seq_bang_switch(PROC)                                           \
  switch ( ca->data_type ) {                                            \
  case CA_INT8:     PROC(int8_t,     NUM2LONG, );   break;              \
  case CA_UINT8:    PROC(uint8_t,   NUM2ULONG, );  break;               \
  case CA_INT16:    PROC(int16_t,    NUM2LONG, );   break;              \
  case CA_UINT16:   PROC(uint16_t,  NUM2ULONG, );  break;               \
  case CA_INT32:    PROC(int32_t,    NUM2LONG, );   break;              \
  case CA_UINT32:   PROC(uint32_t,  NUM2ULONG, );  break;               \
  case CA_INT64:    PROC(int64_t,    NUM2LL, );     break;              \
  case CA_UINT64:   PROC(uint64_t,  rb_num2ull, ); break;               \
  case CA_FLOAT32:  PROC(float32_t,  NUM2DBL, );    break;              \
  case CA_FLOAT64:  PROC(float64_t,  NUM2DBL, );    break;              \
  seq_complex_cases(PROC)                                               \
  default: rb_raise(rb_eCADataTypeError,                                \
                    "invalid data type of receiver");                   \
  }

/* Resolve the `axis:` kwarg to a concrete axis, or -1 for a flat fill.
   Rejects a non-integer (e.g. an Array: multi-axis seq is not
   supported) and an out-of-range axis; normalizes a negative axis. */
static int
ca_seq_resolve_axis (CArray *ca, VALUE raxis)
{
  int axis;
  if ( NIL_P(raxis) ) {
    return -1;
  }
  if ( TYPE(raxis) == T_ARRAY ) {
    rb_raise(rb_eArgError,
             "seq axis must be a single integer (multi-axis seq is not supported)");
  }
  axis = NUM2INT(raxis);
  if ( axis < 0 ) {
    axis += ca->ndim;
  }
  if ( axis < 0 || axis >= ca->ndim ) {
    rb_raise(rb_eArgError,
             "axis out of range for seq (0...%d)", ca->ndim);
  }
  return axis;
}

/* Row-major geometry of a per-axis fill: `len` = length of the seq
   axis, `inner` = product of the trailing dims (contiguous run held
   constant), `outer` = product of the leading dims. */
static void
ca_seq_geometry (CArray *ca, int axis,
                 ca_size_t *len, ca_size_t *inner, ca_size_t *outer)
{
  int i;
  ca_size_t in = 1, out = 1;
  for (i=axis+1; i<ca->ndim; i++) { in  *= ca->dim[i]; }
  for (i=0;      i<axis;    i++) { out *= ca->dim[i]; }
  *len   = ca->dim[axis];
  *inner = in;
  *outer = out;
}

static VALUE
rb_ca_seq_bang_object (VALUE self, VALUE roffset, VALUE rstep, int axis)
{
  volatile VALUE rval, rmethod = Qnil;
  CArray *ca;
  VALUE *p;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( TYPE(rstep) == T_SYMBOL ) {                /* e.g. a.seq("a", :succ) */
    rmethod = rstep;
    rstep = Qnil;
  }

  ca_allocate(ca);

  if ( ca_has_mask(ca) ) {
    ca_clear_mask(ca);                            /* clear all mask */
  }

  if ( axis < 0 ) {                               /* flat fill */
    p = (VALUE *)ca->ptr;
    if ( rb_obj_is_kind_of(roffset, rb_cFloat) ||
         rb_obj_is_kind_of(rstep, rb_cFloat) ) {  /* a.seq(0.0, 1.0) */
      double offset = ( NIL_P(roffset) ) ? 0 : NUM2DBL(roffset);
      double step = ( NIL_P(rstep) ) ? 1 : NUM2DBL(rstep);
      for (i=0; i<ca->elements; i++) {
        *p++ = rb_float_new(step*i+offset);
      }
    }
    else if ( NIL_P(roffset) ) {
      if ( ! NIL_P(rstep) ) {                     /* a.seq(nil, 1) */
        rb_raise(rb_eArgError,
                 "nil is invalid as offset for seq([offset[,step])");
      }
      for (i=0; i<ca->elements; i++) {            /* a.seq() */
        *p++ = LL2NUM(i);
      }
    }
    else if ( ! NIL_P(rmethod) ) {                /* a.seq(obj, :method) */
      ID id_method = SYM2ID(rmethod);
      *p++ = rval = roffset;
      for (i=1; i<ca->elements; i++) {
        *p++ = rval = rb_funcall(rval, id_method, 0);
      }
    }
    else {                                        /* a.seq(obj, step) */
      ID id_plus = rb_intern("+");
      rstep   = ( NIL_P(rstep) ) ? INT2NUM(1) : rstep;
      *p++ = rval = roffset;
      for (i=1; i<ca->elements; i++) {
        *p++ = rval = rb_funcall(rval, id_plus, 1, rstep);
      }
    }
  }
  else {                                          /* per-axis fill */
    /* Build the length-`len` progression first, then broadcast it over
       the outer/inner dims.  The generated VALUEs are held in a Ruby
       Array so the GC keeps them live across the progression's method
       calls (rb_funcall may trigger a collection). */
    ca_size_t len, inner_size, outer_size, o, k, in;
    volatile VALUE vtbl;
    ca_seq_geometry(ca, axis, &len, &inner_size, &outer_size);
    vtbl = rb_ary_new_capa(len);
    if ( rb_obj_is_kind_of(roffset, rb_cFloat) ||
         rb_obj_is_kind_of(rstep, rb_cFloat) ) {
      double offset = ( NIL_P(roffset) ) ? 0 : NUM2DBL(roffset);
      double step = ( NIL_P(rstep) ) ? 1 : NUM2DBL(rstep);
      for (k=0; k<len; k++) {
        rb_ary_push(vtbl, rb_float_new(step*k+offset));
      }
    }
    else if ( NIL_P(roffset) ) {
      if ( ! NIL_P(rstep) ) {
        rb_raise(rb_eArgError,
                 "nil is invalid as offset for seq([offset[,step])");
      }
      for (k=0; k<len; k++) {
        rb_ary_push(vtbl, LL2NUM(k));
      }
    }
    else if ( ! NIL_P(rmethod) ) {
      ID id_method = SYM2ID(rmethod);
      rval = roffset;
      rb_ary_push(vtbl, rval);
      for (k=1; k<len; k++) {
        rval = rb_funcall(rval, id_method, 0);
        rb_ary_push(vtbl, rval);
      }
    }
    else {
      ID id_plus = rb_intern("+");
      rstep = ( NIL_P(rstep) ) ? INT2NUM(1) : rstep;
      rval = roffset;
      rb_ary_push(vtbl, rval);
      for (k=1; k<len; k++) {
        rval = rb_funcall(rval, id_plus, 1, rstep);
        rb_ary_push(vtbl, rval);
      }
    }
    p = (VALUE *)ca->ptr;
    for (o=0; o<outer_size; o++) {
      for (k=0; k<len; k++) {
        VALUE v = RARRAY_AREF(vtbl, k);
        for (in=0; in<inner_size; in++) { *p++ = v; }
      }
    }
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

/* CArray#seq!(init_val=0, step=1, axis: nil) -- arithmetic-progression
   fill, in place.  Without `axis:` the fill runs in row-major order
   over the whole array; with `axis: k` the progression runs along axis
   k and repeats across the other axes.  Numeric arrays use the typed
   proc_seq_bang / proc_seq_bang_axis macros; object arrays delegate to
   rb_ca_seq_bang_object (which also accepts a Symbol `step` to drive
   per-element method calls like `:succ`).  Mutates self and clears any
   existing mask. */
static VALUE
rb_ca_seq_bang_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE roffset = Qnil, rstep = Qnil, rkw = Qnil, raxis = Qnil;
  CArray *ca;
  int axis;

  rb_ca_modify(self);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  rb_scan_args(argc, argv, "02:", (VALUE *) &roffset, (VALUE *) &rstep,
               (VALUE *) &rkw);
  rb_scan_options(rkw, "axis", (VALUE *) &raxis);

  axis = ca_seq_resolve_axis(ca, raxis);          /* -1 = flat; validates */

  /* delegate to rb_ca_seq_bang_object if data_type is object */
  if ( ca_is_object_type(ca) ) {
    return rb_ca_seq_bang_object(self, roffset, rstep, axis);
  }

  ca_allocate(ca);

  if ( ca_has_mask(ca) ) {
    ca_clear_mask(ca);              /* clear all mask */
  }

  if ( axis < 0 ) {
    seq_bang_switch(proc_seq_bang);
  }
  else {
    ca_size_t len, inner_size, outer_size;
    ca_seq_geometry(ca, axis, &len, &inner_size, &outer_size);
    seq_bang_switch(proc_seq_bang_axis);
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

/* CArray#seq(init_val=0, step=1, axis: nil) -- non-destructive variant:
   allocate a fresh template like self and fill it via
   rb_ca_seq_bang_method. */
static VALUE
rb_ca_seq_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out = rb_ca_template(self);
  return rb_ca_seq_bang_method(argc, argv, out);
}

/* C-call shims: pack the (offset, step) args and route through the
   Ruby-method entries above.  Called by ext/carray_cast.c (= the
   Range / ArithmeticSequence to-CArray path uses rb_ca_seq). */
VALUE
rb_ca_seq_bang (VALUE self, VALUE offset, VALUE step)
{
  VALUE args[2] = { offset, step };
  return rb_ca_seq_bang_method(2, args, self);
}

VALUE
rb_ca_seq_bang2 (VALUE self, int n, VALUE *args)
{
  return rb_ca_seq_bang_method(n, args, self);
}

VALUE
rb_ca_seq (VALUE self, VALUE offset, VALUE step)
{
  VALUE args[2] = { offset, step };
  return rb_ca_seq_method(2, args, self);
}

VALUE
rb_ca_seq2 (VALUE self, int n, VALUE *args)
{
  return rb_ca_seq_method(n, args, self);
}

/* ----------------------------------------------------------------- */

/* CArray#swap_bytes lives in ext/ca_obj_byte_swap.c (returns a lazy
   CAByteSwap view).  Use `arr.swap_bytes.to_ca` when an eager copy is
   wanted. */

/* ----------------------------------------------------------------- */


void
Init_carray_generate (void)
{
  rb_define_method(rb_cCArray, "where", rb_ca_where, 0);
  rb_define_method(rb_cCArray, "seq!", rb_ca_seq_bang_method, -1);
  rb_define_method(rb_cCArray, "seq", rb_ca_seq_method, -1);
  /* swap_bytes / swap_bytes! (and the ca_swap_bytes kernel) live in
     ext/ca_obj_byte_swap.c; registered by Init_ca_obj_byte_swap.
     clip / clip! are mkkernel-generated as a triop with signature
     (lo, hi); see ext/mkkernel.rb (MkKernel.triop :clip), registered
     by Init_carray_kernels. */
}



