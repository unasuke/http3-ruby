# frozen_string_literal: true

require "test_helper"

# HTTP3::Server, in a child process, when serving a connection fails.
class TestServerFailures < Minitest::Test
  include TestCertificates
  include TestServerProcess

  def setup
    @dir = Dir.mktmpdir("http3-failures-")
    @log_path = File.join(@dir, "server.log")
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    stop_server(@pid) if @pid
    FileUtils.remove_entry(@dir)
  end

  # The first connection's Session cannot be set up: that connection is
  # logged and closed, and the server goes on to serve the next one.
  #
  # The server closes the first one before its handshake has got far
  # enough for the client to read the CONNECTION_CLOSE, so the child
  # records the close itself, and the client only gives up on the
  # handshake.
  def test_connection_whose_session_cannot_be_set_up
    closes_path = File.join(@dir, "closes")
    @pid, @port = start_server(
      log_path: @log_path, certificate_path: credentials.certificate_path,
      private_key_path: credentials.private_key_path
    ) do
      failures = 1
      HTTP3::Session.singleton_class.prepend(Module.new do
        define_method(:attach) do |*args, **kwargs|
          if failures > 0
            failures -= 1
            raise "attach failed"
          end
          super(*args, **kwargs)
        end
      end)
      QUIC::Connection::Server.prepend(Module.new do
        define_method(:close) do |**kwargs|
          File.write(closes_path, "#{kwargs[:error_code]}\n", mode: "a")
          super(**kwargs)
        end
      end)
      ->(_env) { [200, {}, ["ok"]] }
    end

    assert_raises(QUIC::Error) { connect(handshake_timeout: 500_000_000) }
    assert_equal ["#{HTTP3::Nghttp3::H3_INTERNAL_ERROR}\n"], File.readlines(closes_path)
    assert_match(/ session_error remote=127\.0\.0\.1:\d+ error=RuntimeError message="attach failed" at=\S+$/,
      File.read(@log_path))

    client = connect
    id = client.request(:get, "/")
    client.pump_until { client.response(id).finished? }
    assert_equal "ok", client.response(id).body
  end

  private

  def connect(**settings)
    H3TestClient::QuicTransport.connect(@port, ca_file: credentials.ca_file, **settings).tap { |c| @clients << c }
  end
end
