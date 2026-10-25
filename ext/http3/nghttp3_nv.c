#include "nghttp3.h"

VALUE rb_cNghttp3NV;

/* nghttp3 keeps the name and value of an NV it is told not to copy until
 * writev_stream has sent them, and nothing keeps a Ruby String alive, or in
 * place, that long: the NV may be dropped and its Strings freed, or moved by
 * GC.compact. So these two flags are dropped, and nghttp3 always copies.
 * They only spare a copy; the bytes sent stay the same, except that nghttp3
 * lowercases a name it copies. */
#define NV_FLAGS_NO_COPY                                                       \
  (NGHTTP3_NV_FLAG_NO_COPY_NAME | NGHTTP3_NV_FLAG_NO_COPY_VALUE)

static ID id_iv_name, id_iv_value, id_iv_flags;

/* The instance variables are read as they are, and to_str is not called:
 * Ruby code could change the Strings already taken, or start a GC that
 * moves them. rb_obj_is_kind_of and rb_ivar_get call no methods. */
long nghttp3_rb_nva_fill(VALUE headers, nghttp3_nv *nva, long nvlen) {
  for (long i = 0; i < nvlen; i++) {
    VALUE nv = RARRAY_AREF(headers, i);
    if (!RTEST(rb_obj_is_kind_of(nv, rb_cNghttp3NV))) {
      return i;
    }
    VALUE name = rb_ivar_get(nv, id_iv_name);
    VALUE value = rb_ivar_get(nv, id_iv_value);
    VALUE flags = rb_ivar_get(nv, id_iv_flags);
    if (!RB_TYPE_P(name, T_STRING) || !RB_TYPE_P(value, T_STRING) ||
        !FIXNUM_P(flags) || FIX2LONG(flags) < 0 || FIX2LONG(flags) > 255) {
      return i;
    }
    nva[i] = (nghttp3_nv){
        .name = (const uint8_t *)RSTRING_PTR(name),
        .namelen = (size_t)RSTRING_LEN(name),
        .value = (const uint8_t *)RSTRING_PTR(value),
        .valuelen = (size_t)RSTRING_LEN(value),
        .flags = (uint8_t)(FIX2LONG(flags) & ~NV_FLAGS_NO_COPY),
    };
  }
  return -1;
}

void nghttp3_rb_raise_bad_nv(long index) {
  rb_raise(rb_eArgError,
           "headers[%ld] is not an HTTP3::Nghttp3::NV with String name and "
           "value",
           index);
}

/*
 * call-seq:
 *   NV.new(name, value, flags: 0) -> NV
 *
 * Creates a new NV (name-value pair) object representing an HTTP header.
 * flags is an Integer of 0..255, the NV_FLAG_* constants or-ed together;
 * NV_FLAG_NO_COPY_NAME and NV_FLAG_NO_COPY_VALUE are ignored.
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
  /* nghttp3_nv.flags is a uint8_t. */
  if (!FIXNUM_P(flags) || FIX2LONG(flags) < 0 || FIX2LONG(flags) > 255) {
    rb_raise(rb_eArgError,
             "flags must be an Integer of 0..255 (got %+" PRIsVALUE ")", flags);
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
  id_iv_name = rb_intern("@name");
  id_iv_value = rb_intern("@value");
  id_iv_flags = rb_intern("@flags");

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
