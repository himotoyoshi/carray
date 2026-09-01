/* ---------------------------------------------------------------------------

  Core runtime: obj_type registration (ca_install_obj_type), the
  ca_func / ca_class / ca_typeddata dispatch tables, TypedData mark /
  free, the attach lifecycle, and the per-cell / per-region / whole-view
  transfer primitives (ca_xfer_index / _addrs / _stride / _all).

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_enter / _exit */
#include "ca_iter_substrate.h"
#include <stdarg.h>

/* definition of ca_endian */

#ifdef WORDS_BIGENDIAN
const int ca_endian = CA_BIG_ENDIAN;
#else
const int ca_endian = CA_LITTLE_ENDIAN;
#endif

/* definition of variables for ca_func mechanism */

VALUE ca_class[CA_OBJ_TYPE_MAX];
const rb_data_type_t *ca_typeddata[CA_OBJ_TYPE_MAX];
VALUE ca_mask_class[CA_OBJ_TYPE_MAX];
const rb_data_type_t *ca_mask_typeddata[CA_OBJ_TYPE_MAX];
ca_operation_function_t ca_func[CA_OBJ_TYPE_MAX];
int ca_obj_num = 0;

/* 
   definition of validity of each data_type [1 for valid, 0 for invalid]

   The validity is determined in the configuration by extconf.rb.
*/

const int32_t
ca_valid[CA_NTYPE] = {
  1 /* fixlen type */,
#ifdef HAVE_TYPE_INT8_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_INT8_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_UINT8_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_INT16_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_UINT16_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_INT32_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_UINT32_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_INT64_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_UINT64_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_FLOAT32_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_FLOAT64_T
  1,
#else
  0,
#endif
  0, /* CA_FLOAT128 (not built) */
#ifdef HAVE_TYPE_CMPLX64_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_CMPLX128_T
  1,
#else
  0,
#endif
  0, /* CA_CMPLX256 (not built) */
  1
};

/* definition of ca_sizeof, the element data size */

const int32_t
ca_sizeof[CA_NTYPE] = {
  0 /* fixlen type */,
  sizeof(boolean8_t),
  sizeof(int8_t),
  sizeof(uint8_t),
  sizeof(int16_t),
  sizeof(uint16_t),
  sizeof(int32_t),
  sizeof(uint32_t),
  sizeof(int64_t),
  sizeof(uint64_t),
  sizeof(float32_t),
  sizeof(float64_t),
  0, /* float128_t (not built) */
  sizeof(cmplx64_t),
  sizeof(cmplx128_t),
  0, /* cmplx256_t (not built) */
  sizeof(VALUE),
};

/* definition of ca_type_name, the data type name */

const char *
ca_type_name[CA_NTYPE] = {
  "fixlen",
  "boolean",
  "int8",
  "uint8",
  "int16",
  "uint16",
  "int32",
  "uint32",
  "int64",
  "uint64",
  "float32",
  "float64",
  "(retired:float128)",
  "cmplx64",
  "cmplx128",
  "(retired:cmplx256)",
  "object",
};

/*
   casting table for ARRAY -> ARRAY

   test = ca_cast_table[ary1->data_type][ary2->data_type]

   test == 1  -> ary1 should be casted to ary2->data_type
   test == 0  -> ary1 need not to be casted
   test == -1 -> ary1 can't be casted to ary2->data_type,
                                         try casting for ary2 vs ary1
*/

const int
ca_cast_table[CA_NTYPE][CA_NTYPE] = {
/*      fix bol  i8  u8 i16 u16 i32 u32 i64 u64 f32 f64 f12 c64 c12 c25 obj */
/*fix*/ { 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1},
/*bol*/ {-1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/* i8*/ {-1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/* u8*/ {-1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i16*/ {-1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*u16*/ {-1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i32*/ {-1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*u32*/ {-1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i64*/ {-1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1},
/*u64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1},
/*f32*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1},
/*f64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1},
/*f12*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1},
/*c64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1},
/*c12*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1},
/*c25*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1},
/*obj*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0},
};

/*
   casting table for SCALAR -> ARRAY

   test = ca_cast_table[scl->data_type][ary->data_type]

   test == 1  -> scl should be casted to ary->data_type
   test == 0  -> scl need not to be casted
   test == -1 -> scl can't be casted to ary->data_type
*/

const int
ca_cast_table2[CA_NTYPE][CA_NTYPE] = {
/*      fix bol  i8  u8 i16 u16 i32 u32 i64 u64 f32 f64 f12 c64 c12 c25 obj */
/*fix*/ { 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1},
/*bol*/ {-1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/* i8*/ {-1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/* u8*/ {-1, -1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i16*/ {-1, -1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*u16*/ {-1, -1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i32*/ {-1, -1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*u32*/ {-1, -1,  1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i64*/ {-1, -1,  1,  1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1},
/*u64*/ {-1, -1,  1,  1,  1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1},
/*f32*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1},
/*f64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1,  0,  1,  1,  1,  1,  1},
/*f12*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1,  1,  0,  1,  1,  1,  1},
/*c64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1},
/*c12*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1,  0,  1,  1},
/*c25*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1,  1,  0,  1},
/*obj*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0},
};

/* ------------------------------------------------------------------- */

/*
  initialization of fundamental classes
    * CArray
    * CAWrap
    * CScalar
    * CARefer
    * CABlock
    * CASelect
    * CAObject
    * CARepeat
*/

void
ca_init_obj_type (void)
{
  extern ca_operation_function_t ca_array_func;
  extern ca_operation_function_t ca_wrap_func;
  extern ca_operation_function_t ca_scalar_func;
  extern ca_operation_function_t ca_select_func;
  extern ca_operation_function_t ca_object_func;
  extern ca_operation_function_t ca_stride_func;

  /* CArray */
  ca_func[CA_OBJ_ARRAY]       = ca_array_func;
  ca_class[CA_OBJ_ARRAY]      = rb_cCArray;
  ca_typeddata[CA_OBJ_ARRAY]  = &carray_data_type;
  ca_mask_class[CA_OBJ_ARRAY]     = rb_cCArrayMask;
  ca_mask_typeddata[CA_OBJ_ARRAY] = &carray_mask_data_type;

  /* CAWrap */
  ca_func[CA_OBJ_ARRAY_WRAP]  = ca_wrap_func;
  ca_class[CA_OBJ_ARRAY_WRAP] = rb_cCAWrap;
  ca_typeddata[CA_OBJ_ARRAY_WRAP] = &cawrap_data_type;
  ca_mask_class[CA_OBJ_ARRAY_WRAP] = rb_cCArrayMask;
  ca_mask_typeddata[CA_OBJ_ARRAY_WRAP] = &carray_mask_data_type;

  /* CAScalar */
  ca_func[CA_OBJ_SCALAR]      = ca_scalar_func;
  ca_class[CA_OBJ_SCALAR]     = rb_cCScalar;
  ca_typeddata[CA_OBJ_SCALAR] = &cscalar_data_type;
  ca_mask_class[CA_OBJ_SCALAR] = rb_cCArrayMask;
  ca_mask_typeddata[CA_OBJ_SCALAR] = &carray_mask_data_type;

  /* CARefer (CAStride subclass).  The function table is
     installed as ca_stride_func here as a baseline; Init_ca_obj_refer
     overrides ca_func[CA_OBJ_REFER] with a copy that has custom
     free_object (frees the mask0 tail) and custom create_mask
     (handles byte-reinterpret cases). */
  ca_func[CA_OBJ_REFER]       = ca_stride_func;
  ca_class[CA_OBJ_REFER]      = rb_cCARefer;
  ca_typeddata[CA_OBJ_REFER]  = &carefer_data_type;
  ca_mask_class[CA_OBJ_REFER] = rb_cCAReferMask;
  ca_mask_typeddata[CA_OBJ_REFER] = &carefer_mask_data_type;

  /* CABlock (CAStride subclass).  Baseline registered to
     ca_stride_func; Init_ca_obj_block overrides with a copy that has
     custom free_object (frees the tail arrays) and custom create_mask
     (builds the mask as a CABlock with matching block parameters). */
  ca_func[CA_OBJ_BLOCK]       = ca_stride_func;
  ca_class[CA_OBJ_BLOCK]      = rb_cCABlock;
  ca_typeddata[CA_OBJ_BLOCK]  = &cablock_data_type;
  ca_mask_class[CA_OBJ_BLOCK] = rb_cCABlockMask;
  ca_mask_typeddata[CA_OBJ_BLOCK] = &cablock_mask_data_type;

  /* CASelect */
  ca_func[CA_OBJ_SELECT]      = ca_select_func;
  ca_class[CA_OBJ_SELECT]     = rb_cCASelect;
  ca_typeddata[CA_OBJ_SELECT] = &caselect_data_type;
  ca_mask_class[CA_OBJ_SELECT] = rb_cCASelectMask;
  ca_mask_typeddata[CA_OBJ_SELECT] = &caselect_mask_data_type;

  /* CAObject */
  ca_func[CA_OBJ_OBJECT]      = ca_object_func;
  ca_class[CA_OBJ_OBJECT]     = rb_cCAObject;
  ca_typeddata[CA_OBJ_OBJECT] = &caobject_data_type;
  ca_mask_class[CA_OBJ_OBJECT] = rb_cCArrayMask;
  ca_mask_typeddata[CA_OBJ_OBJECT] = &carray_mask_data_type;

  /* CARepeat (subclass of CAStride; shares its function table and
     TypedData entirely). */
  ca_func[CA_OBJ_REPEAT]      = ca_stride_func;
  ca_class[CA_OBJ_REPEAT]     = rb_cCARepeat;
  ca_typeddata[CA_OBJ_REPEAT] = &castride_data_type;
  ca_mask_class[CA_OBJ_REPEAT] = rb_cCARepeatMask;
  ca_mask_typeddata[CA_OBJ_REPEAT] = &castride_mask_data_type;


  ca_obj_num = 9;
}

/* api: ca_install_obj_type
   regsters a sub-class of CArray 
*/

int
ca_install_obj_type (VALUE klass,
                     const rb_data_type_t *typeddata,
                     VALUE mask_klass,
                     const rb_data_type_t *mask_typeddata,
                     const ca_operation_function_t *func,
                     size_t func_size)
{
  int obj_type  = ca_obj_num++;

  if ( ca_obj_num >= CA_OBJ_TYPE_MAX ) {
    rb_raise(rb_eRuntimeError,
             "internal: too many CArray object types installed <CA_OBJ_TYPE_MAX = %i>",
             CA_OBJ_TYPE_MAX);
  }

  if ( func_size > sizeof(ca_operation_function_t) ) {
    rb_raise(rb_eRuntimeError,
             "operation table is larger than this carray's (%zu > %zu); "
             "the caller was built against a newer carray",
             func_size, sizeof(ca_operation_function_t));
  }

  /* Everything from xfer_index on was appended after the table's first
     shape, so a caller may legitimately stop short of it.  Anything shorter
     than that cannot dispatch at all. */
  if ( func_size < offsetof(ca_operation_function_t, xfer_index) ) {
    rb_raise(rb_eRuntimeError,
             "operation table is too small to dispatch (%zu < %zu)",
             func_size,
             (size_t) offsetof(ca_operation_function_t, xfer_index));
  }

  /* Copy by the caller's length and zero the rest: slots this build knows
     about but the caller does not are NULL, which every dispatcher already
     reads as "not provided". */
  MEMZERO(&ca_func[obj_type], ca_operation_function_t, 1);
  memcpy(&ca_func[obj_type], func, func_size);
  ca_func[obj_type].obj_type = obj_type;

  ca_class[obj_type] = klass;
  ca_typeddata[obj_type]  = typeddata;
  ca_mask_class[obj_type] = mask_klass;
  ca_mask_typeddata[obj_type]  = mask_typeddata;

  return obj_type;
}

/* ------------------------------------------------------------------- */

/* api: ca_mark
   mark function for any carray object
*/

void
ca_mark (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ca_is_object_type(ca) ) {    /* object type array */
    if ( ca_is_attached(ca) ) { /* entity array */
      VALUE *p = (VALUE*) ca->ptr;
      ca_size_t n = ca->elements;
      while ( n-- ) {
        rb_gc_mark(*p++);
      }
    }
  }
}

/* api: ca_free
   free function for the carray object needs free operation.
*/

void
ca_free (void *ap)
{
  if ( ap ) {
    CArray *ca = (CArray *) ap;
    ca_func[ca->obj_type].free_object(ca); /* delegate */
  }
}

/* api: ca_free_nop
   (dummy) free function for the carray object does not need free operation.
*/

void
ca_free_nop (void *ap)
{
}

/* ------------------------------------------------------------------- */

/* Returns true iff ca_attach(ca) is essentially O(1) (= no malloc /
   copy):
     - entity arrays (CA_REAL_ARRAY: already attached, ca->ptr valid)
     - CAStride-family views whose composed strides are row-major
       contiguous (the alias path takes parent->ptr + base_offset
       without allocating)
   Used by kernel_iterator's L1 alias decision (ca_iter_can_alias level 1)
   and by overlay view dispatch.  The name says "is_alias" (a structural
   property) rather than "is_cheap" (a cost claim): the predicate checks
   whether ca can be aliased without materialise. */
int
ca_attach_is_alias (void *ap)
{
  CArray *ca = (CArray *) ap;
  extern ca_operation_function_t ca_stride_func;
  extern ca_operation_function_t ca_lazy_marker_func;
  extern int ca_stride_is_contiguous (CAStride *ca);
  extern int ca_stride_attach_aliases_root (CAStride *ca);

  if ( ca == NULL ) return 0;
  if ( ca_is_entity(ca) )  return 1;

  /* CALazyMarker's attach is literally `ca->ptr = ca->parent->ptr` after
     attaching the parent — it adds no layout of its own — so it aliases
     exactly when its parent does.  Without this a marker looks expensive
     to every caller and views built on it fall onto materialising paths,
     even though there is nothing between the marker and real memory. */
  if ( ca_func[ca->obj_type].attach == ca_lazy_marker_func.attach ) {
    return ca_attach_is_alias(((CAView *) ca)->parent);
  }

  /* CAStride family share ca_stride_func.attach (= ca_stride_func_attach).
     The alias-attach fast path is taken iff composed strides are
     row-major contiguous.  ca_stride_is_contiguous checks the leaf
     view's own strides, which is what we want — the compose-fold to
     root happens during attach itself; if leaf is contig and parent
     chain is too (transitively, since each CAStride's strides are
     composed against parent's), the alias path fires.

     ...and iff there is parent memory to alias at the end of that fold.
     A non-entity root has none to lend, so attach builds its own buffer
     and writes through ca->ptr reach the root only via ca_sync.  Saying
     "alias" there would let a caller write and skip the sync. */
  if ( ca_func[ca->obj_type].attach == ca_stride_func.attach ) {
    return ca_stride_is_contiguous((CAStride *) ca)
           && ca_stride_attach_aliases_root((CAStride *) ca);
  }
  return 0;
}

/* ------------------------------------------------------------------- */

/* Allocate a reduction-output CArray for kernel_iterator authors.

   Arguments:
     self        Ruby VALUE wrapping the input CArray (source of the reduction).
     slab_axes   sort-ascending list of axis indices that the kernel
                 will walk per slab (= the axes removed from the output).
                 May contain any K in [1..self.ndim]; the helper
                 validates range and uniqueness.
     naxes       length of slab_axes.  Must satisfy 0 < naxes <= self.ndim.
     data_type   output data_type (CA_INT32 / CA_FLOAT64 / ... — any numeric
                 data_type with non-zero ca_sizeof[]).  May differ from
                 self's data_type (e.g. mean of int32 → float64).

   Output shape:
     - Partial reduction (naxes < self.ndim): self.dim with slab axes
       removed in ascending order, ndim = self.ndim - naxes.
     - Full reduction (naxes == self.ndim): shape [1] 1-D CArray
       (kernel writes op[0] and the author wraps the result to a Ruby
       Float / CScalar at their own discretion).

   Same axis-validation rules as init_l2 CA_SLAB_AXES (= duplicates and
   out-of-range raise ArgumentError so author input bugs surface here
   rather than at the slab walk).  Mask is NULL on the output (=
   reduction kernels populate it themselves if needed). */
VALUE
rb_ca_new_reduced_bytes (VALUE self, int8_t *slab_axes, int8_t naxes,
                         int32_t data_type, ca_size_t bytes, int keep_axis)
{
  CArray *ca;
  int8_t  k;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( naxes <= 0 || naxes > ca->ndim ) {
    rb_raise(rb_eArgError,
             "rb_ca_new_reduced: naxes=%d invalid for ndim=%d",
             (int) naxes, (int) ca->ndim);
  }

  int8_t in_slab[CA_RANK_MAX];
  for ( k = 0; k < CA_RANK_MAX; k++ ) in_slab[k] = 0;
  for ( k = 0; k < naxes; k++ ) {
    int8_t ax = slab_axes[k];
    if ( ax < 0 || ax >= ca->ndim ) {
      rb_raise(rb_eArgError,
               "rb_ca_new_reduced: slab_axes[%d]=%d out of range [0, %d)",
               (int) k, (int) ax, (int) ca->ndim);
    }
    if ( in_slab[ax] ) {
      rb_raise(rb_eArgError,
               "rb_ca_new_reduced: duplicate axis %d in slab_axes", (int) ax);
    }
    in_slab[ax] = 1;
  }

  ca_size_t out_dim[CA_RANK_MAX];
  int8_t    out_ndim = 0;
  for ( k = 0; k < ca->ndim; k++ ) {
    if ( !in_slab[k] ) {
      out_dim[out_ndim++] = ca->dim[k];
    }
    else if ( keep_axis ) {
      /* keep_axis: retain each reduced axis as a length-1 axis instead
         of dropping it (= automation of view[..., :_]).
         Element count and row-major order are unchanged, so the kernel
         slab walk writes the output identically. */
      out_dim[out_ndim++] = 1;
    }
  }
  if ( out_ndim == 0 ) {
    /* Full reduction without keep_axis: collapse to a 1-element array.
       (With keep_axis, full reduction already produced [1, 1, ..., 1]
       above so out_ndim == ca->ndim and this branch is not taken.) */
    out_dim[0] = 1;
    out_ndim   = 1;
  }

  if ( data_type < 0 || data_type >= CA_NTYPE ) {
    rb_raise(rb_eArgError,
             "rb_ca_new_reduced: data_type=%d out of range", (int) data_type);
  }
  if ( bytes <= 0 ) {
    rb_raise(rb_eArgError,
             "rb_ca_new_reduced: bytes=%ld invalid for data_type=%d",
             (long) bytes, (int) data_type);
  }

  return rb_carray_new(data_type, out_ndim, out_dim, bytes, NULL);
}

/* Fixed-element-size wrapper: the byte width is looked up from ca_sizeof,
   which rejects CA_FIXLEN / CA_OBJECT (runtime-width / VALUE cells).  A
   reduction whose output is a runtime-width data_type (fixlen min / max)
   must call rb_ca_new_reduced_bytes with the source's own byte width. */
VALUE
rb_ca_new_reduced (VALUE self, int8_t *slab_axes, int8_t naxes, int32_t data_type,
                   int keep_axis)
{
  if ( data_type < 0 || data_type >= CA_NTYPE ) {
    rb_raise(rb_eArgError,
             "rb_ca_new_reduced: data_type=%d out of range", (int) data_type);
  }
  ca_size_t bytes = ca_sizeof[data_type];
  if ( bytes <= 0 ) {
    rb_raise(rb_eArgError,
             "rb_ca_new_reduced: data_type=%d unsupported (CA_FIXLEN/OBJECT not supported)",
             (int) data_type);
  }
  return rb_ca_new_reduced_bytes(self, slab_axes, naxes, data_type, bytes, keep_axis);
}

/* ------------------------------------------------------------------- */

/* Parse the variadic axis argument of a reduction kernel into a
   sort-ascending
   int8_t array, with full validation.

   Accepts:
     - Integer args:     kernel(0, 2, 3)        → axes = {0, 2, 3}
     - Single Array arg: kernel([0, 2, 3])      → axes = {0, 2, 3}
     - Negative axes (Python-style): -1 = innermost, normalised to
       positive in-range indices before validation

   Validation (raises ArgumentError on failure):
     - argc == 0                          → no axes given
     - naxes > ca->ndim                   → too many axes
     - any axis out of [0, ca->ndim)      → range
     - duplicate axes                     → duplicate

   Returns the validated naxes (= count of axes written to out_axes[]).
   out_axes[] is filled with the parsed axes in *input order* (= NOT
   pre-sorted; canonicalisation to ascending order happens inside
   init_l2 CA_SLAB_AXES, so callers can pass the user's order directly). */
/* Core validation: takes raw items[] (each must be Integer / Symbol-able
   to NUM2SIZE) of length `count`, normalises + range-checks + duplicate-
   checks, fills out_axes[] in input order.  Shared between the legacy
   variadic entry (rb_ca_parse_reduce_axes) and the kwarg entry
   (rb_ca_parse_reduce_axes_kw).  ctx is a short label embedded in error
   messages so callers can disambiguate which entry raised. */
static int8_t
parse_axes_items (const VALUE *items, int count, CArray *ca,
                  int8_t *out_axes, const char *ctx)
{
  int    i;
  int8_t seen[CA_RANK_MAX];

  if ( count <= 0 ) {
    rb_raise(rb_eArgError, "%s: empty axes array", ctx);
  }
  if ( count > CA_RANK_MAX ) {
    rb_raise(rb_eArgError,
             "%s: too many axes (%d > CA_RANK_MAX=%d)",
             ctx, count, CA_RANK_MAX);
  }
  if ( count > ca->ndim ) {
    rb_raise(rb_eArgError,
             "%s: too many axes (%d > ndim=%d)",
             ctx, count, (int) ca->ndim);
  }

  for ( i = 0; i < CA_RANK_MAX; i++ ) seen[i] = 0;
  for ( i = 0; i < count; i++ ) {
    ca_size_t a = NUM2SIZE(items[i]);
    if ( a < 0 ) a += ca->ndim;
    if ( a < 0 || a >= ca->ndim ) {
      rb_raise(rb_eIndexError,
               "%s: axis %ld out of range [0, %d)",
               ctx, (long) a, (int) ca->ndim);
    }
    if ( seen[a] ) {
      rb_raise(rb_eArgError,
               "%s: duplicate axis %ld", ctx, (long) a);
    }
    seen[a] = 1;
    out_axes[i] = (int8_t) a;
  }

  return (int8_t) count;
}

int8_t
rb_ca_parse_reduce_axes (int argc, VALUE *argv, CArray *ca, int8_t *out_axes)
{
  int    i;

  /* argc == 0 means "full reduction over all axes" -- matches legacy
     CArray#sum etc.  This contract keeps the ki kernels drop-in
     replacements for the legacy stat dispatchers. */
  if ( argc <= 0 ) {
    for ( i = 0; i < ca->ndim; i++ ) {
      out_axes[i] = (int8_t) i;
    }
    return (int8_t) ca->ndim;
  }

  /* Detect single-Array call form: foo([0, 2]) */
  const VALUE *items = (const VALUE *) argv;
  int          count = argc;
  if ( argc == 1 && TYPE(argv[0]) == T_ARRAY ) {
    VALUE arr = argv[0];
    count = (int) RARRAY_LEN(arr);
    items = (const VALUE *) RARRAY_CONST_PTR(arr);
  }

  return parse_axes_items(items, count, ca, out_axes,
                          "rb_ca_parse_reduce_axes");
}

/* Kwarg form of rb_ca_parse_reduce_axes — accepts the `axis:` value as
   extracted by the caller via rb_scan_args(..., "0:", &kw_hash) +
   rb_get_kwargs (or equivalent), and dispatches:

     axis_val == Qnil or Qundef → full reduction (= all axes)
     axis_val Integer           → single axis  (negative normalised)
     axis_val Array of Integer  → multiple axes in input order
     anything else              → TypeError

   Validation (range / duplicates / overflow) is identical to the
   variadic entry.  out_axes[] receives axes in input order.  Returns
   the validated naxes. */
int8_t
rb_ca_parse_reduce_axes_kw_ctx (VALUE axis_val, CArray *ca, int8_t *out_axes,
                                const char *ctx)
{
  int i;

  if ( axis_val == Qnil || axis_val == Qundef ) {
    for ( i = 0; i < ca->ndim; i++ ) {
      out_axes[i] = (int8_t) i;
    }
    return (int8_t) ca->ndim;
  }

  if ( TYPE(axis_val) == T_ARRAY ) {
    int          count = (int) RARRAY_LEN(axis_val);
    const VALUE *items = (const VALUE *) RARRAY_CONST_PTR(axis_val);
    return parse_axes_items(items, count, ca, out_axes, ctx);
  }

  if ( rb_obj_is_kind_of(axis_val, rb_cInteger) ) {
    return parse_axes_items(&axis_val, 1, ca, out_axes, ctx);
  }

  rb_raise(rb_eTypeError,
           "%s: axis: must be nil, Integer, or "
           "Array of Integer (got %"PRIsVALUE")",
           ctx, rb_obj_class(axis_val));
}

int8_t
rb_ca_parse_reduce_axes_kw (VALUE axis_val, CArray *ca, int8_t *out_axes)
{
  return rb_ca_parse_reduce_axes_kw_ctx(axis_val, ca, out_axes,
                                        "rb_ca_parse_reduce_axes_kw");
}

/* ------------------------------------------------------------------- */

/* api: ca_wrap_struct_as
   wraps CArray struct in C -> Ruby's object, with the Ruby class chosen
   by the caller instead of taken from ca_class[obj_type].

   The TypedData tag still comes from obj_type.  Only the class is the
   caller's; the tag is what GetCArray and every dispatch path look at,
   so decoupling the two leaves those paths untouched.  klass must be a
   subclass of the class registered for obj_type -- that is the caller's
   responsibility, not checked here.
*/

VALUE
ca_wrap_struct_as (void *ap, VALUE klass)
{
  CArray *ca = (CArray *) ap;
  return TypedData_Wrap_Struct(klass, ca_typeddata[ca->obj_type], ca);
}

/* api: ca_wrap_struct
   wraps CArray struct in C -> Ruby's object
*/

VALUE
ca_wrap_struct (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ca_wrap_struct_as(ap, ca_class[ca->obj_type]);
}

/* ------------------------------------------------------------------- */

/* calculate index from address.
   Hot path: called per fetch_addr dispatch when the view has no
   dedicated fetch_addr slot (= CAStride family and others that only
   implement fetch_index).  1-D / 2-D / 3-D fast paths skip the
   generic divmod loop; higher-ndim falls through. */

void
ca_addr2index (void *ap, ca_size_t addr, ca_size_t *idx)
{
  CArray *ca = (CArray *) ap;
  ca_size_t *dim = ca->dim;
  int8_t ndim = ca->ndim;
  int8_t i;
  switch (ndim) {
  case 1:
    idx[0] = addr;
    return;
  case 2: {
    ca_size_t d1 = dim[1];
    idx[1] = addr % d1;
    idx[0] = addr / d1;
    return;
  }
  case 3: {
    ca_size_t d1 = dim[1], d2 = dim[2];
    idx[2] = addr % d2;
    addr  /= d2;
    idx[1] = addr % d1;
    idx[0] = addr / d1;
    return;
  }
  default:
    for (i = ndim - 1; i >= 0; i--) {
      idx[i] = addr % dim[i];
      addr  /= dim[i];
    }
  }
}

/* calculate address from index.  1-D / 2-D / 3-D fast paths skip the
   loop entirely.  Compiler typically inlines the generic loop fine
   but the fast paths help where this function is called via pointer. */

ca_size_t
ca_index2addr (void *ap, ca_size_t *idx)
{
  CArray  *ca  = (CArray *) ap;
  ca_size_t *dim = ca->dim;
  int8_t ndim = ca->ndim;
  int8_t i;
  ca_size_t n;
  switch (ndim) {
  case 1:
    return idx[0];
  case 2:
    return dim[1] * idx[0] + idx[1];
  case 3:
    return (dim[1] * idx[0] + idx[1]) * dim[2] + idx[2];
  default:
    n = idx[0];
    for (i = 1; i < ndim; i++) {
      n = dim[i] * n + idx[i];
    }
    return n;
  }
}

/* ------------------------------------------------------------------- */

/* The cyclic reference detection should be done in 
     + ca_fetch_addr, ca_fetch_index,
     + ca_store_addr, ca_store_index,
  to avoid the system stack error in reference of the object array.
*/

void
ca_set_cyclic_check(void *ap)
{
  CArray *ca = (CArray *) ap;
  /* ca.data_type == CA_OBJECT */
  if ( ca_is_object_type(ca) ) {
    if ( ca->flags & CA_FLAG_CYCLE_CHECK ) {
      rb_raise(rb_eRuntimeError, "cyclic reference is not allowed in CArray");
    }
    ca_set_flag(ca, CA_FLAG_CYCLE_CHECK);
  }
}

void
ca_clear_cyclic_check(void *ap)
{
  CArray *ca = (CArray *) ap;
  /* ca.data_type == CA_OBJECT */
  if ( ca_is_object_type(ca) ) {
    ca_unset_flag(ca, CA_FLAG_CYCLE_CHECK);
  }
}

void
ca_test_cyclic_check(void *ap, void *ptr)
{
  CArray *ca = (CArray *) ap;

  /* ca.data_type == CA_OBJECT */
  if ( ca_is_object_type(ca) ) {
    VALUE rval = *(VALUE*) ptr;
    if ( rb_obj_is_carray(rval) ) {
      CArray *cv;
      TypedData_Get_Struct(rval, CArray, &carray_data_type, cv);
      if ( ca_test_flag(cv, CA_FLAG_CYCLE_CHECK) ) {
        rb_raise(rb_eRuntimeError, "cyclic reference is not allowed in CArray");
      }
    }
  }
}

/* ------------------------------------------------------------------- */
/* CArray offers no per-cell ptr accessor (ca_ptr_at_addr /
   ca_ptr_at_index): such a slot is structurally unsafe -- CABitarray /
   CABitfield have no byte-addressable cell, and CAByteSwap / CAFake would
   hand back bytes in the wrong data_type / endian.  Internal code that
   already holds an attached view uses direct `ca->ptr + ca->bytes * addr`
   arithmetic; external ext gems use ca_fetch_addr / ca_fetch_index
   (data_type-correct via the xfer_addrs / xfer_index dispatch) for
   per-cell access. */

/* fetch / store at a single linear address: thin wrappers over
   ca_xfer_addrs. */

void
ca_fetch_addr (void *ap, ca_size_t addr, void *pval)
{
  ca_xfer_addrs(ap, 1, &addr, pval, CA_XFER_GET);
}

void
ca_store_addr (void *ap, ca_size_t addr, void *pval)
{
  ca_xfer_addrs(ap, 1, &addr, pval, CA_XFER_PUT);
}

/* per-cell transfer by multi-dim index.  ca_xfer_index is the primary
   entry; ca_fetch_index / ca_store_index are thin wrappers (kept as
   public C-API for external ext gems).  Every view supplies an
   xfer_index slot. */

static inline void
ca_xfer_index_dispatch (CArray *ca, ca_size_t *idx, void *data, int dir)
{
  if ( ! ca_func[ca->obj_type].xfer_index ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] xfer_index not defined for object type <%i>",
             ca->obj_type);
  }
  ca_func[ca->obj_type].xfer_index(ca, idx, data, dir);
}

struct ca_xfer_index_args {
  CArray    *ca;
  ca_size_t *idx;
  char      *ptr;
};

static VALUE
ca_xfer_index_get_body (VALUE arg)
{
  struct ca_xfer_index_args *d = (struct ca_xfer_index_args *) arg;
  ca_xfer_index_dispatch(d->ca, d->idx, d->ptr, CA_XFER_GET);
  ca_test_cyclic_check(d->ca, d->ptr);
  return Qnil;
}

void
ca_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CArray *ca = (CArray *) ap;

  if ( dir == CA_XFER_PUT && ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "can not store data to read-only array");
  }

  /* Fast path: non-CA_OBJECT element type needs no GC protection. */
  if ( ca->data_type != CA_OBJECT ) {
    ca_xfer_index_dispatch(ca, idx, data, dir);
    return;
  }

  /* CA_OBJECT slow path: cyclic check (+ rb_protect on GET). */
  if ( dir == CA_XFER_GET ) {
    struct ca_xfer_index_args args;
    int state = 0;
    args.ca  = ca;
    args.idx = idx;
    args.ptr = (char *) data;
    ca_set_cyclic_check(ca);
    rb_protect(ca_xfer_index_get_body, (VALUE) &args, &state);
    ca_clear_cyclic_check(ca);
    if ( state ) {
      rb_jump_tag(state);
    }
  }
  else {
    ca_set_cyclic_check(ca);
    ca_xfer_index_dispatch(ca, idx, data, CA_XFER_PUT);
    ca_clear_cyclic_check(ca);
  }
}

/* fetch data of the element at given index to memory pointed by pval */

void
ca_fetch_index (void *ap, ca_size_t *idx, void *pval)
{
  ca_xfer_index(ap, idx, pval, CA_XFER_GET);
}

/* store value pointed by pval to the element at given index */

void
ca_store_index (void *ap, ca_size_t *idx, void *pval)
{
  ca_xfer_index(ap, idx, pval, CA_XFER_PUT);
}

/* gather / scatter over a list of linear addresses.  ca_xfer_addrs is the
   primary addr entry; ca_fetch_addr / ca_store_addr are thin wrappers
   (kept as public C-API for external ext gems).

   Dispatch core (no GC protection; caller handles CA_OBJECT):
     1. ca->ptr present (entity / attached / alias) -> direct memcpy at addr.
     2. xfer_addrs slot -> use it (every view supplies one). */

/* Detect a sequential addr run (addrs[i] == addrs[0] + i for all i) so a
   single bulk memcpy replaces the per-cell loop.  O(n) integer compare
   with early-exit on first mismatch.  This fires for dominant-true mask
   workloads (ca[:is_not_masked] += v etc.): when the boolean is mostly
   TRUE, the view->parent addr remap degenerates to [0..n-1]. */
int
ca_xfer_addrs_is_sequential_run (ca_size_t n, ca_size_t *addrs,
                                 ca_size_t *base_out)
{
  ca_size_t base, i;
  if ( n == 0 ) { *base_out = 0; return 1; }
  base = addrs[0];
  for ( i = 1; i < n; i++ ) {
    if ( addrs[i] != base + i ) return 0;
  }
  *base_out = base;
  return 1;
}

static void
ca_xfer_addrs_dispatch (CArray *ca, ca_size_t n, ca_size_t *addrs,
                        void *data, int dir)
{
  char     *d = (char *) data;
  ca_size_t i, base;

  if ( ca->ptr ) {                 /* attached / entity / alias: fast path */
    if ( ca_xfer_addrs_is_sequential_run(n, addrs, &base) ) {
      /* Sequential-run fast path: single bulk memcpy.  Triggered by any
         sub-region run ([k..k+m-1] form), not whole-view limited.  Safe:
         detection is view-structural (the addr shape, not a workload tag)
         and does not call xfer_all. */
      char *p = ca->ptr + ca->bytes * base;
      ca_size_t nbytes = n * ca->bytes;
      if ( dir == CA_XFER_GET ) memcpy(d, p, nbytes);
      else                      memcpy(p, d, nbytes);
      return;
    }
    /* Per-cell loop for arbitrary (non-sequential) addrs:
       fancy gather/scatter from CASelect 2-D mapper, CSA sparse mask, etc.  */
    for ( i = 0; i < n; i++ ) {
      char *p = ca->ptr + ca->bytes * addrs[i];
      if ( dir == CA_XFER_GET ) memcpy(d + i * ca->bytes, p, ca->bytes);
      else                      memcpy(p, d + i * ca->bytes, ca->bytes);
    }
    return;
  }

  if ( ! ca_func[ca->obj_type].xfer_addrs ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] xfer_addrs not defined for object type <%i>",
             ca->obj_type);
  }
  ca_func[ca->obj_type].xfer_addrs(ca, n, addrs, data, dir);
}

struct ca_xfer_addrs_args {
  CArray    *ca;
  ca_size_t  n;
  ca_size_t *addrs;
  char      *data;
};

static VALUE
ca_xfer_addrs_get_body (VALUE arg)
{
  struct ca_xfer_addrs_args *d = (struct ca_xfer_addrs_args *) arg;
  ca_size_t i;
  ca_xfer_addrs_dispatch(d->ca, d->n, d->addrs, d->data, CA_XFER_GET);
  for ( i = 0; i < d->n; i++ ) {
    ca_test_cyclic_check(d->ca, d->data + i * d->ca->bytes);
  }
  return Qnil;
}

void
ca_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *data, int dir)
{
  CArray *ca = (CArray *) ap;

  if ( dir == CA_XFER_PUT && ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "can not store data to read-only array");
  }

  /* Fast path: non-CA_OBJECT element type needs no GC protection. */
  if ( ca->data_type != CA_OBJECT ) {
    ca_xfer_addrs_dispatch(ca, n, addrs, data, dir);
    return;
  }

  /* CA_OBJECT slow path: cyclic check (+ rb_protect on GET). */
  if ( dir == CA_XFER_GET ) {
    struct ca_xfer_addrs_args args;
    int state = 0;
    args.ca    = ca;
    args.n     = n;
    args.addrs = addrs;
    args.data  = (char *) data;
    ca_set_cyclic_check(ca);
    rb_protect(ca_xfer_addrs_get_body, (VALUE) &args, &state);
    ca_clear_cyclic_check(ca);
    if ( state ) {
      rb_jump_tag(state);
    }
  }
  else {
    ca_set_cyclic_check(ca);
    ca_xfer_addrs_dispatch(ca, n, addrs, data, CA_XFER_PUT);
    ca_clear_cyclic_check(ca);
  }
}

/* gather / scatter over a STRIDED region of the view.  The region is
   described in the view's own byte space:

     base   = Σ starts[k] * native_byte_stride[k]   (the region's first cell,
              starts[] given as a per-axis index into the view's row-major layout)
     cell(idx) byte offset = base + Σ idx[k] * strides[k]   for idx in [0,counts)
     strides[] = SRC access byte strides into the view (NOT a contiguous region;
                 carries sub-sampling / transpose from the composed leaf access)

   data is a CONTIGUOUS caller buffer in row-major order over counts[].  Local
   materialise of the requested region only -- never the whole view.

   One example is CASelect (step = strides[0]/bytes is a view
   access step, data delivered contiguously to the parent).  The boundary wiring
   passes a CAStride leaf's composed access (composed_base, composed_strides,
   leaf->dim) straight through.

   Dispatch core (no GC protection; caller handles CA_OBJECT):
     1. ca->ptr present (entity / attached / alias) -> strided memcpy.
     2. xfer_stride slot -> the view delivers its own region (recurse / cast /
        gather-translate).
     3. else per cell: byte offset -> flat addr -> index -> ca_xfer_index_dispatch
        (universal fallback, no whole-view attach). */

/* Cache-tiled 2-D transpose fast path (helper for ca_xfer_stride_dispatch).

   ------------------------------------------------------------------------
   PROBLEM
   ------------------------------------------------------------------------
   When the dispatcher detects that slab merge fails (innermost stride is
   not contig at ca->bytes) AND the access pattern looks like a 2-D
   transpose (outer view axis IS source-contig: strides[0] == bytes, inner
   view axis is non-contig: strides[1] != bytes), the naive prefix
   odometer issues counts[0] * counts[1] independent memcpy(_,_,bytes)
   calls.  Each call reads one cell of `bytes` from ca->ptr at a different
   row of source -- with strides[1] huge (e.g. N * 8 for f64), every read
   touches a different cache line and often a different 4 KB page.

   At N=2000 / bytes=8 (parent data_type = float64), this is 4M random
   reads.  DRAM random-access bandwidth bottoms out around 1-2 GB/s, so
   the per-cell loop is dominated by cache-line / page misses on a large
   working set.

   ------------------------------------------------------------------------
   TECHNIQUE: cache-tiled transpose with L1-resident scratch
   ------------------------------------------------------------------------
   Process the iteration space in 32x32 tiles, staging each tile through
   a stack-allocated `scratch` buffer that fits in L1 (32 * 32 * 16 =
   16 KB; bytes <= 16 ceiling).

     Load pass:
       Read `Tj` rows of source contiguously, each `Ti * bytes` long, into
       scratch[j_t * Ti + i_t].  Per-tile DRAM traffic: Tj sequential
       reads of small (256 B at bytes=8) runs.  Outer loop carries source
       row band [sr0..sr0+Tj) -- those rows stay resident in L2 across
       the inner sc0 sweep (32 rows * N * bytes = 512 KB at N=2000, fits
       in any modern L2).

     Store pass:
       For each output row (sc0+i_t), write `Tj` cells contiguously to
       the data buffer.  The source side is the L1-resident scratch read
       at byte stride `Ti * bytes` -- a small constant stride into a
       16 KB region, effectively free.

   The key invariant: BOTH DRAM-facing transfers (the load-pass source
   read and the store-pass data write) are sequential.  Random access is
   confined to the L1 scratch.

   ------------------------------------------------------------------------
   bytes specialisation
   ------------------------------------------------------------------------
   The store pass's inner loop is the hottest path (Ti * Tj memcpy calls
   per tile).  memcpy(_,_,bytes) with a runtime `bytes` defeats the
   compiler's small-constant inlining heuristic, so we dispatch on
   bytes ∈ {1, 2, 4, 8} to a TILED_*_TYPED macro that uses typed pointer
   arithmetic and explicit stores.  At bytes=8 (float64 / int64 -- the
   dominant case for large 2-D workloads) Clang / gcc generate vectorised
   loads/stores for the strided scratch reads.

   bytes=16 (cmplx128) and other unusual widths fall through to a generic
   memcpy loop; correctness is preserved, only the typed-store benefit
   is lost.

   ------------------------------------------------------------------------
   Why not always tile?
   ------------------------------------------------------------------------
   When strides[1] IS contig (== bytes), the slab merge already collapses
   the iteration to a single bulk memcpy.  When strides[0] is also non-
   contig (e.g. strided sub-sampling on BOTH axes), tiling still helps
   but the gains are smaller; we conservatively limit the trigger to
   strides[0] == bytes to keep the fast-path predicate cheap and the
   guarantees unambiguous.

   ------------------------------------------------------------------------
   No attach inside xfer_stride
   ------------------------------------------------------------------------
   CAREFUL: xfer_stride is a per-region delivery primitive; it must not
   invoke ca_attach on `ca` itself or any ancestor.  Doing so would
   short-circuit CAStack's multi-parent design and the general "partial
   materialise instead of whole-view attach" goal.  This helper operates
   strictly on ca->ptr in place. */

#define CA_TILED_TRANSPOSE_2D_TILE 32

/* Non-static so cross-file callers (ca_obj_stride.c) can reuse the same
   tile-block algorithm.  `src_base` points at the strided side's [0,0]
   cell; `dst` is the row-major contig side (M x N over bytes).  `strides[0]`
   = source-contig stride (must equal `bytes`), `strides[1]` = source-strided
   stride.  dir = CA_XFER_GET (strided->contig) / CA_XFER_PUT (contig->strided).

   3 caller sites:
     - ca_xfer_stride_dispatch ca->ptr path (this file)
     - ca_stride_func_xfer_stride root-direct (ca_obj_stride.c)
     - ca_stride_xfer_with_layout general driver (ca_obj_stride.c) */
void
ca_xfer_stride_tiled_transpose_2d (char     *src_base,
                                   ca_size_t bytes_,
                                   ca_size_t *counts,
                                   ca_size_t *strides,
                                   char      *data,
                                   int        dir)
{
  enum { TILE = CA_TILED_TRANSPOSE_2D_TILE };
  char       scratch[TILE * TILE * 16];     /* L1-resident, max bytes = 16 */
  ca_size_t  M = counts[0];   /* view outer = source contig direction */
  ca_size_t  N = counts[1];   /* view inner = source non-contig direction */
  ca_size_t  sr0, sc0, i_t, j_t;

  for ( sr0 = 0; sr0 < N; sr0 += TILE ) {
    ca_size_t Tj = (N - sr0 < TILE) ? (N - sr0) : TILE;
    for ( sc0 = 0; sc0 < M; sc0 += TILE ) {
      ca_size_t Ti = (M - sc0 < TILE) ? (M - sc0) : TILE;

      if ( dir == CA_XFER_GET ) {
        /* Load pass: contig source reads -> scratch[j_t * Ti + i_t]. */
        for ( j_t = 0; j_t < Tj; j_t++ ) {
          char *src_row = src_base
                        + (sr0 + j_t) * strides[1]
                        + sc0 * bytes_;
          memcpy(scratch + j_t * Ti * bytes_, src_row, Ti * bytes_);
        }
        /* Store pass: strided read from L1 scratch + contig write to data
           buffer, dispatched by element width.  bytes={1,2,4,8} use
           typed pointer arithmetic so the compiler can vectorise. */
        #define TILED_GET_TYPED(T)                                      \
          do {                                                          \
            T *scr = (T *) scratch;                                     \
            for ( i_t = 0; i_t < Ti; i_t++ ) {                          \
              T *out = (T *) (data + ((sc0 + i_t) * N + sr0) * sizeof(T)); \
              for ( j_t = 0; j_t < Tj; j_t++ ) {                        \
                out[j_t] = scr[j_t * Ti + i_t];                         \
              }                                                         \
            }                                                           \
          } while (0)
        switch ( bytes_ ) {
          case 1: TILED_GET_TYPED(uint8_t);  break;
          case 2: TILED_GET_TYPED(uint16_t); break;
          case 4: TILED_GET_TYPED(uint32_t); break;
          case 8: TILED_GET_TYPED(uint64_t); break;
          default:
            for ( i_t = 0; i_t < Ti; i_t++ ) {
              char *out_row = data + ((sc0 + i_t) * N + sr0) * bytes_;
              for ( j_t = 0; j_t < Tj; j_t++ ) {
                memcpy(out_row + j_t * bytes_,
                       scratch + (j_t * Ti + i_t) * bytes_, bytes_);
              }
            }
            break;
        }
        #undef TILED_GET_TYPED
      }
      else {  /* CA_XFER_PUT: mirror of GET, data drives writes to ca->ptr. */
        /* Load pass: contig data reads -> scratch (transposed layout). */
        #define TILED_PUT_TYPED(T)                                      \
          do {                                                          \
            T *scr = (T *) scratch;                                     \
            for ( i_t = 0; i_t < Ti; i_t++ ) {                          \
              T *in = (T *) (data + ((sc0 + i_t) * N + sr0) * sizeof(T)); \
              for ( j_t = 0; j_t < Tj; j_t++ ) {                        \
                scr[j_t * Ti + i_t] = in[j_t];                          \
              }                                                         \
            }                                                           \
          } while (0)
        switch ( bytes_ ) {
          case 1: TILED_PUT_TYPED(uint8_t);  break;
          case 2: TILED_PUT_TYPED(uint16_t); break;
          case 4: TILED_PUT_TYPED(uint32_t); break;
          case 8: TILED_PUT_TYPED(uint64_t); break;
          default:
            for ( i_t = 0; i_t < Ti; i_t++ ) {
              char *data_row = data + ((sc0 + i_t) * N + sr0) * bytes_;
              for ( j_t = 0; j_t < Tj; j_t++ ) {
                memcpy(scratch + (j_t * Ti + i_t) * bytes_,
                       data_row + j_t * bytes_, bytes_);
              }
            }
            break;
        }
        #undef TILED_PUT_TYPED
        /* Store pass: contig source writes from scratch. */
        for ( j_t = 0; j_t < Tj; j_t++ ) {
          char *src_row = src_base
                        + (sr0 + j_t) * strides[1]
                        + sc0 * bytes_;
          memcpy(src_row, scratch + j_t * Ti * bytes_, Ti * bytes_);
        }
      }
    }
  }
}

/* Shared strided-region walker for the dispatcher (this file) and the CAStride
   root-direct path (ca_obj_stride.c::ca_stride_func_xfer_stride).  This
   helper consolidates the slab-merge + tile-block + general-driver logic
   both paths use.

   Callers responsibility: compute `src_base` to already include any per-axis
   base offset, supply `src_strides[]` as byte strides matching `counts[]`,
   and provide `data` as a row-major contig buffer over counts in `bytes`-
   per-cell layout.  `dir` is CA_XFER_GET (src -> data) or CA_XFER_PUT
   (data -> src).

   Inner-loop strategy: slab merge (innermost contig run) + 2-D tile-block
   transpose at the inner pair + outer-prefix odometer with per-iter memcpy.
   Inner-loop strategy is NOT shared with ca_stride_xfer_with_layout, which
   uses ca_stride_gather_run / scatter_run typed runs -- intentionally kept
   separate to avoid abstraction over two structurally distinct inner
   strategies. */
void
ca_xfer_strided_walk (char            *src_base,
                      ca_size_t        bytes,
                      int8_t           ndim,
                      const ca_size_t *counts,
                      const ca_size_t *src_strides,
                      char            *data,
                      int              dir)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t doff = 0;
  int8_t    k;

  /* slab merge -- scan innermost contig run (src_strides[k] equals the
     accumulated slab byte size).  This collapses per-cell memcpy(_,_,
     bytes) loops into per-slab memcpy when the source region is row-major
     contig.  Critical for transform views (CAFake / CAByteSwap / CATile)
     calling parent.xfer_stride on (N-2)x(N-2)-style interior regions: the
     inner axis is parent-contig and merges into a single row memcpy. */
  int8_t    slab_start = ndim;
  ca_size_t slab_bytes = bytes;
  for ( k = ndim - 1; k >= 0; k-- ) {
    if ( src_strides[k] != slab_bytes ) break;
    slab_bytes *= counts[k];
    slab_start = k;
  }

  if ( slab_start == 0 ) {       /* whole region is one contig slab */
    if ( dir == CA_XFER_GET ) memcpy(data, src_base, slab_bytes);
    else                      memcpy(src_base, data, slab_bytes);
    return;
  }

  /* Innermost-2-axis tile-block transpose (ndim >= 2 generalisation).
     When slab merge cannot
     collapse the innermost axis but the innermost-1 axis is source-contig
     (= transpose-like at the inner pair), iterate the outer (ndim-2) axes
     on an odometer and apply the 2-D cache-tiled helper to each inner
     (counts[ndim-2] x counts[ndim-1]) block.  ndim == 2 reduces to
     outer_n == 0 -- the odometer runs exactly once with soff == 0 (relative
     to src_base) -- so it is byte-equivalent to the 2-D-only case.
     Helper operates in place on src_base; no attach is invoked. */
  if ( ndim >= 2 && bytes <= 16 &&
       slab_start == ndim &&
       src_strides[ndim-2] == bytes && src_strides[ndim-1] != bytes ) {
    int8_t    outer_n = ndim - 2;
    ca_size_t inner_counts[2]  = { counts[ndim-2],      counts[ndim-1]      };
    ca_size_t inner_strides[2] = { src_strides[ndim-2], src_strides[ndim-1] };
    ca_size_t inner_dst_bytes  = counts[ndim-2] * counts[ndim-1] * bytes;

    for ( k = 0; k < outer_n; k++ ) idx[k] = 0;
    while ( 1 ) {
      ca_size_t soff = 0;
      for ( k = 0; k < outer_n; k++ ) soff += idx[k] * src_strides[k];
      ca_xfer_stride_tiled_transpose_2d(src_base + soff, bytes,
                                         inner_counts, inner_strides,
                                         data + doff, dir);
      doff += inner_dst_bytes;
      if ( outer_n == 0 ) break;
      k = outer_n - 1;
      while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
      if ( k < 0 ) break;
    }
    return;
  }

  /* prefix axes [0..slab_start-1] on odometer, slab-sized memcpy per iter. */
  for ( k = 0; k < slab_start; k++ ) idx[k] = 0;
  while ( 1 ) {
    ca_size_t soff = 0;
    for ( k = 0; k < slab_start; k++ ) soff += idx[k] * src_strides[k];
    if ( dir == CA_XFER_GET ) memcpy(data + doff, src_base + soff, slab_bytes);
    else                      memcpy(src_base + soff, data + doff, slab_bytes);
    doff += slab_bytes;
    k = slab_start - 1;
    while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
    if ( k < 0 ) break;
  }
}

/* See the comment on the prototype in carray.h. */
int
ca_xfer_stride_request_is_axis_box (void *ap, ca_size_t *starts,
                                    ca_size_t *counts, ca_size_t *strides)
{
  CArray   *ca = (CArray *) ap;
  ca_size_t native[CA_RANK_MAX];
  ca_size_t s = ca->bytes;
  int8_t    ndim = ca->ndim, k;

  for ( k = ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }

  for ( k = 0; k < ndim; k++ ) {
    ca_size_t q;
    if ( counts[k] <= 1 ) continue;          /* moves nothing */
    if ( strides[k] <= 0 ) return 0;         /* zero / negative: not an axis walk */
    if ( strides[k] % native[k] != 0 ) return 0;
    q = strides[k] / native[k];
    if ( q < 1 ) return 0;
    if ( starts[k] + (counts[k] - 1) * q >= ca->dim[k] ) return 0;   /* runs off axis k */
  }
  return 1;
}

static void
ca_xfer_stride_dispatch (CArray *ca, ca_size_t *starts, ca_size_t *counts,
                         ca_size_t *strides, void *data, int dir)
{
  char     *d = (char *) data;
  int8_t    ndim = ca->ndim;
  ca_size_t native[CA_RANK_MAX];
  ca_size_t base = 0;
  ca_size_t doff = 0;
  ca_size_t s;
  int8_t    k;
  ca_size_t idx[CA_RANK_MAX];

  s = ca->bytes;
  for ( k = ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ndim; k++ ) base += starts[k] * native[k];

  if ( ca->ptr && d != (char *)ca->ptr + base ) {
    /* attached / entity / alias: strided memcpy.
       CAREFUL: the `d != (char *)ca->ptr + base` guard in the branch
       condition above is load-bearing.  It blocks the lazy-view self-fill
       pattern where data == ca->ptr + base would degenerate into a
       self-memcpy and leave the buffer garbage.  Lazy-view attach funcs
       bypass this dispatcher, but the guard catches any future caller that
       re-introduces the same category error. */
    ca_xfer_strided_walk(ca->ptr + base, ca->bytes, ndim, counts, strides,
                         d, dir);
    return;
  }

  if ( ca_func[ca->obj_type].xfer_stride ) {
    ca_func[ca->obj_type].xfer_stride(ca, starts, counts, strides, data, dir);
    return;
  }

  /* fallback: per-cell via byte offset -> flat addr -> index -> xfer_index. */
  for ( k = 0; k < ndim; k++ ) idx[k] = 0;
  while ( 1 ) {
    ca_size_t soff = base, vidx[CA_RANK_MAX];
    for ( k = 0; k < ndim; k++ ) soff += idx[k] * strides[k];
    ca_addr2index(ca, soff / ca->bytes, vidx);
    ca_xfer_index_dispatch(ca, vidx, d + doff, dir);
    doff += ca->bytes;
    k = ndim - 1;
    while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
    if ( k < 0 ) break;
  }
}

struct ca_xfer_stride_args {
  CArray    *ca;
  ca_size_t *starts;
  ca_size_t *counts;
  ca_size_t *strides;
  char      *data;
};

static VALUE
ca_xfer_stride_get_body (VALUE arg)
{
  struct ca_xfer_stride_args *a = (struct ca_xfer_stride_args *) arg;
  ca_size_t n = 1, i;
  int8_t k;
  ca_xfer_stride_dispatch(a->ca, a->starts, a->counts, a->strides, a->data,
                          CA_XFER_GET);
  /* cyclic check over the delivered cells (CA_OBJECT only).  dst is contiguous
     row-major over counts (semantics b), so cell i is at data + i*bytes. */
  for ( k = 0; k < a->ca->ndim; k++ ) n *= a->counts[k];
  for ( i = 0; i < n; i++ ) {
    ca_test_cyclic_check(a->ca, a->data + i * a->ca->bytes);
  }
  return Qnil;
}

void
ca_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                ca_size_t *strides, void *data, int dir)
{
  CArray *ca = (CArray *) ap;

  if ( dir == CA_XFER_PUT && ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "can not store data to read-only array");
  }

  if ( ca->data_type != CA_OBJECT ) {
    ca_xfer_stride_dispatch(ca, starts, counts, strides, data, dir);
    return;
  }

  if ( dir == CA_XFER_GET ) {
    struct ca_xfer_stride_args args;
    int state = 0;
    args.ca = ca; args.starts = starts; args.counts = counts;
    args.strides = strides; args.data = (char *) data;
    ca_set_cyclic_check(ca);
    rb_protect(ca_xfer_stride_get_body, (VALUE) &args, &state);
    ca_clear_cyclic_check(ca);
    if ( state ) rb_jump_tag(state);
  }
  else {
    ca_set_cyclic_check(ca);
    ca_xfer_stride_dispatch(ca, starts, counts, strides, data, CA_XFER_PUT);
    ca_clear_cyclic_check(ca);
  }
}

/* whole-view transfer: direction-unified replacement of copy_data /
   sync_data.  Pure dispatch to the view's xfer_all slot.  Readonly /
   nosync policy lives in ca_sync_data (the PUT entry), not here -- this
   is the raw dispatcher.

   CAREFUL: the dispatcher is a thin wrapper (no ca_attach here), and each
   view's xfer_all slot must not ca_attach(parent) either.  That is what
   gives ca_xfer_all and all internal callers (ca_update / ca_copy_data /
   ca_sync_data / kernel_iterator SRC_ATTACH path) their cheap-attach
   semantics; re-adding an attach into a slot silently reintroduces a
   whole-parent materialise.  External ext gems calling ca_xfer_all should
   likewise expect a thin dispatcher. */

typedef struct {
  CArray *ca;
  void   *data;
  int     dir;
} ca_xfer_all_args_t;

static VALUE
ca_xfer_all_body (VALUE arg)
{
  ca_xfer_all_args_t *a = (ca_xfer_all_args_t *) arg;
  ca_func[a->ca->obj_type].xfer_all(a->ca, a->data, a->dir);
  return Qnil;
}

static VALUE
ca_xfer_all_ensure (VALUE arg)
{
  (void) arg;
  ca_lazy_arena_exit();
  return Qnil;
}

void
ca_xfer_all (void *ap, void *data, int dir)
{
  CArray *ca = (CArray *) ap;
  ca_xfer_all_args_t args;
  if ( ! ca_func[ca->obj_type].xfer_all ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] xfer_all not defined for object type <%i>",
             ca->obj_type);
  }
  /* Universal arena lifetime hook.  ca_xfer_all is the single universal
     entry for materialise (to_ca -> ca_copy -> ca_copy_data ->
     ca_xfer_all), so wrapping here covers every outermost view type,
     including an affine view wrapping a lazy view ((a.lazy+b).transpose).

     CAREFUL: the arena _exit must run under rb_ensure.  If an exception
     skips it, the arena depth stays stuck at +1 and the reset trigger
     (a depth==0 entry) never fires -- a silent failure.  With rb_ensure
     the depth returns to 0 on exit and the reset fires correctly at the
     next entry. */
  ca_lazy_arena_enter();
  args.ca = ca; args.data = data; args.dir = dir;
  rb_ensure(ca_xfer_all_body, (VALUE) &args,
            ca_xfer_all_ensure, Qnil);
}

/* ------------------------------------------------------------------- */

/* make ca->ptr to point the allocated memory block */

void
ca_allocate (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ca_is_view(ca) ) {  /* view array */

    CAVIEW(ca)->attach += 1; /* increments attach level */
    if ( CAVIEW(ca)->attach > CA_ATTACH_MAX ) {
      rb_raise(rb_eRuntimeError,
               "too large attach count of view array");
    }

    if ( ! ca->ptr ) {
      ca_func[ca->obj_type].allocate(ap);
    }
  }
  else {                      /* entity array */
    ca_func[ca->obj_type].allocate(ap);
  }

  if ( ca->data_type == CA_OBJECT ) { /* protection against GC */
    volatile VALUE rzero = INT2NUM(0);
    VALUE *p = (VALUE*)ca->ptr;
    ca_size_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = rzero;
    }
  }

  ca_clear_mask(ca); /* ca_update_mask called in ca_clear_mask */
  ca_allocate(ca->mask);
}

/* attach parent's data to ca->ptr */

void
ca_attach (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ca_is_view(ca) ) {  /* view array */

    CAVIEW(ca)->attach += 1; /* increments attach level */
    if ( CAVIEW(ca)->attach > CA_ATTACH_MAX ) {
      rb_raise(rb_eRuntimeError,
               "too large attach count of view array");
    }

    if ( ! ca->ptr ) {
      ca_func[ca->obj_type].attach(ap);
    }
  }
  else {                      /* entity array */
    ca_func[ca->obj_type].attach(ap);
  }

  ca_update_mask(ca);
  ca_attach(ca->mask);
}

/* attach parent's data to ca->ptr */

void
ca_update (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ca_is_view(ca) ) {  /* view array */

    if ( ca->ptr ) {
      ca_xfer_all(ca, ca->ptr, CA_XFER_GET); /* re-gather into own ptr (step 4) */
    }
    else {
      rb_raise(rb_eRuntimeError,
        "[BUG] ca_update() called for not-attached virtal array");
    }

  }

  ca_update_mask(ca);
  ca_update(ca->mask);
}

/* synchronize the data pointed by ca->ptr to parent's memory block */

void
ca_sync (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ! ca->ptr ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] tried to sync data to detached array");
  }

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not modify read-only array");
  }

  ca_update_mask(ca);
  ca_sync(ca->mask);

  if ( ca_is_view(ca) ) {  /* view array */
    if ( ! CAVIEW(ca)->nosync ) { /* FIXME : */
      ca_func[ca->obj_type].sync(ap);
    }
  }
  else {                      /* enitity array */
    ca_func[ca->obj_type].sync(ap);
  }

}

/* make ca->ptr to be detached */

void
ca_detach (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ! ca->ptr ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] tried to detach a detached array");
  }

  if ( ca_is_view(ca) ) {  /* view array */
    if ( CAVIEW(ca)->attach == 1 ) {
      ca_func[ca->obj_type].detach(ap);
    }
    CAVIEW(ca)->attach -= 1;
  }
  else {                      /* entity array */
    ca_func[ca->obj_type].detach(ap);
  }

  ca_update_mask(ca);
  ca_detach(ca->mask);
}

/* multiple versions of ca_allocate, ca_attach, ca_sync, ca_detach */

void
ca_allocate_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca_allocate(va_arg(args, CArray *));
  }
  va_end(args);
}

void
ca_attach_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca_attach(va_arg(args, CArray *));
  }
  va_end(args);
}

void
ca_update_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca_update(va_arg(args, CArray *));
  }
  va_end(args);
}

void
ca_sync_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca_sync(va_arg(args, CArray *));
  }
  va_end(args);
}

void
ca_detach_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- )
    ca_detach(va_arg(args, CArray *));
  va_end(args);
}

/* ------------------------------------------------------------------- */

/* attach parent's data to given pointer, not to ca->ptr */

void
ca_copy_data (void *ap, char *ptr)
{
  ca_xfer_all(ap, ptr, CA_XFER_GET); /* whole-view gather (step 4) */
}

/* synchronize the data pointed by given pointer to parent's data */

void
ca_sync_data (void *ap, char *ptr)
{
  CArray *ca = (CArray *) ap;

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not sync data to read-only array");
  }

  if ( ca_is_view(ca) && CAVIEW(ca)->nosync ) {
    /* ca is to be attached: treat ca->ptr as an owned entity buffer */
    ca_array_func_xfer_all(ap, ptr, CA_XFER_PUT);
  }
  else {
    ca_xfer_all(ap, ptr, CA_XFER_PUT); /* whole-view scatter (step 4) */
  }
}

/* fill data from given pointer */

void
ca_fill_data (void *ap, void *aptr)
{
  CArray *ca = (CArray *) ap;
  char *ptr = (char *) aptr;

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not fill data to read-only array");
  }

  if ( ca_is_view(ca) ) {   /* view array */
    if ( ca_is_attached(ca) ) { /* ca is to be attached */
      ca_func[CA_OBJ_ARRAY].fill_data(ap, ptr);
    }
    else {
      ca_func[ca->obj_type].fill_data(ap, ptr);
    }
  }
  else {                       /* entity array */
    ca_func[ca->obj_type].fill_data(ap, ptr);
  }
}

/* Write one value into part of a view.

   The default walks the region and hands each cell to xfer_index, which
   composes one hop and delegates to the parent.  It is per-cell, so it is the
   floor rather than the path: a view that can pass the region on fills in the
   slot and the walk never happens.  What the default guarantees is that a view
   with no slot still touches only the region. */

void
ca_fill_stride_default (void *ap, ca_size_t base, int8_t ndim,
                        ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CArray   *ca = (CArray *) ap;
  ca_size_t idx[CA_RANK_MAX];
  int8_t    k;

  for ( k = 0; k < ndim; k++ ) idx[k] = 0;
  while ( 1 ) {
    ca_size_t addr = base, vidx[CA_RANK_MAX];
    for ( k = 0; k < ndim; k++ ) addr += idx[k] * steps[k];
    ca_addr2index(ca, addr, vidx);
    ca_xfer_index_dispatch(ca, vidx, ptr, CA_XFER_PUT);
    k = ndim - 1;
    while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
    if ( k < 0 ) break;
  }
}

void
ca_fill_stride (void *ap, ca_size_t base, int8_t ndim,
                ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CArray *ca = (CArray *) ap;
  int8_t  k;

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "can not fill data to read-only array");
  }

  for ( k = 0; k < ndim; k++ ) {
    if ( counts[k] <= 0 ) return;
  }

  if ( ca_func[ca->obj_type].fill_stride ) {
    ca_func[ca->obj_type].fill_stride(ap, base, ndim, counts, steps, ptr);
    return;
  }

  ca_fill_stride_default(ap, base, ndim, counts, steps, ptr);
}

/* True if the region is exactly `ca`'s own extent in row-major order.  A view
   that composes its axes into its parent's space can only do so for the whole
   of itself: a sub-box arrives as addresses, and recovering which axis each
   step belongs to is not something addresses can answer once the view has
   reordered or dropped axes.  In practice that is the only region a view is
   asked for -- ca_fill_stride_whole is the caller -- so the check is a
   precondition rather than a fast path. */

int
ca_fill_stride_is_whole (void *ap, ca_size_t base, int8_t ndim,
                         ca_size_t *counts, ca_size_t *steps)
{
  CArray   *ca = (CArray *) ap;
  ca_size_t s = 1;
  int8_t    k;

  if ( base != 0 || ndim != ca->ndim ) return 0;
  for ( k = ndim - 1; k >= 0; k-- ) {
    if ( counts[k] != ca->dim[k] || steps[k] != s ) return 0;
    s *= ca->dim[k];
  }
  return 1;
}

/* "All of me" as a region: the whole extent in row-major order. */

void
ca_fill_stride_whole (void *ap, void *ptr)
{
  CArray   *ca = (CArray *) ap;
  ca_size_t counts[CA_RANK_MAX], steps[CA_RANK_MAX];
  ca_size_t s = 1;
  int8_t    k;

  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    counts[k] = ca->dim[k];
    steps[k]  = s;
    s *= ca->dim[k];
  }
  ca_fill_stride(ap, 0, ca->ndim, counts, steps, ptr);
}

void
ca_fill_addrs_default (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr)
{
  CArray   *ca = (CArray *) ap;
  ca_size_t i;

  for ( i = 0; i < n; i++ ) {
    ca_size_t vidx[CA_RANK_MAX];
    ca_addr2index(ca, addrs[i], vidx);
    ca_xfer_index_dispatch(ca, vidx, ptr, CA_XFER_PUT);
  }
}

/* Walk a region and hand its addresses on in windows.

   For a view whose fill is a read-modify-write of the parent -- the sub-byte
   ones, where a cell carries bits the fill must leave alone -- there is no
   region to pass down: the parent has to be read before it can be written.
   What there is to save is being asked for it one cell at a time, each cell
   descending the chain on its own.  The batched address slot already does the
   read and the write in one call each; this only feeds it.

   The window is fixed so the scratch does not follow the region's size. */

#define CA_FILL_ADDR_WINDOW 1024

void
ca_fill_stride_via_addrs (void *ap, ca_size_t base, int8_t ndim,
                          ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CArray   *ca = (CArray *) ap;
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t window[CA_FILL_ADDR_WINDOW];
  ca_size_t n = 0;
  int8_t    k;

  for ( k = 0; k < ndim; k++ ) {
    if ( counts[k] <= 0 ) return;
    idx[k] = 0;
  }

  while ( 1 ) {
    ca_size_t addr = base;
    for ( k = 0; k < ndim; k++ ) addr += idx[k] * steps[k];
    window[n++] = addr;
    if ( n == CA_FILL_ADDR_WINDOW ) {
      ca_fill_addrs(ca, n, window, ptr);
      n = 0;
    }
    k = ndim - 1;
    while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
    if ( k < 0 ) break;
  }
  if ( n ) {
    ca_fill_addrs(ca, n, window, ptr);
  }
}

void
ca_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr)
{
  CArray *ca = (CArray *) ap;

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "can not fill data to read-only array");
  }

  if ( ca_func[ca->obj_type].fill_addrs ) {
    ca_func[ca->obj_type].fill_addrs(ap, n, addrs, ptr);
    return;
  }

  ca_fill_addrs_default(ap, n, addrs, ptr);
}

/* ------------------------------------------------------------------- */

/* clone CArray struct */

void *
ca_clone (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ca_func[ca->obj_type].clone(ap);
}

/* fill parent's data with the data pointed by aptr */

void
ca_fill (void *ap, void *aptr)
{
  CArray *ca = (CArray *) ap;
  char *ptr = (char *) aptr;

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "can't fill read-only carray");
  }

  ca_fill_data(ap, ptr);
}

/* ------------------------------------------------------------------- */

/* subroutines for CArray.attach, CArray.attach!
                   CArray#attach, CArray#attach! */

static void
rb_ca_attach_i (VALUE self)
{
  CArray *ca;
  if ( rb_obj_is_carray(self) ) {
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    ca_attach(ca);
    if ( ca_is_view(ca) ) {
      CAVIEW(ca)->nosync += 1;
      if ( CAVIEW(ca)->nosync > 64 ) {
        rb_raise(rb_eRuntimeError, "nosync count exceeds 64");
      }
    }
  }
}

static void
rb_ca_sync_i (VALUE self)
{
  CArray *ca;
  if ( rb_obj_is_carray(self) ) {
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    if ( ca_is_view(ca) ) {
      CAVIEW(ca)->nosync -= 1;
      ca_sync(ca);
      CAVIEW(ca)->nosync += 1;
    }
    else {
      ca_sync(ca);
    }
  }
}

static void
rb_ca_detach_i (VALUE self) 
{
  CArray *ca;
  if ( rb_obj_is_carray(self) ) {
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    if ( ca_is_view(ca) ) {   /* view array */
      CAVIEW(ca)->nosync -= 1;
      ca_detach(ca);
    }
    else {                       /* entity array */
      ca_detach(ca);
    }
  }
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_s_ensure_detach (VALUE list)
{
  volatile VALUE obj;
  int i;

  for (i=0; i<RARRAY_LEN(list); i++) {
    obj = rb_ary_entry(list, i);
    rb_ca_detach_i(obj);
  }

  return Qnil;
}

/* @overload attach (*arrays)

(Internal) Guarantees that the reference memory block is attached.
The memory block is detached at the end of the block evaluation.
It is not ensured the syncing the memory block at the end of the block evaluation.

@yield
*/

static VALUE
rb_ca_s_attach (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE list, obj;
  int i;

  list = rb_ary_new4(argc, argv);

  for (i=0; i<RARRAY_LEN(list); i++) {
    obj = rb_ary_entry(list, i);
    rb_ca_attach_i(obj);
  }

  return rb_ensure(rb_yield_splat, list, rb_ca_s_ensure_detach, list);
}

static VALUE
rb_ca_s_ensure_sync_detach (VALUE list)
{
  volatile VALUE obj;
  int i;

  for (i=0; i<RARRAY_LEN(list); i++) {
    obj = rb_ary_entry(list, i);
    rb_ca_sync_i(obj);
    rb_ca_detach_i(obj);
  }

  return Qnil;
}

/* @overload attach! (*arrays)

(Internal) Guarantees that the reference memory block is attached.
The memory block is detached at the end of the block evaluation.
It is ensured the syncing the memory block at the end of the block evaluation.

@yield
*/

static VALUE
rb_ca_s_attach_bang (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE list, obj;
  int i;

  list = rb_ary_new4(argc, argv);

  for (i=0; i<RARRAY_LEN(list); i++) {
    obj = rb_ary_entry(list, i);
    rb_check_frozen(obj);
    rb_ca_attach_i(obj);
  }

  return rb_ensure(rb_yield_splat, list, rb_ca_s_ensure_sync_detach, list);
}

static VALUE
rb_ca_ensure_detach (VALUE self)
{
  rb_ca_detach_i(self);
  return Qnil;
}

/* @overload attach 

(Internal) Guarantees that the reference memory block is attached.
The memory block is detached at the end of the block evaluation.
It is ensured the syncing the memory block at the end of the block evaluation.

@yield
*/

static VALUE
rb_ca_attach (VALUE self)
{
  rb_ca_attach_i(self);
  return rb_ensure(rb_yield, self, rb_ca_ensure_detach, self);
}

static VALUE
rb_ca_ensure_sync_detach (VALUE self)
{
  rb_ca_sync_i(self);
  rb_ca_detach_i(self);
  return Qnil;
}

/* @overload attach! 

(Internal) Guarantees that the reference memory block is attached.
The memory block is detached at the end of the block evaluation.
It is ensured the syncing the memory block at the end of the block evaluation.

@yield
*/

static VALUE
rb_ca_attach_bang (VALUE self)
{
  rb_check_frozen(self);
  rb_ca_attach_i(self);
  return rb_ensure(rb_yield, self, rb_ca_ensure_sync_detach, self);
}

/* @overload __attach__ 

(Internal, DevelopperOnly) Attaches the reference memory block.
User must call "CArray#__detach__" appropreate timing.
*/

static VALUE
rb_ca__attach__ (VALUE self)
{
  rb_ca_attach_i(self);
  return self;
}

/* @overload __detach__ 

(Internal, DevelopperOnly) Syncs the reference memory block to the parent array.
*/

static VALUE
rb_ca__sync__ (VALUE self)
{
  rb_check_frozen(self);
  rb_ca_sync_i(self);
  return self;
}

/* @overload __detach__ 

(Internal, DevelopperOnly) Detaches the reference memory block.
*/

static VALUE
rb_ca__detach__ (VALUE self)
{
  rb_ca_detach_i(self);
  return self;
}

/* ------------------------------------------------------------------- */

static ID id_decode, id_encode;

VALUE
rb_ca_data_class_decode (VALUE self, VALUE str)
{
  if ( rb_ca_has_data_class(self) ) {
    volatile VALUE data_class = rb_ca_data_class(self);
    return rb_funcall(data_class, id_decode, 1, str);
  }
  else {
    return str;
  }
}

VALUE
rb_ca_data_class_encode (VALUE self, VALUE obj)
{
  if ( rb_ca_has_data_class(self) ) {
    volatile VALUE data_class = rb_ca_data_class(self);
    if ( rb_obj_is_kind_of(obj, data_class) ) {
      return rb_funcall(obj, id_encode, 0);
    }
  }
  return obj;
}

/* ------------------------------------------------------------------- */

/* @overload members

(Inquiry) Returns data class member names
*/

VALUE
rb_ca_members (VALUE self)
{
  volatile VALUE data_class = rb_ca_data_class(self);
  if ( NIL_P(data_class) ) {
    rb_raise(rb_eRuntimeError, "carray doesn't have data class");
  }
  else {
    return rb_obj_clone(rb_const_get(data_class, rb_intern("MEMBERS")));
  }
}

/* Projects a struct member of `self` to its CAField view.  data_class
   lives only on a Face, so this accepts both a Face and a plain FIXLEN
   entity.  For a Face, the field-view receiver is swapped to the parent
   (= Face strip): the @member cache lives on self (the Face) while the
   actual field view is the CAField on the parent.  A plain FIXLEN entity
   keeps self == receiver. */
VALUE
rb_ca_face_field (VALUE self, VALUE sym)
{
  volatile VALUE data_class = rb_ca_data_class(self);
  volatile VALUE member;
  volatile VALUE obj;
  volatile VALUE receiver;
  CArray *ca;

  if ( NIL_P(data_class) ) {
    rb_raise(rb_eRuntimeError, "carray doesn't have data class");
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  receiver = ca_is_face(ca) ? rb_ca_parent(self) : self;

  member = rb_ivar_get(self, rb_intern("member"));

  if ( NIL_P(member) ) {
    /* Derived CARecord views (= arr[range] / arr.transpose etc.) inherit
       data_class via inherit_data_class but not @member, since only
       ca_record_build initialises it.  Lazy-init here so chain field
       projection (arr[range]["lat"]) works without a [BUG] raise.  Cache
       is local to the derived view; field views are still on its parent
       (which itself is on the entity). */
    member = rb_hash_new();
    rb_ivar_set(self, rb_intern("member"), member);
  }

  if ( rb_obj_is_kind_of(sym, rb_cInteger) ) {
      volatile VALUE member_names = rb_const_get(data_class, rb_intern("MEMBERS"));
      sym = rb_ary_entry(member_names, NUM2SIZE(sym));
      obj = rb_hash_aref(member, sym);
    }
  else {
    obj = rb_hash_aref(member, sym);
    if ( NIL_P(obj) ) {
      sym = rb_funcall(sym, rb_intern("to_s"), 0);
      obj = rb_hash_aref(member, sym);      
    }
  }

  if ( rb_obj_is_carray(obj) ) {
    return obj;
  }
  else {
    volatile VALUE MEMBER_TABLE = rb_const_get(data_class, rb_intern("MEMBER_TABLE"));
    volatile VALUE info = rb_hash_aref(MEMBER_TABLE, sym);
    if ( NIL_P(info) ) {
      if ( TYPE(sym) != T_STRING ) {
        sym = rb_funcall(sym, rb_intern("to_s"), 0);
      }
      rb_raise(rb_eRuntimeError,
               "can't find data_member named <%s>", StringValuePtr(sym));
    }
    Check_Type(info, T_ARRAY);
    /* Bit-typed members route through a CAField power-of-2 byte
       projection + CABitfield, mirroring the
       per-record dispatch in CAStruct#[].  MEMBER_TABLE entry shape
       for bits is `[byte_offset, :bitfield, {bits:, bit_offset:}]`
       where bit_offset is the struct-relative *bit* offset.  Plain
       byte-typed members fall through to the original `.field(...)`
       path. */
    {
      volatile VALUE type_val = rb_ary_entry(info, 1);
      if ( SYMBOL_P(type_val) &&
           SYM2ID(type_val) == rb_intern("bitfield") ) {
        volatile VALUE opts = rb_ary_entry(info, 2);
        volatile VALUE word_view, range, vtype_sym;
        ca_size_t bit_offset = NUM2SIZE(rb_hash_aref(opts,
                                                ID2SYM(rb_intern("bit_offset"))));
        ca_size_t bits       = NUM2SIZE(rb_hash_aref(opts,
                                                ID2SYM(rb_intern("bits"))));
        ca_size_t start_byte    = bit_offset / 8;
        int       bit_in_word   = (int)(bit_offset % 8);
        ca_size_t end_byte_excl = (bit_offset + bits + 7) / 8;
        ca_size_t span          = end_byte_excl - start_byte;
        int view_bytes;
        const char *vtype_name;
        if      (span <= 1) { view_bytes = 1; vtype_name = "uint8";  }
        else if (span <= 2) { view_bytes = 2; vtype_name = "uint16"; }
        else if (span <= 4) { view_bytes = 4; vtype_name = "uint32"; }
        else                { view_bytes = 8; vtype_name = "uint64"; }
        (void) view_bytes;
        vtype_sym = ID2SYM(rb_intern(vtype_name));
        word_view = rb_funcall(receiver, rb_intern("field"), 2,
                               SIZE2NUM(start_byte), vtype_sym);
        range = rb_range_new(LONG2NUM(bit_in_word),
                             SIZE2NUM(bit_in_word + bits - 1), 0);
        obj = rb_funcall(word_view, rb_intern("bitfield"), 1, range);
        rb_hash_aset(member, sym, obj);
        return obj;
      }
    }
    obj = rb_apply(receiver, rb_intern("field"), info);
    rb_hash_aset(member, sym, obj);
    return obj;
  }
}

/* @overload fields

(Reference) Returns an array of data class members (fields)
*/

VALUE
rb_ca_fields (VALUE self)
{
  volatile VALUE data_class = rb_ca_data_class(self);
  volatile VALUE member_names, list;
  int i;
  if ( NIL_P(data_class) ) {
    rb_raise(rb_eRuntimeError, "carray doesn't have data class");
  }
  member_names = rb_const_get(data_class, rb_intern("MEMBERS"));
  list = rb_ary_new2(RARRAY_LEN(member_names));
  for (i=0; i<RARRAY_LEN(member_names); i++) {
    VALUE name = rb_ary_entry(member_names, i);
    rb_ary_store(list, i, rb_ca_face_field(self, name));
  }
  return list;
}

/* @overload fields_at (*names)

Returns an array of data class members (fields) with names specified 
*/

VALUE
rb_ca_fields_at (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE data_class = rb_ca_data_class(self);
  volatile VALUE member_names, list;
  int i;
  if ( NIL_P(data_class) ) {
    rb_raise(rb_eRuntimeError, "carray doesn't have data class");
  }
  member_names = rb_ary_new4(argc, argv);
  list = rb_ary_new2(RARRAY_LEN(member_names));
  for (i=0; i<RARRAY_LEN(member_names); i++) {
    VALUE name = rb_ary_entry(member_names, i);
    rb_ary_store(list, i, rb_ca_face_field(self, name));
  }
  return list;
}


void
Init_carray_core (void)
{
  id_decode = rb_intern("decode");
  id_encode = rb_intern("encode");

  ca_init_obj_type();

  rb_define_singleton_method(rb_cCArray, "attach", rb_ca_s_attach, -1);
  rb_define_singleton_method(rb_cCArray, "attach!", rb_ca_s_attach_bang, -1);

  rb_define_method(rb_cCArray, "attach", rb_ca_attach, 0);
  rb_define_method(rb_cCArray, "attach!", rb_ca_attach_bang, 0);

  rb_define_method(rb_cCArray, "__attach__", rb_ca__attach__, 0);
  rb_define_method(rb_cCArray, "__sync__", rb_ca__sync__, 0);
  rb_define_method(rb_cCArray, "__detach__", rb_ca__detach__, 0);

  rb_define_method(rb_cCArray, "members", rb_ca_members, 0);

  rb_define_method(rb_cCArray, "fields", rb_ca_fields, 0);
  rb_define_method(rb_cCArray, "fields_at", rb_ca_fields_at, -1);

}


/* ------------------------------------------------------------------- */

/* The out-of-build form of the ca_is_entity macro (see carray.h).  Defined
   last so the macro stays in force for the rest of this file. */

#undef ca_is_entity

int
ca_is_entity (const void *ap)
{
  const CArray *ca = (const CArray *) ap;
  return ( ca_func[ca->obj_type].entity_type == CA_REAL_ARRAY );
}
