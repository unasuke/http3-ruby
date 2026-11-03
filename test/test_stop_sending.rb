# frozen_string_literal: true

require "test_helper"
require "socket"

# How an HTTP3::Session acts on a client's STOP_SENDING as it arrives
# (on_stop_sending), instead of when the stream closes: the request is
# dropped, the response stops, and no more of the request is read. On a
# QUIC loopback as in TestResponseTimeout: a QUIC::Connection::Server in a
# thread with a Session attached, and H3TestClient in the main thread. The
# server thread neither hands out, refuses nor answers a request by itself:
# the test has it do so (#on_server), so that a request can be left
# waiting. It records each on_stop_sending, and, at the end of the turn in
# which one came, what the requests and the responses still hold.
class TestStopSending < Minitest::Test
  include TestCertificates

  CHUNK = 16_384
  # Much more than the client's window lets the server send unread, and
  # than nghttp3 takes ahead of what it sends.
  BIG = 2 * 1_024 * 1_024
  MAX_REQUEST_BODY = 1_048_576
  # A body larger than request_body_buffer_size (64 KiB) goes to a
  # temporary file.
  SPOOLED = 100_000
  STREAM_LIMIT = 65_536

  # The response_timeout of the tests that have one: never reached but by
  # the call the test asks for.
  RESPONSE_TIMEOUTS = {
    "test_array_and_file_bodies_let_go_of_what_was_not_sent" => 50
  }.freeze

  # An on_stop_sending call: the stream, and whether its request was still
  # answerable right after.
  Stop = Data.define(:id, :answerable)
  # The end of a turn in which on_stop_sending came: unsent_total, the
  # descriptors open on the file /file serves, the bytes the requests hold
  # in memory and in temporary files, the temporary files open, and
  # response_stalled_since of every stream stopped so far.
  Turn = Data.define(:unsent_total, :fds, :buffer, :spool_bytes, :spool_files, :stalled)

  def setup
    # Generated here, before the server thread could race the main thread
    # to it.
    credentials
    @dir = Dir.mktmpdir
    @file_path = File.join(File.realpath(@dir), "file")
    @sock = UDPSocket.new(Socket::AF_INET)
    @sock.bind("127.0.0.1", 0)
    @stop = false
    @buffer = HTTP3::Session.shared_buffer(1 << 30)
    @spool = HTTP3::Session.shared_spool(1 << 30, files: 100)
    @stops = Thread::Queue.new
    @turns = Thread::Queue.new
    # [stream_id, app_error_code] of each Session#abort_stream
    @aborts = Thread::Queue.new
    # The streams whose requests have been received in full (on_end_stream)
    @ended = Thread::Queue.new
    # [stream_id, bytes] of each on_data, summed up by #received
    @data = Thread::Queue.new
    @received = Hash.new(0)
    # The temporary files the Session made for request bodies
    @spool_files = Thread::Queue.new
    # The Body::Pipe of each /pipe, for the test to write
    @pipes = Thread::Queue.new
    # Blocks the server thread calls with the Session, and what they
    # returned (#on_server)
    @calls = Thread::Queue.new
    @results = Thread::Queue.new
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

  # A request waiting to be handed out is dropped as STOP_SENDING arrives,
  # with what it held: it never reaches whoever takes the requests.
  def test_a_request_waiting_to_be_handed_out_is_dropped
    @client = connect
    id = @client.request(:get, "/small")
    assert_equal id, pop(@ended)
    assert_operator @buffer.used, :>, 0

    @client.stop_sending(id)
    assert_equal Stop.new(id, false), pop(@stops)
    assert_equal 0, pop(@turns).buffer
    assert_nil on_server(&:next_request)
    @client.pump_until { @client.closed?(id) }
  end

  # A request still coming in is dropped with what it held, and read no
  # more: the server stops the client sending it (STOP_SENDING), and the
  # stream closes, though the client never ends the request. The client
  # cannot tell the STOP_SENDING's error code: the server's reset comes with
  # it, and QUIC::Stream reports the stream closed.
  def test_a_request_coming_in_is_dropped_and_no_longer_read
    @client = connect
    id = @client.request(:post, "/echo", body: "x" * 10_000, fin: false)
    @client.pump_until { received(id) >= 10_000 }
    assert_operator @buffer.used, :>=, 10_000

    @client.stop_sending(id)
    assert_equal Stop.new(id, false), pop(@stops)
    assert_equal 0, pop(@turns).buffer
    @client.pump_until { @client.closed?(id) }
  end

  # The same for a request body in a temporary file: the file is closed,
  # and what it held no longer counts.
  def test_a_request_body_in_a_temporary_file_is_let_go
    @client = connect
    id = @client.request(:post, "/echo", body: "x" * SPOOLED, fin: false)
    @client.pump_until { received(id) >= SPOOLED }
    file = pop(@spool_files)
    assert_operator @spool.bytes.used, :>=, SPOOLED
    assert_equal 1, @spool.files.used

    @client.stop_sending(id)
    assert_equal Stop.new(id, false), pop(@stops)
    turn = pop(@turns)
    assert_equal [0, 0], [turn.spool_bytes, turn.spool_files]
    assert_predicate file, :closed?
    @client.pump_until { @client.closed?(id) }
  end

  # A request refused before it was answered is not answered: its refusal
  # is taken back, and the stream closes.
  def test_a_refused_request_is_not_answered
    @client = connect
    id = @client.request(:post, "/echo", body: "x" * (MAX_REQUEST_BODY + 1), fin: false)
    @client.pump_until { received(id) > MAX_REQUEST_BODY }

    @client.stop_sending(id)
    assert_equal Stop.new(id, false), pop(@stops)
    assert_empty on_server(&:take_refusals)
    @client.pump_until { @client.closed?(id) }
  end

  # A request handed out can no longer be answered, but what it holds
  # counts until #finish, as ever.
  def test_a_request_handed_out_is_no_longer_answerable
    @client = connect
    id = @client.request(:get, "/small")
    assert_equal id, pop(@ended)
    assert_equal id, on_server { |session| session.next_request.stream_id }
    held = @buffer.used
    assert_operator held, :>, 0

    @client.stop_sending(id)
    assert_equal Stop.new(id, false), pop(@stops)
    assert_equal held, pop(@turns).buffer
    assert_equal 0, on_server { |session|
      session.finish(id)
      @buffer.used
    }
  end

  # The writer of a Body::Pipe is stopped by StreamClosed as STOP_SENDING
  # arrives, and what it had queued no longer counts, from the same turn.
  # The client is not pumped once STOP_SENDING is out, so that it
  # acknowledges nothing, not even the server's reset, and the stream stays
  # open: the stream closing would cancel the pipe too.
  def test_a_pipe_being_written_gets_stream_closed
    @client = connect
    id = @client.request(:get, "/pipe").tap { |i| @client.pause(i) }
    assert_equal id, pop(@ended)
    answer(1)
    pipe = pop(@pipes)
    writer = Thread.new do
      loop { pipe.write("x" * CHUNK) }
    rescue => e
      e
    end
    pump_for(0.3)

    @client.stop_sending(id)
    @client.pump
    assert writer.join(5), "the writer should have been stopped"
    assert_kind_of HTTP3::StreamClosed, writer.value
    turn = @turns.pop(timeout: 5)
    refute_nil turn, "on_stop_sending should have come"
    assert_equal 0, turn.unsent_total
  ensure
    stop_thread(writer)
  end

  # An array body and a file body not read let go, as STOP_SENDING
  # arrives, of what nghttp3 has not taken: the chunks queued and the
  # file's descriptor. They no longer wait on the client, so that
  # response_timeout does not abort them again.
  def test_array_and_file_bodies_let_go_of_what_was_not_sent
    skip "needs /proc/self/fd" unless File.directory?("/proc/self/fd")
    File.binwrite(@file_path, "x" * BIG)
    @client = connect
    array = @client.request(:get, "/big").tap { |i| @client.pause(i) }
    file = @client.request(:get, "/file").tap { |i| @client.pause(i) }
    2.times { pop(@ended) }
    answer(2)
    pump_for(0.5)
    assert_operator on_server(&:unsent_total), :>, 0
    refute_empty descriptors_of(@file_path), "the file should not have been read in full"

    @client.stop_sending(array)
    @client.stop_sending(file)
    assert_equal [array, file].sort, Array.new(2) { pop(@stops).id }.sort
    turn = last_turn
    assert_equal 0, turn.unsent_total
    assert_empty turn.fds
    assert_equal({array => nil, file => nil}, turn.stalled)
    assert_equal 0, on_server { |session| session.expire_responses(now + 100) }
    assert_empty @aborts
  end

  # A request coming in that the client resets, and then stops reading,
  # in one packet (ngtcp2 puts RESET_STREAM first), is dropped once: the
  # reset has the Session abort the stream with H3_REQUEST_INCOMPLETE, as
  # ever, once, and STOP_SENDING finds nothing more to drop. (The server's
  # RESET_STREAM carries the STOP_SENDING's code all the same: ngtcp2
  # queued it as STOP_SENDING arrived, and keeps it.)
  def test_reset_then_stop_sending_drops_the_request_once
    @client = connect
    id = @client.request(:post, "/echo", body: "x" * 10_000, fin: false)
    @client.pump_until { received(id) >= 10_000 }

    @client.cancel(id)
    assert_equal Stop.new(id, false), pop(@stops)
    @client.pump_until { @client.closed?(id) }
    assert_equal [[id, HTTP3::Nghttp3::H3_REQUEST_INCOMPLETE]], drain(@aborts).select { |aborted, _| aborted == id }
    assert_equal 0, @buffer.used
    assert_nil on_server(&:next_request)
  end

  # A request coming in that the client stops reading, and then resets, is
  # dropped once, as STOP_SENDING arrives: the reset finds nothing to drop,
  # and the server has nothing to reset.
  def test_stop_sending_then_reset_drops_the_request_once
    @client = connect
    id = @client.request(:post, "/echo", body: "x" * 10_000, fin: false)
    @client.pump_until { received(id) >= 10_000 }

    @client.stop_sending(id)
    assert_equal Stop.new(id, false), pop(@stops)
    @client.cancel(id, stop_sending: false)
    @client.pump_until { @client.closed?(id) }
    assert_empty drain(@aborts).select { |aborted, _| aborted == id }
    assert_equal 0, @buffer.used
  end

  private

  def connect(**options)
    H3TestClient::QuicTransport.connect(@sock.addr[1], ca_file: credentials.ca_file, **options)
  end

  # Have the server thread call the block with the Session, between two
  # turns, and return what it returned.
  def on_server(&block)
    @calls << block
    result = pop(@results)
    raise result if result.is_a?(Exception)

    result
  end

  # Have the server thread hand out and answer count requests (#response_to).
  def answer(count)
    on_server do |session|
      count.times do
        request = session.next_request
        session.respond(request, response_to(request))
        session.finish(request.stream_id)
      end
    end
  end

  # The bytes of the request body on stream id the Session has got so far.
  def received(id)
    drain(@data).each { |stream_id, bytes| @received[stream_id] += bytes }
    @received[id]
  end

  # The next of what the server thread put in queue, pumping the client
  # until it comes.
  def pop(queue)
    @client.pump_until { !queue.empty? }
    queue.pop
  end

  # Everything in queue now.
  def drain(queue)
    Array.new(queue.size) { queue.pop }
  end

  # The last of the turns in which on_stop_sending came so far.
  def last_turn
    pop(@turns).then { |turn| drain(@turns).last || turn }
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
    session = HTTP3::Session.attach(conn, max_request_body: MAX_REQUEST_BODY, max_field_section_size: 4_096,
      shared_buffer: @buffer, shared_spool: @spool, response_timeout: RESPONSE_TIMEOUTS[name])
    # The streams stopped so far, and whether one was in this turn
    stopped = []
    new_stop = false
    record(session) do |id|
      stopped << id
      new_stop = true
    end
    until @stop
      conn.pump_once(timeout: 0.002)
      call(session) until @calls.empty?
      session.fill_bodies(STREAM_LIMIT)
      if new_stop
        @turns << Turn.new(session.unsent_total, descriptors_of(@file_path), @buffer.used, @spool.bytes.used,
          @spool.files.used, stopped.to_h { |id| [id, session.response_stalled_since(id)] })
        new_stop = false
      end
      session.release_closed
      error = session.take_error and raise error
    end
  rescue QUIC::Error::Closed, IOError, Errno::ECONNREFUSED
    # The client went away, or teardown closed the socket.
  end

  # Record what the Session's callbacks get; the block gets the stream of
  # each on_stop_sending.
  def record(session, &stopped)
    stops = @stops
    aborts = @aborts
    ended = @ended
    data = @data
    spool_files = @spool_files
    session.define_singleton_method(:on_stop_sending) do |id|
      super(id)
      stopped.call(id)
      stops << Stop.new(id, answerable?(id))
    end
    session.define_singleton_method(:abort_stream) do |id, code|
      aborts << [id, code]
      super(id, code)
    end
    session.define_singleton_method(:on_end_stream) do |id|
      super(id)
      ended << id
    end
    session.define_singleton_method(:on_data) do |id, bytes|
      data << [id, bytes.bytesize]
      super(id, bytes)
    end
    session.define_singleton_method(:open_spool) do
      super().tap { |file| spool_files << file }
    end
  end

  # Call the next block the test gave, and put what it returned, or raised.
  def call(session)
    block = @calls.pop
    @results << begin
      block.call(session)
    rescue => e
      e
    end
  end

  def response_to(request)
    body = case request.headers.assoc(":path").last
    when "/big"
      HTTP3::Body::Chunks.new(enum: Array.new(BIG / CHUNK) { "x" * CHUNK }.each, rack_body: nil)
    when "/file"
      HTTP3::Body::File.new(io: File.open(@file_path, "rb"), offset: 0, length: File.size(@file_path), rack_body: nil)
    when "/pipe"
      HTTP3::Body::Pipe.new(capacity: 65_536, wake: -> {}).tap { |pipe| @pipes << pipe }
    end
    HTTP3::Response.new(status: 200, headers: [], body: body)
  end
end
