# frozen_string_literal: true

require "test_helper"
require "digest"
require "socket"

# HTTP3::Session writing request bodies over request_body_buffer_size to
# temporary files, on a QUIC loopback as in TestSessionLimits: a
# QUIC::Connection::Server in a thread with a Session attached, with small
# limits, and H3TestClient in the main thread.
class TestSessionSpool < Minitest::Test
  include TestCertificates

  MAX_REQUEST_BODY = 4_000
  MAX_FIELD_SECTION_SIZE = 1_000
  REQUEST_BODY_BUFFER_SIZE = 1_000
  # What /big answers with: far more than the client's window lets the
  # server send unread.
  BIG = 1_024 * 1_024

  # The attach options; a test may change them in LIMITS.
  DEFAULTS = {
    max_connection_request_buffer: 100_000,
    max_connection_request_spool: 100_000,
    max_connection_request_spool_files: 16
  }.freeze

  LIMITS = {
    # Room in the spool for one request at max_request_body, not for two.
    "test_spooled_bytes_come_back_for_the_next_request" => {max_connection_request_spool: MAX_REQUEST_BODY},
    "test_503_over_the_spool" => {max_connection_request_spool: MAX_REQUEST_BODY},
    "test_reset_while_spooling_gives_everything_back" => {max_connection_request_spool: MAX_REQUEST_BODY},
    "test_413_while_spooling_gives_everything_back" => {max_connection_request_spool: MAX_REQUEST_BODY},
    "test_spool_counts_until_finish" =>
      {max_connection_request_spool: MAX_REQUEST_BODY, max_connection_request_spool_files: 2},
    "test_spool_counts_after_the_stream_closes_until_finish" => {max_connection_request_spool: MAX_REQUEST_BODY},
    "test_503_over_the_spool_files" => {max_connection_request_spool_files: 2},
    # Just the room in memory a request at the limits needs once its body
    # goes to a file.
    "test_request_at_the_limits_fits_the_least_memory" =>
      {max_connection_request_buffer: REQUEST_BODY_BUFFER_SIZE + MAX_FIELD_SECTION_SIZE}
  }.freeze

  # A Session whose temporary files cannot be made, as when the disk is
  # full.
  class FullDiskSession < HTTP3::Session
    private

    def open_spool
      raise Errno::ENOSPC, Dir.tmpdir
    end
  end

  def setup
    # Generated here, before the server thread could race the main thread
    # to it.
    credentials
    @limits = DEFAULTS.merge(LIMITS.fetch(name, {}))
    @session_class = (name == "test_503_when_no_file_can_be_made") ? FullDiskSession : HTTP3::Session
    # What the server thread saw: [class, external encoding, file name] of
    # each input, the inputs of /read-later and of /hold, and
    # take_spool_error's exceptions.
    @inputs = Thread::Queue.new
    @read_later = Thread::Queue.new
    @held_inputs = Thread::Queue.new
    @spool_errors = Thread::Queue.new
    # The streams of the /hold requests the server is to be done with.
    @release = Thread::Queue.new
    # The temporary files other tests may have left for the GC to close.
    @spool_baseline = all_spool_descriptors
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
  # server sends draws an ICMP port unreachable. join raises what the
  # server thread raised.
  def teardown
    @stop = true
    @server&.join(5)
    @client&.close
    @sock.close
  end

  def test_body_within_the_buffer_stays_in_memory
    response = post("/digest", "x" * REQUEST_BODY_BUFFER_SIZE)
    assert_equal 200, response.status
    klass, = @inputs.pop(timeout: 5)
    assert_equal StringIO, klass
  end

  # A body past the buffer goes to a file without a name, read back as the
  # bytes that came, whatever they are; the file is closed once the
  # response is done.
  def test_body_over_the_buffer_goes_to_a_file
    body = Random.new(4).bytes(MAX_REQUEST_BODY)
    response = post("/digest", body)
    assert_equal 200, response.status
    assert_equal "#{body.bytesize} #{Digest::SHA256.hexdigest(body)}", response.body
    klass, encoding, path = @inputs.pop(timeout: 5)
    assert_equal File, klass
    assert_equal Encoding::ASCII_8BIT, encoding
    assert path.end_with?(" (deleted)"), path
    assert_empty spool_descriptors
  end

  # The spool holds a request's bytes only until the server is done with
  # it (#finish): a second request at max_request_body fits after the
  # first.
  def test_spooled_bytes_come_back_for_the_next_request
    2.times { assert_equal 200, post("/digest", "x" * MAX_REQUEST_BODY).status }
  end

  def test_503_over_the_spool
    held = @client.request(:post, "/digest", body: "x" * MAX_REQUEST_BODY, fin: false)
    wait_for_spool_files(1)
    id = @client.request(:post, "/digest", body: "y" * 2_000, fin: false)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 503, @client.response(id).status

    @client.finish(held)
    @client.pump_until { @client.response(held).finished? }
    assert_equal 200, @client.response(held).status
  end

  # The files open count too, though the bytes have room: the third
  # request to spool gets 503, and once one of the others is done, the
  # next one gets through.
  def test_503_over_the_spool_files
    held = Array.new(2) { @client.request(:post, "/digest", body: "x" * 2_000, fin: false) }
    wait_for_spool_files(2)
    id = @client.request(:post, "/digest", body: "y" * 2_000, fin: false)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 503, @client.response(id).status

    @client.finish(held.first)
    @client.pump_until { @client.response(held.first).finished? }
    assert_equal 200, post("/digest", "z" * 2_000).status
  end

  def test_reset_while_spooling_gives_everything_back
    held = @client.request(:post, "/digest", body: "x" * 2_000, fin: false)
    wait_for_spool_files(1)
    @client.cancel(held)
    @client.pump_until { @client.closed?(held) }
    assert_empty spool_descriptors
    assert_equal 200, post("/digest", "x" * MAX_REQUEST_BODY).status
  end

  def test_413_while_spooling_gives_everything_back
    id = @client.request(:post, "/digest", body: "x" * (MAX_REQUEST_BODY + 1), fin: false)
    @client.pump_until { @client.response(id).finished? }
    assert_equal 413, @client.response(id).status
    @client.pump_until { @client.closed?(id) }
    assert_empty spool_descriptors
    assert_equal 200, post("/digest", "x" * MAX_REQUEST_BODY).status
  end

  # A request handed out keeps its file counted, with its bytes, until
  # finish, which the server here calls once the response body is done, so
  # that the spool bounds the disk the files take: while the client reads
  # none of /big, a second request finds no room in the spool (though a
  # file would fit) and gets 503; once /big has been read, the next one
  # gets through.
  def test_spool_counts_until_finish
    big = @client.request(:post, "/big", body: "x" * MAX_REQUEST_BODY)
    @client.pause(big)
    wait_for_spool_files(1)
    assert_equal 503, post("/digest", "y" * 2_000).status
    refute_predicate @client.response(big), :finished?
    assert_equal 1, spool_descriptors.size

    @client.resume(big)
    @client.pump_until(timeout: 30) { @client.response(big).finished? }
    assert_equal BIG, @client.response(big).body.bytesize
    @client.pump_until { spool_descriptors.empty? }
    assert_equal 200, post("/digest", "y" * MAX_REQUEST_BODY).status
  end

  # The Session leaves the input open, so a body may read it as it goes;
  # the server here closes it once the body is done.
  def test_body_reads_the_spooled_input_as_it_goes
    body = "later" * 700
    response = post("/read-later", body)
    assert_equal body, response.body
    input = @read_later.pop(timeout: 5)
    @client.pump_until { input.closed? }
    assert_predicate input, :closed?
  end

  # What a request handed out holds counts until finish, even once its
  # stream has closed, and the Session leaves its input open for the
  # caller to close.
  def test_spool_counts_after_the_stream_closes_until_finish
    held = @client.request(:post, "/hold", body: "x" * MAX_REQUEST_BODY)
    @client.pump_until { @client.response(held).finished? }
    @client.pump_until { @client.closed?(held) }
    input = @held_inputs.pop(timeout: 5)
    pump_for(0.2)
    assert_equal 503, post("/digest", "y" * 2_000).status
    refute_predicate input, :closed?

    @release << held
    @client.pump_until { input.closed? }
    assert_equal 200, post("/digest", "y" * MAX_REQUEST_BODY).status
  end

  # A file that cannot be made gets the request 503; take_spool_error
  # tells why, once, and the connection goes on.
  def test_503_when_no_file_can_be_made
    assert_equal 503, post("/digest", "x" * 2_000).status
    error = @spool_errors.pop(timeout: 5)
    assert_kind_of Errno::ENOSPC, error
    assert_equal 200, post("/digest", "x" * 100).status
    assert_equal 503, post("/digest", "x" * 2_000).status
    assert_kind_of Errno::ENOSPC, @spool_errors.pop(timeout: 5)
    assert_nil @spool_errors.pop(timeout: 0.2)
  end

  # With max_connection_request_buffer just at the least it may be, a
  # request at both limits gets through: its body is in memory only up to
  # request_body_buffer_size.
  def test_request_at_the_limits_fits_the_least_memory
    # :method, :scheme, :authority and :path take about 160 bytes as RFC
    # 9114 section 4.2.2 counts them.
    field = "x" * (MAX_FIELD_SECTION_SIZE - 260)
    id = @client.request(:post, "/digest", body: "x" * MAX_REQUEST_BODY, headers: {"x-large" => field})
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
  end

  private

  def post(path, body)
    id = @client.request(:post, path, body: body)
    @client.pump_until { @client.response(id).finished? }
    @client.response(id)
  end

  # Pump until the server has n temporary files open, and a while more for
  # the rest of what was sent to arrive.
  def wait_for_spool_files(n)
    @client.pump_until { spool_descriptors.size == n }
    pump_for(0.2)
  end

  # Pump for a while, giving the server the chance to answer early.
  def pump_for(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    @client.pump while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  end

  # The descriptors of this process open on temporary files without a name
  # in Dir.tmpdir (Linux), but those open when the test began.
  def spool_descriptors
    all_spool_descriptors - @spool_baseline
  end

  def all_spool_descriptors
    Dir.children("/proc/self/fd").filter_map do |fd|
      path = File.readlink("/proc/self/fd/#{fd}")
      path if path.start_with?(Dir.tmpdir) && path.end_with?(" (deleted)")
    rescue Errno::ENOENT
      nil
    end
  end

  def serve
    conn = QUIC::Connection::Server.accept(
      sock: @sock,
      certificate_path: credentials.certificate_path,
      private_key_path: credentials.private_key_path,
      settings: QUIC::Settings.default.with(alpn: ["h3"])
    )
    session = @session_class.attach(
      conn, max_request_body: MAX_REQUEST_BODY, max_field_section_size: MAX_FIELD_SECTION_SIZE,
      request_body_buffer_size: REQUEST_BODY_BUFFER_SIZE, **@limits
    )
    # stream_id => the input of each request handed out and not finished,
    # and of the /hold ones among them
    @handed = {}
    @held = {}
    until @stop
      conn.pump_once(timeout: 0.002)
      session.take_refusals.each { |request, status| session.respond(request, response_to(request, status)) }
      while (request = session.next_request)
        answer(session, request)
      end
      until @release.empty?
        id = @release.pop
        @held.delete(id)
        @handed.delete(id).close
        session.finish(id)
      end
      session.fill_bodies(65_536)
      session.release_closed
      error = session.take_error and raise error
      error = session.take_spool_error and @spool_errors << error
    end
  rescue QUIC::Error::Closed, IOError, Errno::ECONNREFUSED
    # The client went away, or teardown closed the socket.
  ensure
    # The files of the requests still under way, such as /big's.
    @handed&.each_value(&:close)
    session&.release_all
  end

  # Answer request; once its response body is done, close its input and
  # finish it, as the server's workers do. A /hold request is answered at
  # once, and left for the test to let go of (@release).
  def answer(session, request)
    @handed[request.stream_id] = request.input
    done = lambda do
      @handed.delete(request.stream_id).close
      session.finish(request.stream_id)
    end
    response = response_to(request, nil)
    if request.headers.assoc(":path").last == "/hold"
      session.respond(request, HTTP3::Response.new(status: 200, headers: [], body: nil))
      @held[request.stream_id] = request.input
      @held_inputs << request.input
      return
    end
    enum = response.body.enum
    ending = Enumerator.new do |y|
      loop { y << enum.next }
      done.call
    end
    session.respond(request, response.with(body: response.body.with(enum: ending)))
  end

  # /digest answers with the size and SHA-256 of the body, read 256 bytes
  # at a time; /big with far more than the client reads; /read-later with
  # the body, read only as the response is sent; /hold with nothing (see
  # #answer).
  def response_to(request, status)
    return HTTP3::Response.new(status: status, headers: [], body: nil) if status

    input = request.input
    @inputs << [input.class, input.external_encoding, input.is_a?(File) ? File.readlink("/proc/self/fd/#{input.fileno}") : nil]
    enum = case request.headers.assoc(":path").last
    when "/digest"
      digest = Digest::SHA256.new
      size = 0
      while (chunk = input.read(256))
        digest << chunk
        size += chunk.bytesize
      end
      ["#{size} #{digest.hexdigest}"].each
    when "/big" then Enumerator.new { |y| (BIG / 1_024).times { y << ("x" * 1_024) } }
    when "/read-later"
      @read_later << input
      Enumerator.new { |y| y << input.read }
    when "/hold" then [].each
    end
    HTTP3::Response.new(status: 200, headers: [], body: HTTP3::Body::Chunks.new(enum: enum, rack_body: nil))
  end
end
