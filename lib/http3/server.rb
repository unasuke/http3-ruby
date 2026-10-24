# frozen_string_literal: true

require "logger"
require "socket"

module HTTP3
  # An HTTP/3 server for a Rack 3 application, on one UDP address:
  #
  #   HTTP3::Server.new(
  #     app: app, bind: "192.0.2.1:443",
  #     certificate_path: "fullchain.pem", private_key_path: "privkey.pem"
  #   ).run
  #
  # #run serves until SIGTERM or SIGINT. It then sends GOAWAY to every
  # client, refuses new connections, and waits up to shutdown_timeout
  # seconds for the requests under way before closing every connection; a
  # second signal stops the wait. SIGHUP reads the certificate and key
  # again for new connections, and keeps the old ones if that fails.
  #
  # Only failures are logged, one line each: the event, then key=value
  # pairs. Requests are not logged; use Rack::CommonLogger for that. Query
  # strings and header values never appear in the log.
  class Server
    ALPN = ["h3"].freeze

    # What the signal handlers write to the self-pipe.
    SIGNALS = {"TERM" => "T", "INT" => "I", "HUP" => "H"}.freeze

    # The largest UDP payload read at once.
    RECV_SIZE = 65_535

    # Datagrams read per turn of the loop at most, so that a flood cannot
    # keep it from sending and running timers.
    RECV_BATCH = 1024

    # The address #run bound, an Addrinfo; nil until then. With port 0 in
    # bind, this tells the port.
    attr_reader :local_address

    # bind is "host:port" or "[v6]:port", one address; 0.0.0.0 and [::] are
    # refused, since the local address of each path has to be known.
    # certificate_path is a PEM chain, leaf first; private_key_path a PEM key
    # without passphrase. qlog_dir writes one qlog file per connection.
    # max_request_body and max_field_section_size (bytes) bound a request's
    # body (413 beyond) and header section (431 beyond).
    # max_connection_request_buffer bounds the bytes the requests of a
    # connection hold before they reach the application, and
    # max_total_request_buffer those of every connection; a request that
    # would pass either gets 503. They have to leave room for a request at
    # the other two limits, or ArgumentError is raised. send_buffer_size
    # bounds the bytes of a response body queued but unsent per stream.
    def initialize(app:, bind:, certificate_path:, private_key_path:, transport_params: nil, settings: nil,
      qlog_dir: nil, max_connections: 1024, max_request_body: 1_048_576, max_field_section_size: 65_536,
      max_connection_request_buffer: 4_194_304, max_total_request_buffer: 67_108_864,
      send_buffer_size: 65_536, shutdown_timeout: 30, logger: Logger.new($stderr))
      check_request_limits(max_request_body, max_field_section_size, max_connection_request_buffer,
        max_total_request_buffer)
      @adapter = RackAdapter.new(app)
      @bind_address = parse_bind(bind)
      @certificate_path = certificate_path
      @private_key_path = private_key_path
      @tls_context = new_tls_context
      @transport_params = transport_params || QUIC::TransportParams.default
      settings ||= QUIC::Settings.default
      settings = settings.with(qlog_dir: qlog_dir) if qlog_dir
      settings.check_qlog_dir
      @settings = settings
      @max_connections = max_connections
      @max_request_body = max_request_body
      @max_field_section_size = max_field_section_size
      @max_connection_request_buffer = max_connection_request_buffer
      @max_total_request_buffer = max_total_request_buffer
      @send_buffer_size = send_buffer_size
      @shutdown_timeout = shutdown_timeout
      @logger = logger
    end

    # Serve until told to stop (see the class comment). Returns nil.
    def run
      sig_r, sig_w = IO.pipe
      @sock = UDPSocket.new(@bind_address.afamily)
      @sock.bind(@bind_address.ip_address, @bind_address.ip_port)
      @local_address = @sock.local_address
      @endpoint = QUIC::Endpoint.new(
        local_address: @local_address, tls_context: @tls_context, transport_params: @transport_params,
        settings: @settings, max_connections: @max_connections
      )
      @sessions = {}
      @remotes = {}
      @request_buffer = Session.shared_buffer(@max_total_request_buffer)
      @blocked_send = nil
      @phase = :serving
      @drain_deadline = nil
      old_traps = install_traps(sig_w)

      turn(sig_r) until finished?
      close_connections
      nil
    ensure
      restore_traps(old_traps) if old_traps
      @sessions&.each_value { |session| release_session(session) }
      [@sock, sig_r, sig_w].each { |io| io.close if io && !io.closed? }
    end

    private

    # One turn of the loop.
    def turn(sig_r)
      writers = @blocked_send ? [@sock] : nil
      readable, writable, = IO.select([@sock, sig_r], writers, nil, select_timeout)
      handle_signals(sig_r) if readable&.include?(sig_r)
      flush if writable&.include?(@sock)
      receive if readable&.include?(@sock)
      serve_requests
      fill_bodies
      @endpoint.handle_expiry if due?(@endpoint.expiry)
      flush
      reap
    end

    def finished?
      case @phase
      when :serving then false
      when :draining then now >= @drain_deadline || @sessions.each_value.none?(&:busy?)
      else true
      end
    end

    # Until the next timer or the end of the drain, but no wait at all while
    # a body could take more.
    def select_timeout
      return 0 if @sessions.each_value.any? { |session| session.wants_fill?(@send_buffer_size) }

      timeouts = []
      expiry = @endpoint.expiry
      timeouts << [(expiry - now_ns) / 1e9, 0.0].max if expiry
      timeouts << [@drain_deadline - now, 0.0].max if @drain_deadline
      timeouts.min
    end

    # Read into one buffer reused for every datagram: a buffer of RECV_SIZE
    # per datagram would be garbage at once, and under a download the client
    # sends thousands of ACKs, enough to grow the process by tens of MiB
    # between GCs. read_pkt keeps nothing of the buffer.
    def receive
      @recv_buffer ||= String.new(capacity: RECV_SIZE, encoding: Encoding::BINARY)
      RECV_BATCH.times do
        result = @sock.recvfrom_nonblock(RECV_SIZE, 0, @recv_buffer, exception: false)
        break if result == :wait_readable

        data, sender_addr = result
        sender = Addrinfo.new(sender_addr, nil, :DGRAM)
        conn = @endpoint.read_pkt(data, remote: sender.to_sockaddr)
        next if conn.nil? || @sessions.key?(conn)

        @sessions[conn] = Session.attach(
          conn, max_request_body: @max_request_body, max_field_section_size: @max_field_section_size,
          max_connection_request_buffer: @max_connection_request_buffer, shared_buffer: @request_buffer
        )
        @remotes[conn] = sender
      end
    end

    def serve_requests
      @sessions.each do |conn, session|
        session.take_requests.each do |request, status|
          response = status ? Response.new(status: status, headers: [], body: nil) : call_app(conn, request)
          begin
            session.respond(request, response) { |error| log_body_error(conn, request, error) }
          rescue Nghttp3::Error
            # The stream went away while the application ran.
            discard_body(response.body)
          end
        end
      end
    end

    def call_app(conn, request)
      @adapter.call(request, remote: @remotes[conn])
    rescue => e
      log_app_error(conn, request, e)
      Response.new(status: 500, headers: [], body: nil)
    end

    def fill_bodies
      @sessions.each do |conn, session|
        session.fill_bodies(@send_buffer_size) { |request, error| log_app_error(conn, request, error) }
      end
    end

    # Send what the Endpoint has, until the socket would block.
    def flush
      loop do
        pkt, to = @blocked_send || @endpoint.write_pkt
        break if pkt.nil?

        result = begin
          @sock.sendmsg_nonblock(pkt, 0, to, exception: false)
        rescue SystemCallError
          # Unreachable, too large, ...: the datagram is lost, as on the
          # wire.
          nil
        end
        if result == :wait_writable
          @blocked_send = [pkt, to]
          break
        end
        @blocked_send = nil
      end
    end

    # Take out what has ended: streams within each Session, and whole
    # connections.
    def reap
      @sessions.each do |conn, session|
        if (error = session.take_error)
          log(:error, "session_error", remote: remote_of(conn), **error_fields(error))
        end
        session.release_closed { |stream_id, e| log_body_close_error(stream_id, e) }
      end
      @endpoint.take_closed.each do |conn|
        if conn.error
          log(:warn, "connection_error", remote: remote_of(conn), error: conn.error.class, message: conn.error.message)
        end
        session = @sessions.delete(conn)
        release_session(session) if session
        @remotes.delete(conn)
      end
    end

    def release_session(session)
      session.release_all { |stream_id, e| log_body_close_error(stream_id, e) }
    end

    def handle_signals(sig_r)
      bytes = sig_r.read_nonblock(64, exception: false)
      return unless bytes.is_a?(String)

      bytes.each_char { |byte| (byte == SIGNALS["HUP"]) ? reload_tls : begin_shutdown }
    end

    # First signal: GOAWAY and drain. Second: stop draining.
    def begin_shutdown
      if @phase == :serving
        @phase = :draining
        @drain_deadline = now + @shutdown_timeout
        @sessions.each_value(&:shutdown_notice)
        @endpoint.stop_accepting
      else
        @phase = :closing
      end
    end

    def reload_tls
      @endpoint.tls_context = new_tls_context
    rescue => e
      log(:error, "tls_reload_failed", certificate_path: @certificate_path, private_key_path: @private_key_path,
        error: e.class, message: e.message)
    end

    # Close every connection and send the CONNECTION_CLOSEs, without
    # waiting out the closing period.
    def close_connections
      @endpoint.connections.each do |conn|
        conn.close(error_code: Nghttp3::H3_NO_ERROR)
      rescue QUIC::Error
        nil
      end
      deadline = now + 1
      loop do
        flush
        break if @blocked_send.nil? || now >= deadline

        IO.select(nil, [@sock], nil, [deadline - now, 0].max)
      end
    end

    def new_tls_context
      QUIC::TLSContext.server(certificate_path: @certificate_path, private_key_path: @private_key_path, alpn: ALPN)
    end

    def install_traps(sig_w)
      SIGNALS.to_h do |name, byte|
        previous = Signal.trap(name) do
          sig_w.write_nonblock(byte, exception: false)
        rescue IOError
          nil
        end
        [name, previous]
      end
    end

    def restore_traps(previous)
      previous.each { |name, handler| Signal.trap(name, handler || "DEFAULT") }
    end

    # Raise ArgumentError for the first request limit found wrong: each has
    # to be an Integer in range, and the buffers have to let a request at
    # max_request_body and max_field_section_size through on a server with
    # nothing else under way.
    def check_request_limits(max_request_body, max_field_section_size, max_connection_request_buffer,
      max_total_request_buffer)
      unless max_request_body.is_a?(Integer) && max_request_body >= 0
        raise ArgumentError, "max_request_body must be an Integer of 0 or more (got #{max_request_body.inspect})"
      end
      # The range Session._attach takes, which would otherwise raise only
      # on the first connection.
      unless max_field_section_size.is_a?(Integer) && (1...2**62).cover?(max_field_section_size)
        raise ArgumentError, "max_field_section_size must be 1..2**62-1 (got #{max_field_section_size.inspect})"
      end
      {max_connection_request_buffer:, max_total_request_buffer:}.each do |name, value|
        raise ArgumentError, "#{name} must be a positive Integer (got #{value.inspect})" unless value.is_a?(Integer) && value.positive?
      end
      request = max_request_body + max_field_section_size
      if max_connection_request_buffer < request
        raise ArgumentError, "max_connection_request_buffer (#{max_connection_request_buffer}) must be at least " \
          "max_request_body + max_field_section_size (#{request})"
      end
      if max_total_request_buffer < max_connection_request_buffer
        raise ArgumentError, "max_total_request_buffer (#{max_total_request_buffer}) must be at least " \
          "max_connection_request_buffer (#{max_connection_request_buffer})"
      end
    end

    def parse_bind(bind)
      match = bind.match(/\A\[(?<host>[^\]]+)\]:(?<port>\d+)\z/) || bind.match(/\A(?<host>[^:\[\]]+):(?<port>\d+)\z/)
      raise ArgumentError, "bind must be \"host:port\" or \"[ipv6]:port\" (got #{bind.inspect})" unless match

      address = Addrinfo.udp(match[:host], Integer(match[:port], 10))
      if address.ip_address == "0.0.0.0" || address.ip_address == "::"
        raise ArgumentError, "bind must name the address to serve, not #{address.ip_address}"
      end
      address
    end

    def discard_body(body)
      return if body.nil?

      body.io.close if body.is_a?(Body::File) && !body.io.closed?
      body.rack_body.close if body.rack_body.respond_to?(:close)
    rescue => e
      log(:error, "body_close_error", **error_fields(e))
    end

    def log_app_error(conn, request, error)
      pseudo = request.headers.select { |name, _| name.start_with?(":") }.to_h
      path = pseudo.fetch(":path", "")[/\A[^?]*/]
      log(:error, "app_error", remote: remote_of(conn), stream: request.stream_id, method: pseudo[":method"],
        path: path, **error_fields(error))
    end

    def log_body_error(conn, request, error)
      log(:error, "body_error", remote: remote_of(conn), stream: request.stream_id, error: error.class,
        message: error.message)
    end

    def log_body_close_error(stream_id, error)
      log(:error, "body_close_error", stream: stream_id, error: error.class, message: error.message)
    end

    def error_fields(error)
      fields = {error: error.class, message: error.message}
      if (location = error.backtrace_locations&.first)
        fields[:at] = "#{location.path}:#{location.lineno}"
      end
      fields
    end

    # The event, then key=value; a value with a space, '"' or '=' is
    # written with String#inspect.
    def log(level, event, **fields)
      pairs = fields.map do |key, value|
        text = value.to_s
        "#{key}=#{text.match?(/[\s"=]/) ? text.inspect : text}"
      end
      @logger.public_send(level, [event, *pairs].join(" "))
    end

    def remote_of(conn)
      address = @remotes[conn] or return "-"
      host = address.ipv6? ? "[#{address.ip_address}]" : address.ip_address
      "#{host}:#{address.ip_port}"
    end

    def due?(expiry)
      expiry && expiry <= now_ns
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def now_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end
  end
end
