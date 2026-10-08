#include "nghttp3.h"

VALUE rb_cNghttp3Connection;

static void connection_mark(void *ptr) {
  ConnectionObj *obj = (ConnectionObj *)ptr;
  if (obj->settings != Qnil) {
    rb_gc_mark(obj->settings);
  }
  if (obj->callbacks != Qnil) {
    rb_gc_mark(obj->callbacks);
  }
  if (obj->stream_data_readers != Qnil) {
    rb_gc_mark(obj->stream_data_readers);
  }
  if (obj->stream_user_data != Qnil) {
    rb_gc_mark(obj->stream_user_data);
  }
  if (obj->pending_data != Qnil) {
    rb_gc_mark(obj->pending_data);
  }
}

static void connection_free(void *ptr) {
  ConnectionObj *obj = (ConnectionObj *)ptr;
  if (obj->conn != NULL && !obj->is_closed) {
    nghttp3_conn_del(obj->conn);
    obj->conn = NULL;
  }
  xfree(ptr);
}

static size_t connection_memsize(const void *ptr) {
  return sizeof(ConnectionObj);
}

/* self is the object wrapping this struct, so it is not marked, but
 * GC.compact may still move it. Everything else is pinned by dmark. */
static void connection_compact(void *ptr) {
  ConnectionObj *obj = (ConnectionObj *)ptr;
  obj->self = rb_gc_location(obj->self);
}

static const rb_data_type_t connection_data_type = {
    .wrap_struct_name = "nghttp3_conn_rb",
    .function =
        {
            .dmark = connection_mark,
            .dfree = connection_free,
            .dsize = connection_memsize,
            .dcompact = connection_compact,
        },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE connection_alloc(VALUE klass) {
  ConnectionObj *obj;
  VALUE self =
      TypedData_Make_Struct(klass, ConnectionObj, &connection_data_type, obj);
  obj->conn = NULL;
  obj->self = self;
  obj->settings = Qnil;
  obj->callbacks = Qnil;
  obj->stream_data_readers = rb_hash_new();
  obj->stream_user_data = rb_hash_new();
  obj->pending_data = rb_hash_new();
  obj->is_closed = 0;
  obj->is_server = 0;
  return self;
}

/* Prepare the nghttp3_callbacks for a new connection. A Callbacks object is
 * checked here, so that the C callbacks can take it as one. */
static void connection_setup_callbacks(ConnectionObj *obj, VALUE rb_callbacks,
                                       nghttp3_callbacks *callbacks) {
  memset(callbacks, 0, sizeof(*callbacks));
  if (!NIL_P(rb_callbacks)) {
    rb_check_typeddata(rb_callbacks, &callbacks_data_type);
    obj->callbacks = rb_callbacks;
    nghttp3_rb_setup_callbacks(callbacks);
  }
}

/*
 * call-seq:
 *   Connection.client_new(settings = nil, callbacks = nil) -> Connection
 *
 * Creates a new client HTTP/3 connection.
 * If settings is nil, default settings are used.
 * If callbacks is provided, it will be used for HTTP/3 event notifications.
 */
static VALUE rb_nghttp3_connection_client_new(int argc, VALUE *argv,
                                              VALUE klass) {
  VALUE rb_settings, rb_callbacks;
  ConnectionObj *obj;
  nghttp3_settings settings;
  nghttp3_settings *settings_ptr;
  nghttp3_callbacks callbacks;
  int rv;
  VALUE self;

  rb_scan_args(argc, argv, "02", &rb_settings, &rb_callbacks);

  self = connection_alloc(klass);
  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (NIL_P(rb_settings)) {
    nghttp3_settings_default(&settings);
    settings_ptr = &settings;
  } else {
    settings_ptr = nghttp3_rb_get_settings(rb_settings);
    obj->settings = rb_settings;
  }

  connection_setup_callbacks(obj, rb_callbacks, &callbacks);

  rv = nghttp3_conn_client_new(&obj->conn, &callbacks, settings_ptr, NULL, obj);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to create client connection");
  }

  obj->is_server = 0;
  return self;
}

/*
 * call-seq:
 *   Connection.server_new(settings = nil, callbacks = nil) -> Connection
 *
 * Creates a new server HTTP/3 connection.
 * If settings is nil, default settings are used.
 * If callbacks is provided, it will be used for HTTP/3 event notifications.
 */
static VALUE rb_nghttp3_connection_server_new(int argc, VALUE *argv,
                                              VALUE klass) {
  VALUE rb_settings, rb_callbacks;
  ConnectionObj *obj;
  nghttp3_settings settings;
  nghttp3_settings *settings_ptr;
  nghttp3_callbacks callbacks;
  int rv;
  VALUE self;

  rb_scan_args(argc, argv, "02", &rb_settings, &rb_callbacks);

  self = connection_alloc(klass);
  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (NIL_P(rb_settings)) {
    nghttp3_settings_default(&settings);
    settings_ptr = &settings;
  } else {
    settings_ptr = nghttp3_rb_get_settings(rb_settings);
    obj->settings = rb_settings;
  }

  connection_setup_callbacks(obj, rb_callbacks, &callbacks);

  rv = nghttp3_conn_server_new(&obj->conn, &callbacks, settings_ptr, NULL, obj);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to create server connection");
  }

  obj->is_server = 1;
  return self;
}

/*
 * call-seq:
 *   connection.bind_control_stream(stream_id) -> self
 *
 * Binds the control stream to the given stream_id.
 * This must be called before sending any HTTP frames.
 */
static VALUE rb_nghttp3_connection_bind_control_stream(VALUE self,
                                                       VALUE rb_stream_id) {
  ConnectionObj *obj;
  int64_t stream_id;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  rv = nghttp3_conn_bind_control_stream(obj->conn, stream_id);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to bind control stream");
  }

  return self;
}

/*
 * call-seq:
 *   connection.bind_qpack_streams(encoder_stream_id, decoder_stream_id) -> self
 *
 * Binds the QPACK encoder and decoder streams.
 * This must be called before sending any HTTP frames.
 */
static VALUE rb_nghttp3_connection_bind_qpack_streams(VALUE self,
                                                      VALUE rb_enc_stream_id,
                                                      VALUE rb_dec_stream_id) {
  ConnectionObj *obj;
  int64_t enc_stream_id, dec_stream_id;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  enc_stream_id = NUM2LL(rb_enc_stream_id);
  dec_stream_id = NUM2LL(rb_dec_stream_id);

  rv = nghttp3_conn_bind_qpack_streams(obj->conn, enc_stream_id, dec_stream_id);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to bind QPACK streams");
  }

  return self;
}

/*
 * call-seq:
 *   connection.close -> nil
 *
 * Explicitly closes the connection and frees resources.
 * After calling this, the connection object cannot be used.
 */
static VALUE rb_nghttp3_connection_close(VALUE self) {
  ConnectionObj *obj;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn != NULL && !obj->is_closed) {
    nghttp3_conn_del(obj->conn);
    obj->conn = NULL;
    obj->is_closed = 1;
  }

  return Qnil;
}

/*
 * call-seq:
 *   connection.closed? -> true or false
 *
 * Returns true if the connection has been closed.
 */
static VALUE rb_nghttp3_connection_closed_p(VALUE self) {
  ConnectionObj *obj;
  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);
  return obj->is_closed ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *   connection.server? -> true or false
 *
 * Returns true if this is a server connection.
 */
static VALUE rb_nghttp3_connection_server_p(VALUE self) {
  ConnectionObj *obj;
  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);
  return obj->is_server ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *   connection.client? -> true or false
 *
 * Returns true if this is a client connection.
 */
static VALUE rb_nghttp3_connection_client_p(VALUE self) {
  ConnectionObj *obj;
  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);
  return obj->is_server ? Qfalse : Qtrue;
}

/*
 * call-seq:
 *   connection.read_stream(stream_id, data, fin: false) -> Integer
 *
 * Reads data on a stream. This should be called when data is received from
 * the QUIC layer. Returns the number of bytes consumed (for flow control).
 */
static VALUE rb_nghttp3_connection_read_stream(int argc, VALUE *argv,
                                               VALUE self) {
  VALUE rb_stream_id, rb_data, rb_opts;
  VALUE rb_fin = Qfalse;
  ConnectionObj *obj;
  nghttp3_ssize rv;
  int64_t stream_id;
  int fin;

  rb_scan_args(argc, argv, "2:", &rb_stream_id, &rb_data, &rb_opts);

  if (!NIL_P(rb_opts)) {
    VALUE rb_fin_val = rb_hash_aref(rb_opts, ID2SYM(rb_intern("fin")));
    if (!NIL_P(rb_fin_val)) {
      rb_fin = rb_fin_val;
    }
  }

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  Check_Type(rb_data, T_STRING);
  stream_id = NUM2LL(rb_stream_id);
  fin = RTEST(rb_fin) ? 1 : 0;

  rv = nghttp3_conn_read_stream(obj->conn, stream_id,
                                (const uint8_t *)RSTRING_PTR(rb_data),
                                RSTRING_LEN(rb_data), fin);

  if (rv < 0) {
    nghttp3_rb_raise((int)rv, "Failed to read stream");
  }

  return LL2NUM(rv);
}

/*
 * call-seq:
 *   connection.writev_stream -> Hash or nil
 *
 * Gets stream data to send to the QUIC layer.
 * Returns a Hash with :stream_id, :fin, and :data keys, or nil if no data.
 */
static VALUE rb_nghttp3_connection_writev_stream(VALUE self) {
  ConnectionObj *obj;
  nghttp3_vec vec[16];
  nghttp3_ssize rv;
  int64_t stream_id;
  int fin;
  VALUE rb_result, rb_data;
  size_t i, total_len;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  rv = nghttp3_conn_writev_stream(obj->conn, &stream_id, &fin, vec, 16);

  if (rv < 0) {
    nghttp3_rb_raise((int)rv, "Failed to writev stream");
  }

  if (rv == 0 && stream_id == -1) {
    return Qnil;
  }

  /* Calculate total length and concatenate data */
  total_len = 0;
  for (i = 0; i < (size_t)rv; i++) {
    total_len += vec[i].len;
  }

  rb_data = rb_str_buf_new(total_len);
  for (i = 0; i < (size_t)rv; i++) {
    rb_str_buf_cat(rb_data, (const char *)vec[i].base, vec[i].len);
  }

  rb_result = rb_hash_new();
  rb_hash_aset(rb_result, ID2SYM(rb_intern("stream_id")), LL2NUM(stream_id));
  rb_hash_aset(rb_result, ID2SYM(rb_intern("fin")), fin ? Qtrue : Qfalse);
  rb_hash_aset(rb_result, ID2SYM(rb_intern("data")), rb_data);

  return rb_result;
}

/*
 * call-seq:
 *   connection.add_write_offset(stream_id, n) -> self
 *
 * Tells the connection that n bytes have been accepted by the QUIC layer.
 */
static VALUE rb_nghttp3_connection_add_write_offset(VALUE self,
                                                    VALUE rb_stream_id,
                                                    VALUE rb_n) {
  ConnectionObj *obj;
  int rv;
  int64_t stream_id;
  size_t n;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  n = NUM2SIZET(rb_n);

  rv = nghttp3_conn_add_write_offset(obj->conn, stream_id, n);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to add write offset");
  }

  return self;
}

/*
 * call-seq:
 *   connection.add_ack_offset(stream_id, n) -> self
 *
 * Tells the connection that n bytes have been acknowledged by the remote peer.
 */
static VALUE rb_nghttp3_connection_add_ack_offset(VALUE self,
                                                  VALUE rb_stream_id,
                                                  VALUE rb_n) {
  ConnectionObj *obj;
  int rv;
  int64_t stream_id;
  uint64_t n;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  n = NUM2ULL(rb_n);

  rv = nghttp3_conn_add_ack_offset(obj->conn, stream_id, n);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to add ack offset");
  }

  return self;
}

/*
 * call-seq:
 *   connection.block_stream(stream_id) -> self
 *
 * Marks a stream as blocked due to QUIC flow control.
 */
static VALUE rb_nghttp3_connection_block_stream(VALUE self,
                                                VALUE rb_stream_id) {
  ConnectionObj *obj;
  int64_t stream_id;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  nghttp3_conn_block_stream(obj->conn, stream_id);

  return self;
}

/*
 * call-seq:
 *   connection.unblock_stream(stream_id) -> self
 *
 * Marks a stream as unblocked (no longer blocked by QUIC flow control).
 */
static VALUE rb_nghttp3_connection_unblock_stream(VALUE self,
                                                  VALUE rb_stream_id) {
  ConnectionObj *obj;
  int rv;
  int64_t stream_id;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  rv = nghttp3_conn_unblock_stream(obj->conn, stream_id);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to unblock stream");
  }

  return self;
}

/*
 * call-seq:
 *   connection.stream_writable?(stream_id) -> true or false
 *
 * Returns true if the stream is writable.
 */
static VALUE rb_nghttp3_connection_stream_writable_p(VALUE self,
                                                     VALUE rb_stream_id) {
  ConnectionObj *obj;
  int64_t stream_id;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  rv = nghttp3_conn_is_stream_writable(obj->conn, stream_id);

  return rv ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *   connection.close_stream(stream_id, app_error_code) -> self
 *
 * Closes the stream with the given error code.
 */
static VALUE rb_nghttp3_connection_close_stream(VALUE self, VALUE rb_stream_id,
                                                VALUE rb_error_code) {
  ConnectionObj *obj;
  int rv;
  int64_t stream_id;
  uint64_t app_error_code;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  app_error_code = NUM2ULL(rb_error_code);

  rv = nghttp3_conn_close_stream(obj->conn, stream_id, app_error_code);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to close stream");
  }

  return self;
}

/*
 * call-seq:
 *   connection.shutdown_stream_write(stream_id) -> self
 *
 * Prevents any further write operations on the stream.
 */
static VALUE rb_nghttp3_connection_shutdown_stream_write(VALUE self,
                                                         VALUE rb_stream_id) {
  ConnectionObj *obj;
  int64_t stream_id;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  nghttp3_conn_shutdown_stream_write(obj->conn, stream_id);

  return self;
}

/*
 * call-seq:
 *   connection.resume_stream(stream_id) -> self
 *
 * Resumes a stream that was blocked for input data.
 */
static VALUE rb_nghttp3_connection_resume_stream(VALUE self,
                                                 VALUE rb_stream_id) {
  ConnectionObj *obj;
  int rv;
  int64_t stream_id;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  rv = nghttp3_conn_resume_stream(obj->conn, stream_id);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to resume stream");
  }

  return self;
}

/*
 * Callback function for providing body data to nghttp3.
 */
static nghttp3_ssize read_data_callback(nghttp3_conn *conn, int64_t stream_id,
                                        nghttp3_vec *vec, size_t veccnt,
                                        uint32_t *pflags, void *conn_user_data,
                                        void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE readers, reader, result;
  VALUE rb_stream_id = LL2NUM(stream_id);

  readers = obj->stream_data_readers;
  reader = rb_hash_aref(readers, rb_stream_id);

  if (NIL_P(reader)) {
    *pflags |= NGHTTP3_DATA_FLAG_EOF;
    return 0;
  }

  if (RB_TYPE_P(reader, T_STRING)) {
    /* String: return all data at once */
    vec[0].base = (uint8_t *)RSTRING_PTR(reader);
    vec[0].len = RSTRING_LEN(reader);
    *pflags |= NGHTTP3_DATA_FLAG_EOF;

    /* Keep string in pending_data until ACKed */
    VALUE pending = rb_hash_aref(obj->pending_data, rb_stream_id);
    if (NIL_P(pending)) {
      pending = rb_ary_new();
      rb_hash_aset(obj->pending_data, rb_stream_id, pending);
    }
    rb_ary_push(pending, reader);
    rb_hash_delete(readers, rb_stream_id);
    return 1;
  }

  /* Proc: call it to get data */
  result = rb_funcall(reader, rb_intern("call"), 1, rb_stream_id);

  if (NIL_P(result)) {
    *pflags |= NGHTTP3_DATA_FLAG_EOF;
    rb_hash_delete(readers, rb_stream_id);
    return 0;
  }

  if (SYMBOL_P(result) && SYM2ID(result) == rb_intern("wouldblock")) {
    return NGHTTP3_ERR_WOULDBLOCK;
  }

  /* Result should be a String */
  StringValue(result);

  /* Store in pending_data for GC protection until ACKed */
  VALUE pending = rb_hash_aref(obj->pending_data, rb_stream_id);
  if (NIL_P(pending)) {
    pending = rb_ary_new();
    rb_hash_aset(obj->pending_data, rb_stream_id, pending);
  }
  rb_ary_push(pending, result);

  vec[0].base = (uint8_t *)RSTRING_PTR(result);
  vec[0].len = RSTRING_LEN(result);

  return 1;
}

/* Static data_reader structure for use in submit functions */
static const nghttp3_data_reader data_reader = {.read_data =
                                                    read_data_callback};

/*
 * call-seq:
 *   connection.submit_request(stream_id, headers, body: nil) -> self
 *   connection.submit_request(stream_id, headers) { |stream_id| ... } -> self
 *
 * Submits an HTTP request on the given stream.
 * Headers should be an array of Nghttp3::NV objects.
 */
static VALUE rb_nghttp3_connection_submit_request(int argc, VALUE *argv,
                                                  VALUE self) {
  VALUE rb_stream_id, rb_headers, rb_opts, rb_body;
  ConnectionObj *obj;
  int64_t stream_id;
  nghttp3_nv *nva;
  size_t nvlen, i;
  int rv;
  int has_body = 0;

  rb_scan_args(argc, argv, "2:", &rb_stream_id, &rb_headers, &rb_opts);

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  if (obj->is_server) {
    rb_raise(rb_eNghttp3InvalidStateError,
             "submit_request can only be called on client connections");
  }

  stream_id = NUM2LL(rb_stream_id);
  Check_Type(rb_headers, T_ARRAY);
  nvlen = RARRAY_LEN(rb_headers);

  /* Allocate and convert headers */
  nva = ALLOCA_N(nghttp3_nv, nvlen);
  for (i = 0; i < nvlen; i++) {
    VALUE rb_nv = rb_ary_entry(rb_headers, i);
    nva[i] = nghttp3_rb_nv_to_c(rb_nv);
  }

  /* Check for body */
  rb_body = Qnil;
  if (!NIL_P(rb_opts)) {
    rb_body = rb_hash_aref(rb_opts, ID2SYM(rb_intern("body")));
  }

  if (!NIL_P(rb_body)) {
    StringValue(rb_body);
    rb_hash_aset(obj->stream_data_readers, LL2NUM(stream_id), rb_body);
    has_body = 1;
  } else if (rb_block_given_p()) {
    VALUE block = rb_block_proc();
    rb_hash_aset(obj->stream_data_readers, LL2NUM(stream_id), block);
    has_body = 1;
  }

  rv = nghttp3_conn_submit_request(obj->conn, stream_id, nva, nvlen,
                                   has_body ? &data_reader : NULL, NULL);

  if (rv != 0) {
    rb_hash_delete(obj->stream_data_readers, LL2NUM(stream_id));
    nghttp3_rb_raise(rv, "Failed to submit request");
  }

  return self;
}

/*
 * call-seq:
 *   connection.submit_response(stream_id, headers, body: nil) -> self
 *   connection.submit_response(stream_id, headers) { |stream_id| ... } -> self
 *
 * Submits an HTTP response on the given stream.
 * Headers should be an array of Nghttp3::NV objects.
 */
static VALUE rb_nghttp3_connection_submit_response(int argc, VALUE *argv,
                                                   VALUE self) {
  VALUE rb_stream_id, rb_headers, rb_opts, rb_body;
  ConnectionObj *obj;
  int64_t stream_id;
  nghttp3_nv *nva;
  size_t nvlen, i;
  int rv;
  int has_body = 0;

  rb_scan_args(argc, argv, "2:", &rb_stream_id, &rb_headers, &rb_opts);

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  if (!obj->is_server) {
    rb_raise(rb_eNghttp3InvalidStateError,
             "submit_response can only be called on server connections");
  }

  stream_id = NUM2LL(rb_stream_id);
  Check_Type(rb_headers, T_ARRAY);
  nvlen = RARRAY_LEN(rb_headers);

  /* Allocate and convert headers */
  nva = ALLOCA_N(nghttp3_nv, nvlen);
  for (i = 0; i < nvlen; i++) {
    VALUE rb_nv = rb_ary_entry(rb_headers, i);
    nva[i] = nghttp3_rb_nv_to_c(rb_nv);
  }

  /* Check for body */
  rb_body = Qnil;
  if (!NIL_P(rb_opts)) {
    rb_body = rb_hash_aref(rb_opts, ID2SYM(rb_intern("body")));
  }

  if (!NIL_P(rb_body)) {
    StringValue(rb_body);
    rb_hash_aset(obj->stream_data_readers, LL2NUM(stream_id), rb_body);
    has_body = 1;
  } else if (rb_block_given_p()) {
    VALUE block = rb_block_proc();
    rb_hash_aset(obj->stream_data_readers, LL2NUM(stream_id), block);
    has_body = 1;
  }

  rv = nghttp3_conn_submit_response(obj->conn, stream_id, nva, nvlen,
                                    has_body ? &data_reader : NULL);

  if (rv != 0) {
    rb_hash_delete(obj->stream_data_readers, LL2NUM(stream_id));
    nghttp3_rb_raise(rv, "Failed to submit response");
  }

  return self;
}

/*
 * call-seq:
 *   connection.submit_info(stream_id, headers) -> self
 *
 * Submits a 1xx informational response on the given stream.
 * Headers should be an array of Nghttp3::NV objects.
 */
static VALUE rb_nghttp3_connection_submit_info(VALUE self, VALUE rb_stream_id,
                                               VALUE rb_headers) {
  ConnectionObj *obj;
  int64_t stream_id;
  nghttp3_nv *nva;
  size_t nvlen, i;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  Check_Type(rb_headers, T_ARRAY);
  nvlen = RARRAY_LEN(rb_headers);

  nva = ALLOCA_N(nghttp3_nv, nvlen);
  for (i = 0; i < nvlen; i++) {
    VALUE rb_nv = rb_ary_entry(rb_headers, i);
    nva[i] = nghttp3_rb_nv_to_c(rb_nv);
  }

  rv = nghttp3_conn_submit_info(obj->conn, stream_id, nva, nvlen);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to submit info");
  }

  return self;
}

/*
 * call-seq:
 *   connection.submit_trailers(stream_id, trailers) -> self
 *
 * Submits trailer headers on the given stream.
 * This implicitly ends the stream.
 * Trailers should be an array of Nghttp3::NV objects.
 */
static VALUE rb_nghttp3_connection_submit_trailers(VALUE self,
                                                   VALUE rb_stream_id,
                                                   VALUE rb_trailers) {
  ConnectionObj *obj;
  int64_t stream_id;
  nghttp3_nv *nva;
  size_t nvlen, i;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  stream_id = NUM2LL(rb_stream_id);
  Check_Type(rb_trailers, T_ARRAY);
  nvlen = RARRAY_LEN(rb_trailers);

  nva = ALLOCA_N(nghttp3_nv, nvlen);
  for (i = 0; i < nvlen; i++) {
    VALUE rb_nv = rb_ary_entry(rb_trailers, i);
    nva[i] = nghttp3_rb_nv_to_c(rb_nv);
  }

  rv = nghttp3_conn_submit_trailers(obj->conn, stream_id, nva, nvlen);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to submit trailers");
  }

  return self;
}

/*
 * call-seq:
 *   connection.submit_shutdown_notice -> self
 *
 * Signals the intention to shut down the connection gracefully.
 * After calling this, no new streams will be accepted.
 */
static VALUE rb_nghttp3_connection_submit_shutdown_notice(VALUE self) {
  ConnectionObj *obj;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  rv = nghttp3_conn_submit_shutdown_notice(obj->conn);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to submit shutdown notice");
  }

  return self;
}

/*
 * call-seq:
 *   connection.shutdown -> self
 *
 * Initiates graceful shutdown. Should be called after submit_shutdown_notice.
 */
static VALUE rb_nghttp3_connection_shutdown(VALUE self) {
  ConnectionObj *obj;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  rv = nghttp3_conn_shutdown(obj->conn);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to shutdown connection");
  }

  return self;
}

/*
 * call-seq:
 *   connection.set_stream_user_data(stream_id, data) -> self
 *
 * Associates arbitrary data with the given stream.
 */
static VALUE rb_nghttp3_connection_set_stream_user_data(VALUE self,
                                                        VALUE rb_stream_id,
                                                        VALUE rb_data) {
  ConnectionObj *obj;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  rb_hash_aset(obj->stream_user_data, rb_stream_id, rb_data);

  return self;
}

/*
 * call-seq:
 *   connection.get_stream_user_data(stream_id) -> Object or nil
 *
 * Returns the data associated with the given stream, or nil if none.
 */
static VALUE rb_nghttp3_connection_get_stream_user_data(VALUE self,
                                                        VALUE rb_stream_id) {
  ConnectionObj *obj;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  return rb_hash_aref(obj->stream_user_data, rb_stream_id);
}

void Init_nghttp3_connection(void) {
  rb_cNghttp3Connection =
      rb_define_class_under(rb_mNghttp3, "Connection", rb_cObject);

  /* Disable direct instantiation with new */
  rb_undef_alloc_func(rb_cNghttp3Connection);

  /* Class methods */
  rb_define_singleton_method(rb_cNghttp3Connection, "client_new",
                             rb_nghttp3_connection_client_new, -1);
  rb_define_singleton_method(rb_cNghttp3Connection, "server_new",
                             rb_nghttp3_connection_server_new, -1);

  /* Instance methods */
  rb_define_method(rb_cNghttp3Connection, "bind_control_stream",
                   rb_nghttp3_connection_bind_control_stream, 1);
  rb_define_method(rb_cNghttp3Connection, "bind_qpack_streams",
                   rb_nghttp3_connection_bind_qpack_streams, 2);
  rb_define_method(rb_cNghttp3Connection, "close", rb_nghttp3_connection_close,
                   0);
  rb_define_method(rb_cNghttp3Connection, "closed?",
                   rb_nghttp3_connection_closed_p, 0);
  rb_define_method(rb_cNghttp3Connection, "server?",
                   rb_nghttp3_connection_server_p, 0);
  rb_define_method(rb_cNghttp3Connection, "client?",
                   rb_nghttp3_connection_client_p, 0);

  /* Stream operation methods */
  rb_define_method(rb_cNghttp3Connection, "read_stream",
                   rb_nghttp3_connection_read_stream, -1);
  rb_define_method(rb_cNghttp3Connection, "writev_stream",
                   rb_nghttp3_connection_writev_stream, 0);
  rb_define_method(rb_cNghttp3Connection, "add_write_offset",
                   rb_nghttp3_connection_add_write_offset, 2);
  rb_define_method(rb_cNghttp3Connection, "add_ack_offset",
                   rb_nghttp3_connection_add_ack_offset, 2);
  rb_define_method(rb_cNghttp3Connection, "block_stream",
                   rb_nghttp3_connection_block_stream, 1);
  rb_define_method(rb_cNghttp3Connection, "unblock_stream",
                   rb_nghttp3_connection_unblock_stream, 1);
  rb_define_method(rb_cNghttp3Connection, "stream_writable?",
                   rb_nghttp3_connection_stream_writable_p, 1);
  rb_define_method(rb_cNghttp3Connection, "close_stream",
                   rb_nghttp3_connection_close_stream, 2);
  rb_define_method(rb_cNghttp3Connection, "shutdown_stream_write",
                   rb_nghttp3_connection_shutdown_stream_write, 1);
  rb_define_method(rb_cNghttp3Connection, "resume_stream",
                   rb_nghttp3_connection_resume_stream, 1);

  /* HTTP operation methods */
  rb_define_method(rb_cNghttp3Connection, "submit_request",
                   rb_nghttp3_connection_submit_request, -1);
  rb_define_method(rb_cNghttp3Connection, "submit_response",
                   rb_nghttp3_connection_submit_response, -1);
  rb_define_method(rb_cNghttp3Connection, "submit_info",
                   rb_nghttp3_connection_submit_info, 2);
  rb_define_method(rb_cNghttp3Connection, "submit_trailers",
                   rb_nghttp3_connection_submit_trailers, 2);
  rb_define_method(rb_cNghttp3Connection, "submit_shutdown_notice",
                   rb_nghttp3_connection_submit_shutdown_notice, 0);
  rb_define_method(rb_cNghttp3Connection, "shutdown",
                   rb_nghttp3_connection_shutdown, 0);
  rb_define_method(rb_cNghttp3Connection, "set_stream_user_data",
                   rb_nghttp3_connection_set_stream_user_data, 2);
  rb_define_method(rb_cNghttp3Connection, "get_stream_user_data",
                   rb_nghttp3_connection_get_stream_user_data, 1);
}
