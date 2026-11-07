# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "socket"
require "stringio"
require "net/http"
require "http3/net/http"

# Net::HTTP::Client over HTTP/3 (http3/net/http), as the prototype was
# tried: against HTTP3::Server in a child process, which each test that
# needs it starts. What the prototype gets wrong (the known defects at the
# top of http3/net/http.rb) is left out, as is what only a public server
# shows.
class TestNetHTTP < Minitest::Test
  include TestCertificates
  include TestServerProcess

  BIG_CHUNK = 16_384
  BIG_CHUNKS = 256
  # Longer than the request timeout of #test_request_timeout, by far.
  HANG = 5
  # The server's max_idle_timeout in #test_idle_connection_is_not_lent,
  # and how long the test leaves the connection alone.
  IDLE_TIMEOUT_NS = 1_000_000_000
  IDLE_WAIT = 2
  # The request body of #test_early_413, past the server's
  # max_request_body (1 MiB).
  TOO_LARGE = 4 << 20

  # A StringIO that counts the bytes read from it.
  class CountingIO < StringIO
    attr_reader :bytes_read

    def initialize(...)
      super
      @bytes_read = 0
    end

    def read(...)
      data = super
      @bytes_read += data.bytesize if data
      data
    end
  end

  def self.app
    lambda do |env|
      case env["PATH_INFO"]
      when "/hello"
        [200, {"content-type" => "text/plain"}, ["hello over h3\n"]]
      when "/echo"
        body = env["rack.input"].read
        [200, {"content-type" => "application/octet-stream", "x-request-bytes" => body.bytesize.to_s}, [body]]
      when "/big"
        [200, {"content-type" => "application/octet-stream"}, Enumerator.new { |y| BIG_CHUNKS.times { y << ("x" * BIG_CHUNK) } }]
      when "/hang"
        sleep HANG
        [200, {"content-type" => "text/plain"}, ["late\n"]]
      else
        [404, {"content-type" => "text/plain"}, ["not found\n"]]
      end
    end
  end

  def setup
    # Generated here, before a server process could make its own.
    credentials
    @dir = Dir.mktmpdir
    @pid = nil
  end

  def teardown
    Net::HTTP::Client.shutdown
    stop_server(@pid) if @pid
    FileUtils.remove_entry(@dir)
  end

  def test_get
    start_h3_server
    response = client.get("/hello")

    assert_equal "200", response.code
    assert_equal "hello over h3\n", response.body
    assert_equal "3", response.http_version
  end

  def test_reuses_the_connection
    start_h3_server
    sessions = record_sessions do
      c = client
      2.times { assert_equal "200", c.get("/hello").code }
    end

    assert_equal 1, sessions.size
    assert_equal 1, Net::HTTP::Client.pool_stats[:connections]
  end

  def test_post_bodies_come_back_as_sent
    start_h3_server
    c = client

    body = Random.new(1).bytes(200 * 1024)
    response = c.post("/echo", body: body, headers: {"content-type" => "application/octet-stream"})
    assert_equal body, response.body
    assert_equal body.bytesize.to_s, response["x-request-bytes"]

    assert_equal '{"name":"h3"}', c.post("/echo", json: {name: "h3"}).body
    assert_equal "c" * 300_000, c.post("/echo", body: StringIO.new("c" * 300_000)).body
    assert_equal "a" * 1_000_000, c.post("/echo", body: "a" * 1_000_000).body
  end

  # Past the server's max_request_body (1 MiB): it answers 413 before
  # reading the rest, which it stops with STOP_SENDING. Flow control, not
  # time, keeps the client from sending all of it: the server widens the
  # stream's window (256 KiB) only as it reads.
  def test_early_413
    start_h3_server
    c = client
    body = CountingIO.new("b" * TOO_LARGE)

    assert_equal "413", c.post("/echo", body: body).code
    assert_operator body.bytes_read, :<, TOO_LARGE
    assert_equal "200", c.get("/hello").code
    assert_equal 1, Net::HTTP::Client.pool_stats[:connections]
  end

  def test_streams_a_large_body
    start_h3_server
    total = 0
    client.stream(:get, "/big") do |response|
      response.each_body_chunk { |chunk| total += chunk.bytesize }
    end

    assert_equal BIG_CHUNK * BIG_CHUNKS, total
  end

  # Once only: a few more stall the connection (known defect 2).
  def test_leaving_a_response_early_keeps_the_connection
    start_h3_server
    c = client
    c.stream(:get, "/big") { |response| response.each_body_chunk { break } }

    assert_equal "200", c.get("/hello").code
    assert_equal 1, Net::HTTP::Client.pool_stats[:connections]
  end

  def test_not_found
    start_h3_server
    response = client.get("/missing")

    assert_equal "404", response.code
    assert_raises(Net::HTTP::Client::ResponseError) { response.raise_for_status }
  end

  def test_concurrent_requests_share_one_connection
    start_h3_server
    c = client
    codes = Array.new(8) { Thread.new { Array.new(5) { c.get("/hello").code } } }.flat_map(&:value)

    assert_equal ["200"] * 40, codes
    assert_equal 1, Net::HTTP::Client.pool_stats[:connections]
  end

  def test_per_request_protocols
    start_h3_server
    c = Net::HTTP.client("https://127.0.0.1:#{@port}", tls: {ca_file: credentials.ca_file}, timeout: 20)
    response = c.get("/hello", protocols: [:http3])

    assert_equal "200", response.code
    assert_equal "3", response.http_version
  end

  def test_request_timeout
    start_h3_server
    c = client

    assert_raises(Net::HTTP::Client::RequestTimeout) { c.get("/hang", timeout: 0.2) }
    assert_equal "200", c.get("/hello").code
    assert_equal 1, Net::HTTP::Client.pool_stats[:connections]
  end

  def test_certificate_verification
    start_h3_server
    url = "https://127.0.0.1:#{@port}"

    assert_raises(QUIC::Error::CertificateVerifyFailed) do
      Net::HTTP.client(url, protocols: [:http3], open_timeout: 5).get("/hello")
    end
    unverified = Net::HTTP.client(url, protocols: [:http3], tls: {verify_mode: OpenSSL::SSL::VERIFY_NONE}, timeout: 20)
    assert_equal "200", unverified.get("/hello").code
  end

  def test_closed_port
    sock = UDPSocket.new
    sock.bind("127.0.0.1", 0)
    port = sock.local_address.ip_port
    sock.close

    assert_raises(Errno::ECONNREFUSED) { client(port: port, open_timeout: 5).get("/hello") }
  end

  def test_unresponsive_peer
    sock = UDPSocket.new
    sock.bind("127.0.0.1", 0)
    error = assert_raises(Net::OpenTimeout) do
      client(port: sock.local_address.ip_port, open_timeout: 1).get("/hello")
    end

    assert_equal "QUIC handshake timeout", error.message
  ensure
    sock&.close
  end

  # A connection the server's max_idle_timeout has closed, though nothing
  # has driven it since, is not lent again. The closed session stays in the
  # pool until it reaps, so pool_stats does not tell.
  def test_idle_connection_is_not_lent
    start_h3_server(transport_params: QUIC::TransportParams.default.with(max_idle_timeout: IDLE_TIMEOUT_NS))
    sessions = record_sessions do |made|
      c = client
      assert_equal "200", c.get("/hello").code
      assert_equal 1, made.size
      refute_predicate made.first, :closed?
      sleep IDLE_WAIT
      assert_equal "200", c.get("/hello").code
    end

    assert_equal 2, sessions.size
    assert_predicate sessions.first, :closed?
  end

  def test_proxy
    error = assert_raises(Net::HTTP::Client::ProtocolError) do
      client(port: 1, proxy: "http://127.0.0.1:9").get("/hello")
    end

    assert_equal "HTTP/3 cannot be carried by an HTTP proxy", error.message
  end

  # HTTP/1.1 goes as before through the prepended ConnectionFactory.open,
  # which hands its http: (the Net::HTTP that the convenience methods pass)
  # on.
  def test_http1_unchanged
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.ip_port
    acceptor = Thread.new do
      loop do
        Thread.new(server.accept) do |sock|
          while (line = sock.gets) && line != "\r\n"
          end
          sock.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") if line
        ensure
          sock.close
        end
      end
    rescue IOError
      nil
    end

    response = Net::HTTP.client("http://127.0.0.1:#{port}", protocols: [:http1], timeout: 20).get("/")
    assert_equal "200", response.code
    assert_equal "ok", response.body
    assert_equal "ok", Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))

    client_class = Net::HTTP::Client
    options = client_class.const_get(:DEFAULTS).merge(protocols: [:http1], proxy: nil)
    http = Net::HTTP.new("127.0.0.1", port, nil)
    session = client_class.const_get(:ConnectionFactory).open(
      client_class::Request.new("GET", "http://127.0.0.1:#{port}/"), options,
      client_class.const_get(:Operation).new(options), nil, http: http
    )
    assert_same http, session.instance_variable_get(:@http)
    session.close
  ensure
    server&.close
    acceptor&.join(5)
  end

  # A failure on HTTP/1.1 comes out of the prepended
  # ConnectionFactory.open as it does from net-http's own: the HTTP/3
  # branch's rescue adds nothing to it.
  def test_http1_failures_unchanged
    client_class = Net::HTTP::Client
    factory = client_class.const_get(:ConnectionFactory)
    options = client_class.const_get(:DEFAULTS).merge(protocols: [:http1], proxy: nil)
    request = client_class::Request.new("GET", "http://127.0.0.1:1/")
    chain = lambda do |open|
      operation = client_class.const_get(:Operation).new(options)
      operation.cancel
      error = assert_raises(client_class::CancelledError) { open.call(request, options, operation, nil) }
      [error, error.cause, error.cause&.cause].map(&:class)
    end

    assert_equal chain.call(factory.method(:open).super_method), chain.call(factory.method(:open))
  end

  def test_argument_checks
    combined = ":http3 cannot be combined with other protocols"
    [[:http3, :http2], [:http3, :http1]].each do |protocols|
      assert_equal combined, assert_raises(ArgumentError) { Net::HTTP::Client.new(protocols: protocols) }.message
    end
    assert_equal combined, assert_raises(ArgumentError) {
      Net::HTTP.client("https://127.0.0.1:1").get("/", protocols: [:http3, :http2])
    }.message

    only = "protocols must contain :http1 and/or :http2"
    assert_equal only, assert_raises(ArgumentError) { Net::HTTP::Client.new(protocols: [:http3, :http4]) }.message
    assert_equal only, assert_raises(ArgumentError) { Net::HTTP::Client.new(protocols: [:http4]) }.message
    assert_equal "unknown options: bogus",
      assert_raises(ArgumentError) { Net::HTTP::Client.new(bogus: 1, protocols: [:http3, :http2]) }.message

    assert_equal "HTTP/3 requires HTTPS", assert_raises(Net::HTTP::Client::ProtocolError) {
      Net::HTTP.client("http://127.0.0.1:1", protocols: [:http3]).get("/")
    }.message
    assert_equal "TLS settings not supported over HTTP/3: verify_hostname", assert_raises(Net::HTTP::Client::ProtocolError) {
      client(port: 1, tls: {verify_hostname: false}).get("/")
    }.message
  end

  def test_check_client
    klass = Class.new do
      private

      def validate_options(_options)
      end
    end
    %i[ResponseMethods ResponseBody Clock Wait].each { |name| klass.const_set(name, Module.new) }

    error = assert_raises(LoadError) { HTTP3::NetHTTP.check_client(klass) }
    assert_equal "http3/net/http needs Net::HTTP::Client from net-http's http2 branch " \
      "(github.com/nurse/net-http) (missing: ConnectionFactory)", error.message
  end

  private

  def start_h3_server(**options)
    @pid, @port = start_server(
      log_path: File.join(@dir, "server.log"),
      certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path,
      **options
    ) { self.class.app }
  end

  # The ClientSessions made while the block runs, which it is given as they
  # are made.
  def record_sessions
    sessions = []
    new = HTTP3::NetHTTP::ClientSession.method(:new)
    HTTP3::NetHTTP::ClientSession.stub(:new, ->(*args) { new.call(*args).tap { |session| sessions << session } }) do
      yield sessions
    end
    sessions
  end

  # An HTTP/3 Client of the server, trusting its CA, with options over
  # these. timeout bounds a test that goes wrong.
  def client(port: @port, **options)
    defaults = {protocols: [:http3], tls: {ca_file: credentials.ca_file}, timeout: 20}
    Net::HTTP.client("https://127.0.0.1:#{port}", **defaults.merge(options))
  end
end
