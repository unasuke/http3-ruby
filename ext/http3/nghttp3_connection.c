#include "nghttp3.h"

#include <time.h>

VALUE rb_cNghttp3Connection;

/* The body Strings handed to nghttp3 for one stream and not yet wholly
 * acknowledged, oldest first. acked counts the bytes of the first of them
 * the peer has acknowledged so far. */
typedef struct {
  VALUE strings;
  uint64_t acked;
} PendingStream;

static int pending_mark_i(st_data_t key, st_data_t value, st_data_t arg) {
  const PendingStream *ps = (const PendingStream *)value;
  /* rb_gc_mark, not rb_gc_mark_movable: nghttp3 holds pointers into these
   * Strings, so neither they nor (for an embedded String) their bytes may
   * move. */
  rb_gc_mark(ps->strings);
  if (!NIL_P(ps->strings)) {
    for (long i = 0; i < RARRAY_LEN(ps->strings); i++) {
      rb_gc_mark(RARRAY_AREF(ps->strings, i));
    }
  }
  return ST_CONTINUE;
}

static int pending_free_i(st_data_t key, st_data_t value, st_data_t arg) {
  xfree((void *)value);
  return ST_CONTINUE;
}

static void pending_clear(ConnectionObj *obj) {
  if (obj->pending == NULL) {
    return;
  }
  st_foreach(obj->pending, pending_free_i, 0);
  st_clear(obj->pending);
}

static void connection_mark(void *ptr) {
  ConnectionObj *obj = (ConnectionObj *)ptr;
  rb_gc_mark(obj->settings);
  rb_gc_mark(obj->callbacks);
  rb_gc_mark(obj->stream_data_readers);
  rb_gc_mark(obj->stream_user_data);
  rb_gc_mark(obj->pending_exc);
  if (obj->pending != NULL) {
    st_foreach(obj->pending, pending_mark_i, 0);
  }
}

static void connection_free(void *ptr) {
  ConnectionObj *obj = (ConnectionObj *)ptr;
  if (obj->conn != NULL && !obj->is_closed) {
    nghttp3_conn_del(obj->conn);
    obj->conn = NULL;
  }
  if (obj->pending != NULL) {
    pending_clear(obj);
    st_free_table(obj->pending);
  }
  xfree(ptr);
}

static size_t connection_memsize(const void *ptr) {
  const ConnectionObj *obj = (const ConnectionObj *)ptr;
  return sizeof(ConnectionObj) +
         (obj->pending != NULL ? st_memsize(obj->pending) : 0);
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
  obj->stream_data_readers = Qnil;
  obj->stream_user_data = Qnil;
  obj->pending_exc = Qnil;
  obj->is_closed = 0;
  obj->is_server = 0;
  obj->pending = st_init_numtable();
  obj->stream_data_readers = rb_hash_new();
  obj->stream_user_data = rb_hash_new();
  return self;
}

int nghttp3_rb_protect(ConnectionObj *obj, VALUE (*body)(VALUE), VALUE arg) {
  int state = 0;
  rb_protect(body, arg, &state);
  if (state == 0) {
    return 0;
  }
  if (NIL_P(obj->pending_exc)) {
    obj->pending_exc = rb_errinfo();
  }
  rb_set_errinfo(Qnil);
  return NGHTTP3_ERR_CALLBACK_FAILURE;
}

/* Raise the exception a callback left in obj->pending_exc, if any. Called
 * right after nghttp3 returns, before its return value is looked at: the
 * NGHTTP3_ERR_CALLBACK_FAILURE it reports is the result of that
 * exception. */
static void connection_raise_pending(ConnectionObj *obj) {
  if (NIL_P(obj->pending_exc)) {
    return;
  }
  VALUE exc = obj->pending_exc;
  obj->pending_exc = Qnil;
  rb_exc_raise(exc);
}

static PendingStream *pending_lookup(ConnectionObj *obj, int64_t stream_id) {
  st_data_t value;
  if (!st_lookup(obj->pending, (st_data_t)stream_id, &value)) {
    return NULL;
  }
  return (PendingStream *)value;
}

/* Keep str, which nghttp3 is about to read from, until the peer has
 * acknowledged all of it. */
static void pending_push(ConnectionObj *obj, int64_t stream_id, VALUE str) {
  PendingStream *ps = pending_lookup(obj, stream_id);
  if (ps == NULL) {
    ps = ALLOC(PendingStream);
    ps->strings = Qnil;
    ps->acked = 0;
    st_insert(obj->pending, (st_data_t)stream_id, (st_data_t)ps);
    ps->strings = rb_ary_new();
  }
  rb_ary_push(ps->strings, str);
}

/* Drop the Strings at the front that the peer has now acknowledged to their
 * end, as quic-ruby's quic_acked_stream_data_offset_cb does. A String
 * acknowledged only in part stays. */
void nghttp3_rb_conn_acked(ConnectionObj *obj, int64_t stream_id,
                           uint64_t datalen) {
  PendingStream *ps = pending_lookup(obj, stream_id);
  if (ps == NULL) {
    return;
  }
  ps->acked += datalen;
  while (RARRAY_LEN(ps->strings) > 0) {
    uint64_t len = (uint64_t)RSTRING_LEN(RARRAY_AREF(ps->strings, 0));
    if (ps->acked < len) {
      break;
    }
    ps->acked -= len;
    rb_ary_shift(ps->strings);
  }
}

void nghttp3_rb_conn_stream_closed(ConnectionObj *obj, int64_t stream_id) {
  st_data_t key = (st_data_t)stream_id;
  st_data_t value;
  if (st_delete(obj->pending, &key, &value)) {
    xfree((void *)value);
  }
  rb_hash_delete(obj->stream_data_readers, LL2NUM(stream_id));
}

/* Prepare the nghttp3_callbacks for a new connection. A Callbacks object is
 * checked here, so that the C callbacks can take it as one. */
static void connection_setup_callbacks(ConnectionObj *obj, VALUE rb_callbacks,
                                       nghttp3_callbacks *callbacks) {
  memset(callbacks, 0, sizeof(*callbacks));
  if (!NIL_P(rb_callbacks)) {
    rb_check_typeddata(rb_callbacks, &callbacks_data_type);
    obj->callbacks = rb_callbacks;
  }
  nghttp3_rb_setup_callbacks(callbacks);
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
    /* nghttp3 reads none of the body Strings any more. */
    pending_clear(obj);
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

static nghttp3_tstamp monotonic_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (nghttp3_tstamp)ts.tv_sec * 1000000000ULL + (nghttp3_tstamp)ts.tv_nsec;
}

struct read_stream_args {
  ConnectionObj *obj;
  int64_t stream_id;
  VALUE data;
  int fin;
  nghttp3_tstamp ts;
};

static VALUE read_stream_body(VALUE arg) {
  struct read_stream_args *a = (struct read_stream_args *)arg;
  nghttp3_ssize rv = nghttp3_conn_read_stream2(
      a->obj->conn, a->stream_id, (const uint8_t *)RSTRING_PTR(a->data),
      (size_t)RSTRING_LEN(a->data), a->fin, a->ts);
  connection_raise_pending(a->obj);
  if (rv < 0) {
    nghttp3_rb_raise((int)rv, "Failed to read stream");
  }
  return LL2NUM(rv);
}

static VALUE read_stream_unlock(VALUE arg) {
  rb_str_unlocktmp(((struct read_stream_args *)arg)->data);
  return Qnil;
}

/*
 * call-seq:
 *   connection.read_stream(stream_id, data, fin: false, ts: nil) -> Integer
 *
 * Reads data on a stream. This should be called when data is received from
 * the QUIC layer. Returns the number of bytes consumed (for flow control).
 * ts is the current time in nanoseconds on any monotonic clock, used for
 * nghttp3's rate limits; it defaults to CLOCK_MONOTONIC. An exception
 * raised by a callback comes out of here.
 */
static VALUE rb_nghttp3_connection_read_stream(int argc, VALUE *argv,
                                               VALUE self) {
  VALUE rb_stream_id, rb_data, rb_opts;
  VALUE rb_fin = Qfalse;
  VALUE rb_ts = Qnil;
  ConnectionObj *obj;

  rb_scan_args(argc, argv, "2:", &rb_stream_id, &rb_data, &rb_opts);

  if (!NIL_P(rb_opts)) {
    VALUE rb_fin_val = rb_hash_aref(rb_opts, ID2SYM(rb_intern("fin")));
    if (!NIL_P(rb_fin_val)) {
      rb_fin = rb_fin_val;
    }
    rb_ts = rb_hash_aref(rb_opts, ID2SYM(rb_intern("ts")));
  }

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  Check_Type(rb_data, T_STRING);

  struct read_stream_args args;
  args.obj = obj;
  args.stream_id = NUM2LL(rb_stream_id);
  args.data = rb_data;
  args.fin = RTEST(rb_fin) ? 1 : 0;
  args.ts = NIL_P(rb_ts) ? monotonic_now() : (nghttp3_tstamp)NUM2ULL(rb_ts);

  /* Callbacks run Ruby code, which must not change data under nghttp3. */
  rb_str_locktmp(rb_data);
  return rb_ensure(read_stream_body, (VALUE)&args, read_stream_unlock,
                   (VALUE)&args);
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
  connection_raise_pending(obj);

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
  connection_raise_pending(obj);

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
  connection_raise_pending(obj);

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
  connection_raise_pending(obj);

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
  connection_raise_pending(obj);

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
  connection_raise_pending(obj);

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
  connection_raise_pending(obj);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to resume stream");
  }

  return self;
}

struct read_data_args {
  ConnectionObj *obj;
  int64_t stream_id;
  nghttp3_vec *vec;
  uint32_t *pflags;
  nghttp3_ssize result;
};

static VALUE read_data_body(VALUE arg) {
  struct read_data_args *a = (struct read_data_args *)arg;
  ConnectionObj *obj = a->obj;
  VALUE rb_stream_id = LL2NUM(a->stream_id);
  VALUE reader = rb_hash_aref(obj->stream_data_readers, rb_stream_id);
  VALUE data;

  a->result = 0;
  if (NIL_P(reader)) {
    *a->pflags |= NGHTTP3_DATA_FLAG_EOF;
    return Qnil;
  }

  if (RB_TYPE_P(reader, T_STRING)) {
    /* The whole body at once: already a frozen copy, made by submit_*. */
    data = reader;
    rb_hash_delete(obj->stream_data_readers, rb_stream_id);
    *a->pflags |= NGHTTP3_DATA_FLAG_EOF;
  } else {
    /* Proc: call it to get data */
    VALUE result = rb_funcall(reader, rb_intern("call"), 1, rb_stream_id);

    if (NIL_P(result)) {
      *a->pflags |= NGHTTP3_DATA_FLAG_EOF;
      rb_hash_delete(obj->stream_data_readers, rb_stream_id);
      return Qnil;
    }

    if (SYMBOL_P(result) && SYM2ID(result) == rb_intern("wouldblock")) {
      a->result = NGHTTP3_ERR_WOULDBLOCK;
      return Qnil;
    }

    StringValue(result);
    data = rb_str_new_frozen(result);
  }

  /* nghttp3 reads from data until the peer acknowledges it. */
  pending_push(obj, a->stream_id, data);
  a->vec[0].base = (uint8_t *)RSTRING_PTR(data);
  a->vec[0].len = (size_t)RSTRING_LEN(data);
  a->result = 1;
  return Qnil;
}

/*
 * Callback function for providing body data to nghttp3. The Ruby side runs
 * under rb_protect: an exception waits in pending_exc for writev_stream.
 */
static nghttp3_ssize read_data_callback(nghttp3_conn *conn, int64_t stream_id,
                                        nghttp3_vec *vec, size_t veccnt,
                                        uint32_t *pflags, void *conn_user_data,
                                        void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  struct read_data_args args = {obj, stream_id, vec, pflags, 0};

  if (nghttp3_rb_protect(obj, read_data_body, (VALUE)&args) != 0) {
    return NGHTTP3_ERR_CALLBACK_FAILURE;
  }
  return args.result;
}

/* Static data_reader structure for use in submit functions */
static const nghttp3_data_reader data_reader = {.read_data =
                                                    read_data_callback};

/* The body of a submit_request or submit_response: a frozen copy of body:,
 * so that the application cannot change the bytes nghttp3 will read, or the
 * block, or Qnil for none. StringValue may run Ruby code (to_str). */
static VALUE submit_body_reader(VALUE rb_opts) {
  VALUE rb_body = Qnil;
  if (!NIL_P(rb_opts)) {
    rb_body = rb_hash_aref(rb_opts, ID2SYM(rb_intern("body")));
  }
  if (!NIL_P(rb_body)) {
    StringValue(rb_body);
    return rb_str_new_frozen(rb_body);
  }
  return rb_block_given_p() ? rb_block_proc() : Qnil;
}

/*
 * The submit_* methods take the pointers into the header Strings only once
 * nothing more can run Ruby code or allocate before nghttp3 copies them: Ruby
 * code could change or drop the Strings, and an allocation could start a GC
 * that moves them. So they first convert their arguments, which may call
 * to_int and to_str, then check the connection, which that Ruby code may
 * have closed, then allocate (the header array, and the reader entry), and
 * only then fill the array and call nghttp3.
 */

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
  VALUE rb_stream_id, rb_headers, rb_opts, reader;
  ConnectionObj *obj;
  int64_t stream_id;
  nghttp3_nv *nva;
  VALUE nva_buf;
  long nvlen, bad;
  int rv;

  rb_scan_args(argc, argv, "2:", &rb_stream_id, &rb_headers, &rb_opts);

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->is_server) {
    rb_raise(rb_eNghttp3InvalidStateError,
             "submit_request can only be called on client connections");
  }

  stream_id = NUM2LL(rb_stream_id);
  Check_Type(rb_headers, T_ARRAY);
  reader = submit_body_reader(rb_opts);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  /* On the heap: a Ruby thread's machine stack is too small for a long
   * list. */
  nvlen = RARRAY_LEN(rb_headers);
  nva = ALLOCV_N(nghttp3_nv, nva_buf, nvlen);
  if (!NIL_P(reader)) {
    rb_hash_aset(obj->stream_data_readers, LL2NUM(stream_id), reader);
  }

  bad = nghttp3_rb_nva_fill(rb_headers, nva, nvlen);
  if (bad >= 0) {
    ALLOCV_END(nva_buf);
    if (!NIL_P(reader)) {
      rb_hash_delete(obj->stream_data_readers, LL2NUM(stream_id));
    }
    nghttp3_rb_raise_bad_nv(bad);
  }
  rv = nghttp3_conn_submit_request(obj->conn, stream_id, nva, (size_t)nvlen,
                                   NIL_P(reader) ? NULL : &data_reader, NULL);
  ALLOCV_END(nva_buf);
  RB_GC_GUARD(rb_headers);
  connection_raise_pending(obj);

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
  VALUE rb_stream_id, rb_headers, rb_opts, reader;
  ConnectionObj *obj;
  int64_t stream_id;
  nghttp3_nv *nva;
  VALUE nva_buf;
  long nvlen, bad;
  int rv;

  rb_scan_args(argc, argv, "2:", &rb_stream_id, &rb_headers, &rb_opts);

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (!obj->is_server) {
    rb_raise(rb_eNghttp3InvalidStateError,
             "submit_response can only be called on server connections");
  }

  stream_id = NUM2LL(rb_stream_id);
  Check_Type(rb_headers, T_ARRAY);
  reader = submit_body_reader(rb_opts);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  nvlen = RARRAY_LEN(rb_headers);
  nva = ALLOCV_N(nghttp3_nv, nva_buf, nvlen);
  if (!NIL_P(reader)) {
    rb_hash_aset(obj->stream_data_readers, LL2NUM(stream_id), reader);
  }

  bad = nghttp3_rb_nva_fill(rb_headers, nva, nvlen);
  if (bad >= 0) {
    ALLOCV_END(nva_buf);
    if (!NIL_P(reader)) {
      rb_hash_delete(obj->stream_data_readers, LL2NUM(stream_id));
    }
    nghttp3_rb_raise_bad_nv(bad);
  }
  rv = nghttp3_conn_submit_response(obj->conn, stream_id, nva, (size_t)nvlen,
                                    NIL_P(reader) ? NULL : &data_reader);
  ALLOCV_END(nva_buf);
  RB_GC_GUARD(rb_headers);
  connection_raise_pending(obj);

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
  VALUE nva_buf;
  long nvlen, bad;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  stream_id = NUM2LL(rb_stream_id);
  Check_Type(rb_headers, T_ARRAY);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  nvlen = RARRAY_LEN(rb_headers);
  nva = ALLOCV_N(nghttp3_nv, nva_buf, nvlen);

  bad = nghttp3_rb_nva_fill(rb_headers, nva, nvlen);
  if (bad >= 0) {
    ALLOCV_END(nva_buf);
    nghttp3_rb_raise_bad_nv(bad);
  }
  rv = nghttp3_conn_submit_info(obj->conn, stream_id, nva, (size_t)nvlen);
  ALLOCV_END(nva_buf);
  RB_GC_GUARD(rb_headers);
  connection_raise_pending(obj);

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
  VALUE nva_buf;
  long nvlen, bad;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  stream_id = NUM2LL(rb_stream_id);
  Check_Type(rb_trailers, T_ARRAY);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  nvlen = RARRAY_LEN(rb_trailers);
  nva = ALLOCV_N(nghttp3_nv, nva_buf, nvlen);

  bad = nghttp3_rb_nva_fill(rb_trailers, nva, nvlen);
  if (bad >= 0) {
    ALLOCV_END(nva_buf);
    nghttp3_rb_raise_bad_nv(bad);
  }
  rv = nghttp3_conn_submit_trailers(obj->conn, stream_id, nva, (size_t)nvlen);
  ALLOCV_END(nva_buf);
  RB_GC_GUARD(rb_trailers);
  connection_raise_pending(obj);

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
  connection_raise_pending(obj);

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
  connection_raise_pending(obj);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to shutdown connection");
  }

  return self;
}

/*
 * call-seq:
 *   connection.shutdown_stream_read(stream_id) -> self
 *
 * Tells the connection that no more data will be read on the stream, so
 * that QPACK stops waiting on it.
 */
static VALUE rb_nghttp3_connection_shutdown_stream_read(VALUE self,
                                                        VALUE rb_stream_id) {
  ConnectionObj *obj;
  int rv;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  rv = nghttp3_conn_shutdown_stream_read(obj->conn, NUM2LL(rb_stream_id));
  connection_raise_pending(obj);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to shutdown stream read");
  }

  return self;
}

/*
 * call-seq:
 *   connection.set_max_client_streams_bidi(max_streams) -> self
 *
 * Tells a server connection the cumulative number of bidirectional streams
 * the client may open, as QUIC's MAX_STREAMS allows. nghttp3 uses it for
 * graceful shutdown.
 */
static VALUE
rb_nghttp3_connection_set_max_client_streams_bidi(VALUE self,
                                                  VALUE rb_max_streams) {
  ConnectionObj *obj;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  if (obj->conn == NULL || obj->is_closed) {
    rb_raise(rb_eNghttp3InvalidStateError, "Connection is closed");
  }

  nghttp3_conn_set_max_client_streams_bidi(obj->conn, NUM2ULL(rb_max_streams));

  return self;
}

/*
 * call-seq:
 *   connection.pending_data(stream_id) -> Array
 *
 * The body Strings handed to nghttp3 on the stream that the peer has not
 * acknowledged in full yet, oldest first. A copy, for inspection.
 */
static VALUE rb_nghttp3_connection_pending_data(VALUE self,
                                                VALUE rb_stream_id) {
  ConnectionObj *obj;

  TypedData_Get_Struct(self, ConnectionObj, &connection_data_type, obj);

  PendingStream *ps = pending_lookup(obj, NUM2LL(rb_stream_id));
  return ps == NULL ? rb_ary_new() : rb_ary_dup(ps->strings);
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
  rb_define_method(rb_cNghttp3Connection, "shutdown_stream_read",
                   rb_nghttp3_connection_shutdown_stream_read, 1);
  rb_define_method(rb_cNghttp3Connection, "set_max_client_streams_bidi",
                   rb_nghttp3_connection_set_max_client_streams_bidi, 1);
  rb_define_method(rb_cNghttp3Connection, "pending_data",
                   rb_nghttp3_connection_pending_data, 1);

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
