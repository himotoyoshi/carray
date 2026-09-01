/* ---------------------------------------------------------------------------

  Operator dispatch: the drivers behind CArray's arithmetic / comparison
  operators (rb_ca_call_monop / _binop / _triop / _moncmp / _bincmp),
  plus the chunked-gather and safe-mask-overlay helpers that let the eager
  slow path materialise operands without attaching attach-hostile views.

---------------------------------------------------------------------------- */

#include <math.h>
#include <stdarg.h>

#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_* */
#include "ca_obj_face.h"   /* ca_face_reconcile_comparison (comparison Face gate) */

VALUE rb_mCAMath;

extern ca_binop_func_t ca_binop_mul[CA_NTYPE];
extern ca_binop_func_t ca_binop_add[CA_NTYPE];

void
ca_zerodiv (void)
{
  rb_raise(rb_eZeroDivError, "divided by 0");
}

/* Chunked gather helpers for the eager slow path.  Instead of an ALLOCV
   full-size materialise, gather per-region via xfer_stride into arena
   scratch, dropping the memory peak from O(operand_size) to O(chunk).

   Policy:
   - target chunk = 4096 elements (~32KB at f64), L1d-friendly
   - N-D shape: outer-axis chunking, row-aligned
   - mask handling: via the ca_copy_mask_overlay path

   These three helpers (ca_chunk_inner_size / ca_chunk_compute_n /
   ca_chunked_gather) are extern so ca_sweep_engine.c can reuse the same
   chunk policy + region-gather mechanism for the sweep ELEMENT macro
   family without duplicating the implementation. */

#define CA_CHUNK_TARGET_ELEMENTS 4096

ca_size_t
ca_chunk_inner_size (CArray *ca)
{
  /* product of all dims except outermost; 1 for ndim <= 1 / scalar */
  ca_size_t inner = 1;
  int8_t k;
  if (ca->ndim <= 1) return 1;
  for (k = ca->ndim - 1; k >= 1; k--) inner *= ca->dim[k];
  return inner;
}

ca_size_t
ca_chunk_compute_n (ca_size_t total, ca_size_t inner, ca_size_t bytes_per_cell)
{
  /* Compute chunk_n in elements aligned to outer axis: a multiple of
     `inner` (or = inner if target < inner = 1 row/chunk fallback).
     Result is clamped to `total`. */
  ca_size_t target_bytes = CA_CHUNK_TARGET_ELEMENTS * 8;  /* ~32KB at f64 */
  ca_size_t target_n = target_bytes / (bytes_per_cell > 0 ? bytes_per_cell : 1);
  ca_size_t chunk_n;
  if (target_n < 1) target_n = 1;
  if (inner <= 0) inner = 1;
  if (target_n >= inner) {
    chunk_n = (target_n / inner) * inner;  /* round down to inner multiple */
  } else {
    chunk_n = inner;                        /* 1 row/chunk fallback */
  }
  if (chunk_n > total) chunk_n = total;
  if (chunk_n < 1) chunk_n = 1;
  return chunk_n;
}

/* Gather `n` elements starting at flat-offset `off` from `ca` into `dest`
   (contig native byte layout of the chunked region).  Requires:
   - `off` and `n` are multiples of inner = Π_{k>=1} ca->dim[k]
   - `n` represents `outer_rows * inner` consecutive flat-addr cells
   For ndim <= 1: simple linear region. */
void
ca_chunked_gather (CArray *ca, ca_size_t off, ca_size_t n, void *dest)
{
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t counts[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  int8_t k;
  ca_size_t inner, bytes, s;

  bytes = ca->bytes;

  if (ca->ndim <= 1) {
    /* 1-D (or scalar reified to 1-D via elements): single axis chunk */
    starts[0]  = (ca->ndim == 0) ? 0 : off;
    counts[0]  = (ca->ndim == 0) ? 1 : n;
    strides[0] = bytes;
    ca_xfer_stride(ca, starts, counts, strides, dest, CA_XFER_GET);
    return;
  }

  inner = 1;
  for (k = ca->ndim - 1; k >= 1; k--) inner *= ca->dim[k];

  starts[0] = (inner > 0) ? off / inner : 0;
  counts[0] = (inner > 0) ? n   / inner : 0;
  for (k = 1; k < ca->ndim; k++) {
    starts[k] = 0;
    counts[k] = ca->dim[k];
  }

  /* native contig strides for the chunked shape */
  s = bytes;
  for (k = ca->ndim - 1; k >= 0; k--) {
    strides[k] = s;
    s *= counts[k];
  }
  ca_xfer_stride(ca, starts, counts, strides, dest, CA_XFER_GET);
}

/* Operand mask overlay without calling ca_attach on the operand masks.

   `ca_copy_mask_overlay` (carray_mask.c) attaches each operand mask via
   ca_attach(cs->mask) before OR-folding into the output mask.  For
   attach-hostile operand masks (= mock fixture, CAStack expansion,
   per-region xfer-only views) that raises.

   This helper instead materialises each operand mask via ca_xfer_all into
   a transient arena scratch and OR-folds byte-wise into ca_out->mask.
   Memory peak: one mask scratch at a time (= elements bytes, 1 B/cell),
   released between operands.

   CAREFUL: `ca_out` must be a freshly templated entity (driver allocates
   via ca_template_safe), so ca_out->mask->ptr is directly writable
   without attach.

   This gathers the full mask once; a per-chunk mask gather inside the
   chunked branch is a possible future optimisation. */
void
ca_mask_overlay_safe (CArray *ca_out, int n, ...)
{
  va_list ap;
  CArray *slist[8];
  int i, any_mask = 0;

  if ( n < 0 || n > 8 ) {
    rb_raise(rb_eRuntimeError, "ca_mask_overlay_safe: n out of range");
  }
  va_start(ap, n);
  for ( i = 0; i < n; i++ ) {
    slist[i] = va_arg(ap, CArray *);
    if ( slist[i] && ca_has_mask(slist[i]) ) any_mask = 1;
  }
  va_end(ap);

  if ( ! any_mask ) return;

  ca_update_mask(ca_out);
  {
    int created_new = 0;
    if ( ! ca_out->mask ) {
      ca_create_mask(ca_out);
      created_new = 1;
    }

    boolean8_t *ma = (boolean8_t *) ca_out->mask->ptr;
    ca_size_t elements = ca_out->elements;
    ca_size_t j;

    /* Fresh mask → zero-init.  Existing mask (= bang variant where
       ca_out IS one of the operands) → preserve as initial accumulator
       (= ca_out's own contribution is already in `ma`, OR in others).
       This is structurally equivalent to ca_copy_mask_overlay_n's
       behavior which OR'd into existing mask without clearing.        */
    if ( created_new ) memset(ma, 0, elements);

    for ( i = 0; i < n; i++ ) {
      CArray *cs = slist[i];
      if ( ! cs ) continue;
      ca_update_mask(cs);
      if ( ! cs->mask ) continue;

      if ( ca_is_scalar(cs) ) {
        boolean8_t bit = 0;
        ca_xfer_all(cs->mask, &bit, CA_XFER_GET);
        if ( bit ) memset(ma, 1, elements);
      } else {
        void *scratch = ca_lazy_arena_acquire(elements);
        boolean8_t *ms = (boolean8_t *) scratch;
        ca_xfer_all(cs->mask, scratch, CA_XFER_GET);
        for ( j = 0; j < elements; j++ ) ma[j] |= ms[j];
        ca_lazy_arena_release(scratch);
      }
    }
  }
}

/* Monop driver.  ca1 is input-only (the driver does not attach it); ca2
   is the output (a new entity, attach legit).  fast = ca_attach_is_alias(ca1)
   → 1-shot; slow = ALLOCV + ca_xfer_all without ca_func[X].attach. */
VALUE
rb_ca_call_monop (VALUE self, ca_monop_func_t func[])
{
  volatile VALUE out;
  CArray *ca1, *ca2;   /* ca2 = ca1.op */

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca1);

  /* Boolean-as-numeric promotion: an arithmetic monop (-@ etc.) has no
     boolean kernel (func[CA_BOOLEAN] == ca_monop_not_implement), so coerce
     a bool input to CA_INT64 -- `-b` yields [-1, 0, ...] as its 0/1 numeric
     storage.  Monops that DO define a boolean kernel are left as bool. */
  if ( ca1->data_type == CA_BOOLEAN && func[CA_BOOLEAN] == ca_monop_not_implement ) {
    self = rb_ca_wrap_readonly(self, INT2NUM(CA_INT64));
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca1);
  }

  ca2 = ca_has_mask(ca1) ? ca_template_safe(ca1) : ca_template(ca1);
  out = ca_wrap_struct(ca2);

  ca_mask_overlay_safe(ca2, 1, ca1);

  if ( ca_attach_is_alias(ca1) ) {
    ca_attach(ca1);
    func[ca1->data_type](ca1->elements,
                         ( ca2->mask ) ? (boolean8_t *)ca2->mask->ptr : NULL,
                         ca1->ptr, 1,
                         ca2->ptr, 1);
    ca_detach(ca1);
  }
  else {
    /* Strided-walk fast path: when ca1 is a non-alias CAStride-family view
       that composes to a ptr-bearing root, walk strides directly into the
       kernel instead of staging via ca_xfer_all + a contig-kernel pass.
       Saves 2x bandwidth (no gather buffer write+read).  Output ca2 is a
       contig entity; per-row output offset = row_idx * inner_count *
       ca2->bytes. */
    int strided_path_done = 0;
    {
      extern ca_operation_function_t ca_stride_func;
      if ( ca_func[ca1->obj_type].attach == ca_stride_func.attach ) {
        CAStride *cs1 = (CAStride *) ca1;
        CArray   *root1;
        ca_size_t strides1[CA_RANK_MAX];
        ca_size_t base1;
        int8_t    ndim = cs1->ndim;
        int8_t    k;
        int       ok = 1;

        ca_stride_compose_to_root(cs1, &root1, strides1, &base1);

        if ( !root1->ptr ) ok = 0;

        /* element-stride conversion: strides must be byte-multiples of bytes */
        if ( ok ) {
          for ( k = 0; k < ndim; k++ ) {
            if ( strides1[k] % ca1->bytes != 0 ) { ok = 0; break; }
          }
        }
        if ( ok && (base1 % ca1->bytes != 0) ) ok = 0;

        if ( ok ) {
          int8_t    inner_axis = ndim - 1;
          ca_size_t inner_n = (ndim >= 1) ? cs1->dim[inner_axis] : ca1->elements;
          ca_size_t s1_inner = (ndim >= 1) ? strides1[inner_axis] / ca1->bytes : 1;
          ca_size_t idx[CA_RANK_MAX];
          ca_size_t out_off = 0;
          ca_size_t e1_strides[CA_RANK_MAX];
          ca_size_t e1_base;
          char     *p1_root;

          for ( k = 0; k < ndim; k++ ) {
            e1_strides[k] = strides1[k] / ca1->bytes;
          }
          e1_base = base1 / ca1->bytes;
          p1_root = (char *) root1->ptr;

          for ( k = 0; k < ndim; k++ ) idx[k] = 0;

          if ( ndim == 0 || ndim == 1 ) {
            ca_size_t n_call = (ndim == 0) ? 1 : inner_n;
            func[ca1->data_type](n_call,
                                 ( ca2->mask ) ? (boolean8_t *) ca2->mask->ptr : NULL,
                                 p1_root + e1_base * ca1->bytes,
                                   (ndim == 0) ? 0 : s1_inner,
                                 ca2->ptr, 1);
          }
          else {
            while ( 1 ) {
              ca_size_t off1 = e1_base;
              for ( k = 0; k < ndim - 1; k++ ) {
                off1 += idx[k] * e1_strides[k];
              }
              func[ca1->data_type](inner_n,
                                   ca2->mask
                                     ? ((boolean8_t *) ca2->mask->ptr) + out_off
                                     : NULL,
                                   p1_root + off1 * ca1->bytes, s1_inner,
                                   (char *) ca2->ptr + out_off * ca2->bytes, 1);
              out_off += inner_n;
              k = ndim - 2;
              while ( k >= 0 ) {
                if ( ++idx[k] < cs1->dim[k] ) break;
                idx[k] = 0; k--;
              }
              if ( k < 0 ) break;
            }
          }
          strided_path_done = 1;
        }
      }
    }

    if ( !strided_path_done ) {
      volatile VALUE h1 = Qnil;
      char *p1;
      (void) h1;
      p1 = ALLOCV_N(char, h1, ca1->elements * ca1->bytes);
      ca_xfer_all(ca1, p1, CA_XFER_GET);
      func[ca1->data_type](ca1->elements,
                           ( ca2->mask ) ? (boolean8_t *)ca2->mask->ptr : NULL,
                           p1,       1,
                           ca2->ptr, 1);
      ALLOCV_END(h1);
    }
  }

  return out;
}

VALUE
rb_ca_call_monop_bang (VALUE self, ca_monop_func_t func[])
{
  CArray *ca1;         /* ca1.op! */

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca1);

  ca_attach(ca1);
  func[ca1->data_type](ca1->elements,
                       ( ca1->mask ) ? (boolean8_t *)ca1->mask->ptr : NULL,
                       ca1->ptr, 1,
                       ca1->ptr, 1);
  ca_sync(ca1);
  ca_detach(ca1);

  return self;
}

/* Dtype-changing monop dispatch.  Allocates output of data_type
   out_data_types[in_data_type].  When out_data_type == in_data_type this is identical
   to rb_ca_call_monop; when they differ (e.g. abs on cmplx128 -> f64),
   the output array has different cell size from input.  No bang form
   (= data_type change in-place is ill-defined; bang must preserve data_type). */
VALUE
rb_ca_call_monop_typed (VALUE self, ca_monop_func_t func[],
                                    int8_t out_data_types[])
{
  volatile VALUE out;
  CArray *ca1, *ca2;
  int8_t out_dt;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca1);

  out_dt = out_data_types[ca1->data_type];
  if ( out_dt < 0 ) {
    rb_raise(rb_eCADataTypeError,
             "data_type-changing monop not implemented for input data_type %d",
             ca1->data_type);
  }

  /* Allocate output with the per-op output data_type.  Same shape as input. */
  ca2 = carray_new(out_dt, ca1->ndim, ca1->dim, 0, NULL);
  out = ca_wrap_struct(ca2);

  /* Same fast/slow pattern as rb_ca_call_monop.  ca1 input-only, ca2 output. */
  ca_mask_overlay_safe(ca2, 1, ca1);

  if ( ca_attach_is_alias(ca1) ) {
    ca_attach(ca1);
    func[ca1->data_type](ca1->elements,
                         ( ca2->mask ) ? (boolean8_t *)ca2->mask->ptr : NULL,
                         ca1->ptr, 1,
                         ca2->ptr, 1);
    ca_detach(ca1);
  }
  else {
    /* Same strided-walk fast path as rb_ca_call_monop, but the output ca2
       may have a different cell size (ca2->bytes may differ from
       ca1->bytes, e.g. abs cmplx128 -> f64). */
    int strided_path_done = 0;
    {
      extern ca_operation_function_t ca_stride_func;
      if ( ca_func[ca1->obj_type].attach == ca_stride_func.attach ) {
        CAStride *cs1 = (CAStride *) ca1;
        CArray   *root1;
        ca_size_t strides1[CA_RANK_MAX];
        ca_size_t base1;
        int8_t    ndim = cs1->ndim;
        int8_t    k;
        int       ok = 1;

        ca_stride_compose_to_root(cs1, &root1, strides1, &base1);

        if ( !root1->ptr ) ok = 0;

        if ( ok ) {
          for ( k = 0; k < ndim; k++ ) {
            if ( strides1[k] % ca1->bytes != 0 ) { ok = 0; break; }
          }
        }
        if ( ok && (base1 % ca1->bytes != 0) ) ok = 0;

        if ( ok ) {
          int8_t    inner_axis = ndim - 1;
          ca_size_t inner_n = (ndim >= 1) ? cs1->dim[inner_axis] : ca1->elements;
          ca_size_t s1_inner = (ndim >= 1) ? strides1[inner_axis] / ca1->bytes : 1;
          ca_size_t idx[CA_RANK_MAX];
          ca_size_t out_off = 0;
          ca_size_t e1_strides[CA_RANK_MAX];
          ca_size_t e1_base;
          char     *p1_root;

          for ( k = 0; k < ndim; k++ ) {
            e1_strides[k] = strides1[k] / ca1->bytes;
          }
          e1_base = base1 / ca1->bytes;
          p1_root = (char *) root1->ptr;

          for ( k = 0; k < ndim; k++ ) idx[k] = 0;

          if ( ndim == 0 || ndim == 1 ) {
            ca_size_t n_call = (ndim == 0) ? 1 : inner_n;
            func[ca1->data_type](n_call,
                                 ( ca2->mask ) ? (boolean8_t *) ca2->mask->ptr : NULL,
                                 p1_root + e1_base * ca1->bytes,
                                   (ndim == 0) ? 0 : s1_inner,
                                 ca2->ptr, 1);
          }
          else {
            while ( 1 ) {
              ca_size_t off1 = e1_base;
              for ( k = 0; k < ndim - 1; k++ ) {
                off1 += idx[k] * e1_strides[k];
              }
              func[ca1->data_type](inner_n,
                                   ca2->mask
                                     ? ((boolean8_t *) ca2->mask->ptr) + out_off
                                     : NULL,
                                   p1_root + off1 * ca1->bytes, s1_inner,
                                   (char *) ca2->ptr + out_off * ca2->bytes, 1);
              out_off += inner_n;
              k = ndim - 2;
              while ( k >= 0 ) {
                if ( ++idx[k] < cs1->dim[k] ) break;
                idx[k] = 0; k--;
              }
              if ( k < 0 ) break;
            }
          }
          strided_path_done = 1;
        }
      }
    }

    if ( !strided_path_done ) {
      volatile VALUE h1 = Qnil;
      char *p1;
      (void) h1;
      p1 = ALLOCV_N(char, h1, ca1->elements * ca1->bytes);
      ca_xfer_all(ca1, p1, CA_XFER_GET);
      func[ca1->data_type](ca1->elements,
                           ( ca2->mask ) ? (boolean8_t *)ca2->mask->ptr : NULL,
                           p1,       1,
                           ca2->ptr, 1);
      ALLOCV_END(h1);
    }
  }

  return out;
}

int
rb_ca_test_castable (VALUE other)
{
  volatile VALUE retval;
  if ( rb_respond_to(other, rb_intern("castable_to_carray?")) ) {
    retval = rb_funcall(other, rb_intern("castable_to_carray?"), 0);
    return RTEST(retval); 
  }
  else {
    return 1;
  }
}

VALUE 
rb_ca_binop_pass_to_other (VALUE self, VALUE other, ID method)
{
  volatile VALUE pair;
  pair = rb_funcall(other, rb_intern("coerce"), 1, self);
  self  = rb_ary_entry(pair, 0);
  other = rb_ary_entry(pair, 1);
  return rb_funcall(self, method, 1, other);
}

/* Gather a boolean operand's value + mask bytes into vbuf/mbuf, broadcasting
   a scalar operand across n cells.  Uses ca_copy_data (materialise, no
   attach) so views / lazy sources are handled transparently. */
static void
kleene_gather_bool (CArray *ca, boolean8_t *vbuf, boolean8_t *mbuf, ca_size_t n)
{
  if ( ca->elements == n ) {
    ca_copy_data(ca, (char *) vbuf);
    ca_update_mask(ca);
    if ( ca->mask ) {
      ca_copy_data(ca->mask, (char *) mbuf);
    }
    else {
      memset(mbuf, 0, n);
    }
  }
  else {                          /* scalar operand: gather one, broadcast */
    boolean8_t v = 0, m = 0;
    ca_copy_data(ca, (char *) &v);
    ca_update_mask(ca);
    if ( ca->mask ) {
      ca_copy_data(ca->mask, (char *) &m);
    }
    memset(vbuf, v, n);
    memset(mbuf, m, n);
  }
}

/* Kleene three-valued mask fixup for boolean AND (is_or=0) / OR (is_or=1).

   After the value-blind binop, a masked output cell can still be resolved by
   the *known* side: `unknown | true = true`, `unknown & false = false`.  This
   pass forces those cells to the known result and unmasks them; genuinely
   undetermined cells (U|U, U&U, U|F, U&T) keep the blind mask.  All other
   cells were already correct from the value kernel.

   Gate: boolean data type + output has a mask (else no-op -- the hot path is
   untouched, integer bitwise stays blind).  `out` is a fresh entity, so
   out->ptr / out->mask->ptr are writable without attach. */
VALUE
ca_kleene_bool_fixup (VALUE vout, VALUE vself, VALUE vother, int is_or)
{
  CArray *out, *a, *b;
  volatile VALUE va, vb;
  boolean8_t *ov, *om, *av, *am, *bv, *bm;
  ca_size_t n, i;

  TypedData_Get_Struct(vout, CArray, &carray_data_type, out);
  if ( out->data_type != CA_BOOLEAN ) {
    return vout;                       /* integer bitwise: blind, unchanged */
  }
  ca_update_mask(out);
  if ( ! out->mask ) {
    return vout;                       /* no undetermined cells to resolve */
  }

  /* Re-normalise the operands the same way rb_ca_call_binop did, so scalar /
     CScalar / view operands all present as boolean CArrays. */
  va = vself; vb = vother;
  rb_ca_cast_self_or_other(&va, &vb);
  TypedData_Get_Struct(va, CArray, &carray_data_type, a);
  TypedData_Get_Struct(vb, CArray, &carray_data_type, b);

  n  = out->elements;
  av = ALLOC_N(boolean8_t, n); am = ALLOC_N(boolean8_t, n);
  bv = ALLOC_N(boolean8_t, n); bm = ALLOC_N(boolean8_t, n);
  kleene_gather_bool(a, av, am, n);
  kleene_gather_bool(b, bv, bm, n);

  ov = (boolean8_t *) out->ptr;
  om = (boolean8_t *) out->mask->ptr;
  for (i = 0; i < n; i++) {
    if ( ! om[i] ) {
      continue;                        /* cell already determined */
    }
    if ( is_or ) {
      if ( ( ! am[i] && av[i] ) || ( ! bm[i] && bv[i] ) ) {     /* known TRUE */
        ov[i] = 1;
        om[i] = 0;
      }
    }
    else {
      if ( ( ! am[i] && ! av[i] ) || ( ! bm[i] && ! bv[i] ) ) { /* known FALSE */
        ov[i] = 0;
        om[i] = 0;
      }
    }
  }

  xfree(av); xfree(am); xfree(bv); xfree(bm);
  return vout;
}

/* Binop driver, split into fast / slow path.
   - fast: both operands alias-attachable (= entity / cscalar / contig
           CAStride) → 1-shot ca_attach_n + kernel call.
   - slow: at least one operand needs materialise → use ca_xfer_all to
           gather into ALLOCV scratch, never calling ca_func[X].attach
           on the operand.  Honors the core invariant "the driver does
           not attach an input-only operand", which keeps CAStack /
           CATile expansion, attach-hostile roots, and unattachable test
           fixtures working.
   Output `ca3` is always a new entity (write target, attach legitimate). */
VALUE
rb_ca_call_binop (volatile VALUE self, volatile VALUE other,
                                         ca_binop_func_t func[])
{
  volatile VALUE out;
  CArray *ca1, *ca2, *ca3; /* ca3 = ca1.op(ca2) */
  int self_is_scalar, other_is_scalar;
  ca_size_t n_kernel;
  ca_size_t i1, i2, i3;
  int fast_path;

  /* do implicit casting and resolving unbound repeat array */
  rb_ca_cast_self_or_other(&self, &other);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca1);
  TypedData_Get_Struct(other, CArray, &carray_data_type, ca2);

  /* Boolean-as-numeric promotion: an arithmetic op (+ - * / % ** ...) has
     no boolean kernel, so its func[CA_BOOLEAN] slot is ca_binop_not_implement.
     When both operands promoted to CA_BOOLEAN (= bool op bool), coerce them
     to CA_INT64 so `b1 + b2` behaves as its 0/1 numeric storage.  Signed
     (not the u64 used by bool reductions) because `b1 - b2` must reach -1.
     Logical ops (& | ^) DO have a boolean kernel, so this leaves them as
     bool.  A bool op numeric already promoted away from CA_BOOLEAN above. */
  if ( ca1->data_type == CA_BOOLEAN && func[CA_BOOLEAN] == ca_binop_not_implement ) {
    self  = rb_ca_wrap_readonly(self,  INT2NUM(CA_INT64));
    other = rb_ca_wrap_readonly(other, INT2NUM(CA_INT64));
    TypedData_Get_Struct(self,  CArray, &carray_data_type, ca1);
    TypedData_Get_Struct(other, CArray, &carray_data_type, ca2);
  }

  self_is_scalar  = RTEST(rb_obj_is_cscalar(self));
  other_is_scalar = RTEST(rb_obj_is_cscalar(other));

  /* output template + kernel n + strides (= preserve existing dispatch
     matrix: scalar×scalar / scalar×array / array×scalar / array×array) */
  if ( self_is_scalar && other_is_scalar ) {
    ca3 = ( ca_has_mask(ca1) || ca_has_mask(ca2) ) ? ca_template_safe(ca1)
                                                   : ca_template(ca1);
    n_kernel = ca1->elements;
    i1 = 0; i2 = 0; i3 = 0;
  }
  else if ( self_is_scalar /* && !other_is_scalar */ ) {
    ca3 = ( ca_has_mask(ca1) || ca_has_mask(ca2) ) ? ca_template_safe(ca2)
                                                   : ca_template(ca2);
    n_kernel = ca2->elements;
    i1 = 0; i2 = 1; i3 = 1;
  }
  else if ( other_is_scalar /* && !self_is_scalar */ ) {
    ca3 = ( ca_has_mask(ca1) || ca_has_mask(ca2) ) ? ca_template_safe(ca1)
                                                   : ca_template(ca1);
    n_kernel = ca1->elements;
    i1 = 1; i2 = 0; i3 = 1;
  }
  else {  /* array vs array */
    if ( ca1->elements != ca2->elements ) {
      rb_raise(rb_eRuntimeError, "elements mismatch (%" PRId64 " <-> %" PRId64 ")",
                                 (ca_size_t) ca1->elements,
                                 (ca_size_t) ca2->elements);
    }
    ca3 = ( ca_has_mask(ca1) || ca_has_mask(ca2) ) ? ca_template_safe(ca1)
                                                   : ca_template(ca1);
    n_kernel = ca1->elements;
    i1 = 1; i2 = 1; i3 = 1;
  }
  out = ca_wrap_struct(ca3);

  /* Mask overlay via the safe variant: materialises operand masks with
     ca_xfer_all instead of attaching them, so a mask on an attach-hostile
     input-only operand does not raise. */
  ca_mask_overlay_safe(ca3, 2, ca1, ca2);

  /* path decision: alias-attachable both → fast path */
  fast_path = ca_attach_is_alias(ca1) && ca_attach_is_alias(ca2);

  if ( fast_path ) {
    /* FAST PATH: zero behavioral change for the hot case. */
    ca_attach_n(2, ca1, ca2);
    func[ca1->data_type](n_kernel,
                         ( ca3->mask ) ? (boolean8_t *) ca3->mask->ptr : NULL,
                         ca1->ptr, i1,
                         ca2->ptr, i2,
                         ca3->ptr, i3);
    ca_detach_n(2, ca1, ca2);
  }
  else if ( ca1 == ca2 ) {
    /* SAME-OPERAND SHARING.  When the same view appears on both sides
       (`mt + mt`, `(view) < (view)` etc.), materialise once and share the
       scratch buffer between both kernel inputs.  When !fast_path &&
       ca1 == ca2, ca1 must be non-alias (if it were alias, fast_path would
       be true), so a single ALLOCV + ca_xfer_all suffices. */
    volatile VALUE h_shared = Qnil;
    char *p_shared;
    (void) h_shared;

    p_shared = ALLOCV_N(char, h_shared, ca1->elements * ca1->bytes);
    ca_xfer_all(ca1, p_shared, CA_XFER_GET);
    func[ca1->data_type](n_kernel,
                         ( ca3->mask ) ? (boolean8_t *) ca3->mask->ptr : NULL,
                         p_shared, i1,
                         p_shared, i2,
                         ca3->ptr, i3);
    ALLOCV_END(h_shared);
  }
  else {
    /* SLOW PATH (distinct operands): CHUNKED materialise via arena.
       Memory peak: O(operand_size) → O(chunk).  Per-operand decision:
       - i==0 scalar  → gather 1 element once (fixed, stride 0 in kernel)
       - alias array  → use ca->ptr + off*bytes (no copy, contig alias)
       - non-alias array → per-chunk gather into arena scratch

       Threshold dispatch: count the non-alias array operands.  If only 1
       needs per-chunk gather, chunking gives no memory-peak win (the other
       operand is already alias = no scratch) but pays per-iter dispatch
       overhead, so fall back to a 1-shot ALLOCV for that operand.  Only
       when both operands need gather (a structural 2x peak reduction) do
       we keep the chunked path.

       Decision matrix:
       - both array & both non-alias (= mt + mt2) → CHUNKED (peak 2x win)
       - one non-alias array + one alias/scalar (= mt + 3.14, mt + entity)
         → 1-shot ALLOCV  */
    char *p1_src = NULL, *p2_src = NULL;
    void *s1_arena = NULL, *s2_arena = NULL;
    int gather_per_chunk1 = 0, gather_per_chunk2 = 0;
    int attached1 = 0, attached2 = 0;
    int8_t dt = ca1->data_type;
    ca_size_t chunk_n;
    ca_size_t off;
    int nonalias_arrays;
    int use_chunked;

    nonalias_arrays = 0;
    if ( i1 == 1 && !ca_attach_is_alias(ca1) ) nonalias_arrays++;
    if ( i2 == 1 && !ca_attach_is_alias(ca2) ) nonalias_arrays++;
    use_chunked = (nonalias_arrays >= 2);

    /* Unified strided-walk path.  Eligibility: both operands are array
       (i==1) and at least one needs gather.  Each operand must compose to
       a ptr-bearing root,
       either as CAStride family (via ca_stride_compose_to_root) or as an
       entity (CA_OBJ_ARRAY / CA_OBJ_ARRAY_WRAP) treated as a view
       CAStride with row-major byte strides + base 0.  When eligible, walk
       per-row directly into the kernel and skip the chunked-gather / ALLOCV
       materialise pass — saves 2x bandwidth (no gather buffer write+read).
       Output ca3 is contig entity; per-row output offset = row_idx *
       inner_count.  The use_chunked / ALLOCV blocks below remain as a
       fallback (dead on the success path) but fire for views outside the
       CAStride+entity family (CASelect / CAMapping / CAReduce
       etc.). */
    if ( i1 == 1 && i2 == 1 && nonalias_arrays >= 1 ) {
      extern ca_operation_function_t ca_stride_func;
      CArray   *root1 = NULL, *root2 = NULL;
      ca_size_t strides1[CA_RANK_MAX], strides2[CA_RANK_MAX];
      ca_size_t base1 = 0, base2 = 0;
      int8_t    ndim = ca1->ndim;
      int8_t    k;
      int       ok = 1;

      /* operand 1: CAStride family -> compose, entity -> synthesize */
      if ( ca_func[ca1->obj_type].attach == ca_stride_func.attach ) {
        ca_stride_compose_to_root((CAStride *) ca1, &root1, strides1, &base1);
      }
      else if ( ca1->obj_type == CA_OBJ_ARRAY ||
                ca1->obj_type == CA_OBJ_ARRAY_WRAP ) {
        ca_size_t stride_bytes = ca1->bytes;
        root1 = ca1;
        base1 = 0;
        for ( k = ca1->ndim - 1; k >= 0; k-- ) {
          strides1[k] = stride_bytes;
          stride_bytes *= ca1->dim[k];
        }
      }
      else ok = 0;

      if ( ok ) {
        if ( ca_func[ca2->obj_type].attach == ca_stride_func.attach ) {
          ca_stride_compose_to_root((CAStride *) ca2, &root2, strides2, &base2);
        }
        else if ( ca2->obj_type == CA_OBJ_ARRAY ||
                  ca2->obj_type == CA_OBJ_ARRAY_WRAP ) {
          ca_size_t stride_bytes = ca2->bytes;
          root2 = ca2;
          base2 = 0;
          for ( k = ca2->ndim - 1; k >= 0; k-- ) {
            strides2[k] = stride_bytes;
            stride_bytes *= ca2->dim[k];
          }
        }
        else ok = 0;
      }

      if ( ok ) {
        if ( !root1->ptr || !root2->ptr ) ok = 0;
        if ( ca2->ndim != ndim ) ok = 0;

        /* element-stride conversion: strides must be byte-multiples of bytes */
        if ( ok ) {
          for ( k = 0; k < ndim; k++ ) {
            if ( strides1[k] % ca1->bytes != 0 ) { ok = 0; break; }
            if ( strides2[k] % ca2->bytes != 0 ) { ok = 0; break; }
          }
        }
        if ( ok && (base1 % ca1->bytes != 0 || base2 % ca2->bytes != 0) ) ok = 0;
      }

      if ( ok ) {
        int8_t    inner_axis = ndim - 1;
        ca_size_t inner_n = (ndim >= 1) ? ca1->dim[inner_axis] : ca1->elements;
        ca_size_t s1_inner = (ndim >= 1) ? strides1[inner_axis] / ca1->bytes : 1;
        ca_size_t s2_inner = (ndim >= 1) ? strides2[inner_axis] / ca2->bytes : 1;
        ca_size_t idx[CA_RANK_MAX];
        ca_size_t out_off = 0;
        ca_size_t e1_strides[CA_RANK_MAX], e2_strides[CA_RANK_MAX];
        ca_size_t e1_base, e2_base;
        char     *p1_root, *p2_root;

        for ( k = 0; k < ndim; k++ ) {
          e1_strides[k] = strides1[k] / ca1->bytes;
          e2_strides[k] = strides2[k] / ca2->bytes;
        }
        e1_base = base1 / ca1->bytes;
        e2_base = base2 / ca2->bytes;
        p1_root = (char *) root1->ptr;
        p2_root = (char *) root2->ptr;

        for ( k = 0; k < ndim; k++ ) idx[k] = 0;

        if ( ndim == 0 || ndim == 1 ) {
          ca_size_t n_call = (ndim == 0) ? 1 : inner_n;
          func[dt](n_call,
                   ( ca3->mask ) ? (boolean8_t *) ca3->mask->ptr : NULL,
                   p1_root + e1_base * ca1->bytes, (ndim == 0) ? 0 : s1_inner,
                   p2_root + e2_base * ca2->bytes, (ndim == 0) ? 0 : s2_inner,
                   ca3->ptr, i3);
        }
        else {
          while ( 1 ) {
            ca_size_t off1 = e1_base, off2 = e2_base;
            for ( k = 0; k < ndim - 1; k++ ) {
              off1 += idx[k] * e1_strides[k];
              off2 += idx[k] * e2_strides[k];
            }
            func[dt](inner_n,
                     ca3->mask
                       ? ((boolean8_t *) ca3->mask->ptr) + out_off
                       : NULL,
                     p1_root + off1 * ca1->bytes, s1_inner,
                     p2_root + off2 * ca2->bytes, s2_inner,
                     (char *) ca3->ptr + out_off * ca3->bytes, i3);
            out_off += inner_n;
            k = ndim - 2;
            while ( k >= 0 ) {
              if ( ++idx[k] < ca1->dim[k] ) break;
              idx[k] = 0; k--;
            }
            if ( k < 0 ) break;
          }
        }

        return out;
      }
      /* else fall through to the use_chunked / ALLOCV path */
    }

    if ( !use_chunked ) {
      /* 1-shot ALLOCV path.  At most 1 operand needs ALLOCV; the other is
         alias-direct. */
      volatile VALUE h1 = Qnil, h2 = Qnil;
      char *p1, *p2;
      int a1 = 0, a2 = 0;
      (void) h1; (void) h2;

      if ( ca_attach_is_alias(ca1) ) {
        ca_attach(ca1);  p1 = (char *) ca1->ptr;  a1 = 1;
      } else {
        p1 = ALLOCV_N(char, h1, ca1->elements * ca1->bytes);
        ca_xfer_all(ca1, p1, CA_XFER_GET);
      }
      if ( ca_attach_is_alias(ca2) ) {
        ca_attach(ca2);  p2 = (char *) ca2->ptr;  a2 = 1;
      } else {
        p2 = ALLOCV_N(char, h2, ca2->elements * ca2->bytes);
        ca_xfer_all(ca2, p2, CA_XFER_GET);
      }

      func[dt](n_kernel,
               ( ca3->mask ) ? (boolean8_t *) ca3->mask->ptr : NULL,
               p1, i1,
               p2, i2,
               ca3->ptr, i3);

      if ( a2 ) { ca_detach(ca2); } else { ALLOCV_END(h2); }
      if ( a1 ) { ca_detach(ca1); } else { ALLOCV_END(h1); }

      return out;
    }

    /* Compute chunk_n: target ~32KB worth of cells, row-aligned to the
       larger-inner operand's outer axis. */
    {
      ca_size_t inner = 1;
      ca_size_t maxb = ca1->bytes > ca2->bytes ? ca1->bytes : ca2->bytes;
      if (ca3->bytes > maxb) maxb = ca3->bytes;
      if (i1 == 1) inner = ca_chunk_inner_size(ca1);
      if (i2 == 1) {
        ca_size_t inner2 = ca_chunk_inner_size(ca2);
        if (inner2 > inner) inner = inner2;
      }
      chunk_n = ca_chunk_compute_n(n_kernel, inner, maxb);
    }

    ca_lazy_arena_enter();

    /* ca1 acquire */
    if ( i1 == 0 ) {
      /* scalar: gather 1 element once, kernel re-reads with stride 0 */
      if ( ca_attach_is_alias(ca1) ) {
        ca_attach(ca1);
        p1_src = (char *) ca1->ptr;
        attached1 = 1;
      } else {
        s1_arena = ca_lazy_arena_acquire(ca1->bytes);
        ca_xfer_all(ca1, s1_arena, CA_XFER_GET);
        p1_src = (char *) s1_arena;
      }
    } else if ( ca_attach_is_alias(ca1) ) {
      ca_attach(ca1);
      p1_src = (char *) ca1->ptr;
      attached1 = 1;
    } else {
      s1_arena = ca_lazy_arena_acquire(chunk_n * ca1->bytes);
      p1_src = (char *) s1_arena;
      gather_per_chunk1 = 1;
    }

    /* ca2 acquire (mirror) */
    if ( i2 == 0 ) {
      if ( ca_attach_is_alias(ca2) ) {
        ca_attach(ca2);
        p2_src = (char *) ca2->ptr;
        attached2 = 1;
      } else {
        s2_arena = ca_lazy_arena_acquire(ca2->bytes);
        ca_xfer_all(ca2, s2_arena, CA_XFER_GET);
        p2_src = (char *) s2_arena;
      }
    } else if ( ca_attach_is_alias(ca2) ) {
      ca_attach(ca2);
      p2_src = (char *) ca2->ptr;
      attached2 = 1;
    } else {
      s2_arena = ca_lazy_arena_acquire(chunk_n * ca2->bytes);
      p2_src = (char *) s2_arena;
      gather_per_chunk2 = 1;
    }

    /* chunk loop: walk n_kernel cells in chunk_n strides */
    for ( off = 0; off < n_kernel; off += chunk_n ) {
      ca_size_t n_done = (off + chunk_n > n_kernel) ? n_kernel - off : chunk_n;
      char *p1, *p2;

      if ( gather_per_chunk1 ) {
        ca_chunked_gather(ca1, off, n_done, s1_arena);
        p1 = (char *) s1_arena;
      } else {
        p1 = p1_src + (i1 ? off * ca1->bytes : 0);
      }
      if ( gather_per_chunk2 ) {
        ca_chunked_gather(ca2, off, n_done, s2_arena);
        p2 = (char *) s2_arena;
      } else {
        p2 = p2_src + (i2 ? off * ca2->bytes : 0);
      }

      func[dt](n_done,
               ca3->mask ? ((boolean8_t *) ca3->mask->ptr) + (i3 ? off : 0)
                         : NULL,
               p1, i1,
               p2, i2,
               (char *) ca3->ptr + (i3 ? off * ca3->bytes : 0), i3);
    }

    if ( s2_arena ) ca_lazy_arena_release(s2_arena);
    if ( s1_arena ) ca_lazy_arena_release(s1_arena);
    if ( attached2 ) ca_detach(ca2);
    if ( attached1 ) ca_detach(ca1);

    ca_lazy_arena_exit();
  }

  return out;
}

/* Bang (in-place) variant.  Invariant: the input-only operand (= other)
   must not be attached; self IS the output (write target, attach
   legitimate).  Same fast/slow pattern as rb_ca_call_binop, applied to
   `other` only.
   self always goes through ca_attach + ca_sync (= write-back to root). */
VALUE
rb_ca_call_binop_bang (VALUE self, VALUE other, ca_binop_func_t func[])
{
  CArray *ca1, *ca2;   /* ca1.op!(ca2) */
  int self_is_scalar, other_is_scalar;
  ca_size_t i1, i2;

  rb_ca_modify(self);

  /* do implicit casting and resolving unbound repeat array */
  rb_ca_cast_other(&self, &other);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca1);
  TypedData_Get_Struct(other, CArray, &carray_data_type, ca2);

  self_is_scalar  = RTEST(rb_obj_is_cscalar(self));
  other_is_scalar = RTEST(rb_obj_is_cscalar(other));

  /* self is the write target, so its shape is the result's by definition
     and the destination rule applies (the same one assignment uses), not
     the symmetric one a binary operation is held to. */
  if ( !self_is_scalar && !other_is_scalar ) {
    ca_broadcast_to_destination(self, &other);
    TypedData_Get_Struct(other, CArray, &carray_data_type, ca2);
    other_is_scalar = RTEST(rb_obj_is_cscalar(other));
  }
  if ( self_is_scalar && !other_is_scalar &&
       ca1->elements != ca2->elements ) {
    rb_raise(rb_eRuntimeError, "elements mismatch (%" PRId64 " <-> %" PRId64 ")",
                               (ca_size_t) ca1->elements,
                               (ca_size_t) ca2->elements);
  }

  /* kernel strides: cscalar → 0 (broadcast).  ca1 is both src1 (input)
     and dst (output), same stride.  ca2 is input only. */
  i1 = self_is_scalar  ? 0 : 1;
  i2 = other_is_scalar ? 0 : 1;

  /* self IS the output (= write target).  Always attach + ca_sync
     (= legitimate per refined invariant; self can be view e.g.
     `arr[i,nil].add!(b)`, sync writes back to root). */
  ca_attach(ca1);
  ca_mask_overlay_safe(ca1, 2, ca1, ca2);

  /* other is input only: fast path if alias-cheap, else materialise
     via ca_xfer_all without ca_func[X].attach. */
  if ( ca_attach_is_alias(ca2) ) {
    ca_attach(ca2);
    func[ca1->data_type](ca1->elements,
                         ( ca1->mask ) ? (boolean8_t *) ca1->mask->ptr : NULL,
                         ca1->ptr, i1,
                         ca2->ptr, i2,
                         ca1->ptr, i1);
    ca_detach(ca2);
  }
  else {
    volatile VALUE h2 = Qnil;
    char *p2;
    (void) h2;
    p2 = ALLOCV_N(char, h2, ca2->elements * ca2->bytes);
    ca_xfer_all(ca2, p2, CA_XFER_GET);
    func[ca1->data_type](ca1->elements,
                         ( ca1->mask ) ? (boolean8_t *) ca1->mask->ptr : NULL,
                         ca1->ptr, i1,
                         p2,       i2,
                         ca1->ptr, i1);
    ALLOCV_END(h2);
  }

  ca_sync(ca1);
  ca_detach(ca1);

  return self;
}

/* ------------------------------------------------------------------- */
/* Triop driver — 3 inputs, 1 output, eager-only.                       */
/*                                                                       */
/* Approach: instead of enumerating the 2^3 = 8 scalar/array combos in   */
/* line as `rb_ca_call_binop` does, we reuse `ca_set_iterator(3, ...)`   */
/* from carray_call_cfunc.c which collapses any operand with             */
/* `is_scalar == true` to a stride-0 walker.  Same uniform inner loop    */
/* for all 8 cases.  Output is templated from the first non-scalar       */
/* operand (or self if all are scalar).                                  */
/* ------------------------------------------------------------------- */

static VALUE
rb_ca_triop_select_template (VALUE self, VALUE other2, VALUE other3,
                             CArray *ca1, CArray *ca2, CArray *ca3)
{
  /* Template from the first non-scalar operand; fall back to self if
     all three are scalars.  Mask is allocated when any operand has
     a mask.                                                          */
  int has_mask = ca_has_mask(ca1) || ca_has_mask(ca2) || ca_has_mask(ca3);
  CArray *src;
  if      ( ! rb_obj_is_cscalar(self)   ) src = ca1;
  else if ( ! rb_obj_is_cscalar(other2) ) src = ca2;
  else if ( ! rb_obj_is_cscalar(other3) ) src = ca3;
  else                                    src = ca1;
  return has_mask ? ca_wrap_struct(ca_template_safe(src))
                  : ca_wrap_struct(ca_template(src));
}

/* Per-operand acquire/release macros for input-only operands.  Used by
   the triop / bincmp drivers where 3 inputs make inline branching
   unwieldy.

   - alias-cheap operand → ca_attach (= O(1)) + use ca->ptr directly
   - else → ALLOCV scratch + ca_xfer_all without ca_func[X].attach

   Pair ACQUIRE / RELEASE; `h` must be a volatile VALUE declared by
   caller (= ALLOCV_END requires it even on alias-cheap branch where
   ALLOCV_N wasn't actually called, since holder stays Qnil = no-op). */
#define EAGER_ACQUIRE_INPUT(ca_, p_, h_, attached_) do {              \
    if ( ca_attach_is_alias(ca_) ) {                                  \
      ca_attach(ca_);                                                 \
      (p_) = (char *)(ca_)->ptr;                                      \
      (attached_) = 1;                                                \
    }                                                                 \
    else {                                                            \
      (p_) = ALLOCV_N(char, (h_), (ca_)->elements * (ca_)->bytes);    \
      ca_xfer_all((ca_), (p_), CA_XFER_GET);                          \
      (attached_) = 0;                                                \
    }                                                                 \
  } while (0)

#define EAGER_RELEASE_INPUT(ca_, h_, attached_) do {                  \
    if ( (attached_) ) { ca_detach(ca_); }                            \
    else { ALLOCV_END(h_); }                                          \
  } while (0)

/* triop driver.  3 inputs are input-only (the driver does not attach
   them); cao = new entity output (attach is legit).  Each input
   independently uses fast (= alias) or slow (= ALLOCV + ca_xfer_all)
   path. */
VALUE
rb_ca_call_triop (VALUE self, VALUE other2, VALUE other3,
                  ca_triop_func_t func[])
{
  volatile VALUE out;
  CArray *ca1, *ca2, *ca3, *cao;

  /* Pairwise data_type promotion: ((self, other2) -> common), then
     ((self', other3) -> common).  Mirrors how the binop driver normalises
     two operands; for triop we apply it twice.  After this, all three
     CArrays share the same data_type (and unbound-repeats are resolved). */
  rb_ca_cast_self_or_other(&self, &other2);
  rb_ca_cast_self_or_other(&self, &other3);
  rb_ca_cast_self_or_other(&other2, &other3);
  /* one more pass to re-normalise self vs other2 in case the
     other2/other3 cast widened other2 above self's data_type  */
  rb_ca_cast_self_or_other(&self, &other2);

  TypedData_Get_Struct(self,   CArray, &carray_data_type, ca1);
  TypedData_Get_Struct(other2, CArray, &carray_data_type, ca2);
  TypedData_Get_Struct(other3, CArray, &carray_data_type, ca3);

  /* Boolean-as-numeric promotion (same rule as rb_ca_call_binop): an
     arithmetic triop (fma / fms) has no boolean kernel, so its
     func[CA_BOOLEAN] slot is ca_triop_not_implement.  When all three
     operands promoted to CA_BOOLEAN (= every operand boolean), coerce
     them to CA_INT64 so `a * b + c` behaves as their 0/1 numeric storage
     (signed, so a product/sum can reach negative in fms).  A boolean
     mixed with a numeric already promoted away from CA_BOOLEAN via the
     pairwise casts above. */
  if ( ca1->data_type == CA_BOOLEAN && func[CA_BOOLEAN] == ca_triop_not_implement ) {
    self   = rb_ca_wrap_readonly(self,   INT2NUM(CA_INT64));
    other2 = rb_ca_wrap_readonly(other2, INT2NUM(CA_INT64));
    other3 = rb_ca_wrap_readonly(other3, INT2NUM(CA_INT64));
    TypedData_Get_Struct(self,   CArray, &carray_data_type, ca1);
    TypedData_Get_Struct(other2, CArray, &carray_data_type, ca2);
    TypedData_Get_Struct(other3, CArray, &carray_data_type, ca3);
  }

  /* Element-count check: all non-scalar operands must agree.            */
  {
    ca_size_t n = 1;
    if ( ! rb_obj_is_cscalar(self)   ) n = ca1->elements;
    if ( ! rb_obj_is_cscalar(other2) ) {
      if ( n == 1 ) n = ca2->elements;
      else if ( ca2->elements != n ) {
        rb_raise(rb_eRuntimeError, "elements mismatch in triop (op2: %" PRId64 " != %" PRId64 ")",
                 (ca_size_t) ca2->elements, n);
      }
    }
    if ( ! rb_obj_is_cscalar(other3) ) {
      if ( n == 1 ) n = ca3->elements;
      else if ( ca3->elements != n ) {
        rb_raise(rb_eRuntimeError, "elements mismatch in triop (op3: %" PRId64 " != %" PRId64 ")",
                 (ca_size_t) ca3->elements, n);
      }
    }
  }

  out = rb_ca_triop_select_template(self, other2, other3, ca1, ca2, ca3);
  TypedData_Get_Struct(out, CArray, &carray_data_type, cao);

  ca_mask_overlay_safe(cao, 3, ca1, ca2, ca3);

  {
    ca_size_t s1 = rb_obj_is_cscalar(self)   ? 0 : 1;
    ca_size_t s2 = rb_obj_is_cscalar(other2) ? 0 : 1;
    ca_size_t s3 = rb_obj_is_cscalar(other3) ? 0 : 1;

    /* Binop-style threshold dispatch: count non-alias array operands;
       >= 2 → CHUNKED (memory peak amortizes), else 1-shot ALLOCV.  3-way
       same-operand sharing is not done (a rare pattern like `fma(a, a, b)`;
       for now a non-alias `a` is gathered twice — wasteful but correct). */
    int nonalias_arrays = 0;
    int use_chunked;
    if ( s1 == 1 && !ca_attach_is_alias(ca1) ) nonalias_arrays++;
    if ( s2 == 1 && !ca_attach_is_alias(ca2) ) nonalias_arrays++;
    if ( s3 == 1 && !ca_attach_is_alias(ca3) ) nonalias_arrays++;
    use_chunked = (nonalias_arrays >= 2);

    if ( !use_chunked ) {
      volatile VALUE h1 = Qnil, h2 = Qnil, h3 = Qnil;
      char *p1, *p2, *p3;
      int attached1, attached2, attached3;
      (void) h1; (void) h2; (void) h3;

      EAGER_ACQUIRE_INPUT(ca1, p1, h1, attached1);
      EAGER_ACQUIRE_INPUT(ca2, p2, h2, attached2);
      EAGER_ACQUIRE_INPUT(ca3, p3, h3, attached3);

      func[ca1->data_type](cao->elements,
                           ( cao->mask ) ? (boolean8_t *) cao->mask->ptr : NULL,
                           p1, s1,
                           p2, s2,
                           p3, s3,
                           cao->ptr, 1);

      EAGER_RELEASE_INPUT(ca3, h3, attached3);
      EAGER_RELEASE_INPUT(ca2, h2, attached2);
      EAGER_RELEASE_INPUT(ca1, h1, attached1);
    }
    else {
      /* CHUNKED PATH: per-operand decision matrix (the binop pattern
         extended to 3 inputs).  scalar/alias same as before; non-alias
         array goes through per-chunk gather. */
      char *p1_src = NULL, *p2_src = NULL, *p3_src = NULL;
      void *s1_arena = NULL, *s2_arena = NULL, *s3_arena = NULL;
      int gpc1 = 0, gpc2 = 0, gpc3 = 0;  /* gather-per-chunk flags */
      int att1 = 0, att2 = 0, att3 = 0;
      int8_t dt = ca1->data_type;
      ca_size_t chunk_n;
      ca_size_t off;
      ca_size_t n_total = cao->elements;

      {
        ca_size_t inner = 1;
        ca_size_t maxb = ca1->bytes;
        if ( ca2->bytes > maxb ) maxb = ca2->bytes;
        if ( ca3->bytes > maxb ) maxb = ca3->bytes;
        if ( cao->bytes > maxb ) maxb = cao->bytes;
        if ( s1 == 1 ) inner = ca_chunk_inner_size(ca1);
        if ( s2 == 1 ) {
          ca_size_t inn = ca_chunk_inner_size(ca2);
          if ( inn > inner ) inner = inn;
        }
        if ( s3 == 1 ) {
          ca_size_t inn = ca_chunk_inner_size(ca3);
          if ( inn > inner ) inner = inn;
        }
        chunk_n = ca_chunk_compute_n(n_total, inner, maxb);
      }

      ca_lazy_arena_enter();

      /* ca1 acquire */
      if ( s1 == 0 ) {
        if ( ca_attach_is_alias(ca1) ) {
          ca_attach(ca1);  p1_src = (char *) ca1->ptr;  att1 = 1;
        } else {
          s1_arena = ca_lazy_arena_acquire(ca1->bytes);
          ca_xfer_all(ca1, s1_arena, CA_XFER_GET);
          p1_src = (char *) s1_arena;
        }
      } else if ( ca_attach_is_alias(ca1) ) {
        ca_attach(ca1);  p1_src = (char *) ca1->ptr;  att1 = 1;
      } else {
        s1_arena = ca_lazy_arena_acquire(chunk_n * ca1->bytes);
        p1_src = (char *) s1_arena;  gpc1 = 1;
      }
      /* ca2 acquire (mirror) */
      if ( s2 == 0 ) {
        if ( ca_attach_is_alias(ca2) ) {
          ca_attach(ca2);  p2_src = (char *) ca2->ptr;  att2 = 1;
        } else {
          s2_arena = ca_lazy_arena_acquire(ca2->bytes);
          ca_xfer_all(ca2, s2_arena, CA_XFER_GET);
          p2_src = (char *) s2_arena;
        }
      } else if ( ca_attach_is_alias(ca2) ) {
        ca_attach(ca2);  p2_src = (char *) ca2->ptr;  att2 = 1;
      } else {
        s2_arena = ca_lazy_arena_acquire(chunk_n * ca2->bytes);
        p2_src = (char *) s2_arena;  gpc2 = 1;
      }
      /* ca3 acquire (mirror) */
      if ( s3 == 0 ) {
        if ( ca_attach_is_alias(ca3) ) {
          ca_attach(ca3);  p3_src = (char *) ca3->ptr;  att3 = 1;
        } else {
          s3_arena = ca_lazy_arena_acquire(ca3->bytes);
          ca_xfer_all(ca3, s3_arena, CA_XFER_GET);
          p3_src = (char *) s3_arena;
        }
      } else if ( ca_attach_is_alias(ca3) ) {
        ca_attach(ca3);  p3_src = (char *) ca3->ptr;  att3 = 1;
      } else {
        s3_arena = ca_lazy_arena_acquire(chunk_n * ca3->bytes);
        p3_src = (char *) s3_arena;  gpc3 = 1;
      }

      for ( off = 0; off < n_total; off += chunk_n ) {
        ca_size_t n_done = (off + chunk_n > n_total) ? n_total - off
                                                     : chunk_n;
        char *p1, *p2, *p3;

        if ( gpc1 ) { ca_chunked_gather(ca1, off, n_done, s1_arena);
                      p1 = (char *) s1_arena; }
        else        { p1 = p1_src + (s1 ? off * ca1->bytes : 0); }
        if ( gpc2 ) { ca_chunked_gather(ca2, off, n_done, s2_arena);
                      p2 = (char *) s2_arena; }
        else        { p2 = p2_src + (s2 ? off * ca2->bytes : 0); }
        if ( gpc3 ) { ca_chunked_gather(ca3, off, n_done, s3_arena);
                      p3 = (char *) s3_arena; }
        else        { p3 = p3_src + (s3 ? off * ca3->bytes : 0); }

        func[dt](n_done,
                 cao->mask ? ((boolean8_t *) cao->mask->ptr) + off
                           : NULL,
                 p1, s1,
                 p2, s2,
                 p3, s3,
                 (char *) cao->ptr + off * cao->bytes, 1);
      }

      if ( s3_arena ) ca_lazy_arena_release(s3_arena);
      if ( s2_arena ) ca_lazy_arena_release(s2_arena);
      if ( s1_arena ) ca_lazy_arena_release(s1_arena);
      if ( att3 ) ca_detach(ca3);
      if ( att2 ) ca_detach(ca2);
      if ( att1 ) ca_detach(ca1);

      ca_lazy_arena_exit();
    }
  }

  return out;
}

/* triop_bang (in-place) driver.  ca1 = self = output (write target,
   attach legit; keep ca_attach + ca_sync); ca2/ca3 = input only (fast/slow
   dispatch via EAGER_ACQUIRE/RELEASE). */
VALUE
rb_ca_call_triop_bang (VALUE self, VALUE other2, VALUE other3,
                       ca_triop_func_t func[])
{
  CArray *ca1, *ca2, *ca3;

  rb_ca_modify(self);

  rb_ca_cast_other(&self, &other2);
  rb_ca_cast_other(&self, &other3);

  TypedData_Get_Struct(self,   CArray, &carray_data_type, ca1);
  TypedData_Get_Struct(other2, CArray, &carray_data_type, ca2);
  TypedData_Get_Struct(other3, CArray, &carray_data_type, ca3);

  /* self is the write target, so the destination rule applies to each
     input operand in turn (the same one assignment uses). */
  if ( ! rb_obj_is_cscalar(other2) ) {
    ca_broadcast_to_destination(self, &other2);
    TypedData_Get_Struct(other2, CArray, &carray_data_type, ca2);
  }
  if ( ! rb_obj_is_cscalar(other3) ) {
    ca_broadcast_to_destination(self, &other3);
    TypedData_Get_Struct(other3, CArray, &carray_data_type, ca3);
  }

  /* self IS the output (= write target; attach legit per refined invariant) */
  ca_attach(ca1);
  ca_mask_overlay_safe(ca1, 3, ca1, ca2, ca3);

  {
    ca_size_t s2 = rb_obj_is_cscalar(other2) ? 0 : 1;
    ca_size_t s3 = rb_obj_is_cscalar(other3) ? 0 : 1;

    /* Threshold dispatch on the input-only operands (ca2 / ca3).  Self
       (ca1) IS the output (attached + ca_sync as usual).  >= 2 non-alias
       input arrays → chunked, else 1-shot ALLOCV. */
    int nonalias_arrays = 0;
    int use_chunked;
    if ( s2 == 1 && !ca_attach_is_alias(ca2) ) nonalias_arrays++;
    if ( s3 == 1 && !ca_attach_is_alias(ca3) ) nonalias_arrays++;
    use_chunked = (nonalias_arrays >= 2);

    if ( !use_chunked ) {
      volatile VALUE h2 = Qnil, h3 = Qnil;
      char *p2, *p3;
      int attached2, attached3;
      (void) h2; (void) h3;

      EAGER_ACQUIRE_INPUT(ca2, p2, h2, attached2);
      EAGER_ACQUIRE_INPUT(ca3, p3, h3, attached3);

      func[ca1->data_type](ca1->elements,
                           ( ca1->mask ) ? (boolean8_t *) ca1->mask->ptr : NULL,
                           ca1->ptr, 1,
                           p2, s2,
                           p3, s3,
                           ca1->ptr, 1);

      EAGER_RELEASE_INPUT(ca3, h3, attached3);
      EAGER_RELEASE_INPUT(ca2, h2, attached2);
    }
    else {
      /* CHUNKED PATH: both ca2 and ca3 non-alias arrays.  ca1 (= self =
         output) is already attached; its ptr is contig (= ca_attach
         materialise + alias for entity, or full materialise for view).
         Write to ca1->ptr + off*bytes in chunks; sync at end. */
      void *s2_arena = NULL, *s3_arena = NULL;
      int8_t dt = ca1->data_type;
      ca_size_t chunk_n;
      ca_size_t off;
      ca_size_t n_total = ca1->elements;

      {
        ca_size_t inner = ca_chunk_inner_size(ca1);
        ca_size_t inn2 = ca_chunk_inner_size(ca2);
        ca_size_t inn3 = ca_chunk_inner_size(ca3);
        ca_size_t maxb = ca1->bytes;
        if ( ca2->bytes > maxb ) maxb = ca2->bytes;
        if ( ca3->bytes > maxb ) maxb = ca3->bytes;
        if ( inn2 > inner ) inner = inn2;
        if ( inn3 > inner ) inner = inn3;
        chunk_n = ca_chunk_compute_n(n_total, inner, maxb);
      }

      ca_lazy_arena_enter();
      s2_arena = ca_lazy_arena_acquire(chunk_n * ca2->bytes);
      s3_arena = ca_lazy_arena_acquire(chunk_n * ca3->bytes);

      for ( off = 0; off < n_total; off += chunk_n ) {
        ca_size_t n_done = (off + chunk_n > n_total) ? n_total - off
                                                     : chunk_n;
        ca_chunked_gather(ca2, off, n_done, s2_arena);
        ca_chunked_gather(ca3, off, n_done, s3_arena);

        func[dt](n_done,
                 ca1->mask ? ((boolean8_t *) ca1->mask->ptr) + off
                           : NULL,
                 (char *) ca1->ptr + off * ca1->bytes, 1,
                 (char *) s2_arena, s2,
                 (char *) s3_arena, s3,
                 (char *) ca1->ptr + off * ca1->bytes, 1);
      }

      ca_lazy_arena_release(s3_arena);
      ca_lazy_arena_release(s2_arena);
      ca_lazy_arena_exit();
    }
  }

  ca_sync(ca1);
  ca_detach(ca1);

  return self;
}

/* moncmp driver.  ca1 input-only (EAGER_ACQUIRE/RELEASE fast/slow), ca2 =
   new boolean entity output (attach legit). */
VALUE
rb_ca_call_moncmp (VALUE self, ca_moncmp_func_t func[])
{
  volatile VALUE out;
  CArray *ca1, *ca2;    /* ca2 = ca1.op */

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca1);

  if ( ca_is_scalar(ca1) ) {
    out = rb_cscalar_new(CA_BOOLEAN, 0, NULL);
  }
  else {
    out = rb_carray_new(CA_BOOLEAN, ca1->ndim, ca1->dim, 0, NULL);
  }

  TypedData_Get_Struct(out, CArray, &carray_data_type, ca2);

  ca_mask_overlay_safe(ca2, 1, ca1);

  /* The kernel's masked branch skips masked cells, so they would keep the
     uninitialised data from rb_carray_new.  Zero the output when a mask is
     present so masked cells read as 0 (matching binop's ca_template_safe
     convention) instead of exposing uninitialised memory. */
  if ( ca2->mask ) {
    MEMZERO(ca2->ptr, char, ca2->elements * ca2->bytes);
  }

  {
    volatile VALUE h1 = Qnil;
    char *p1;
    int attached1;
    (void) h1;

    EAGER_ACQUIRE_INPUT(ca1, p1, h1, attached1);
    func[ca1->data_type](ca1->elements,
                         ( ca2->mask ) ? (boolean8_t *) ca2->mask->ptr : NULL,
                         p1, 1,
                         (boolean8_t *) ca2->ptr, 1);
    EAGER_RELEASE_INPUT(ca1, h1, attached1);
  }

  return out;
}


/* ca_bincmp_eq / ca_bincmp_ne are declared (correctly typed) in
   ca_bincmp_dispatch.h, reached via the carray.h umbrella.  The
   UNDEF-comparison identity checks below cast to ca_bincmp_func_t
   explicitly. */

VALUE
rb_ca_call_bincmp (volatile VALUE self, volatile VALUE other,
                                    ca_bincmp_func_t func[],
                                    double tol)
{
  volatile VALUE out = Qnil;
  CArray *ca1, *ca2, *ca3;  /* ca3 = ca1.op(ca2) */

  /* check for comparison with CA_UNDEF */
  if ( other == CA_UNDEF ) {
    if ( (ca_bincmp_func_t) func == (ca_bincmp_func_t) ca_bincmp_eq ) {  /* a.eq(UNDEF) -> a.is_masked */
      return rb_ca_is_masked(self);
    }
    else if ( (ca_bincmp_func_t) func == (ca_bincmp_func_t) ca_bincmp_ne ) { /* a.ne(UNDEF) -> a.is_not_masked */
      return rb_ca_is_not_masked(self);
    }
    else {
      rb_raise(rb_eRuntimeError, "array can not be compared with UNDEF");
    }
  }

  /* Face gate: an ORDERABLE Face over numeric storage descends to storage
     (fixing the surface-fixlen memcmp mis-order) and reconciles a Face RHS
     via to_comparable (e.g. unit alignment).  No-op for non-Face self and
     for fixlen-storage Faces (memcmp is already correct there). */
  ca_face_reconcile_comparison(&self, &other);

  /* do implicit casting and resolving unbound repeat array */
  rb_ca_cast_self_or_other(&self, &other);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca1);
  TypedData_Get_Struct(other, CArray, &carray_data_type, ca2);

  /* Same fast/slow shape as rb_ca_call_binop, but the output data_type is
     fixed boolean (rb_ca_call_binop's output data_type matches its input). */
  {
    int self_is_scalar  = RTEST(rb_obj_is_cscalar(self));
    int other_is_scalar = RTEST(rb_obj_is_cscalar(other));
    ca_size_t n_kernel, i1, i2, i3;

    if ( self_is_scalar && other_is_scalar ) {
      out = rb_cscalar_new(CA_BOOLEAN, 0, NULL);
      n_kernel = ca1->elements; i1 = 0; i2 = 0; i3 = 0;
    }
    else if ( self_is_scalar /* && !other_is_scalar */ ) {
      out = rb_carray_new(CA_BOOLEAN, ca2->ndim, ca2->dim, 0, NULL);
      n_kernel = ca2->elements; i1 = 0; i2 = 1; i3 = 1;
    }
    else if ( other_is_scalar /* && !self_is_scalar */ ) {
      out = rb_carray_new(CA_BOOLEAN, ca1->ndim, ca1->dim, 0, NULL);
      n_kernel = ca1->elements; i1 = 1; i2 = 0; i3 = 1;
    }
    else {
      if ( ca1->elements != ca2->elements ) {
        rb_raise(rb_eRuntimeError, "elements mismatch in bincmp (%" PRId64 " <-> %" PRId64 ")",
                                   (ca_size_t) ca1->elements,
                                   (ca_size_t) ca2->elements);
      }
      out = rb_carray_new(CA_BOOLEAN, ca1->ndim, ca1->dim, 0, NULL);
      n_kernel = ca1->elements; i1 = 1; i2 = 1; i3 = 1;
    }
    TypedData_Get_Struct(out, CArray, &carray_data_type, ca3);

    ca_mask_overlay_safe(ca3, 2, ca1, ca2);

    /* The kernel's masked branch skips masked cells, so they would keep the
       uninitialised data from rb_carray_new.  Zero the output when a mask is
       present so masked cells read as 0 (matching binop's ca_template_safe
       convention) instead of exposing uninitialised memory. */
    if ( ca3->mask ) {
      MEMZERO(ca3->ptr, char, ca3->elements * ca3->bytes);
    }

    /* SAME-OPERAND SHARING: prevents materialising the same view twice in
       cases like `view < view`. */
    if ( ca1 == ca2 && !ca_attach_is_alias(ca1) ) {
      volatile VALUE h_shared = Qnil;
      char *p_shared;
      (void) h_shared;
      p_shared = ALLOCV_N(char, h_shared, ca1->elements * ca1->bytes);
      ca_xfer_all(ca1, p_shared, CA_XFER_GET);
      func[ca1->data_type](n_kernel,
                           ( ca3->mask ) ? (boolean8_t *) ca3->mask->ptr : NULL,
                           p_shared, ca1->bytes, i1,
                           p_shared, ca2->bytes, i2,
                           ca3->ptr,  ca3->bytes, i3,
                           tol);
      ALLOCV_END(h_shared);
    }
    else {
      /* Binop-style threshold dispatch + chunked path for bincmp: only
         when both operands need per-region gather (both non-alias array)
         do we use the chunked path; else 1-shot ALLOCV for the single
         non-alias operand. */
      int nonalias_arrays = 0;
      int use_chunked;
      if ( i1 == 1 && !ca_attach_is_alias(ca1) ) nonalias_arrays++;
      if ( i2 == 1 && !ca_attach_is_alias(ca2) ) nonalias_arrays++;
      use_chunked = (nonalias_arrays >= 2);

      if ( !use_chunked ) {
        volatile VALUE h1 = Qnil, h2 = Qnil;
        char *p1, *p2;
        int attached1, attached2;
        (void) h1; (void) h2;

        EAGER_ACQUIRE_INPUT(ca1, p1, h1, attached1);
        EAGER_ACQUIRE_INPUT(ca2, p2, h2, attached2);

        func[ca1->data_type](n_kernel,
                             ( ca3->mask ) ? (boolean8_t *) ca3->mask->ptr : NULL,
                             p1, ca1->bytes, i1,
                             p2, ca2->bytes, i2,
                             ca3->ptr, ca3->bytes, i3,
                             tol);

        EAGER_RELEASE_INPUT(ca2, h2, attached2);
        EAGER_RELEASE_INPUT(ca1, h1, attached1);
      }
      else {
        /* CHUNKED PATH (both operands non-alias array): per-chunk gather
           into arena scratch.  Mirrors the binop chunked branch. */
        void *s1_arena = NULL, *s2_arena = NULL;
        ca_size_t b1 = ca1->bytes, b2 = ca2->bytes, b3 = ca3->bytes;
        int8_t dt = ca1->data_type;
        ca_size_t chunk_n, off;

        {
          ca_size_t inner1 = ca_chunk_inner_size(ca1);
          ca_size_t inner2 = ca_chunk_inner_size(ca2);
          ca_size_t inner = inner1 > inner2 ? inner1 : inner2;
          ca_size_t maxb = b1 > b2 ? b1 : b2;
          if ( b3 > maxb ) maxb = b3;
          chunk_n = ca_chunk_compute_n(n_kernel, inner, maxb);
        }

        ca_lazy_arena_enter();
        s1_arena = ca_lazy_arena_acquire(chunk_n * b1);
        s2_arena = ca_lazy_arena_acquire(chunk_n * b2);

        for ( off = 0; off < n_kernel; off += chunk_n ) {
          ca_size_t n_done = (off + chunk_n > n_kernel) ? n_kernel - off
                                                        : chunk_n;
          ca_chunked_gather(ca1, off, n_done, s1_arena);
          ca_chunked_gather(ca2, off, n_done, s2_arena);

          func[dt](n_done,
                   ca3->mask ? ((boolean8_t *) ca3->mask->ptr) + off
                             : NULL,
                   (char *) s1_arena, b1, i1,
                   (char *) s2_arena, b2, i2,
                   (char *) ca3->ptr + off * b3, b3, i3,
                   tol);
        }

        ca_lazy_arena_release(s2_arena);
        ca_lazy_arena_release(s1_arena);
        ca_lazy_arena_exit();
      }
    }
  }

  return out;
}

void
ca_monop_not_implement(ca_size_t n, boolean8_t *m, 
                                char *ptr1, ca_size_t i1, 
                                char *ptr2, ca_size_t i2)
{
  rb_raise(rb_eCADataTypeError,
           "invalid data type for monop (not implemented)");
}

void
ca_binop_not_implement(ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2,
                                char *ptr3, ca_size_t i3)
{
  rb_raise(rb_eCADataTypeError,
           "invalid data_type for binop (not implemented)");
}

void
ca_triop_not_implement(ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2,
                                char *ptr3, ca_size_t i3,
                                char *ptr4, ca_size_t i4)
{
  rb_raise(rb_eCADataTypeError,
           "invalid data_type for triop (not implemented)");
}

void
ca_moncmp_not_implement(ca_size_t n, boolean8_t *m, 
                                 char *ptr1, ca_size_t i1, 
                                 boolean8_t *ptr2, ca_size_t i2)
{
  rb_raise(rb_eCADataTypeError,
           "invalid data_type for moncmp (not implemented)");
}

void
ca_bincmp_not_implement (ca_size_t n, boolean8_t *m,
                                 char *ptr1, ca_size_t b1, ca_size_t i1,
                                 char *ptr2, ca_size_t b2, ca_size_t i2,
                                 char *ptr3, ca_size_t b3, ca_size_t i3,
                                 double tol)
{
  rb_raise(rb_eTypeError, "invalid data_type for bincmp (not implemented)");
}

VALUE
ca_math_call (VALUE mod, VALUE arg, ID id)
{
  if ( rb_obj_is_carray(arg) ) {
    return rb_funcall(arg, id, 0);
  }
#ifdef HAVE_COMPLEX_H
  else if ( RB_TYPE_P(arg, T_COMPLEX) ) {
    if ( rb_respond_to(arg, id) ) {
      return rb_funcall(arg, id, 0);
    }
    else if ( rb_respond_to(rb_mMath, id) ) {
      return rb_funcall(rb_mMath, id, 1, arg);
    }
    else {
      rb_raise(rb_eRuntimeError, "unknown method for Math");
    }
  }
#endif
  else {
    /* rb_funcall calls even for Math's private method -> infinite loop */
    if ( rb_respond_to(rb_mMath, id) ) {
      return rb_funcall(rb_mMath, id, 1, arg);
    }
    else {
      rb_raise(rb_eRuntimeError, "unknown method for Math");
    }
  }
}

/* @overload coerce (other)

[TBD]
*/

static VALUE
rb_ca_coerce (VALUE self, VALUE other)
{
  if ( rb_obj_is_carray(other) ) {
    return Qnil;
  }
  else if ( rb_respond_to(other, rb_intern("to_ca")) ) {
    return rb_ca_coerce(self, rb_funcall(other,rb_intern("to_ca"),0));
  }
  else {
    /* do implicit casting and resolving unbound repeat array */
    rb_ca_cast_self_or_other(&self, &other);
    return rb_assoc_new(other, self);
  }
}


/* CArray#mul_add was retired in 3.0 — superseded by `wsum` (mkkernel
   array_arg reduction, ext/mkkernel.rb).  `wsum` is the strict superset:
     - f64 accumulator (overflow-safe for integer input)
     - per-axis (`a.wsum(w, axis)`)
     - kernel_iterator universal dispatch (= mask + lazy operand)
     - 3.0-unified min_count semantic ("min valid required").
   Migration:  a.mul_add(b)                    -> a.wsum(b)
               a.mul_add(b, mc, fill)          -> a.wsum(b, min_count: mc,
                                                         fill_value: fill)
*/

void
Init_carray_operator (void)
{
  rb_mCAMath = rb_define_module("CAMath");

  rb_define_method(rb_cCArray, "coerce", rb_ca_coerce, 1);
}



