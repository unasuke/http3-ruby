# frozen_string_literal: true

require "test_helper"
require "socket"

# How an HTTP3::Session tells that a response waits on its client
# (response_stalled_since), on a QUIC loopback as in TestSendLimits: a
# QUIC::Connection::Server in a thread with a Session attached, and
# H3TestClient in the main thread, which stops reading some of the
# responses. Every turn, the server thread samples response_stalled_since of
# the streams the test watches.
class TestResponseTimeout < Minitest::Test
  include TestCertificates

  CHUNK = 16_384
  # Much more than the client's window lets the server send unread.
  BIG = 2 * 1_024 * 1_024

  Sample = Data.define(:at, :id, :since)

  def setup
    # Generated here, before the server thread could race the main thread
    # to it.
    credentials
    @dir = Dir.mktmpdir
    @file_path = File.join(File.realpath(@dir), "file")
    @sock = UDPSocket.new(Socket::AF_INET)
    @sock.bind("127.0.0.1", 0)
    @stop = false
    # The streams whose response_stalled_since the server samples, and the
    # samples, taken by #samples.
    @watched = []
    @sample_queue = Thread::Queue.new
    @samples = []
    # The Body::Pipe of each /pipe, for the test to write.
    @pipes = Thread::Queue.new
    @server = Thread.new do
      Thread.current.report_on_exception = false
      serve
    end
  end

  # The server stops first: once the client's socket is gone, whatever the
  # server sends draws an ICMP port unreachable. join raises what the
  # server thread raised.
  def teardown
    @stop = true
    @server&.join(5)
    @client&.close
    @sock.close
    FileUtils.remove_entry(@dir)
  end

  # Not read, a body waits from when it was queued, and the time stays put;
  # read again, it moves; read in full, nothing waits.
  def test_a_body_not_read_stays_stalled_since_it_stopped
    @client = connect
    id = @client.request(:get, "/big").tap { |i| @client.pause(i) }
    @watched = [id]
    pump_for(1)
    stalled = samples(id).last(50)
    since = stalled.first.since
    refute_nil since
    assert stalled.all? { |sample| sample.since == since }, "response_stalled_since should stay put while not read"
    assert_operator stalled.last.at - since, :>=, 0.5

    @client.resume(id)
    @client.pump_until { @client.response(id).finished? }
    assert_equal BIG, @client.response(id).body.bytesize
    pump_for(0.2)
    read = samples(id).select { |sample| sample.at > stalled.last.at }
    assert read.any? { |sample| sample.since && sample.since > since }, "response_stalled_since should move as the body is read"
    assert_nil read.last.since
  end

  # A body with nothing to send, such as server-sent events between events,
  # does not wait on its client.
  def test_a_body_with_nothing_to_send_is_not_stalled
    @client = connect
    id = @client.request(:get, "/pipe")
    @watched = [id]
    pipe = pop_pipe
    pump_for(0.2)
    pipe.write("first")
    @client.pump_until { @client.response(id)&.body == "first" }
    pump_for(0.5)
    assert_nil samples(id).last.since

    finisher = Thread.new { pipe.finish }
    @client.pump_until { @client.response(id).finished? }
    finisher.join(5)
    assert_equal "first", @client.response(id).body
  ensure
    stop_thread(finisher)
  end

  # nghttp3 sends the responses of one priority one at a time, lowest
  # stream first. One waiting its turn behind another the client is reading
  # gets no acknowledgements of its own, but is not stalled: the
  # acknowledgements of the other move it. The client has windows wider
  # than the file, so that the file never waits on them, and pumps slowly,
  # so that it takes a while (about 200 KB a second): long enough that
  # /small, going by its own acknowledgements, would look stalled for
  # seconds.
  def test_a_response_waiting_its_turn_moves_with_the_connection
    File.binwrite(@file_path, "x" * (768 * 1_024))
    params = QUIC::TransportParams.default.with(
      initial_max_stream_data_bidi_local: 16 * 1_024 * 1_024, initial_max_data: 32 * 1_024 * 1_024
    )
    @client = connect(transport_params: params)
    file = @client.request(:get, "/file")
    small = @client.request(:get, "/small")
    @watched = [file, small]
    started = now
    until @client.response(file)&.finished?
      raise "timed out" if now - started > 60

      @client.pump
      sleep 0.005
    end
    took = now - started
    @client.pump_until { @client.response(small)&.finished? }
    waited = samples(small).select(&:since)

    assert_operator took, :>=, 1.5, "the file was read too fast to tell"
    assert_operator waited.last.at - waited.first.at, :>=, 1.5, "/small should have waited behind the file"
    # By its own acknowledgements, /small would look stalled for about as
    # long as the file took.
    stalest = waited.map { |sample| sample.at - sample.since }.max
    assert_operator stalest, :<, took / 2, "/small should not look stalled while the file is read"
  end

  private

  def connect(**options)
    H3TestClient::QuicTransport.connect(@sock.addr[1], ca_file: credentials.ca_file, **options)
  end

  # The samples of stream id taken so far, oldest first.
  def samples(id)
    @samples << @sample_queue.pop until @sample_queue.empty?
    @samples.select { |sample| sample.id == id }
  end

  def pop_pipe
    @client.pump_until { !@pipes.empty? }
    @pipes.pop
  end

  def pump_for(seconds)
    deadline = now + seconds
    @client.pump while now < deadline
  end

  # Stop thread, if it is still running, and wait for it, whatever it
  # ended with.
  def stop_thread(thread)
    thread&.kill
    thread&.join
  rescue Exception # rubocop:disable Lint/RescueException
    nil
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
      session.take_refusals.each { |request, status| session.respond(request, HTTP3::Response.new(status: status, headers: [], body: nil)) }
      while (request = session.next_request)
        session.respond(request, response_to(request))
        session.finish(request.stream_id)
      end
      session.fill_bodies(65_536)
      at = now
      @watched.each { |id| @sample_queue << Sample.new(at, id, session.response_stalled_since(id)) }
      session.release_closed
      error = session.take_error and raise error
    end
  rescue QUIC::Error::Closed, IOError, Errno::ECONNREFUSED
    # The client went away, or teardown closed the socket.
  end

  def response_to(request)
    body = case request.headers.assoc(":path").last
    when "/big"
      HTTP3::Body::Chunks.new(enum: Array.new(BIG / CHUNK) { "x" * CHUNK }.each, rack_body: nil)
    when "/small"
      HTTP3::Body::Chunks.new(enum: ["small"].each, rack_body: nil)
    when "/file"
      HTTP3::Body::File.new(io: File.open(@file_path, "rb"), offset: 0, length: File.size(@file_path), rack_body: nil)
    when "/pipe"
      HTTP3::Body::Pipe.new(capacity: 65_536, wake: -> {}).tap { |pipe| @pipes << pipe }
    end
    HTTP3::Response.new(status: 200, headers: [], body: body)
  end
end
