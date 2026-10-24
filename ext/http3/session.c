#include "nghttp3.h"

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <unistd.h>

/*
 * HTTP3::Session, the C part: the glue between the quic gem's stream handler
 * (quic/ext.h) and an nghttp3 server connection. quic calls the handler
 * functions below from inside QUIC::Connection#read_pkt / #write_pkt; they
 * feed nghttp3, whose callbacks hand the parts of each request to the Ruby
 * part (lib/http3/session.rb) and take response bodies from what Ruby
 * queued with #push_chunk or #attach_file.
 *
 * Neither the handler functions nor the nghttp3 callbacks may raise. Ruby is
 * only called under rb_protect, and an exception waits in pending_exc for
 * #take_error. Memory a callback allocates is malloc()ed, not xmalloc()ed,
 * since ruby_xmalloc raises NoMemoryError on failure.
 */

/* How much of a file body read_data reads at a time. */
#define H3_FILE_CHUNK_SIZE (16 * 1024)

VALUE rb_cHTTP3Session;

static ID id_on_begin_headers, id_on_header, id_on_end_headers, id_on_data,
    id_on_end_stream, id_on_fields_too_large, id_on_reset;

/* What h3_session.field_sizes holds for a request whose header section has
 * gone over max_field_section_size. */
#define H3_FIELD_SECTION_OVER UINT64_MAX

/* The size RFC 9114 section 4.2.2 counts a field at: its name and value
 * plus 32 bytes. */
#define H3_FIELD_OVERHEAD 32

/* The largest value a QUIC variable-length integer, such as a SETTINGS
 * value, can hold. */
#define H3_VARINT_MAX ((1ULL << 62) - 1)

_Static_assert(sizeof(quic_ext_vec) == sizeof(nghttp3_vec),
               "quic_ext_vec must have the layout of nghttp3_vec");
_Static_assert(offsetof(quic_ext_vec, base) == offsetof(nghttp3_vec, base),
               "quic_ext_vec.base must line up with nghttp3_vec.base");
_Static_assert(offsetof(quic_ext_vec, len) == offsetof(nghttp3_vec, len),
               "quic_ext_vec.len must line up with nghttp3_vec.len");

/* A piece of a response body handed to nghttp3, kept until the peer has
 * acknowledged it. str is the frozen String it points into, pinned by dmark;
 * for a piece read from a file, str is Qnil and base is malloc()ed. */
typedef struct {
  const uint8_t *base;
  size_t len;
  VALUE str;
} h3_chunk;

/* The body of one response. */
typedef struct {
  int64_t id;
  h3_chunk *chunks; /* in the order queued; acknowledged ones leave the front */
  size_t nchunks, cap;
  size_t handed;    /* how many of chunks read_data has handed to nghttp3 */
  uint64_t unsent;  /* bytes queued but not handed to nghttp3 yet */
  uint64_t acked;   /* bytes the peer has acknowledged */
  uint64_t shifted; /* bytes of the chunks already dropped */
  int fd;           /* a file body (#attach_file) not read in full yet, or -1 */
  off_t file_off, file_end;
  bool eof;     /* nothing follows the queued chunks */
  bool blocked; /* read_data returned NGHTTP3_ERR_WOULDBLOCK */
} h3_stream;

typedef struct {
  VALUE self;      /* the object wrapping this struct; dcompact follows it */
  VALUE quic_conn; /* the QUIC::Connection::Server */
  quic_ext_conn *qc;
  nghttp3_conn *h3;  /* made on handshake_completed */
  st_table *streams; /* stream_id => h3_stream * */
  VALUE pending_exc; /* an exception the Ruby part raised in a callback */
  VALUE closed_ids;  /* ids of the streams nghttp3 closed, for #take_closed */
  /* The largest header section a request may have. nghttp3 only advertises
   * the limit in SETTINGS; it is enforced here. */
  uint64_t max_field_section_size;
  /* stream_id => size of the header section received so far, while the
   * headers of that request come in */
  st_table *field_sizes;
} h3_session;

/* Streams */

static void h3_chunk_release(h3_chunk *chunk) {
  if (NIL_P(chunk->str)) {
    free((void *)chunk->base);
  }
}

static void h3_stream_free(h3_stream *st) {
  for (size_t i = 0; i < st->nchunks; i++) {
    h3_chunk_release(&st->chunks[i]);
  }
  free(st->chunks);
  if (st->fd >= 0) {
    close(st->fd);
  }
  xfree(st);
}

static h3_stream *h3_stream_find(h3_session *s, int64_t id) {
  st_data_t value;
  return st_lookup(s->streams, (st_data_t)id, &value) ? (h3_stream *)value
                                                      : NULL;
}

/* Queue a chunk. Returns -1 when the list cannot grow. */
static int h3_stream_push(h3_stream *st, const uint8_t *base, size_t len,
                          VALUE str) {
  if (st->nchunks == st->cap) {
    size_t cap = st->cap ? st->cap * 2 : 8;
    h3_chunk *chunks = realloc(st->chunks, cap * sizeof(*chunks));
    if (chunks == NULL) {
      return -1;
    }
    st->chunks = chunks;
    st->cap = cap;
  }
  st->chunks[st->nchunks++] = (h3_chunk){base, len, str};
  st->unsent += len;
  return 0;
}

/* The whole file body has been read: let go of its descriptor now rather
 * than when the stream closes, which waits for the peer to acknowledge
 * every byte. */
static void h3_stream_end_file(h3_stream *st) {
  close(st->fd);
  st->fd = -1;
  st->eof = true;
}

/* Drop the chunks at the front the peer has acknowledged to their end. A
 * chunk acknowledged only in part stays. */
static void h3_stream_acked(h3_stream *st, uint64_t n) {
  size_t drop = 0;
  st->acked += n;
  while (drop < st->handed && st->shifted + st->chunks[drop].len <= st->acked) {
    st->shifted += st->chunks[drop].len;
    h3_chunk_release(&st->chunks[drop]);
    drop++;
  }
  if (drop == 0) {
    return;
  }
  memmove(st->chunks, st->chunks + drop,
          (st->nchunks - drop) * sizeof(*st->chunks));
  st->nchunks -= drop;
  st->handed -= drop;
}

/* Calling the Ruby part */

static int h3_protect(h3_session *s, VALUE (*body)(VALUE), VALUE arg) {
  int state = 0;
  rb_protect(body, arg, &state);
  if (state == 0) {
    return 0;
  }
  if (NIL_P(s->pending_exc)) {
    s->pending_exc = rb_errinfo();
  }
  rb_set_errinfo(Qnil);
  return NGHTTP3_ERR_CALLBACK_FAILURE;
}

typedef struct {
  h3_session *s;
  ID mid;
  int64_t id;
  int nbytes;
  nghttp3_vec bytes[2];
} h3_call;

static VALUE h3_call_body(VALUE arg) {
  const h3_call *call = (const h3_call *)arg;
  VALUE argv[3];
  argv[0] = LL2NUM(call->id);
  for (int i = 0; i < call->nbytes; i++) {
    argv[1 + i] =
        rb_str_new((const char *)call->bytes[i].base, call->bytes[i].len);
  }
  rb_funcallv(call->s->self, call->mid, 1 + call->nbytes, argv);
  return Qnil;
}

/* self.mid(id, *bytes as Strings) under rb_protect. */
static int h3_call_ruby(h3_session *s, ID mid, int64_t id, int nbytes,
                        const nghttp3_vec *bytes) {
  h3_call call = {s, mid, id, nbytes, {{0}}};
  for (int i = 0; i < nbytes; i++) {
    call.bytes[i] = bytes[i];
  }
  return h3_protect(s, h3_call_body, (VALUE)&call);
}

typedef struct {
  h3_session *s;
  int64_t id;
} h3_closed_arg;

static VALUE h3_closed_body(VALUE arg) {
  const h3_closed_arg *a = (const h3_closed_arg *)arg;
  st_data_t key = (st_data_t)a->id;
  st_delete(a->s->field_sizes, &key, NULL);
  rb_ary_push(a->s->closed_ids, LL2NUM(a->id));
  return Qnil;
}

/* Header sections. The bookkeeping in field_sizes may allocate, so it runs
 * under rb_protect together with the call into Ruby. */

typedef struct {
  h3_session *s;
  int64_t id;
  nghttp3_vec name, value;
} h3_field_arg;

static VALUE h3_begin_headers_body(VALUE arg) {
  const h3_field_arg *a = (const h3_field_arg *)arg;
  st_insert(a->s->field_sizes, (st_data_t)a->id, 0);
  rb_funcall(a->s->self, id_on_begin_headers, 1, LL2NUM(a->id));
  return Qnil;
}

/* Pass the field on, unless the section has grown past
 * max_field_section_size: then tell Ruby once, so that it can answer 431,
 * and drop that field and every later one. */
static VALUE h3_recv_header_body(VALUE arg) {
  const h3_field_arg *a = (const h3_field_arg *)arg;
  h3_session *s = a->s;
  st_data_t size = 0;
  st_lookup(s->field_sizes, (st_data_t)a->id, &size);
  if ((uint64_t)size == H3_FIELD_SECTION_OVER) {
    return Qnil;
  }
  uint64_t total =
      (uint64_t)size + a->name.len + a->value.len + H3_FIELD_OVERHEAD;
  if (total > s->max_field_section_size) {
    st_insert(s->field_sizes, (st_data_t)a->id,
              (st_data_t)H3_FIELD_SECTION_OVER);
    rb_funcall(s->self, id_on_fields_too_large, 1, LL2NUM(a->id));
    return Qnil;
  }
  st_insert(s->field_sizes, (st_data_t)a->id, (st_data_t)total);
  rb_funcall(s->self, id_on_header, 3, LL2NUM(a->id),
             rb_str_new((const char *)a->name.base, a->name.len),
             rb_str_new((const char *)a->value.base, a->value.len));
  return Qnil;
}

static VALUE h3_end_headers_body(VALUE arg) {
  const h3_field_arg *a = (const h3_field_arg *)arg;
  st_data_t key = (st_data_t)a->id;
  st_delete(a->s->field_sizes, &key, NULL);
  rb_funcall(a->s->self, id_on_end_headers, 1, LL2NUM(a->id));
  return Qnil;
}

/* nghttp3 callbacks (nghttp3 -> glue) */

static int h3_acked_stream_data_cb(nghttp3_conn *conn, int64_t id,
                                   uint64_t datalen, void *user_data,
                                   void *stream_user_data) {
  h3_stream *st = h3_stream_find(user_data, id);
  if (st != NULL) {
    h3_stream_acked(st, datalen);
  }
  return 0;
}

static int h3_stream_close_cb(nghttp3_conn *conn, int64_t id,
                              uint64_t app_error_code, void *user_data,
                              void *stream_user_data) {
  h3_session *s = user_data;
  st_data_t key = (st_data_t)id;
  st_data_t value;
  if (st_delete(s->streams, &key, &value)) {
    h3_stream_free((h3_stream *)value);
  }
  h3_closed_arg arg = {s, id};
  return h3_protect(s, h3_closed_body, (VALUE)&arg);
}

/* The body goes to Ruby, which takes all of it, so the peer gets the flow
 * control credit back at once. */
static int h3_recv_data_cb(nghttp3_conn *conn, int64_t id, const uint8_t *data,
                           size_t datalen, void *user_data,
                           void *stream_user_data) {
  h3_session *s = user_data;
  nghttp3_vec bytes = {(uint8_t *)data, datalen};
  int rv = h3_call_ruby(s, id_on_data, id, 1, &bytes);
  if (rv != 0) {
    return rv;
  }
  return http3_quic_api->consume(s->qc, id, datalen) == 0
             ? 0
             : NGHTTP3_ERR_CALLBACK_FAILURE;
}

static int h3_deferred_consume_cb(nghttp3_conn *conn, int64_t id,
                                  size_t consumed, void *user_data,
                                  void *stream_user_data) {
  h3_session *s = user_data;
  return http3_quic_api->consume(s->qc, id, consumed) == 0
             ? 0
             : NGHTTP3_ERR_CALLBACK_FAILURE;
}

static int h3_begin_headers_cb(nghttp3_conn *conn, int64_t id, void *user_data,
                               void *stream_user_data) {
  h3_field_arg arg = {user_data, id};
  return h3_protect(user_data, h3_begin_headers_body, (VALUE)&arg);
}

static int h3_recv_header_cb(nghttp3_conn *conn, int64_t id, int32_t token,
                             nghttp3_rcbuf *name, nghttp3_rcbuf *value,
                             uint8_t flags, void *user_data,
                             void *stream_user_data) {
  h3_field_arg arg = {user_data, id, nghttp3_rcbuf_get_buf(name),
                      nghttp3_rcbuf_get_buf(value)};
  return h3_protect(user_data, h3_recv_header_body, (VALUE)&arg);
}

static int h3_end_headers_cb(nghttp3_conn *conn, int64_t id, int fin,
                             void *user_data, void *stream_user_data) {
  h3_field_arg arg = {user_data, id};
  return h3_protect(user_data, h3_end_headers_body, (VALUE)&arg);
}

static int h3_end_stream_cb(nghttp3_conn *conn, int64_t id, void *user_data,
                            void *stream_user_data) {
  return h3_call_ruby(user_data, id_on_end_stream, id, 0, NULL);
}

/* nghttp3 asks the QUIC layer to send STOP_SENDING, or RESET_STREAM. */
static int h3_stop_sending_cb(nghttp3_conn *conn, int64_t id,
                              uint64_t app_error_code, void *user_data,
                              void *stream_user_data) {
  h3_session *s = user_data;
  return http3_quic_api->shutdown_stream_read(s->qc, id, app_error_code) == 0
             ? 0
             : NGHTTP3_ERR_CALLBACK_FAILURE;
}

static int h3_reset_stream_cb(nghttp3_conn *conn, int64_t id,
                              uint64_t app_error_code, void *user_data,
                              void *stream_user_data) {
  h3_session *s = user_data;
  return http3_quic_api->shutdown_stream_write(s->qc, id, app_error_code) == 0
             ? 0
             : NGHTTP3_ERR_CALLBACK_FAILURE;
}

/* Unpredictable bytes for nghttp3's hardening against misbehaving peers.
 * Should getrandom fail other than by EINTR, the rest stays as it was:
 * nghttp3 only loses some unpredictability. */
static void h3_rand_cb(uint8_t *dest, size_t destlen) {
  while (destlen > 0) {
    ssize_t n = getrandom(dest, destlen, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return;
    }
    dest += n;
    destlen -= (size_t)n;
  }
}

/* The body reader. A file body is read 16 KiB at a time as nghttp3 asks;
 * queued chunks are handed over as they are, without copying. */
static nghttp3_ssize h3_read_data_cb(nghttp3_conn *conn, int64_t id,
                                     nghttp3_vec *vec, size_t veccnt,
                                     uint32_t *pflags, void *user_data,
                                     void *stream_user_data) {
  h3_stream *st = h3_stream_find(user_data, id);
  if (st == NULL) {
    *pflags |= NGHTTP3_DATA_FLAG_EOF;
    return 0;
  }

  if (st->fd >= 0 && st->handed == st->nchunks && st->file_off < st->file_end) {
    size_t want = (size_t)(st->file_end - st->file_off);
    if (want > H3_FILE_CHUNK_SIZE) {
      want = H3_FILE_CHUNK_SIZE;
    }
    uint8_t *buf = malloc(want);
    if (buf == NULL) {
      return NGHTTP3_ERR_NOMEM;
    }
    ssize_t n = pread(st->fd, buf, want, st->file_off);
    if (n <= 0 || h3_stream_push(st, buf, (size_t)n, Qnil) != 0) {
      /* A read error, or the file shrank under us: the response cannot be
       * completed. */
      free(buf);
      return NGHTTP3_ERR_CALLBACK_FAILURE;
    }
    st->file_off += n;
    if (st->file_off >= st->file_end) {
      h3_stream_end_file(st);
    }
  }

  size_t n = 0;
  while (st->handed < st->nchunks && n < veccnt) {
    const h3_chunk *chunk = &st->chunks[st->handed];
    vec[n].base = (uint8_t *)chunk->base;
    vec[n].len = chunk->len;
    st->unsent -= chunk->len;
    st->handed++;
    n++;
  }
  if (st->eof && st->handed == st->nchunks) {
    *pflags |= NGHTTP3_DATA_FLAG_EOF;
  }
  if (n > 0 || st->eof) {
    return (nghttp3_ssize)n;
  }
  st->blocked = true;
  return NGHTTP3_ERR_WOULDBLOCK;
}

static const nghttp3_data_reader h3_data_reader = {.read_data =
                                                       h3_read_data_cb};

/* Stream handler (quic -> glue). ud is the h3_session. */

/* Make the nghttp3 connection and its three unidirectional streams, as
 * ngtcp2's examples/server.cc does once the handshake is done. */
static int h3_handshake_completed(void *ud) {
  h3_session *s = ud;
  if (s->h3 != NULL) {
    return 0;
  }

  nghttp3_callbacks callbacks = {
      .acked_stream_data = h3_acked_stream_data_cb,
      .stream_close = h3_stream_close_cb,
      .recv_data = h3_recv_data_cb,
      .deferred_consume = h3_deferred_consume_cb,
      .begin_headers = h3_begin_headers_cb,
      .recv_header = h3_recv_header_cb,
      .end_headers = h3_end_headers_cb,
      .stop_sending = h3_stop_sending_cb,
      .end_stream = h3_end_stream_cb,
      .reset_stream = h3_reset_stream_cb,
      .rand = h3_rand_cb,
  };
  nghttp3_settings settings;
  nghttp3_settings_default(&settings);
  settings.qpack_max_dtable_capacity = 4096;
  settings.qpack_blocked_streams = 100;
  settings.max_field_section_size = s->max_field_section_size;

  if (nghttp3_conn_server_new(&s->h3, &callbacks, &settings, NULL, s) != 0) {
    s->h3 = NULL;
    return -1;
  }
  uint64_t max_streams = http3_quic_api->local_max_streams_bidi(s->qc);
  nghttp3_conn_set_max_client_streams_bidi(s->h3, max_streams);
  /* Every request #stop_reading gives up on leaves a Stream Cancellation on
   * the QPACK decoder stream, and nghttp3 fails the connection once that
   * stream holds more than max(this, 100) * 20 bytes. */
  nghttp3_conn_set_max_concurrent_streams(s->h3, (size_t)max_streams);

  int64_t ctrl, enc, dec;
  if (http3_quic_api->open_uni_stream(s->qc, &ctrl) != 0 ||
      http3_quic_api->open_uni_stream(s->qc, &enc) != 0 ||
      http3_quic_api->open_uni_stream(s->qc, &dec) != 0 ||
      nghttp3_conn_bind_control_stream(s->h3, ctrl) != 0 ||
      nghttp3_conn_bind_qpack_streams(s->h3, enc, dec) != 0) {
    return -1;
  }
  return 0;
}

/* A failure inside nghttp3 closes the QUIC connection with the HTTP/3 error
 * code it stands for. */
static int h3_fail(h3_session *s, int64_t rv) {
  http3_quic_api->set_application_error(
      s->qc, nghttp3_err_infer_quic_app_error_code((int)rv));
  return -1;
}

static int h3_recv_stream_data(void *ud, int64_t id, const uint8_t *data,
                               size_t len, int fin, uint64_t ts,
                               size_t *consumed) {
  h3_session *s = ud;
  if (s->h3 == NULL) {
    /* Nothing can arrive on a stream before the handshake; drop it. */
    *consumed = len;
    return 0;
  }
  nghttp3_ssize rv = nghttp3_conn_read_stream2(s->h3, id, data, len, fin, ts);
  if (rv < 0) {
    return h3_fail(s, rv);
  }
  *consumed = (size_t)rv;
  return 0;
}

static int h3_next_stream_data(void *ud, int64_t *id, int *fin,
                               quic_ext_vec *vecs, size_t cap, size_t *nvecs) {
  h3_session *s = ud;
  *id = -1;
  *fin = 0;
  *nvecs = 0;
  if (s->h3 == NULL) {
    return 0;
  }
  nghttp3_ssize n =
      nghttp3_conn_writev_stream(s->h3, id, fin, (nghttp3_vec *)vecs, cap);
  if (n < 0) {
    return h3_fail(s, n);
  }
  *nvecs = (size_t)n;
  return 0;
}

static int h3_stream_data_written(void *ud, int64_t id, size_t n) {
  h3_session *s = ud;
  if (s->h3 == NULL || id < 0) {
    return 0;
  }
  int rv = nghttp3_conn_add_write_offset(s->h3, id, n);
  return rv == 0 ? 0 : h3_fail(s, rv);
}

static int h3_stream_blocked(void *ud, int64_t id) {
  h3_session *s = ud;
  if (s->h3 != NULL) {
    nghttp3_conn_block_stream(s->h3, id);
  }
  return 0;
}

static int h3_stream_shut_write(void *ud, int64_t id) {
  h3_session *s = ud;
  if (s->h3 != NULL) {
    nghttp3_conn_shutdown_stream_write(s->h3, id);
  }
  return 0;
}

static int h3_acked_stream_data(void *ud, int64_t id, uint64_t n) {
  h3_session *s = ud;
  if (s->h3 == NULL) {
    return 0;
  }
  int rv = nghttp3_conn_add_ack_offset(s->h3, id, n);
  return rv == 0 ? 0 : h3_fail(s, rv);
}

static int h3_extend_max_stream_data(void *ud, int64_t id) {
  h3_session *s = ud;
  if (s->h3 == NULL) {
    return 0;
  }
  int rv = nghttp3_conn_unblock_stream(s->h3, id);
  return rv == 0 ? 0 : h3_fail(s, rv);
}

static int h3_extend_max_remote_streams_bidi(void *ud, uint64_t max) {
  h3_session *s = ud;
  if (s->h3 != NULL) {
    nghttp3_conn_set_max_client_streams_bidi(s->h3, max);
  }
  return 0;
}

static int h3_shutdown_stream_read(h3_session *s, int64_t id) {
  if (s->h3 == NULL) {
    return 0;
  }
  int rv = nghttp3_conn_shutdown_stream_read(s->h3, id);
  return rv == 0 ? 0 : h3_fail(s, rv);
}

static int h3_stream_stop_sending(void *ud, int64_t id,
                                  uint64_t app_error_code) {
  return h3_shutdown_stream_read(ud, id);
}

/* The client reset its side of the stream. The Ruby part answers a request
 * cut short by it (#on_reset). */
static int h3_stream_reset(void *ud, int64_t id, uint64_t final_size,
                           uint64_t app_error_code) {
  h3_session *s = ud;
  int rv = h3_shutdown_stream_read(s, id);
  if (rv != 0 || s->h3 == NULL) {
    return rv;
  }
  return h3_call_ruby(s, id_on_reset, id, 0, NULL);
}

static int h3_stream_close(void *ud, int64_t id, int has_code,
                           uint64_t app_error_code) {
  h3_session *s = ud;
  if (s->h3 == NULL) {
    return 0;
  }
  int rv = nghttp3_conn_close_stream(
      s->h3, id, has_code ? app_error_code : NGHTTP3_H3_NO_ERROR);
  if (rv == 0 || rv == NGHTTP3_ERR_STREAM_NOT_FOUND) {
    return 0;
  }
  return h3_fail(s, rv);
}

static const quic_ext_stream_handler h3_handler = {
    .size = sizeof(quic_ext_stream_handler),
    .recv_stream_data = h3_recv_stream_data,
    .next_stream_data = h3_next_stream_data,
    .stream_data_written = h3_stream_data_written,
    .stream_blocked = h3_stream_blocked,
    .stream_shut_write = h3_stream_shut_write,
    .acked_stream_data = h3_acked_stream_data,
    .extend_max_stream_data = h3_extend_max_stream_data,
    .extend_max_remote_streams_bidi = h3_extend_max_remote_streams_bidi,
    .stream_stop_sending = h3_stream_stop_sending,
    .stream_reset = h3_stream_reset,
    .stream_close = h3_stream_close,
    .handshake_completed = h3_handshake_completed,
};

/* The Ruby object */

static int h3_mark_stream_i(st_data_t key, st_data_t value, st_data_t arg) {
  const h3_stream *st = (const h3_stream *)value;
  /* rb_gc_mark, not rb_gc_mark_movable: nghttp3 holds pointers into these
   * Strings. */
  for (size_t i = 0; i < st->nchunks; i++) {
    rb_gc_mark(st->chunks[i].str);
  }
  return ST_CONTINUE;
}

static void h3_session_mark(void *ptr) {
  h3_session *s = ptr;
  rb_gc_mark(s->quic_conn);
  rb_gc_mark(s->pending_exc);
  rb_gc_mark(s->closed_ids);
  if (s->streams != NULL) {
    st_foreach(s->streams, h3_mark_stream_i, 0);
  }
}

static int h3_free_stream_i(st_data_t key, st_data_t value, st_data_t arg) {
  h3_stream_free((h3_stream *)value);
  return ST_CONTINUE;
}

/* Never touches qc: the QUIC connection may be gone already. */
static void h3_session_free(void *ptr) {
  h3_session *s = ptr;
  if (s->h3 != NULL) {
    nghttp3_conn_del(s->h3);
  }
  if (s->streams != NULL) {
    st_foreach(s->streams, h3_free_stream_i, 0);
    st_free_table(s->streams);
  }
  if (s->field_sizes != NULL) {
    st_free_table(s->field_sizes);
  }
  xfree(s);
}

static size_t h3_session_memsize(const void *ptr) {
  const h3_session *s = ptr;
  return sizeof(*s) + (s->streams != NULL ? st_memsize(s->streams) : 0);
}

/* self is the object wrapping this struct, so it is not marked, but
 * GC.compact may still move it. Everything else is pinned by dmark. */
static void h3_session_compact(void *ptr) {
  h3_session *s = ptr;
  s->self = rb_gc_location(s->self);
}

static const rb_data_type_t h3_session_data_type = {
    .wrap_struct_name = "HTTP3::Session",
    .function =
        {
            .dmark = h3_session_mark,
            .dfree = h3_session_free,
            .dsize = h3_session_memsize,
            .dcompact = h3_session_compact,
        },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static h3_session *h3_session_get(VALUE self) {
  h3_session *s;
  TypedData_Get_Struct(self, h3_session, &h3_session_data_type, s);
  return s;
}

static h3_session *h3_session_get_open(VALUE self) {
  h3_session *s = h3_session_get(self);
  if (s->h3 == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError,
             "the HTTP/3 connection is not set up yet (handshake pending)");
  }
  return s;
}

static h3_stream *h3_session_stream(VALUE self, VALUE rb_id) {
  h3_session *s = h3_session_get(self);
  h3_stream *st = h3_stream_find(s, NUM2LL(rb_id));
  if (st == NULL) {
    rb_raise(rb_eNghttp3StreamNotFoundError,
             "no response body is open on stream %" PRIsVALUE, rb_id);
  }
  return st;
}

/* Let nghttp3 ask for the body again after read_data said it would block. */
static void h3_stream_wake(h3_session *s, h3_stream *st) {
  if (!st->blocked || s->h3 == NULL) {
    return;
  }
  st->blocked = false;
  int rv = nghttp3_conn_resume_stream(s->h3, st->id);
  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to resume stream");
  }
}

/*
 * call-seq:
 *   HTTP3::Session._attach(quic_conn, max_field_section_size) -> Session
 *
 * Take over the streams of quic_conn, a QUIC::Connection::Server no stream
 * has been opened on yet. The nghttp3 connection is made when the
 * handshake completes (at once if it already has). A request whose header
 * section (counted as RFC 9114 section 4.2.2 does) exceeds
 * max_field_section_size gets #on_fields_too_large instead of the rest of
 * its headers.
 */
static VALUE rb_http3_session_s_attach(VALUE klass, VALUE quic_conn,
                                       VALUE max_field_section_size) {
  uint64_t max_fields = NUM2ULL(max_field_section_size);
  if (max_fields == 0 || max_fields > H3_VARINT_MAX) {
    rb_raise(rb_eArgError, "max_field_section_size must be 1..2**62-1");
  }
  quic_ext_conn *qc = http3_quic_api->conn_get(quic_conn);

  h3_session *s;
  VALUE self =
      TypedData_Make_Struct(klass, h3_session, &h3_session_data_type, s);
  s->self = self;
  s->quic_conn = quic_conn;
  s->qc = qc;
  s->pending_exc = Qnil;
  s->closed_ids = Qnil;
  s->max_field_section_size = max_fields;
  s->streams = st_init_numtable();
  s->field_sizes = st_init_numtable();
  s->closed_ids = rb_ary_new();

  int rv = http3_quic_api->set_stream_handler(qc, &h3_handler, s, self);
  if (rv != 0) {
    rb_raise(rb_eNghttp3InvalidStateError,
             "cannot attach to the QUIC connection (set_stream_handler: %d)",
             rv);
  }
  if (RTEST(rb_funcall(quic_conn, rb_intern("handshake_completed?"), 0)) &&
      h3_handshake_completed(s) != 0) {
    rb_raise(rb_eNghttp3FatalError, "cannot set up the HTTP/3 connection");
  }
  return self;
}

/*
 * call-seq:
 *   session.submit_response(stream_id, headers, has_body) -> self
 *
 * headers is an Array of [name, value] Strings, ":status" first. With
 * has_body, the body follows through #push_chunk / #push_eof or
 * #attach_file.
 */
static VALUE rb_http3_session_submit_response(VALUE self, VALUE rb_id,
                                              VALUE headers, VALUE has_body) {
  h3_session *s = h3_session_get_open(self);
  int64_t id = NUM2LL(rb_id);
  Check_Type(headers, T_ARRAY);

  long nvlen = RARRAY_LEN(headers);
  VALUE tmp;
  nghttp3_nv *nva = ALLOCV_N(nghttp3_nv, tmp, nvlen);
  for (long i = 0; i < nvlen; i++) {
    VALUE pair = rb_check_array_type(RARRAY_AREF(headers, i));
    if (NIL_P(pair) || RARRAY_LEN(pair) != 2) {
      rb_raise(rb_eArgError, "headers must be [name, value] pairs");
    }
    VALUE name = RARRAY_AREF(pair, 0);
    VALUE value = RARRAY_AREF(pair, 1);
    StringValue(name);
    StringValue(value);
    nva[i] = (nghttp3_nv){.name = (const uint8_t *)RSTRING_PTR(name),
                          .value = (const uint8_t *)RSTRING_PTR(value),
                          .namelen = (size_t)RSTRING_LEN(name),
                          .valuelen = (size_t)RSTRING_LEN(value),
                          .flags = NGHTTP3_NV_FLAG_NONE};
  }

  h3_stream *st = NULL;
  if (RTEST(has_body) && h3_stream_find(s, id) == NULL) {
    st = ZALLOC(h3_stream);
    st->id = id;
    st->fd = -1;
    st_insert(s->streams, (st_data_t)id, (st_data_t)st);
  }

  /* nghttp3 copies the header names and values. */
  int rv = nghttp3_conn_submit_response(
      s->h3, id, nva, (size_t)nvlen, RTEST(has_body) ? &h3_data_reader : NULL);
  ALLOCV_END(tmp);
  RB_GC_GUARD(headers);
  if (rv != 0) {
    if (st != NULL) {
      st_data_t key = (st_data_t)id;
      st_delete(s->streams, &key, NULL);
      h3_stream_free(st);
    }
    nghttp3_rb_raise(rv, "Failed to submit response");
  }
  return self;
}

/* rb_id as the id of a request stream: 0..2**62-1 and client-initiated
 * bidirectional. nghttp3 asserts the range. */
static int64_t h3_request_stream_id(VALUE rb_id) {
  int64_t id = NUM2LL(rb_id);
  if (id < 0 || (uint64_t)id > H3_VARINT_MAX) {
    rb_raise(rb_eArgError, "stream_id must be 0..2**62-1 (got %" PRIsVALUE ")",
             rb_id);
  }
  if ((id & 3) != 0) {
    rb_raise(rb_eArgError,
             "stream_id %" PRIsVALUE
             " is not a client-initiated bidirectional stream",
             rb_id);
  }
  return id;
}

/*
 * call-seq:
 *   session.stop_reading(stream_id) -> self
 *
 * Read no more of the request on stream_id, which is being answered
 * before all of it has arrived: nghttp3 drops what still comes, and the
 * client gets STOP_SENDING with H3_NO_ERROR. RFC 9114 section 4.1 lets a
 * server send a complete response before the request is complete and
 * then ask the client to stop sending it, with H3_NO_ERROR.
 */
static VALUE rb_http3_session_stop_reading(VALUE self, VALUE rb_id) {
  h3_session *s = h3_session_get_open(self);
  int64_t id = h3_request_stream_id(rb_id);
  int rv = nghttp3_conn_shutdown_stream_read(s->h3, id);
  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to stop reading the stream");
  }
  if (http3_quic_api->shutdown_stream_read(s->qc, id, NGHTTP3_H3_NO_ERROR) !=
      0) {
    rb_raise(rb_eNghttp3Error, "cannot send STOP_SENDING on stream %" PRIsVALUE,
             rb_id);
  }
  /* No end_headers will come to drop the count of a section cut short. */
  st_data_t key = (st_data_t)id;
  st_delete(s->field_sizes, &key, NULL);
  return self;
}

/*
 * call-seq:
 *   session.push_chunk(stream_id, str) -> self
 *
 * Queue a frozen copy of str as the next piece of the response body.
 */
static VALUE rb_http3_session_push_chunk(VALUE self, VALUE rb_id, VALUE str) {
  h3_session *s = h3_session_get(self);
  h3_stream *st = h3_session_stream(self, rb_id);
  StringValue(str);
  if (st->eof) {
    rb_raise(rb_eNghttp3InvalidStateError, "the body has ended");
  }
  if (RSTRING_LEN(str) == 0) {
    return self;
  }
  VALUE copy = rb_str_new_frozen(str);
  if (h3_stream_push(st, (const uint8_t *)RSTRING_PTR(copy),
                     (size_t)RSTRING_LEN(copy), copy) != 0) {
    rb_raise(rb_eNoMemError, "failed to queue a body chunk");
  }
  RB_GC_GUARD(copy);
  h3_stream_wake(s, st);
  return self;
}

/*
 * call-seq:
 *   session.push_eof(stream_id) -> self
 *
 * Mark the end of the response body.
 */
static VALUE rb_http3_session_push_eof(VALUE self, VALUE rb_id) {
  h3_session *s = h3_session_get(self);
  h3_stream *st = h3_session_stream(self, rb_id);
  st->eof = true;
  h3_stream_wake(s, st);
  return self;
}

/*
 * call-seq:
 *   session.attach_file(stream_id, io, offset, length) -> self
 *
 * Send length bytes of io from offset as the whole response body. The
 * descriptor is duplicated, so io may be closed afterwards. The duplicate
 * is close-on-exec, as Ruby's own descriptors are, so that a process the
 * application spawns does not inherit it, and is closed as soon as the
 * whole length has been read.
 */
static VALUE rb_http3_session_attach_file(VALUE self, VALUE rb_id, VALUE io,
                                          VALUE offset, VALUE length) {
  h3_session *s = h3_session_get(self);
  h3_stream *st = h3_session_stream(self, rb_id);
  if (st->fd >= 0 || st->eof || st->nchunks > 0) {
    rb_raise(rb_eNghttp3InvalidStateError, "the body is already given");
  }
  off_t off = NUM2OFFT(offset);
  off_t len = NUM2OFFT(length);
  if (off < 0 || len < 0) {
    rb_raise(rb_eArgError, "offset and length must not be negative");
  }
  int fd = rb_cloexec_dup(NUM2INT(rb_funcall(io, rb_intern("fileno"), 0)));
  if (fd < 0) {
    rb_sys_fail("dup");
  }
  rb_update_max_fd(fd);
  st->fd = fd;
  st->file_off = off;
  st->file_end = off + len;
  if (len == 0) {
    h3_stream_end_file(st);
  }
  h3_stream_wake(s, st);
  return self;
}

/*
 * call-seq:
 *   session.unsent_bytes(stream_id) -> Integer
 *
 * Bytes queued with #push_chunk that nghttp3 has not taken yet; 0 for a
 * stream without a body.
 */
static VALUE rb_http3_session_unsent_bytes(VALUE self, VALUE rb_id) {
  h3_stream *st = h3_stream_find(h3_session_get(self), NUM2LL(rb_id));
  return ULL2NUM(st == NULL ? 0 : st->unsent);
}

/*
 * call-seq:
 *   session.take_closed -> Array
 *
 * The ids of the streams nghttp3 closed since the last call.
 */
static VALUE rb_http3_session_take_closed(VALUE self) {
  h3_session *s = h3_session_get(self);
  VALUE closed = s->closed_ids;
  s->closed_ids = rb_ary_new();
  return closed;
}

/*
 * call-seq:
 *   session.take_error -> Exception or nil
 *
 * The exception the Ruby part raised inside a callback, if any. The
 * connection was closed because of it.
 */
static VALUE rb_http3_session_take_error(VALUE self) {
  h3_session *s = h3_session_get(self);
  VALUE exc = s->pending_exc;
  s->pending_exc = Qnil;
  return exc;
}

/*
 * call-seq:
 *   session.shutdown_notice -> self
 *
 * Send GOAWAY: the client may finish its requests, but no new one will be
 * served.
 */
static VALUE rb_http3_session_shutdown_notice(VALUE self) {
  h3_session *s = h3_session_get(self);
  if (s->h3 == NULL) {
    return self;
  }
  int rv = nghttp3_conn_submit_shutdown_notice(s->h3);
  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to submit shutdown notice");
  }
  return self;
}

/*
 * call-seq:
 *   session.abort_stream(stream_id, app_error_code) -> self
 *
 * Stop the stream in both directions with app_error_code (for instance
 * H3_INTERNAL_ERROR after the response headers went out).
 */
static VALUE rb_http3_session_abort_stream(VALUE self, VALUE rb_id,
                                           VALUE rb_code) {
  h3_session *s = h3_session_get(self);
  int64_t id = NUM2LL(rb_id);
  uint64_t code = NUM2ULL(rb_code);
  if (s->h3 != NULL) {
    nghttp3_conn_shutdown_stream_write(s->h3, id);
  }
  http3_quic_api->shutdown_stream_write(s->qc, id, code);
  http3_quic_api->shutdown_stream_read(s->qc, id, code);
  return self;
}

void Init_http3_session(VALUE rb_mHTTP3) {
  id_on_begin_headers = rb_intern("on_begin_headers");
  id_on_header = rb_intern("on_header");
  id_on_end_headers = rb_intern("on_end_headers");
  id_on_data = rb_intern("on_data");
  id_on_end_stream = rb_intern("on_end_stream");
  id_on_fields_too_large = rb_intern("on_fields_too_large");
  id_on_reset = rb_intern("on_reset");

  rb_cHTTP3Session = rb_define_class_under(rb_mHTTP3, "Session", rb_cObject);
  rb_undef_alloc_func(rb_cHTTP3Session);
  rb_define_singleton_method(rb_cHTTP3Session, "_attach",
                             rb_http3_session_s_attach, 2);
  rb_define_method(rb_cHTTP3Session, "submit_response",
                   rb_http3_session_submit_response, 3);
  rb_define_method(rb_cHTTP3Session, "stop_reading",
                   rb_http3_session_stop_reading, 1);
  rb_define_method(rb_cHTTP3Session, "push_chunk", rb_http3_session_push_chunk,
                   2);
  rb_define_method(rb_cHTTP3Session, "push_eof", rb_http3_session_push_eof, 1);
  rb_define_method(rb_cHTTP3Session, "attach_file",
                   rb_http3_session_attach_file, 4);
  rb_define_method(rb_cHTTP3Session, "unsent_bytes",
                   rb_http3_session_unsent_bytes, 1);
  rb_define_method(rb_cHTTP3Session, "take_closed",
                   rb_http3_session_take_closed, 0);
  rb_define_method(rb_cHTTP3Session, "take_error", rb_http3_session_take_error,
                   0);
  rb_define_method(rb_cHTTP3Session, "shutdown_notice",
                   rb_http3_session_shutdown_notice, 0);
  rb_define_method(rb_cHTTP3Session, "abort_stream",
                   rb_http3_session_abort_stream, 2);
}
