# frozen_string_literal: true

require "test_helper"
require "digest"
require "objspace"

# HTTP3::Server writing request bodies over request_body_buffer_size to
# temporary files, with the server in a child process, whose descriptors
# and memory are looked at through /proc.
class TestServerSpool < Minitest::Test
  include TestCertificates
  include TestServerProcess

  LIMITS = {
    max_request_body: 4_000,
    max_field_section_size: 1_000,
    request_body_buffer_size: 1_000,
    max_connection_request_buffer: 5_000,
    max_total_request_buffer: 10_000
  }.freeze

  # The options of the tests that need more than LIMITS.
  OPTIONS = {
    "test_large_body_is_not_kept_in_memory" => {
      max_request_body: 64 * 1_024 * 1_024, max_connection_request_spool: 64 * 1_024 * 1_024, request_timeout: 120
    },
    "test_connections_share_the_total_spool" => {max_connection_request_spool: 4_000, max_total_request_spool: 4_000},
    "test_connections_share_the_total_spool_files" =>
      {max_connection_request_spool_files: 1, max_total_request_spool_files: 1},
    "test_spool_counts_until_the_application_is_done_with_a_gone_connection" =>
      {max_connection_request_spool: 4_000, max_total_request_spool: 4_000, max_connections: 1},
    "test_503_and_one_log_line_when_a_file_cannot_be_written" => {max_request_body: 200_000}
  }.freeze

  # Bytes a temporary file may grow to in test_503_and_one_log_line_when_a_file_cannot_be_written,
  # far more than the log and far less than its request bodies.
  FILE_SIZE_LIMIT = 64 * 1_024

  def setup
    @dir = Dir.mktmpdir("http3-spool-")
    @log_path = File.join(@dir, "server.log")
    @clients = []
    # /block writes a byte to the second pipe, then waits for a byte on the
    # first before it reads its body.
    @release_r, @release_w = IO.pipe
    @started_r, @started_w = IO.pipe
    release_r = @release_r
    started_w = @started_w
    limit_file_size = name == "test_503_and_one_log_line_when_a_file_cannot_be_written"
    @pid, @port = start_server(
      log_path: @log_path,
      certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path,
      **LIMITS, **OPTIONS.fetch(name, {})
    ) do
      if limit_file_size
        # Writing past the limit fails with EFBIG instead of killing the
        # process.
        Signal.trap("XFSZ", "IGNORE")
        Process.setrlimit(:FSIZE, FILE_SIZE_LIMIT)
      end
      lambda do |env|
        if env["PATH_INFO"] == "/block"
          started_w.write("s")
          release_r.read(1)
        end
        input = env["rack.input"]
        digest = Digest::SHA256.new
        size = 0
        while (chunk = input.read(16_384))
          digest << chunk
          size += chunk.bytesize
        end
        # /strings tells, too, the bytes of the Strings still alive once
        # the GC has run.
        strings = if env["PATH_INFO"] == "/strings"
          GC.start
          " #{ObjectSpace.memsize_of_all(String)}"
        end
        [200, {}, ["#{size} #{digest.hexdigest}#{strings}"]]
      end
    end
    @release_r.close
    @started_w.close
  end

  def teardown
    @clients.each(&:close)
    @release_w.close
    stop_server(@pid) if @pid
    @started_r.close
    FileUtils.remove_entry(@dir)
  end

  # A body within request_body_buffer_size stays in memory; one past it is
  # in a file without a name while the application has it, and the file
  # is closed once the response is done.
  def test_body_over_the_buffer_is_in_a_file_while_the_application_has_it
    client = connect
    id = client.request(:post, "/block", body: "x" * 1_000)
    pump_for(client, 0.3)
    assert_empty spool_descriptors
    @release_w.write("x")
    client.pump_until { client.response(id).finished? }

    body = Random.new(5).bytes(4_000)
    id = client.request(:post, "/block", body: body)
    pump_for(client, 0.3)
    assert_equal 1, spool_descriptors.size
    @release_w.write("x")
    client.pump_until { client.response(id).finished? }
    assert_equal "4000 #{Digest::SHA256.hexdigest(body)}", client.response(id).body
    eventually(timeout: 5) { assert_empty spool_descriptors }
  end

  # A body far over max_connection_request_buffer goes through, and is not
  # kept in memory: once the GC has run, the server's Strings come to
  # about 2 MiB, where a body held in memory would add all of its 64 MiB.
  # The resident set size would not tell: it grows with the Strings each
  # DATA frame comes in until the GC collects them, by how much depending
  # on the GC's malloc limits (90 MiB for a 192 MiB body with the defaults,
  # 2.5 MiB with RUBY_GC_MALLOC_LIMIT_MAX=8000000).
  def test_large_body_is_not_kept_in_memory
    client = connect
    body = Random.new(6).bytes(64 * 1_024 * 1_024)
    id = client.request(:post, "/strings", body: body)
    client.pump_until(timeout: 120) { client.response(id).finished? }
    assert_equal 200, client.response(id).status
    size, digest, strings = client.response(id).body.split
    assert_equal [body.bytesize.to_s, Digest::SHA256.hexdigest(body)], [size, digest]
    assert_operator Integer(strings), :<, 16 * 1_024 * 1_024, "the server's Strings take #{strings} bytes"
  end

  # A request spooling on one connection leaves too little of the total for
  # one on another, though that connection's own limit has room.
  def test_connections_share_the_total_spool
    first = connect
    held = first.request(:post, "/", body: "x" * 3_000, fin: false)
    wait_for_spool_files(first, 1)
    assert_equal 503, post(connect, "y" * 2_000).status
    first.finish(held)
    first.pump_until { first.response(held).finished? }
    assert_equal 200, post(connect, "y" * 2_000).status
  end

  def test_connections_share_the_total_spool_files
    first = connect
    held = first.request(:post, "/", body: "x" * 2_000, fin: false)
    wait_for_spool_files(first, 1)
    assert_equal 503, post(connect, "y" * 2_000).status
    first.finish(held)
    first.pump_until { first.response(held).finished? }
    eventually(timeout: 5) { assert_equal 200, post(connect, "y" * 2_000).status }
  end

  # A request the application has still counts in the spool once its
  # connection has gone, until the application is done with it: the
  # worker still has its file. The server takes one connection at a time,
  # so the second gets in once the first has gone.
  def test_spool_counts_until_the_application_is_done_with_a_gone_connection
    first = connect
    first.request(:post, "/block", body: "x" * 4_000)
    first.pump_until { @started_r.wait_readable(0) }
    first.close
    @clients.delete(first)
    second = connect_once_free
    assert_equal 503, post(second, "y" * 2_000).status
    @release_w.write("x")
    eventually(timeout: 5) { assert_equal 200, post(second, "y" * 2_000).status }
  end

  # A file that cannot be written (here, past RLIMIT_FSIZE) gets the
  # request 503 and a request_spool_failed line; the next failure, within
  # refusal_log_interval, gets no line of its own.
  def test_503_and_one_log_line_when_a_file_cannot_be_written
    client = connect
    assert_equal 503, post(client, "x" * 100_000).status
    eventually(timeout: 5) { assert_equal 1, spool_failure_lines.size }
    assert_equal 503, post(client, "y" * 100_000).status
    assert_equal 200, post(client, "z" * 2_000).status
    lines = spool_failure_lines
    assert_equal 1, lines.size, lines.inspect
    assert_match(/\Arequest_spool_failed remote=127\.0\.0\.1:\d+ error=Errno::EFBIG message=/, lines.first)
  end

  # Server.new makes a temporary file in Dir.tmpdir when bodies may go to
  # files, and raises what that raises; when none may, it does not look.
  # Dir.tmpdir skips a TMPDIR it cannot write to, so the child has it
  # answer a directory it cannot write to.
  def test_new_checks_the_temporary_directory
    skip "root writes anywhere" if Process.uid.zero?
    readonly = File.join(@dir, "readonly")
    Dir.mkdir(readonly, 0o500)
    assert_equal "Errno::EACCES", new_server_with_tmpdir(readonly)
    assert_equal "made", new_server_with_tmpdir(readonly, max_request_body: 65_536)
  end

  private

  # Make a Server with options in a child whose Dir.tmpdir is dir; returns
  # "made" or the class of what Server.new raised.
  def new_server_with_tmpdir(dir, **options)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Dir.singleton_class.define_method(:tmpdir) { dir }
      result = begin
        HTTP3::Server.new(
          app: ->(_env) {}, bind: "127.0.0.1:0",
          certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path, **options
        )
        "made"
      rescue => e
        e.class.name
      end
      writer.write(result)
      writer.close
      exit!(0)
    end
    writer.close
    result = reader.read
    Process.wait(pid)
    result
  ensure
    reader&.close
  end

  def connect
    H3TestClient::QuicTransport.connect(@port, ca_file: credentials.ca_file).tap { |client| @clients << client }
  end

  # Connect, again and again while the server refuses the connection.
  def connect_once_free
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    begin
      connect
    rescue QUIC::Error
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
      retry
    end
  end

  def post(client, body)
    id = client.request(:post, "/", body: body)
    client.pump_until { client.response(id).finished? }
    client.response(id)
  end

  # The server's descriptors open on temporary files without a name in
  # Dir.tmpdir (Linux).
  def spool_descriptors
    Dir.children("/proc/#{@pid}/fd").filter_map do |fd|
      path = File.readlink("/proc/#{@pid}/fd/#{fd}")
      path if path.start_with?(Dir.tmpdir) && path.end_with?(" (deleted)")
    rescue Errno::ENOENT
      nil
    end
  end

  # The request_spool_failed lines of the server's log so far.
  def spool_failure_lines
    File.read(@log_path).scan(/request_spool_failed[^\n]*/)
  end

  # Pump until the server has n temporary files open, and a while more for
  # the rest of what client sent to arrive.
  def wait_for_spool_files(client, n)
    client.pump_until { spool_descriptors.size == n }
    pump_for(client, 0.2)
  end

  # Pump for a while, so that the server gets what the client sent.
  def pump_for(client, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    client.pump while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  end

  # Retry the block until it succeeds; the server lets go of what a
  # response held on a later turn.
  def eventually(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    begin
      yield
    rescue Minitest::Assertion
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
      retry
    end
  end
end
