# frozen_string_literal: true

require "openssl"
require "socket"

module HTTP3
  module NetHTTP
    # An HTTP/3 Session for Net::HTTP::Client: QUIC through the quic gem's
    # Ruby-level connection and streams, HTTP/3 framing and QPACK through
    # HTTP3::Nghttp3. It is the prototype of the net-http HTTP/3 study,
    # moved here as it was, and it keeps that prototype's known defects.
    # They are listed, with their numbers, at the top of http3/net/http.rb,
    # and marked below where they are.
    #
    # It implements the Session contract of net-http's H1Session and
    # HTTP2::Session: reserve, release, idle?, closed?, close,
    # discard_after_fork, progress and exchange.
    #
    # The quic gem has no locking of its own, so every call into the QUIC
    # connection, its streams and nghttp3 happens under @lock. One caller at
    # a time waits on the UDP socket (@reader); the others pause briefly and
    # find their data queued when they look again.
    class ClientSession
      Stream = Struct.new(:id, :quic, :status, :headers, :headers_done, :trailers,
        :queue, :queued, :ended, :closed, :error, :cancelled)
      Reservation = Struct.new(:stream)
      # Received body bytes held per stream before the session stops
      # reading that QUIC stream (and so stops returning flow-control credit).
      QUEUE_LIMIT = 1 << 20
      LOCAL_STREAM_LIMIT = 100

      def initialize(uri, options, operation)
        @lock, @reader = Mutex.new, Mutex.new
        @closed = @draining = false
        @streams, @quic_streams, @reservations, @blocked, @fed_eof = {}, {}, {}, {}, {}
        # Unsupported TLS settings are refused only here, on connecting
        # (defect 6).
        tls = options[:tls]
        unsupported = tls.keys - [:ca_file, :ca_path, :verify_mode]
        unless unsupported.empty?
          raise ::Net::HTTP::Client::ProtocolError, "TLS settings not supported over HTTP/3: #{unsupported.join(", ")}"
        end
        settings = {alpn: ["h3"]}
        settings[:ca_file] = tls[:ca_file] if tls[:ca_file]
        settings[:ca_path] = tls[:ca_path] if tls[:ca_path]
        settings[:verify_mode] = :none if tls[:verify_mode] == OpenSSL::SSL::VERIFY_NONE
        @quic = ::QUIC::Connection::Client.new(host: uri.hostname, port: uri.port,
          settings: ::QUIC::Settings.default.with(**settings))
        remote = @quic.remote_address
        @sock = UDPSocket.new(remote.afamily)
        @sock.connect(remote.ip_address, remote.ip_port)
        @quic.bind(@sock)
        # The path Client.new gave ngtcp2 (the quic gem's own convention).
        @local_sockaddr = Addrinfo.udp("0.0.0.0", 0).to_sockaddr
        @remote_sockaddr = @sock.remote_address.to_sockaddr
        operation.on_cancel { close }
        deadline = Clock.now + operation.remaining(options[:open_timeout])
        until @lock.synchronize { @quic.handshake_completed? }
          raise ::Net::OpenTimeout, "QUIC handshake timeout" if Clock.now >= deadline
          turn(operation, deadline)
        end
        @lock.synchronize do
          @h3 = Nghttp3::Connection.client_new(Nghttp3::Settings.default, callbacks)
          control, encoder, decoder = Array.new(3) { track(@quic.open_uni_stream) }
          @h3.bind_control_stream(control.id)
          @h3.bind_qpack_streams(encoder.id, decoder.id)
          flush
        end
      rescue Exception # rubocop:disable Lint/RescueException
        close
        raise
      end

      # QUIC MAX_STREAMS is cumulative and not visible through the quic
      # gem's Ruby API, so only a local concurrency limit applies here;
      # exchange waits when the peer has not granted another stream yet.
      def reserve
        @lock.synchronize do
          return nil if @closed || @draining || @reservations.size >= LOCAL_STREAM_LIMIT
          # Nobody drives an idle connection, so run its overdue timers
          # now: past the negotiated max_idle_timeout, ngtcp2 closes it
          # here instead of letting a request go out on it.
          begin
            expiry = @quic.expiry
            @quic.handle_expiry if expiry && expiry <= Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          rescue ::QUIC::Error
            @closed = true
          end
          return nil if @closed || @quic.in_closing_period? || @quic.in_draining_period?
          reservation = Reservation.new(nil)
          @reservations[reservation.object_id] = reservation
          reservation
        end
      end

      def release(reservation)
        @lock.synchronize do
          @reservations.delete(reservation.object_id)
          @streams.delete(reservation.stream.id) if reservation.stream
        end
      end

      def idle?
        @lock.synchronize { @reservations.empty? }
      end

      def closed?
        @closed || (@draining && idle?) ||
          @lock.synchronize { @quic.in_closing_period? || @quic.in_draining_period? }
      end

      def close
        return if @closed
        @closed = true
        @lock.synchronize do
          begin
            @quic.close(error_code: Nghttp3::H3_NO_ERROR) if @quic&.handshake_completed?
          rescue
            nil
          end
          fail_streams(EOFError.new("HTTP/3 connection closed"))
        end
        @sock.close if @sock && !@sock.closed?
      rescue IOError, SystemCallError
        nil
      end

      # The child must not send anything for the parent's connection.
      def discard_after_fork
        @closed = true
        @sock.close if @sock && !@sock.closed?
      rescue IOError, SystemCallError
        nil
      end

      def progress(operation)
        turn(operation, Clock.now)
      end

      def exchange(request, operation, reservation)
        stream = nil
        operation.on_cancel { cancel(stream) if stream }
        complete = false
        begin
          stream = open_request(request, operation, reservation)
          deadline = Clock.now + operation.options[:read_timeout]
          loop do
            headers_done = @lock.synchronize do
              check_stream(stream)
              stream.headers_done
            end
            break if headers_done
            raise ::Net::ReadTimeout, "HTTP/3 response timeout" if Clock.now >= deadline
            turn(operation, deadline)
          end
          code = stream.status
          klass = ::Net::HTTPResponse::CODE_TO_OBJ[code] || ::Net::HTTPResponse::CODE_CLASS_TO_OBJ[code[0, 1]] || ::Net::HTTPUnknownResponse
          response = klass.new("3", code, nil)
          stream.headers.each { |name, value| response.add_field(name, value) }
          response.instance_variable_set(:@uri, request.uri)
          response.extend(ResponseMethods)
          response.instance_variable_set(:@client_body_consumed, false)
          response.instance_variable_set(:@client_body_complete, false)
          response.instance_variable_set(:@client_body_allowed, request.method != "HEAD" && klass.body_permitted?)
          source = proc do |&sink|
            loop do
              deadline = Clock.now + operation.options[:read_timeout]
              chunk = ended = nil
              loop do
                @lock.synchronize do
                  check_stream(stream)
                  chunk = stream.queue.shift
                  stream.queued -= chunk.bytesize if chunk
                  ended = stream.ended
                end
                break if chunk || ended
                raise ::Net::ReadTimeout, "HTTP/3 body timeout" if Clock.now >= deadline
                turn(operation, deadline)
              end
              break unless chunk
              sink.call(chunk)
            end
            response.instance_variable_set(:@client_trailers, stream.trailers.transform_values(&:freeze).freeze)
          end
          reader = ResponseBody.new(response, operation, &source)
          response.instance_variable_set(:@client_body_source, proc { |&sink| reader.each(&sink) })
          begin
            yield response
          ensure
            response.instance_variable_set(:@client_body_source, nil)
          end
          complete = stream.ended && stream.queue.empty?
          response
        ensure
          cancel(stream) if stream && !complete
        end
      end

      private

      def open_request(request, operation, reservation)
        headers = request_headers(request)
        body = (request.body_length == 0) ? nil : body_reader(request)
        deadline = Clock.now + operation.options[:write_timeout]
        loop do
          opened = @lock.synchronize do
            raise EOFError, "HTTP/3 connection closed" if @closed
            begin
              quic = @quic.open_bidi_stream
            rescue ::QUIC::Error::StreamClosed, ::QUIC::Error::InvalidState
              raise
            rescue ::QUIC::Error
              # The peer has not granted another bidirectional stream yet.
              # Any other QUIC::Error than the two above is taken for that
              # too, and waited out (defect 7).
              next nil
            end
            stream = Stream.new(quic.id, quic, nil, [], false, {}, [], 0, false, false, nil, false)
            track(quic)
            @streams[quic.id] = stream
            reservation.stream = stream
            nv = headers.map { |name, value| Nghttp3::NV.new(name, value) }
            if body
              @h3.submit_request(quic.id, nv) { |_id| body.call }
            else
              @h3.submit_request(quic.id, nv)
            end
            flush
            stream
          end
          return opened if opened
          raise ::Net::WriteTimeout, "HTTP/3 stream limit timeout" if Clock.now >= deadline
          turn(operation, deadline)
        end
      end

      def request_headers(request)
        authority = request.headers.fetch("host") { [request.uri.host + ((request.uri.port == 443) ? "" : ":#{request.uri.port}")] }.first
        headers = [[":method", request.method], [":scheme", "https"], [":authority", authority], [":path", request.request_target]]
        request.headers.each do |name, values|
          next if name == "host"
          raise ArgumentError, "#{name} is not allowed in HTTP/3" if %w[connection keep-alive proxy-connection transfer-encoding upgrade].include?(name)
          values.each { |value| headers << [name, value] }
        end
        if request.body_length && request.body_length > 0 && !request.headers.key?("content-length")
          headers << ["content-length", request.body_length.to_s]
        end
        headers
      end

      # nghttp3 pulls the body: each call returns the next chunk, or nil
      # at the end. Request bodies are push-style (each), so an external
      # enumerator turns them around. nghttp3 calls this from #flush, under
      # @lock, so a slow body holds up the whole connection (defect 4).
      def body_reader(request)
        chunks = request.to_enum(:each_body_chunk)
        proc do
          chunk = chunks.next until chunk && !chunk.empty?
          chunk.b
        rescue StopIteration
          nil
        end
      end

      # One round of I/O. Called without @lock; only the caller holding
      # @reader waits on the socket. An HTTP3::Nghttp3::Error goes through
      # without closing the session (defect 3), and a QUIC::Error goes out
      # as it is (defect 6).
      def turn(operation, deadline)
        operation.check!
        unless @reader.try_lock
          Wait.pause(operation)
          return
        end
        begin
          wait = @lock.synchronize do
            flush
            expiry = @quic.expiry
            timer = expiry && [(expiry - Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)) / 1e9, 0].max
            [timer, deadline && [deadline - Clock.now, 0].max, 0.05].compact.min
          end
          ready = @sock.wait_readable(wait)
          @lock.synchronize { ingest(ready) }
        rescue ::QUIC::Error, IOError, SystemCallError => error
          @lock.synchronize { fail_streams(error) }
          @closed = true
          raise
        ensure
          @reader.unlock
        end
      end

      def ingest(readable)
        if readable
          loop do
            packet = @sock.recv_nonblock(65_536, exception: false)
            break if packet == :wait_readable || packet.nil?
            @quic.read_pkt(packet, local_sockaddr: @local_sockaddr, remote_sockaddr: @remote_sockaddr)
          end
        end
        expiry = @quic.expiry
        @quic.handle_expiry if expiry && expiry <= Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        loop { track(@quic.accept_stream_nonblock) }
      rescue ::QUIC::Error::WaitReadable
        feed if @h3 # server streams may carry data before nghttp3 is set up
        flush
      end

      # Hand QUIC stream data to nghttp3. A request stream whose received
      # body is not being consumed is left unread: QUIC::Stream returns
      # flow-control credit only for what is read from it. The streams of
      # finished requests are never closed in nghttp3 nor dropped from
      # @quic_streams and @fed_eof, so this goes over more of them with
      # every request (defect 1).
      def feed
        @quic_streams.each_value do |quic|
          id = quic.id
          next if id % 4 == 2 || @fed_eof[id]
          stream = @streams[id]
          next if stream && stream.queued >= QUEUE_LIMIT
          loop do
            @h3.read_stream(id, quic.read_nonblock(65_536))
            break if stream && stream.queued >= QUEUE_LIMIT
          rescue ::QUIC::Error::WaitReadable
            break
          rescue EOFError
            @h3.read_stream(id, "".b, fin: true)
            @fed_eof[id] = true
            break
          rescue ::QUIC::Error::StreamReset, ::QUIC::Error::StreamClosed => error
            stream.error ||= ::Net::HTTP::Client::ProtocolError.new("HTTP/3 stream reset (#{error.message})") if stream
            @fed_eof[id] = true
            break
          end
        end
      end

      # Move what nghttp3 has to send into the QUIC streams, then the
      # packets onto the socket. QUIC::Stream copies what it accepts, so
      # nghttp3 can let go of those bytes at once (add_ack_offset).
      def flush
        return flush_packets unless @h3
        @blocked.each_key { |id| @h3.unblock_stream(id) }
        @blocked.clear
        while (out = @h3.writev_stream)
          id, data, fin = out[:stream_id], out[:data], out[:fin]
          quic = @quic_streams.fetch(id)
          begin
            written = data.empty? ? quic.write_nonblock("".b, fin: fin) : quic.write_nonblock(data, fin: fin)
          rescue ::QUIC::Error::WaitWritable
            @h3.block_stream(id)
            @blocked[id] = true
            next
          rescue ::QUIC::Error::StreamClosed, ::QUIC::Error::StreamReset
            @h3.shutdown_stream_write(id)
            next
          end
          @h3.add_write_offset(id, written)
          @h3.add_ack_offset(id, written) if written > 0
        end
        flush_packets
      end

      def flush_packets
        while (packet = @quic.write_pkt)
          @sock.send(packet, 0)
        end
      end

      def track(quic)
        @quic_streams[quic.id] = quic
      end

      def check_stream(stream)
        raise stream.error if stream.error
        raise ::Net::HTTP::Client::CancelledError, "stream cancelled" if stream.cancelled
        raise EOFError, "HTTP/3 connection closed" if @closed
      end

      # RESET_STREAM alone: no STOP_SENDING, and what has arrived on the
      # stream is left unread, so the peer's flow-control credit for it
      # never comes back (defect 2).
      def cancel(stream)
        @lock.synchronize do
          next if stream.cancelled || @closed
          stream.cancelled = true
          stream.queue.clear
          unless stream.ended
            begin
              stream.quic.reset(Nghttp3::H3_REQUEST_CANCELLED)
              @h3.shutdown_stream_read(stream.id)
            rescue ::QUIC::Error, Nghttp3::Error
              nil
            end
          end
          @quic_streams.delete(stream.id)
          begin
            flush
          rescue ::QUIC::Error, IOError, SystemCallError
            nil
          end
        end
      end

      def fail_streams(error)
        @streams.each_value { |stream| stream.error ||= error }
      end

      # on_reset_stream is nghttp3 asking for a RESET_STREAM, not the peer's
      # reset, and on_stop_sending is not set (defect 5).
      def callbacks
        Nghttp3::Callbacks.new
          .on_recv_header do |id, name, value, _flags|
            stream = @streams[id]
            if stream
              if name == ":status"
                stream.status = value
              else
                stream.headers << [name, value]
              end
            end
          end
          .on_end_headers do |id, _fin|
            stream = @streams[id]
            if stream&.status&.start_with?("1")
              stream.status = nil
              stream.headers = []
            elsif stream
              stream.headers_done = true
            end
          end
          .on_recv_trailer do |id, name, value, _flags|
            stream = @streams[id]
            (stream.trailers[name] ||= []) << value.freeze if stream
          end
          .on_recv_data do |id, data|
            stream = @streams[id]
            if stream && !stream.cancelled
              stream.queue << data.b
              stream.queued += data.bytesize
            end
          end
          .on_end_stream do |id|
            stream = @streams[id]
            stream.ended = true if stream
          end
          .on_reset_stream do |id, code|
            stream = @streams[id]
            stream.error ||= ::Net::HTTP::Client::ProtocolError.new("HTTP/3 stream reset (#{code})") if stream && !stream.ended
          end
          .on_stream_close do |id, code|
            stream = @streams[id]
            stream.error ||= ::Net::HTTP::Client::ProtocolError.new("HTTP/3 stream closed (#{code})") if stream && !stream.ended
            @quic_streams.delete(id)
          end
          .on_shutdown { |_id| @draining = true }
      end
    end
  end
end
