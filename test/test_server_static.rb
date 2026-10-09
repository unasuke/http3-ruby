# frozen_string_literal: true

require "test_helper"
require "digest"

# HTTP3::Server serving Rack::Static, wrapped in Rack::Lint so that every
# env and response is checked against Rack 3. The server and its app are in
# support/static_server.rb, run as a process of its own.
class TestServerStatic < Minitest::Test
  include TestCertificates
  include TestServerProcess

  # Large enough that a server holding the file whole is far over the
  # limit below, whatever its fixed costs.
  LARGE_FILE_SIZE = 32 * 1024 * 1024

  def setup
    @dir = Dir.mktmpdir("http3-static-")
    @root = File.join(@dir, "public")
    FileUtils.mkdir_p(File.join(@root, "static"))
    File.write(File.join(@root, "static", "small.txt"), "small file\n")
    File.binwrite(File.join(@root, "static", "large.bin"), Random.new(3).bytes(LARGE_FILE_SIZE))
    @log_path = File.join(@dir, "server.log")
    @pid, @port = spawn_server(
      File.expand_path("support/static_server.rb", __dir__),
      @root, credentials.certificate_path, credentials.private_key_path, @log_path
    )
    @client = H3TestClient::QuicTransport.connect(@port, ca_file: credentials.ca_file)
  end

  # The client goes first, so that the server has no stream to drain.
  def teardown
    @client&.close
    stop_server(@pid) if @pid
    FileUtils.remove_entry(@dir)
  end

  def test_serves_a_small_file
    response = fetch("/static/small.txt")
    assert_equal 200, response.status
    assert_equal "small file\n", response.body
    assert_equal "text/plain", response.headers["content-type"]
  end

  # The file is read 16 KiB at a time as the connection can take it, so the
  # server's memory does not grow with the file: it grows by about 5 MiB
  # here, where a server reading the file whole grows by about 41 MiB. What
  # growth there is comes from the data in flight, which the client's flow
  # control windows cap so that the measure does not depend on how far they
  # would grow, and from packet Strings the GC has not collected yet.
  def test_large_file_in_bounded_memory
    @client.close
    @client = H3TestClient::QuicTransport.connect(
      @port, ca_file: credentials.ca_file, max_window: 2 * 1024 * 1024, max_stream_window: 1024 * 1024
    )
    fetch("/static/small.txt")
    before = rss_kib(@pid)
    peak = before

    id = @client.request(:get, "/static/large.bin")
    @client.pump_until(timeout: 60) do
      peak = [peak, rss_kib(@pid)].max
      @client.response(id).finished?
    end

    response = @client.response(id)
    assert_equal 200, response.status
    assert_equal LARGE_FILE_SIZE, response.body.bytesize
    assert_equal Digest::SHA256.file(File.join(@root, "static", "large.bin")).hexdigest,
      Digest::SHA256.hexdigest(response.body)
    assert_operator peak - before, :<, 16 * 1024, "the server grew by #{peak - before} KiB"
  end

  def test_missing_file_is_404
    assert_equal 404, fetch("/static/missing.txt").status
  end

  def test_array_body
    response = fetch("/array")
    assert_equal 200, response.status
    assert_equal "a,b,c", response.body
  end

  def test_each_body
    response = fetch("/each")
    assert_equal 200, response.status
    assert_equal "one,two", response.body
  end

  def test_head_has_no_body
    id = @client.request(:head, "/array")
    @client.pump_until { @client.response(id).finished? }
    assert_equal 200, @client.response(id).status
    assert_empty @client.response(id).body.to_s
  end

  def test_exception_before_the_headers_is_500
    assert_equal 500, fetch("/raise").status
    assert_logged(/^E.* app_error remote=127\.0\.0\.1:\d+ stream=\d+ method=GET path=\/raise error=RuntimeError message="the app failed" at=\S+/)
  end

  # The headers are out, so the server can only stop the stream (with
  # H3_INTERNAL_ERROR, which the client cannot see through QUIC::Stream).
  def test_exception_after_the_headers_aborts_the_stream
    id = @client.request(:get, "/fail-midway")
    @client.pump_until { @client.aborted?(id) }
    assert_equal 200, @client.response(id).status
    refute @client.response(id).finished?
    assert_logged(/app_error .* path=\/fail-midway error=RuntimeError message="the body failed"/)
  end

  def test_query_string_and_header_values_stay_out_of_the_log
    fetch("/raise?token=secret", headers: {"authorization" => "Bearer hush"})
    log = File.read(@log_path)
    assert_match(/path=\/raise /, log)
    refute_match(/secret|hush/, log)
  end

  private

  def fetch(path, headers: {})
    id = @client.request(:get, path, headers: headers)
    @client.pump_until { @client.response(id).finished? }
    @client.response(id)
  end

  def assert_logged(pattern)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.read(@log_path).match?(pattern)
      flunk "#{pattern.inspect} not in the log:\n#{File.read(@log_path)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
