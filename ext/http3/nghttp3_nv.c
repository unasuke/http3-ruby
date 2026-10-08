#include "nghttp3.h"

VALUE rb_cNghttp3NV;

/*
 * Converts a Ruby NV object to a C nghttp3_nv structure.
 * Note: The returned structure contains pointers to Ruby string data,
 * so the Ruby strings must remain valid while the structure is in use.
 */
nghttp3_nv nghttp3_rb_nv_to_c(VALUE rb_nv) {
  nghttp3_nv nv;
  VALUE name = rb_iv_get(rb_nv, "@name");
  VALUE value = rb_iv_get(rb_nv, "@value");
  VALUE flags = rb_iv_get(rb_nv, "@flags");

  StringValue(name);
  StringValue(value);

  nv.name = (uint8_t *)RSTRING_PTR(name);
  nv.namelen = RSTRING_LEN(name);
  nv.value = (uint8_t *)RSTRING_PTR(value);
  nv.valuelen = RSTRING_LEN(value);
  nv.flags = NIL_P(flags) ? 0 : NUM2UINT(flags);

  return nv;
}

/*
 * call-seq:
 *   NV.new(name, value, flags: 0) -> NV
 *
 * Creates a new NV (name-value pair) object representing an HTTP header.
 */
static VALUE rb_nghttp3_nv_initialize(int argc, VALUE *argv, VALUE self) {
  VALUE name, value, opts;
  VALUE flags = INT2FIX(0);

  rb_scan_args(argc, argv, "2:", &name, &value, &opts);

  StringValue(name);
  StringValue(value);

  if (!NIL_P(opts)) {
    VALUE rb_flags = rb_hash_aref(opts, ID2SYM(rb_intern("flags")));
    if (!NIL_P(rb_flags)) {
      flags = rb_flags;
    }
  }

  rb_iv_set(self, "@name", rb_str_freeze(rb_str_dup(name)));
  rb_iv_set(self, "@value", rb_str_freeze(rb_str_dup(value)));
  rb_iv_set(self, "@flags", flags);

  return self;
}

static VALUE rb_nghttp3_nv_get_name(VALUE self) {
  return rb_iv_get(self, "@name");
}

static VALUE rb_nghttp3_nv_get_value(VALUE self) {
  return rb_iv_get(self, "@value");
}

static VALUE rb_nghttp3_nv_get_flags(VALUE self) {
  return rb_iv_get(self, "@flags");
}

void Init_nghttp3_nv(void) {
  /* Define NV flag constants */
  rb_define_const(rb_mNghttp3, "NV_FLAG_NONE", UINT2NUM(NGHTTP3_NV_FLAG_NONE));
  rb_define_const(rb_mNghttp3, "NV_FLAG_NEVER_INDEX",
                  UINT2NUM(NGHTTP3_NV_FLAG_NEVER_INDEX));
  rb_define_const(rb_mNghttp3, "NV_FLAG_NO_COPY_NAME",
                  UINT2NUM(NGHTTP3_NV_FLAG_NO_COPY_NAME));
  rb_define_const(rb_mNghttp3, "NV_FLAG_NO_COPY_VALUE",
                  UINT2NUM(NGHTTP3_NV_FLAG_NO_COPY_VALUE));
  rb_define_const(rb_mNghttp3, "NV_FLAG_TRY_INDEX",
                  UINT2NUM(NGHTTP3_NV_FLAG_TRY_INDEX));

  /* Define NV class */
  rb_cNghttp3NV = rb_define_class_under(rb_mNghttp3, "NV", rb_cObject);
  rb_define_method(rb_cNghttp3NV, "initialize", rb_nghttp3_nv_initialize, -1);
  rb_define_method(rb_cNghttp3NV, "name", rb_nghttp3_nv_get_name, 0);
  rb_define_method(rb_cNghttp3NV, "value", rb_nghttp3_nv_get_value, 0);
  rb_define_method(rb_cNghttp3NV, "flags", rb_nghttp3_nv_get_flags, 0);
}
