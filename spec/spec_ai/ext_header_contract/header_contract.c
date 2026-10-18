/* header_contract: calls the public C surface of carray.h as a companion
   gem does (built without CARRAY_BUILD), so that what the header promises
   can be checked from Ruby. */

#include "ruby.h"
#include "carray.h"
#include <stddef.h>

static CArray *
get (VALUE v)
{
  CArray *ca;
  GetCArray(v, ca);
  return ca;
}

static VALUE
hc_overlay_safe (VALUE self, VALUE out, VALUE src)
{
  ca_mask_overlay_safe(get(out), 1, get(src));
  return out;
}

static VALUE
hc_setup_mask (VALUE self, VALUE a, VALUE mask)
{
  ca_setup_mask(get(a), NIL_P(mask) ? NULL : get(mask));
  return a;
}

static VALUE
hc_create_mask (VALUE self, VALUE a)
{
  ca_create_mask(get(a));
  return a;
}

static VALUE
hc_unmask_copy (VALUE self, VALUE a)
{
  return ca_wrap_struct(ca_unmask_copy(get(a), NULL));
}

static VALUE
hc_attach (VALUE self, VALUE a)
{
  ca_attach(get(a));
  return a;
}

static VALUE
hc_detach (VALUE self, VALUE a)
{
  ca_detach(get(a));
  return a;
}

/* The attach level of a view (nil for an entity). */
static VALUE
hc_attach_level (VALUE self, VALUE a)
{
  CArray *ca = get(a);
  return ca_is_view(ca) ? UINT2NUM(CAVIEW(ca)->attach) : Qnil;
}

static VALUE
hc_obj_num (VALUE self)
{
  return INT2NUM(ca_obj_num);
}

static VALUE hc_klass;

/* Installs a copy of the entity's operation table, passing func_size. */
static VALUE
hc_install (VALUE self, VALUE vsize)
{
  ca_operation_function_t f = ca_func[CA_OBJ_ARRAY];
  int t = ca_install_obj_type(hc_klass, ca_typeddata[CA_OBJ_ARRAY],
                              ca_mask_class[CA_OBJ_ARRAY],
                              ca_mask_typeddata[CA_OBJ_ARRAY],
                              &f, NUM2SIZET(vsize));
  return INT2NUM(t);
}

/* CA_CHECK_DATA_TYPE with an expression argument. */
static VALUE
hc_check_data_type (VALUE self, VALUE flag, VALUE dt)
{
  int d = FIXNUM_P(dt) ? NUM2INT(dt) : rb_ca_guess_type(dt);
  CA_CHECK_DATA_TYPE(RTEST(flag) ? d : CA_INT32);
  CA_CHECK_DATA_TYPE_NUMERIC(RTEST(flag) ? d : CA_INT32);
  return Qtrue;
}

static VALUE
hc_check_same_data_type (VALUE self, VALUE a, VALUE b)
{
  ca_check_same_data_type(get(a), get(b));
  return Qtrue;
}

static VALUE
hc_promote_type (VALUE self, VALUE a, VALUE b)
{
  return INT2NUM(ca_promote_type((int8_t) NUM2INT(a), (int8_t) NUM2INT(b)));
}

static VALUE
hc_unmask_without_fill (VALUE self, VALUE a)
{
  ca_unmask(get(a), NULL);
  return a;
}

void
Init_header_contract (void)
{
  VALUE m = rb_define_module("HeaderContract");
  hc_klass = rb_define_class_under(m, "Installed", rb_cCArray);
  rb_define_module_function(m, "overlay_safe", hc_overlay_safe, 2);
  rb_define_module_function(m, "setup_mask", hc_setup_mask, 2);
  rb_define_module_function(m, "create_mask", hc_create_mask, 1);
  rb_define_module_function(m, "unmask_copy", hc_unmask_copy, 1);
  rb_define_module_function(m, "attach", hc_attach, 1);
  rb_define_module_function(m, "detach", hc_detach, 1);
  rb_define_module_function(m, "attach_level", hc_attach_level, 1);
  rb_define_module_function(m, "obj_num", hc_obj_num, 0);
  rb_define_module_function(m, "install", hc_install, 1);
  rb_define_module_function(m, "check_data_type", hc_check_data_type, 2);
  rb_define_module_function(m, "check_same_data_type", hc_check_same_data_type, 2);
  rb_define_module_function(m, "promote_type", hc_promote_type, 2);
  rb_define_module_function(m, "unmask_without_fill", hc_unmask_without_fill, 1);
  rb_define_const(m, "FUNC_SIZE", SIZET2NUM(sizeof(ca_operation_function_t)));
  rb_define_const(m, "XFER_INDEX_OFFSET",
                  SIZET2NUM(offsetof(ca_operation_function_t, xfer_index)));
  rb_define_const(m, "XFER_ALL_END",
                  SIZET2NUM(offsetof(ca_operation_function_t, xfer_all) +
                            sizeof(((ca_operation_function_t *) 0)->xfer_all)));
}
