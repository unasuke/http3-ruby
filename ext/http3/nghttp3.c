#include "nghttp3.h"
#include <stdarg.h>

const quic_ext_api *http3_quic_api;

VALUE rb_mNghttp3;
VALUE rb_cNghttp3Info;
VALUE rb_eNghttp3Error;

/* Error classes */
VALUE rb_eNghttp3InvalidArgumentError;
VALUE rb_eNghttp3InvalidStateError;
VALUE rb_eNghttp3WouldBlockError;
VALUE rb_eNghttp3StreamInUseError;
VALUE rb_eNghttp3MalformedHTTPHeaderError;
VALUE rb_eNghttp3MalformedHTTPMessagingError;
VALUE rb_eNghttp3QPACKFatalError;
VALUE rb_eNghttp3QPACKHeaderTooLargeError;
VALUE rb_eNghttp3StreamNotFoundError;
VALUE rb_eNghttp3ConnClosingError;
VALUE rb_eNghttp3StreamDataOverflowError;
VALUE rb_eNghttp3FatalError;
VALUE rb_eNghttp3NoMemError;
VALUE rb_eNghttp3CallbackFailureError;

/*
 * call-seq:
 *   Nghttp3.library_version -> Nghttp3::Info
 *   Nghttp3.library_version(least_version) -> Nghttp3::Info or nil
 *
 * Returns version information about the nghttp3 library.
 * If least_version is specified and the library version is less than
 * that value, returns nil.
 */
static VALUE rb_nghttp3_library_version(int argc, VALUE *argv, VALUE self) {
  VALUE rb_least_version;
  int least_version = 0;
  const nghttp3_info *info;
  VALUE info_obj;

  rb_scan_args(argc, argv, "01", &rb_least_version);

  if (!NIL_P(rb_least_version)) {
    least_version = NUM2INT(rb_least_version);
  }

  info = nghttp3_version(least_version);

  if (info == NULL) {
    return Qnil;
  }

  info_obj = rb_obj_alloc(rb_cNghttp3Info);
  rb_iv_set(info_obj, "@age", INT2NUM(info->age));
  rb_iv_set(info_obj, "@version_num", INT2NUM(info->version_num));
  rb_iv_set(info_obj, "@version_str", rb_str_new_cstr(info->version_str));

  return info_obj;
}

/*
 * Returns the age of the nghttp3 library.
 */
static VALUE rb_nghttp3_info_age(VALUE self) { return rb_iv_get(self, "@age"); }

/*
 * Returns the numerical version of the nghttp3 library.
 */
static VALUE rb_nghttp3_info_version_num(VALUE self) {
  return rb_iv_get(self, "@version_num");
}

/*
 * Returns the version string of the nghttp3 library.
 */
static VALUE rb_nghttp3_info_version_str(VALUE self) {
  return rb_iv_get(self, "@version_str");
}

/*
 * Returns the appropriate Ruby error class for the given nghttp3 error code.
 */
VALUE nghttp3_rb_error_class_for_code(int error_code) {
  switch (error_code) {
  case NGHTTP3_ERR_INVALID_ARGUMENT:
    return rb_eNghttp3InvalidArgumentError;
  case NGHTTP3_ERR_INVALID_STATE:
    return rb_eNghttp3InvalidStateError;
  case NGHTTP3_ERR_WOULDBLOCK:
    return rb_eNghttp3WouldBlockError;
  case NGHTTP3_ERR_STREAM_IN_USE:
    return rb_eNghttp3StreamInUseError;
  case NGHTTP3_ERR_MALFORMED_HTTP_HEADER:
    return rb_eNghttp3MalformedHTTPHeaderError;
  case NGHTTP3_ERR_MALFORMED_HTTP_MESSAGING:
    return rb_eNghttp3MalformedHTTPMessagingError;
  case NGHTTP3_ERR_QPACK_FATAL:
    return rb_eNghttp3QPACKFatalError;
  case NGHTTP3_ERR_QPACK_HEADER_TOO_LARGE:
    return rb_eNghttp3QPACKHeaderTooLargeError;
  case NGHTTP3_ERR_STREAM_NOT_FOUND:
    return rb_eNghttp3StreamNotFoundError;
  case NGHTTP3_ERR_CONN_CLOSING:
    return rb_eNghttp3ConnClosingError;
  case NGHTTP3_ERR_STREAM_DATA_OVERFLOW:
    return rb_eNghttp3StreamDataOverflowError;
  case NGHTTP3_ERR_NOMEM:
    return rb_eNghttp3NoMemError;
  case NGHTTP3_ERR_CALLBACK_FAILURE:
    return rb_eNghttp3CallbackFailureError;
  default:
    if (nghttp3_err_is_fatal(error_code)) {
      return rb_eNghttp3FatalError;
    }
    return rb_eNghttp3Error;
  }
}

/*
 * Raises an appropriate Ruby exception for the given nghttp3 error code.
 */
void nghttp3_rb_raise(int error_code, const char *fmt, ...) {
  VALUE error_class;
  char buf[256];
  va_list args;

  error_class = nghttp3_rb_error_class_for_code(error_code);

  if (fmt != NULL) {
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    rb_raise(error_class, "%s: %s", buf, nghttp3_strerror(error_code));
  } else {
    rb_raise(error_class, "%s", nghttp3_strerror(error_code));
  }
}

/*
 * call-seq:
 *   Nghttp3.err_is_fatal?(error_code) -> true or false
 *
 * Returns true if the given error code represents a fatal error.
 */
static VALUE rb_nghttp3_err_is_fatal(VALUE self, VALUE rb_error_code) {
  int error_code = NUM2INT(rb_error_code);
  return nghttp3_err_is_fatal(error_code) ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *   Nghttp3.strerror(error_code) -> String
 *
 * Returns a textual representation of the given error code.
 */
static VALUE rb_nghttp3_strerror(VALUE self, VALUE rb_error_code) {
  int error_code = NUM2INT(rb_error_code);
  const char *str = nghttp3_strerror(error_code);
  return rb_str_new_cstr(str);
}

/*
 * The quic gem's C function table for ABI major version major. quic must be
 * loaded. Raises LoadError naming the versions when the quic gem has no
 * such table (too old, or an incompatible major version) or a smaller one
 * than this extension was built against.
 */
static const quic_ext_api *http3_load_quic_api(uint32_t major) {
  quic_ext_get_api_fn get = (quic_ext_get_api_fn)rb_ext_resolve_symbol(
      "quic/quic", "quic_ext_get_api");
  const quic_ext_api *api = get != NULL ? get(major) : NULL;
  if (api == NULL || api->size < sizeof(quic_ext_api)) {
    VALUE quic = rb_const_get(rb_cObject, rb_intern("QUIC"));
    VALUE version = rb_const_get(quic, rb_intern("VERSION"));
    rb_raise(rb_eLoadError,
             "http3 needs the quic gem's C function table for quic/ext.h "
             "ABI major version %u (quic ~> 0.0.3), which quic %" PRIsVALUE
             " does not provide",
             (unsigned int)major, version);
  }
  return api;
}

/*
 * call-seq:
 *   HTTP3::Testing.load_quic_api(major) -> true
 *
 * Looks the quic gem's table up again for the given ABI major version, as
 * loading http3 does, and raises LoadError if there is none. Internal, for
 * testing the version check.
 */
static VALUE rb_http3_testing_load_quic_api(VALUE self, VALUE major) {
  http3_load_quic_api(NUM2UINT(major));
  return Qtrue;
}

RUBY_FUNC_EXPORTED void Init_http3(void) {
  /* quic.so has to be loaded before its symbols can be resolved. */
  rb_require("quic");
  http3_quic_api = http3_load_quic_api(QUIC_EXT_ABI_MAJOR);

  /* The nghttp3 bindings live in HTTP3::Nghttp3. HTTP3 is also opened in
   * lib/http3.rb; both must stay modules. */
  VALUE rb_mHTTP3 = rb_define_module("HTTP3");
  VALUE rb_mHTTP3Testing = rb_define_module_under(rb_mHTTP3, "Testing");
  rb_define_singleton_method(rb_mHTTP3Testing, "load_quic_api",
                             rb_http3_testing_load_quic_api, 1);
  rb_mNghttp3 = rb_define_module_under(rb_mHTTP3, "Nghttp3");

  /* Define compile-time version constants */
  rb_define_const(rb_mNghttp3, "NGHTTP3_VERSION",
                  rb_str_new_cstr(NGHTTP3_VERSION));
  rb_define_const(rb_mNghttp3, "NGHTTP3_VERSION_NUM",
                  INT2NUM(NGHTTP3_VERSION_NUM));
  rb_define_const(rb_mNghttp3, "NGHTTP3_VERSION_AGE",
                  INT2NUM(NGHTTP3_VERSION_AGE));

  /* Define module method for runtime version */
  rb_define_singleton_method(rb_mNghttp3, "library_version",
                             rb_nghttp3_library_version, -1);

  /* Define Info class */
  rb_cNghttp3Info = rb_define_class_under(rb_mNghttp3, "Info", rb_cObject);
  rb_undef_method(rb_singleton_class(rb_cNghttp3Info), "new");
  rb_define_method(rb_cNghttp3Info, "age", rb_nghttp3_info_age, 0);
  rb_define_method(rb_cNghttp3Info, "version_num", rb_nghttp3_info_version_num,
                   0);
  rb_define_method(rb_cNghttp3Info, "version_str", rb_nghttp3_info_version_str,
                   0);

  /* Define base error class */
  rb_eNghttp3Error =
      rb_define_class_under(rb_mNghttp3, "Error", rb_eStandardError);

  /* Define error code constants */
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_INVALID_ARGUMENT",
                  INT2NUM(NGHTTP3_ERR_INVALID_ARGUMENT));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_INVALID_STATE",
                  INT2NUM(NGHTTP3_ERR_INVALID_STATE));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_WOULDBLOCK",
                  INT2NUM(NGHTTP3_ERR_WOULDBLOCK));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_STREAM_IN_USE",
                  INT2NUM(NGHTTP3_ERR_STREAM_IN_USE));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_MALFORMED_HTTP_HEADER",
                  INT2NUM(NGHTTP3_ERR_MALFORMED_HTTP_HEADER));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_MALFORMED_HTTP_MESSAGING",
                  INT2NUM(NGHTTP3_ERR_MALFORMED_HTTP_MESSAGING));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_QPACK_FATAL",
                  INT2NUM(NGHTTP3_ERR_QPACK_FATAL));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_QPACK_HEADER_TOO_LARGE",
                  INT2NUM(NGHTTP3_ERR_QPACK_HEADER_TOO_LARGE));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_STREAM_NOT_FOUND",
                  INT2NUM(NGHTTP3_ERR_STREAM_NOT_FOUND));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_CONN_CLOSING",
                  INT2NUM(NGHTTP3_ERR_CONN_CLOSING));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_STREAM_DATA_OVERFLOW",
                  INT2NUM(NGHTTP3_ERR_STREAM_DATA_OVERFLOW));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_FATAL", INT2NUM(NGHTTP3_ERR_FATAL));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_NOMEM", INT2NUM(NGHTTP3_ERR_NOMEM));
  rb_define_const(rb_mNghttp3, "NGHTTP3_ERR_CALLBACK_FAILURE",
                  INT2NUM(NGHTTP3_ERR_CALLBACK_FAILURE));

  /* Define HTTP/3 application error code constants */
  rb_define_const(rb_mNghttp3, "H3_NO_ERROR", INT2NUM(NGHTTP3_H3_NO_ERROR));
  rb_define_const(rb_mNghttp3, "H3_GENERAL_PROTOCOL_ERROR",
                  INT2NUM(NGHTTP3_H3_GENERAL_PROTOCOL_ERROR));
  rb_define_const(rb_mNghttp3, "H3_INTERNAL_ERROR",
                  INT2NUM(NGHTTP3_H3_INTERNAL_ERROR));
  rb_define_const(rb_mNghttp3, "H3_STREAM_CREATION_ERROR",
                  INT2NUM(NGHTTP3_H3_STREAM_CREATION_ERROR));
  rb_define_const(rb_mNghttp3, "H3_CLOSED_CRITICAL_STREAM",
                  INT2NUM(NGHTTP3_H3_CLOSED_CRITICAL_STREAM));
  rb_define_const(rb_mNghttp3, "H3_FRAME_UNEXPECTED",
                  INT2NUM(NGHTTP3_H3_FRAME_UNEXPECTED));
  rb_define_const(rb_mNghttp3, "H3_FRAME_ERROR",
                  INT2NUM(NGHTTP3_H3_FRAME_ERROR));
  rb_define_const(rb_mNghttp3, "H3_EXCESSIVE_LOAD",
                  INT2NUM(NGHTTP3_H3_EXCESSIVE_LOAD));
  rb_define_const(rb_mNghttp3, "H3_ID_ERROR", INT2NUM(NGHTTP3_H3_ID_ERROR));
  rb_define_const(rb_mNghttp3, "H3_SETTINGS_ERROR",
                  INT2NUM(NGHTTP3_H3_SETTINGS_ERROR));
  rb_define_const(rb_mNghttp3, "H3_MISSING_SETTINGS",
                  INT2NUM(NGHTTP3_H3_MISSING_SETTINGS));
  rb_define_const(rb_mNghttp3, "H3_REQUEST_REJECTED",
                  INT2NUM(NGHTTP3_H3_REQUEST_REJECTED));
  rb_define_const(rb_mNghttp3, "H3_REQUEST_CANCELLED",
                  INT2NUM(NGHTTP3_H3_REQUEST_CANCELLED));
  rb_define_const(rb_mNghttp3, "H3_REQUEST_INCOMPLETE",
                  INT2NUM(NGHTTP3_H3_REQUEST_INCOMPLETE));
  rb_define_const(rb_mNghttp3, "H3_MESSAGE_ERROR",
                  INT2NUM(NGHTTP3_H3_MESSAGE_ERROR));
  rb_define_const(rb_mNghttp3, "H3_CONNECT_ERROR",
                  INT2NUM(NGHTTP3_H3_CONNECT_ERROR));
  rb_define_const(rb_mNghttp3, "H3_VERSION_FALLBACK",
                  INT2NUM(NGHTTP3_H3_VERSION_FALLBACK));

  /* Define data flag constants */
  rb_define_const(rb_mNghttp3, "DATA_FLAG_NONE",
                  UINT2NUM(NGHTTP3_DATA_FLAG_NONE));
  rb_define_const(rb_mNghttp3, "DATA_FLAG_EOF",
                  UINT2NUM(NGHTTP3_DATA_FLAG_EOF));
  rb_define_const(rb_mNghttp3, "DATA_FLAG_NO_END_STREAM",
                  UINT2NUM(NGHTTP3_DATA_FLAG_NO_END_STREAM));

  /* Define specific error classes */
  rb_eNghttp3InvalidArgumentError = rb_define_class_under(
      rb_mNghttp3, "InvalidArgumentError", rb_eNghttp3Error);
  rb_eNghttp3InvalidStateError =
      rb_define_class_under(rb_mNghttp3, "InvalidStateError", rb_eNghttp3Error);
  rb_eNghttp3WouldBlockError =
      rb_define_class_under(rb_mNghttp3, "WouldBlockError", rb_eNghttp3Error);
  rb_eNghttp3StreamInUseError =
      rb_define_class_under(rb_mNghttp3, "StreamInUseError", rb_eNghttp3Error);
  rb_eNghttp3MalformedHTTPHeaderError = rb_define_class_under(
      rb_mNghttp3, "MalformedHTTPHeaderError", rb_eNghttp3Error);
  rb_eNghttp3MalformedHTTPMessagingError = rb_define_class_under(
      rb_mNghttp3, "MalformedHTTPMessagingError", rb_eNghttp3Error);
  rb_eNghttp3QPACKFatalError =
      rb_define_class_under(rb_mNghttp3, "QPACKFatalError", rb_eNghttp3Error);
  rb_eNghttp3QPACKHeaderTooLargeError = rb_define_class_under(
      rb_mNghttp3, "QPACKHeaderTooLargeError", rb_eNghttp3Error);
  rb_eNghttp3StreamNotFoundError = rb_define_class_under(
      rb_mNghttp3, "StreamNotFoundError", rb_eNghttp3Error);
  rb_eNghttp3ConnClosingError =
      rb_define_class_under(rb_mNghttp3, "ConnClosingError", rb_eNghttp3Error);
  rb_eNghttp3StreamDataOverflowError = rb_define_class_under(
      rb_mNghttp3, "StreamDataOverflowError", rb_eNghttp3Error);
  rb_eNghttp3FatalError =
      rb_define_class_under(rb_mNghttp3, "FatalError", rb_eNghttp3Error);
  rb_eNghttp3NoMemError =
      rb_define_class_under(rb_mNghttp3, "NoMemError", rb_eNghttp3Error);
  rb_eNghttp3CallbackFailureError = rb_define_class_under(
      rb_mNghttp3, "CallbackFailureError", rb_eNghttp3Error);

  /* Define error utility methods */
  rb_define_singleton_method(rb_mNghttp3, "err_is_fatal?",
                             rb_nghttp3_err_is_fatal, 1);
  rb_define_singleton_method(rb_mNghttp3, "strerror", rb_nghttp3_strerror, 1);

  /* Initialize other classes */
  Init_nghttp3_settings();
  Init_nghttp3_nv();
  Init_nghttp3_callbacks();
  Init_nghttp3_connection();
  Init_nghttp3_qpack();
  Init_http3_session(rb_mHTTP3);
}
