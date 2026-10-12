# frozen_string_literal: true

require "test_helper"

# Signals to HTTP3::Server in a child process: SIGHUP reloads the
# certificate, SIGTERM drains and stops.
class TestServerSignals < Minitest::Test
  include TestServerProcess

  def setup
    @dir = Dir.mktmpdir("http3-signals-")
    # The certificate the server starts with, in files a test can replace.
    @old = TestCertificates.generate_credentials(ca_common_name: "http3 old CA", dir: @dir)
    @log_path = File.join(@dir, "server.log")
    @clients = []
    @pid, @port = start_server(
      log_path: @log_path, shutdown_timeout: 30,
      certificate_path: @old.certificate_path, private_key_path: @old.private_key_path
    ) { method(:app).to_proc }
  end

  def teardown
    @clients.each(&:close)
    if @pid
      begin
        Process.kill("KILL", @pid)
        Process.wait(@pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    FileUtils.remove_entry(@dir)
  end

  # After SIGHUP, a new connection meets the new certificate: trusting the
  # new CA works and trusting the old one fails. A connection made before
  # keeps working.
  def test_sighup_reloads_the_certificate
    before = connect(@old.ca_file)
    assert_equal "ok", get(before, "/").body

    new_dir = File.join(@dir, "new")
    Dir.mkdir(new_dir)
    replacement = TestCertificates.generate_credentials(ca_common_name: "http3 new CA", dir: new_dir)
    FileUtils.cp(replacement.certificate_path, @old.certificate_path)
    FileUtils.cp(replacement.private_key_path, @old.private_key_path)
    Process.kill("HUP", @pid)

    after = eventually { connect(replacement.ca_file) }
    assert_equal "ok", get(after, "/").body
    assert_raises(QUIC::Error::CertificateVerifyFailed) { connect(@old.ca_file) }
    assert_equal "ok", get(before, "/").body
  end

  def test_sighup_keeps_the_old_certificate_when_the_new_one_fails
    File.write(@old.certificate_path, "not a certificate\n")
    Process.kill("HUP", @pid)

    eventually { File.read(@log_path).include?("tls_reload_failed") || raise("not reloaded yet") }
    assert_match(/tls_reload_failed certificate_path=\S+ private_key_path=\S+ error=ArgumentError message="failed to load certificate: /,
      File.read(@log_path))
    assert_equal "ok", get(connect(@old.ca_file), "/").body
  end

  # GOAWAY reaches the client before the connection closes, and the server
  # exits once nothing is under way. The client keeps pumping until then:
  # the server counts the request stream as under way until the client
  # acknowledges the end of the response, and that acknowledgement may
  # still be waiting for its delay to pass when GOAWAY arrives.
  def test_sigterm_sends_goaway_and_exits
    client = connect(@old.ca_file)
    assert_equal "ok", get(client, "/").body

    Process.kill("TERM", @pid)
    status = nil
    begin
      client.pump_until(timeout: STOP_TIMEOUT) { status = Process.wait2(@pid, Process::WNOHANG)&.last }
    rescue QUIC::Error::Closed
      client.feed
    end
    refute_nil client.client.goaway_id
    assert_predicate status || wait_server(@pid), :success?
    @pid = nil
  end

  # The client stops reading a large response, so the stream stays open and
  # the drain would wait shutdown_timeout (30 s). A second SIGTERM ends it.
  def test_second_sigterm_stops_waiting
    client = connect(@old.ca_file)
    id = client.request(:get, "/large")
    client.pump_until { client.response(id).status }

    Process.kill("TERM", @pid)
    sleep 0.5
    assert_nil Process.wait2(@pid, Process::WNOHANG), "the server should still be draining"

    Process.kill("TERM", @pid)
    assert_predicate wait_server(@pid, timeout: 5), :success?
    @pid = nil
  end

  private

  def app(env)
    case env["PATH_INFO"]
    when "/large" then [200, {}, Array.new(20) { "x" * 1_000_000 }]
    else [200, {"content-type" => "text/plain"}, ["ok"]]
    end
  end

  def connect(ca_file)
    H3TestClient::QuicTransport.connect(@port, ca_file: ca_file).tap { |client| @clients << client }
  end

  def get(client, path)
    id = client.request(:get, path)
    client.pump_until { client.response(id).finished? }
    client.response(id)
  end

  # Retry the block until it succeeds; the server handles a signal on its
  # next turn.
  def eventually(timeout: 5)
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
