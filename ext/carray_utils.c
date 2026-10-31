/* ---------------------------------------------------------------------------

  Utility helpers shared across the `ext/` C files: iterator setup / loop count
  variadic helpers, Range parsing (`ca_parse_range` family), axis
  normalization primitives (`ca_normalize_axis*` + Ruby-facing
  `normalize_axis` / `normalize_axes`).

  YARD signatures live in yard-stubs/carray_utils.rb; this file
  carries implementation-only prose.

---------------------------------------------------------------------------- */

#include <stdarg.h>
#include "ruby.h"
#include "carray.h"
#include "carray_internal.h"   /* ca_calling_method_name */

#include "ruby/st.h"
#include "ruby/thread_native.h"
#include "ruby/ractor.h"
#include "ruby/debug.h"     /* rb_profile_frames: the method the user called */

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
        rb_raise(rb_eArgError, "%s: data size mismatch in operation",
                 ca_calling_method_name());
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
    rb_raise(rb_eArgError, "no data to process");
  }
  return elements;
}

/* A bound of a range that is not a key of `[]`: a window or a bit range says
   how many cells, so a Float is refused rather than cut down. */
static ca_size_t
ca_range_bound (VALUE v)
{
  return ca_integer_arg(v, "a range bound", NULL);
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
    start = ca_range_bound(arg);
    CA_CHECK_INDEX(start, size);
    *poffset = start;
    *pcount  = 1;
    *pstep   = 1;
  }
  else if ( rb_obj_is_kind_of(arg, rb_cRange) ) {
                                     /* i..j */
    start = ca_range_bound(RANGE_BEG(arg));
    last  = ca_range_bound(RANGE_END(arg));
    excl  = RTEST(RANGE_EXCL(arg));
    CA_CHECK_INDEX(start, size);
    if ( last < 0 ) {
      last += size;
    }
    if ( excl ) {
      last += ( (last>=start) ? -1 : 1 );
    }
    if ( last < 0 || last >= size ) {
      ca_index_out_of_range(last, size, "index");
    }
    *poffset = start;
    *pcount  = llabs(last - start) + 1;
    *pstep   = ( last >= start ) ? 1 : -1;
  }
#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
  else if ( rb_obj_is_kind_of(arg, rb_cArithSeq) ) { /* ca[--,ArithSeq,--]*/
    rb_arithmetic_sequence_components_t x;
    rb_arithmetic_sequence_extract(arg, &x);

    start = ca_range_bound(x.begin);
    last  = ca_range_bound(x.end);
    excl  = RTEST(x.exclude_end);
    step  = ca_range_bound(x.step);
    if ( step == 0 ) {
      rb_raise(rb_eArgError, "step should not be 0");
    }
    CA_CHECK_INDEX(start, size);
    if ( last < 0 ) {
      last += size;
    }
    if ( excl ) {
      last += ( (last>=start) ? -1 : 1 );
    }
    if ( last < 0 || last >= size ) {
      ca_index_out_of_range(last, size, "index");
    }
    if ( (last - start) * step < 0 ) {
      count = 1;
    }
    else {
      count = llabs(last - start)/llabs(step) + 1;
    }
    bound = start + (count - 1)*step;
    if ( count > 0 && ( bound < 0 || bound >= size ) ) {
      ca_index_out_of_range(bound, size, "index");
    }
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
        step  = ca_range_bound(arg1);
        if ( step == 0 ) {
          rb_raise(rb_eArgError, "step should not be 0");
        }
        start = 0;
        count = (size-1)/llabs(step) + 1;
        bound = start + (count - 1)*step;
        if ( count > 0 && ( bound < 0 || bound >= size ) ) {
          ca_index_out_of_range(bound, size, "index");
        }
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
      else if ( rb_obj_is_kind_of(arg0, rb_cRange) ) { /* [i..j,k] */
        start = ca_range_bound(RANGE_BEG(arg0));
        last  = ca_range_bound(RANGE_END(arg0));
        excl  = RTEST(RANGE_EXCL(arg0));
        step  = ca_range_bound(arg1);
        if ( step == 0 ) {
          rb_raise(rb_eArgError, "step should not be 0");
        }
        CA_CHECK_INDEX(start, size);
        if ( last < 0 ) {
          last += size;
        }
        if ( excl ) {
          last += ( (last>=start) ? -1 : 1 );
        }
        if ( last < 0 || last >= size ) {
          ca_index_out_of_range(last, size, "index");
        }
        if ( (last - start) * step < 0 ) {
          count = 1;
        }
        else {
          count = llabs(last - start)/llabs(step) + 1;
        }
        bound = start + (count - 1)*step;
        if ( count > 0 && ( bound < 0 || bound >= size ) ) {
          ca_index_out_of_range(bound, size, "index");
        }
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
      else if ( rb_obj_is_kind_of(arg0, rb_cArithSeq) ) { /* ca[--,ArithSeq,--]*/
        rb_arithmetic_sequence_components_t x;
        rb_arithmetic_sequence_extract(arg0, &x);

        start = ca_range_bound(x.begin);
        last  = ca_range_bound(x.end);
        excl  = RTEST(x.exclude_end);
        step  = ca_range_bound(x.step);
        if ( step == 0 ) {
          rb_raise(rb_eArgError, "step should not be 0");
        }
        CA_CHECK_INDEX(start, size);
        if ( last < 0 ) {
          last += size;
        }
        if ( excl ) {
          last += ( (last>=start) ? -1 : 1 );
        }
        if ( last < 0 || last >= size ) {
          ca_index_out_of_range(last, size, "index");
        }
        if ( (last - start) * step < 0 ) {
          count = 1;
        }
        else {
          count = llabs(last - start)/llabs(step) + 1;
        }
        bound = start + (count - 1)*step;
        if ( count > 0 && ( bound < 0 || bound >= size ) ) {
          ca_index_out_of_range(bound, size, "index");
        }
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
#endif      
      else {                            /* [i,n] */
        start = ca_range_bound(arg0);
        count = ca_range_bound(arg1);
        CA_CHECK_INDEX(start, size);
        bound = start + (count - 1);
        if ( count > 0 && ( bound < 0 || bound >= size ) ) {
          ca_index_out_of_range(bound, size, "index");
        }
        *poffset = start;
        *pcount  = count;
        *pstep    = 1;
      }
    }
    else if ( RARRAY_LEN(arg) == 3 ) { /* [i,n,k] */
      start = ca_range_bound(rb_ary_entry(arg, 0));
      count = ca_range_bound(rb_ary_entry(arg, 1));
      step  = ca_range_bound(rb_ary_entry(arg, 2));
      if ( step == 0 ) {
        rb_raise(rb_eArgError, "step should not be 0");
      }
      CA_CHECK_INDEX(start, size);
      bound = start + (count - 1)*step;
      if ( count > 0 && ( bound < 0 || bound >= size ) ) {
        ca_index_out_of_range(bound, size, "index");
      }
      *poffset = start;
      *pcount  = count;
      *pstep   = step;
    }
    else {
      rb_raise(rb_eArgError, "unknown range specification");
    }
  }
  else {
    rb_raise(rb_eArgError, "unknown range specification");
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
    start = ca_range_bound(arg);
    *poffset = start;
    *pcount  = 1;
    *pstep   = 1;
  }
  else if ( rb_obj_is_kind_of(arg, rb_cRange) ) {
                                     /* i..j */
    start = ca_range_bound(RANGE_BEG(arg));
    last  = ca_range_bound(RANGE_END(arg));
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

    start = ca_range_bound(x.begin);
    last  = ca_range_bound(x.end);
    excl  = RTEST(x.exclude_end);
    step  = ca_range_bound(x.step);
    if ( step == 0 ) {
      rb_raise(rb_eArgError, "%s: step should not be 0",
               ca_calling_method_name());
    }
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
        step  = ca_range_bound(arg1);
        if ( step == 0 ) {
          rb_raise(rb_eArgError, "%s: step should not be 0",
                   ca_calling_method_name());
        }
        count = (size-1)/llabs(step) + 1;
        *poffset = start;
        *pcount  = count;
        *pstep   = step;
      }
      else if ( rb_obj_is_kind_of(arg0, rb_cRange) ) { /* [i..j,k] */
        start = ca_range_bound(RANGE_BEG(arg0));
        last  = ca_range_bound(RANGE_END(arg0));
        excl  = RTEST(RANGE_EXCL(arg0));
        step  = ca_range_bound(arg1);
        if ( step == 0 ) {
          rb_raise(rb_eArgError, "%s: step should not be 0",
                   ca_calling_method_name());
        }
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

        start = ca_range_bound(x.begin);
        last  = ca_range_bound(x.end);
        excl  = RTEST(x.exclude_end);
        step  = ca_range_bound(x.step);
        if ( step == 0 ) {
          rb_raise(rb_eArgError, "%s: step should not be 0",
                   ca_calling_method_name());
        }
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
        start = ca_range_bound(arg0);
        count = ca_range_bound(arg1);
        *poffset = start;
        *pcount  = count;
        *pstep    = 1;
      }
    }
    else if ( RARRAY_LEN(arg) == 3 ) { /* [i,n,k] */
      start = ca_range_bound(rb_ary_entry(arg, 0));
      count = ca_range_bound(rb_ary_entry(arg, 1));
      step  = ca_range_bound(rb_ary_entry(arg, 2));
      *poffset = start;
      *pcount  = count;
      *pstep   = step;
    }
    else {
      rb_raise(rb_eArgError, "unknown range specification");
    }
  }
  else {
    rb_raise(rb_eArgError, "unknown range specification");
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
      ca_index_out_of_range(k, size0, "index");
    }
    return k;
  case CA_BOUNDS_STRICT:
    if ( k < 0 || k >= size0 ) {
      ca_index_out_of_range(k, size0, "index");
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
    rb_raise(rb_eArgError,
             "unknown window boundary specified (%i)", bounds);
  }
}

/* The name of the method the user called, for error messages.  A C
   entry reached directly from C (no rb_funcall) reports the method that
   was entered from Ruby, which is the one the user wrote.  The internal
   `_ki` twin of a public method is reported under the public name.
   Falls back to "axis" when there is no method frame. */
/* A C copy of an ID's name that stays put.  rb_id2name points into the
   name's String, which compaction can move while a caller is still
   formatting a message with it; the copy is made once per ID while the
   String is held on the stack (and so pinned), and kept for the life of
   the process.  The table is shared by every Ractor, hence the lock. */
static st_table              *ca_id_names = NULL;
static rb_nativethread_lock_t ca_id_names_lock;

static const char *
ca_stable_id_name (ID id)
{
  st_data_t   found;
  const char *name = NULL;
  rb_nativethread_lock_lock(&ca_id_names_lock);
  if ( st_lookup(ca_id_names, (st_data_t) id, &found) ) {
    name = (const char *) found;
  }
  rb_nativethread_lock_unlock(&ca_id_names_lock);
  if ( name ) {
    return name;
  }
  {
    VALUE  str = rb_id2str(id);
    long   len;
    char  *copy;
    if ( NIL_P(str) ) {
      return NULL;
    }
    len  = RSTRING_LEN(str);
    copy = ALLOC_N(char, len + 1);
    memcpy(copy, RSTRING_PTR(str), len);
    copy[len] = '\0';
    RB_GC_GUARD(str);
    rb_nativethread_lock_lock(&ca_id_names_lock);
    if ( st_lookup(ca_id_names, (st_data_t) id, &found) ) {
      xfree(copy);
      name = (const char *) found;
    }
    else {
      st_insert(ca_id_names, (st_data_t) id, (st_data_t) copy);
      name = copy;
    }
    rb_nativethread_lock_unlock(&ca_id_names_lock);
    return name;
  }
}

/* The method a delegating method answers for.  A method that does its work
   by calling others (median calls partition_index, mode calls sort) runs
   them under ca_answer_as_caller, so an error they raise names the method
   the user called.  The outermost one wins.  The name is kept with the
   Ruby thread (Thread#[], so per fiber): Ractors share native threads under
   the M:N scheduler, and a native-thread-local variable leaks one Ractor's
   name into another's message. */
static ID id_answering;

static const char *
ca_answering_name (void)
{
  VALUE name = rb_thread_local_aref(rb_thread_current(), id_answering);
  return NIL_P(name) ? NULL : ca_stable_id_name(SYM2ID(name));
}

static void
ca_set_answering_name (const char *name)
{
  rb_thread_local_aset(rb_thread_current(), id_answering,
                       name ? ID2SYM(rb_intern(name)) : Qnil);
}

static VALUE
ca_answer_restore (VALUE unused)
{
  ca_set_answering_name(NULL);
  return Qnil;
}

/* A C method that does its work by calling others runs them through here.
   It used to fix the name at entry; the name is now found from the frames
   when an error is raised (ca_user_called_method_id), which also reaches
   the outer method, so nothing is fixed and nothing is paid on the way in. */
VALUE
ca_answer_as_caller (VALUE (*body)(VALUE), VALUE arg)
{
  return body(arg);
}

/* CArray.__name_errors_after_method__(name) { ... }: the same for a method written in Ruby. */
static VALUE
rb_ca_s_answer_as_body (VALUE unused)
{
  return rb_yield(Qnil);
}

static VALUE
rb_ca_s_answer_as (VALUE klass, VALUE name)
{
  if ( ca_answering_name() ) {
    return rb_yield(Qnil);
  }
  ca_set_answering_name(ca_stable_id_name(rb_to_id(name)));
  return rb_ensure(rb_ca_s_answer_as_body, Qnil, ca_answer_restore, Qnil);
}

/* The directory the library's Ruby files are loaded from (lib/), set once
   by lib/carray.rb as it loads, read only afterwards. */
static char *ca_library_root = NULL;
static long  ca_library_root_len = 0;

/* CArray.library_root = dir (private): where the frames of the library's
   own Ruby methods are.  The first call wins. */
static VALUE
rb_ca_s_set_library_root (VALUE klass, VALUE dir)
{
  if ( ca_library_root == NULL ) {
    long  len = RSTRING_LEN(StringValue(dir));
    char *copy = ALLOC_N(char, len + 1);
    memcpy(copy, RSTRING_PTR(dir), len);
    copy[len] = '\0';
    ca_library_root_len = len;
    ca_library_root = copy;
  }
  return Qnil;
}

/* Whether a frame without a source file -- a C method -- is one of the
   library's: a method of a CA* or CScalar class, or a CA_* conversion
   function.  A method of a core class (Array#map, Integer#times) is not. */
static int
ca_frame_is_library_cfunc (VALUE frame, VALUE name)
{
  VALUE path = rb_profile_frame_classpath(frame);
  if ( ! NIL_P(path) ) {
    const char *p = RSTRING_PTR(path);
    long        n = RSTRING_LEN(path);
    if ( ( n >= 2 && strncmp(p, "CA", 2) == 0 )
         || ( n >= 7 && strncmp(p, "CScalar", 7) == 0 ) ) {
      return 1;
    }
  }
  return RSTRING_LEN(name) > 3 && strncmp(RSTRING_PTR(name), "CA_", 3) == 0;
}

/* The method the user called: going out from the innermost frame, the last
   frame of the library -- a Ruby method under ca_library_root, or one of
   its C methods -- before the user's own code (a block included) is
   reached.  A core C method the library calls on the way (Array#map) is
   passed through.  0 when no frame of the library is found. */
#define CA_NAMING_FRAMES 64

static ID
ca_user_called_method_id (void)
{
  ID id_initialize = rb_intern("initialize");
  ID id_new        = rb_intern("new");
  VALUE frames[CA_NAMING_FRAMES];
  int   lines[CA_NAMING_FRAMES];
  int   n, i;
  ID    found = 0;
  if ( ca_library_root == NULL ) {
    return 0;
  }
  n = rb_profile_frames(0, CA_NAMING_FRAMES, frames, lines);
  for (i = 0; i < n; i++) {
    VALUE file = rb_profile_frame_absolute_path(frames[i]);
    VALUE name, label;
    if ( NIL_P(file) ) {
      /* code evaluated with a file name (class_eval in the library) and the
         core written in Ruby ("<internal:numeric>") have a path but no
         absolute path; -e has a path outside the library */
      file = rb_profile_frame_path(frames[i]);
    }
    if ( ! NIL_P(file) && strcmp(StringValueCStr(file), "<cfunc>") == 0 ) {
      name = rb_profile_frame_method_name(frames[i]);
      if ( NIL_P(name) ) {
        continue;
      }
      if ( ca_frame_is_library_cfunc(frames[i], name) ) {
        found = rb_to_id(name);
      }
      else if ( found == id_initialize && rb_to_id(name) == id_new ) {
        found = id_new;                       /* Class#new around our initialize */
      }
      continue;                               /* a core C method passes */
    }
    if ( ! NIL_P(file) && strncmp(StringValueCStr(file), "<internal:", 10) == 0 ) {
      continue;                               /* core written in Ruby (Integer#times) */
    }
    if ( NIL_P(file)                          /* eval without a file: the user's */
         || RSTRING_LEN(file) <= ca_library_root_len
         || strncmp(RSTRING_PTR(file), ca_library_root, ca_library_root_len) != 0
         || RSTRING_PTR(file)[ca_library_root_len] != '/' ) {
      break;
    }
    /* A block of the library (an each inside a method, the autoload stub)
       names nothing: the method around it is further out.  A block whose
       method is a class body is a method made by define_method, and its
       frame does not carry the method's name, so the walk gives up and the
       innermost C method is named, as before the walk. */
    label = rb_profile_frame_label(frames[i]);
    if ( ! NIL_P(label) && strncmp(StringValueCStr(label), "block ", 6) == 0 ) {
      VALUE base = rb_profile_frame_base_label(frames[i]);
      if ( ! NIL_P(base) && RSTRING_LEN(base) > 0 && RSTRING_PTR(base)[0] == '<' ) {
        return 0;
      }
      continue;
    }
    name = rb_profile_frame_method_name(frames[i]);
    if ( ! NIL_P(name) ) {
      found = rb_to_id(name);
    }
  }
  return found;
}

const char *
ca_calling_method_name (void)
{
  ID id;
  const char *s;
  size_t n;
  if ( (s = ca_answering_name()) ) {
    return s;
  }
  id = ca_user_called_method_id();
  if ( ! id ) {
    id = rb_frame_this_func();
  }
  if ( ! id ) {
    return "axis";
  }
  s = ca_stable_id_name(id);
  if ( ! s ) {
    return "axis";
  }
  n = strlen(s);
  if ( n > 3 && strcmp(s + n - 3, "_ki") == 0 ) {
    return ca_stable_id_name(rb_intern2(s, (long) (n - 3)));
  }
  return s;
}

/* The Integer value of an integer argument (`axis`, `kth`, `min_count`,
   ...).  Anything else -- a Float included, which NUM2LONG would truncate
   -- is a TypeError.  `arg` is the argument's name; `name` names the method
   in the message, NULL for the method the user called. */
/* The number of cells in a shape.  A shape whose cell count, or whose size
   at `bytes` a cell, does not fit ca_size_t is refused: wrapped, the count
   would describe a smaller array than the view addresses, and every read
   and write past it would leave the buffer.  Negative extents are the
   caller's to refuse, with its own message. */
ca_size_t
ca_shape_elements (int8_t ndim, const ca_size_t *dim, ca_size_t bytes)
{
  ca_size_t elements = 1, total;
  int8_t i;
  for ( i = 0; i < ndim; i++ ) {
    if ( dim[i] == 0 ) return 0;     /* empty, whatever the other extents */
  }
  for ( i = 0; i < ndim; i++ ) {
    if ( __builtin_mul_overflow(elements, dim[i], &elements) ) {
      rb_raise(rb_eArgError, "too large byte length");
    }
  }
  if ( __builtin_mul_overflow(elements, (bytes > 0 ? bytes : 1), &total) ) {
    rb_raise(rb_eArgError, "too large byte length");
  }
  return elements;
}

/* An index array is read as ca_size_t.  A float or complex one would be
   cut to an integer on the way, so it is refused, as the indexer refuses
   it.  A uint64 one holding 2**63 or more would turn negative and count
   from the end of the axis, so it is refused as the out-of-range index it
   is. */
void
ca_check_index_array (VALUE v)
{
  CArray *ca;
  if ( ! rb_obj_is_carray(v) ) return;
  GetCArray(v, ca);
  if ( ca_is_float_type(ca) || ca_is_complex_type(ca) ) {
    rb_raise(rb_eIndexError,
             "data_type %s is invalid for an index (should be integer)",
             ca_type_name[ca->data_type]);
  }
  if ( ca->data_type != CA_UINT64 || ca->elements == 0 ) return;
  {
    VALUE max = rb_funcall(v, rb_intern("max"), 0);
    if ( rb_obj_is_kind_of(max, rb_cInteger) &&
         RTEST(rb_funcall(max, rb_intern(">"), 1, LL2NUM(CA_LENGTH_MAX))) ) {
      rb_raise(rb_eIndexError, "index %"PRIsVALUE" is out of range", max);
    }
  }
}

long
ca_integer_arg (VALUE v, const char *arg, const char *name)
{
  if ( ! RB_INTEGER_TYPE_P(v) ) {
    rb_raise(rb_eTypeError, "%s: %s must be an Integer (got %"PRIsVALUE")",
             name ? name : ca_calling_method_name(), arg, rb_obj_class(v));
  }
  return NUM2LONG(v);
}

void
ca_index_out_of_range_at (ca_size_t idx, ca_size_t n, int axis)
{
  rb_raise(rb_eIndexError,
           "%s: index %lld is out of range for length %lld on axis %d",
           ca_calling_method_name(), (long long) idx, (long long) n, axis);
}

void
ca_obj_compare_refused (VALUE a, VALUE b)
{
  /* The right-hand value is written as Ruby's own comparison error writes
     it: inspected when it is nil, true, false or a number, its class
     otherwise. */
  volatile VALUE rhs = ( RB_SPECIAL_CONST_P(b) || RB_FLOAT_TYPE_P(b) )
                       ? rb_inspect(b) : rb_class_name(rb_obj_class(b));
  rb_raise(rb_eArgError, "%s: comparison of %"PRIsVALUE" with %"PRIsVALUE" failed",
           ca_calling_method_name(), rb_class_name(rb_obj_class(a)), rhs);
}

void
ca_index_out_of_range (ca_size_t idx, ca_size_t n, const char *what)
{
  rb_raise(rb_eIndexError, "%s: %s %lld is out of range for length %lld",
           ca_calling_method_name(), what, (long long) idx, (long long) n);
}

/* The min_count: keyword of a reduction: nil (not given) is -1, any other
   value an Integer of at least 0.  An error names `name`, or the method the
   user called when NULL.  See ca_too_few_present. */
long
ca_min_count_arg (VALUE v, const char *name)
{
  long n;
  if ( NIL_P(v) ) {
    return -1;
  }
  n = ca_integer_arg(v, "min_count", name);
  if ( n < 0 ) {
    rb_raise(rb_eArgError, "%s: min_count must be non-negative (got %ld)",
             name ? name : ca_calling_method_name(), n);
  }
  return n;
}

/* CArray.__present_cells_needed_per_result_cell__(op, min_count, least): how many present cells a
   result cell of `op` needs (ca_too_few_present), for a reduction written
   in Ruby; it masks the cells whose count is below it. */
static VALUE
rb_ca_s_min_count_need (VALUE klass, VALUE vop, VALUE vmc, VALUE vleast)
{
  volatile VALUE name = rb_String(vop);
  long need  = NUM2LONG(vleast);
  long mc    = ca_min_count_arg(vmc, StringValueCStr(name));
  return LONG2NUM(mc > need ? mc : need);
}

/* A keyword that names one of two Symbols (`masked_position: :first /
   :last`, `kind: :quick / :stable`, `method: :ordinal / :dense`):
   returns 0 for c0 and 1 for c1.  Anything but a Symbol is a TypeError,
   another Symbol an ArgumentError, both naming the method (`name`, or the
   method the user called when NULL). */
int
ca_symbol_choice (VALUE v, const char *arg, const char *c0, const char *c1,
                  const char *name)
{
  ID id;
  if ( ! SYMBOL_P(v) ) {
    rb_raise(rb_eTypeError, "%s: %s must be a Symbol (got %"PRIsVALUE")",
             name ? name : ca_calling_method_name(), arg, rb_obj_class(v));
  }
  id = SYM2ID(v);
  if ( id == rb_intern(c0) ) {
    return 0;
  }
  if ( id == rb_intern(c1) ) {
    return 1;
  }
  rb_raise(rb_eArgError, "%s: unknown %s :%"PRIsVALUE" (expected :%s or :%s)",
           name ? name : ca_calling_method_name(), arg, rb_id2str(id), c0, c1);
  return 0;
}

/* `fill` as a cell of `data_type` holds it: the value a store of `fill`
   into such an array would leave. */
VALUE
ca_fill_as (VALUE fill, int8_t data_type)
{
  ca_size_t dim[1] = { 1 };
  VALUE cell = rb_carray_new(data_type, 1, dim, 0, NULL);
  rb_ca_store_all(cell, fill);
  return rb_ca_fetch_addr(cell, 0);
}

/* The `fill_value:` of a reduction, applied to its result: the masked
   cells of a CArray result are filled as a store would fill them, each
   member of a two-array result (minmax) alike.  `whole` says the result
   was computed with every axis kept for a full reduction; its one cell
   is then returned as the scalar the caller asked for.  A caller passes
   no fill for `fill_value: UNDEF`, which leaves the cells undefined. */
VALUE
ca_reduce_fill (VALUE result, VALUE fill, int whole)
{
  if ( RB_TYPE_P(result, T_ARRAY) ) {
    long i, n = RARRAY_LEN(result);
    VALUE out = rb_ary_new_capa(n);
    for ( i = 0; i < n; i++ ) {
      rb_ary_push(out, ca_reduce_fill(RARRAY_AREF(result, i), fill, whole));
    }
    return out;
  }
  if ( rb_obj_is_kind_of(result, rb_cCArray) ) {
    CArray *cr;
    GetCArray(result, cr);
    if ( ca_has_mask(cr) ) {
      result = rb_ca_mask_fill_copy(result, fill);
    }
    else if ( cr->elements > 0 ) {
      /* No cell needed the fill, but a fill the result cannot hold is
         refused all the same, not only when some cell happens to be
         undefined: it goes into a one-cell array of the result's kind. */
      volatile VALUE one = rb_funcall(rb_funcall(result, rb_intern("flatten"), 0),
                                      rb_intern("[]"), 1,
                                      rb_range_new(INT2FIX(0), INT2FIX(0), 0));
      rb_ca_store_addr(rb_ca_template(one), 0, fill);
    }
    return whole ? rb_ca_fetch_addr(result, 0) : result;
  }
  return ( result == CA_UNDEF ) ? fill : result;
}

/* CArray.__fill_undefined_result_cells__(result, fill_value): ca_reduce_fill for a
   reduction written in Ruby.  A fill_value of nil or UNDEF leaves the
   undefined cells as they are. */
static VALUE
rb_ca_s_reduce_fill (VALUE klass, VALUE result, VALUE fill)
{
  if ( NIL_P(fill) || fill == CA_UNDEF ) {
    return result;
  }
  return ca_reduce_fill(result, fill, 0);
}

/* ca_integer_arg for an `axis` argument. */
long
ca_axis_integer (VALUE raxis, const char *name)
{
  return ca_integer_arg(raxis, "axis", name);
}

/* Self-independent kernel: normalize `raw` against `ndim`, returning a
   canonical non-negative axis in [0, ndim) as int.  Accepts negative
   values (Python/Ruby convention: -1 => ndim-1).  Raises ArgumentError
   if out of range.  `name` is used in the error message (e.g.
   "mask_duplicates", "sum", "merge"); pass NULL to use the name of the
   method the user called.

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
             name ? name : ca_calling_method_name(), raw, ndim);
  }
  return (int) axis;
}

/* An array has at most CA_RANK_MAX axes, and every dim[] and strides[]
   array in the library is that long.  A constructor or view whose result
   would have more -- a shape given, a rank computed -- calls this before it
   writes a single dim, and is refused with ArgumentError naming the method,
   the rank and the limit.  `name` NULL names the method the user called. */
void
ca_check_rank_fits (long ndim, const char *name)
{
  if ( ndim > CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "%s: ndim %ld exceeds CA_RANK_MAX %d",
             name ? name : ca_calling_method_name(), ndim, CA_RANK_MAX);
  }
}

/* The axis an `axis` argument names among `ndim` axes: the one rule every
   entry that takes an axis from Ruby keeps.  An Integer, negative counting
   from the end; anything else raises TypeError, and an Integer outside
   [-ndim, ndim) raises ArgumentError naming the value given -- a Bignum
   too, since no ndim reaches it.  `name` and the insertion-position use of
   `ndim` are as for rb_ca_normalize_axis_for_ndim. */
int
ca_normalize_axis_arg (VALUE raxis, int ndim, const char *name)
{
  ca_check_rank_fits(ndim, name);   /* no array has the axes to name */
  if ( RB_INTEGER_TYPE_P(raxis) && ! RB_FIXNUM_P(raxis) ) {
    rb_raise(rb_eArgError,
             "%s: axis %"PRIsVALUE" out of range for ndim %d",
             name ? name : ca_calling_method_name(), raxis, ndim);
  }
  return rb_ca_normalize_axis_for_ndim(ca_axis_integer(raxis, name), ndim, name);
}

/* Self-bound wrapper: delegate to the kernel using self.ndim.  Kept
   for backward compatibility with the existing instance method
   `CArray#normalize_axis`. */
int
rb_ca_normalize_axis_value (VALUE self, VALUE raxis, const char *name)
{
  CArray *ca;
  GetCArray(self, ca);
  return ca_normalize_axis_arg(raxis, (int) ca->ndim, name);
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
  k = ca_normalize_axis_arg(raxis, NUM2INT(rndim), name);
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
  name = NIL_P(rname) ? NULL : StringValueCStr(rname);   /* NULL: looked up on error */
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
    /* Check before narrowing to int8_t, so the message names the id given. */
    long id = FIX2LONG(obj);
    if ( id <= CA_NONE || id >= CA_NTYPE ) {
      rb_raise(rb_eArgError, "%s: invalid data_type id %ld",
               ca_calling_method_name(), id);
    }
    return (int8_t) id;
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
    return rb_ca_guess_type(rb_str_dup(rb_sym2str(obj)));
  }
  else if ( TYPE(obj) == T_CLASS ) {
    ca_check_data_class(obj);
    return CA_FIXLEN;
  }

  inspect = rb_inspect(obj);
  rb_raise(rb_eArgError,
           "%s: <%s> is unknown data_type representation",
           ca_calling_method_name(), StringValuePtr(inspect));
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
        *bytes = ca_integer_arg(rbytes, "bytes", NULL);
      }
    }
  }
  else {
    CA_CHECK_DATA_TYPE_GIVEN(*data_type);
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

/* Takes the trailing keyword Hash off argv when the caller passed keywords.
   A Hash passed as a positional argument (`f({axis: 0})`) stays an argument,
   as in Ruby 3: it may be a value, such as a cell of an object array. */
VALUE
rb_pop_options (int *argc, VALUE **argv)
{
  VALUE ropt;
  if ( ( *argc > 0 ) && rb_keyword_given_p() &&
       ( TYPE( (*argv)[*argc-1] ) == T_HASH ) ) {
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

/* The next comma-separated key of a spec, its length in *len, or NULL
   past the last key.  The spec is read in place: a copy to cut up would
   be a C allocation, and its failure has nowhere to go but to drop every
   keyword. */
static const char *
option_key (const char **sp, long *len)
{
  const char *p = *sp, *end;

  if ( p == NULL ) {
    return NULL;
  }
  end = strchr(p, ',');
  if ( end ) {
    *len = end - p;
    *sp  = end + 1;
  }
  else {
    *len = (long) strlen(p);
    *sp  = NULL;
  }
  return p;
}

void
rb_scan_options (VALUE ropt, const char *spec_in, ...)
{
  VALUE *vp;
  const char *sp, *tok;
  long len;
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
  sp = spec_in;
  while ( ( tok = option_key(&sp, &len) ) != NULL ) {
    vp = va_arg(vals, VALUE*);
    if ( has_option ) {
      VALUE key = ID2SYM(rb_intern2(tok, len));
      if ( rb_hash_has_key(ropt, key) ) {
        *vp = rb_hash_aref(ropt, key);
      }
      /* key absent: leave *vp unchanged (caller's pre-initialized default) */
    }
    /* opts == Qnil: leave all *vp unchanged */
  }
  va_end(vals);

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
      long kn_len = RSTRING_LEN(kname);
      int found = 0;
      sp = spec_in;
      while ( ( tok = option_key(&sp, &len) ) != NULL ) {
        if ( len == kn_len && memcmp(tok, kn, len) == 0 ) { found = 1; break; }
      }
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
  const char *sp, *tok;
  long len;
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
  sp = spec_in;
  while ( ( tok = option_key(&sp, &len) ) != NULL ) {
    rval = va_arg(vals, VALUE);
    if ( has_option ) {
      rb_hash_aset(ropt, ID2SYM(rb_intern2(tok, len)), rval);
    }
  }
  va_end(vals);

  return;
}


/* Whether this runs in the main Ractor: Init does, and leaves a value in
   its Ractor-local storage that no other Ractor has. */
static rb_ractor_local_key_t ca_main_ractor_key;

int
ca_in_main_ractor (void)
{
  VALUE mark;
  return rb_ractor_local_storage_value_lookup(ca_main_ractor_key, &mark);
}

void
Init_carray_utils (void)
{
  ca_main_ractor_key = rb_ractor_local_storage_value_newkey();
  rb_ractor_local_storage_value_set(ca_main_ractor_key, Qtrue);
  ca_id_names = st_init_numtable();
  rb_nativethread_lock_initialize(&ca_id_names_lock);
  id_answering = rb_intern("__carray_answering_method__");
  id_begin    = rb_intern("begin");
  id_end      = rb_intern("end");
  id_excl_end = rb_intern("exclude_end?");

  rb_define_singleton_method(rb_cCArray, "guess_type_and_bytes",
                             rb_ca_s_guess_type_and_bytes, -1);

  rb_define_method(rb_cCArray, "normalize_axis", rb_ca_normalize_axis, -1);
  rb_define_method(rb_cCArray, "normalize_axes", rb_ca_normalize_axes, -1);
  rb_define_singleton_method(rb_cCArray, "normalize_axis",
                             rb_ca_s_normalize_axis, -1);
  rb_define_singleton_method(rb_cCArray, "__present_cells_needed_per_result_cell__",
                             rb_ca_s_min_count_need, 3);
  rb_define_singleton_method(rb_cCArray, "__fill_undefined_result_cells__",
                             rb_ca_s_reduce_fill, 2);
  rb_define_private_method(rb_singleton_class(rb_cCArray), "library_root=",
                           rb_ca_s_set_library_root, 1);
  rb_define_singleton_method(rb_cCArray, "__name_errors_after_method__",
                             rb_ca_s_answer_as, 1);

}

