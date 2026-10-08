# frozen_string_literal: true

require "test_helper"

# The C extension's contract with nghttp3 and the GC: exceptions from Ruby
# never unwind through nghttp3, and callbacks keep working after GC.compact.
# A client and a server Connection talk to each other directly, as a
# lossless QUIC without flow control would carry their streams.
class TestNghttp3Safety < Minitest::Test
  REQUEST_STREAM = 0

  def test_exception_in_a_callback_comes_out_of_read_stream
    callbacks = Nghttp3::Callbacks.new.on_begin_headers { |_stream_id| raise "boom" }
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers)
    server = new_server(callbacks)

    error = assert_raises(RuntimeError) { transfer(client, server) }
    assert_equal "boom", error.message
  end

  def test_exception_in_read_data_comes_out_of_writev_stream
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers(method: "POST")) do |_stream_id|
      raise ArgumentError, "no body today"
    end

    error = assert_raises(ArgumentError) { drain(client) }
    assert_equal "no body today", error.message
  end

  def test_callbacks_must_be_a_callbacks_object
    assert_raises(TypeError) { Nghttp3::Connection.client_new(nil, Object.new) }
    assert_raises(TypeError) { Nghttp3::Connection.server_new(nil, "callbacks") }
  end

  # The server's callbacks find their connection through conn_user_data,
  # which must survive the server object moving.
  def test_callbacks_survive_gc_compaction
    headers = []
    callbacks = Nghttp3::Callbacks.new
      .on_recv_header { |_stream_id, name, value, _flags| headers << [name, value] }
    client = new_client
    server = new_server(callbacks)
    client.submit_request(REQUEST_STREAM, request_headers)

    GC.start
    GC.verify_compaction_references(expand_heap: true, toward: :empty)

    transfer(client, server)
    assert_includes headers, [":method", "GET"]
  end

  private

  def new_client(callbacks = nil)
    Nghttp3::Connection.client_new(nil, callbacks).tap do |conn|
      conn.bind_control_stream(2)
      conn.bind_qpack_streams(6, 10)
    end
  end

  def new_server(callbacks = nil)
    Nghttp3::Connection.server_new(nil, callbacks).tap do |conn|
      conn.bind_control_stream(3)
      conn.bind_qpack_streams(7, 11)
    end
  end

  def request_headers(method: "GET")
    [
      Nghttp3::NV.new(":method", method),
      Nghttp3::NV.new(":path", "/"),
      Nghttp3::NV.new(":scheme", "https"),
      Nghttp3::NV.new(":authority", "example.com")
    ]
  end

  # Take everything from's writev_stream offers without a peer. Returns the
  # bytes written per stream.
  def drain(from)
    sent = Hash.new(0)
    while (out = from.writev_stream)
      from.add_write_offset(out[:stream_id], out[:data].bytesize)
      sent[out[:stream_id]] += out[:data].bytesize
    end
    sent
  end

  # Hand everything from's writev_stream offers to to.
  def transfer(from, to)
    while (out = from.writev_stream)
      to.read_stream(out[:stream_id], out[:data], fin: out[:fin])
      from.add_write_offset(out[:stream_id], out[:data].bytesize)
    end
  end
end
