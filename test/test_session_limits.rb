# frozen_string_literal: true

require "test_helper"
require "socket"

# The limits HTTP3::Session puts on requests still coming in, on a QUIC
# loopback as in TestSession: a QUIC::Connection::Server in a thread with a
# Session attached, with small limits, and H3TestClient in the main thread.
class TestSessionLimits < Minitest::Test
  include TestCertificates

  MAX_REQUEST_BODY = 4_000
  MAX_FIELD_SECTION_SIZE = 1_000
  # Room for one request at both limits above, not for two.
  MAX_CONNECTION_REQUEST_BUFFER = 5_000

  def setup
    # Generated here, before the server thread could race the main thread
    # to it.
    credentials
    @sock = UDPSocket.new(Socket::AF_INET)
    @sock.bind("127.0.0.1", 0)
    @stop = false
    # [stream_id, app_error_code] of each Session#abort_stream
    @aborts = Thread::Queue.new
    @server = Thread.new do
      Thread.current.report_on_exception = false
      serve
    end
    @client = H3TestClient::QuicTransport.connect(@sock.addr[1], ca_file: credentials.ca_file)
  end

  # The server stops first: once the client's socket is gone, whatever the
  # server sends draws an ICMP port unreachable. join raises what the
  # server thread raised.
  def teardown
    @stop = true
    @server&.join(5)
    @client&.close
    @sock.close
  end

  # 413 goes out as soon as the body passes max_request_body, while the
  # client is still sending it, and the server reads no more of it: its
  # STOP_SENDING has the client reset its side, and the stream closes.
  def test_413_comes_before_the_body_ends
    id = @client.request(:post, "/echo", body: "x" * (MAX_REQUEST_BODY + 1), fin: false)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 413, @client.response(id).status
    @client.pump_until { @client.closed?(id) }
    assert_get_hello
  end

  def test_431_comes_before_the_request_ends
    id = @client.request(:get, "/hello", headers: {"x-large" => "x" * MAX_FIELD_SECTION_SIZE}, fin: false)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 431, @client.response(id).status
    @client.pump_until { @client.closed?(id) }
    assert_get_hello
  end

  # A body within the limit waits for its FIN and then reaches the
  # application whole.
  def test_body_within_the_limit_reaches_the_application
    id = @client.request(:post, "/echo", body: "x" * MAX_REQUEST_BODY, fin: false)
    pump_for(0.2)
    refute @client.response(id).finished?
    @client.finish(id)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
    assert_equal MAX_REQUEST_BODY, @client.response(id).body.bytesize
  end

  # A request held open takes most of the connection's buffer; the next
  # one gets 503 once its body would pass it. The first one still
  # completes.
  def test_503_over_the_connection_buffer
    held = @client.request(:post, "/echo", body: "x" * MAX_REQUEST_BODY, fin: false)
    pump_for(0.2)
    id = @client.request(:post, "/echo", body: "y" * 1_000, fin: false)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 503, @client.response(id).status
    assert_empty @client.response(id).headers.to_h
    @client.pump_until { @client.closed?(id) }

    @client.finish(held)
    @client.pump_until { @client.response(held).finished? }
    assert_equal 200, @client.response(held).status
    assert_equal MAX_REQUEST_BODY, @client.response(held).body.bytesize
  end

  # Header fields count too: 503 can come while they arrive.
  def test_503_while_the_headers_come_in
    @client.request(:post, "/echo", body: "x" * MAX_REQUEST_BODY, fin: false)
    pump_for(0.2)
    id = @client.request(:get, "/hello", headers: {"x-large" => "x" * 750}, fin: false)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 503, @client.response(id).status
  end

  # A request the client gives up on gives its bytes back: a request at
  # the limits gets through after it.
  def test_cancel_gives_the_bytes_back
    held = @client.request(:post, "/echo", body: "x" * MAX_REQUEST_BODY, fin: false)
    pump_for(0.2)
    @client.cancel(held)
    @client.pump_until { @client.closed?(held) }

    id = @client.request(:post, "/echo", body: "x" * MAX_REQUEST_BODY)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
  end

  # A request the client resets before its end without STOP_SENDING: the
  # server resets its side too, with H3_REQUEST_INCOMPLETE (RFC 9114
  # section 4.1), so that the stream closes, and the bytes come back.
  # quic gives the client no error code of a reset, so the server records
  # the one it sent.
  def test_reset_before_the_end_closes_the_stream
    held = @client.request(:post, "/echo", body: "x" * MAX_REQUEST_BODY, fin: false)
    pump_for(0.2)
    @client.cancel(held, stop_sending: false)
    @client.pump_until { @client.closed?(held) }
    assert_equal [held, HTTP3::Nghttp3::H3_REQUEST_INCOMPLETE], @aborts.pop(timeout: 5)

    id = @client.request(:post, "/echo", body: "x" * MAX_REQUEST_BODY)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
  end

  private

  # Pump for a while, giving the server the chance to answer early.
  def pump_for(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    @client.pump while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  end

  def assert_get_hello
    id = @client.request(:get, "/hello")
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
    assert_equal "hello", @client.response(id).body
  end

  # Answer every request: /hello with "hello", /echo with the request body.
  def serve
    conn = QUIC::Connection::Server.accept(
      sock: @sock,
      certificate_path: credentials.certificate_path,
      private_key_path: credentials.private_key_path,
      settings: QUIC::Settings.default.with(alpn: ["h3"])
    )
    session = HTTP3::Session.attach(
      conn, max_request_body: MAX_REQUEST_BODY, max_field_section_size: MAX_FIELD_SECTION_SIZE,
      max_connection_request_buffer: MAX_CONNECTION_REQUEST_BUFFER, shared_buffer: HTTP3::Session.shared_buffer(1_000_000)
    )
    aborts = @aborts
    session.define_singleton_method(:abort_stream) do |id, code|
      aborts << [id, code]
      super(id, code)
    end
    until @stop
      conn.pump_once(timeout: 0.002)
      session.take_requests.each { |request, status| session.respond(request, response_to(request, status)) }
      session.fill_bodies(65_536)
      session.release_closed
      error = session.take_error and raise error
    end
  rescue QUIC::Error::Closed, IOError, Errno::ECONNREFUSED
    # The client went away, or teardown closed the socket.
  end

  def response_to(request, status)
    return HTTP3::Response.new(status: status, headers: [], body: nil) if status

    body = (request.headers.assoc(":path").last == "/hello") ? "hello" : request.body
    HTTP3::Response.new(status: 200, headers: [], body: HTTP3::Body::Chunks.new(enum: [body].each, rack_body: nil))
  end
end
