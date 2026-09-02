/* ---------------------------------------------------------------------------
 *
 *  cslab.c -- ca_call_cslab_*_r usage example
 *
 *  The chunked counterpart of the cfunc family.  Where ca_call_cfunc_N
 *  hands the author one cell at a time, ca_call_cslab_N hands it one chunk
 *  at a time -- `base` / `stride` per operand, a cell count, and the
 *  chunk's slice of the iteration mask.  Two things follow, and they are
 *  the same thing seen from two sides:
 *
 *    memory -- a non-alias INPUT is gathered into a ~32KB arena scratch per
 *      chunk rather than materialised whole, so the input memory peak stops
 *      scaling with the operand.  That is the whole reason the chunked path
 *      exists; the cfunc family is the whole-buffer caller.
 *
 *    speed -- the indirect call is paid once per chunk instead of once per
 *      cell, and the author's inner loop is a loop the compiler can see,
 *      so it vectorises.  A per-cell callback cannot.
 *
 *  Build:    ruby extconf.rb && make
 *  Run:      ruby example.rb
 *
 *  --------------------------------------------------------------------------- */

#include "carray.h"

/* User-data struct: the scale the kernel applies, plus what the walk saw.
   Recording the chunk count and the largest chunk is what makes the memory
   claim observable from Ruby -- a walk that reports 977 chunks of 4096
   cells never held the 4M-cell operand. */
typedef struct {
  double     scale;
  ca_size_t  chunks;
  ca_size_t  chunk_n_max;
  /* Where operand 1 was read from on each chunk.  An alias INPUT is walked
     in place, so its base advances by stride * chunk_n from chunk to chunk;
     a non-alias INPUT is re-gathered into the same arena scratch, so its
     base does not move.  Comparing the first two chunks is therefore a
     direct read on which of the two happened -- no RSS guessing. */
  const char *first_base;
  const char *second_base;
} ud_t;

/* y = a + b * scale, one chunk at a time.
 *
 * The contiguous branch is not an optimisation the author has to invent:
 * a non-alias INPUT arrives packed in the arena scratch, so stride is the
 * element size for exactly the operands that were gathered.  Splitting on
 * it is what lets the compiler vectorise the common case. */
static void
slab_add_scaled (char **base, ca_size_t *stride, ca_size_t n,
                 const boolean8_t *m0, void *userdata)
{
  ud_t *ud = (ud_t *) userdata;
  ca_size_t k;

  ud->chunks++;
  if ( n > ud->chunk_n_max ) ud->chunk_n_max = n;
  if ( ud->chunks == 1 ) ud->first_base  = base[1];
  if ( ud->chunks == 2 ) ud->second_base = base[1];

  if ( !m0
       && stride[0] == (ca_size_t) sizeof(double)
       && stride[1] == (ca_size_t) sizeof(double)
       && stride[2] == (ca_size_t) sizeof(double) ) {
    double       *y = (double *) base[0];
    const double *a = (const double *) base[1];
    const double *b = (const double *) base[2];
    for ( k = 0; k < n; k++ ) {
      y[k] = a[k] + b[k] * ud->scale;
    }
  } else {
    for ( k = 0; k < n; k++ ) {
      /* A masked cell is the author's to skip.  A slab has no way to leave
         a hole, so unlike the per-cell form the engine cannot skip it for
         you -- it hands you the mask instead. */
      if ( m0 && m0[k] ) continue;
      *(double *) (base[0] + k * stride[0]) =
        *(const double *) (base[1] + k * stride[1]) +
        *(const double *) (base[2] + k * stride[2]) * ud->scale;
    }
  }
}

/* out = a + b * scale.  fsync "100": operand 0 is the OUTPUT, 1 and 2 are
   INPUTs.  Returns [out, chunks, largest chunk, gathered?] so the walk is
   inspectable from Ruby -- `gathered?` says whether operand 1 went through
   the arena scratch, which is the case the chunked path exists for. */
static VALUE
demo_cslab_3_r (VALUE self, VALUE r_out, VALUE r_a, VALUE r_b, VALUE r_scale)
{
  ud_t ud = { NUM2DBL(r_scale), 0, 0, NULL, NULL };
  VALUE gathered;
  ca_call_cslab_3_r(slab_add_scaled, "100", r_out, r_a, r_b, &ud);
  /* Undecidable from one chunk: a walk short enough to fit in a single
     chunk never moves a base either way. */
  gathered = ( ud.chunks < 2 ) ? Qnil
           : ( ud.first_base == ud.second_base ? Qtrue : Qfalse );
  return rb_ary_new3(4, r_out,
                     SIZE2NUM(ud.chunks), SIZE2NUM(ud.chunk_n_max), gathered);
}

/* The same arithmetic through the per-cell family, so example.rb can time
   the two against each other over the same operands. */
static void
cell_add_scaled (void *p_y, void *p_a, void *p_b, void *userdata)
{
  ud_t *ud = (ud_t *) userdata;
  *(double *) p_y = *(double *) p_a + *(double *) p_b * ud->scale;
}

static VALUE
demo_cfunc_3_r (VALUE self, VALUE r_out, VALUE r_a, VALUE r_b, VALUE r_scale)
{
  ud_t ud = { NUM2DBL(r_scale), 0, 0, NULL, NULL };
  ca_call_cfunc_3_r(cell_add_scaled, "100", r_out, r_a, r_b, &ud);
  return r_out;
}

/* --------------------------------------------------------------------------
 * The typed dispatcher.
 *
 * ca_call_cslab_M_N declares the data types the callback works in, wraps
 * each input readonly to its declared type, and allocates the output --
 * so the caller neither supplies an output array nor matches dtypes by
 * hand.  It is the layer a math-function wrapper actually uses.
 *
 * It is also where chunking pays most.  The coercion is a lazy readonly
 * cast view, which is never attach-alias, so declaring CA_DOUBLE over an
 * int32 array is exactly the operand kind the whole-buffer path copies
 * whole -- and the chunked path gathers 32KB at a time.
 * -------------------------------------------------------------------------- */

/* y = x * scale, one chunk at a time. */
static void
slab_scale (char **base, ca_size_t *stride, ca_size_t n,
            const boolean8_t *m0, void *userdata)
{
  ud_t *ud = (ud_t *) userdata;
  ca_size_t k;

  ud->chunks++;
  if ( n > ud->chunk_n_max ) ud->chunk_n_max = n;
  if ( ud->chunks == 1 ) ud->first_base  = base[1];
  if ( ud->chunks == 2 ) ud->second_base = base[1];

  for ( k = 0; k < n; k++ ) {
    if ( m0 && m0[k] ) continue;
    *(double *) (base[0] + k * stride[0]) =
      *(const double *) (base[1] + k * stride[1]) * ud->scale;
  }
}

/* The input may be of any data_type: CA_DOUBLE is what the callback reads,
   and the dispatcher wraps whatever arrives into that.  Returns
   [y, chunks, gathered?] so example.rb can show what the coercion cost. */
static VALUE
demo_cslab_1_1_r (VALUE self, VALUE r_x, VALUE r_scale)
{
  ud_t ud = { NUM2DBL(r_scale), 0, 0, NULL, NULL };
  VALUE y, gathered;
  y = ca_call_cslab_1_1_r(CA_DOUBLE, CA_DOUBLE, slab_scale, r_x, &ud);
  gathered = ( ud.chunks < 2 ) ? Qnil
           : ( ud.first_base == ud.second_base ? Qtrue : Qfalse );
  return rb_ary_new3(3, y, SIZE2NUM(ud.chunks), gathered);
}

/* The same through the per-cell typed dispatcher, so the two can be timed
   over the same input. */
static void
cell_scale (void *p_y, void *p_x, void *userdata)
{
  *(double *) p_y = *(double *) p_x * ((ud_t *) userdata)->scale;
}

static VALUE
demo_cfunc_1_1_r (VALUE self, VALUE r_x, VALUE r_scale)
{
  ud_t ud = { NUM2DBL(r_scale), 0, 0, NULL, NULL };
  return ca_call_cfunc_1_1_r(CA_DOUBLE, CA_DOUBLE, cell_scale, r_x, &ud);
}

void
Init_cslab (void)
{
  rb_define_singleton_method(rb_cCArray, "demo_cslab_3_r", demo_cslab_3_r, 4);
  rb_define_singleton_method(rb_cCArray, "demo_cfunc_3_r", demo_cfunc_3_r, 4);
  rb_define_singleton_method(rb_cCArray, "demo_cslab_1_1_r", demo_cslab_1_1_r, 2);
  rb_define_singleton_method(rb_cCArray, "demo_cfunc_1_1_r", demo_cfunc_1_1_r, 2);
}
