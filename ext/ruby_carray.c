/* ---------------------------------------------------------------------------

  Single entry point Init_carray_ext: declares the CArray class
  hierarchy + exception class + CA module, populates top-level
  constants (CA_RANK_MAX / CA_* data_type Symbols / alignment
  values), then drives the per-module Init_* sequence in load order.

  CAREFUL: the Init_* call order below carries real ordering
  invariants in several places (e.g. CAStride before its subclasses,
  ca_op_ipower before mask_fast_paths, ca_face before its concrete
  Faces, lazy before monop).  Each load-bearing edge is annotated at
  the callsite; do not reorder without reading those notes.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "version.h"

#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
VALUE rb_cArithSeq;
#endif

/* Form-only base of the 3.0 iterator family (defined in Init_carray_ext). */
VALUE rb_cCAIterator;
  
VALUE rb_eCADataTypeError;
VALUE rb_mCA;

VALUE CA_UNSPECIFIED;

void Init_carray_core ();
void Init_carray_undef ();
void Init_carray_class ();
void Init_carray_data_type ();
void Init_carray_test ();
void Init_carray_attribute ();
void Init_carray_loop ();
void Init_carray_mask ();
void Init_carray_hold ();
void Init_carray_mask_fast_paths ();  /* patches generated bit-op tables;
                                         must run AFTER Init_ca_op_ipower */
void Init_carray_access ();
void Init_carray_index_classifier ();
void Init_carray_element ();
void Init_carray_scatter ();     /* scatter_*! family */
void Init_ca_axis_group ();      /* devel/MEMO_AXIS_GROUP.md — axis-group reduction kernel */
void Init_ca_group_iter ();      /* devel/MEMO_AXIS_GROUP.md — axis-group [] surface */
void Init_carray_bincount ();    /* bincount dedicated kernel */
void Init_carray_factorize ();   /* single-pass integer factorization for categorize */
void Init_carray_histogram ();   /* histogram + histbin_ki */
void Init_ca_categorical_iterator (); /* CACategoricalIterator counting-sort scatter */
void Init_carray_operator ();
void Init_ca_op_ipower ();
void Init_carray_utils ();
void Init_carray_order ();
void Init_carray_partition ();          /* partition / partition_copy */
void Init_carray_median_percentile ();  /* median / percentile / quantile */
void Init_carray_sort ();         /* sort / sort_copy / sort_addr / axis2addr */
void Init_carray_count ();
void Init_carray_kernels ();      /* mkkernel-generated: reductions + maps */
void Init_carray_utils ();
void Init_carray_generate ();
void Init_carray_copy ();
void Init_carray_conversion ();
void Init_carray_cast ();
void Init_carray_broadcast ();

void Init_ca_obj_array ();
void Init_ca_obj_refer ();
void Init_ca_obj_farray ();
void Init_ca_obj_block ();
void Init_ca_obj_select ();
void Init_ca_obj_select_axis ();
void Init_ca_obj_object ();
void Init_ca_obj_grid ();
void Init_ca_obj_window ();
void Init_ca_obj_shift ();
void Init_ca_obj_tile ();
void Init_ca_obj_roll ();
void Init_ca_obj_stack ();   /* multi-parent outer-axis stack */
void Init_ca_obj_meld ();    /* multi-parent ragged concat along existing axis */
void Init_ca_obj_transpose ();
void Init_ca_obj_repeat ();
void Init_ca_obj_reduce ();
void Init_ca_obj_field ();
void Init_ca_obj_fake ();
void Init_ca_obj_byte_swap ();
void Init_ca_face ();            /* CAFace abstract base; must precede CATime / CATimedelta / CARecord / CAConstString */
void Init_ca_source ();          /* CASource abstract base; concrete sources live in C extensions */
void Init_ca_obj_time ();  /* first numeric Face */
void Init_ca_obj_timedelta ();   /* CATime sibling */
void Init_ca_obj_record ();      /* composite Face for CAStruct backing */
void Init_ca_obj_const_string ();/* read-only variable-length string Face */
void Init_ca_obj_string ();      /* mutable string Face over CA_OBJECT storage */
void Init_ca_obj_fixlen_string ();/* string Face over CA_FIXLEN storage */
void Init_ca_obj_bitarray ();
void Init_ca_obj_bitfield ();
void Init_ca_obj_stride ();
void Init_ca_obj_remap ();   /* internal-only (no Ruby surface) */
void Init_carray_lazy ();    /* CALazyMarker; must precede Init_ca_obj_monop / _binop / _moncmp / _bincmp */
void Init_ca_obj_monop ();   /* CAMonOp + lazy elementwise monadic dispatch */
void Init_ca_obj_binop ();   /* CABinOp + lazy elementwise binary dispatch */
void Init_ca_obj_triop ();   /* CATriOp + lazy elementwise triadic dispatch */
void Init_ca_obj_bincmp ();  /* CABinCmp + lazy elementwise comparison dispatch */
void Init_ca_obj_moncmp ();  /* CAMonCmp + lazy elementwise predicate dispatch */

/* Init_carray_iterator retired; CAIterator is a form-only base defined inline
   in Init_carray_ext (accessors in lib/carray/iterator.rb).  The 2.0 C engines
   (dimension / window / block iterators) were retired in 3.0. */

void Init_carray_mathfunc ();

void Init_carray_memory_view ();

void Init_carray_struct ();

void Init_carray_random ();

void Init_ca_kernel_iterator ();

void Init_carray_slab ();

void
Init_carray_ext (void)
{

#ifdef HAVE_RB_EXT_RACTOR_SAFE
    rb_ext_ractor_safe(true);
#endif
		
  /* Classes and Modules */

#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
  rb_cArithSeq   = rb_const_get(rb_cEnumerator, rb_intern("ArithmeticSequence"));
#endif

  /* -- CArray class -- */

  rb_cCArray     = rb_define_class("CArray",    rb_cObject);
  rb_cCAWrap     = rb_define_class("CAWrap",    rb_cCArray);
  rb_cCScalar    = rb_define_class("CScalar",   rb_cCArray);
  rb_cCAView  = rb_define_class("CAView", rb_cCArray);
  /* CAREFUL: CAStride must exist before its subclasses (CARefer /
     CABlock / CAField / CARepeat / CATranspose /
     CAFarray) are defined or registered.  See devel/CAStride.md. */
  rb_cCAStride   = rb_define_class("CAStride",  rb_cCAView);
  rb_cCARefer    = rb_define_class("CARefer",   rb_cCAStride);
  rb_cCABlock    = rb_define_class("CABlock",   rb_cCAStride);
  rb_cCAField    = rb_define_class("CAField",   rb_cCAStride);
  rb_cCASelect   = rb_define_class("CASelect",  rb_cCAView);
  rb_cCAObject   = rb_define_class("CAObject",  rb_cCAView);
  rb_cCARepeat   = rb_define_class("CARepeat",  rb_cCAStride);
  rb_cCArrayMask     = rb_define_class("CArrayMask",    rb_cCArray);
  rb_cCAStrideMask   = rb_define_class("CAStrideMask",  rb_cCAStride);
  rb_cCAReferMask    = rb_define_class("CAReferMask",   rb_cCARefer);
  rb_cCABlockMask    = rb_define_class("CABlockMask",   rb_cCABlock);
  rb_cCAFieldMask    = rb_define_class("CAFieldMask",   rb_cCAField);
  rb_cCASelectMask   = rb_define_class("CASelectMask",  rb_cCASelect);
  rb_cCARepeatMask   = rb_define_class("CARepeatMask",  rb_cCARepeat);

  /* -- Exception class -- */

  rb_eCADataTypeError =
    rb_define_class_under(rb_cCArray, "DataTypeError", rb_eStandardError);

  /* -- CA module -- namespace for misc utilities related to CArray */

  rb_mCA = rb_define_module("CA");

  /* -- version -- */

  rb_define_const(rb_cCArray, "VERSION",       rb_str_new2(CA_VERSION));
  rb_define_const(rb_cCArray, "VERSION_CODE",  INT2NUM(CA_VERSION_CODE));
  rb_define_const(rb_cCArray, "VERSION_MAJOR", INT2NUM(CA_VERSION_MAJOR));
  rb_define_const(rb_cCArray, "VERSION_MINOR", INT2NUM(CA_VERSION_MINOR));
  rb_define_const(rb_cCArray, "VERSION_TEENY", INT2NUM(CA_VERSION_TEENY));
  rb_define_const(rb_cCArray, "VERSION_DATE",  rb_str_new2(CA_VERSION_DATE));

  /* -- system -- */
  rb_define_const(rb_cObject, "CA_RANK_MAX", INT2NUM(CA_RANK_MAX));
  /* Sentinel meaning "the caller did not give this argument".  It is
     distinct from nil because nil is itself a legal fill value (a
     CA_OBJECT array can be filled with nil), so nil cannot mark
     absence.  C code only ever compares against it; the value is never
     read and must never be passed in from Ruby.  The constant exists to
     anchor the object against the GC. */
  CA_UNSPECIFIED = rb_funcall(rb_cObject, rb_intern("new"), 0);
  rb_define_const(rb_cCArray, "UNSPECIFIED", CA_UNSPECIFIED);

#ifdef HAVE_COMPLEX_H
  /* @private */
  rb_define_const(rb_cCArray, "HAVE_COMPLEX", Qtrue);
#else
  /* @private */
  rb_define_const(rb_cCArray, "HAVE_COMPLEX", Qfalse);
#endif

  /* -- data types -- */

  /* CAREFUL: precompute the Symbol ID cache for the ca.data_type
     accessor BEFORE the CA_* data_type constants below are defined —
     they read from ca_data_type_sym[]. */
  {
    int i;
    for ( i = 0; i < CA_NTYPE; i++ ) {
      if ( ca_type_name[i] != NULL ) {
        ca_data_type_sym[i] = rb_intern(ca_type_name[i]);
      }
      else {
        ca_data_type_sym[i] = rb_intern("");
      }
    }
  }

  /* The Ruby-surface CA_* data_type constants are Symbols (the C
     internal `#define CA_INT64 8` etc. is unchanged); both sides flip
     to Symbol together so `case when CA_INT64` over `ca.data_type`
     stays transparent.  Alias constants (CA_DOUBLE etc.) share the
     canonical Symbol via Symbol identity, so `CA_DOUBLE ==
     CA_FLOAT64` evaluates true. */

  rb_define_const(rb_cObject, "CA_FIXLEN",      ID2SYM(ca_data_type_sym[CA_FIXLEN]));
  rb_define_const(rb_cObject, "CA_BOOLEAN",     ID2SYM(ca_data_type_sym[CA_BOOLEAN]));
  rb_define_const(rb_cObject, "CA_INT8",        ID2SYM(ca_data_type_sym[CA_INT8]));
  rb_define_const(rb_cObject, "CA_UINT8",       ID2SYM(ca_data_type_sym[CA_UINT8]));
  rb_define_const(rb_cObject, "CA_INT16",       ID2SYM(ca_data_type_sym[CA_INT16]));
  rb_define_const(rb_cObject, "CA_UINT16",      ID2SYM(ca_data_type_sym[CA_UINT16]));
  rb_define_const(rb_cObject, "CA_INT32",       ID2SYM(ca_data_type_sym[CA_INT32]));
  rb_define_const(rb_cObject, "CA_UINT32",      ID2SYM(ca_data_type_sym[CA_UINT32]));
  rb_define_const(rb_cObject, "CA_INT64",       ID2SYM(ca_data_type_sym[CA_INT64]));
  rb_define_const(rb_cObject, "CA_UINT64",      ID2SYM(ca_data_type_sym[CA_UINT64]));
  rb_define_const(rb_cObject, "CA_FLOAT32",     ID2SYM(ca_data_type_sym[CA_FLOAT32]));
  rb_define_const(rb_cObject, "CA_FLOAT64",     ID2SYM(ca_data_type_sym[CA_FLOAT64]));
  rb_define_const(rb_cObject, "CA_CMPLX64",     ID2SYM(ca_data_type_sym[CA_CMPLX64]));
  rb_define_const(rb_cObject, "CA_CMPLX128",    ID2SYM(ca_data_type_sym[CA_CMPLX128]));
  rb_define_const(rb_cObject, "CA_OBJECT",      ID2SYM(ca_data_type_sym[CA_OBJECT]));

  /* Aliases share the canonical Symbol: CA_BYTE == CA_UINT8, etc. */
  rb_define_const(rb_cObject, "CA_BYTE",        ID2SYM(ca_data_type_sym[CA_BYTE]));
  rb_define_const(rb_cObject, "CA_SHORT",       ID2SYM(ca_data_type_sym[CA_INT16]));
  rb_define_const(rb_cObject, "CA_INT",         ID2SYM(ca_data_type_sym[CA_INT32]));
  rb_define_const(rb_cObject, "CA_FLOAT",       ID2SYM(ca_data_type_sym[CA_FLOAT]));
  rb_define_const(rb_cObject, "CA_DOUBLE",      ID2SYM(ca_data_type_sym[CA_DOUBLE]));
  rb_define_const(rb_cObject, "CA_COMPLEX",     ID2SYM(ca_data_type_sym[CA_COMPLEX]));
  rb_define_const(rb_cObject, "CA_DCOMPLEX",    ID2SYM(ca_data_type_sym[CA_DCOMPLEX]));
  rb_define_const(rb_cObject, "CA_SIZE",        ID2SYM(ca_data_type_sym[CA_SIZE]));

  rb_define_const(rb_cObject, "CA_ALIGN_VOIDP",    INT2NUM(CA_ALIGN_VOIDP));
  rb_define_const(rb_cObject, "CA_ALIGN_FIXLEN",   INT2NUM(CA_ALIGN_INT8));
  rb_define_const(rb_cObject, "CA_ALIGN_BOOLEAN",  INT2NUM(CA_ALIGN_INT8));
  rb_define_const(rb_cObject, "CA_ALIGN_INT8",     INT2NUM(CA_ALIGN_INT8));
  rb_define_const(rb_cObject, "CA_ALIGN_INT16",    INT2NUM(CA_ALIGN_INT16));
  rb_define_const(rb_cObject, "CA_ALIGN_INT32",    INT2NUM(CA_ALIGN_INT32));
  rb_define_const(rb_cObject, "CA_ALIGN_INT64",    INT2NUM(CA_ALIGN_INT64));
  rb_define_const(rb_cObject, "CA_ALIGN_FLOAT32",  INT2NUM(CA_ALIGN_FLOAT32));
  rb_define_const(rb_cObject, "CA_ALIGN_FLOAT64",  INT2NUM(CA_ALIGN_FLOAT64));
  rb_define_const(rb_cObject, "CA_ALIGN_CMPLX64",  INT2NUM(CA_ALIGN_CMPLX64));
  rb_define_const(rb_cObject, "CA_ALIGN_CMPLX128", INT2NUM(CA_ALIGN_CMPLX128));
  rb_define_const(rb_cObject, "CA_ALIGN_OBJECT",   INT2NUM(CA_ALIGN_OBJECT));

  /* load modules in external files */

  Init_carray_core(); /* Init_carray_core should be called first*/

  Init_carray_class();
  Init_carray_data_type();
  Init_carray_test();
  Init_carray_attribute();
  Init_carray_undef();
  Init_carray_mask();
  Init_carray_hold();
  Init_carray_loop();
  Init_carray_access();
  Init_carray_index_classifier();
  Init_carray_element();
  Init_carray_scatter();
  Init_ca_axis_group();    /* devel/MEMO_AXIS_GROUP.md — axis-group reduction kernel */
  Init_carray_bincount();
  Init_carray_factorize();
  Init_carray_histogram();
  Init_ca_categorical_iterator();
  Init_carray_operator();
  Init_ca_op_ipower();              /* CArray#pow / pow! + ipower fast path.
                                       CAREFUL: must precede the numeric init
                                       block that follows. */
  Init_carray_mask_fast_paths();    /* patches bit-op tables for boolean8_t;
                                       must run AFTER Init_ca_op_ipower
                                       (which sets up the tables). */
  Init_carray_order();
  Init_carray_partition();          /* partition / partition_copy */
  Init_carray_median_percentile();  /* needs partition_copy_c from carray_partition */
  Init_carray_sort();               /* sort / sort_copy / sort_addr / axis2addr */
  Init_carray_count();
  Init_carray_kernels();            /* mkkernel-generated: reductions + maps */

  Init_carray_utils();

  Init_carray_generate();
  Init_carray_copy();
  Init_carray_conversion();
  Init_carray_cast();
  Init_carray_broadcast();

  Init_ca_obj_array();
  Init_ca_obj_refer();
  Init_ca_obj_stride();       /* CAREFUL: must precede CAStride subclasses
                                 (farray / block / transpose / repeat /
                                 unbound_repeat / field). */
  Init_ca_obj_farray();
  Init_ca_obj_block();
  Init_ca_obj_select();
  Init_ca_obj_select_axis();
  Init_ca_obj_object();
  Init_ca_obj_grid();
  Init_ca_obj_window();
  Init_ca_obj_shift();
  Init_ca_obj_tile();
  Init_ca_obj_roll();         /* depends on tile */
  Init_ca_obj_stack();
  Init_ca_obj_meld();
  Init_ca_obj_transpose();
  Init_ca_obj_repeat();
  Init_ca_obj_reduce();
  Init_ca_obj_field();
  Init_ca_obj_fake();
  Init_ca_obj_byte_swap();
  Init_ca_source();           /* CASource: abstract, no obj_type of its own.
                                 Concrete sources are registered by C
                                 extensions via ca_install_obj_type. */
  Init_ca_face();             /* CAREFUL: must precede every concrete Face
                                 (datetime / timedelta / record /
                                 const_string). */
  Init_ca_obj_time();
  Init_ca_obj_timedelta();
  Init_ca_obj_record();
  Init_ca_obj_const_string();
  Init_ca_obj_string();
  Init_ca_obj_fixlen_string();
  Init_ca_obj_bitarray();
  Init_ca_obj_bitfield();
  Init_ca_obj_remap();        /* internal-only (no Ruby surface) */
  Init_carray_lazy();         /* CALazyMarker; CAREFUL: must precede the
                                 four lazy elementwise inits below. */
  Init_ca_obj_monop();
  Init_ca_obj_binop();
  Init_ca_obj_triop();
  Init_ca_obj_bincmp();
  Init_ca_obj_moncmp();

  /* CAIterator is the form-only base of the 3.0 iterator family; its shared
     accessors are plain Ruby attr_readers (lib/carray/iterator.rb).  The C
     reduction iterators subclass it and carray_access.c constructs
     CASlabIterator by name, so the class object must exist here. */
  rb_cCAIterator = rb_define_class("CAIterator", rb_cObject);

  Init_ca_group_iter();    /* devel/MEMO_AXIS_GROUP.md — axis-group [] surface
                              (CAGroupIterator); after CAIterator is defined
                              (CAGroupIterator subclasses it). */

  Init_carray_mathfunc();

  Init_carray_memory_view();

  Init_carray_struct();

  Init_carray_random();

  Init_ca_kernel_iterator();

  Init_carray_slab();
}

