#ifndef NGHTTP3_RUBY_H
#define NGHTTP3_RUBY_H 1

#include "ruby.h"
#include "ruby/st.h"
#include <nghttp3/nghttp3.h>
#include <quic/ext.h>

/* The quic gem's C function table, looked up once by Init_http3. */
extern const quic_ext_api *http3_quic_api;

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

/* Which call into nghttp3 a connection is in, for ConnectionObj.entered.
 * nghttp3 runs callbacks only inside such a call, and lets a callback call
 * back into the connection only as far as that call allows: from inside
 * read_stream, ngtcp2's examples submit a response, but nghttp3 is in no
 * state to read, write or be deleted. */
enum { CONN_IDLE, CONN_IN_READ, CONN_IN_OTHER };

/* The C side of an Nghttp3::Connection. nghttp3 gets a pointer to this
 * struct as conn_user_data, never the Ruby object: GC.compact may move the
 * object, and dcompact keeps self pointing at it. */
typedef struct {
  nghttp3_conn *conn;
  VALUE self;
  VALUE settings;            /* Prevent Settings from being GC'd */
  VALUE callbacks;           /* An Nghttp3::Callbacks, or nil */
  VALUE stream_data_readers; /* stream_id => Proc/String for body data */
  VALUE stream_user_data;    /* stream_id => arbitrary user data */
  /* stream_id => PendingStream *: the body Strings handed to nghttp3 and
   * not yet wholly acknowledged, which nghttp3 may still read. dmark pins
   * every one of them, so that GC.compact cannot move their bytes. */
  st_table *pending;
  /* An exception a Ruby callback raised inside nghttp3, kept here instead
   * of unwinding through nghttp3's frames; the method that called into
   * nghttp3 raises it once nghttp3 has returned. Qnil when there is none. */
  VALUE pending_exc;
  int is_closed;
  int is_server;
  int entered; /* CONN_IDLE, or the call into nghttp3 under way */
  /* nghttp3 returned an error after which it allows nothing but
   * nghttp3_conn_del: any from read_stream or writev_stream, or a fatal one
   * from another call. */
  int failed;
  /* What has been done to the connection, for the calls nghttp3 asserts
   * come after it or not after it. goaway is 0 before any GOAWAY, 1 after
   * submit_shutdown_notice and 2 after shutdown. max_client_streams is the
   * last value given to set_max_client_streams_bidi. */
  int ctrl_bound;
  int qpack_bound;
  int goaway;
  uint64_t max_client_streams;
} ConnectionObj;

/* Run body(arg) under rb_protect on behalf of a callback of obj. An
 * exception is kept in obj->pending_exc (the first one wins) and turned
 * into NGHTTP3_ERR_CALLBACK_FAILURE; 0 otherwise. */
int nghttp3_rb_protect(ConnectionObj *obj, VALUE (*body)(VALUE), VALUE arg);

/* Bookkeeping of the body Strings, for the acked_stream_data and
 * stream_close callbacks. Both touch Ruby objects, so call them under
 * nghttp3_rb_protect. */
void nghttp3_rb_conn_acked(ConnectionObj *obj, int64_t stream_id,
                           uint64_t datalen);
void nghttp3_rb_conn_stream_closed(ConnectionObj *obj, int64_t stream_id);

/* Helper functions */
VALUE nghttp3_rb_error_class_for_code(int error_code);
void nghttp3_rb_raise(int error_code, const char *fmt, ...);

/* rb_id (to_int is called) as a stream id for nghttp3, which asserts the
 * range of the ids it is given: ArgumentError unless it is 0..2**62-1. */
int64_t nghttp3_rb_stream_id(VALUE rb_id);

/* Settings helper */
nghttp3_settings *nghttp3_rb_get_settings(VALUE rb_settings);

/* NV helpers. nghttp3_rb_nva_fill fills nva with the first nvlen elements
 * of headers, an Array of NVs, pointing into their Strings. It never raises,
 * allocates nothing and runs no Ruby code, so that from the moment it takes
 * those pointers until nghttp3 has copied the Strings, nothing can change,
 * free or move them; so call it after anything that allocates or may run
 * Ruby code, and call nghttp3 right after it. It returns the index of the
 * first element that is not an NV with String name and value and flags of
 * 0..255, or -1 if there is none. nghttp3_rb_raise_bad_nv raises
 * ArgumentError for that index. */
long nghttp3_rb_nva_fill(VALUE headers, nghttp3_nv *nva, long nvlen);
NORETURN(void nghttp3_rb_raise_bad_nv(long index));

/* Callbacks helper: install the C callbacks, which do their own
 * bookkeeping and then call the Ruby blocks of conn's Callbacks, if any. */
void nghttp3_rb_setup_callbacks(nghttp3_callbacks *callbacks);

/* Init functions */
void Init_nghttp3_settings(void);
void Init_nghttp3_nv(void);
void Init_nghttp3_connection(void);
void Init_nghttp3_callbacks(void);
void Init_nghttp3_qpack(void);
void Init_http3_session(VALUE rb_mHTTP3);

#endif /* NGHTTP3_RUBY_H */
