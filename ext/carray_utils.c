/* ---------------------------------------------------------------------------

  Utility helpers shared across the `ext/` C files: iterator setup / loop count
  variadic helpers, Range parsing (`ca_parse_range` family), axis
  normalization primitives (`ca_normalize_axis*` + Ruby-facing
  `normalize_axis` / `normalize_axes`), and text-scan helpers
  (`_scan_float` / `_scan_int`) for the text I/O layer.

  YARD signatures live in yard-stubs/carray_utils.rb; this file
  carries implementation-only prose.

---------------------------------------------------------------------------- */

#include <stdarg.h>
#include "ruby.h"
#include "carray.h"

#include "ruby/st.h"

static ID id_begin, id_end, id_excl_end;
#define RANGE_BEG(r)  (rb_funcall(r, id_begin, 0))
#define RANGE_END(r)  (rb_funcall(r, id_end, 0))
#define RANGE_EXCL(r) (rb_funcall(r, id_excl_end, 0))

/* ------------------------------------------------------------------- */

void
ca_debug (void) {}

/* ------------------------------------------------------------------- */

ca_size_t
ca_set_iterator (int n, ...)
{
  CArray *ca;
  char   **p;
  ca_size_t *s;
  ca_size_t max = -1;
  int     all_scalar = 1;
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca = va_arg(args, CArray *);
    p  = va_arg(args, char **);
    s  = va_arg(args, ca_size_t *);
    *p = ca->ptr;
    if ( ca_is_scalar(ca) ) {
      *s = 0;
      all_scalar &= 1;
    }
    else {
      *s = 1;
      all_scalar = 0;
      if ( max < 0 ) {
        max = ca->elements;
      }
      else if ( max != ca->elements ) {
        rb_raise(rb_eRuntimeError, "data size mismatch in operation");
      }
    }
  }
  va_end(args);

  if ( all_scalar && max < 0 ) {
    max = 1;
  }

  return max;
}

/* ------------------------------------------------------------------- */

ca_size_t
ca_get_loop_count (int n, ...)
{
  CArray *ca;
  ca_size_t elements = -1;
  int32_t is_scalar = 1;
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca = va_arg(args, CArray*);
    if ( ca_is_scalar(ca) ) {
      continue;
    }
    is_scalar = 0;
    if ( elements == -1 || ca->elements < elements ) {
      elements = ca->elements;
    }
  }
  va_end(args);
  if ( elements == -1 && is_scalar ) {
    elements = 1;
  }

  if ( elements == -1 ) {
    rb_raise(rb_eRuntimeError, "no data to process");
  }
  return elements;
}

/*
  ca_parse_range and ca_parse_range_without_check parse the following
  types of range specifications

   i

   nil
   i..j

   [nil]
   [i..j]

   [nil, k]
   [i..j, k]

   [i]
   [i,n]
   [i,n,k]
*/

void
ca_parse_range (VALUE arg, ca_size_t size, 
                ca_size_t *poffset, ca_size_t *pcount, ca_size_t *pstep)
{
  ca_size_t start, last, count, step, bound, excl;

 retry:

  if ( NIL_P(arg) ) {                /* nil */
    *poffset = 0;
    *pcount  = size;
    *pstep   = 1;
  }
  else if ( rb_obj_is_kind_of(arg, rb_cInteger) ) {
                                     /* i */
    start = NUM2SIZE(arg);
    CA_CHECK_INDEX(start, size);
    *poffset = start;
    *pcount  = 1;
    *pstep   = 1;
  }
  else if ( rb_obj_is_kind_of(arg, rb_cRange) ) {
                                     /* i..j */
    start = NUM2SIZE(RANGE_BEG(arg));
    last  = NUM2SIZE(RANGE_END(arg));
    excl  = RTEST(RANGE_EXCL(arg));
    CA_CHECK_INDEX(start, size);
    if ( last < 0 ) {
      last += size;
    }
    if ( excl ) {
      last += ( (last>=start) ? -1 : 1 );
    }
    if ( last < 0 || last >= size ) {
      rb_raise(rb_eIndexError,
               "invalid index range");
    }
    *poffset = start;
    *pcount  = llabs(last - start) + 1;
    *pstep   = 1;
  }
#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
  else if ( rb_obj_is_kind_of(arg, rb_cArithSeq) ) { /* ca[--,ArithSeq,--]*/
    rb_arithmetic_sequence_components_t x;
    rb_arithmetic_sequence_extract(arg, &x);

    start = NUM2SIZE(x.begin);
    last  = NUM2SIZE(x.end);
    excl  = RTEST(x.exclude_end);
    step  = NUM2SIZE(x.step);
    if ( step == 0 ) {
      rb_raise(rb_eRuntimeError, "step should not be 0");
    }
    if ( last < 0 ) {
      last += size;
    }
    if ( excl ) {
      last += ( (last>=start) ? -1 : 1 );
    }
    if ( last < 0 || last >= size ) {
      rb_raise(rb_eIndexError, "index out of range");
    }
    CA_CHECK_INDEX(start, size);
    if ( (last - start) * step < 0 ) {
      count = 1;
    }
    else {
      count = llabs(last - start)/llabs(step) + 1;
    }
    bound = start + (count - 1)*step;
    CA_CHECK_INDEX(bound, size);
    *poffset = start;
    *pcount  = count;
    *pstep   = step;
  }
#endif
  else if ( TYPE(arg) == T_ARRAY ) {
    if ( RARRAY_LEN(arg) == 1 ) {     /* [nil] or [i..j] or [i] */
      arg = rb_ary_entry(arg, 0);
      goto retry;
    }
    else if ( RARRAY_LEN(arg) == 2 ) {
      VALUE arg0 = rb_ary_entry(arg, 0);
      VALUE arg1 = rb_ary_entry(arg, 1);
      if ( NIL_P(arg0) ) {              /* [nil,k] */
        step  = NUM2SIZE(arg1);
        if ( step == 0 ) {
          rb_raise(rb_eRuntimeError, "step should not be 0");
        }
        start = 0;
        count = (size-1)/llabs(step) + 1;
        bound = start + (count - 1)*step;
        CA_CHECK_INDEX(start, size);
        CA_CHECK_INDEX(bound, size);
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
      else if ( rb_obj_is_kind_of(arg0, rb_cRange) ) { /* [i..j,k] */
        start = NUM2SIZE(RANGE_BEG(arg0));
        last  = NUM2SIZE(RANGE_END(arg0));
        excl  = RTEST(RANGE_EXCL(arg0));
        step  = NUM2SIZE(arg1);
        if ( step == 0 ) {
          rb_raise(rb_eRuntimeError, "step should not be 0");
        }
        if ( last < 0 ) {
          last += size;
        }
        if ( excl ) {
          last += ( (last>=start) ? -1 : 1 );
        }
        if ( last < 0 || last >= size ) {
          rb_raise(rb_eIndexError, "index out of range");
        }
        CA_CHECK_INDEX(start, size);
        if ( (last - start) * step < 0 ) {
          count = 1;
        }
        else {
          count = llabs(last - start)/llabs(step) + 1;
        }
        bound = start + (count - 1)*step;
        CA_CHECK_INDEX(bound, size);
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
      else if ( rb_obj_is_kind_of(arg0, rb_cArithSeq) ) { /* ca[--,ArithSeq,--]*/
        rb_arithmetic_sequence_components_t x;
        rb_arithmetic_sequence_extract(arg0, &x);

        start = NUM2SIZE(x.begin);
        last  = NUM2SIZE(x.end);
        excl  = RTEST(x.exclude_end);
        step  = NUM2SIZE(x.step);
        if ( step == 0 ) {
          rb_raise(rb_eRuntimeError, "step should not be 0");
        }
        if ( last < 0 ) {
          last += size;
        }
        if ( excl ) {
          last += ( (last>=start) ? -1 : 1 );
        }
        if ( last < 0 || last >= size ) {
          rb_raise(rb_eIndexError, "index out of range");
        }
        CA_CHECK_INDEX(start, size);
        if ( (last - start) * step < 0 ) {
          count = 1;
        }
        else {
          count = llabs(last - start)/llabs(step) + 1;
        }
        bound = start + (count - 1)*step;
        CA_CHECK_INDEX(bound, size);
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
#endif      
      else {                            /* [i,n] */
        start = NUM2SIZE(arg0);
        count = NUM2SIZE(arg1);
        bound = start + (count - 1);
        CA_CHECK_INDEX(start, size);
        CA_CHECK_INDEX(bound, size);
        *poffset = start;
        *pcount  = count;
        *pstep    = 1;
      }
    }
    else if ( RARRAY_LEN(arg) == 3 ) { /* [i,n,k] */
      start = NUM2SIZE(rb_ary_entry(arg, 0));
      count = NUM2SIZE(rb_ary_entry(arg, 1));
      step  = NUM2SIZE(rb_ary_entry(arg, 2));
      if ( step == 0 ) {
        rb_raise(rb_eRuntimeError, "step should not be 0");
      }
      bound = start + (count - 1)*step;
      CA_CHECK_INDEX(start, size);
      CA_CHECK_INDEX(bound, size);
      *poffset = start;
      *pcount  = count;
      *pstep   = step;
    }
    else {
      rb_raise(rb_eRuntimeError, "unknown range specification");
    }
  }
  else {
    rb_raise(rb_eRuntimeError, "unknown range specification");
  }
}

void
ca_parse_range_without_check (VALUE arg, ca_size_t size,
                              ca_size_t *poffset, ca_size_t *pcount, ca_size_t *pstep)
{
  ca_size_t start, last, count, step, excl;

 retry:

  if ( NIL_P(arg) ) {                /* nil */
    *poffset = 0;
    *pcount  = size;
    *pstep   = 1;
  }
  else if ( rb_obj_is_kind_of(arg, rb_cInteger) ) {
                                     /* i */
    start = NUM2SIZE(arg);
    *poffset = start;
    *pcount  = 1;
    *pstep   = 1;
  }
  else if ( rb_obj_is_kind_of(arg, rb_cRange) ) {
                                     /* i..j */
    start = NUM2SIZE(RANGE_BEG(arg));
    last  = NUM2SIZE(RANGE_END(arg));
    excl  = RTEST(RANGE_EXCL(arg));
    if ( excl ) {
      last += ( (last>=start) ? -1 : 1 );
    }
    *poffset = start;
    *pcount  = last - start + 1;
    *pstep   = 1;
  }
#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
  else if ( rb_obj_is_kind_of(arg, rb_cArithSeq) ) { /* ca[--,ArithSeq,--]*/
    rb_arithmetic_sequence_components_t x;
    rb_arithmetic_sequence_extract(arg, &x);

    start = NUM2SIZE(x.begin);
    last  = NUM2SIZE(x.end);
    excl  = RTEST(x.exclude_end);
    step  = NUM2SIZE(x.step);
    if ( excl ) {
      last += ( (last>=start) ? -1 : 1 );
    }
    count = (last - start)/llabs(step) + 1;
    *poffset = start;
    *pcount  = count;
    *pstep   = step;
  }
#endif
  else if ( TYPE(arg) == T_ARRAY ) {
    if ( RARRAY_LEN(arg) == 1 ) {   /* [nil] or [i..j] or [i] */
      arg = rb_ary_entry(arg, 0);
      goto retry;
    }
    else if ( RARRAY_LEN(arg) == 2 ) {
      VALUE arg0 = rb_ary_entry(arg, 0);
      VALUE arg1 = rb_ary_entry(arg, 1);
      if ( NIL_P(arg0) ) {              /* [nil,k] */
        start = 0;
        step  = NUM2SIZE(arg1);
        count = (size-1)/llabs(step) + 1;
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
      else if ( rb_obj_is_kind_of(arg0, rb_cRange) ) { /* [i..j,k] */
        start = NUM2SIZE(RANGE_BEG(arg0));
        last  = NUM2SIZE(RANGE_END(arg0));
        excl  = RTEST(RANGE_EXCL(arg0));
        step  = NUM2SIZE(arg1);
        if ( excl ) {
          last += ( (last>=start) ? -1 : 1 );
        }
        count = (last - start)/llabs(step) + 1;
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
      else if ( rb_obj_is_kind_of(arg0, rb_cArithSeq) ) { /* ca[--,ArithSeq,--]*/
        rb_arithmetic_sequence_components_t x;
        rb_arithmetic_sequence_extract(arg0, &x);

        start = NUM2SIZE(x.begin);
        last  = NUM2SIZE(x.end);
        excl  = RTEST(x.exclude_end);
        step  = NUM2SIZE(x.step);
        if ( excl ) {
          last += ( (last>=start) ? -1 : 1 );
        }
        count = (last - start)/llabs(step) + 1;
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
#endif
      else {                            /* [i,n] */
        start = NUM2SIZE(arg0);
        count = NUM2SIZE(arg1);
        *poffset = start;
        *pcount  = count;
        *pstep    = 1;
      }
    }
    else if ( RARRAY_LEN(arg) == 3 ) { /* [i,n,k] */
      start = NUM2SIZE(rb_ary_entry(arg, 0));
      count = NUM2SIZE(rb_ary_entry(arg, 1));
      step  = NUM2SIZE(rb_ary_entry(arg, 2));
      *poffset = start;
      *pcount  = count;
      *pstep   = step;
    }
    else {
      rb_raise(rb_eRuntimeError, "unknown range specification");
    }
  }
  else {
    rb_raise(rb_eRuntimeError, "unknown range specification");
  }
}

ca_size_t
ca_bounds_normalize_index (int8_t bounds, ca_size_t size0, ca_size_t k)
{
  switch ( bounds ) {
  case CA_BOUNDS_MASK:
  case CA_BOUNDS_FILL:
    return k;
  case CA_BOUNDS_PERIODIC:
    if ( k >= 0 ) {
      return k % size0;
    }
    else {
      k = (-k) % size0;
      return ( ! k ) ? 0 : size0 - k;
    }
  case CA_BOUNDS_RUBY:
    if ( k < 0 ) {
      k += size0;
    }
    if ( k < 0 || k >= size0 ) {
      rb_raise(rb_eRuntimeError,
               "window index out of range");
    }
    return k;
  case CA_BOUNDS_STRICT:
    if ( k < 0 || k >= size0 ) {
      rb_raise(rb_eRuntimeError,
               "window index out of range");
    }
    return k;
  case CA_BOUNDS_NEAREST:
    return ( k < 0 ) ? 0 : ( k >= size0 ) ? size0 - 1 : k;
  case CA_BOUNDS_REFLECT:
    if ( k < 0 ) {
      k = -k - 1;
    }
    k = k % (2*size0);
    return ( k < size0 ) ? k : 2*size0-1-k;
  default:
    rb_raise(rb_eRuntimeError,
             "unknown window boundary specified (%i)", bounds);
  }
}

/* Self-independent kernel: normalize `raw` against `ndim`, returning a
   canonical non-negative axis in [0, ndim) as int.  Accepts negative
   values (Python/Ruby convention: -1 => ndim-1).  Raises ArgumentError
   if out of range.  `name` is used in the error message (e.g.
   "mask_duplicates", "sum", "merge"); pass NULL to default to "axis".

   For an insertion position (= valid range [0, old_ndim] inclusive),
   pass `old_ndim + 1` as `ndim` so the half-open [0, ndim) check
   matches the inclusive [0, old_ndim] semantics. */
int
rb_ca_normalize_axis_for_ndim (long raw, int ndim, const char *name)
{
  long axis = (raw < 0) ? raw + ndim : raw;
  if ( axis < 0 || axis >= ndim ) {
    rb_raise(rb_eArgError,
             "%s: axis %ld out of range for ndim %d",
             name ? name : "axis", raw, ndim);
  }
  return (int) axis;
}

/* Self-bound wrapper: delegate to the kernel using self.ndim.  Kept
   for backward compatibility with the existing instance method
   `CArray#normalize_axis`. */
int
rb_ca_normalize_axis_value (VALUE self, VALUE raxis, const char *name)
{
  CArray *ca;
  GetCArray(self, ca);
  return rb_ca_normalize_axis_for_ndim(NUM2LONG(raxis), (int) ca->ndim, name);
}

/* Ruby-facing `CArray#normalize_axis(axis, name=nil)` — returns the
 * canonical non-negative axis index in [0, ndim) for `self`. Accepts
 * negative `axis` interpreted as (ndim + axis). Raises ArgumentError
 * on out-of-range input; `name` (if given) is embedded in the
 * message. */
static VALUE
rb_ca_normalize_axis (int argc, VALUE *argv, VALUE self)
{
  VALUE raxis, rname;
  const char *name;
  int k;
  rb_scan_args(argc, argv, "11", &raxis, &rname);
  name = NIL_P(rname) ? NULL : StringValueCStr(rname);
  k = rb_ca_normalize_axis_value(self, raxis, name);
  return INT2NUM(k);
}

/* Class-method form `CArray.normalize_axis(axis, ndim, name=nil)` —
 * normalizes `axis` against an explicit `ndim` (range [0, ndim))
 * without needing a CArray instance. For an insertion position
 * (valid range [0, old_ndim] inclusive), pass `old_ndim + 1` as
 * `ndim`. Called from class-method contexts (e.g. `CArray.stack`
 * normalizing before `list[0]` is available) and from
 * lib/carray/compose.rb merge / composite paths. */
static VALUE
rb_ca_s_normalize_axis (int argc, VALUE *argv, VALUE klass)
{
  VALUE raxis, rndim, rname;
  const char *name;
  int k;
  rb_scan_args(argc, argv, "21", &raxis, &rndim, &rname);
  name = NIL_P(rname) ? NULL : StringValueCStr(rname);
  k = rb_ca_normalize_axis_for_ndim(NUM2LONG(raxis), NUM2INT(rndim), name);
  return INT2NUM(k);
}

/* Ruby-facing `CArray#normalize_axes(axes, name=nil)` — normalizes a
 * multi-axis specifier to an Array<Integer> of canonical axes in
 * [0, ndim), preserving input order. Accepts nil (returns the full
 * axis list [0..ndim-1]), a single Integer (returns [k] after
 * normalization), or an Array<Integer> (each element normalized).
 * Raises on out-of-range or duplicate axes. */
static VALUE
rb_ca_normalize_axes (int argc, VALUE *argv, VALUE self)
{
  VALUE raxes, rname, out;
  CArray *ca;
  int8_t axes_buf[CA_RANK_MAX];
  int8_t naxes, i;
  const char *name;

  rb_scan_args(argc, argv, "11", &raxes, &rname);
  name = NIL_P(rname) ? "axes" : StringValueCStr(rname);
  GetCArray(self, ca);

  if ( NIL_P(raxes) ) {
    out = rb_ary_new_capa(ca->ndim);
    for ( i = 0; i < ca->ndim; i++ ) {
      rb_ary_push(out, INT2NUM(i));
    }
    return out;
  }

  naxes = rb_ca_parse_reduce_axes_kw_ctx(raxes, ca, axes_buf, name);
  out = rb_ary_new_capa(naxes);
  for ( i = 0; i < naxes; i++ ) {
    rb_ary_push(out, INT2NUM(axes_buf[i]));
  }
  return out;
}

/* `CArray._scan_float(str, fill_value=nil)` — parses `str` as a
 * single double via `sscanf("%lf")`. Returns `fill_value` (or NaN
 * when `fill_value` is nil) if `str` is nil or unparseable. Internal
 * helper for text-format I/O readers. */

static VALUE
rb_ca_s_scan_float (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rstr, rfval;
  double value;
  int count;

  rb_scan_args(argc, argv, "11", (VALUE *)&rstr, (VALUE *)&rfval);

  if ( NIL_P(rstr) ) {
    return ( NIL_P(rfval) ) ? rb_float_new(0.0/0.0) : rfval;
  }

  Check_Type(rstr, T_STRING);

  count = sscanf(StringValuePtr(rstr), "%lf", &value);

  if ( count == 1 ) {
    return rb_float_new(value);
  }
  else {
    return ( NIL_P(rfval) ) ? rb_float_new(0.0/0.0) : rfval;
  }
}

/* `CArray._scan_int(str, fill_value=nil)` — parses `str` as a single
 * integer via `sscanf("%li")` (accepts `0x`, `0`, and decimal
 * prefixes). Returns `fill_value` (or 0 when `fill_value` is nil) if
 * `str` is nil or unparseable. Internal helper for text-format I/O
 * readers. */

static VALUE
rb_ca_s_scan_int (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rstr, rfval;
  long value;
  int count;

  rb_scan_args(argc, argv, "11", (VALUE *) &rstr, (VALUE *) &rfval);

  if ( NIL_P(rstr) ) {
    return ( NIL_P(rfval) ) ? INT2NUM(0) : rfval;
  }

  Check_Type(rstr, T_STRING);

  count = sscanf(StringValuePtr(rstr), "%li", &value);

  if ( count == 1 ) {
    return SIZE2NUM(value);
  }
  else {
    return ( NIL_P(rfval) ) ? INT2NUM(0) : rfval;
  }
}

static const struct {
  const char *name;
  int  data_type;
} ca_name_to_type[] = {
  { "fixlen", CA_FIXLEN },
  { "boolean", CA_BOOLEAN },
  { "int8", CA_INT8 },
  { "uint8", CA_UINT8 },
  { "int16", CA_INT16 },
  { "uint16", CA_UINT16 },
  { "int32", CA_INT32 },
  { "uint32", CA_UINT32 },
  { "int64", CA_INT64 },
  { "uint64", CA_UINT64 },
  { "float32", CA_FLOAT32 },
  { "float64", CA_FLOAT64 },
  { "float128", CA_FLOAT128 }, /* reserved (retired in 3.0); ca_valid[12]=0 */
  { "cmplx64", CA_CMPLX64 },
  { "cmplx128", CA_CMPLX128 },
  { "cmplx256", CA_CMPLX256 }, /* reserved (retired in 3.0); ca_valid[15]=0 */
  { "object", CA_OBJECT },
  { "byte", CA_UINT8 },
  { "short", CA_INT16 },
  { "int", CA_INT32 },
  { "float", CA_FLOAT32 },
  { "double", CA_FLOAT64 },
  { "complex", CA_CMPLX64 },
  { "dcomplex", CA_CMPLX128 },
  { NULL, CA_NONE },
};



int8_t
rb_ca_guess_type (VALUE obj)
{
  VALUE inspect;

  if ( TYPE(obj) == T_FIXNUM ) {
    return NUM2SIZE(obj);
  }
  else if ( TYPE(obj) == T_STRING ) {
    const char *name0;
    char *name = StringValuePtr(obj);
    int i;
    i = 0;
    while ( ( name0 = ca_name_to_type[i].name ) ) {
      name0 = ca_name_to_type[i].name;
      if ( ! strncmp(name, name0, strlen(name0)) ) {
        return ca_name_to_type[i].data_type;
      }
      i++;
    }
  }
  else if ( TYPE(obj) == T_SYMBOL ) {
    return rb_ca_guess_type(rb_str_new2(rb_id2name(SYM2ID(obj))));
  }
  else if ( TYPE(obj) == T_CLASS ) {
    ca_check_data_class(obj);
    return CA_FIXLEN;
  }

  inspect = rb_inspect(obj);
  rb_raise(rb_eRuntimeError,
           "<%s> is unknown data_type representation", StringValuePtr(inspect));
}

void
rb_ca_guess_type_and_bytes (VALUE rtype, VALUE rbytes,
                            int8_t *data_type, ca_size_t *bytes)
{
  *data_type = rb_ca_guess_type(rtype);

  if ( *data_type == CA_FIXLEN ) {
    if ( TYPE(rtype) == T_CLASS ) {
      *bytes = NUM2SIZE(rb_const_get(rtype, rb_intern("DATA_SIZE")));
    }
    else {
      if ( NIL_P(rbytes) ) {
        *bytes = 0;
      }
      else {
        *bytes = NUM2SIZE(rbytes);
      }
    }
  }
  else {
    CA_CHECK_DATA_TYPE(*data_type);
    *bytes = ca_sizeof[*data_type];
  }
}

/* @private
  def CArray.guess_type_and_bytes (type, bytes=0)
  end
*/

static VALUE
rb_ca_s_guess_type_and_bytes (int argc, VALUE *argv, VALUE klass)
{
  VALUE rtype, rbytes;
  int8_t data_type;
  ca_size_t bytes;
  rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &rbytes);
  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
  return rb_assoc_new(INT2NUM(data_type), SIZE2NUM(bytes));
}

VALUE
rb_pop_options (int *argc, VALUE **argv)
{
  VALUE ropt;
  if ( ( *argc > 0 ) && ( TYPE( (*argv)[*argc-1] ) == T_HASH ) ) {
    ropt = (*argv)[*argc-1];
    (*argc) -= 1;
  }
  else {
    ropt = Qnil;
  }
  return ropt;
}


char *
strsep1(char **sp, const char sep)
{
  char *p  = *sp;
  char *p0 = *sp;

  if ( p == NULL ) {
    return NULL;
  }

  while ( *p != '\0' ) {
    if ( *p == sep ) {
      *p  = '\0';
      *sp = p+1;
      return p0;
    }
    else {
      p++;
    }
  }

  *sp = NULL;
  return p0;
}

static VALUE
rb_hash_has_key(VALUE hash, VALUE key)
{
  if ( RHASH_EMPTY_P(hash) ) {
    return Qfalse;
  }
  if (st_lookup(RHASH_TBL(hash), key, 0)) {
    return Qtrue;
  }
  return Qfalse;
}

void
rb_scan_options (VALUE ropt, const char *spec_in, ...)
{
  VALUE *vp;
  char *sp, *tok, *spec;
  int has_option = 0;
  va_list vals;

  if ( TYPE(ropt) == T_HASH ) {
    has_option = 1;
  }
  else if ( ! NIL_P(ropt) ) {
    VALUE inspect = rb_inspect(ropt);
    rb_raise(rb_eArgError,
             "<%s> is invalid option specifier",
             StringValuePtr(inspect));
  }

  va_start(vals, spec_in);
  sp = spec = strdup(spec_in);
  tok = strsep1(&sp, ',');
  while ( tok != NULL ) {
    vp = va_arg(vals, VALUE*);
    if ( has_option ) {
      VALUE key = ID2SYM(rb_intern(tok));
      if ( rb_hash_has_key(ropt, key) ) {
        *vp = rb_hash_aref(ropt, key);
      }
      /* key absent: leave *vp unchanged (caller's pre-initialized default) */
    }
    /* opts == Qnil: leave all *vp unchanged */
    tok = strsep1(&sp, ',');
  }
  va_end(vals);
  free(spec);

  /* Strict: reject any key not named in spec, matching Ruby's native
     keyword-argument behaviour ("unknown keyword: :foo").  Every call
     site scans all of a method's accepted keys in a single call, so a
     leftover key is genuinely unrecognised. */
  if ( has_option && ! RHASH_EMPTY_P(ropt) ) {
    VALUE keys = rb_funcall(ropt, rb_intern("keys"), 0);
    long i, n = RARRAY_LEN(keys);
    for ( i = 0; i < n; i++ ) {
      VALUE key = rb_ary_entry(keys, i);
      VALUE kname = SYMBOL_P(key) ? rb_sym2str(key) : rb_obj_as_string(key);
      const char *kn = StringValueCStr(kname);
      char *sp2, *tok2, *spec2;
      int found = 0;
      sp2 = spec2 = strdup(spec_in);
      tok2 = strsep1(&sp2, ',');
      while ( tok2 != NULL ) {
        if ( strcmp(tok2, kn) == 0 ) { found = 1; break; }
        tok2 = strsep1(&sp2, ',');
      }
      free(spec2);
      if ( ! found ) {
        rb_raise(rb_eArgError, "unknown keyword: %"PRIsVALUE, rb_inspect(key));
      }
    }
  }

  return;
}

/* For methods that take no keyword arguments at all.  ropt is the trailing
   Hash from rb_pop_options / rb_scan_args "*:", or Qnil when there is none.
   Raises the same message Ruby raises for an unrecognised keyword
   ("unknown keyword: :axis"), so a keyword passed to a positional-only
   method does not surface as a TypeError from NUM2SIZE or as an
   argument-count mismatch. */
void
rb_reject_options (VALUE ropt)
{
  /* Table of accepted keys, empty.  rb_get_kwargs declares it non-null and
     reads required + optional (= 0) entries, so a one-slot dummy is enough. */
  static const ID accepts_none[1] = { 0 };

  if ( NIL_P(ropt) ) {
    return;
  }
  rb_get_kwargs(ropt, accepts_none, 0, 0, NULL);
}

void
rb_set_options (VALUE ropt, const char *spec_in, ...)
{
  VALUE rval;
  char *sp, *tok, *spec;
  int has_option = 0;
  va_list vals;

  if ( TYPE(ropt) == T_HASH ) {
    has_option = 1;
  }
  else if ( ! NIL_P(ropt) ) {
    VALUE inspect = rb_inspect(ropt);
    rb_raise(rb_eArgError,
             "<%s> is invalid option specifier",
             StringValuePtr(inspect));
  }

  va_start(vals, spec_in);
  sp = spec = strdup(spec_in);
  tok = strsep1(&sp, ',');
  while ( tok != NULL ) {
    rval = va_arg(vals, VALUE);
    if ( has_option ) {
      rb_hash_aset(ropt, ID2SYM(rb_intern(tok)), rval);
    }
    tok = strsep1(&sp, ',');
  }
  va_end(vals);
  free(spec);

  return;
}


void
Init_carray_utils (void)
{
  id_begin    = rb_intern("begin");
  id_end      = rb_intern("end");
  id_excl_end = rb_intern("exclude_end?");

  rb_define_singleton_method(rb_cCArray, "_scan_float",
           rb_ca_s_scan_float, -1);
  rb_define_singleton_method(rb_cCArray, "_scan_int",
           rb_ca_s_scan_int, -1);

  rb_define_singleton_method(rb_cCArray, "guess_type_and_bytes",
                             rb_ca_s_guess_type_and_bytes, -1);

  rb_define_method(rb_cCArray, "normalize_axis", rb_ca_normalize_axis, -1);
  rb_define_method(rb_cCArray, "normalize_axes", rb_ca_normalize_axes, -1);
  rb_define_singleton_method(rb_cCArray, "normalize_axis",
                             rb_ca_s_normalize_axis, -1);

}

