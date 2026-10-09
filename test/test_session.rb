# frozen_string_literal: true

require "test_helper"
require "socket"

# HTTP3::Session on a QUIC loopback, without HTTP3::Server: a
# QUIC::Connection::Server in a thread with a Session attached, answering
# with the Session API directly, and H3TestClient in the main thread.
class TestSession < Minitest::Test
  include TestCertificates

  MAX_REQUEST_BODY = 1_048_576

  def setup
    # Generated here, before the server thread could race the main thread
    # to it.
    credentials
    @sock = UDPSocket.new(Socket::AF_INET)
    @sock.bind("127.0.0.1", 0)
    @stop = false
    @server = Thread.new do
      Thread.current.report_on_exception = false
      serve
    end
    @client = H3TestClient::QuicTransport.connect(@sock.addr[1], ca_file: credentials.ca_file)
  end

  # The server stops first: once the client's socket is gone, whatever the
  # server sends draws an ICMP port unreachable.
  def teardown
    @stop = true
    @server&.join(5)
    @client&.close
    @sock.close
  end

  def test_get
    id = @client.request(:get, "/hello")
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
    assert_equal "text/plain", @client.response(id).headers["content-type"]
    assert_equal "hello", @client.response(id).body
  end

  def test_head_has_no_body
    id = @client.request(:head, "/hello")
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
    assert_empty @client.response(id).body.to_s
  end

  def test_post_body_comes_back
    payload = Random.new(1).bytes(200_000)
    id = @client.request(:post, "/echo", body: payload)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
    assert_equal payload.b, @client.response(id).body.b
  end

  def test_post_over_max_request_body_gets_413
    id = @client.request(:post, "/echo", body: "x" * (MAX_REQUEST_BODY + 1))
    @client.pump_until { @client.response(id).finished? }
    assert_equal 413, @client.response(id).status
  end

  # More than initial_max_streams_bidi (100): the session has to give the
  # client new streams as the old ones close.
  def test_250_requests_in_a_row_on_one_connection
    250.times do |i|
      id = @client.request(:get, "/hello")
      @client.pump_until { @client.response(id).finished? }
      assert_equal 200, @client.response(id).status, "request #{i}"
    end
  end

  private

  # Answer every request: /hello with "hello" (no body for HEAD), /echo
  # with the request body, sent in chunks.
  def serve
    conn = QUIC::Connection::Server.accept(
      sock: @sock,
      certificate_path: credentials.certificate_path,
      private_key_path: credentials.private_key_path,
      settings: QUIC::Settings.default.with(alpn: ["h3"])
    )
    session = HTTP3::Session.attach(conn, max_request_body: MAX_REQUEST_BODY, max_field_section_size: 65_536)
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

    method = request.headers.assoc(":method").last
    case request.headers.assoc(":path").last
    when "/hello"
      body = (method == "HEAD") ? nil : HTTP3::Body::Chunks.new(enum: ["hel", "lo"].each, rack_body: nil)
      HTTP3::Response.new(status: 200, headers: [["content-type", "text/plain"]], body: body)
    when "/echo"
      chunks = request.body.each_char.each_slice(16_384).map(&:join)
      HTTP3::Response.new(status: 200, headers: [], body: HTTP3::Body::Chunks.new(enum: chunks.each, rack_body: nil))
    else
      HTTP3::Response.new(status: 404, headers: [], body: nil)
    end
  end
end
