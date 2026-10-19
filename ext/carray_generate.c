/* ---------------------------------------------------------------------------

  Population helpers that fill a CArray in place: #where (collect flat
  addresses of non-zero / true cells) and the #seq / #seq! family
  (arithmetic / object-method progressions).  User-facing docs live in
  yard-stubs/carray_generate.rb.

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "carray_internal.h"   /* ca_attach_window, ca_normalize_axis_arg */
#include "ca_obj_face.h"      /* ca_face_element_to_storage */

/* ----------------------------------------------------------------- */

/* CArray#where -- collect the flat addresses of all non-zero (or
   true) cells in self into a fresh 1-D CA_SIZE array.  An integer,
   float or complex array selects its non-zero cells (NaN is non-zero);
   any other non-boolean array is cast to boolean, which takes only
   0 / 1 / true / false.  Masked cells are excluded.

   Also used internally by ext/ca_obj_grid.c when it needs to extract
   the addresses of true cells from a boolean axis selector. */
VALUE
rb_ca_where (VALUE self)
{
  volatile VALUE bool0, obj;
  CArray *ca, *co;
  boolean8_t *p, *m;
  ca_size_t *q;
  ca_size_t i, j, n, last, count;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ca_is_boolean_type(ca) ) {
    bool0 = self;
  }
  else if ( ! ca_is_face(ca) &&
            ( ca_is_integer_type(ca) || ca_is_float_type(ca) ||
              ca_is_complex_type(ca) ) ) {
    bool0 = rb_funcall(self, rb_intern("ne"), 1, INT2FIX(0));
  }
  else {
    bool0 = rb_ca_to_boolean(self);
  }

  TypedData_Get_Struct(bool0, CArray, &carray_data_type, ca);

  ca_attach(ca);   /* window: nothing raises inside */

  /* calculate elements of output array, and the last selected cell */
  p = (boolean8_t *) ca->ptr;
  m = ca_mask_ptr(ca);
  n = ca->elements;
  count = 0;
  if ( m ) {
    for (i=0; i<n; i++) {
      count += ( ! m[i] ) & ( p[i] != 0 );     /* not-masked && true */
    }
  }
  else {
    for (i=0; i<n; i++) {
      count += ( p[i] != 0 );                   /* true */
    }
  }
  last = n - 1;
  if ( count > 0 ) {
    while ( m ? ( m[last] || ! p[last] ) : ! p[last] ) {
      last--;
    }
  }

  /* create output array */
  obj = rb_carray_new(CA_SIZE, 1, &count, 0, NULL);
  TypedData_Get_Struct(obj, CArray, &carray_data_type, co);

  /* Store the address of each selected cell.  Every cell up to the last
     selected one is written and the output position advances only on a
     selected cell, so a selection with true and false mixed at random
     does not mispredict a branch on most cells.  Stopping at the last
     selected cell keeps the writes inside the count slots. */
  q = (ca_size_t *) co->ptr;
  j = 0;
  if ( count > 0 ) {
    if ( m ) {
      for (i=0; i<=last; i++) {           /* not-masked && true */
        q[j] = i;
        j += ( ! m[i] ) & ( p[i] != 0 );
      }
    }
    else {                                /* true */
      for (i=0; i<=last; i++) {
        q[j] = i;
        j += ( p[i] != 0 );
      }
    }
  }

  ca_detach(ca);

  return obj;
}

/* ----------------------------------------------------------------- */

/* A number that is not an Integer (a Float, a Rational, a BigDecimal) makes
   the progression a real one: every cell is offset + step*i computed in
   double, and an integer array takes it as a store takes a float (cut
   toward zero; the run is checked to fit before anything is written). */
static int
ca_seq_is_real (VALUE v)
{
  return ! NIL_P(v) && ! RB_INTEGER_TYPE_P(v) && ! RB_TYPE_P(v, T_COMPLEX)
      && RTEST(rb_obj_is_kind_of(v, rb_cNumeric));
}

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
    else if ( ca_seq_is_real(rstep) || ca_seq_is_real(roffset) ) { \
      double offset = (NIL_P(roffset)) ? 0 : NUM2DBL(roffset);    \
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
    if ( ca_seq_is_real(rstep) || ca_seq_is_real(roffset) ) {           \
      double offset = (NIL_P(roffset)) ? 0 : NUM2DBL(roffset);          \
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
             "%s: axis must be a single Integer (a seq over several axes is not supported)",
             ca_calling_method_name());
  }
  axis = ca_normalize_axis_arg(raxis, ca->ndim, NULL);
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

/* The object fill calls Ruby per cell (`+`, or the method given as the
   step), which can raise part way, so it runs in a window that attaches:
   the cells filled before the raise then reach the parent with the rest
   left as they were, as they would for an entity. */

typedef struct {
  VALUE   self;
  CArray *ca;
  VALUE   roffset;
  VALUE   rstep;
  VALUE   rmethod;
  int     axis;
} ca_seq_ctx_t;

/* A value of the progression as it goes into a cell: a Face receiver (a
   CAString) checks it as it checks any value stored into it. */
static VALUE
ca_seq_cell (ca_seq_ctx_t *c, VALUE v)
{
  return ca_face_element_to_storage(c->self, c->ca, v);
}

static VALUE
ca_seq_bang_object_body (VALUE arg)
{
  ca_seq_ctx_t *c = (ca_seq_ctx_t *) arg;
  CArray *ca = c->ca;
  volatile VALUE rval;
  VALUE roffset = c->roffset, rstep = c->rstep, rmethod = c->rmethod;
  int axis = c->axis;
  VALUE *p;
  ca_size_t i;

  if ( axis < 0 ) {                               /* flat fill */
    p = (VALUE *)ca->ptr;
    if ( rb_obj_is_kind_of(roffset, rb_cFloat) ||
         rb_obj_is_kind_of(rstep, rb_cFloat) ) {  /* a.seq(0.0, 1.0) */
      double offset = ( NIL_P(roffset) ) ? 0 : NUM2DBL(roffset);
      double step = ( NIL_P(rstep) ) ? 1 : NUM2DBL(rstep);
      for (i=0; i<ca->elements; i++) {
        *p++ = ca_seq_cell(c, rb_float_new(step*i+offset));
      }
    }
    else if ( NIL_P(roffset) ) {
      if ( ! NIL_P(rstep) ) {                     /* a.seq(nil, 1) */
        rb_raise(rb_eArgError,
                 "nil is invalid as offset for seq([offset[,step])");
      }
      for (i=0; i<ca->elements; i++) {            /* a.seq() */
        *p++ = ca_seq_cell(c, LL2NUM(i));
      }
    }
    else if ( ! NIL_P(rmethod) ) {                /* a.seq(obj, :method) */
      ID id_method = SYM2ID(rmethod);
      if ( ca->elements == 0 ) {                  /* no first cell to write */
        return Qnil;
      }
      *p++ = ca_seq_cell(c, rval = roffset);
      for (i=1; i<ca->elements; i++) {
        *p++ = ca_seq_cell(c, rval = rb_funcall(rval, id_method, 0));
      }
    }
    else {                                        /* a.seq(obj, step) */
      ID id_plus = rb_intern("+");
      rstep   = ( NIL_P(rstep) ) ? INT2NUM(1) : rstep;
      if ( ca->elements == 0 ) {                  /* no first cell to write */
        return Qnil;
      }
      *p++ = ca_seq_cell(c, rval = roffset);
      for (i=1; i<ca->elements; i++) {
        *p++ = ca_seq_cell(c, rval = rb_funcall(rval, id_plus, 1, rstep));
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
        rb_ary_push(vtbl, ca_seq_cell(c, rb_float_new(step*k+offset)));
      }
    }
    else if ( NIL_P(roffset) ) {
      if ( ! NIL_P(rstep) ) {
        rb_raise(rb_eArgError,
                 "nil is invalid as offset for seq([offset[,step])");
      }
      for (k=0; k<len; k++) {
        rb_ary_push(vtbl, ca_seq_cell(c, LL2NUM(k)));
      }
    }
    else if ( ! NIL_P(rmethod) ) {
      ID id_method = SYM2ID(rmethod);
      rval = roffset;
      rb_ary_push(vtbl, ca_seq_cell(c, rval));
      for (k=1; k<len; k++) {
        rval = rb_funcall(rval, id_method, 0);
        rb_ary_push(vtbl, ca_seq_cell(c, rval));
      }
    }
    else {
      ID id_plus = rb_intern("+");
      rstep = ( NIL_P(rstep) ) ? INT2NUM(1) : rstep;
      rval = roffset;
      rb_ary_push(vtbl, ca_seq_cell(c, rval));
      for (k=1; k<len; k++) {
        rval = rb_funcall(rval, id_plus, 1, rstep);
        rb_ary_push(vtbl, ca_seq_cell(c, rval));
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

  /* Cleared last, so a fill that raises leaves the mask as it was. */
  if ( ca_has_mask(ca) ) {
    ca_clear_mask(ca);
  }
  return Qnil;
}

static VALUE
rb_ca_seq_bang_object (VALUE self, VALUE roffset, VALUE rstep, int axis)
{
  ca_seq_ctx_t c;

  TypedData_Get_Struct(self, CArray, &carray_data_type, c.ca);

  c.self    = self;
  c.rmethod = Qnil;
  if ( TYPE(rstep) == T_SYMBOL ) {                /* e.g. a.seq("a", :succ) */
    c.rmethod = rstep;
    rstep = Qnil;
  }
  c.roffset = roffset;
  c.rstep   = rstep;
  c.axis    = axis;

  ca_attach_window(1, &c.ca, "w", ca_seq_bang_object_body, (VALUE) &c);

  return self;
}

/* The numeric fill runs in an allocate window, which clears an entity's
   mask as it opens (an entity has no separate buffer), so nothing in it may
   raise: offset and step are checked to be numbers before it opens. */
static VALUE
ca_seq_bang_numeric_body (VALUE arg)
{
  ca_seq_ctx_t *c = (ca_seq_ctx_t *) arg;
  CArray *ca = c->ca;
  VALUE roffset = c->roffset, rstep = c->rstep;

  if ( ca_has_mask(ca) ) {
    ca_clear_mask(ca);              /* clear all mask */
  }

  if ( c->axis < 0 ) {
    seq_bang_switch(proc_seq_bang);
  }
  else {
    ca_size_t len, inner_size, outer_size;
    ca_seq_geometry(ca, c->axis, &len, &inner_size, &outer_size);
    seq_bang_switch(proc_seq_bang_axis);
  }
  return Qnil;
}

/* An integer array refuses a first value it cannot hold, as a store does,
   and an Integer step whose size it cannot hold.  An unsigned array takes
   a negative step (a descending run).  A run that passes the end of the
   type wraps, as integer arithmetic does. */
static void
ca_seq_check_integer_args (CArray *ca, VALUE roffset, VALUE rstep)
{
  int8_t dt = ca->data_type;
  /* Only a number is checked here; anything else is left to the fill's
     own conversion, which refuses it with TypeError. */
  if ( RB_INTEGER_TYPE_P(roffset) || RB_FLOAT_TYPE_P(roffset) ) {
    VALUE first = RB_INTEGER_TYPE_P(roffset) ? roffset : rb_Integer(roffset);
    if ( ca_integer_range_side(first, dt) != 0 ) {
      rb_raise(rb_eRangeError, "%s: first value %"PRIsVALUE" is out of range for %s",
               ca_calling_method_name(), rb_inspect(roffset), ca_type_name[dt]);
    }
  }
  if ( RB_INTEGER_TYPE_P(rstep) ) {
    int is_unsigned = ( dt == CA_UINT8  || dt == CA_UINT16 ||
                        dt == CA_UINT32 || dt == CA_UINT64 );
    VALUE size = rstep;
    if ( is_unsigned && RTEST(rb_funcall(rstep, rb_intern("negative?"), 0)) ) {
      size = rb_funcall(rstep, rb_intern("-@"), 0);
    }
    if ( ca_integer_range_side(size, dt) != 0 ) {
      rb_raise(rb_eRangeError, "%s: step %"PRIsVALUE" is out of range for %s",
               ca_calling_method_name(), rb_inspect(rstep), ca_type_name[dt]);
    }
  }
}

/* A real progression on an integer array: each cell takes offset + step*i
   cut toward zero, as a store takes a float, so the first and the last
   value (the extremes of a linear run) must fit the type, and NaN raises
   as it does in a store.  Checked before the fill writes anything. */
static void
ca_seq_check_real_run (CArray *ca, VALUE roffset, VALUE rstep, ca_size_t n)
{
  int8_t dt = ca->data_type;
  double offset = NIL_P(roffset) ? 0.0 : NUM2DBL(roffset);
  double step   = NIL_P(rstep)   ? 1.0 : NUM2DBL(rstep);
  double ends[2];
  double lo, hi_excl;
  int k;
  if ( n == 0 ) return;
  ends[0] = offset;
  ends[1] = step * (double) (n - 1) + offset;
  switch ( dt ) {
  case CA_INT8:   lo = INT8_MIN;  hi_excl = (double) INT8_MAX + 1;   break;
  case CA_UINT8:  lo = 0;         hi_excl = (double) UINT8_MAX + 1;  break;
  case CA_INT16:  lo = INT16_MIN; hi_excl = (double) INT16_MAX + 1;  break;
  case CA_UINT16: lo = 0;         hi_excl = (double) UINT16_MAX + 1; break;
  case CA_INT32:  lo = INT32_MIN; hi_excl = (double) INT32_MAX + 1;  break;
  case CA_UINT32: lo = 0;         hi_excl = (double) UINT32_MAX + 1; break;
  case CA_INT64:  lo = -ldexp(1.0, 63); hi_excl = ldexp(1.0, 63);    break;
  default:        lo = 0;         hi_excl = ldexp(1.0, 64);          break;
  }
  for (k = 0; k < 2; k++) {
    double t = trunc(ends[k]);
    if ( isnan(ends[k]) || ( step != 0.0 && isnan(step) ) ) {
      rb_raise(rb_eFloatDomainError, "%s: the run has NaN",
               ca_calling_method_name());
    }
    if ( ! ( t >= lo && t < hi_excl ) ) {
      rb_raise(rb_eRangeError, "%s: value %g is out of range for %s",
               ca_calling_method_name(), ends[k], ca_type_name[dt]);
    }
  }
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

  {
    VALUE args[2];
    const char *names[2] = { "offset", "step" };
    int k;
    args[0] = roffset;
    args[1] = rstep;
    for (k = 0; k < 2; k++) {
      VALUE v = args[k];
      if ( NIL_P(v) ) continue;
      if ( ! RTEST(rb_obj_is_kind_of(v, rb_cNumeric)) ||
           ( RB_TYPE_P(v, T_COMPLEX) && ! ca_is_complex_type(ca) ) ) {
        rb_raise(rb_eTypeError, "%s: %s must be a %snumber (got %"PRIsVALUE")",
                 ca_calling_method_name(), names[k],
                 ca_is_complex_type(ca) ? "" : "real ", rb_inspect(v));
      }
    }
  }

  if ( ca_is_integer_type(ca) ) {
    if ( ca_seq_is_real(roffset) || ca_seq_is_real(rstep) ) {
      ca_seq_check_real_run(ca, roffset, rstep,
                            axis < 0 ? ca->elements : ca->dim[axis]);
    }
    else {
      ca_seq_check_integer_args(ca, roffset, rstep);
    }
  }

  {
    ca_seq_ctx_t c;
    c.ca      = ca;
    c.roffset = roffset;
    c.rstep   = rstep;
    c.rmethod = Qnil;
    c.axis    = axis;
    ca_attach_window(1, &ca, "a", ca_seq_bang_numeric_body, (VALUE) &c);
  }

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



