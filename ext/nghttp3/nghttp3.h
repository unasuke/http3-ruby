#ifndef NGHTTP3_RUBY_H
#define NGHTTP3_RUBY_H 1

#include "ruby.h"
#include <nghttp3/nghttp3.h>

extern VALUE rb_mNghttp3;
extern VALUE rb_cNghttp3Info;
extern VALUE rb_eNghttp3Error;

/* Error classes */
extern VALUE rb_eNghttp3InvalidArgumentError;
extern VALUE rb_eNghttp3InvalidStateError;
extern VALUE rb_eNghttp3WouldBlockError;
extern VALUE rb_eNghttp3StreamInUseError;
extern VALUE rb_eNghttp3MalformedHTTPHeaderError;
extern VALUE rb_eNghttp3MalformedHTTPMessagingError;
extern VALUE rb_eNghttp3QPACKFatalError;
extern VALUE rb_eNghttp3QPACKHeaderTooLargeError;
extern VALUE rb_eNghttp3StreamNotFoundError;
extern VALUE rb_eNghttp3ConnClosingError;
extern VALUE rb_eNghttp3StreamDataOverflowError;
extern VALUE rb_eNghttp3FatalError;
extern VALUE rb_eNghttp3NoMemError;
extern VALUE rb_eNghttp3CallbackFailureError;

/* Data structure classes */
extern VALUE rb_cNghttp3Settings;
extern VALUE rb_cNghttp3NV;
extern VALUE rb_cNghttp3Connection;
extern VALUE rb_cNghttp3Callbacks;

/* QPACK module and classes */
extern VALUE rb_mNghttp3QPACK;
extern VALUE rb_cNghttp3QPACKEncoder;
extern VALUE rb_cNghttp3QPACKDecoder;

/* TypedData type for Settings (used by Connection) */
extern const rb_data_type_t settings_data_type;

/* TypedData type for Callbacks */
extern const rb_data_type_t callbacks_data_type;

/* The C side of an Nghttp3::Connection. nghttp3 gets a pointer to this
 * struct as conn_user_data, never the Ruby object: GC.compact may move the
 * object, and dcompact keeps self pointing at it. */
typedef struct {
  nghttp3_conn *conn;
  VALUE self;
  VALUE settings;            /* Prevent Settings from being GC'd */
  VALUE callbacks;           /* Prevent Callbacks from being GC'd */
  VALUE stream_data_readers; /* stream_id => Proc/String for body data */
  VALUE stream_user_data;    /* stream_id => arbitrary user data */
  VALUE pending_data;        /* stream_id => [String, ...] for ACK tracking */
  int is_closed;
  int is_server;
} ConnectionObj;

/* Helper functions */
VALUE nghttp3_rb_error_class_for_code(int error_code);
void nghttp3_rb_raise(int error_code, const char *fmt, ...);

/* Settings helper */
nghttp3_settings *nghttp3_rb_get_settings(VALUE rb_settings);

/* NV helper */
nghttp3_nv nghttp3_rb_nv_to_c(VALUE rb_nv);

/* Callbacks helper */
void nghttp3_rb_setup_callbacks(nghttp3_callbacks *callbacks);

/* Init functions */
void Init_nghttp3_settings(void);
void Init_nghttp3_nv(void);
void Init_nghttp3_connection(void);
void Init_nghttp3_callbacks(void);
void Init_nghttp3_qpack(void);

#endif /* NGHTTP3_RUBY_H */
