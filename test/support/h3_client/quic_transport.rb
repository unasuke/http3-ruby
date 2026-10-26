# frozen_string_literal: true

require "socket"

module H3TestClient
  # A Client carried over a QUIC::Connection::Client on a connected UDP
  # socket, both pumped from the calling thread. The Client allocates
  # stream IDs itself, so the QUIC streams are opened in the same order
  # (control and QPACK streams first, then one per request) and their IDs
  # always match.
  class QuicTransport
    attr_reader :client, :quic

    # Connect to the HTTP/3 server on 127.0.0.1:port, trusting ca_file.
    # settings overrides QUIC::Settings.default fields.
    def self.connect(port, ca_file:, **settings)
      quic = QUIC::Connection::Client.new(
        host: "127.0.0.1", port: port, address_family: :inet,
        settings: QUIC::Settings.default.with(alpn: ["h3"], ca_file: ca_file, **settings)
      )
      sock = UDPSocket.new(Socket::AF_INET)
      sock.connect(quic.remote_address.ip_address, quic.remote_address.ip_port)
      begin
        quic.bind(sock).run
      rescue
        sock.close
        raise
      end
      new(quic, sock)
    end

    def initialize(quic, sock)
      @quic = quic
      @sock = sock
      @client = Client.new
      @streams = {}
      @fed_eof = {}
      @paused = {}
      control, encoder, decoder = Array.new(3) { track(@quic.open_uni_stream) }
      @client.bind_streams(control: control.id, qpack_encoder: encoder.id, qpack_decoder: decoder.id)
    end

    # Send a request (:get, :head or :post) and return its stream ID. With
    # fin: false the request stays open after its body, until #finish.
    def request(method, path, body: nil, headers: {}, fin: true)
      stream = open_request_stream
      url = "https://127.0.0.1#{path}"
      request = case method
      when :get then Request.get(url, headers: headers)
      when :head then Request.head(url, headers: headers)
      when :post then Request.post(url, body: body, headers: headers)
      else raise ArgumentError, "unknown method #{method.inspect}"
      end
      id = @client.submit(request, fin: fin)
      raise "stream IDs out of step: QUIC #{stream.id}, HTTP/3 #{id}" unless id == stream.id

      id
    end

    # End a request sent with fin: false.
    def finish(id)
      @client.finish_body(id)
    end

    def response(id)
      @client.responses[id]
    end

    # True once the request stream has closed without the response
    # ending: the server aborted it.
    def aborted?(id)
      stream = @streams[id]
      !stream.nil? && stream.closed? && !response(id).finished?
    end

    # True once the request stream has closed in both directions, and
    # everything sent on it has been acknowledged. A request the server
    # stopped reading closes once its response has arrived and the reset
    # of the client's side, which the server's STOP_SENDING brings about,
    # has been acknowledged.
    def closed?(id)
      @streams.fetch(id).closed?
    end

    # Give up on a request: RESET_STREAM with H3_REQUEST_CANCELLED and, with
    # stop_sending, STOP_SENDING too, so that the server stops sending the
    # response.
    def cancel(id, stop_sending: true)
      stream = @streams.fetch(id)
      @client.connection.shutdown_stream_write(id)
      stream.reset(HTTP3::Nghttp3::H3_REQUEST_CANCELLED)
      stream.close_read if stop_sending
    end

    # Stop reading the response on stream id, until #resume. QUIC::Stream
    # gives the server more window only as the data is read, so the server
    # soon has to stop sending; the connection goes on.
    def pause(id)
      @paused[id] = true
    end

    def resume(id)
      @paused.delete(id)
    end

    # Pump until the block returns true; raises after timeout seconds.
    def pump_until(timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        raise "timed out after #{timeout} seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        pump
      end
    end

    # One round: hand what HTTP/3 has to QUIC, run QUIC's I/O once, and
    # hand back whatever arrived.
    def pump
      @client.pump_writes do |id, data, fin|
        write(@streams.fetch(id), data, fin)
        data.bytesize
      end
      @quic.pump_once(timeout: 0.002)
      feed
    end

    # Pass whatever the QUIC streams hold to HTTP/3, without any I/O. Useful
    # after #pump raised because the connection closed.
    def feed
      loop { track(@quic.accept_stream_nonblock) }
    rescue QUIC::Error::WaitReadable
      @streams.each_value { |stream| feed_stream(stream) }
    end

    def close
      @quic.close
    rescue QUIC::Error
      nil
    ensure
      @sock.close unless @sock.closed?
    end

    private

    def track(stream)
      @streams[stream.id] = stream
    end

    # QUIC::Stream#write waits until the peer's window has room for all of
    # the data, which may never happen for more than the window holds, so
    # write it piece by piece. FIN goes with the last piece.
    #
    # The server may answer a request before reading all of it and stop
    # reading (STOP_SENDING); QUIC then raises StreamClosed, and what is
    # left of the stream is dropped.
    def write(stream, data, fin)
      return stream.write("".b, fin: true) if data.empty? && fin

      offset = 0
      while offset < data.bytesize
        piece = data.byteslice(offset, 16_384)
        offset += piece.bytesize
        stream.write(piece, fin: fin && offset >= data.bytesize)
      end
    rescue QUIC::Error::StreamClosed
      nil
    end

    # The server lets the client open another request stream once one
    # closes; wait for that when the limit is reached.
    def open_request_stream
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      begin
        track(@quic.open_bidi_stream)
      rescue QUIC::Error
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        pump
        retry
      end
    end

    def feed_stream(stream)
      # Client-initiated unidirectional streams only send.
      return if stream.id % 4 == 2 || @fed_eof[stream.id] || @paused[stream.id]

      loop do
        @client.read_stream(stream.id, stream.read_nonblock(65_536))
      rescue QUIC::Error::WaitReadable
        break
      rescue EOFError
        @client.read_stream(stream.id, "".b, fin: true)
        @fed_eof[stream.id] = true
        break
      end
    end
  end
end
