/* A kernel whose WRITE destination is a view the caller supplies.

   Every kernel inside carray writes into an array it just allocated
   (rb_ca_template_with_type, ca_template_safe, rb_carray_new), so the
   destination is always a fresh entity and the iterator's WRITE half is
   only ever exercised on obj_type 0.  A C extension using the author
   macros is under no such restriction: it can hand any view to
   CA_FOR_EACH_SLAB with CA_KERNEL_WRITE.  This fixture is that caller.

   The entry points are deliberately thin -- they fill the destination
   with one value and let the test compare the base entity before and
   after, so what is being measured is whether the write reached memory,
   not what the kernel computed. */

#include <string.h>
#include "ruby.h"
#include "carray.h"
#include "ca_kernel_iterator.h"

/* CA_SLAB_AXES + CA_KERNEL_FIBER_CONTIG.  dst must be float64. */
static VALUE
iw_fiber_fill (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v    = NUM2DBL(vval);
  int           axis = NUM2INT(vaxis);
  ca_iter_state st;
  char         *p;
  ca_size_t     n;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);

  CA_FOR_EACH_FIBER(st, dst, axis,
                    CA_KERNEL_WRITE | CA_KERNEL_NO_MASK, p, n) {
    double *d = (double *) p;
    for ( ca_size_t i = 0; i < n; i++ ) d[i] = v;
  }
  return Qnil;
}

/* CA_SLAB_AXES without FIBER_CONTIG: the slab is walked with strides. */
static VALUE
iw_slab_fill (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v = NUM2DBL(vval);
  int8_t        ax[1];
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  ax[0] = (int8_t) NUM2INT(vaxis);

  CA_FOR_EACH_SLAB(st, dst, ax, 1, CA_KERNEL_WRITE, p, m) {
    ca_size_t n = st.slab_dims[0];
    ca_size_t s = st.slab_strides[0];
    for ( ca_size_t i = 0; i < n; i++ ) *(double *)(p + i * s) = v;
  }
  return Qnil;
}

/* Writes the mask half of the yielded slab as well as the data half.
   Returns whether a mask pointer was yielded at all. */
static VALUE
iw_slab_fill_mask (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v = NUM2DBL(vval);
  int8_t        ax[1];
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;
  int           mask_seen = 0;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  ax[0] = (int8_t) NUM2INT(vaxis);

  CA_FOR_EACH_SLAB(st, dst, ax, 1, CA_KERNEL_WRITE, p, m) {
    ca_size_t n  = st.slab_dims[0];
    ca_size_t s  = st.slab_strides[0];
    ca_size_t ms = st.slab_mask_strides[0];
    for ( ca_size_t i = 0; i < n; i++ ) {
      *(double *)(p + i * s) = v;
      if ( m ) { m[i * ms] = 1; mask_seen = 1; }
    }
  }
  return mask_seen ? Qtrue : Qfalse;
}

/* A READ walk that writes into the mask cursor it is handed.  The cursor
   is the walk's own copy, so the source's mask must not change.  Returns
   whether a mask cursor was yielded. */
static VALUE
iw_read_poke_mask (VALUE klass, VALUE vsrc, VALUE vaxis)
{
  CArray       *src;
  int8_t        ax[1];
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;
  int           mask_seen = 0;

  (void) klass;
  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  ax[0] = (int8_t) NUM2INT(vaxis);

  CA_FOR_EACH_SLAB(st, src, ax, 1, 0, p, m) {
    ca_size_t n  = st.slab_dims[0];
    ca_size_t ms = st.slab_mask_strides[0];
    (void) p;
    for ( ca_size_t i = 0; i < n; i++ ) {
      if ( m ) { m[i * ms] = 1; mask_seen = 1; }
    }
  }
  return mask_seen ? Qtrue : Qfalse;
}

/* The mask an L2 CA_SLAB_WHOLE walk hands out through
   ca_iter_state_next_slab_strided, flattened in walk order; nil when no
   mask cursor is given. */
static VALUE
iw_strided_mask (VALUE klass, VALUE vsrc)
{
  CArray       *src;
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;
  ca_size_t     n, s;
  VALUE         out = rb_ary_new();
  int           seen = 0;

  (void) klass;
  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  ca_iter_check_init(ca_iter_state_init_l2(&st, src, CA_SLAB_WHOLE,
                                           NULL, 0, 0));
  while ( ca_iter_state_next_slab_strided(&st, &p, &m, &n, &s) ) {
    for ( ca_size_t i = 0; i < n; i++ ) {
      rb_ary_push(out, m ? INT2FIX(m[i]) : Qnil);
      if ( m ) seen = 1;
    }
  }
  ca_iter_state_finish(&st);
  return seen ? out : Qnil;
}

/* Copy src into dst fiber by fiber along `axis` with the INOUT form. */
static VALUE
iw_inout_copy (VALUE klass, VALUE vsrc, VALUE vdst, VALUE vaxis)
{
  CArray       *src, *dst;
  int           axis = NUM2INT(vaxis);
  ca_iter_state st_in, st_out;
  char         *p_in, *p_out;
  ca_size_t     n;

  (void) klass;
  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);

  CA_FOR_EACH_FIBER_INOUT(st_in, st_out, src, dst, axis, CA_KERNEL_NO_MASK,
                          p_in, p_out, n) {
    memcpy(p_out, p_in, n * sizeof(double));
  }
  return Qnil;
}

/* Fill the first fiber along `axis` and leave the walk with `break`. */
static VALUE
iw_fiber_fill_break (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v    = NUM2DBL(vval);
  int           axis = NUM2INT(vaxis);
  ca_iter_state st;
  char         *p;
  ca_size_t     n;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);

  CA_FOR_EACH_FIBER(st, dst, axis, CA_KERNEL_WRITE | CA_KERNEL_NO_MASK, p, n) {
    double *d = (double *) p;
    for ( ca_size_t i = 0; i < n; i++ ) d[i] = v;
    break;
  }
  return Qnil;
}

/* The return code init_l2 gives for (dst, axis, flags), without iterating.
   The block macros discard this value; this entry point is how the test
   sees what they discarded. */
static VALUE
iw_init_rc (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vflags)
{
  CArray       *dst;
  ca_iter_state st;
  int8_t        ax[1];
  int           rc;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  ax[0] = (int8_t) NUM2INT(vaxis);
  memset(&st, 0, sizeof(st));

  rc = ca_iter_state_init_l2(&st, dst, CA_SLAB_AXES, ax, 1,
                             (uint32_t) NUM2UINT(vflags));
  if ( rc == CA_ITER_OK ) ca_iter_state_finish(&st);
  return INT2NUM(rc);
}

/* Return code of init_l1 / init_l2 handed a NULL source. */
static VALUE
iw_null_src_rc (VALUE klass, VALUE vlevel, VALUE vflags)
{
  ca_iter_state st;
  int8_t        ax[1] = { 0 };
  uint32_t      flags = (uint32_t) NUM2UINT(vflags);
  int           rc;

  (void) klass;
  if ( NUM2INT(vlevel) == 1 ) {
    rc = ca_iter_state_init_l1(&st, NULL, CA_SLAB_WHOLE, NULL, 0, flags);
  }
  else {
    rc = ca_iter_state_init_l2(&st, NULL, CA_SLAB_AXES, ax, 1, flags);
  }
  if ( rc == CA_ITER_OK ) ca_iter_state_finish(&st);
  return INT2NUM(rc);
}

/* iw_slab_fill with the state struct poisoned first, which is what a real
   caller frame looks like when init returns early without writing to it.
   A caller that happens to sit on zeroed stack sees the write vanish; this
   one sees whatever the garbage decodes to. */
static VALUE
iw_slab_fill_poisoned (VALUE klass, VALUE vdst, VALUE vaxis, VALUE vval)
{
  CArray       *dst;
  double        v = NUM2DBL(vval);
  int8_t        ax[1];
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  ax[0] = (int8_t) NUM2INT(vaxis);
  memset(&st, 0x5A, sizeof(st));

  CA_FOR_EACH_SLAB(st, dst, ax, 1, CA_KERNEL_WRITE, p, m) {
    ca_size_t n = st.slab_dims[0];
    ca_size_t s = st.slab_strides[0];
    for ( ca_size_t i = 0; i < n; i++ ) *(double *)(p + i * s) = v;
  }
  return Qnil;
}

/* ---- delivery matrix ------------------------------------------------

   iw_read_cells / iw_write_cells walk a float64 source the four ways a
   kernel can ask for it:

     0  L1 whole        (init_l1 + next_slab)
     1  L2 whole        (init_l2 + next_slab_strided)
     2  one slab axis   (CA_SLAB_AXES, strided slab)
     3  one fiber       (CA_SLAB_AXES + FIBER_CONTIG, contiguous)

   A whole walk may still yield its cells as several slabs (an L2 walk over
   a strided source yields one row at a time); they come in row-major order.
   iw_read_cells returns the slabs in the order they were yielded, each an
   Array of the cell values with nil where the yielded mask is set.
   iw_write_cells writes 1000 + the cell's position in the walk for a whole
   walk, and 1000 * (slab number + 1) + position in the slab for the
   others, so the test can tell where each root cell was reached from. */

static int
iw_open (ca_iter_state *st, CArray *ca, int mode, int8_t axis, uint32_t flags)
{
  int8_t ax[1];
  ax[0] = axis;
  switch ( mode ) {
    case 0:
      return ca_iter_state_init_l1(st, ca, CA_SLAB_WHOLE, NULL, 0, flags);
    case 1:
      return ca_iter_state_init_l2(st, ca, CA_SLAB_WHOLE, NULL, 0, flags);
    case 2:
      return ca_iter_state_init_l2(st, ca, CA_SLAB_AXES, ax, 1, flags);
    default:
      return ca_iter_state_init_l2(st, ca, CA_SLAB_AXES, ax, 1,
                                   flags | CA_KERNEL_FIBER_CONTIG);
  }
}

/* Yields the next slab as (base, mask, n, value stride, mask stride). */
static int
iw_next (ca_iter_state *st, int mode, char **p, boolean8_t **m,
         ca_size_t *n, ca_size_t *s, ca_size_t *ms)
{
  switch ( mode ) {
    case 0:
      if ( ! ca_iter_state_next_slab(st, p, m, n) ) return 0;
      *s = st->bytes; *ms = 1;
      return 1;
    case 1:
      if ( ! ca_iter_state_next_slab_strided(st, p, m, n, s) ) return 0;
      *ms = 1;
      return 1;
    case 2:
      if ( ! ca_iter_state_next_slab_axes(st, p, m) ) return 0;
      *n = st->slab_dims[0]; *s = st->slab_strides[0];
      *ms = st->slab_mask_strides[0];
      return 1;
    default:
      if ( ! ca_iter_state_next_slab_axes(st, p, m) ) return 0;
      *n = st->slab_dims[0]; *s = st->bytes; *ms = 1;
      return 1;
  }
}

static VALUE
iw_read_cells (VALUE klass, VALUE vsrc, VALUE vmode, VALUE vaxis)
{
  CArray       *src;
  int           mode = NUM2INT(vmode);
  int8_t        axis = (int8_t) NUM2INT(vaxis);
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;
  ca_size_t     n, s, ms;
  VALUE         out  = rb_ary_new();

  (void) klass;
  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);

  ca_iter_check_init(iw_open(&st, src, mode, axis, 0));
  while ( iw_next(&st, mode, &p, &m, &n, &s, &ms) ) {
    VALUE slab = rb_ary_new_capa(n);
    for ( ca_size_t i = 0; i < n; i++ ) {
      if ( m && m[i * ms] ) {
        rb_ary_push(slab, Qnil);
      }
      else {
        rb_ary_push(slab, rb_float_new(*(double *)(p + i * s)));
      }
    }
    rb_ary_push(out, slab);
    ca_iter_state_sync_slab(&st);
  }
  ca_iter_state_close(&st);
  return out;
}

static VALUE
iw_write_cells (VALUE klass, VALUE vdst, VALUE vmode, VALUE vaxis)
{
  CArray       *dst;
  int           mode = NUM2INT(vmode);
  int8_t        axis = (int8_t) NUM2INT(vaxis);
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;
  ca_size_t     n, s, ms;
  ca_size_t     slab = 0;
  ca_size_t     done = 0;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);

  ca_iter_check_init(iw_open(&st, dst, mode, axis, CA_KERNEL_WRITE));
  while ( iw_next(&st, mode, &p, &m, &n, &s, &ms) ) {
    slab++;
    for ( ca_size_t i = 0; i < n; i++ ) {
      double v = ( mode < 2 ) ? (double) (1000 + done + i)
                              : (double) (1000 * slab + i);
      *(double *)(p + i * s) = v;
    }
    done += n;
    ca_iter_state_sync_slab(&st);
  }
  ca_iter_state_close(&st);
  return Qnil;
}

/* The route a walk takes, read from the state after its first slab:
   src_kind, alias_mode, whether it attached a root, whether it gathered a
   whole-view scratch, and whether the first fiber was gathered into the
   fiber scratch.  mode as in iw_read_cells; write selects CA_KERNEL_WRITE. */
static VALUE
iw_route (VALUE klass, VALUE vsrc, VALUE vmode, VALUE vaxis, VALUE vwrite)
{
  CArray       *src;
  int           mode  = NUM2INT(vmode);
  int8_t        axis  = (int8_t) NUM2INT(vaxis);
  uint32_t      flags = RTEST(vwrite) ? CA_KERNEL_WRITE : 0;
  ca_iter_state st;
  char         *p;
  boolean8_t   *m;
  ca_size_t     n, s, ms;
  VALUE         out = rb_hash_new();
  int           got;

  (void) klass;
  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);

  ca_iter_check_init(iw_open(&st, src, mode, axis, flags));
  got = iw_next(&st, mode, &p, &m, &n, &s, &ms);
  rb_hash_aset(out, ID2SYM(rb_intern("src_kind")),   INT2NUM(st.src_kind));
  rb_hash_aset(out, ID2SYM(rb_intern("alias_mode")), INT2NUM(st.alias_mode));
  rb_hash_aset(out, ID2SYM(rb_intern("root")),       st.root ? Qtrue : Qfalse);
  rb_hash_aset(out, ID2SYM(rb_intern("scratch")),    st.scratch_ptr ? Qtrue : Qfalse);
  rb_hash_aset(out, ID2SYM(rb_intern("fiber_scratch")),
               ( got && st.fiber_data_scratch && p == st.fiber_data_scratch ) ? Qtrue : Qfalse);
  ca_iter_state_close(&st);
  return out;
}

/* ---- CA_FOR_EACH_WHOLE ----------------------------------------------- */

/* The cells and mask flags the whole-array macro hands the kernel, as an
   Array with nil where the flag is set.  masked selects the MASKED form;
   the plain form reads every cell as a value. */
static VALUE
iw_whole_read (VALUE klass, VALUE vsrc, VALUE vmasked)
{
  CArray       *src;
  ca_iter_state st;
  char         *p;
  boolean8_t   *m = NULL;
  ca_size_t     n;
  VALUE         out = rb_ary_new();

  (void) klass;
  TypedData_Get_Struct(vsrc, CArray, &carray_data_type, src);
  if ( RTEST(vmasked) ) {
    CA_FOR_EACH_WHOLE_MASKED(st, src, 0, p, n, m) {
      for ( ca_size_t i = 0; i < n; i++ ) {
        rb_ary_push(out, ( m && m[i] ) ? Qnil
                                       : rb_float_new(((double *) p)[i]));
      }
    }
  }
  else {
    CA_FOR_EACH_WHOLE(st, src, 0, p, n) {
      for ( ca_size_t i = 0; i < n; i++ ) {
        rb_ary_push(out, rb_float_new(((double *) p)[i]));
      }
    }
  }
  return out;
}

/* Writes 1000 + i into cell i, in row-major order. */
static VALUE
iw_whole_write (VALUE klass, VALUE vdst)
{
  CArray       *dst;
  ca_iter_state st;
  char         *p;
  ca_size_t     n;

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  CA_FOR_EACH_WHOLE(st, dst, CA_KERNEL_WRITE, p, n) {
    for ( ca_size_t i = 0; i < n; i++ ) ((double *) p)[i] = 1000.0 + i;
  }
  return Qnil;
}

/* Writes -1 into the first k cells, then leaves the body with break. */
static VALUE
iw_whole_break (VALUE klass, VALUE vdst, VALUE vk)
{
  CArray       *dst;
  ca_iter_state st;
  char         *p;
  ca_size_t     n, k = NUM2SIZET(vk);

  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, dst);
  CA_FOR_EACH_WHOLE(st, dst, CA_KERNEL_WRITE, p, n) {
    for ( ca_size_t i = 0; i < k && i < n; i++ ) ((double *) p)[i] = -1.0;
    break;
  }
  return Qnil;
}

/* A body that raises after writing -1 into the first k cells, opened
   inside ca_iter_ensure as the header says a raising body must be. */
typedef struct { ca_iter_state st[1]; CArray *dst; ca_size_t k; } iw_whole_raise_t;

static VALUE
iw_whole_raise_body (VALUE arg)
{
  iw_whole_raise_t *c = (iw_whole_raise_t *) arg;
  char      *p;
  ca_size_t  n;
  CA_FOR_EACH_WHOLE(c->st[0], c->dst, CA_KERNEL_WRITE, p, n) {
    for ( ca_size_t i = 0; i < c->k && i < n; i++ ) ((double *) p)[i] = -1.0;
    rb_raise(rb_eRuntimeError, "iw_whole_raise");
  }
  return Qnil;
}

static VALUE
iw_whole_raise (VALUE klass, VALUE vdst, VALUE vk)
{
  iw_whole_raise_t c;
  (void) klass;
  TypedData_Get_Struct(vdst, CArray, &carray_data_type, c.dst);
  c.k = NUM2SIZET(vk);
  return ca_iter_ensure(1, c.st, iw_whole_raise_body, (VALUE) &c);
}

void
Init_iter_write (void)
{
  rb_define_singleton_method(rb_cCArray, "iw_fiber_fill", iw_fiber_fill, 3);
  rb_define_singleton_method(rb_cCArray, "iw_slab_fill", iw_slab_fill, 3);
  rb_define_singleton_method(rb_cCArray, "iw_slab_fill_mask", iw_slab_fill_mask, 3);
  rb_define_singleton_method(rb_cCArray, "iw_init_rc", iw_init_rc, 3);
  rb_define_singleton_method(rb_cCArray, "iw_null_src_rc", iw_null_src_rc, 2);
  rb_define_singleton_method(rb_cCArray, "iw_read_poke_mask", iw_read_poke_mask, 2);
  rb_define_singleton_method(rb_cCArray, "iw_strided_mask", iw_strided_mask, 1);
  rb_define_singleton_method(rb_cCArray, "iw_inout_copy", iw_inout_copy, 3);
  rb_define_singleton_method(rb_cCArray, "iw_fiber_fill_break", iw_fiber_fill_break, 3);
  rb_define_singleton_method(rb_cCArray, "iw_slab_fill_poisoned", iw_slab_fill_poisoned, 3);
  rb_define_singleton_method(rb_cCArray, "iw_read_cells", iw_read_cells, 3);
  rb_define_singleton_method(rb_cCArray, "iw_write_cells", iw_write_cells, 3);
  rb_define_singleton_method(rb_cCArray, "iw_route", iw_route, 4);
  rb_define_singleton_method(rb_cCArray, "iw_whole_read", iw_whole_read, 2);
  rb_define_singleton_method(rb_cCArray, "iw_whole_write", iw_whole_write, 1);
  rb_define_singleton_method(rb_cCArray, "iw_whole_break", iw_whole_break, 2);
  rb_define_singleton_method(rb_cCArray, "iw_whole_raise", iw_whole_raise, 2);
}
