#include "nghttp3.h"

VALUE rb_cNghttp3Settings;

typedef struct {
  nghttp3_settings settings;
} SettingsObj;

static void settings_free(void *ptr) { xfree(ptr); }

static size_t settings_memsize(const void *ptr) { return sizeof(SettingsObj); }

const rb_data_type_t settings_data_type = {
    .wrap_struct_name = "nghttp3_settings_rb",
    .function =
        {
            .dmark = NULL,
            .dfree = settings_free,
            .dsize = settings_memsize,
        },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE settings_alloc(VALUE klass) {
  SettingsObj *obj;
  VALUE self =
      TypedData_Make_Struct(klass, SettingsObj, &settings_data_type, obj);
  memset(&obj->settings, 0, sizeof(nghttp3_settings));
  return self;
}

/*
 * Returns a pointer to the underlying nghttp3_settings structure.
 */
nghttp3_settings *nghttp3_rb_get_settings(VALUE rb_settings) {
  SettingsObj *obj;
  TypedData_Get_Struct(rb_settings, SettingsObj, &settings_data_type, obj);
  return &obj->settings;
}

/*
 * call-seq:
 *   Settings.new -> Settings
 *
 * Creates a new Settings object with all values set to zero.
 */
static VALUE rb_nghttp3_settings_initialize(VALUE self) { return self; }

/*
 * call-seq:
 *   Settings.default -> Settings
 *
 * Creates a new Settings object with default values from nghttp3.
 */
static VALUE rb_nghttp3_settings_default(VALUE klass) {
  VALUE self = settings_alloc(klass);
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  nghttp3_settings_default(&obj->settings);
  return self;
}

/* Settings getters */
static VALUE rb_nghttp3_settings_get_max_field_section_size(VALUE self) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  return ULL2NUM(obj->settings.max_field_section_size);
}

static VALUE rb_nghttp3_settings_get_qpack_max_dtable_capacity(VALUE self) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  return SIZET2NUM(obj->settings.qpack_max_dtable_capacity);
}

static VALUE
rb_nghttp3_settings_get_qpack_encoder_max_dtable_capacity(VALUE self) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  return SIZET2NUM(obj->settings.qpack_encoder_max_dtable_capacity);
}

static VALUE rb_nghttp3_settings_get_qpack_blocked_streams(VALUE self) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  return SIZET2NUM(obj->settings.qpack_blocked_streams);
}

static VALUE rb_nghttp3_settings_get_enable_connect_protocol(VALUE self) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  return obj->settings.enable_connect_protocol ? Qtrue : Qfalse;
}

static VALUE rb_nghttp3_settings_get_h3_datagram(VALUE self) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  return obj->settings.h3_datagram ? Qtrue : Qfalse;
}

/* Settings setters */
static VALUE rb_nghttp3_settings_set_max_field_section_size(VALUE self,
                                                            VALUE val) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  obj->settings.max_field_section_size = NUM2ULL(val);
  return val;
}

static VALUE rb_nghttp3_settings_set_qpack_max_dtable_capacity(VALUE self,
                                                               VALUE val) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  obj->settings.qpack_max_dtable_capacity = NUM2SIZET(val);
  return val;
}

static VALUE
rb_nghttp3_settings_set_qpack_encoder_max_dtable_capacity(VALUE self,
                                                          VALUE val) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  obj->settings.qpack_encoder_max_dtable_capacity = NUM2SIZET(val);
  return val;
}

static VALUE rb_nghttp3_settings_set_qpack_blocked_streams(VALUE self,
                                                           VALUE val) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  obj->settings.qpack_blocked_streams = NUM2SIZET(val);
  return val;
}

static VALUE rb_nghttp3_settings_set_enable_connect_protocol(VALUE self,
                                                             VALUE val) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  obj->settings.enable_connect_protocol = RTEST(val) ? 1 : 0;
  return val;
}

static VALUE rb_nghttp3_settings_set_h3_datagram(VALUE self, VALUE val) {
  SettingsObj *obj;
  TypedData_Get_Struct(self, SettingsObj, &settings_data_type, obj);
  obj->settings.h3_datagram = RTEST(val) ? 1 : 0;
  return val;
}

void Init_nghttp3_settings(void) {
  rb_cNghttp3Settings =
      rb_define_class_under(rb_mNghttp3, "Settings", rb_cObject);
  rb_define_alloc_func(rb_cNghttp3Settings, settings_alloc);
  rb_define_method(rb_cNghttp3Settings, "initialize",
                   rb_nghttp3_settings_initialize, 0);
  rb_define_singleton_method(rb_cNghttp3Settings, "default",
                             rb_nghttp3_settings_default, 0);

  /* Settings getters */
  rb_define_method(rb_cNghttp3Settings, "max_field_section_size",
                   rb_nghttp3_settings_get_max_field_section_size, 0);
  rb_define_method(rb_cNghttp3Settings, "qpack_max_dtable_capacity",
                   rb_nghttp3_settings_get_qpack_max_dtable_capacity, 0);
  rb_define_method(rb_cNghttp3Settings, "qpack_encoder_max_dtable_capacity",
                   rb_nghttp3_settings_get_qpack_encoder_max_dtable_capacity,
                   0);
  rb_define_method(rb_cNghttp3Settings, "qpack_blocked_streams",
                   rb_nghttp3_settings_get_qpack_blocked_streams, 0);
  rb_define_method(rb_cNghttp3Settings, "enable_connect_protocol",
                   rb_nghttp3_settings_get_enable_connect_protocol, 0);
  rb_define_method(rb_cNghttp3Settings, "h3_datagram",
                   rb_nghttp3_settings_get_h3_datagram, 0);

  /* Settings setters */
  rb_define_method(rb_cNghttp3Settings, "max_field_section_size=",
                   rb_nghttp3_settings_set_max_field_section_size, 1);
  rb_define_method(rb_cNghttp3Settings, "qpack_max_dtable_capacity=",
                   rb_nghttp3_settings_set_qpack_max_dtable_capacity, 1);
  rb_define_method(rb_cNghttp3Settings, "qpack_encoder_max_dtable_capacity=",
                   rb_nghttp3_settings_set_qpack_encoder_max_dtable_capacity,
                   1);
  rb_define_method(rb_cNghttp3Settings, "qpack_blocked_streams=",
                   rb_nghttp3_settings_set_qpack_blocked_streams, 1);
  rb_define_method(rb_cNghttp3Settings, "enable_connect_protocol=",
                   rb_nghttp3_settings_set_enable_connect_protocol, 1);
  rb_define_method(rb_cNghttp3Settings,
                   "h3_datagram=", rb_nghttp3_settings_set_h3_datagram, 1);
}
