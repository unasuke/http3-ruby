# frozen_string_literal: true

require "test_helper"
require "socket"

# How an HTTP3::Session tells that a response waits on its client
# (response_stalled_since), and aborts one that has waited response_timeout
# (expire_responses), on a QUIC loopback as in TestSendLimits: a
# QUIC::Connection::Server in a thread with a Session attached, and
# H3TestClient in the main thread, which stops reading some of the
# responses. Every turn, the server thread samples response_stalled_since of
# the streams the test watches, and records what it aborts.
class TestResponseTimeout < Minitest::Test
  include TestCertificates

  CHUNK = 16_384
  # Much more than the client's window lets the server send unread.
  BIG = 2 * 1_024 * 1_024

  RESPONSE_TIMEOUT = 0.5

  # The response_timeout of the tests that have one.
  RESPONSE_TIMEOUTS = {
    "test_a_body_not_read_is_aborted" => RESPONSE_TIMEOUT,
    "test_an_ended_body_of_one_big_chunk_not_read_is_aborted" => RESPONSE_TIMEOUT,
    "test_a_file_not_read_is_aborted_and_its_descriptor_closed" => RESPONSE_TIMEOUT,
    "test_a_pipe_written_to_without_end_gets_stream_closed" => RESPONSE_TIMEOUT,
    "test_a_pipe_with_nothing_to_send_is_not_aborted" => RESPONSE_TIMEOUT,
    "test_a_client_that_reads_in_spurts_is_not_aborted" => RESPONSE_TIMEOUT,
    "test_a_body_its_window_holds_back_times_out_while_another_is_read" => RESPONSE_TIMEOUT,
    # Never reached but by the call the test asks for.
    "test_a_response_held_back_by_the_connection_limit_is_not_aborted" => 50
  }.freeze

  # The limits fill_bodies fills by, of the tests that need others than
  # these: a stream's, and the connection's.
  STREAM_LIMIT = 65_536
  LIMITS = {
    # The stream not read fills the connection's limit by itself.
    "test_a_response_held_back_by_the_connection_limit_is_not_aborted" => [16_384, 16_384]
  }.freeze

  Sample = Data.define(:at, :id, :since)
  # An abort_stream call: when, the stream, the code, and, just before,
  # response_stalled_since and the descriptors open on the file /file
  # serves.
  Abort = Data.define(:at, :id, :code, :since, :fds)
  # A turn in which expire_responses aborted some: how many, and what was
  # left right after, in the same turn: unsent_total, and the descriptors
  # open on the file /file serves.
  Expired = Data.define(:count, :unsent_total, :fds)

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
    @aborts = Thread::Queue.new
    @expired = Thread::Queue.new
    # Offsets from now to call expire_responses at, once each, as the test
    # asks (#expire_responses_at), and what each call returned.
    @expire_calls = Thread::Queue.new
    @expire_results = Thread::Queue.new
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

  # Not read, an array body is aborted with H3_REQUEST_CANCELLED once it
  # has waited response_timeout, not before, and what it had queued no
  # longer counts, from the same turn.
  def test_a_body_not_read_is_aborted
    @client = connect
    id = @client.request(:get, "/big").tap { |i| @client.pause(i) }
    aborted = pop(@aborts)
    assert_equal [id, HTTP3::Nghttp3::H3_REQUEST_CANCELLED], [aborted.id, aborted.code]
    assert_operator aborted.at - aborted.since, :>=, RESPONSE_TIMEOUT
    assert_operator aborted.at - aborted.since, :<, RESPONSE_TIMEOUT + 3
    assert_equal 0, pop(@expired).unsent_total
    @client.pump_until { @client.aborted?(id) }
  end

  # A body nghttp3 took in one go, and that has ended, is aborted all the
  # same: what is measured is what the client has acknowledged, not what
  # nghttp3 has taken.
  def test_an_ended_body_of_one_big_chunk_not_read_is_aborted
    @client = connect
    id = @client.request(:get, "/one-chunk").tap { |i| @client.pause(i) }
    aborted = pop(@aborts)
    assert_equal [id, HTTP3::Nghttp3::H3_REQUEST_CANCELLED], [aborted.id, aborted.code]
    assert_operator aborted.at - aborted.since, :>=, RESPONSE_TIMEOUT
  end

  # A file body not read is aborted, and its descriptor closed in the same
  # turn.
  def test_a_file_not_read_is_aborted_and_its_descriptor_closed
    skip "needs /proc/self/fd" unless File.directory?("/proc/self/fd")
    File.binwrite(@file_path, "x" * BIG)
    @client = connect
    id = @client.request(:get, "/file").tap { |i| @client.pause(i) }
    aborted = pop(@aborts)
    assert_equal [id, HTTP3::Nghttp3::H3_REQUEST_CANCELLED], [aborted.id, aborted.code]
    refute_empty aborted.fds, "the file should not have been read in full"
    assert_empty pop(@expired).fds
    @client.pump_until { @client.aborted?(id) }
  end

  # The writer of a Body::Pipe whose client reads none of it is stopped by
  # StreamClosed once the response is aborted, without the stream closing:
  # the client is left alone once the body has stopped on its window, and
  # acknowledges nothing, not even the reset.
  def test_a_pipe_written_to_without_end_gets_stream_closed
    @client = connect
    id = @client.request(:get, "/pipe").tap { |i| @client.pause(i) }
    pipe = pop_pipe
    writer = Thread.new do
      loop { pipe.write("x" * CHUNK) }
    rescue => e
      e
    end
    pump_for(0.3)
    assert writer.join(RESPONSE_TIMEOUT + 3), "the writer should have been stopped"
    assert_kind_of HTTP3::StreamClosed, writer.value
    assert_equal id, pop(@aborts).id
  ensure
    stop_thread(writer)
  end

  # A Body::Pipe with nothing to send for longer than response_timeout, as
  # server-sent events between events, is not aborted.
  def test_a_pipe_with_nothing_to_send_is_not_aborted
    @client = connect
    id = @client.request(:get, "/pipe")
    pipe = pop_pipe
    pipe.write("first")
    @client.pump_until { @client.response(id)&.body == "first" }
    pump_for(RESPONSE_TIMEOUT * 3)
    pipe.write("second")
    finisher = Thread.new { pipe.finish }
    @client.pump_until { @client.response(id).finished? }
    finisher.join(5)
    assert_equal "firstsecond", @client.response(id).body
    assert_empty @aborts
  ensure
    stop_thread(finisher)
  end

  # A stream the client's window holds back counts only its own
  # acknowledgements: another one on the connection that the client goes
  # on reading does not keep it from timing out. The client pumps slowly,
  # so that the other one is still being read by then.
  def test_a_body_its_window_holds_back_times_out_while_another_is_read
    @client = connect
    held = @client.request(:get, "/big").tap { |i| @client.pause(i) }
    read = @client.request(:get, "/bigger")
    started = now
    until !@aborts.empty? || now - started > RESPONSE_TIMEOUT + 5
      @client.pump
      sleep 0.005
    end
    refute_empty @aborts, "the stream held back should have timed out"
    assert @client.response(read)&.body.to_s.bytesize.positive?, "/bigger should have been read meanwhile"
    refute_predicate @client.response(read), :finished?, "/bigger should still be read when /big times out"
    aborted = @aborts.pop
    assert_equal held, aborted.id
    assert_operator aborted.at - aborted.since, :>=, RESPONSE_TIMEOUT
    assert_empty @aborts
  end

  # A client that reads in spurts, stopping for less than
  # response_timeout each time, gets all of the body, though that takes
  # more than twice response_timeout.
  def test_a_client_that_reads_in_spurts_is_not_aborted
    @client = connect
    id = @client.request(:get, "/bigger")
    started = now
    until @client.response(id)&.finished?
      raise "timed out" if now - started > 60

      @client.resume(id)
      pump_for(0.02)
      @client.pause(id)
      pump_for(RESPONSE_TIMEOUT * 0.4)
    end
    assert_operator now - started, :>=, RESPONSE_TIMEOUT * 2, "the body was read too fast to tell"
    assert_equal 4 * BIG, @client.response(id).body.bytesize
    assert_empty @aborts
  end

  # A response the connection's limit keeps from queuing anything does not
  # wait on its client: the stream holding the limit does, and it alone is
  # aborted, after which the other gets its body.
  def test_a_response_held_back_by_the_connection_limit_is_not_aborted
    @client = connect
    held = @client.request(:get, "/big").tap { |i| @client.pause(i) }
    pump_for(0.5)
    waiting = @client.request(:get, "/big")
    pump_for(0.5)
    assert_equal 1, expire_responses_at(100)
    assert_equal held, pop(@aborts).id
    @client.pump_until { @client.response(waiting)&.finished? }
    assert_equal BIG, @client.response(waiting).body.bytesize
    assert_empty @aborts
  end

  # Without response_timeout, nothing is aborted, however long it waits.
  def test_without_response_timeout_nothing_is_aborted
    @client = connect
    id = @client.request(:get, "/big").tap { |i| @client.pause(i) }
    pump_for(1)
    assert_equal 0, expire_responses_at(1_000)
    @client.resume(id)
    @client.pump_until { @client.response(id).finished? }
    assert_equal BIG, @client.response(id).body.bytesize
    assert_empty @aborts
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
    pop(@pipes)
  end

  # The next of what the server thread put in queue, pumping the client
  # until it comes.
  def pop(queue)
    @client.pump_until { !queue.empty? }
    queue.pop
  end

  # Have the server thread call expire_responses once, offset seconds from
  # now, and return what it returned.
  def expire_responses_at(offset)
    @expire_calls << offset
    pop(@expire_results)
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

  # The descriptors of this process open on path (Linux).
  def descriptors_of(path)
    Dir.children("/proc/self/fd").map(&:to_i).select do |fd|
      File.readlink("/proc/self/fd/#{fd}") == path
    rescue Errno::ENOENT
      false
    end
  end

  def serve
    conn = QUIC::Connection::Server.accept(
      sock: @sock,
      certificate_path: credentials.certificate_path,
      private_key_path: credentials.private_key_path,
      settings: QUIC::Settings.default.with(alpn: ["h3"])
    )
    session = HTTP3::Session.attach(conn, max_request_body: 1_024, max_field_section_size: 4_096,
      response_timeout: RESPONSE_TIMEOUTS[name])
    aborts = @aborts
    fds = -> { descriptors_of(@file_path) }
    session.define_singleton_method(:abort_stream) do |id, code|
      aborts << Abort.new(Process.clock_gettime(Process::CLOCK_MONOTONIC), id, code, response_stalled_since(id), fds.call)
      super(id, code)
    end
    stream_limit, connection_limit = LIMITS.fetch(name, [STREAM_LIMIT, nil])
    until @stop
      conn.pump_once(timeout: 0.002)
      session.take_refusals.each { |request, status| session.respond(request, HTTP3::Response.new(status: status, headers: [], body: nil)) }
      while (request = session.next_request)
        session.respond(request, response_to(request))
        session.finish(request.stream_id)
      end
      count = session.expire_responses(now)
      @expired << Expired.new(count, session.unsent_total, descriptors_of(@file_path)) if count.positive?
      @expire_results << session.expire_responses(now + @expire_calls.pop) until @expire_calls.empty?
      session.fill_bodies(stream_limit, connection_limit: connection_limit)
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
    when "/bigger"
      HTTP3::Body::Chunks.new(enum: Array.new(4 * BIG / CHUNK) { "x" * CHUNK }.each, rack_body: nil)
    when "/one-chunk"
      HTTP3::Body::Chunks.new(enum: ["x" * (BIG / 2)].each, rack_body: nil)
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
