# frozen_string_literal: true

require "test_helper"
require "socket"

# HTTP3::Session on a connection whose HTTP/3 fails. The server runs in a
# child process: nghttp3 is built with its assertions, which abort the
# whole process, and a child that aborts fails one test instead of ending
# the run.
class TestSessionFailures < Minitest::Test
  include TestCertificates

  TIMEOUT = 10

  # What the child reports once the Session has let go of a failed
  # connection.
  FAILED = "shutdown_notice returned self; " \
    "submit_response raised InvalidStateError: the HTTP/3 connection has failed"

  # A client that lets the server open two unidirectional streams, fewer
  # than the three HTTP/3 needs (RFC 9114 section 6.2): the server cannot
  # set HTTP/3 up, and what the Session is asked afterwards must not reach
  # the half-made nghttp3 connection.
  def test_connection_whose_streams_cannot_be_opened
    outcome = serve_in_child do |port|
      client = QUIC::Connection::Client.new(
        host: "127.0.0.1", port: port, address_family: :inet,
        transport_params: QUIC::TransportParams.default.with(initial_max_streams_uni: 2),
        settings: QUIC::Settings.default.with(alpn: ["h3"], ca_file: credentials.ca_file)
      )
      sock = UDPSocket.new(Socket::AF_INET)
      sock.connect("127.0.0.1", port)
      client.bind(sock).run
      client
    end
    assert_equal FAILED, outcome
  end

  # A second control stream is H3_STREAM_CREATION_ERROR (RFC 9114 section
  # 6.2.1), which nghttp3 reports from read_stream. nghttp3 allows nothing
  # but deleting the connection after that, so the Session lets go of it.
  def test_connection_nghttp3_reported_an_error_on
    outcome = serve_in_child do |port|
      client = H3TestClient::QuicTransport.connect(port, ca_file: credentials.ca_file)
      # The client's own control stream, written by nghttp3 when pumped,
      client.pump
      # and another: a stream type of 0x00 (control), then SETTINGS with no
      # settings.
      client.quic.open_uni_stream.write("\x00\x04\x00".b)
      client.quic
    end
    assert_equal FAILED, outcome
  end

  # A Session method called from inside a callback of the Session would
  # call into nghttp3, or delete it, while nghttp3 runs: it is refused.
  # The refusal is the callback's exception, which fails the connection
  # and waits in #take_error.
  def test_session_method_called_from_inside_a_callback
    prepare = ->(session) { session.define_singleton_method(:on_end_stream) { |_id| shutdown_notice } }
    outcome = serve_in_child(prepare) do |port|
      client = H3TestClient::QuicTransport.connect(port, ca_file: credentials.ca_file)
      client.request(:get, "/")
      # Hand the request to QUIC; the QUIC connection alone is pumped next.
      client.pump
      client.quic
    end
    assert_equal "#{FAILED}; take_error returned HTTP3::Nghttp3::InvalidStateError: " \
      "#shutdown_notice cannot be called from inside a callback of this session", outcome
  end

  private

  # Accept one connection in a child process, attach a Session to it, give
  # it to prepare, if any, and pump until the connection fails; then call
  # #shutdown_notice and #submit_response, and return what they did, and
  # what #take_error returned if not nil. The block is the client: it gets
  # the port and returns a connection, which is pumped until the child has
  # exited.
  def serve_in_child(prepare = nil)
    credentials
    server_sock = UDPSocket.new(Socket::AF_INET)
    server_sock.bind("127.0.0.1", 0)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(fail_session(server_sock, prepare))
      writer.close
      # Not exit: the parent's at_exit hooks (Minitest's included) must not
      # run here.
      exit!(0)
    end
    writer.close
    client = yield server_sock.addr[1]
    status = pump_until_exit(client, pid)
    pid = nil
    assert_predicate status, :success?, "the server process ended with #{status.inspect}"
    reader.read
  ensure
    if pid
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
    client&.bound_socket&.close
    reader&.close
    server_sock&.close
  end

  def pump_until_exit(client, pid)
    deadline = now + TIMEOUT
    loop do
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      flunk "the server process did not exit within #{TIMEOUT} seconds" if now > deadline

      begin
        client.pump_once(timeout: 0.01)
      rescue QUIC::Error, SystemCallError
        # The connection has failed; the child goes on without it.
        sleep 0.01
      end
    end
  end

  # In the child.
  def fail_session(sock, prepare)
    conn = QUIC::Connection::Server.accept(
      sock: sock, certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path,
      settings: QUIC::Settings.default.with(alpn: ["h3"])
    )
    session = HTTP3::Session.attach(conn, max_request_body: 1_024, max_field_section_size: 1_024)
    prepare&.call(session)
    deadline = now + TIMEOUT
    begin
      conn.pump_once(timeout: 0.01) until now > deadline
      return "the connection did not fail"
    rescue QUIC::Error
      # What the test is after.
    end
    outcome = "shutdown_notice returned #{session.shutdown_notice.equal?(session) ? "self" : "something else"}"
    begin
      session.submit_response(0, [[":status", "200"]], false)
      outcome += "; submit_response did not raise"
    rescue HTTP3::Nghttp3::InvalidStateError => e
      outcome += "; submit_response raised InvalidStateError: #{e.message}"
    end
    error = session.take_error
    error ? "#{outcome}; take_error returned #{error.class}: #{error.message}" : outcome
  rescue Exception => e # rubocop:disable Lint/RescueException
    e.full_message
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
