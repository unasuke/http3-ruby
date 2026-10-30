# frozen_string_literal: true

require "test_helper"
require "socket"

# The limits on the response bytes an HTTP3::Session queues for nghttp3, on
# a QUIC loopback as in TestSessionLimits: a QUIC::Connection::Server in a
# thread with a Session attached, and H3TestClient in the main thread,
# which stops reading some of the responses.
class TestSendLimits < Minitest::Test
  include TestCertificates

  CHUNK = 1_024
  # Much more than the client's window lets the server send unread.
  BODY = 2 * 1_024 * 1_024
  STREAM_LIMIT = 4_096
  CONNECTION_LIMIT = 16_384

  def setup
    # Generated here, before the server thread could race the main thread
    # to it.
    credentials
    @sock = UDPSocket.new(Socket::AF_INET)
    @sock.bind("127.0.0.1", 0)
    @stop = false
    # The limits the server thread fills with; a test may change them
    # before its requests.
    @connection_limit = CONNECTION_LIMIT
    @total = nil
    # What the server thread saw: the most bytes unsent at the end of a
    # turn, and whether wants_fill? said yes with the limits used up.
    @max_unsent = 0
    @wanted_when_full = false
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

  # More streams than the connection's limit has room for stop reading:
  # what they hold unsent stays within the limit, by less than a chunk.
  def test_streams_not_read_hold_at_most_the_connection_limit
    ids = Array.new(8) { request_paused }
    pump_for(1.5)
    assert_operator @max_unsent, :>=, CONNECTION_LIMIT - CHUNK
    assert_operator @max_unsent, :<, CONNECTION_LIMIT + CHUNK
    refute @wanted_when_full, "wants_fill? should be false with the connection's limit used up"
    ids.each { |id| refute_predicate @client.response(id), :finished? }
  end

  def test_a_stream_read_again_gets_all_of_its_body
    paused = request_paused
    resumed = request_paused
    pump_for(0.5)

    @client.resume(resumed)
    @client.pump_until(timeout: 30) { @client.response(resumed).finished? }
    assert_equal BODY, @client.response(resumed).body.bytesize
    refute_predicate @client.response(paused), :finished?
  end

  # room bounds what is queued as the connection's limit does.
  def test_room_bounds_what_is_queued
    @connection_limit = nil
    @total = 8_192
    Array.new(4) { request_paused }
    pump_for(1.5)
    assert_operator @max_unsent, :>=, @total - CHUNK
    assert_operator @max_unsent, :<, @total + CHUNK
  end

  private

  # A request for a big body whose response is not read. It does not wait
  # for the status: a few such streams use up the client's window for the
  # whole connection, and the HEADERS of the next would not come.
  def request_paused
    @client.request(:get, "/big").tap { |id| @client.pause(id) }
  end

  def pump_for(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    @client.pump while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  end

  def serve
    conn = QUIC::Connection::Server.accept(
      sock: @sock,
      certificate_path: credentials.certificate_path,
      private_key_path: credentials.private_key_path,
      settings: QUIC::Settings.default.with(alpn: ["h3"])
    )
    session = HTTP3::Session.attach(conn, max_request_body: 1_024, max_field_section_size: 4_096)
    until @stop
      conn.pump_once(timeout: 0.002)
      session.take_refusals.each { |request, _status| session.respond(request, big_response) }
      while (request = session.next_request)
        session.respond(request, big_response)
        session.finish(request.stream_id)
      end
      room = @total && @total - session.unsent_total
      session.fill_bodies(STREAM_LIMIT, connection_limit: @connection_limit, room: room)
      unsent = session.unsent_total
      @max_unsent = unsent if unsent > @max_unsent
      if @connection_limit && unsent >= @connection_limit &&
          session.wants_fill?(STREAM_LIMIT, connection_limit: @connection_limit)
        @wanted_when_full = true
      end
      session.release_closed
      error = session.take_error and raise error
    end
  rescue QUIC::Error::Closed, IOError, Errno::ECONNREFUSED
    # The client went away, or teardown closed the socket.
  end

  def big_response
    enum = Enumerator.new { |y| (BODY / CHUNK).times { y << ("x" * CHUNK) } }
    HTTP3::Response.new(status: 200, headers: [], body: HTTP3::Body::Chunks.new(enum: enum, rack_body: nil))
  end
end
