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
  #
  # One thread drives every connection; the application runs on worker
  # threads (WorkerPool), and only there: its call, the each of its body
  # and the close of its body all run on the worker that took the request.
  # The workers hand their responses to that thread through a queue, and
  # wake it through a pipe.
  class Server
    ALPN = ["h3"].freeze

    # A request handed to a worker. remote is the client's address, taken
    # when the request was handed out, for the log; pipe is the response's
    # Body::Pipe, once the worker has one; started is true once a worker
    # has taken the job.
    Job = Struct.new(:conn, :session, :request, :remote, :pipe, :started)
    private_constant :Job

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
    # the requests of a connection hold until the application is done with
    # them, and max_total_request_buffer those of every connection;
    # max_connection_request_spool and max_total_request_spool bound the
    # bytes in temporary files, and max_connection_request_spool_files and
    # max_total_request_spool_files the files open at once. A request that
    # would pass any of them, or whose file cannot be made or written, gets
    # 503. They have to leave room for a request at the limits on a server
    # with nothing else under way, or ArgumentError is raised; and when
    # bodies may go to files, Dir.tmpdir has to take one, or
    # SystemCallError is. send_buffer_size
    # bounds the bytes of a response body queued but unsent per stream,
    # max_connection_send_buffer those of the array and each bodies of a
    # connection, and max_total_send_buffer those of every connection; a
    # body waits for room. Each has to be at least the one before. A request
    # not received in full within request_timeout seconds of the start of
    # its headers gets 408, and one that waits that long for a worker
    # afterwards 503; nil is no limit. refusal_log_interval is the seconds
    # between the requests_refused lines (see above). threads is the number
    # of worker threads.
    def initialize(app:, bind:, certificate_path:, private_key_path:, transport_params: nil, settings: nil,
      qlog_dir: nil, max_connections: 1024, threads: 3, max_request_body: 1_048_576, max_field_section_size: 65_536,
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
      check_threads(threads)
      check_request_timeout(request_timeout)
      check_refusal_log_interval(refusal_log_interval)
      @app = app
      @threads = threads
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
      # The workers write to it when they have a result for the loop, or a
      # Body::Pipe has something to take.
      @wake_r, @wake_w = IO.pipe
      @results = Thread::Queue.new
      # The jobs handed to a worker and not done yet, and whether the
      # workers have been told to stop; the lock is for the pipes of the
      # jobs, which workers set.
      @jobs = {}.compare_by_identity
      @jobs_lock = Thread::Mutex.new
      @workers_stopped = false
      @adapter = RackAdapter.new(@app, pipe_capacity: @send_buffer_size, wake: method(:wake))
      @sock = UDPSocket.new(@bind_address.afamily)
      @sock.bind(@bind_address.ip_address, @bind_address.ip_port)
      @local_address = @sock.local_address
      @endpoint = QUIC::Endpoint.new(
        local_address: @local_address, tls_context: @tls_context, transport_params: @transport_params,
        settings: @settings, max_connections: @max_connections
      )
      @sessions = {}
      @remotes = {}
      # The index in @sessions of the connection whose turn it is to hand a
      # request to the application (#next_request).
      @next_turn = 0
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
      @pool = WorkerPool.new(@threads).start

      turn(sig_r) until finished?
      close_connections
      stop_workers
      log_refusals
      nil
    ensure
      restore_traps(old_traps) if old_traps
      stop_workers if @pool && !@workers_stopped
      @sessions&.each_value { |session| release_session(session) }
      [@sock, sig_r, sig_w, @wake_r, @wake_w].each { |io| io.close if io && !io.closed? }
    end

    private

    # One turn of the loop. The room left in max_total_send_buffer is
    # counted once, at the start. Only fill_bodies queues more, so until
    # then the room can only have grown (nghttp3 taking what flush sends),
    # and filling by the room counted queues no more than the limit allows.
    def turn(sig_r)
      room = send_room
      writers = @blocked_send ? [@sock] : nil
      readable, writable, = IO.select([@sock, sig_r, @wake_r], writers, nil, select_timeout(room))
      handle_signals(sig_r) if readable&.include?(sig_r)
      flush if writable&.include?(@sock)
      receive if readable&.include?(@sock)
      # Emptied before the results are taken: a result put after that
      # leaves a byte for the next select.
      drain_wake
      take_results
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
      when :draining then now >= @drain_deadline || (@jobs.empty? && @sessions.each_value.none?(&:busy?))
      else true
      end
    end

    # Until the next timer, the next request to run out of time (coming in,
    # or waiting for a worker), the next requests_refused lines or the end
    # of the drain, but no wait at all while a body could take more within
    # the send buffers: a Body::Pipe only once its worker has written to it.
    # A worker with a result wakes the loop through @wake_r.
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

    # Answer the refused requests at once, then hand those received in full
    # to the free workers, one at a time (#next_request).
    def serve_requests
      @sessions.each do |conn, session|
        session.take_refusals.each do |request, status|
          count_refusal(status)
          respond(conn, session, request, Response.new(status: status, headers: [], body: nil))
        end
      end
      while @jobs.size < @threads
        conn, request = next_request
        break if request.nil?

        dispatch(conn, request)
      end
      @adapter.take_refusals.each { |status, count| count_refusal(status, count) }
    end

    # A method of its own, so that each block posted has a job of its own:
    # a while loop's body shares its variables between rounds.
    def dispatch(conn, request)
      job = Job.new(conn, @sessions[conn], request, @remotes[conn], nil, false)
      @jobs[job] = true
      @pool.post { work(job) }
    end

    # The next request for the application and its connection, or nil. The
    # connections take turns, one request each, and the turns go on from
    # one call to the next, across turns of the loop: counted from the
    # first connection every time, the oldest ones would always go first.
    def next_request
      conns = @sessions.keys
      conns.size.times do
        @next_turn = 0 if @next_turn >= conns.size
        conn = conns[@next_turn]
        @next_turn += 1
        request = @sessions[conn].next_request
        return [conn, request] if request
      end
      nil
    end

    def respond(conn, session, request, response)
      session.respond(request, response) { |error| log_body_error(conn, request, error) }
    rescue Nghttp3::Error
      # The stream went away while the application ran.
      discard_body(response.body)
    end

    # On a worker, unless stop_workers has let go of the job before a
    # worker took it.
    def work(job)
      @jobs_lock.synchronize do
        return if @workers_stopped

        job.started = true
      end
      run_job(job)
    end

    # On a worker: call the application for job's request, hand the
    # response to the loop, write its body, if it is read with each, and
    # tell the loop the job is done, once the request's input is closed.
    # The loop does the logging.
    def run_job(job)
      begin
        response, fill = @adapter.call(job.request, remote: job.remote)
      rescue Exception => e # rubocop:disable Lint/RescueException
        put_result(:error, job, e)
        return
      end
      body = response.body
      # With the lock, so that stop_workers, which takes no results after
      # it, either cancels the pipe and takes this response, or finds the
      # workers stopped here; then the body goes nowhere.
      sent = @jobs_lock.synchronize do
        job.pipe = body if body.is_a?(Body::Pipe)
        put_result(:response, job, response) unless @workers_stopped
        !@workers_stopped
      end
      drop_body(body) unless sent
      begin
        fill&.call
      rescue Exception => e # rubocop:disable Lint/RescueException
        # fill fails the pipe itself; what gets out of it is the close of
        # the Rack body, after the body has ended.
        body.fail(e)
        close_error = e
      end
    ensure
      close_input(job.request.input)
      put_result(:done, job, close_error)
    end

    # From a worker: kind is :response (value the Response), :error (value
    # what the application raised) or :done (value an exception from the
    # close of the Rack body, or nil).
    def put_result(kind, job, value)
      @results << [kind, job, value]
      wake
    end

    # Wake the loop, from any thread. A full pipe wakes it already.
    def wake
      @wake_w.write_nonblock(".", exception: false)
    rescue IOError, SystemCallError
      # #run has ended, and closed the pipe.
      nil
    end

    # A body that goes nowhere, without a word: a Body::Pipe is cancelled,
    # so that the worker's next write stops it, and a Body::File's own IO
    # closed.
    def drop_body(body)
      case body
      when Body::Pipe then body.cancel
      when Body::File then body.io.close unless body.io.closed?
      end
    rescue IOError, SystemCallError
      nil
    end

    def close_input(input)
      input.close unless input.closed?
    rescue IOError, SystemCallError
      nil
    end

    def drain_wake
      loop do
        break unless @wake_r.read_nonblock(4096, exception: false).is_a?(String)
      end
    end

    # What the workers put, in the order they put it.
    def take_results
      until @results.empty?
        kind, job, value = @results.pop
        case kind
        when :response
          deliver(job, value)
        when :error
          log_app_error(remote_label(job.remote), job.request, value)
          deliver(job, Response.new(status: 500, headers: [], body: nil))
        when :done
          @jobs.delete(job)
          log_body_close_error(job.request.stream_id, value) if value
          job.session.finish(job.request.stream_id)
        end
      end
    end

    # Send response for job, unless its request can no longer be answered:
    # the client reset it, or its stream or connection is gone.
    def deliver(job, response)
      session = job.session
      if @sessions[job.conn].equal?(session) && session.answerable?(job.request.stream_id)
        respond(job.conn, session, job.request, response)
      else
        discard_body(response.body)
      end
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
          room: room) { |request, error| log_app_error(remote_of(conn), request, error) }
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

    # Cancel the Body::Pipes of the jobs under way, so that the workers
    # writing to them stop, let go of the jobs no worker has taken, which
    # the pool drops, and wait a second for the workers, as
    # close_connections waits for the CONNECTION_CLOSEs to go. A worker
    # still in the application then is left to it, and counted in a warn
    # line. What the workers have put and the loop not taken is dropped.
    def stop_workers
      waiting = @jobs_lock.synchronize do
        @workers_stopped = true
        @jobs.each_key { |job| job.pipe&.cancel }
        @jobs.keys.reject(&:started)
      end
      waiting.each { |job| end_job(job) }
      running = @pool.stop(1)
      until @results.empty?
        kind, job, value = @results.pop
        case kind
        when :response then drop_body(value.body)
        when :done then end_job(job)
        end
      end
      log(:warn, "workers_still_running", count: running) if running.positive?
    end

    # A job no longer to be heard from: its input is closed, and what its
    # request holds no longer counts.
    def end_job(job)
      @jobs.delete(job)
      close_input(job.request.input)
      job.session.finish(job.request.stream_id)
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

    def check_threads(threads)
      raise ArgumentError, "threads must be a positive Integer (got #{threads.inspect})" unless threads.is_a?(Integer) && threads.positive?
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

    # A body that will not be sent: a Body::Pipe is cancelled, so that its
    # worker stops writing, and a Body::File's own IO closed. The Rack body
    # is the worker's to close.
    def discard_body(body)
      case body
      when Body::Pipe then body.cancel
      when Body::File then body.io.close unless body.io.closed?
      end
    rescue => e
      log(:error, "body_close_error", **error_fields(e))
    end

    def log_app_error(remote, request, error)
      pseudo = request.headers.select { |name, _| name.start_with?(":") }.to_h
      path = pseudo.fetch(":path", "")[/\A[^?]*/]
      log(:error, "app_error", remote: remote, stream: request.stream_id, method: pseudo[":method"],
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
      remote_label(@remotes[conn])
    end

    def remote_label(address)
      address ? format_remote(address) : "-"
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
