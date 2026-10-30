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
  # strings and header values never appear in the log. Those answered
  # without the application (400, 408, 413, 431, 501, 503) are counted
  # instead: refusal_log_interval seconds after the first of them, and when
  # #run ends, a warn line per status tells how many there were since,
  # such as "requests_refused status=503 count=1234 seconds=60".
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
    # body (413 beyond) and header section (431 beyond). A body over
    # request_body_buffer_size bytes is written to a temporary file in
    # Dir.tmpdir. max_connection_request_buffer bounds the bytes of memory
    # the requests of a connection hold before they reach the application,
    # and max_total_request_buffer those of every connection;
    # max_connection_request_spool and max_total_request_spool bound the
    # bytes in temporary files, which stay open until the response body is
    # done, and max_connection_request_spool_files and
    # max_total_request_spool_files the files open at once. A request that would pass any of them, or
    # whose file cannot be made or written, gets 503. They have to leave
    # room for a request at the limits on a server with nothing else under
    # way, or ArgumentError is raised; and when bodies may go to files,
    # Dir.tmpdir has to take one, or SystemCallError is. send_buffer_size
    # bounds the bytes of a response body queued but unsent per stream,
    # max_connection_send_buffer those of the array and each bodies of a
    # connection, and max_total_send_buffer those of every connection; a
    # body waits for room. Each has to be at least the one before. A request
    # not received in full within request_timeout seconds of the start of
    # its headers gets 408; nil is no limit. refusal_log_interval is the
    # seconds between the requests_refused lines (see above).
    def initialize(app:, bind:, certificate_path:, private_key_path:, transport_params: nil, settings: nil,
      qlog_dir: nil, max_connections: 1024, max_request_body: 1_048_576, max_field_section_size: 65_536,
      max_connection_request_buffer: 4_194_304, max_total_request_buffer: 67_108_864,
      request_body_buffer_size: 65_536, max_connection_request_spool: 16_777_216,
      max_total_request_spool: 1_073_741_824, max_connection_request_spool_files: 16,
      max_total_request_spool_files: 256,
      send_buffer_size: 65_536, max_connection_send_buffer: 1_048_576, max_total_send_buffer: 67_108_864,
      request_timeout: 30, refusal_log_interval: 60, shutdown_timeout: 30, logger: Logger.new($stderr))
      check_request_limits(max_request_body:, max_field_section_size:, max_connection_request_buffer:,
        max_total_request_buffer:, request_body_buffer_size:, max_connection_request_spool:,
        max_total_request_spool:, max_connection_request_spool_files:, max_total_request_spool_files:)
      # Found out now rather than by the first large request.
      Session.spool_file.close if max_request_body > request_body_buffer_size
      check_send_limits(send_buffer_size, max_connection_send_buffer, max_total_send_buffer)
      check_request_timeout(request_timeout)
      check_refusal_log_interval(refusal_log_interval)
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
      @request_body_buffer_size = request_body_buffer_size
      @max_connection_request_spool = max_connection_request_spool
      @max_total_request_spool = max_total_request_spool
      @max_connection_request_spool_files = max_connection_request_spool_files
      @max_total_request_spool_files = max_total_request_spool_files
      @send_buffer_size = send_buffer_size
      @max_connection_send_buffer = max_connection_send_buffer
      @max_total_send_buffer = max_total_send_buffer
      @request_timeout = request_timeout
      @refusal_log_interval = refusal_log_interval
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
      @request_spool = Session.shared_spool(@max_total_request_spool, files: @max_total_request_spool_files)
      # When request_spool_failed was last logged; nil until then.
      @spool_failure_logged_at = nil
      @blocked_send = nil
      @phase = :serving
      @drain_deadline = nil
      # {status => count} of the requests answered without the
      # application, since @refusals_since.
      @refusals = Hash.new(0)
      @refusals_since = nil
      old_traps = install_traps(sig_w)

      turn(sig_r) until finished?
      close_connections
      log_refusals
      nil
    ensure
      restore_traps(old_traps) if old_traps
      @sessions&.each_value { |session| release_session(session) }
      [@sock, sig_r, sig_w].each { |io| io.close if io && !io.closed? }
    end

    private

    # One turn of the loop. The room left in max_total_send_buffer is
    # counted once, at the start. Only fill_bodies queues more, so until
    # then the room can only have grown (nghttp3 taking what flush sends),
    # and filling by the room counted queues no more than the limit allows.
    def turn(sig_r)
      room = send_room
      writers = @blocked_send ? [@sock] : nil
      readable, writable, = IO.select([@sock, sig_r], writers, nil, select_timeout(room))
      handle_signals(sig_r) if readable&.include?(sig_r)
      flush if writable&.include?(@sock)
      receive if readable&.include?(@sock)
      expire_requests
      serve_requests
      log_refusals if refusals_due?
      fill_bodies(room)
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

    # Until the next timer, the next request to run out of time, the next
    # requests_refused lines or the end of the drain, but no wait at all
    # while a body could take more within the send buffers.
    def select_timeout(room)
      wants_fill = @sessions.each_value.any? { |session|
        session.wants_fill?(@send_buffer_size, connection_limit: @max_connection_send_buffer, room: room)
      }
      return 0 if wants_fill

      timeouts = []
      expiry = @endpoint.expiry
      timeouts << [(expiry - now_ns) / 1e9, 0.0].max if expiry
      deadline = @sessions.each_value.filter_map(&:next_request_deadline).min
      timeouts << [deadline - now, 0.0].max if deadline
      timeouts << [refusal_log_at - now, 0.0].max if refusal_log_at
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

        attach_session(conn, sender)
      end
    end

    # Serve a new connection. One whose Session cannot be set up is logged
    # and closed, and the loop goes on with the others.
    def attach_session(conn, sender)
      @sessions[conn] = Session.attach(
        conn, max_request_body: @max_request_body, max_field_section_size: @max_field_section_size,
        max_connection_request_buffer: @max_connection_request_buffer, shared_buffer: @request_buffer,
        request_timeout: @request_timeout, request_body_buffer_size: @request_body_buffer_size,
        max_connection_request_spool: @max_connection_request_spool,
        max_connection_request_spool_files: @max_connection_request_spool_files, shared_spool: @request_spool
      )
      @remotes[conn] = sender
    rescue => e
      log(:error, "session_error", remote: format_remote(sender), **error_fields(e))
      begin
        conn.close(error_code: Nghttp3::H3_INTERNAL_ERROR)
      rescue QUIC::Error
        nil
      end
    end

    # Refuse with 408 the requests that ran out of time; serve_requests
    # answers them.
    def expire_requests
      at = now
      @sessions.each_value { |session| session.expire_requests(at) }
    end

    def serve_requests
      @sessions.each do |conn, session|
        session.take_requests.each do |request, status|
          count_refusal(status) if status
          response = status ? Response.new(status: status, headers: [], body: nil) : call_app(conn, request)
          begin
            session.respond(request, response) { |error| log_body_error(conn, request, error) }
          rescue Nghttp3::Error
            # The stream went away while the application ran.
            discard_body(response.body)
          end
        end
      end
      @adapter.take_refusals.each { |status, count| count_refusal(status, count) }
    end

    def call_app(conn, request)
      @adapter.call(request, remote: @remotes[conn])
    rescue => e
      log_app_error(conn, request, e)
      Response.new(status: 500, headers: [], body: nil)
    end

    def count_refusal(status, count = 1)
      @refusals_since ||= now
      @refusals[status] += count
    end

    # When the refusals counted are due to be logged; nil while there are
    # none.
    def refusal_log_at
      @refusals_since && @refusals_since + @refusal_log_interval
    end

    def refusals_due?
      at = refusal_log_at
      !at.nil? && at <= now
    end

    # One line per status, in ascending order, with the seconds since the
    # first of them; the count starts over.
    def log_refusals
      return if @refusals_since.nil?

      seconds = (now - @refusals_since).round
      @refusals.sort.each do |status, count|
        log(:warn, "requests_refused", status: status, count: count, seconds: seconds)
      end
      @refusals.clear
      @refusals_since = nil
    end

    # The connections are filled in the order they came, so that while the
    # total is short the older ones get its room first.
    def fill_bodies(room)
      @sessions.each do |conn, session|
        room -= session.fill_bodies(@send_buffer_size, connection_limit: @max_connection_send_buffer,
          room: room) { |request, error| log_app_error(conn, request, error) }
      end
    end

    # What max_total_send_buffer has left for array and each bodies.
    def send_room
      @max_total_send_buffer - @sessions.each_value.sum(&:unsent_total)
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
        if (error = session.take_spool_error)
          log_spool_failure(conn, error)
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
    # to be an Integer in range, and the limits have to let a request at
    # max_request_body and max_field_section_size through on a server with
    # nothing else under way. A body over request_body_buffer_size goes to a
    # temporary file, so then memory has to hold only that much of it, and
    # the spool all of it.
    def check_request_limits(max_request_body:, max_field_section_size:, max_connection_request_buffer:,
      max_total_request_buffer:, request_body_buffer_size:, max_connection_request_spool:,
      max_total_request_spool:, max_connection_request_spool_files:, max_total_request_spool_files:)
      unless max_request_body.is_a?(Integer) && max_request_body >= 0
        raise ArgumentError, "max_request_body must be an Integer of 0 or more (got #{max_request_body.inspect})"
      end
      # The range Session._attach takes, which would otherwise raise only
      # on the first connection.
      unless max_field_section_size.is_a?(Integer) && (1...2**62).cover?(max_field_section_size)
        raise ArgumentError, "max_field_section_size must be 1..2**62-1 (got #{max_field_section_size.inspect})"
      end
      {max_connection_request_buffer:, max_total_request_buffer:, request_body_buffer_size:,
       max_connection_request_spool:, max_total_request_spool:, max_connection_request_spool_files:,
       max_total_request_spool_files:}.each do |name, value|
        raise ArgumentError, "#{name} must be a positive Integer (got #{value.inspect})" unless value.is_a?(Integer) && value.positive?
      end
      spooled = max_request_body > request_body_buffer_size
      in_memory, terms = if spooled
        [request_body_buffer_size, "request_body_buffer_size + max_field_section_size"]
      else
        [max_request_body, "max_request_body + max_field_section_size"]
      end
      request = in_memory + max_field_section_size
      if max_connection_request_buffer < request
        raise ArgumentError, "max_connection_request_buffer (#{max_connection_request_buffer}) must be at least " \
          "#{terms} (#{request})"
      end
      if max_total_request_buffer < max_connection_request_buffer
        raise ArgumentError, "max_total_request_buffer (#{max_total_request_buffer}) must be at least " \
          "max_connection_request_buffer (#{max_connection_request_buffer})"
      end
      if spooled && max_connection_request_spool < max_request_body
        raise ArgumentError, "max_connection_request_spool (#{max_connection_request_spool}) must be at least " \
          "max_request_body (#{max_request_body})"
      end
      if max_total_request_spool < max_connection_request_spool
        raise ArgumentError, "max_total_request_spool (#{max_total_request_spool}) must be at least " \
          "max_connection_request_spool (#{max_connection_request_spool})"
      end
      if max_total_request_spool_files < max_connection_request_spool_files
        raise ArgumentError, "max_total_request_spool_files (#{max_total_request_spool_files}) must be at least " \
          "max_connection_request_spool_files (#{max_connection_request_spool_files})"
      end
    end

    # Raise ArgumentError for the first send limit found wrong: each has to
    # be a positive Integer, at least the one before.
    def check_send_limits(send_buffer_size, max_connection_send_buffer, max_total_send_buffer)
      {send_buffer_size:, max_connection_send_buffer:, max_total_send_buffer:}.each do |name, value|
        raise ArgumentError, "#{name} must be a positive Integer (got #{value.inspect})" unless value.is_a?(Integer) && value.positive?
      end
      if max_connection_send_buffer < send_buffer_size
        raise ArgumentError, "max_connection_send_buffer (#{max_connection_send_buffer}) must be at least " \
          "send_buffer_size (#{send_buffer_size})"
      end
      if max_total_send_buffer < max_connection_send_buffer
        raise ArgumentError, "max_total_send_buffer (#{max_total_send_buffer}) must be at least " \
          "max_connection_send_buffer (#{max_connection_send_buffer})"
      end
    end

    def check_request_timeout(request_timeout)
      return if request_timeout.nil?
      return if (request_timeout.is_a?(Integer) || request_timeout.is_a?(Float)) && request_timeout.positive?

      raise ArgumentError, "request_timeout must be nil or a positive number of seconds (got #{request_timeout.inspect})"
    end

    def check_refusal_log_interval(refusal_log_interval)
      return if (refusal_log_interval.is_a?(Integer) || refusal_log_interval.is_a?(Float)) && refusal_log_interval.positive?

      raise ArgumentError,
        "refusal_log_interval must be a positive number of seconds (got #{refusal_log_interval.inspect})"
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

    # A temporary file for a request body could not be made or written
    # (the request got 503). While the disk is full every large request
    # fails, so after one line, those within refusal_log_interval seconds
    # are not logged.
    def log_spool_failure(conn, error)
      at = now
      return if @spool_failure_logged_at && at < @spool_failure_logged_at + @refusal_log_interval

      @spool_failure_logged_at = at
      log(:error, "request_spool_failed", remote: remote_of(conn), error: error.class, message: error.message)
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
      format_remote(address)
    end

    def format_remote(address)
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
