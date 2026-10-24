# frozen_string_literal: true

require "test_helper"
require "socket"

# HTTP3::Session on a QUIC loopback, without HTTP3::Server: a
# QUIC::Connection::Server in a thread with a Session attached, answering
# with the Session API directly, and H3TestClient in the main thread.
class TestSession < Minitest::Test
  include TestCertificates

  MAX_REQUEST_BODY = 1_048_576

  # What /file serves; more than one 16 KiB read of the C part.
  FILE_CONTENT = Random.new(2).bytes(100_000).freeze

  # An IO whose descriptor dup(2) refuses (EBADF), as it refuses any with
  # EMFILE once the process is out of descriptors.
  class UnattachableIO
    def fileno
      1_000_000
    end

    def close
      @closed = true
    end

    def closed?
      !!@closed
    end
  end

  def setup
    # Generated here, before the server thread could race the main thread
    # to it.
    credentials
    @dir = Dir.mktmpdir
    @file_path = File.join(File.realpath(@dir), "file")
    File.binwrite(@file_path, FILE_CONTENT)
    @file_responses = Thread::Queue.new
    @body_errors = Thread::Queue.new
    @second_responses = Thread::Queue.new
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
    FileUtils.remove_entry(@dir)
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

  # respond closes the Body::File's IO at once: the C part reads the file
  # through a duplicate of its own, which is close-on-exec and closed once
  # the whole file has been read, before the stream closes.
  def test_file_body_descriptors
    skip "needs /proc/self/fd" unless File.directory?("/proc/self/fd")
    id = @client.request(:get, "/file")
    @client.pump_until { @client.response(id).finished? }
    assert_equal FILE_CONTENT, @client.response(id).body.b
    after_respond = @file_responses.pop(timeout: 5)
    assert after_respond[:io_closed]
    assert_equal [true], after_respond[:close_on_exec]
    assert_empty descriptors_of(@file_path)
  end

  # A file body whose descriptor cannot be duplicated (EMFILE, say) aborts
  # its stream: respond yields the error instead of raising it, and the
  # connection goes on.
  def test_file_body_that_cannot_be_attached_aborts_the_stream
    id = @client.request(:get, "/unattachable")
    @client.pump_until { @client.aborted?(id) }
    assert_kind_of Errno::EBADF, @body_errors.pop(timeout: 5)

    id = @client.request(:get, "/hello")
    @client.pump_until { @client.response(id).finished? }
    assert_equal "hello", @client.response(id).body
  end

  # nghttp3 would send a second response after the first, so respond
  # refuses it.
  def test_second_response_is_refused
    id = @client.request(:get, "/twice")
    @client.pump_until { @client.response(id).finished? }
    assert_equal 204, @client.response(id).status
    error = @second_responses.pop(timeout: 5)
    assert_kind_of HTTP3::Nghttp3::InvalidStateError, error
    assert_equal "stream #{id} has been answered", error.message
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
      session.take_requests.each { |request, status| answer(session, request, status) }
      session.fill_bodies(65_536)
      session.release_closed
      error = session.take_error and raise error
    end
  rescue QUIC::Error::Closed, IOError, Errno::ECONNREFUSED
    # The client went away, or teardown closed the socket.
  end

  def answer(session, request, status)
    response = response_to(request, status)
    session.respond(request, response) { |error| @body_errors << error }
    if request.headers.assoc(":path").last == "/twice"
      begin
        session.respond(request, HTTP3::Response.new(status: 500, headers: [], body: nil))
      rescue => e
        @second_responses << e
      end
    end
    body = response.body
    return unless body.is_a?(HTTP3::Body::File) && body.io.is_a?(File) && File.directory?("/proc/self/fd")

    # What respond left open of the file, before any of it was read.
    @file_responses << {
      io_closed: body.io.closed?,
      close_on_exec: descriptors_of(@file_path).map { |fd| IO.for_fd(fd, autoclose: false).close_on_exec? }
    }
  end

  # The descriptors of this process open on path (Linux).
  def descriptors_of(path)
    Dir.children("/proc/self/fd").map(&:to_i).select do |fd|
      File.readlink("/proc/self/fd/#{fd}") == path
    rescue Errno::ENOENT
      false
    end
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
    when "/file"
      io = File.open(@file_path, "rb")
      body = HTTP3::Body::File.new(io: io, offset: 0, length: FILE_CONTENT.bytesize, rack_body: nil)
      HTTP3::Response.new(status: 200, headers: [], body: body)
    when "/twice"
      HTTP3::Response.new(status: 204, headers: [], body: nil)
    when "/unattachable"
      body = HTTP3::Body::File.new(io: UnattachableIO.new, offset: 0, length: 10, rack_body: nil)
      HTTP3::Response.new(status: 200, headers: [], body: body)
    else
      HTTP3::Response.new(status: 404, headers: [], body: nil)
    end
  end
end
