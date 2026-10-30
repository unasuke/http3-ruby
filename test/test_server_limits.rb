# frozen_string_literal: true

require "test_helper"

# The limits HTTP3::Server puts on requests still coming in and on the
# response bytes it queues, over every connection, with HTTP3::Server in a
# child process, and the checks of the options that set them.
class TestServerLimits < Minitest::Test
  include TestCertificates
  include TestServerProcess

  LIMITS = {
    max_request_body: 4_000,
    max_field_section_size: 1_000,
    max_connection_request_buffer: 5_000,
    # Room for one request at the limits above, not for two.
    max_total_request_buffer: 8_000,
    send_buffer_size: 4_096,
    # One connection's streams can take all of the total.
    max_connection_send_buffer: 8_192,
    max_total_send_buffer: 8_192,
    # Long enough for the requests the other tests hold open.
    request_timeout: 2
  }.freeze

  # The options of the tests that need more than LIMITS.
  OPTIONS = {
    "test_refusals_are_logged_once_refusal_log_interval_has_passed" => {refusal_log_interval: 1}
  }.freeze

  # /big is far more than the client's window lets the server send unread.
  BIG = 2 * 1_024 * 1_024

  def setup
    @dir = Dir.mktmpdir("http3-limits-")
    @log_path = File.join(@dir, "server.log")
    @clients = []
    @pid, @port = start_server(
      log_path: @log_path,
      certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path,
      **LIMITS, **OPTIONS.fetch(name, {})
    ) do
      lambda do |env|
        case env["PATH_INFO"]
        when "/big" then [200, {}, Enumerator.new { |y| (BIG / 1_024).times { y << ("x" * 1_024) } }]
        when "/small" then [200, {}, Enumerator.new { |y| y << "small" }]
        else [200, {}, [env["rack.input"].read.bytesize.to_s]]
        end
      end
    end
  end

  def teardown
    @clients.each(&:close)
    stop_server(@pid) if @pid
    FileUtils.remove_entry(@dir)
  end

  # A request held open on one connection leaves too little of the
  # server's buffer for one on another, though that connection's own
  # buffer has room.
  def test_connections_share_the_total_buffer
    first = connect
    held = first.request(:post, "/", body: "x" * 4_000, fin: false)
    pump_for(first, 0.2)

    second = connect
    id = second.request(:post, "/", body: "y" * 4_000, fin: false)
    second.pump_until { second.response(id).finished? }
    assert_equal 503, second.response(id).status

    first.finish(held)
    first.pump_until { first.response(held).finished? }
    assert_equal "4000", first.response(held).body
  end

  # Once a connection with a request held open has closed, what it held
  # is free for the others.
  def test_closing_a_connection_gives_its_bytes_back
    first = connect
    first.request(:post, "/", body: "x" * 4_000, fin: false)
    pump_for(first, 0.2)
    second = connect
    assert_equal 503, post(second, "y" * 4_000).status

    first.close
    response = eventually(timeout: 5) { post(second, "y" * 4_000).tap { |r| raise "still 503" if r.status == 503 } }
    assert_equal 200, response.status
    assert_equal "4000", response.body
  end

  # Responses one connection does not read take all of the server's send
  # buffer: another connection's response gets its status, but no body
  # until that connection has gone.
  def test_connections_share_the_total_send_buffer
    first = connect
    2.times { first.request(:get, "/big").tap { |id| first.pause(id) } }
    pump_for(first, 1)

    second = connect
    id = second.request(:get, "/small")
    second.pump_until { second.response(id).status }
    pump_for(second, 2)
    assert_equal 200, second.response(id).status
    refute_predicate second.response(id), :finished?

    first.close
    second.pump_until { second.response(id).finished? }
    assert_equal "small", second.response(id).body
  end

  # The server's request_timeout reaches the Sessions: a request held open
  # past it gets 408.
  def test_request_held_past_request_timeout_gets_408
    client = connect
    id = client.request(:post, "/", body: "x" * 1_000, fin: false)
    client.pump_until(timeout: 10) { client.response(id).finished? }
    assert_equal 408, client.response(id).status
  end

  def test_request_timeout_is_checked
    [0, -1, "30"].each do |value|
      error = assert_raises(ArgumentError, value.inspect) { new_server(request_timeout: value) }
      assert_equal "request_timeout must be nil or a positive number of seconds (got #{value.inspect})", error.message
    end
    [nil, 0.5].each { |value| new_server(request_timeout: value) }
  end

  def test_threads_is_checked
    [0, -1, 1.5, "3", nil].each do |value|
      error = assert_raises(ArgumentError, value.inspect) { new_server(threads: value) }
      assert_equal "threads must be a positive Integer (got #{value.inspect})", error.message
    end
    new_server(threads: 1)
  end

  # The 503s within refusal_log_interval (1 second here) of the first make
  # one line, logged once it has passed.
  def test_refusals_are_logged_once_refusal_log_interval_has_passed
    held = hold_request
    second = connect
    ids = Array.new(2) { second.request(:post, "/", body: "y" * 4_000, fin: false) }
    second.pump_until { ids.all? { |id| second.response(id).finished? } }
    assert_equal [503, 503], ids.map { |id| second.response(id).status }
    assert_empty refusal_lines
    finish_held(*held)

    eventually(timeout: 5) { refusal_lines.empty? && raise("not logged yet") }
    assert_equal ["requests_refused status=503 count=2 seconds=1"], refusal_lines
  end

  # What has been counted is logged when the server stops, before
  # refusal_log_interval (60 seconds by default) has passed.
  def test_refusals_are_logged_when_the_server_stops
    held = hold_request
    second = connect
    assert_equal 503, post(second, "y" * 4_000).status
    finish_held(*held)

    # Closed, or the drain would wait for the client to acknowledge the
    # responses, and it pumps no more.
    @clients.each(&:close)
    status = stop_server(@pid)
    @pid = nil
    assert_predicate status, :success?
    lines = refusal_lines
    assert_equal 1, lines.size, lines.inspect
    assert_match(/\Arequests_refused status=503 count=1 seconds=\d+\z/, lines.first)
  end

  def test_refusal_log_interval_is_checked
    [0, -1, "60", nil].each do |value|
      error = assert_raises(ArgumentError, value.inspect) { new_server(refusal_log_interval: value) }
      assert_equal "refusal_log_interval must be a positive number of seconds (got #{value.inspect})", error.message
    end
    [1, 0.5].each { |value| new_server(refusal_log_interval: value) }
  end

  def test_send_limits_are_checked
    {
      {send_buffer_size: 0} => "send_buffer_size must be a positive Integer (got 0)",
      {max_connection_send_buffer: 1.5} => "max_connection_send_buffer must be a positive Integer (got 1.5)",
      {max_total_send_buffer: nil} => "max_total_send_buffer must be a positive Integer (got nil)",
      {max_connection_send_buffer: 1_000} =>
        "max_connection_send_buffer (1000) must be at least send_buffer_size (65536)",
      {max_total_send_buffer: 1_000} =>
        "max_total_send_buffer (1000) must be at least max_connection_send_buffer (1048576)"
    }.each do |options, message|
      error = assert_raises(ArgumentError, options.inspect) do
        HTTP3::Server.new(
          app: ->(_env) {}, bind: "127.0.0.1:0",
          certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path, **options
        )
      end
      assert_equal message, error.message
    end
  end

  def test_request_limits_are_checked
    {
      {max_request_body: 1.5} => "max_request_body must be an Integer of 0 or more (got 1.5)",
      {max_field_section_size: 0} => "max_field_section_size must be 1..2**62-1 (got 0)",
      {max_connection_request_buffer: 0} => "max_connection_request_buffer must be a positive Integer (got 0)",
      {max_total_request_buffer: nil} => "max_total_request_buffer must be a positive Integer (got nil)",
      {max_request_body: 4_000, max_field_section_size: 1_000, max_connection_request_buffer: 4_000} =>
        "max_connection_request_buffer (4000) must be at least max_request_body + max_field_section_size (5000)",
      {max_total_request_buffer: 1_000} =>
        "max_total_request_buffer (1000) must be at least max_connection_request_buffer (4194304)",
      {request_body_buffer_size: 0} => "request_body_buffer_size must be a positive Integer (got 0)",
      {max_connection_request_spool: nil} => "max_connection_request_spool must be a positive Integer (got nil)",
      {max_total_request_spool: -1} => "max_total_request_spool must be a positive Integer (got -1)",
      {max_connection_request_spool_files: 0} => "max_connection_request_spool_files must be a positive Integer (got 0)",
      {max_total_request_spool_files: 1.0} => "max_total_request_spool_files must be a positive Integer (got 1.0)",
      # A body over request_body_buffer_size goes to a file, so memory has
      # to hold only that much of it.
      {max_request_body: 4_000, max_field_section_size: 1_000, request_body_buffer_size: 1_000,
       max_connection_request_buffer: 1_500} =>
        "max_connection_request_buffer (1500) must be at least request_body_buffer_size + max_field_section_size (2000)",
      {max_request_body: 20_000_000} =>
        "max_connection_request_spool (16777216) must be at least max_request_body (20000000)",
      {max_total_request_spool: 1_000} =>
        "max_total_request_spool (1000) must be at least max_connection_request_spool (16777216)",
      {max_total_request_spool_files: 8} =>
        "max_total_request_spool_files (8) must be at least max_connection_request_spool_files (16)"
    }.each do |options, message|
      error = assert_raises(ArgumentError, options.inspect) do
        HTTP3::Server.new(
          app: ->(_env) {}, bind: "127.0.0.1:0",
          certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path, **options
        )
      end
      assert_equal message, error.message
    end
    # No body goes to a file, so the spool needs no room.
    new_server(max_request_body: 4_000, max_connection_request_spool: 1, max_total_request_spool: 1)
  end

  private

  def connect
    H3TestClient::QuicTransport.connect(@port, ca_file: credentials.ca_file).tap { |client| @clients << client }
  end

  def new_server(**options)
    HTTP3::Server.new(
      app: ->(_env) {}, bind: "127.0.0.1:0",
      certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path, **options
    )
  end

  def post(client, body)
    id = client.request(:post, "/", body: body)
    client.pump_until { client.response(id).finished? }
    client.response(id)
  end

  # A request held open on a new connection, with too much for another
  # one to fit in the total buffer; returns [client, id].
  def hold_request
    client = connect
    id = client.request(:post, "/", body: "x" * 4_000, fin: false)
    pump_for(client, 0.2)
    [client, id]
  end

  # Finish a request hold_request held, before it runs out of time.
  def finish_held(client, id)
    client.finish(id)
    client.pump_until { client.response(id).finished? }
    assert_equal 200, client.response(id).status
  end

  # The requests_refused lines of the server's log so far.
  def refusal_lines
    File.read(@log_path).scan(/requests_refused[^\n]*/)
  end

  # Pump for a while, so that the server gets what the client sent.
  def pump_for(client, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    client.pump while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  end

  # Retry the block until it succeeds; the server lets go of a closed
  # connection on a later turn.
  def eventually(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    begin
      yield
    rescue
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
      retry
    end
  end
end
