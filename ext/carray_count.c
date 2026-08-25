/* ---------------------------------------------------------------------------

  CArray#count dispatcher (= value-comparison family entry point).
  Hand-routed because the dispatch decision depends on (self.data_type,
  v's runtime class), which the per-dtype mkkernel kernels can't see;
  the actual counting is delegated to the kernel-iterator helpers
  listed below.

  Future count_axis / count_where extensions belong here.

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "ca_obj_face.h"
#include <math.h>
#include <float.h>
#include <stdarg.h>

/* Forwardees from carray_kernels.c (mkkernel-generated).  rb_ca_count
   below picks one based on (self.data_type, v). */
VALUE rb_ca_count_equal_ki (int argc, VALUE *argv, VALUE self);
VALUE rb_ca_count_true_ki  (int argc, VALUE *argv, VALUE self);
VALUE rb_ca_count_false_ki (int argc, VALUE *argv, VALUE self);

/* Forwardees from carray_mask.c.  Public linkage for cross-TU dispatch:
   count(UNDEF) is mask-state vocabulary, not value vocabulary, so it
   routes through the mask-family entry; count with no value argument is
   present-cell cardinality, which routes through count_not_masked. */
VALUE rb_ca_count_masked (int argc, VALUE *argv, VALUE self);
VALUE rb_ca_count_not_masked (int argc, VALUE *argv, VALUE self);

/* CArray#count(v, axis: nil, min_count: K, fill_value: x) -- count
   cells of self that equal v, with mask-aware reduction along axis.

   Dispatch:
     - no argument               -> count_not_masked (present-cell count)
     - v == UNDEF                -> count_masked (mask-state count)
     - v is a CArray             -> broadcast: count each v[k] and stack
                                    (rejected for boolean self; see below)
     - self is boolean, v scalar -> v must be true/false literal
     - self is numeric, v scalar -> count_equal_ki (numeric equality)

   FIXLEN and OBJECT data_types raise CArray::DataTypeError (the
   kernel-iterator helpers do not implement them).  Extend
   count_equal_ki if demand returns. */

static VALUE
rb_ca_count (int argc, VALUE *argv, VALUE self)
{
  CArray *src;
  GetCArray(self, src);

  /* count (no value argument) == count_not_masked: present-cell
     cardinality ("how many are there"), the arity-0 rung of the dispatch
     ladder.  kwargs reach a -1 C method as a trailing options hash, so a
     bare `count(axis: k)` arrives as argc==1 with argv[0] a Hash; discount
     that trailing hash (same convention as the CArray-broadcast branch
     below) before deciding there is no positional value.  argv is forwarded
     verbatim so the axis: kwarg passes through. */
  {
    int has_opts = ( argc >= 1 &&
                     rb_obj_is_kind_of(argv[argc - 1], rb_cHash) );
    if ( argc - (has_opts ? 1 : 0) < 1 ) {
      return rb_ca_count_not_masked(argc, argv, self);
    }
  }

  volatile VALUE rval = argv[0];

  /* count(UNDEF) == count_masked: UNDEF is mask-state vocabulary, not a
     value to compare against.  Forward, dropping the UNDEF from argv. */
  if ( rval == CA_UNDEF ) {
    return rb_ca_count_masked(argc - 1, argv + 1, self);
  }

  /* Face gate, mirroring the search / linear family (ext/carray_order.c):
     descend an ORDERABLE Face to its storage so the equality runs on the
     numeric storage, and let the reference reconcile the query into its own
     space -- a COMPARABLE Face compares directly (strip a Face query, take a
     plain one as-is), a unit-bearing one calls its own to_comparable for any
     query type (Face CArray, Element, Time, DateTime).  A Face that counts
     by other means never arrives here: CACategorical / CAConstString define
     their own #count in Ruby.  Placed after the mask-state branches above,
     which read the mask the Face already shares with its storage, and before
     the broadcast branch, so a reconciled query array recurses as storage. */
  if ( ca_is_face(src) ) {
    volatile VALUE self_ref = self;
    int query_was_scalar = ! rb_obj_is_carray(rval);
    if ( ! ca_test_flag(src, CA_FLAG_FACE_ORDERABLE_STORAGE) ) {
      rb_raise(rb_eArgError,
               "count(v): Face-typed input (%s) is not orderable by storage; "
               "use ca.parent to count the raw storage",
               rb_obj_classname(self));
    }
    if ( ca_test_flag(src, CA_FLAG_FACE_COMPARABLE_STORAGE) ) {
      if ( ! query_was_scalar ) {
        CArray *cv;
        GetCArray(rval, cv);
        if ( ca_is_face(cv) ) {
          rval = rb_ca_strip_face_value(rval);
        }
      }
    }
    else if ( rb_respond_to(self_ref, rb_intern("to_comparable")) ) {
      rval = rb_ca_strip_face_value(rb_funcall(self_ref,
                                               rb_intern("to_comparable"),
                                               1, rval));
      /* to_comparable lifts a scalar query to a length-1 array; unwrap it so a
         scalar query still answers with a count rather than a length-1 array
         from the broadcast branch below. */
      if ( query_was_scalar && rb_obj_is_carray(rval) ) {
        rval = rb_ca_fetch_addr(rval, 0);
      }
    }
    else {
      rb_raise(rb_eArgError,
               "count(v): non-comparable Face (%s) has no to_comparable to "
               "reconcile the query; use ca.parent to count the raw storage",
               rb_obj_classname(self));
    }
    self = rb_ca_strip_face_value(self);
    GetCArray(self, src);
    /* Hand the reconciled query down in argv (count_equal_ki pops argv[0],
       the broadcast branch reads rval). */
    {
      VALUE *nargv = ALLOCA_N(VALUE, argc);
      MEMCPY(nargv, argv, VALUE, argc);
      nargv[0] = rval;
      argv = nargv;
    }
  }

  /* count(v: CArray) -- broadcast: v.shape is appended to the trailing
     axes of the output (same shape rule as SEARCH_AXIS / LINEAR_INTERP).
     Each v[k] is counted independently and stacked.  Boolean self is
     rejected here because the per-scalar dispatch below requires v to
     be a true/false literal, which an array cannot guarantee per-cell.
     Implementation iterates v in flat order and recursively calls
     self.count(vk, *axes, **opts) for each v[k]. */
  if ( rb_obj_is_kind_of(rval, rb_cCArray) ) {
    if ( src->data_type == CA_BOOLEAN ) {
      rb_raise(rb_eTypeError,
               "count(v: CArray) on boolean array: not supported "
               "(use scalar true/false; broadcast is numeric-only)");
    }

    CArray *cv;
    GetCArray(rval, cv);

    /* Pop trailing options hash (min_count / fill_value) before axes
       parsing so parse_reduce_axes only sees Integer axes.  The opts
       are forwarded verbatim via inner_argv to the recursive count(). */
    int    inner_argc = argc - 1;
    VALUE *inner_axes = argv + 1;
    volatile VALUE opt_hash = Qnil;
    if ( inner_argc > 0 && rb_obj_is_kind_of(inner_axes[inner_argc - 1],
                                              rb_cHash) ) {
      opt_hash = inner_axes[inner_argc - 1];
      inner_argc--;
    }

    /* axis comes via kwarg (axis:) in opt_hash, not positional;
       extract before computing slab_axes. */
    int8_t  slab_axes[CA_RANK_MAX];
    int8_t  naxes;
    VALUE   axis_val = Qnil;
    if ( ! NIL_P(opt_hash) ) {
      axis_val = rb_hash_lookup2(opt_hash, ID2SYM(rb_intern("axis")), Qnil);
    }
    naxes = rb_ca_parse_reduce_axes_kw(axis_val, src, slab_axes);
    (void) inner_axes;  /* axes no longer parsed from inner_axes */
    int     out_ndim;
    ca_size_t out_dim[CA_RANK_MAX];
    ca_size_t base_elements = 1;
    {
      /* base_reduced: self.shape minus slab_axes */
      int8_t is_slab[CA_RANK_MAX] = {0};
      for (int k = 0; k < naxes; k++) is_slab[slab_axes[k]] = 1;
      out_ndim = 0;
      for (int k = 0; k < src->ndim; k++) {
        if ( ! is_slab[k] ) {
          out_dim[out_ndim++] = src->dim[k];
          base_elements *= src->dim[k];
        }
      }
      /* Full reduction (naxes == ndim): base_elements = 1, no base axes. */
      /* Append v.shape. */
      for (int k = 0; k < cv->ndim; k++) {
        out_dim[out_ndim++] = cv->dim[k];
      }
    }

    /* Allocate output i64 CArray. */
    VALUE vout = rb_funcall(rb_cCArray, rb_intern("new"), 2,
                            INT2NUM(CA_INT64),
                            rb_ary_new4(out_ndim,
                                        ({ VALUE *tmp = ALLOCA_N(VALUE, out_ndim);
                                           for (int k = 0; k < out_ndim; k++)
                                             tmp[k] = SIZE2NUM(out_dim[k]);
                                           tmp; })));
    CArray *cout;
    GetCArray(vout, cout);

    /* Iterate v in flat order, call self.count(vk, *axes, **opts)
       recursively, place result at output[..., k]. */
    ca_attach(cv);
    int64_t *out_ptr = (int64_t *) cout->ptr;
    boolean8_t *out_mask = NULL;
    ca_size_t v_elements = cv->elements;
    /* inner_argv layout: [vk_scalar, axis..., axis..., [opt_hash]]
       inner_call_argc = 1 (vk) + inner_argc (axes) + (opt_hash ? 1 : 0). */
    int inner_call_argc = 1 + inner_argc + (NIL_P(opt_hash) ? 0 : 1);
    VALUE inner_argv[CA_RANK_MAX + 2];
    for (int j = 0; j < inner_argc; j++) inner_argv[1 + j] = inner_axes[j];
    if ( ! NIL_P(opt_hash) ) inner_argv[1 + inner_argc] = opt_hash;

    for (ca_size_t k = 0; k < v_elements; k++) {
      /* Extract vk as a scalar VALUE via flat addr.  rb_ca_fetch_addr
         takes a ca_size_t addr (not a Ruby VALUE). */
      VALUE vk = rb_ca_fetch_addr(rval, k);
      inner_argv[0] = vk;
      VALUE sub = rb_ca_count(inner_call_argc, inner_argv, self);

      /* Place sub into output[..., k] slot.
         Output stride for v-axis = 1, base stride = v_elements. */
      if ( sub == CA_UNDEF ) {
        if ( ! out_mask ) {
          ca_create_mask(cout);
          out_mask = (boolean8_t *) cout->mask->ptr;
        }
        for (ca_size_t i = 0; i < base_elements; i++) {
          out_ptr[i * v_elements + k] = 0;
          out_mask[i * v_elements + k] = 1;
        }
      } else if ( rb_obj_is_kind_of(sub, rb_cInteger) ) {
        /* Full reduction: sub is a single integer. */
        out_ptr[k] = NUM2LL(sub);
      } else if ( rb_obj_is_kind_of(sub, rb_cCArray) ) {
        CArray *csub;
        GetCArray(sub, csub);
        ca_attach(csub);
        int64_t *sub_ptr = (int64_t *) csub->ptr;
        boolean8_t *sub_mask = (csub->mask) ? (boolean8_t *) csub->mask->ptr : NULL;
        for (ca_size_t i = 0; i < base_elements; i++) {
          out_ptr[i * v_elements + k] = sub_ptr[i];
          if ( sub_mask && sub_mask[i] ) {
            if ( ! out_mask ) {
              ca_create_mask(cout);
              out_mask = (boolean8_t *) cout->mask->ptr;
            }
            out_mask[i * v_elements + k] = 1;
          }
        }
        ca_detach(csub);
      } else {
        ca_detach(cv);
        rb_raise(rb_eRuntimeError,
                 "count(v: CArray): unexpected sub-result type");
      }
    }
    ca_detach(cv);
    return vout;
  }

  /* Scalar v: strict (self.data_type, v) validation, then forward. */
  if ( src->data_type == CA_BOOLEAN ) {
    if ( rval == Qtrue ) {
      return rb_ca_count_true_ki(argc - 1, argv + 1, self);
    } else if ( rval == Qfalse ) {
      return rb_ca_count_false_ki(argc - 1, argv + 1, self);
    } else if ( FIXNUM_P(rval) ) {
      /* Boolean stores 0/1; accept the integer literals 1 (= true) and
         0 (= false) as the query, matching boolean-as-0/1-numeric.  Any
         other integer is outside the boolean domain and rejected.  (A
         Bignum / Float / other type falls through to the raise below --
         only true / false / 1 / 0 are accepted.) */
      long iv = FIX2LONG(rval);
      if ( iv == 1 ) {
        return rb_ca_count_true_ki(argc - 1, argv + 1, self);
      } else if ( iv == 0 ) {
        return rb_ca_count_false_ki(argc - 1, argv + 1, self);
      }
      rb_raise(rb_eTypeError,
               "count(v) on boolean array: v must be true / false / 1 / 0, got %ld",
               iv);
    } else {
      rb_raise(rb_eTypeError,
               "count(v) on boolean array: v must be true / false / 1 / 0, got %s",
               rb_obj_classname(rval));
    }
  } else {
    if ( rval == Qtrue || rval == Qfalse ) {
      rb_raise(rb_eTypeError,
               "count(v) on numeric array: v must be numeric, got %s",
               rb_obj_classname(rval));
    }
    /* Pass full argv; count_equal_ki pops argv[0] as value_arg. */
    return rb_ca_count_equal_ki(argc, argv, self);
  }
}

void
Init_carray_count (void)
{
  /* CArray#count is the sole value-comparison entry.  Replaces the
     pre-3.0 count_equal / count_equiv / count_close / count_true /
     count_false (no aliases retained; see NEWS for migration). */
  rb_define_method(rb_cCArray,  "count",       rb_ca_count,        -1);
}


