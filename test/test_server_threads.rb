# frozen_string_literal: true

require "test_helper"

# HTTP3::Server calling the application on worker threads, with the server
# in a child process. The application tells the test what it does through a
# pipe, a line an event: "call /path thread", "close /path thread", and so
# on, the path with its query. /slow waits for a byte on another pipe before
# it answers.
class TestServerThreads < Minitest::Test
  include TestCertificates
  include TestServerProcess

  # The options of the tests that need more than the defaults.
  OPTIONS = {
    "test_requests_wait_for_a_free_worker" => {threads: 1},
    "test_request_waiting_too_long_for_a_worker_gets_503" => {threads: 1, request_timeout: 1},
    "test_request_reset_while_waiting_never_reaches_the_application" => {threads: 1},
    "test_connections_take_turns" => {threads: 1},
    "test_exit_or_raise_in_the_application_keeps_the_worker" => {threads: 1},
    "test_stop_gives_up_on_a_stuck_job" => {shutdown_timeout: 1},
    "test_stop_cancels_a_body_still_being_written" => {shutdown_timeout: 1}
  }.freeze

  Event = Data.define(:name, :detail, :thread, :extra)

  # A body that tells the test which thread closes it.
  class TrackedBody
    def initialize(chunks, detail, record)
      @chunks = chunks
      @detail = detail
      @record = record
    end

    def each(&)
      @chunks.each(&)
    end

    def close
      @record.call("close", @detail)
    end
  end

  # Rack 3 has to_ary close the body.
  class TrackedArray < TrackedBody
    def to_ary
      close
      @chunks
    end
  end

  class TrackedFile < TrackedBody
    def initialize(path, detail, record)
      super([], detail, record)
      @path = path
    end

    def to_path
      @path
    end

    def each
      yield File.binread(@path)
    end
  end

  # Its first chunk, then the second once a byte comes on release.
  class SlowEachBody < TrackedBody
    def initialize(release, detail, record)
      super([], detail, record)
      @release = release
    end

    def each
      yield "first"
      @release.read(1)
      yield "second"
    end
  end

  # More than the send buffer holds, then it fails: the headers go out
  # first.
  class FailingBody < TrackedBody
    def each
      yield "x" * 100_000
      raise "the body failed"
    end
  end

  # Chunks until writing them fails; tells the test how it ended.
  class EndlessBody < TrackedBody
    def each
      loop { yield "x" * 16_384 }
    ensure
      @record.call("each-ended", @detail, $!&.class)
    end
  end

  # A chunk a while after the response was handed over.
  class LateBody < TrackedBody
    def each
      sleep 0.2
      yield "late"
    end
  end

  def setup
    @dir = Dir.mktmpdir("http3-threads-")
    @log_path = File.join(@dir, "server.log")
    @file_path = File.join(@dir, "file")
    File.write(@file_path, "file content")
    @clients = []
    @events = []
    @event_buffer = +""
    @release_r, @release_w = IO.pipe
    @events_r, @events_w = IO.pipe
    release_r = @release_r
    events_w = @events_w
    file_path = @file_path
    @pid, @port = start_server(
      log_path: @log_path,
      certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path,
      **OPTIONS.fetch(name, {})
    ) { build_app(release_r, events_w, file_path) }
    @release_r.close
    @events_w.close
  end

  # The pipe is closed first, so that an application still waiting on it
  # goes on.
  def teardown
    @clients.each(&:close)
    @release_w.close
    stop_server(@pid) if @pid
    @events_r.close
    FileUtils.remove_entry(@dir)
  end

  # While a request keeps a worker, another connection's request comes back
  # at once.
  def test_slow_request_does_not_hold_up_another_connection
    slow = connect
    held = slow.request(:get, "/slow")
    wait_for_event(slow, "call", "/slow")
    started = now
    assert_equal "fast", get(connect, "/fast").body
    assert_operator now - started, :<, 2
    release
    slow.pump_until { slow.response(held).finished? }
    assert_equal "slow", slow.response(held).body
  end

  def test_slow_each_does_not_hold_up_another_connection
    slow = connect
    held = slow.request(:get, "/slow-each")
    slow.pump_until { slow.response(held).body.to_s == "first" }
    assert_equal "fast", get(connect, "/fast").body
    release
    slow.pump_until { slow.response(held).finished? }
    assert_equal "firstsecond", slow.response(held).body
  end

  # call, each and close all run on the worker that took the request,
  # whatever the body: a file, an Array, each, none (HEAD, 204), and one
  # refused once the application returned it (a status that is not final).
  def test_call_and_close_run_on_the_same_worker
    client = connect
    assert_equal "file content", get(client, "/file").body
    assert_equal "ab", get(client, "/array").body
    assert_equal "one,two", get(client, "/each").body
    assert_equal 204, get(client, "/no-content").status
    assert_equal 500, get(client, "/invalid").status
    id = client.request(:head, "/each?head")
    client.pump_until { client.response(id).finished? }
    assert_equal 200, client.response(id).status
    %w[/file /array /each /no-content /invalid /each?head].each { |detail| assert_same_worker(client, detail) }
  end

  # A body that fails after its headers went out aborts its stream, and is
  # closed on its worker.
  def test_each_that_raises_aborts_the_stream
    client = connect
    id = client.request(:get, "/each-raise")
    client.pump_until { client.aborted?(id) }
    assert_equal 200, client.response(id).status
    assert_logged(/app_error .* path=\/each-raise error=RuntimeError message="the body failed"/)
    assert_same_worker(client, "/each-raise")
  end

  # A client that resets a stream while its each body is being written
  # stops the body: write raises StreamClosed in it, which is neither a 500
  # nor an app_error, and the connection's other streams go on.
  def test_reset_during_each_stops_the_body
    client = connect
    id = client.request(:get, "/endless")
    client.pump_until { client.response(id).status }
    client.cancel(id)
    client.pump_until { client.closed?(id) }
    ended = wait_for_event(client, "each-ended", "/endless")
    assert_equal "HTTP3::StreamClosed", ended.extra
    assert_same_worker(client, "/endless")
    assert_equal "fast", get(client, "/fast").body
    refute_match(/app_error/, File.read(@log_path))
  end

  # With every worker taken, a request waits, and the connections are
  # served all the while: a new one is set up. The request is answered once
  # the worker is free.
  def test_requests_wait_for_a_free_worker
    client = connect
    held = client.request(:get, "/slow")
    wait_for_event(client, "call", "/slow")
    id = client.request(:get, "/fast")
    pump_for(client, 0.3)
    other = connect
    refute_predicate client.response(id), :finished?
    assert_nil event("call", "/fast")
    release
    client.pump_until { client.response(id).finished? }
    assert_equal ["slow", "fast"], [client.response(held).body, client.response(id).body]
    assert_equal "fast", get(other, "/fast").body
  end

  # A request that waits for a worker for request_timeout gets 503, and
  # never reaches the application, the only other way it could have been
  # answered.
  def test_request_waiting_too_long_for_a_worker_gets_503
    client = connect
    held = client.request(:get, "/slow")
    wait_for_event(client, "call", "/slow")
    id = client.request(:get, "/fast")
    client.pump_until(timeout: 5) { client.response(id).finished? }
    assert_equal 503, client.response(id).status
    release
    client.pump_until { client.response(held).finished? }
    assert_equal 200, client.response(held).status
    assert_nil event("call", "/fast")
    refute_match(/ E, /, File.read(@log_path))
  end

  # A request the client gives up on while it waits for a worker never
  # reaches the application. Sent in full, it gets STOP_SENDING alone, and
  # the server drops it once its stream closes: when the client has
  # acknowledged the server's reset, which it does by the next packet it
  # sends.
  def test_request_reset_while_waiting_never_reaches_the_application
    client = connect
    held = client.request(:get, "/slow")
    wait_for_event(client, "call", "/slow")
    id = client.request(:get, "/fast")
    barrier(client)
    client.cancel(id)
    client.pump_until { client.closed?(id) }
    barrier(client)
    release
    client.pump_until { client.response(held).finished? }
    assert_equal "fast", get(client, "/fast?after").body
    assert_nil event("call", "/fast")
  end

  # The connections take turns at the one worker, a request each.
  def test_connections_take_turns
    a = connect
    b = connect
    held = a.request(:get, "/slow")
    wait_for_event(a, "call", "/slow")
    ids = {a => Array.new(4) { |i| a.request(:get, "/rr?a#{i}") }, b => Array.new(4) { |i| b.request(:get, "/rr?b#{i}") }}
    # All of them wait for the worker.
    barrier(a)
    barrier(b)
    release
    deadline = now + 10
    until ids.all? { |client, list| list.all? { |id| client.response(id)&.finished? } } && a.response(held).finished?
      flunk "the requests did not finish" if now > deadline
      [a, b].each(&:pump)
    end
    order = events.select { |e| e.name == "call" && e.detail.start_with?("/rr") }.map { |e| e.detail[4] }
    assert_equal 8, order.size
    order.each_cons(2) { |x, y| refute_equal x, y, order.join }
  end

  # A response a worker hands over wakes the loop, though no packet comes
  # in: these come a while after the request, once the loop has nothing
  # left to do.
  def test_responses_come_back_without_waiting_for_a_packet
    client = connect
    [[:head, "/each?head&late"], [:get, "/no-content?late"], [:get, "/file?late"], [:get, "/empty-each?late"],
      [:get, "/late-each"]].each do |method, path|
      started = now
      id = client.request(method, path)
      client.pump_until { client.response(id).finished? }
      assert_operator now - started, :<, 1, path
    end
  end

  # SIGTERM waits for the job under way, and its response goes out.
  def test_stop_waits_for_the_job_under_way
    client = connect
    held = client.request(:get, "/slow")
    wait_for_event(client, "call", "/slow")
    Process.kill("TERM", @pid)
    pump_for(client, 0.5)
    assert_nil Process.wait(@pid, Process::WNOHANG)
    release
    client.pump_until { client.response(held).finished? }
    assert_equal "slow", client.response(held).body
    # The stream closes, and the server stops, once the client has
    # acknowledged the response.
    status = nil
    begin
      client.pump_until { (status = Process.wait2(@pid, Process::WNOHANG)&.last) }
    rescue QUIC::Error::Closed
      # The server's CONNECTION_CLOSE.
    end
    status ||= wait_server(@pid)
    @pid = nil
    assert_predicate status, :success?
    assert_same_worker(client, "/slow")
  end

  # A job still in the application after shutdown_timeout is left to it:
  # the server stops a second later, and says so.
  def test_stop_gives_up_on_a_stuck_job
    client = connect
    client.request(:get, "/slow")
    wait_for_event(client, "call", "/slow")
    Process.kill("TERM", @pid)
    status = wait_server(@pid, timeout: 10)
    @pid = nil
    assert_predicate status, :success?
    assert_match(/workers_still_running count=1/, File.read(@log_path))
  end

  # Stopping gives up on a body still being written, whose client reads
  # none of it: write raises StreamClosed in its each, on its worker, which
  # closes it.
  def test_stop_cancels_a_body_still_being_written
    client = connect
    id = client.request(:get, "/endless")
    client.pump_until { client.response(id).status }
    client.pause(id)
    pump_for(client, 0.3)
    Process.kill("TERM", @pid)
    status = wait_server(@pid, timeout: 10)
    @pid = nil
    assert_predicate status, :success?
    assert_equal "HTTP3::StreamClosed", event("each-ended", "/endless")&.extra
    assert_equal event("call", "/endless").thread, event("close", "/endless")&.thread
    refute_match(/workers_still_running/, File.read(@log_path))
  end

  # Neither exit nor raise in the application costs the worker: the next
  # request gets the one there is.
  def test_exit_or_raise_in_the_application_keeps_the_worker
    client = connect
    assert_equal 500, get(client, "/exit").status
    assert_equal 500, get(client, "/raise").status
    assert_equal "fast", get(client, "/fast").body
    assert_logged(/app_error .* path=\/exit error=SystemExit/)
  end

  # The worker closes rack.input unless the application has.
  def test_application_may_close_rack_input
    client = connect
    id = client.request(:post, "/close-input", body: "x" * 100_000)
    client.pump_until { client.response(id).finished? }
    assert_equal 204, client.response(id).status
    assert_equal "fast", get(client, "/fast").body
    refute_match(/ E, /, File.read(@log_path))
  end

  private

  def build_app(release_r, events_w, file_path)
    record = lambda do |name, detail, extra = nil|
      events_w.write("#{[name, detail, Thread.current.name, extra].compact.join(" ")}\n")
    end
    lambda do |env|
      query = env["QUERY_STRING"]
      detail = query.empty? ? env["PATH_INFO"] : "#{env["PATH_INFO"]}?#{query}"
      record.call("call", detail)
      sleep 0.2 if query.include?("late")
      tracked = ->(chunks) { TrackedBody.new(chunks, detail, record) }
      case env["PATH_INFO"]
      when "/slow"
        release_r.read(1)
        [200, {}, tracked.call(["slow"])]
      when "/slow-each" then [200, {}, SlowEachBody.new(release_r, detail, record)]
      when "/fast", "/rr" then [200, {}, [env["PATH_INFO"].delete("/")]]
      when "/file" then [200, {}, TrackedFile.new(file_path, detail, record)]
      when "/array" then [200, {}, TrackedArray.new(["a", "b"], detail, record)]
      when "/each" then [200, {}, tracked.call(["one,", "two"])]
      when "/empty-each" then [200, {}, tracked.call([])]
      when "/no-content" then [204, {}, tracked.call([])]
      when "/invalid" then [99, {}, tracked.call(["x"])]
      when "/each-raise" then [200, {}, FailingBody.new([], detail, record)]
      when "/endless" then [200, {}, EndlessBody.new([], detail, record)]
      when "/late-each" then [200, {}, LateBody.new([], detail, record)]
      when "/raise" then raise "the app failed"
      when "/exit" then exit
      when "/close-input"
        env["rack.input"].close
        [204, {}, []]
      else [404, {}, []]
      end
    end
  end

  def connect
    H3TestClient::QuicTransport.connect(@port, ca_file: credentials.ca_file).tap { |client| @clients << client }
  end

  def get(client, path)
    id = client.request(:get, path)
    client.pump_until { client.response(id).finished? }
    client.response(id)
  end

  # Send client a request the server refuses at once (431, its headers
  # too large), and wait for the answer: by then the server has read what
  # the client sent before it.
  def barrier(client)
    id = client.request(:get, "/", headers: {"x-large" => "x" * 70_000})
    client.pump_until { client.response(id).finished? }
  end

  # A byte for one /slow to go on.
  def release
    @release_w.write("x")
  end

  # The events the application has told of so far.
  def events
    loop do
      chunk = @events_r.read_nonblock(65_536, exception: false)
      break unless chunk.is_a?(String)

      @event_buffer << chunk
    end
    while (line = @event_buffer.slice!(/\A[^\n]*\n/))
      @events << Event.new(*line.chomp.split(" ", 4).then { |fields| fields.fill(nil, fields.size...4) })
    end
    @events
  end

  def event(name, detail)
    events.find { |e| e.name == name && e.detail == detail }
  end

  # Pump client until the application has told of the event.
  def wait_for_event(client, name, detail)
    client.pump_until { event(name, detail) }
    event(name, detail)
  end

  def assert_same_worker(client, detail)
    closed = wait_for_event(client, "close", detail)
    called = event("call", detail)
    assert_match(/\Ahttp3-worker-\d+\z/, called.thread, detail)
    assert_equal called.thread, closed.thread, detail
  end

  def pump_for(client, seconds)
    deadline = now + seconds
    client.pump while now < deadline
  end

  def assert_logged(pattern)
    deadline = now + 5
    until File.read(@log_path).match?(pattern)
      flunk "#{pattern.inspect} not in the log:\n#{File.read(@log_path)}" if now > deadline

      sleep 0.01
    end
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
