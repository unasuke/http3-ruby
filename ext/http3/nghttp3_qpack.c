#include "nghttp3.h"

VALUE rb_mNghttp3QPACK;
VALUE rb_cNghttp3QPACKEncoder;
VALUE rb_cNghttp3QPACKDecoder;

/* ============== Encoder ============== */

typedef struct {
  nghttp3_qpack_encoder *encoder;
  size_t hard_max_dtable_capacity;
} EncoderObj;

static void encoder_free(void *ptr) {
  EncoderObj *obj = (EncoderObj *)ptr;
  if (obj->encoder != NULL) {
    nghttp3_qpack_encoder_del(obj->encoder);
    obj->encoder = NULL;
  }
  xfree(ptr);
}

static size_t encoder_memsize(const void *ptr) { return sizeof(EncoderObj); }

static const rb_data_type_t encoder_data_type = {
    .wrap_struct_name = "nghttp3_qpack_encoder_rb",
    .function =
        {
            .dmark = NULL,
            .dfree = encoder_free,
            .dsize = encoder_memsize,
        },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE encoder_alloc(VALUE klass) {
  EncoderObj *obj;
  VALUE self =
      TypedData_Make_Struct(klass, EncoderObj, &encoder_data_type, obj);
  obj->encoder = NULL;
  obj->hard_max_dtable_capacity = 0;
  return self;
}

/*
 * call-seq:
 *   Encoder.new(max_dtable_capacity) -> Encoder
 *
 * Creates a new QPACK encoder.
 */
static VALUE rb_nghttp3_qpack_encoder_initialize(VALUE self,
                                                 VALUE rb_max_capacity) {
  EncoderObj *obj;
  size_t max_capacity;
  int rv;

  TypedData_Get_Struct(self, EncoderObj, &encoder_data_type, obj);

  max_capacity = NUM2SIZET(rb_max_capacity);
  obj->hard_max_dtable_capacity = max_capacity;

  rv = nghttp3_qpack_encoder_new(&obj->encoder, max_capacity,
                                 nghttp3_mem_default());

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to create QPACK encoder");
  }

  return self;
}

/*
 * Helper to convert nghttp3_buf to Ruby String
 */
static VALUE buf_to_string(nghttp3_buf *buf) {
  size_t len = nghttp3_buf_len(buf);
  if (len == 0) {
    return rb_str_new("", 0);
  }
  return rb_str_new((const char *)buf->pos, len);
}

/*
 * call-seq:
 *   encoder.encode(stream_id, headers) -> Hash
 *
 * Encodes headers. Returns a Hash with :prefix, :data, and :encoder_stream.
 */
static VALUE rb_nghttp3_qpack_encoder_encode(VALUE self, VALUE rb_stream_id,
                                             VALUE rb_headers) {
  EncoderObj *obj;
  int64_t stream_id;
  nghttp3_nv *nva;
  VALUE nva_buf;
  long nvlen, bad;
  nghttp3_buf pbuf, rbuf, ebuf;
  int rv;
  VALUE result;

  TypedData_Get_Struct(self, EncoderObj, &encoder_data_type, obj);

  /* As Connection#submit_request does: the arguments first, since to_int
   * may run Ruby code, then every allocation, and only then the pointers
   * into the header Strings. */
  stream_id = nghttp3_rb_stream_id(rb_stream_id);
  Check_Type(rb_headers, T_ARRAY);

  if (obj->encoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Encoder is not initialized");
  }

  /* On the heap: a Ruby thread's machine stack is too small for a long
   * list. */
  nvlen = RARRAY_LEN(rb_headers);
  nva = ALLOCV_N(nghttp3_nv, nva_buf, nvlen);

  bad = nghttp3_rb_nva_fill(rb_headers, nva, nvlen);
  if (bad >= 0) {
    ALLOCV_END(nva_buf);
    nghttp3_rb_raise_bad_nv(bad);
  }

  /* Initialize buffers */
  nghttp3_buf_init(&pbuf);
  nghttp3_buf_init(&rbuf);
  nghttp3_buf_init(&ebuf);

  rv = nghttp3_qpack_encoder_encode(obj->encoder, &pbuf, &rbuf, &ebuf,
                                    stream_id, nva, (size_t)nvlen);
  ALLOCV_END(nva_buf);
  RB_GC_GUARD(rb_headers);

  if (rv != 0) {
    nghttp3_buf_free(&pbuf, nghttp3_mem_default());
    nghttp3_buf_free(&rbuf, nghttp3_mem_default());
    nghttp3_buf_free(&ebuf, nghttp3_mem_default());
    nghttp3_rb_raise(rv, "Failed to encode headers");
  }

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("prefix")), buf_to_string(&pbuf));
  rb_hash_aset(result, ID2SYM(rb_intern("data")), buf_to_string(&rbuf));
  rb_hash_aset(result, ID2SYM(rb_intern("encoder_stream")),
               buf_to_string(&ebuf));

  nghttp3_buf_free(&pbuf, nghttp3_mem_default());
  nghttp3_buf_free(&rbuf, nghttp3_mem_default());
  nghttp3_buf_free(&ebuf, nghttp3_mem_default());

  return result;
}

/*
 * call-seq:
 *   encoder.read_decoder(data) -> Integer
 *
 * Reads decoder stream data. Returns number of bytes consumed.
 */
static VALUE rb_nghttp3_qpack_encoder_read_decoder(VALUE self, VALUE rb_data) {
  EncoderObj *obj;
  nghttp3_ssize rv;

  TypedData_Get_Struct(self, EncoderObj, &encoder_data_type, obj);

  if (obj->encoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Encoder is not initialized");
  }

  Check_Type(rb_data, T_STRING);

  rv = nghttp3_qpack_encoder_read_decoder(obj->encoder,
                                          (const uint8_t *)RSTRING_PTR(rb_data),
                                          RSTRING_LEN(rb_data));

  if (rv < 0) {
    nghttp3_rb_raise((int)rv, "Failed to read decoder stream");
  }

  return LL2NUM(rv);
}

/*
 * call-seq:
 *   encoder.max_dtable_capacity = capacity
 *
 * Sets the maximum dynamic table capacity.
 */
static VALUE rb_nghttp3_qpack_encoder_set_max_dtable_capacity(VALUE self,
                                                              VALUE rb_cap) {
  EncoderObj *obj;
  size_t cap;

  TypedData_Get_Struct(self, EncoderObj, &encoder_data_type, obj);

  if (obj->encoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Encoder is not initialized");
  }

  cap = NUM2SIZET(rb_cap);
  nghttp3_qpack_encoder_set_max_dtable_capacity(obj->encoder, cap);

  return rb_cap;
}

/*
 * call-seq:
 *   encoder.max_blocked_streams = num
 *
 * Sets the maximum number of blocked streams.
 */
static VALUE rb_nghttp3_qpack_encoder_set_max_blocked_streams(VALUE self,
                                                              VALUE rb_num) {
  EncoderObj *obj;
  size_t num;

  TypedData_Get_Struct(self, EncoderObj, &encoder_data_type, obj);

  if (obj->encoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Encoder is not initialized");
  }

  num = NUM2SIZET(rb_num);
  nghttp3_qpack_encoder_set_max_blocked_streams(obj->encoder, num);

  return rb_num;
}

/*
 * call-seq:
 *   encoder.num_blocked_streams -> Integer
 *
 * Returns the number of currently blocked streams.
 */
static VALUE rb_nghttp3_qpack_encoder_get_num_blocked_streams(VALUE self) {
  EncoderObj *obj;
  size_t num;

  TypedData_Get_Struct(self, EncoderObj, &encoder_data_type, obj);

  if (obj->encoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Encoder is not initialized");
  }

  num = nghttp3_qpack_encoder_get_num_blocked_streams(obj->encoder);

  return SIZET2NUM(num);
}

/* ============== Decoder ============== */

typedef struct {
  nghttp3_qpack_decoder *decoder;
  /* stream_id => nghttp3_qpack_stream_context *, in a C st_table: dfree
   * runs during GC, when a Ruby Hash may already be freed. */
  st_table *stream_contexts;
  size_t hard_max_dtable_capacity;
  size_t max_blocked_streams;
} DecoderObj;

static int free_stream_context_i(st_data_t key, st_data_t value,
                                 st_data_t arg) {
  nghttp3_qpack_stream_context_del((nghttp3_qpack_stream_context *)value);
  return ST_CONTINUE;
}

static void decoder_free(void *ptr) {
  DecoderObj *obj = (DecoderObj *)ptr;

  if (obj->stream_contexts != NULL) {
    st_foreach(obj->stream_contexts, free_stream_context_i, 0);
    st_free_table(obj->stream_contexts);
  }

  if (obj->decoder != NULL) {
    nghttp3_qpack_decoder_del(obj->decoder);
    obj->decoder = NULL;
  }
  xfree(ptr);
}

static size_t decoder_memsize(const void *ptr) {
  const DecoderObj *obj = (const DecoderObj *)ptr;
  return sizeof(DecoderObj) +
         (obj->stream_contexts != NULL ? st_memsize(obj->stream_contexts) : 0);
}

static const rb_data_type_t decoder_data_type = {
    .wrap_struct_name = "nghttp3_qpack_decoder_rb",
    .function =
        {
            .dmark = NULL,
            .dfree = decoder_free,
            .dsize = decoder_memsize,
        },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE decoder_alloc(VALUE klass) {
  DecoderObj *obj;
  VALUE self =
      TypedData_Make_Struct(klass, DecoderObj, &decoder_data_type, obj);
  obj->decoder = NULL;
  obj->stream_contexts = st_init_numtable();
  obj->hard_max_dtable_capacity = 0;
  obj->max_blocked_streams = 0;
  return self;
}

/*
 * call-seq:
 *   Decoder.new(max_dtable_capacity, max_blocked_streams) -> Decoder
 *
 * Creates a new QPACK decoder.
 */
static VALUE rb_nghttp3_qpack_decoder_initialize(VALUE self,
                                                 VALUE rb_max_capacity,
                                                 VALUE rb_max_blocked) {
  DecoderObj *obj;
  size_t max_capacity, max_blocked;
  int rv;

  TypedData_Get_Struct(self, DecoderObj, &decoder_data_type, obj);

  max_capacity = NUM2SIZET(rb_max_capacity);
  max_blocked = NUM2SIZET(rb_max_blocked);
  obj->hard_max_dtable_capacity = max_capacity;
  obj->max_blocked_streams = max_blocked;

  rv = nghttp3_qpack_decoder_new(&obj->decoder, max_capacity, max_blocked,
                                 nghttp3_mem_default());

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to create QPACK decoder");
  }

  return self;
}

/*
 * Get or create a stream context for the given stream_id
 */
static nghttp3_qpack_stream_context *
get_or_create_stream_context(DecoderObj *obj, int64_t stream_id) {
  st_data_t existing;

  if (st_lookup(obj->stream_contexts, (st_data_t)stream_id, &existing)) {
    return (nghttp3_qpack_stream_context *)existing;
  }

  /* Create new context */
  nghttp3_qpack_stream_context *sctx;
  int rv =
      nghttp3_qpack_stream_context_new(&sctx, stream_id, nghttp3_mem_default());

  if (rv != 0) {
    return NULL;
  }

  st_insert(obj->stream_contexts, (st_data_t)stream_id, (st_data_t)sctx);

  return sctx;
}

/* Free the stream context for stream_id, if there is one. */
static void delete_stream_context(DecoderObj *obj, int64_t stream_id) {
  st_data_t key = (st_data_t)stream_id;
  st_data_t value;

  if (st_delete(obj->stream_contexts, &key, &value)) {
    nghttp3_qpack_stream_context_del((nghttp3_qpack_stream_context *)value);
  }
}

/*
 * Helper to convert nghttp3_rcbuf to Ruby String and decref
 */
static VALUE rcbuf_to_string(nghttp3_rcbuf *rcbuf) {
  nghttp3_vec vec = nghttp3_rcbuf_get_buf(rcbuf);
  VALUE str = rb_str_new((const char *)vec.base, vec.len);
  nghttp3_rcbuf_decref(rcbuf);
  return str;
}

/*
 * call-seq:
 *   decoder.decode(stream_id, data, fin: false) -> Hash
 *
 * Decodes headers. Returns a Hash with :headers, :blocked, :consumed.
 */
static VALUE rb_nghttp3_qpack_decoder_decode(int argc, VALUE *argv,
                                             VALUE self) {
  VALUE rb_stream_id, rb_data, rb_opts;
  VALUE rb_fin = Qfalse;
  DecoderObj *obj;
  int64_t stream_id;
  nghttp3_qpack_stream_context *sctx;
  nghttp3_qpack_nv nv;
  uint8_t flags;
  nghttp3_ssize rv;
  const uint8_t *src;
  size_t srclen;
  int fin;
  VALUE result, headers;
  size_t total_consumed = 0;
  int blocked = 0;

  rb_scan_args(argc, argv, "2:", &rb_stream_id, &rb_data, &rb_opts);

  if (!NIL_P(rb_opts)) {
    rb_fin = rb_hash_aref(rb_opts, ID2SYM(rb_intern("fin")));
  }

  TypedData_Get_Struct(self, DecoderObj, &decoder_data_type, obj);

  if (obj->decoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Decoder is not initialized");
  }

  stream_id = nghttp3_rb_stream_id(rb_stream_id);
  Check_Type(rb_data, T_STRING);
  src = (const uint8_t *)RSTRING_PTR(rb_data);
  srclen = RSTRING_LEN(rb_data);
  fin = RTEST(rb_fin) ? 1 : 0;

  sctx = get_or_create_stream_context(obj, stream_id);
  if (sctx == NULL) {
    rb_raise(rb_eNghttp3NoMemError, "Failed to create stream context");
  }

  headers = rb_ary_new();

  while (srclen > 0 || fin) {
    rv = nghttp3_qpack_decoder_read_request(obj->decoder, sctx, &nv, &flags,
                                            src, srclen, fin);

    if (rv < 0) {
      nghttp3_rb_raise((int)rv, "Failed to decode headers");
    }

    total_consumed += (size_t)rv;
    src += rv;
    srclen -= (size_t)rv;

    if (flags & NGHTTP3_QPACK_DECODE_FLAG_BLOCKED) {
      blocked = 1;
      break;
    }

    if (flags & NGHTTP3_QPACK_DECODE_FLAG_EMIT) {
      VALUE header = rb_hash_new();
      rb_hash_aset(header, ID2SYM(rb_intern("name")), rcbuf_to_string(nv.name));
      rb_hash_aset(header, ID2SYM(rb_intern("value")),
                   rcbuf_to_string(nv.value));
      rb_hash_aset(header, ID2SYM(rb_intern("token")), INT2NUM(nv.token));
      rb_ary_push(headers, header);
    }

    if (flags & NGHTTP3_QPACK_DECODE_FLAG_FINAL) {
      delete_stream_context(obj, stream_id);
      break;
    }

    if (rv == 0 && srclen == 0) {
      break;
    }
  }

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("headers")), blocked ? Qnil : headers);
  rb_hash_aset(result, ID2SYM(rb_intern("blocked")), blocked ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("consumed")),
               SIZET2NUM(total_consumed));

  return result;
}

/*
 * call-seq:
 *   decoder.read_encoder(data) -> Integer
 *
 * Reads encoder stream data. Returns number of bytes consumed.
 */
static VALUE rb_nghttp3_qpack_decoder_read_encoder(VALUE self, VALUE rb_data) {
  DecoderObj *obj;
  nghttp3_ssize rv;

  TypedData_Get_Struct(self, DecoderObj, &decoder_data_type, obj);

  if (obj->decoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Decoder is not initialized");
  }

  Check_Type(rb_data, T_STRING);

  rv = nghttp3_qpack_decoder_read_encoder(obj->decoder,
                                          (const uint8_t *)RSTRING_PTR(rb_data),
                                          RSTRING_LEN(rb_data));

  if (rv < 0) {
    nghttp3_rb_raise((int)rv, "Failed to read encoder stream");
  }

  return LL2NUM(rv);
}

/*
 * call-seq:
 *   decoder.decoder_stream_data -> String
 *
 * Returns data to be sent on the decoder stream.
 */
static VALUE rb_nghttp3_qpack_decoder_decoder_stream_data(VALUE self) {
  DecoderObj *obj;
  nghttp3_buf dbuf;
  size_t len;
  VALUE result;

  TypedData_Get_Struct(self, DecoderObj, &decoder_data_type, obj);

  if (obj->decoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Decoder is not initialized");
  }

  len = nghttp3_qpack_decoder_get_decoder_streamlen(obj->decoder);

  if (len == 0) {
    return rb_str_new("", 0);
  }

  /* Allocate buffer */
  nghttp3_buf_init(&dbuf);
  dbuf.begin = ALLOC_N(uint8_t, len);
  dbuf.pos = dbuf.begin;
  dbuf.last = dbuf.begin;
  dbuf.end = dbuf.begin + len;

  nghttp3_qpack_decoder_write_decoder(obj->decoder, &dbuf);

  result = rb_str_new((const char *)dbuf.pos, nghttp3_buf_len(&dbuf));

  xfree(dbuf.begin);

  return result;
}

/*
 * call-seq:
 *   decoder.cancel_stream(stream_id) -> nil
 *
 * Cancels decoding for the given stream.
 */
static VALUE rb_nghttp3_qpack_decoder_cancel_stream(VALUE self,
                                                    VALUE rb_stream_id) {
  DecoderObj *obj;
  int64_t stream_id;
  int rv;

  TypedData_Get_Struct(self, DecoderObj, &decoder_data_type, obj);

  if (obj->decoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Decoder is not initialized");
  }

  stream_id = nghttp3_rb_stream_id(rb_stream_id);

  delete_stream_context(obj, stream_id);

  rv = nghttp3_qpack_decoder_cancel_stream(obj->decoder, stream_id);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to cancel stream");
  }

  return Qnil;
}

/*
 * call-seq:
 *   decoder.max_dtable_capacity = capacity
 *
 * Sets the maximum dynamic table capacity.
 */
static VALUE rb_nghttp3_qpack_decoder_set_max_dtable_capacity(VALUE self,
                                                              VALUE rb_cap) {
  DecoderObj *obj;
  size_t cap;
  int rv;

  TypedData_Get_Struct(self, DecoderObj, &decoder_data_type, obj);

  if (obj->decoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Decoder is not initialized");
  }

  cap = NUM2SIZET(rb_cap);
  rv = nghttp3_qpack_decoder_set_max_dtable_capacity(obj->decoder, cap);

  if (rv != 0) {
    nghttp3_rb_raise(rv, "Failed to set max dtable capacity");
  }

  return rb_cap;
}

/*
 * call-seq:
 *   decoder.insert_count -> Integer
 *
 * Returns the current insert count.
 */
static VALUE rb_nghttp3_qpack_decoder_get_insert_count(VALUE self) {
  DecoderObj *obj;
  uint64_t icnt;

  TypedData_Get_Struct(self, DecoderObj, &decoder_data_type, obj);

  if (obj->decoder == NULL) {
    rb_raise(rb_eNghttp3InvalidStateError, "Decoder is not initialized");
  }

  icnt = nghttp3_qpack_decoder_get_icnt(obj->decoder);

  return ULL2NUM(icnt);
}

void Init_nghttp3_qpack(void) {
  /* Define QPACK module */
  rb_mNghttp3QPACK = rb_define_module_under(rb_mNghttp3, "QPACK");

  /* Define Encoder class */
  rb_cNghttp3QPACKEncoder =
      rb_define_class_under(rb_mNghttp3QPACK, "Encoder", rb_cObject);
  rb_define_alloc_func(rb_cNghttp3QPACKEncoder, encoder_alloc);
  rb_define_method(rb_cNghttp3QPACKEncoder, "initialize",
                   rb_nghttp3_qpack_encoder_initialize, 1);
  rb_define_method(rb_cNghttp3QPACKEncoder, "encode",
                   rb_nghttp3_qpack_encoder_encode, 2);
  rb_define_method(rb_cNghttp3QPACKEncoder, "read_decoder",
                   rb_nghttp3_qpack_encoder_read_decoder, 1);
  rb_define_method(rb_cNghttp3QPACKEncoder, "max_dtable_capacity=",
                   rb_nghttp3_qpack_encoder_set_max_dtable_capacity, 1);
  rb_define_method(rb_cNghttp3QPACKEncoder, "max_blocked_streams=",
                   rb_nghttp3_qpack_encoder_set_max_blocked_streams, 1);
  rb_define_method(rb_cNghttp3QPACKEncoder, "num_blocked_streams",
                   rb_nghttp3_qpack_encoder_get_num_blocked_streams, 0);

  /* Define Decoder class */
  rb_cNghttp3QPACKDecoder =
      rb_define_class_under(rb_mNghttp3QPACK, "Decoder", rb_cObject);
  rb_define_alloc_func(rb_cNghttp3QPACKDecoder, decoder_alloc);
  rb_define_method(rb_cNghttp3QPACKDecoder, "initialize",
                   rb_nghttp3_qpack_decoder_initialize, 2);
  rb_define_method(rb_cNghttp3QPACKDecoder, "decode",
                   rb_nghttp3_qpack_decoder_decode, -1);
  rb_define_method(rb_cNghttp3QPACKDecoder, "read_encoder",
                   rb_nghttp3_qpack_decoder_read_encoder, 1);
  rb_define_method(rb_cNghttp3QPACKDecoder, "decoder_stream_data",
                   rb_nghttp3_qpack_decoder_decoder_stream_data, 0);
  rb_define_method(rb_cNghttp3QPACKDecoder, "cancel_stream",
                   rb_nghttp3_qpack_decoder_cancel_stream, 1);
  rb_define_method(rb_cNghttp3QPACKDecoder, "max_dtable_capacity=",
                   rb_nghttp3_qpack_decoder_set_max_dtable_capacity, 1);
  rb_define_method(rb_cNghttp3QPACKDecoder, "insert_count",
                   rb_nghttp3_qpack_decoder_get_insert_count, 0);
}
