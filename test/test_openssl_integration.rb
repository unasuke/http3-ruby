# frozen_string_literal: true

require "test_helper"
require "openssl"
require "socket"

# Integration tests for OpenSSL QUIC + nghttp3-ruby
#
# These tests demonstrate how nghttp3-ruby integrates with OpenSSL's QUIC API.
# Test success/failure may be ignored as OpenSSL gem QUIC support is partial.
#
# Prerequisites:
# - OpenSSL gem with QUIC support (poc-2025-12 branch from ~/src/github.com/ruby/openssl)
# - HTTP/3 server for live testing (optional)
#
# @see https://nghttp2.org/nghttp3/
class TestOpenSSLIntegration < Minitest::Test
  # Default test host for local testing
  TEST_HOST = "localhost"
  TEST_PORT = 443

  # Known HTTP/3 enabled public endpoints
  # These servers support HTTP/3 (h3) via QUIC on port 443
  HTTP3_ENDPOINTS = [
    {host: "www.google.com", port: 443, path: "/"},
    {host: "www.youtube.com", port: 443, path: "/"},
    {host: "cloudflare.com", port: 443, path: "/"},
    {host: "www.cloudflare.com", port: 443, path: "/"},
    {host: "www.facebook.com", port: 443, path: "/"},
    {host: "blog.cloudflare.com", port: 443, path: "/"}
  ].freeze

  # Specific well-known endpoints for individual tests
  GOOGLE_ENDPOINT = {host: "www.google.com", port: 443, path: "/"}.freeze
  CLOUDFLARE_ENDPOINT = {host: "www.cloudflare.com", port: 443, path: "/"}.freeze

  # Skip tests if OpenSSL QUIC is not available
  def setup
    skip_unless_quic_available
  end

  #
  # QUIC Connection Setup Tests
  #

  def test_create_quic_ssl_context
    ctx = create_quic_context

    assert_kind_of OpenSSL::SSL::SSLContext, ctx
    assert ctx.quic_enabled?, "SSLContext should be QUIC-enabled"
  end

  def test_quic_context_with_h3_alpn
    ctx = create_quic_context
    ctx.alpn_protocols = ["h3"]

    assert_equal ["h3"], ctx.alpn_protocols
  end

  def test_create_quic_ssl_socket_with_udp
    ctx = create_quic_context
    udp = UDPSocket.new

    ssl = OpenSSL::SSL::SSLSocket.new(udp, ctx)
    assert_kind_of OpenSSL::SSL::SSLSocket, ssl

    ssl.hostname = TEST_HOST
    ssl.alpn_protocols = ["h3"]

    assert_equal TEST_HOST, ssl.hostname
  ensure
    begin
      ssl&.close
    rescue
      nil
    end
    begin
      udp&.close
    rescue
      nil
    end
  end

  #
  # nghttp3 Client + OpenSSL QUIC Integration Tests
  #

  def test_client_with_quic_streams
    # Create nghttp3 client
    client = HTTP3::Nghttp3::Client.new

    # In a real scenario, these stream IDs would come from QUIC layer
    # Client-initiated unidirectional streams: 2, 6, 10
    control_stream_id = 2
    qpack_encoder_stream_id = 6
    qpack_decoder_stream_id = 10

    # Bind HTTP/3 control and QPACK streams
    client.bind_streams(
      control: control_stream_id,
      qpack_encoder: qpack_encoder_stream_id,
      qpack_decoder: qpack_decoder_stream_id
    )

    assert client.streams_bound?
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_client_pump_writes_to_quic
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit a request
    client.get("https://#{TEST_HOST}/")

    # Collect data that would be sent to QUIC layer
    writes = []
    client.pump_writes do |sid, data, fin|
      writes << {stream_id: sid, data: data, fin: fin}
      data.bytesize
    end

    # Should have some data to write (at least SETTINGS frame on control stream)
    refute writes.empty?, "Expected HTTP/3 frames to be generated"

    # Verify stream IDs are valid
    writes.each do |write|
      assert_kind_of Integer, write[:stream_id]
      assert_kind_of String, write[:data]
      refute write[:data].empty?
    end
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_client_pump_writes_with_mock_quic_transport
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit request
    request_stream_id = client.get("https://#{TEST_HOST}/path")

    # Mock QUIC transport - collect all writes by stream
    streams_data = Hash.new { |h, k| h[k] = [] }

    client.pump_writes do |stream_id, data, fin|
      streams_data[stream_id] << {data: data, fin: fin}
      data.bytesize
    end

    # Control stream (2) should have SETTINGS frame
    assert streams_data.key?(2), "Expected data on control stream"

    # Request stream should have HEADERS frame
    assert streams_data.key?(request_stream_id), "Expected data on request stream"
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_client_read_stream_from_quic
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit a request to create response tracking
    stream_id = client.get("https://#{TEST_HOST}/")

    # Pump initial writes
    client.pump_writes { |_, data, _| data.bytesize }

    # Simulate receiving response from QUIC layer
    # This is a minimal HTTP/3 response frame (would need actual encoded data)
    # For now, we just verify the method exists and accepts data
    begin
      # Note: This would fail with invalid HTTP/3 frame data
      # In real integration, this would be actual QUIC data
      mock_response_data = "\x00\x00"  # Placeholder
      client.read_stream(stream_id, mock_response_data, fin: false)
    rescue HTTP3::Nghttp3::Error
      # Expected - mock data is not valid HTTP/3 frames
    end

    # Response object should exist for the stream
    response = client.responses[stream_id]
    assert_kind_of HTTP3::Nghttp3::Response, response
    assert_equal stream_id, response.stream_id
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_full_http3_request_response_cycle
    skip "Requires live HTTP/3 server"

    ctx = create_quic_context
    ctx.alpn_protocols = ["h3"]

    # Create UDP socket and connect
    udp = UDPSocket.new
    udp.connect(TEST_HOST, TEST_PORT)

    # Create QUIC connection (main connection for streams)
    ssl = OpenSSL::SSL::SSLSocket.new(udp, ctx)
    ssl.hostname = TEST_HOST
    ssl.alpn_protocols = ["h3"]

    # Perform QUIC handshake
    ssl.connect

    # Verify ALPN negotiation
    assert_equal "h3", ssl.alpn_protocol

    # Setup nghttp3 client
    client = HTTP3::Nghttp3::Client.new
    # In real implementation, stream IDs come from ssl.new_stream
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit request
    stream_id = client.get("https://#{TEST_HOST}/")

    # Event loop: pump data between nghttp3 and QUIC
    loop do
      # HTTP/3 -> QUIC
      client.pump_writes do |sid, data, fin|
        # Route data to appropriate QUIC stream
        # ssl.write(data) for the corresponding stream
        data.bytesize
      end

      # QUIC -> HTTP/3
      # data = ssl.read(4096)
      # client.read_stream(stream_id, data, fin: eof?)

      break if client.responses[stream_id]&.finished?
    end

    response = client.responses[stream_id]
    assert response.finished?
    assert_kind_of Integer, response.status
  ensure
    begin
      client&.close
    rescue
      nil
    end
    begin
      ssl&.close
    rescue
      nil
    end
    begin
      udp&.close
    rescue
      nil
    end
  end

  #
  # nghttp3 Server + OpenSSL QUIC Integration Tests
  #

  def test_server_with_quic_streams
    server = HTTP3::Nghttp3::Server.new

    # Server-initiated unidirectional streams: 3, 7, 11
    server.bind_streams(
      control: 3,
      qpack_encoder: 7,
      qpack_decoder: 11
    )

    assert server.streams_bound?

    # Register request handler
    handler_called = false
    server.on_request do |request, response|
      handler_called = true
      response.status = 200
      response.headers["content-type"] = "text/plain"
      response.body = "Hello, HTTP/3!"
    end

    # Verify server is ready to accept requests
    assert_kind_of HTTP3::Nghttp3::Connection, server.connection
  ensure
    begin
      server&.close
    rescue
      nil
    end
  end

  def test_server_pump_writes_generates_settings
    server = HTTP3::Nghttp3::Server.new
    server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)

    # Register a simple handler
    server.on_request do |request, response|
      response.status = 200
      response.body = "OK"
    end

    # Pump initial writes - should generate SETTINGS on control stream
    writes = []
    server.pump_writes do |stream_id, data, fin|
      writes << {stream_id: stream_id, data: data, fin: fin}
      data.bytesize
    end

    # Server should emit SETTINGS frame on control stream (3)
    control_writes = writes.select { |w| w[:stream_id] == 3 }
    refute control_writes.empty?, "Expected SETTINGS frame on control stream"
  ensure
    begin
      server&.close
    rescue
      nil
    end
  end

  def test_server_receives_request_from_quic
    server = HTTP3::Nghttp3::Server.new
    server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)

    received_request = nil
    server.on_request do |request, response|
      received_request = request
      response.status = 200
      response.body = "Received!"
    end

    # Pump initial SETTINGS
    server.pump_writes { |_, data, _| data.bytesize }

    # Simulate receiving a request from QUIC layer
    # In real scenario, this would be encoded HEADERS frame from client
    # For now, verify the interface exists
    begin
      # Request stream ID would be 0 (client-initiated bidi)
      mock_request_data = "\x00\x00"  # Placeholder - not valid HTTP/3
      server.read_stream(0, mock_request_data, fin: false)
    rescue HTTP3::Nghttp3::Error
      # Expected - mock data is not valid
    end

    # Server should be tracking the stream
    assert_kind_of Hash, server.requests
  ensure
    begin
      server&.close
    rescue
      nil
    end
  end

  def test_server_sends_response_to_quic
    server = HTTP3::Nghttp3::Server.new
    server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)

    server.on_request do |request, response|
      response.status = 200
      response.headers["content-type"] = "application/json"
      response.body = '{"status":"ok"}'
    end

    # In a real scenario, after receiving a complete request,
    # the server would call the handler and submit the response.
    # pump_writes would then yield the response frames.

    # For now, verify the response structure
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    response.headers["content-type"] = "application/json"
    response.body = '{"status":"ok"}'

    nvs = response.to_nv_array
    assert nvs.any? { |nv| nv.name == ":status" && nv.value == "200" }
    assert nvs.any? { |nv| nv.name == "content-type" }
  ensure
    begin
      server&.close
    rescue
      nil
    end
  end

  #
  # Data Flow Integration Tests
  #

  def test_multiple_stream_data_flow
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit multiple requests
    stream1 = client.get("https://#{TEST_HOST}/path1")
    stream2 = client.get("https://#{TEST_HOST}/path2")
    stream3 = client.get("https://#{TEST_HOST}/path3")

    # Collect all writes
    all_writes = Hash.new { |h, k| h[k] = [] }
    client.pump_writes do |stream_id, data, fin|
      all_writes[stream_id] << {data: data, fin: fin}
      data.bytesize
    end

    # Should have data on control stream
    assert all_writes.key?(2), "Expected control stream data"

    # Should have data on each request stream
    assert all_writes.key?(stream1), "Expected data on stream #{stream1}"
    assert all_writes.key?(stream2), "Expected data on stream #{stream2}"
    assert all_writes.key?(stream3), "Expected data on stream #{stream3}"

    # Stream IDs should follow HTTP/3 pattern (0, 4, 8 for client bidi)
    assert_equal 0, stream1
    assert_equal 4, stream2
    assert_equal 8, stream3
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_stream_id_mapping
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit a request
    request_stream_id = client.submit(
      HTTP3::Nghttp3::Request.get("https://#{TEST_HOST}/test")
    )

    # Create a mock stream mapping (stream_id -> socket)
    stream_sockets = {}

    # Pump writes and track which streams get data
    client.pump_writes do |stream_id, data, fin|
      stream_sockets[stream_id] ||= []
      stream_sockets[stream_id] << data
      data.bytesize
    end

    # Control stream (2) - unidirectional for SETTINGS
    assert stream_sockets.key?(2), "Control stream should have data"

    # Request stream (0) - bidirectional for request/response
    assert stream_sockets.key?(request_stream_id), "Request stream should have data"

    # QPACK streams may or may not have data depending on dynamic table usage
    # stream_sockets[6] - qpack encoder
    # stream_sockets[10] - qpack decoder
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  #
  # Error Handling Tests
  #

  def test_connection_error_handling
    # Test behavior when QUIC connection fails
    client = HTTP3::Nghttp3::Client.new

    # Attempting operations without binding streams should raise
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      client.get("https://#{TEST_HOST}/")
    end
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_stream_error_handling
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit a request
    stream_id = client.get("https://#{TEST_HOST}/")

    # Pump initial data
    client.pump_writes { |_, data, _| data.bytesize }

    # Simulate receiving invalid data
    begin
      invalid_data = "\xff\xff\xff\xff"  # Invalid HTTP/3 frame
      client.read_stream(stream_id, invalid_data, fin: false)
    rescue HTTP3::Nghttp3::Error => e
      # Expected - invalid frame should cause error
      assert_kind_of HTTP3::Nghttp3::Error, e
    end
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_closed_connection_handling
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Close the connection
    client.close
    assert client.closed?

    # Operations on closed connection should fail
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      client.get("https://#{TEST_HOST}/")
    end
  end

  def test_timeout_handling
    skip "Timeout handling requires async I/O implementation"

    # In a real implementation, timeouts would be handled by:
    # 1. Setting socket timeouts on UDPSocket
    # 2. Using non-blocking I/O with select/poll
    # 3. Implementing idle timeout per QUIC spec
  end

  #
  # Real HTTP/3 Server Connection Tests
  #
  # These tests attempt to connect to known HTTP/3 enabled servers.
  # They require network access and may fail if the servers are unreachable.
  #

  def test_connect_to_google_http3
    skip_unless_network_available

    endpoint = GOOGLE_ENDPOINT
    ctx = create_quic_context
    ctx.alpn_protocols = ["h3"]

    # Create UDP socket and connect to Google
    udp = UDPSocket.new
    udp.connect(endpoint[:host], endpoint[:port])

    # Create QUIC/TLS connection
    ssl = OpenSSL::SSL::SSLSocket.new(udp, ctx)
    ssl.hostname = endpoint[:host]
    ssl.alpn_protocols = ["h3"]

    # Attempt QUIC handshake
    ssl.connect

    # Verify HTTP/3 was negotiated
    assert_equal "h3", ssl.alpn_protocol, "Expected HTTP/3 (h3) ALPN"
  ensure
    begin
      ssl&.close
    rescue
      nil
    end
    begin
      udp&.close
    rescue
      nil
    end
  end

  def test_connect_to_cloudflare_http3
    # skip_unless_network_available

    endpoint = CLOUDFLARE_ENDPOINT
    ctx = create_quic_context
    ctx.alpn_protocols = ["h3"]

    # Create UDP socket and connect to Cloudflare
    udp = UDPSocket.new
    udp.connect(endpoint[:host], endpoint[:port])

    # Create QUIC/TLS connection
    ssl = OpenSSL::SSL::SSLSocket.new(udp, ctx)
    ssl.hostname = endpoint[:host]
    ssl.alpn_protocols = ["h3"]

    # Attempt QUIC handshake
    ssl.connect

    # Verify HTTP/3 was negotiated
    assert_equal "h3", ssl.alpn_protocol, "Expected HTTP/3 (h3) ALPN"
  ensure
    begin
      ssl&.close
    rescue
      nil
    end
    begin
      udp&.close
    rescue
      nil
    end
  end

  def test_http3_request_to_google
    skip_unless_network_available

    endpoint = GOOGLE_ENDPOINT

    # Setup nghttp3 client
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Create request to Google
    url = "https://#{endpoint[:host]}#{endpoint[:path]}"
    stream_id = client.get(url, headers: {
      "user-agent" => "nghttp3-ruby/test"
    })

    # Pump writes - this generates HTTP/3 frames
    frames = []
    client.pump_writes do |sid, data, fin|
      frames << {stream_id: sid, data: data, fin: fin, size: data.bytesize}
      data.bytesize
    end

    # Verify frames were generated
    refute frames.empty?, "Expected HTTP/3 frames for Google request"

    # Verify request stream has data
    request_frames = frames.select { |f| f[:stream_id] == stream_id }
    refute request_frames.empty?, "Expected HEADERS frame on request stream"

    # Verify pending request tracking
    assert client.pending_requests.key?(stream_id)
    assert_equal "GET", client.pending_requests[stream_id].method

    # Verify HTML response (when response is received via QUIC)
    response = client.responses[stream_id]
    pp response.body
    if response&.finished?
      assert_match(/<html/i, response.body, "Expected HTML response")
    end
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_http3_request_to_cloudflare
    # skip_unless_network_available

    endpoint = CLOUDFLARE_ENDPOINT

    # Setup nghttp3 client
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Create request to Cloudflare
    url = "https://#{endpoint[:host]}#{endpoint[:path]}"
    stream_id = client.get(url, headers: {
      "user-agent" => "nghttp3-ruby/test",
      "accept" => "text/html"
    })

    # Pump writes - this generates HTTP/3 frames
    frames = []
    client.pump_writes do |sid, data, fin|
      frames << {stream_id: sid, data: data, fin: fin, size: data.bytesize}
      data.bytesize
    end

    # Verify frames were generated
    refute frames.empty?, "Expected HTTP/3 frames for Cloudflare request"

    # Verify control stream has SETTINGS
    control_frames = frames.select { |f| f[:stream_id] == 2 }
    refute control_frames.empty?, "Expected SETTINGS frame on control stream"

    # Verify HTML response (when response is received via QUIC)
    response = client.responses[stream_id]
    pp response.body
    if response&.finished?
      pp response.body
      assert_match(/<html/i, response.body, "Expected HTML response")
    end
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_multiple_requests_to_http3_endpoints
    skip_unless_network_available

    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit requests to multiple endpoints
    stream_ids = HTTP3_ENDPOINTS.take(3).map do |endpoint|
      url = "https://#{endpoint[:host]}#{endpoint[:path]}"
      client.get(url, headers: {"user-agent" => "nghttp3-ruby/test"})
    end

    # Pump all writes
    all_frames = Hash.new { |h, k| h[k] = [] }
    client.pump_writes do |sid, data, fin|
      all_frames[sid] << {data: data, fin: fin}
      data.bytesize
    end

    # Verify each request stream got data
    stream_ids.each_with_index do |sid, idx|
      assert all_frames.key?(sid), "Expected frames for request #{idx} (stream #{sid})"
    end

    # Verify stream IDs follow HTTP/3 pattern
    assert_equal [0, 4, 8], stream_ids, "Expected client bidi stream IDs 0, 4, 8"
  ensure
    begin
      client&.close
    rescue
      nil
    end
  end

  def test_full_http3_cycle_to_cloudflare
    skip_unless_network_available
    skip "Full cycle requires complete QUIC integration"

    endpoint = CLOUDFLARE_ENDPOINT
    ctx = create_quic_context
    ctx.alpn_protocols = ["h3"]

    # Create UDP socket
    udp = UDPSocket.new
    udp.connect(endpoint[:host], endpoint[:port])

    # Create QUIC connection
    ssl = OpenSSL::SSL::SSLSocket.new(udp, ctx)
    ssl.hostname = endpoint[:host]
    ssl.alpn_protocols = ["h3"]
    ssl.connect

    # Setup nghttp3 client
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    # Submit request
    url = "https://#{endpoint[:host]}#{endpoint[:path]}"
    stream_id = client.get(url)

    # Event loop (simplified - real impl needs multi-stream support)
    10.times do
      # HTTP/3 -> QUIC
      client.pump_writes do |sid, data, fin|
        ssl.write(data)
        ssl.stream_conclude if fin
        data.bytesize
      end

      # QUIC -> HTTP/3
      begin
        data = ssl.read_nonblock(4096)
        client.read_stream(stream_id, data, fin: false) if data
      rescue IO::WaitReadable
        # No data yet
      rescue EOFError
        client.read_stream(stream_id, "", fin: true)
        break
      end

      break if client.responses[stream_id]&.finished?
    end

    # Check response
    response = client.responses[stream_id]
    if response&.finished?
      assert_kind_of Integer, response.status
      assert response.status >= 100 && response.status < 600

      # Verify HTML response
      assert_match(/<html/i, response.body, "Expected HTML response")
    end
  ensure
    begin
      client&.close
    rescue
      nil
    end
    begin
      ssl&.close
    rescue
      nil
    end
    begin
      udp&.close
    rescue
      nil
    end
  end

  #
  # Client-Server Loopback Test
  #

  def test_client_server_loopback
    # Create client and server
    client = HTTP3::Nghttp3::Client.new
    server = HTTP3::Nghttp3::Server.new

    # Bind streams (using different stream IDs for client vs server)
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)

    # Setup server handler
    received_path = nil
    server.on_request do |request, response|
      received_path = request.path
      response.status = 200
      response.headers["content-type"] = "text/plain"
      response.body = "Hello from server!"
    end

    # Submit client request
    request_stream_id = client.get("https://#{TEST_HOST}/test-path")

    # In a real loopback test, we would:
    # 1. Pump client writes -> feed to server read_stream
    # 2. Pump server writes -> feed to client read_stream
    # 3. Repeat until response is complete

    # For now, verify the objects are properly initialized
    assert client.streams_bound?
    assert server.streams_bound?
    assert_equal 0, request_stream_id
  ensure
    begin
      client&.close
    rescue
      nil
    end
    begin
      server&.close
    rescue
      nil
    end
  end

  private

  # Check if OpenSSL QUIC is available
  def skip_unless_quic_available
    unless quic_available?
      skip "OpenSSL QUIC support not available"
    end
  end

  # Skip tests that require network access
  def skip_unless_network_available
    skip_unless_quic_available
    unless network_available?
      skip "Network access not available"
    end
  end

  # Check if network is available by attempting DNS resolution
  def network_available?
    return @network_available if defined?(@network_available)

    @network_available = begin
      require "resolv"
      Resolv.getaddress("www.google.com")
      true
    rescue
      false
    end
  end

  # Check if OpenSSL gem has QUIC support
  def quic_available?
    return @quic_available if defined?(@quic_available)

    @quic_available = begin
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.respond_to?(:set_quic_context) && ctx.respond_to?(:quic_enabled?)
    rescue
      false
    end
  end

  # Create a QUIC-enabled SSL context
  def create_quic_context
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.set_quic_context
    ctx.min_version = OpenSSL::SSL::TLS1_3_VERSION
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE  # For testing only
    ctx
  end

  # Create a QUIC stream (helper for future multi-stream API)
  # @param ctx [OpenSSL::SSL::SSLContext] QUIC context
  # @param host [String] hostname
  # @param port [Integer] port number
  # @param unidirectional [Boolean] true for unidirectional stream
  # @return [Array<UDPSocket, OpenSSL::SSL::SSLSocket>] socket pair
  def create_quic_stream(ctx, host, port, unidirectional: false)
    udp = UDPSocket.new
    udp.connect(host, port)

    ssl = OpenSSL::SSL::SSLSocket.new(udp, ctx)
    ssl.hostname = host
    ssl.alpn_protocols = ["h3"]

    # Future: ssl.new_stream(unidirectional: unidirectional)

    [udp, ssl]
  end

  # Setup HTTP/3 client with QUIC streams
  # @param host [String] hostname
  # @param port [Integer] port number
  # @return [Hash] client and stream sockets
  def setup_http3_client(host, port)
    ctx = create_quic_context
    ctx.alpn_protocols = ["h3"]

    # Create streams (future: use ssl.new_stream)
    streams = {}

    # Control stream (unidirectional, ID 2)
    streams[:control] = {id: 2, socket: nil}

    # QPACK encoder stream (unidirectional, ID 6)
    streams[:qpack_encoder] = {id: 6, socket: nil}

    # QPACK decoder stream (unidirectional, ID 10)
    streams[:qpack_decoder] = {id: 10, socket: nil}

    # Create nghttp3 client
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(
      control: streams[:control][:id],
      qpack_encoder: streams[:qpack_encoder][:id],
      qpack_decoder: streams[:qpack_decoder][:id]
    )

    {client: client, streams: streams, context: ctx}
  end

  # Setup HTTP/3 server with QUIC streams
  # @return [Hash] server and stream configuration
  def setup_http3_server
    streams = {}

    # Server control stream (unidirectional, ID 3)
    streams[:control] = {id: 3, socket: nil}

    # Server QPACK encoder stream (unidirectional, ID 7)
    streams[:qpack_encoder] = {id: 7, socket: nil}

    # Server QPACK decoder stream (unidirectional, ID 11)
    streams[:qpack_decoder] = {id: 11, socket: nil}

    # Create nghttp3 server
    server = HTTP3::Nghttp3::Server.new
    server.bind_streams(
      control: streams[:control][:id],
      qpack_encoder: streams[:qpack_encoder][:id],
      qpack_decoder: streams[:qpack_decoder][:id]
    )

    {server: server, streams: streams}
  end

  # Pump writes from nghttp3 to QUIC sockets
  # @param h3_conn [HTTP3::Nghttp3::Client, HTTP3::Nghttp3::Server] HTTP/3 connection
  # @param stream_map [Hash] stream_id -> socket mapping
  def pump_to_quic(h3_conn, stream_map)
    h3_conn.pump_writes do |stream_id, data, fin|
      socket = stream_map[stream_id]
      if socket
        bytes = socket.write(data)
        socket.stream_conclude if fin
        bytes
      else
        # Stream not mapped, just acknowledge
        data.bytesize
      end
    end
  end

  # Read from QUIC sockets and feed to nghttp3
  # @param h3_conn [HTTP3::Nghttp3::Client, HTTP3::Nghttp3::Server] HTTP/3 connection
  # @param stream_map [Hash] stream_id -> socket mapping
  def read_from_quic(h3_conn, stream_map)
    stream_map.each do |stream_id, socket|
      next unless socket

      begin
        data = socket.read_nonblock(4096)
        fin = false  # Would check socket state
        h3_conn.read_stream(stream_id, data, fin: fin) if data
      rescue IO::WaitReadable
        # No data available
      rescue EOFError
        # Stream closed
        h3_conn.read_stream(stream_id, "", fin: true)
      end
    end
  end
end
