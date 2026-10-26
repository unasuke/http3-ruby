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

  # A Ruby thread's machine stack is small: 100,000 fields, 40 bytes each
  # as nghttp3_nv, would overflow it were they put there.
  def test_many_fields_in_a_thread
    headers = request_headers + Array.new(100_000) { |i| HTTP3::Nghttp3::NV.new("x-field", i.to_s) }
    encoded = Thread.new do
      new_client.submit_request(REQUEST_STREAM, headers)
      HTTP3::Nghttp3::QPACK::Encoder.new(0).encode(REQUEST_STREAM, headers)
    end.value
    refute_empty encoded[:data]
  end

  # The pointers into the header Strings are taken only once no Ruby code
  # can run before nghttp3 copies them, so an NV's instance variables are
  # read as they are: one that is not an NV with String name and value and
  # flags of 0..255 is refused, to_str is not called, and nothing reaches
  # nghttp3.
  def test_bad_nvs_are_refused_without_running_ruby_code
    value = Object.new
    to_str_called = false
    value.define_singleton_method(:to_str) { to_str_called = true }
    bad_nvs = [
      HTTP3::Nghttp3::NV.new("x-a", "a").tap { |nv| nv.instance_variable_set(:@name, 1) },
      HTTP3::Nghttp3::NV.new("x-b", "b").tap { |nv| nv.instance_variable_set(:@value, value) },
      HTTP3::Nghttp3::NV.new("x-c", "c").tap { |nv| nv.instance_variable_set(:@flags, "x") },
      "x-d: d"
    ]
    message = "headers[4] is not an HTTP3::Nghttp3::NV with String name and value"
    client = new_client
    server = new_server
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(0)
    bad_nvs.each do |nv|
      headers = request_headers + [nv]
      assert_equal message, assert_raises(ArgumentError) { client.submit_request(REQUEST_STREAM, headers, body: "a") }.message
      assert_equal message, assert_raises(ArgumentError) { client.submit_trailers(REQUEST_STREAM, headers) }.message
      assert_equal message, assert_raises(ArgumentError) { server.submit_response(REQUEST_STREAM, headers) }.message
      assert_equal message, assert_raises(ArgumentError) { server.submit_info(REQUEST_STREAM, headers) }.message
      assert_equal message, assert_raises(ArgumentError) { encoder.encode(REQUEST_STREAM, headers) }.message
    end
    refute to_str_called

    # The stream is still free for a request.
    received = +""
    callbacks = HTTP3::Nghttp3::Callbacks.new.on_recv_data { |_stream_id, data| received << data }
    client.submit_request(REQUEST_STREAM, request_headers(method: "POST"), body: "the body")
    transfer(client, new_server(callbacks))
    assert_equal "the body", received
  end

  # The body's to_str runs before the connection is checked, and so before
  # nghttp3 is called with a connection to_str has closed.
  def test_connection_closed_by_the_body_to_str
    client = new_client
    body = Object.new
    body.define_singleton_method(:to_str) do
      client.close
      "body"
    end
    error = assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      client.submit_request(REQUEST_STREAM, request_headers(method: "POST"), body: body)
    end
    assert_equal "Connection is closed", error.message
  end

  # nghttp3 is still using the connection while it runs a callback: closing
  # it there, or reading into it again, is refused, and the error comes out
  # of read_stream as a callback's exception does.
  def test_close_and_read_stream_are_refused_inside_a_callback
    [
      [:close, ->(conn, _stream_id) { conn.close }, :on_begin_headers],
      [:read_stream, ->(conn, stream_id) { conn.read_stream(stream_id, "") }, :on_recv_header]
    ].each do |name, call, callback|
      server = nil
      callbacks = HTTP3::Nghttp3::Callbacks.new.public_send(callback) { |stream_id, *| call.call(server, stream_id) }
      server = new_server(callbacks)
      client = new_client
      client.submit_request(REQUEST_STREAM, request_headers)

      error = assert_raises(HTTP3::Nghttp3::InvalidStateError) { transfer(client, server) }
      assert_equal "##{name} cannot be called from inside a callback of this connection", error.message
      refute_predicate server, :closed?
      server.close
      assert_predicate server, :closed?
    end
  end

  # Once read_stream has failed, nghttp3 allows nothing but deleting the
  # connection, so only #close goes through, and what calls no nghttp3.
  def test_only_close_after_the_connection_failed
    callbacks = HTTP3::Nghttp3::Callbacks.new.on_begin_headers { |_stream_id| raise "boom" }
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers)
    server = new_server(callbacks)
    assert_raises(RuntimeError) { transfer(client, server) }

    [
      -> { server.read_stream(REQUEST_STREAM, "") },
      -> { server.writev_stream },
      -> { server.submit_response(REQUEST_STREAM, [HTTP3::Nghttp3::NV.new(":status", "200")]) }
    ].each do |call|
      error = assert_raises(HTTP3::Nghttp3::InvalidStateError) { call.call }
      assert_equal "the connection has failed; only #close is allowed", error.message
    end
    assert_empty server.pending_data(REQUEST_STREAM)
    refute_predicate server, :closed?
    server.close
    assert_predicate server, :closed?
  end

  def test_writev_stream_is_refused_inside_a_body_block
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers(method: "POST")) { |_stream_id| client.writev_stream }

    error = assert_raises(HTTP3::Nghttp3::InvalidStateError) { drain(client) }
    assert_equal "#writev_stream cannot be called from inside a callback of this connection", error.message
  end

  # As ngtcp2's examples do, a server may answer from inside read_stream.
  def test_submit_response_inside_on_end_stream
    server = nil
    callbacks = HTTP3::Nghttp3::Callbacks.new.on_end_stream do |stream_id|
      server.submit_response(stream_id, [HTTP3::Nghttp3::NV.new(":status", "204")])
    end
    server = new_server(callbacks)
    received = []
    client = new_client(HTTP3::Nghttp3::Callbacks.new.on_recv_header { |_stream_id, name, value, _flags| received << [name, value] })
    client.submit_request(REQUEST_STREAM, request_headers)

    transfer(client, server)
    transfer(server, client)
    assert_equal [[":status", "204"]], received
  end

  # read_stream locks the data while nghttp3 reads it, so that a callback
  # cannot change it, and unlocks it after; frozen data needs no lock.
  def test_read_stream_locks_data_that_is_not_frozen
    data = nil
    callbacks = HTTP3::Nghttp3::Callbacks.new.on_begin_headers { |_stream_id| data << "x" }
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers)
    server = new_server(callbacks)
    error = assert_raises(RuntimeError) do
      while (out = client.writev_stream)
        data = out[:data]
        server.read_stream(out[:stream_id], data, fin: out[:fin])
        client.add_write_offset(out[:stream_id], data.bytesize)
      end
    end
    assert_match(/temporarily locked/, error.message)
    data << "x"
  end

  def test_read_stream_takes_frozen_data
    headers = []
    callbacks = HTTP3::Nghttp3::Callbacks.new.on_recv_header { |_stream_id, name, value, _flags| headers << [name, value] }
    client = new_client
    client.submit_request(REQUEST_STREAM, request_headers)
    server = new_server(callbacks)
    while (out = client.writev_stream)
      server.read_stream(out[:stream_id], out[:data].freeze, fin: out[:fin])
      client.add_write_offset(out[:stream_id], out[:data].bytesize)
    end
    assert_includes headers, [":method", "GET"]
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
