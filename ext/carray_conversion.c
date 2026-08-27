/* ---------------------------------------------------------------------------

  Value conversion and binary serialization: to_a / convert / dump_binary /
  to_s / load_binary.  Ruby-facing docs live in
  yard-stubs/carray_conversion.rb.

  Siblings:
    carray_copy.c        — CArray-to-CArray copy / template family
    carray_element.c     — element-level fetch/store (rb_ca_ptr2obj / obj2ptr)
    carray_cast_func.c   — data type cast table used by rb_ca_ptr2obj

---------------------------------------------------------------------------- */

#include "carray.h"

#include "ruby/io.h"

/* to_a dispatch:
     numeric / boolean data type + entity or attach-able view -> fast path
       (data type-direct leaf loop over the attached contig buffer)
     CA_OBJECT / CA_FIXLEN                                -> universal
       (rb_ca_fetch_index per cell; ptr is VALUE or byte string, not
        directly castable through the leaf switch)

   Masked cells materialise as CA_UNDEF on both paths. */

/* Leaf macro: data type-specialized inner loop.  Produces `n` VALUE objects
   from a contig ptr base + element width, storing into `dst` (Ruby Array). */
#define TO_A_LEAF_LOOP(T, TO_VALUE) do { \
  const T *src = (const T *) base; \
  for (li = 0; li < n; li++) { \
    rb_ary_store(dst, li, TO_VALUE(src[li])); \
  } \
} while (0)

#define TO_A_LEAF_LOOP_MASKED(T, TO_VALUE) do { \
  const T *src = (const T *) base; \
  for (li = 0; li < n; li++) { \
    rb_ary_store(dst, li, mask[li] ? CA_UNDEF : TO_VALUE(src[li])); \
  } \
} while (0)

#define TO_A_DISPATCH_LEAF(LOOP) do { \
  ca_size_t li; \
  switch ( data_type ) { \
  case CA_FLOAT64: LOOP(double,   rb_float_new); break; \
  case CA_FLOAT32: LOOP(float,    rb_float_new); break; \
  case CA_INT64:   LOOP(int64_t,  LL2NUM);       break; \
  case CA_INT32:   LOOP(int32_t,  INT2NUM);      break; \
  case CA_INT16:   LOOP(int16_t,  INT2FIX);      break; \
  case CA_INT8:    LOOP(int8_t,   INT2FIX);      break; \
  case CA_UINT64:  LOOP(uint64_t, ULL2NUM);      break; \
  case CA_UINT32:  LOOP(uint32_t, UINT2NUM);     break; \
  case CA_UINT16:  LOOP(uint16_t, INT2FIX);      break; \
  case CA_UINT8:   LOOP(uint8_t,  INT2FIX);      break; \
  case CA_BOOLEAN: \
    /* Emit Ruby true/false.  Consistent with the per-cell Ruby-land yield
       family (a[i], each, each_with_addr, elem_fetch, CScalar value) which
       all yield Qtrue/Qfalse since Part A.  Numeric casts and serialize
       paths keep the raw uint8 encoding via BOOL2OBJ (they do not go
       through this leaf). */ \
    { \
      const uint8_t *src = (const uint8_t *) base; \
      for (li = 0; li < n; li++) { \
        rb_ary_store(dst, li, src[li] ? Qtrue : Qfalse); \
      } \
    } \
    break; \
  default: \
    rb_bug("to_a fast path: unexpected data type %d", data_type); \
  } \
} while (0)

#define TO_A_DISPATCH_LEAF_MASKED(LOOP) do { \
  ca_size_t li; \
  switch ( data_type ) { \
  case CA_FLOAT64: LOOP(double,   rb_float_new); break; \
  case CA_FLOAT32: LOOP(float,    rb_float_new); break; \
  case CA_INT64:   LOOP(int64_t,  LL2NUM);       break; \
  case CA_INT32:   LOOP(int32_t,  INT2NUM);      break; \
  case CA_INT16:   LOOP(int16_t,  INT2FIX);      break; \
  case CA_INT8:    LOOP(int8_t,   INT2FIX);      break; \
  case CA_UINT64:  LOOP(uint64_t, ULL2NUM);      break; \
  case CA_UINT32:  LOOP(uint32_t, UINT2NUM);     break; \
  case CA_UINT16:  LOOP(uint16_t, INT2FIX);      break; \
  case CA_UINT8:   LOOP(uint8_t,  INT2FIX);      break; \
  case CA_BOOLEAN: \
    /* Emit Ruby true/false, matching the unmasked leaf above. */ \
    { \
      const uint8_t *src = (const uint8_t *) base; \
      for (li = 0; li < n; li++) { \
        rb_ary_store(dst, li, mask[li] ? CA_UNDEF \
                                       : (src[li] ? Qtrue : Qfalse)); \
      } \
    } \
    break; \
  default: \
    rb_bug("to_a fast path masked: unexpected data type %d", data_type); \
  } \
} while (0)

/* Recursive multi-dim wrap: for non-leaf levels, allocate child Array and
   recurse with adjusted base pointer.  At leaf level, invoke dispatch.
   `flat_base` is ca->ptr + cumulative byte offset for this slab. */
static void
to_a_fast_recurse (CArray *ca, int32_t level, const char *base,
                   const boolean8_t *mask_base, VALUE dst,
                   int data_type, ca_size_t bytes, int has_mask)
{
  ca_size_t i, n, slab_elements, slab_bytes;

  if ( level == ca->ndim - 1 ) {
    n = ca->dim[level];
    if ( has_mask ) {
      const boolean8_t *mask = mask_base;
      TO_A_DISPATCH_LEAF_MASKED(TO_A_LEAF_LOOP_MASKED);
    }
    else {
      TO_A_DISPATCH_LEAF(TO_A_LEAF_LOOP);
    }
    return;
  }

  /* Non-leaf: walk dim[level], for each i allocate child Array + recurse. */
  n = ca->dim[level];
  slab_elements = 1;
  for (i = level + 1; i < ca->ndim; i++) {
    slab_elements *= ca->dim[i];
  }
  slab_bytes = slab_elements * bytes;

  for (i = 0; i < n; i++) {
    volatile VALUE child = rb_ary_new2(ca->dim[level + 1]);
    rb_ary_store(dst, i, child);
    to_a_fast_recurse(ca, level + 1,
                      base + i * slab_bytes,
                      has_mask ? mask_base + i * slab_elements : NULL,
                      child, data_type, bytes, has_mask);
  }
}

/* Universal fallback for CA_OBJECT / CA_FIXLEN, where ptr-direct cast
   through the leaf switch is not safe.  Walks every cell through
   rb_ca_fetch_index; masked cells return CA_UNDEF via the fetcher. */
static void
rb_ca_to_a_loop_universal (VALUE self, int32_t level, ca_size_t *idx, VALUE ary)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( level == ca->ndim - 1 ) {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      rb_ary_store(ary, i, rb_ca_fetch_index(self, idx));
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level] = i;
      obj = rb_ary_new2(ca->dim[level+1]);
      rb_ca_to_a_loop_universal(self, level+1, idx, obj);
      rb_ary_store(ary, i, obj);
    }
  }
}

/* CArray#to_a — return a nested Ruby Array holding self's element values.
 *
 * ndim-1 nesting: shape [2, 3] -> 2-element Array of 3-element Arrays.
 * Masked cells become CA_UNDEF; the mask itself is not preserved on the
 * result.  ca_attach(self) supplies a contig row-major buffer for the
 * fast path, so all view kinds land in the data type-direct leaf loop when
 * the data type is numeric or boolean; CA_OBJECT / CA_FIXLEN fall through
 * to the universal fetch_index walk. */
VALUE
rb_ca_to_a (VALUE self)
{
  volatile VALUE ary;
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  int data_type, fast_eligible;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ary = rb_ca_is_empty(self) ? rb_ary_new() : rb_ary_new2(ca->dim[0]);
  ca_attach(ca);

  /* After ca_attach, ca->ptr is a contig row-major buffer (alias for
     contig views, materialised otherwise) and ca->mask matches, so the
     fast path handles every view kind.  CA_OBJECT / CA_FIXLEN stay on
     the universal path because their ptr is VALUE / byte string and
     the leaf switch cannot cast them directly.

     A Face stays on it too, whatever its storage: the fast path reads the
     storage buffer, and a Face means something else on its surface (an
     Element, a label).  Reading the buffer would hand back the storage of a
     numeric-storage Face -- CATimedelta serials instead of CATimedelta
     Elements -- while ca[i] / each / to_type(:object) all decode.  The
     universal loop goes through rb_ca_fetch_addr, which decodes. */
  data_type = ca->data_type;
  fast_eligible = (ca->elements > 0)
                  && ( ! ca_is_face(ca) )
                  && (data_type == CA_FLOAT64 || data_type == CA_FLOAT32
                      || data_type == CA_INT64   || data_type == CA_INT32
                      || data_type == CA_INT16   || data_type == CA_INT8
                      || data_type == CA_UINT64  || data_type == CA_UINT32
                      || data_type == CA_UINT16  || data_type == CA_UINT8
                      || data_type == CA_BOOLEAN);

  if ( fast_eligible ) {
    int has_mask = (ca->mask != NULL);
    const boolean8_t *mask_base = has_mask
        ? (const boolean8_t *) ca->mask->ptr : NULL;
    to_a_fast_recurse(ca, 0, ca->ptr, mask_base, ary,
                      data_type, ca->bytes, has_mask);
  }
  else if ( ca->elements > 0 ) {
    rb_ca_to_a_loop_universal(self, 0, idx, ary);
  }
  ca_detach(ca);
  return ary;
}

#undef TO_A_LEAF_LOOP
#undef TO_A_LEAF_LOOP_MASKED
#undef TO_A_DISPATCH_LEAF
#undef TO_A_DISPATCH_LEAF_MASKED

/* CArray#convert(data_type=nil, bytes: nil) { |elem| ... } — map every cell
 * through the block, into a new array whose data type is chosen by argv via
 * CArray#template (shape is inherited from self).
 *
 * Masked cells skip the block; if the block returns CA_UNDEF, the
 * corresponding output cell is masked instead of stored.  Both self
 * and the template result are attached symmetrically (R3-compliant) so
 * an overridden #template returning a view stays on the in-ptr path. */
static VALUE
rb_ca_convert (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  CArray *ca, *co;
  ca_size_t i, n, sbytes, dbytes;
  int has_mask;
  const boolean8_t *src_mask = NULL;
  boolean8_t *dst_mask = NULL;
  const char *src_ptr;
  char *dst_ptr;

  rb_need_block();

  obj = rb_apply(self, rb_intern("template"), rb_ary_new4(argc, argv));

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  TypedData_Get_Struct(obj, CArray, &carray_data_type, co);

  n = ca->elements;
  has_mask = ca_has_mask(ca);
  sbytes = ca->bytes;
  dbytes = co->bytes;

  /* Attach every storage touched by ptr (self, obj, and either side's
     mask) — parent → child order per the R4 attach protocol. */
  ca_attach(ca);
  ca_attach(co);
  if ( has_mask ) {
    ca_attach(ca->mask);
    if ( ! co->mask ) {
      ca_create_mask(co);
    }
    ca_attach(co->mask);
    src_mask = (const boolean8_t *) ca->mask->ptr;
    dst_mask = (boolean8_t *) co->mask->ptr;
    memset(dst_mask, 0, (size_t) n);
  }
  src_ptr = ca->ptr;
  dst_ptr = co->ptr;

  if ( has_mask ) {
    for (i = 0; i < n; i++) {
      if ( ! src_mask[i] ) {
        VALUE val = rb_ca_ptr2obj(self, (void *) (src_ptr + i * sbytes));
        VALUE ret = rb_yield(val);
        if ( ret == CA_UNDEF ) {
          dst_mask[i] = 1;
        }
        else {
          rb_ca_obj2ptr(obj, ret, dst_ptr + i * dbytes);
        }
      }
      else {
        dst_mask[i] = 1;
      }
    }
  }
  else {
    for (i = 0; i < n; i++) {
      VALUE val = rb_ca_ptr2obj(self, (void *) (src_ptr + i * sbytes));
      VALUE ret = rb_yield(val);
      if ( ret == CA_UNDEF ) {
        if ( ! co->mask ) {
          ca_create_mask(co);
          ca_attach(co->mask);
          dst_mask = (boolean8_t *) co->mask->ptr;
          memset(dst_mask, 0, (size_t) n);
        }
        dst_mask[i] = 1;
      }
      else {
        rb_ca_obj2ptr(obj, ret, dst_ptr + i * dbytes);
      }
    }
  }

  if ( co->mask ) {
    ca_sync(co->mask);
    ca_detach(co->mask);
  }
  if ( has_mask ) {
    ca_detach(ca->mask);
  }
  ca_sync(co);
  ca_detach(co);
  ca_detach(ca);

  return obj;
}

/* CArray#dump_binary([io]) — write self's raw element bytes to io in
 * row-major order.
 *
 * With no arg, returns a fresh binary String.  A String arg is resized
 * and overwritten in-place; a T_FILE writes through rb_io_bufwrite for
 * entities (no Ruby String copy) or a scratch buffer for views; any
 * other object must respond to #write.  Rejects CA_OBJECT (data is
 * VALUE, not portable). */
static VALUE
rb_ca_dump_binary (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE io;
  CArray *ca;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_object_type(ca) ) {
    rb_raise(rb_eCADataTypeError, "don't dump object array");
  }

  if ( argc == 0 ) {
    io = rb_str_new(NULL, 0);
  }
  else if ( argc == 1 ) {
    io = argv[0];
  }
  else {
    rb_raise(rb_eArgError, "invalid # of arguments (%i for 1)", argc);
  }

  switch ( TYPE(io) ) {
  case T_STRING:
    rb_check_frozen(io);
    if ( ca_length(ca) != RSTRING_LEN(io) ) {
      rb_str_resize(io, ca_length(ca));
    }
    ca_copy_data(ca, RSTRING_PTR(io));
    break;
  case T_FILE: {
    rb_io_t *iop;
    ca_size_t total = ca_length(ca);
    GetOpenFile(io, iop);
    rb_io_check_writable(iop);
    if ( ca_is_entity(ca) ) {
      /* Owned ca->ptr: write through the IO buffer machinery so peak
         stays at ca_length instead of doubling via a Ruby String. */
      ssize_t n = rb_io_bufwrite(io, ca->ptr, (size_t) total);
      if ( n < 0 || (ca_size_t) n != total ) {
        rb_raise(rb_eRuntimeError,
                 "short write to IO (wrote %" PRId64 " bytes, expected %" PRId64 ")",
                 (ca_size_t) (n < 0 ? 0 : n), (ca_size_t) total);
      }
    }
    else {
      /* View: no chunked gather API, so materialise into one buffer. */
      volatile VALUE buf = rb_str_new(NULL, total);
      ca_copy_data(ca, RSTRING_PTR(buf));
      rb_io_write(io, buf);
    }
    break;
  }
  default:
    if ( rb_respond_to(io, rb_intern("write") ) ) {
      volatile VALUE buf = rb_str_new(NULL, ca_length(ca));
      ca_copy_data(ca, RSTRING_PTR(buf));
      rb_funcall(io, rb_intern("write"), 1, buf);
    }
    else {
      rb_raise(rb_eRuntimeError, "IO like object should have 'write' method");
    }
  }

  return io;
}

/* CArray#to_s — equivalent to dump_binary with no argument. */
static VALUE
rb_ca_to_s (VALUE self)
{
  return rb_ca_dump_binary(0, NULL, self);
}

/* CArray#load_binary(io) — overwrite self's element bytes with ca_length
 * bytes read from io in row-major order.
 *
 * A String arg of the exact length is used directly; anything else
 * must respond to #read(n, buf).  Entity targets read in 64 KiB
 * chunks straight into ca->ptr (peak = ca_length + CHUNK); view
 * targets buffer the full read and recurse via T_STRING because
 * ca_sync_data scatters in one pass. */
static VALUE
rb_ca_load_binary (VALUE self, VALUE io)
{
  CArray *ca;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_object_type(ca) ) {
    rb_raise(rb_eCADataTypeError, "don't load object array");
  }

  switch ( TYPE(io) ) {
  case T_STRING:
    if ( ca_length(ca) != RSTRING_LEN(io) ) {
      rb_raise(rb_eRuntimeError,
               "data size mismatch (got %" PRId64 " bytes, expected %" PRId64 ")",
               (ca_size_t) RSTRING_LEN(io), (ca_size_t) ca_length(ca));
    }
    ca_sync_data(ca, RSTRING_PTR(io));
    return self;
    break;
  default:
    if ( rb_respond_to(io, rb_intern("read") ) ) {
      ca_size_t total = ca_length(ca);
      ID id_read = rb_intern("read");
      if ( ca_is_entity(ca) ) {
        /* Read straight into owned ca->ptr in CHUNK-sized slices. */
        const ca_size_t CHUNK = 65536;
        volatile VALUE scratch = rb_str_buf_new(CHUNK < total ? CHUNK : total);
        ca_size_t off = 0;
        ca_allocate(ca);
        while ( off < total ) {
          ca_size_t want = (total - off < CHUNK) ? (total - off) : CHUNK;
          VALUE r = rb_funcall(io, id_read, 2, SIZE2NUM(want), scratch);
          if ( NIL_P(r) || RSTRING_LEN(r) != want ) {
            ca_detach(ca);
            rb_raise(rb_eRuntimeError,
                     "short read from IO at offset %" PRId64 " "
                     "(got %" PRId64 " bytes, expected %" PRId64 ")",
                     (ca_size_t) off,
                     (ca_size_t) (NIL_P(r) ? 0 : RSTRING_LEN(r)),
                     (ca_size_t) want);
          }
          memcpy(ca->ptr + off, RSTRING_PTR(r), want);
          off += want;
        }
        ca_sync(ca);
        ca_detach(ca);
      }
      else {
        /* ca_sync_data scatters in one pass, so buffer the full read
           and recurse via T_STRING. */
        volatile VALUE buf = rb_funcall(io, id_read, 1, SIZE2NUM(total));
        if ( NIL_P(buf) || RSTRING_LEN(buf) != total ) {
          rb_raise(rb_eRuntimeError,
                   "short read from IO (got %" PRId64 " bytes, expected %" PRId64 ")",
                   (ca_size_t) (NIL_P(buf) ? 0 : RSTRING_LEN(buf)),
                   (ca_size_t) total);
        }
        return rb_ca_load_binary(self, buf);
      }
      return self;
    }
    else {
      rb_raise(rb_eRuntimeError, "IO like object should have 'read' method");
    }
  }

  return self;
}

/* [MOVED] str_format (2.0-era per-element formatter) is replaced by the Ruby
   CArray#format / CArray.format surface in lib/carray/methods/string_format.rb,
   which yields a CAString. */

/* [MOVED] time-related conversion (str_strptime / time_strftime) is
   subsumed by CATime (see lib/carray/time.rb). */

void
Init_carray_conversion (void)
{
  rb_define_method(rb_cCArray, "to_a", rb_ca_to_a, 0);
  rb_define_method(rb_cCArray, "convert", rb_ca_convert, -1);

  rb_define_method(rb_cCArray, "dump_binary", rb_ca_dump_binary, -1);
  rb_define_method(rb_cCArray, "to_s", rb_ca_to_s, 0);
  rb_define_method(rb_cCArray, "load_binary", rb_ca_load_binary, 1);

  /* CAREFUL: do not bind #to_ary — implicit array coercion in Ruby core
     (splat / multiple assignment / Array()) then triggers on any CArray
     and disrupts unrelated call sites. */
  /* rb_define_method(rb_cCArray, "to_ary", rb_ca_to_a, 0); */
}
