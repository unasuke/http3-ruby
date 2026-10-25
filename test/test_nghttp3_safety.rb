# frozen_string_literal: true

require "test_helper"

# The C extension's contract with nghttp3 and the GC: exceptions from Ruby
# never unwind through nghttp3, body Strings stay put until the peer
# acknowledges them, and callbacks keep working after GC.compact. A client
# and a server Connection talk to each other directly, as a lossless QUIC
# without flow control would carry their streams.
class TestNghttp3Safety < Minitest::Test
  REQUEST_STREAM = 0

  def test_exception_in_a_callback_comes_out_of_read_stream
    callbacks = HTTP3::Nghttp3::Callbacks.new.on_begin_headers { |_stream_id| raise "boom" }
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
    assert_raises(TypeError) { HTTP3::Nghttp3::Connection.client_new(nil, Object.new) }
    assert_raises(TypeError) { HTTP3::Nghttp3::Connection.server_new(nil, "callbacks") }
  end

  # nghttp3 reports acknowledged body bytes only. A String goes once the
  # peer has acknowledged it to its end; one acknowledged in part stays.
  def test_pending_data_shrinks_as_the_peer_acknowledges
    chunks = ["a" * 100, "b" * 200, "c" * 300]
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers(method: "POST")) { |_stream_id| chunks.shift }
    sent = drain(client)
    assert_equal ["a" * 100, "b" * 200, "c" * 300], client.pending_data(REQUEST_STREAM)

    client.add_ack_offset(REQUEST_STREAM, sent[REQUEST_STREAM] - 1)
    assert_equal ["c" * 300], client.pending_data(REQUEST_STREAM)

    client.add_ack_offset(REQUEST_STREAM, 1)
    assert_empty client.pending_data(REQUEST_STREAM)
  end

  # submit_* keeps a frozen copy, so changing the String afterwards does not
  # change what is sent.
  def test_body_is_copied_when_submitted
    body = +"original body"
    received = +""
    callbacks = HTTP3::Nghttp3::Callbacks.new.on_recv_data { |_stream_id, data| received << data }
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers(method: "POST"), body: body)
    body.replace("changed!")

    transfer(client, new_server(callbacks))
    assert_equal "original body", received
  end

  # Until add_write_offset, writev_stream hands out the same bytes again,
  # read from the body String nghttp3 holds. That String is short enough to
  # be embedded, so only pinning keeps compaction from moving its bytes. The
  # server's callbacks find their connection through conn_user_data, which
  # must survive the server object moving too.
  def test_body_and_callbacks_survive_gc_compaction
    headers = []
    received = +""
    callbacks = HTTP3::Nghttp3::Callbacks.new
      .on_recv_header { |_stream_id, name, value, _flags| headers << [name, value] }
      .on_recv_data { |_stream_id, data| received << data }
    client = new_client
    server = new_server(callbacks)
    client.submit_request(REQUEST_STREAM, request_headers(method: "POST"), body: "compact me")

    transfer(client, server, until_stream: REQUEST_STREAM)
    before = client.writev_stream
    assert_equal REQUEST_STREAM, before[:stream_id]

    GC.start
    GC.verify_compaction_references(expand_heap: true, toward: :empty)

    assert_equal before, client.writev_stream
    transfer(client, server)
    assert_includes headers, [":method", "POST"]
    assert_equal "compact me", received
  end

  # Told not to copy, nghttp3 would read the names and values only when
  # writev_stream sends them, after the NVs are gone and their Strings
  # freed or moved. The flags are ignored, so the right headers arrive.
  def test_no_copy_flags_are_ignored
    headers = [[":method", "GET"], [":path", "/" + "p" * 200], [":scheme", "https"], [":authority", "example.com"]]
    received = []
    callbacks = HTTP3::Nghttp3::Callbacks.new.on_recv_header { |_stream_id, name, value, _flags| received << [name, value] }
    client = new_client
    flags = HTTP3::Nghttp3::NV_FLAG_NO_COPY_NAME | HTTP3::Nghttp3::NV_FLAG_NO_COPY_VALUE
    client.submit_request(REQUEST_STREAM, headers.map { |name, value| HTTP3::Nghttp3::NV.new(name, value, flags: flags) })

    GC.start
    GC.verify_compaction_references(expand_heap: true, toward: :empty)
    Array.new(100_000) { "x" * 200 }

    transfer(client, new_server(callbacks))
    assert_equal headers, received
  end

  def test_read_stream_takes_a_timestamp
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers)
    server = new_server
    while (out = client.writev_stream)
      consumed = server.read_stream(out[:stream_id], out[:data], fin: out[:fin], ts: 42)
      assert_kind_of Integer, consumed
      client.add_write_offset(out[:stream_id], out[:data].bytesize)
    end
  end

  def test_shutdown_stream_read_and_set_max_client_streams_bidi
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers)
    server = new_server
    transfer(client, server)

    assert_same server, server.shutdown_stream_read(REQUEST_STREAM)
    assert_same server, server.set_max_client_streams_bidi(100)
  end

  private

  def new_client(callbacks = nil)
    HTTP3::Nghttp3::Connection.client_new(nil, callbacks).tap do |conn|
      conn.bind_control_stream(2)
      conn.bind_qpack_streams(6, 10)
    end
  end

  def new_server(callbacks = nil)
    HTTP3::Nghttp3::Connection.server_new(nil, callbacks).tap do |conn|
      conn.bind_control_stream(3)
      conn.bind_qpack_streams(7, 11)
    end
  end

  def request_headers(method: "GET")
    [
      HTTP3::Nghttp3::NV.new(":method", method),
      HTTP3::Nghttp3::NV.new(":path", "/"),
      HTTP3::Nghttp3::NV.new(":scheme", "https"),
      HTTP3::Nghttp3::NV.new(":authority", "example.com")
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

  # Hand everything from's writev_stream offers to to. With until_stream,
  # stop before the first data of that stream, leaving it unwritten.
  def transfer(from, to, until_stream: nil)
    while (out = from.writev_stream)
      break if out[:stream_id] == until_stream

      to.read_stream(out[:stream_id], out[:data], fin: out[:fin])
      from.add_write_offset(out[:stream_id], out[:data].bytesize)
    end
  end
end
