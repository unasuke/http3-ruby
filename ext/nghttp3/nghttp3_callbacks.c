#include "nghttp3.h"

VALUE rb_cNghttp3Callbacks;

typedef struct {
  VALUE on_acked_stream_data;
  VALUE on_stream_close;
  VALUE on_recv_data;
  VALUE on_deferred_consume;
  VALUE on_begin_headers;
  VALUE on_recv_header;
  VALUE on_end_headers;
  VALUE on_begin_trailers;
  VALUE on_recv_trailer;
  VALUE on_end_trailers;
  VALUE on_stop_sending;
  VALUE on_end_stream;
  VALUE on_reset_stream;
  VALUE on_shutdown;
  VALUE on_recv_settings;
} CallbacksObj;

static void callbacks_mark(void *ptr) {
  CallbacksObj *obj = (CallbacksObj *)ptr;
  rb_gc_mark(obj->on_acked_stream_data);
  rb_gc_mark(obj->on_stream_close);
  rb_gc_mark(obj->on_recv_data);
  rb_gc_mark(obj->on_deferred_consume);
  rb_gc_mark(obj->on_begin_headers);
  rb_gc_mark(obj->on_recv_header);
  rb_gc_mark(obj->on_end_headers);
  rb_gc_mark(obj->on_begin_trailers);
  rb_gc_mark(obj->on_recv_trailer);
  rb_gc_mark(obj->on_end_trailers);
  rb_gc_mark(obj->on_stop_sending);
  rb_gc_mark(obj->on_end_stream);
  rb_gc_mark(obj->on_reset_stream);
  rb_gc_mark(obj->on_shutdown);
  rb_gc_mark(obj->on_recv_settings);
}

static void callbacks_free(void *ptr) { xfree(ptr); }

static size_t callbacks_memsize(const void *ptr) {
  return sizeof(CallbacksObj);
}

const rb_data_type_t callbacks_data_type = {
    .wrap_struct_name = "nghttp3_callbacks_rb",
    .function =
        {
            .dmark = callbacks_mark,
            .dfree = callbacks_free,
            .dsize = callbacks_memsize,
        },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE callbacks_alloc(VALUE klass) {
  CallbacksObj *obj;
  VALUE self =
      TypedData_Make_Struct(klass, CallbacksObj, &callbacks_data_type, obj);
  obj->on_acked_stream_data = Qnil;
  obj->on_stream_close = Qnil;
  obj->on_recv_data = Qnil;
  obj->on_deferred_consume = Qnil;
  obj->on_begin_headers = Qnil;
  obj->on_recv_header = Qnil;
  obj->on_end_headers = Qnil;
  obj->on_begin_trailers = Qnil;
  obj->on_recv_trailer = Qnil;
  obj->on_end_trailers = Qnil;
  obj->on_stop_sending = Qnil;
  obj->on_end_stream = Qnil;
  obj->on_reset_stream = Qnil;
  obj->on_shutdown = Qnil;
  obj->on_recv_settings = Qnil;
  return self;
}

/*
 * call-seq:
 *   Callbacks.new -> Callbacks
 *
 * Creates a new Callbacks object for handling HTTP/3 events.
 */
static VALUE rb_nghttp3_callbacks_initialize(VALUE self) { return self; }

/* Callback setters - each takes a block and stores it */

/*
 * call-seq:
 *   callbacks.on_acked_stream_data { |stream_id, datalen| ... } -> self
 *
 * Sets the callback for acknowledged stream data.
 */
static VALUE rb_nghttp3_callbacks_on_acked_stream_data(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_acked_stream_data = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_stream_close { |stream_id, app_error_code| ... } -> self
 *
 * Sets the callback for stream close events.
 */
static VALUE rb_nghttp3_callbacks_on_stream_close(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_stream_close = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_recv_data { |stream_id, data| ... } -> self
 *
 * Sets the callback for receiving data.
 */
static VALUE rb_nghttp3_callbacks_on_recv_data(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_recv_data = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_deferred_consume { |stream_id, consumed| ... } -> self
 *
 * Sets the callback for deferred consume events.
 */
static VALUE rb_nghttp3_callbacks_on_deferred_consume(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_deferred_consume = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_begin_headers { |stream_id| ... } -> self
 *
 * Sets the callback for the start of headers.
 */
static VALUE rb_nghttp3_callbacks_on_begin_headers(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_begin_headers = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_recv_header { |stream_id, name, value, flags| ... } -> self
 *
 * Sets the callback for receiving headers.
 */
static VALUE rb_nghttp3_callbacks_on_recv_header(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_recv_header = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_end_headers { |stream_id, fin| ... } -> self
 *
 * Sets the callback for the end of headers.
 */
static VALUE rb_nghttp3_callbacks_on_end_headers(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_end_headers = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_begin_trailers { |stream_id| ... } -> self
 *
 * Sets the callback for the start of trailers.
 */
static VALUE rb_nghttp3_callbacks_on_begin_trailers(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_begin_trailers = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_recv_trailer { |stream_id, name, value, flags| ... } -> self
 *
 * Sets the callback for receiving trailers.
 */
static VALUE rb_nghttp3_callbacks_on_recv_trailer(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_recv_trailer = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_end_trailers { |stream_id, fin| ... } -> self
 *
 * Sets the callback for the end of trailers.
 */
static VALUE rb_nghttp3_callbacks_on_end_trailers(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_end_trailers = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_stop_sending { |stream_id, app_error_code| ... } -> self
 *
 * Sets the callback for stop sending events.
 */
static VALUE rb_nghttp3_callbacks_on_stop_sending(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_stop_sending = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_end_stream { |stream_id| ... } -> self
 *
 * Sets the callback for stream end events.
 */
static VALUE rb_nghttp3_callbacks_on_end_stream(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_end_stream = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_reset_stream { |stream_id, app_error_code| ... } -> self
 *
 * Sets the callback for stream reset events.
 */
static VALUE rb_nghttp3_callbacks_on_reset_stream(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_reset_stream = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_shutdown { |id| ... } -> self
 *
 * Sets the callback for shutdown events.
 */
static VALUE rb_nghttp3_callbacks_on_shutdown(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_shutdown = rb_block_proc();
  return self;
}

/*
 * call-seq:
 *   callbacks.on_recv_settings { |settings| ... } -> self
 *
 * Sets the callback for receiving SETTINGS frame.
 */
static VALUE rb_nghttp3_callbacks_on_recv_settings(VALUE self) {
  CallbacksObj *obj;
  TypedData_Get_Struct(self, CallbacksObj, &callbacks_data_type, obj);
  obj->on_recv_settings = rb_block_proc();
  return self;
}

/* C callback wrapper functions - called by nghttp3 */

static int nghttp3_rb_acked_stream_data_callback(nghttp3_conn *conn,
                                                 int64_t stream_id,
                                                 uint64_t datalen,
                                                 void *conn_user_data,
                                                 void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_acked_stream_data))
    return 0;

  VALUE args[2] = {LL2NUM(stream_id), ULL2NUM(datalen)};
  rb_proc_call(cb->on_acked_stream_data, rb_ary_new_from_values(2, args));

  return 0;
}

static int nghttp3_rb_stream_close_callback(nghttp3_conn *conn,
                                            int64_t stream_id,
                                            uint64_t app_error_code,
                                            void *conn_user_data,
                                            void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_stream_close))
    return 0;

  VALUE args[2] = {LL2NUM(stream_id), ULL2NUM(app_error_code)};
  rb_proc_call(cb->on_stream_close, rb_ary_new_from_values(2, args));

  return 0;
}

static int nghttp3_rb_recv_data_callback(nghttp3_conn *conn, int64_t stream_id,
                                         const uint8_t *data, size_t datalen,
                                         void *conn_user_data,
                                         void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_recv_data))
    return 0;

  VALUE rb_data = rb_str_new((const char *)data, datalen);
  VALUE args[2] = {LL2NUM(stream_id), rb_data};
  rb_proc_call(cb->on_recv_data, rb_ary_new_from_values(2, args));

  return 0;
}

static int nghttp3_rb_deferred_consume_callback(nghttp3_conn *conn,
                                                int64_t stream_id,
                                                size_t consumed,
                                                void *conn_user_data,
                                                void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_deferred_consume))
    return 0;

  VALUE args[2] = {LL2NUM(stream_id), SIZET2NUM(consumed)};
  rb_proc_call(cb->on_deferred_consume, rb_ary_new_from_values(2, args));

  return 0;
}

static int nghttp3_rb_begin_headers_callback(nghttp3_conn *conn,
                                             int64_t stream_id,
                                             void *conn_user_data,
                                             void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_begin_headers))
    return 0;

  VALUE args[1] = {LL2NUM(stream_id)};
  rb_proc_call(cb->on_begin_headers, rb_ary_new_from_values(1, args));

  return 0;
}

static int nghttp3_rb_recv_header_callback(nghttp3_conn *conn,
                                           int64_t stream_id, int32_t token,
                                           nghttp3_rcbuf *name,
                                           nghttp3_rcbuf *value, uint8_t flags,
                                           void *conn_user_data,
                                           void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_recv_header))
    return 0;

  nghttp3_vec name_vec = nghttp3_rcbuf_get_buf(name);
  nghttp3_vec value_vec = nghttp3_rcbuf_get_buf(value);

  VALUE rb_name = rb_str_new((const char *)name_vec.base, name_vec.len);
  VALUE rb_value = rb_str_new((const char *)value_vec.base, value_vec.len);

  VALUE args[4] = {LL2NUM(stream_id), rb_name, rb_value, UINT2NUM(flags)};
  rb_proc_call(cb->on_recv_header, rb_ary_new_from_values(4, args));

  return 0;
}

static int nghttp3_rb_end_headers_callback(nghttp3_conn *conn,
                                           int64_t stream_id, int fin,
                                           void *conn_user_data,
                                           void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_end_headers))
    return 0;

  VALUE args[2] = {LL2NUM(stream_id), fin ? Qtrue : Qfalse};
  rb_proc_call(cb->on_end_headers, rb_ary_new_from_values(2, args));

  return 0;
}

static int nghttp3_rb_begin_trailers_callback(nghttp3_conn *conn,
                                              int64_t stream_id,
                                              void *conn_user_data,
                                              void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_begin_trailers))
    return 0;

  VALUE args[1] = {LL2NUM(stream_id)};
  rb_proc_call(cb->on_begin_trailers, rb_ary_new_from_values(1, args));

  return 0;
}

static int nghttp3_rb_recv_trailer_callback(nghttp3_conn *conn,
                                            int64_t stream_id, int32_t token,
                                            nghttp3_rcbuf *name,
                                            nghttp3_rcbuf *value, uint8_t flags,
                                            void *conn_user_data,
                                            void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_recv_trailer))
    return 0;

  nghttp3_vec name_vec = nghttp3_rcbuf_get_buf(name);
  nghttp3_vec value_vec = nghttp3_rcbuf_get_buf(value);

  VALUE rb_name = rb_str_new((const char *)name_vec.base, name_vec.len);
  VALUE rb_value = rb_str_new((const char *)value_vec.base, value_vec.len);

  VALUE args[4] = {LL2NUM(stream_id), rb_name, rb_value, UINT2NUM(flags)};
  rb_proc_call(cb->on_recv_trailer, rb_ary_new_from_values(4, args));

  return 0;
}

static int nghttp3_rb_end_trailers_callback(nghttp3_conn *conn,
                                            int64_t stream_id, int fin,
                                            void *conn_user_data,
                                            void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_end_trailers))
    return 0;

  VALUE args[2] = {LL2NUM(stream_id), fin ? Qtrue : Qfalse};
  rb_proc_call(cb->on_end_trailers, rb_ary_new_from_values(2, args));

  return 0;
}

static int nghttp3_rb_stop_sending_callback(nghttp3_conn *conn,
                                            int64_t stream_id,
                                            uint64_t app_error_code,
                                            void *conn_user_data,
                                            void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_stop_sending))
    return 0;

  VALUE args[2] = {LL2NUM(stream_id), ULL2NUM(app_error_code)};
  rb_proc_call(cb->on_stop_sending, rb_ary_new_from_values(2, args));

  return 0;
}

static int nghttp3_rb_end_stream_callback(nghttp3_conn *conn, int64_t stream_id,
                                          void *conn_user_data,
                                          void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_end_stream))
    return 0;

  VALUE args[1] = {LL2NUM(stream_id)};
  rb_proc_call(cb->on_end_stream, rb_ary_new_from_values(1, args));

  return 0;
}

static int nghttp3_rb_reset_stream_callback(nghttp3_conn *conn,
                                            int64_t stream_id,
                                            uint64_t app_error_code,
                                            void *conn_user_data,
                                            void *stream_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_reset_stream))
    return 0;

  VALUE args[2] = {LL2NUM(stream_id), ULL2NUM(app_error_code)};
  rb_proc_call(cb->on_reset_stream, rb_ary_new_from_values(2, args));

  return 0;
}

static int nghttp3_rb_shutdown_callback(nghttp3_conn *conn, int64_t id,
                                        void *conn_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_shutdown))
    return 0;

  VALUE args[1] = {LL2NUM(id)};
  rb_proc_call(cb->on_shutdown, rb_ary_new_from_values(1, args));

  return 0;
}

static int nghttp3_rb_recv_settings_callback(nghttp3_conn *conn,
                                             const nghttp3_settings *settings,
                                             void *conn_user_data) {
  ConnectionObj *obj = conn_user_data;
  VALUE rb_callbacks = obj->callbacks;

  if (NIL_P(rb_callbacks))
    return 0;

  CallbacksObj *cb;
  TypedData_Get_Struct(rb_callbacks, CallbacksObj, &callbacks_data_type, cb);

  if (NIL_P(cb->on_recv_settings))
    return 0;

  /* Create a Ruby hash with settings values */
  VALUE rb_settings = rb_hash_new();
  rb_hash_aset(rb_settings, ID2SYM(rb_intern("max_field_section_size")),
               ULL2NUM(settings->max_field_section_size));
  rb_hash_aset(rb_settings, ID2SYM(rb_intern("qpack_max_dtable_capacity")),
               SIZET2NUM(settings->qpack_max_dtable_capacity));
  rb_hash_aset(rb_settings,
               ID2SYM(rb_intern("qpack_encoder_max_dtable_capacity")),
               SIZET2NUM(settings->qpack_encoder_max_dtable_capacity));
  rb_hash_aset(rb_settings, ID2SYM(rb_intern("qpack_blocked_streams")),
               SIZET2NUM(settings->qpack_blocked_streams));
  rb_hash_aset(rb_settings, ID2SYM(rb_intern("enable_connect_protocol")),
               settings->enable_connect_protocol ? Qtrue : Qfalse);
  rb_hash_aset(rb_settings, ID2SYM(rb_intern("h3_datagram")),
               settings->h3_datagram ? Qtrue : Qfalse);

  VALUE args[1] = {rb_settings};
  rb_proc_call(cb->on_recv_settings, rb_ary_new_from_values(1, args));

  return 0;
}

/*
 * Sets up the nghttp3_callbacks structure with our C wrapper functions.
 */
void nghttp3_rb_setup_callbacks(nghttp3_callbacks *callbacks) {
  callbacks->acked_stream_data = nghttp3_rb_acked_stream_data_callback;
  callbacks->stream_close = nghttp3_rb_stream_close_callback;
  callbacks->recv_data = nghttp3_rb_recv_data_callback;
  callbacks->deferred_consume = nghttp3_rb_deferred_consume_callback;
  callbacks->begin_headers = nghttp3_rb_begin_headers_callback;
  callbacks->recv_header = nghttp3_rb_recv_header_callback;
  callbacks->end_headers = nghttp3_rb_end_headers_callback;
  callbacks->begin_trailers = nghttp3_rb_begin_trailers_callback;
  callbacks->recv_trailer = nghttp3_rb_recv_trailer_callback;
  callbacks->end_trailers = nghttp3_rb_end_trailers_callback;
  callbacks->stop_sending = nghttp3_rb_stop_sending_callback;
  callbacks->end_stream = nghttp3_rb_end_stream_callback;
  callbacks->reset_stream = nghttp3_rb_reset_stream_callback;
  callbacks->shutdown = nghttp3_rb_shutdown_callback;
  callbacks->recv_settings = nghttp3_rb_recv_settings_callback;
}

void Init_nghttp3_callbacks(void) {
  rb_cNghttp3Callbacks =
      rb_define_class_under(rb_mNghttp3, "Callbacks", rb_cObject);

  rb_define_alloc_func(rb_cNghttp3Callbacks, callbacks_alloc);

  rb_define_method(rb_cNghttp3Callbacks, "initialize",
                   rb_nghttp3_callbacks_initialize, 0);

  /* Callback setters */
  rb_define_method(rb_cNghttp3Callbacks, "on_acked_stream_data",
                   rb_nghttp3_callbacks_on_acked_stream_data, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_stream_close",
                   rb_nghttp3_callbacks_on_stream_close, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_recv_data",
                   rb_nghttp3_callbacks_on_recv_data, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_deferred_consume",
                   rb_nghttp3_callbacks_on_deferred_consume, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_begin_headers",
                   rb_nghttp3_callbacks_on_begin_headers, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_recv_header",
                   rb_nghttp3_callbacks_on_recv_header, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_end_headers",
                   rb_nghttp3_callbacks_on_end_headers, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_begin_trailers",
                   rb_nghttp3_callbacks_on_begin_trailers, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_recv_trailer",
                   rb_nghttp3_callbacks_on_recv_trailer, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_end_trailers",
                   rb_nghttp3_callbacks_on_end_trailers, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_stop_sending",
                   rb_nghttp3_callbacks_on_stop_sending, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_end_stream",
                   rb_nghttp3_callbacks_on_end_stream, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_reset_stream",
                   rb_nghttp3_callbacks_on_reset_stream, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_shutdown",
                   rb_nghttp3_callbacks_on_shutdown, 0);
  rb_define_method(rb_cNghttp3Callbacks, "on_recv_settings",
                   rb_nghttp3_callbacks_on_recv_settings, 0);
}
