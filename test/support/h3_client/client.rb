# frozen_string_literal: true

module H3TestClient
  # High-level HTTP/3 client
  #
  # Wraps the low-level HTTP3::Nghttp3::Connection API with automatic stream management,
  # convenient request methods, and response tracking.
  #
  # @example Basic usage
  #   client = H3TestClient::Client.new
  #   client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
  #
  #   stream_id = client.get("https://example.com/path")
  #
  #   # Pump data to QUIC layer
  #   client.pump_writes do |stream_id, data, fin|
  #     quic.write(stream_id, data, fin)
  #   end
  #
  #   # Feed data from QUIC layer
  #   client.read_stream(stream_id, received_data, fin: false)
  #
  #   # Get response when ready
  #   response = client.responses[stream_id]
  class Client
    # @return [Connection] the underlying low-level connection
    attr_reader :connection

    # @return [Settings] the settings used for this client
    attr_reader :settings

    # @return [Hash{Integer => Response}] responses by stream ID
    attr_reader :responses

    # @return [Hash{Integer => Request}] pending requests by stream ID
    attr_reader :pending_requests

    # The stream ID the server's GOAWAY carried, or nil if none came
    attr_reader :goaway_id

    # Create a new HTTP/3 client
    # @param settings [Settings, nil] settings to use (defaults to HTTP3::Nghttp3::Settings.default)
    def initialize(settings: nil)
      @settings = settings || HTTP3::Nghttp3::Settings.default
      @callbacks = setup_callbacks
      @connection = HTTP3::Nghttp3::Connection.client_new(@settings, @callbacks)
      @stream_manager = StreamManager.new(is_server: false)
      @pending_requests = {}
      @responses = {}
      @open_bodies = {}
      @streams_bound = false
    end

    # Bind control and QPACK streams
    #
    # Must be called before submitting requests. The stream IDs should be
    # unidirectional streams opened by the QUIC layer.
    #
    # @param control [Integer] control stream ID
    # @param qpack_encoder [Integer] QPACK encoder stream ID
    # @param qpack_decoder [Integer] QPACK decoder stream ID
    # @return [self]
    def bind_streams(control:, qpack_encoder:, qpack_decoder:)
      @connection.bind_control_stream(control)
      @connection.bind_qpack_streams(qpack_encoder, qpack_decoder)
      @stream_manager.register_stream(control, type: :uni)
      @stream_manager.register_stream(qpack_encoder, type: :uni)
      @stream_manager.register_stream(qpack_decoder, type: :uni)
      @streams_bound = true
      self
    end

    # Check if streams are bound
    # @return [Boolean]
    def streams_bound?
      @streams_bound
    end

    # Submit a request
    # @param request [Request] the request to submit
    # @param fin [Boolean] false to leave the request open after its body,
    #   until #finish_body
    # @return [Integer] the stream ID for this request
    def submit(request, fin: true)
      raise HTTP3::Nghttp3::InvalidStateError, "Streams not bound. Call bind_streams first." unless @streams_bound

      stream_id = @stream_manager.allocate_bidi_stream_id
      @pending_requests[stream_id] = request
      @responses[stream_id] = Response.new(stream_id: stream_id)

      if fin
        @connection.submit_request(stream_id, request.to_nv_array, body: request.body)
      else
        pieces = @open_bodies[stream_id] = request.body? ? [request.body] : []
        @connection.submit_request(stream_id, request.to_nv_array) { next_piece(pieces) }
      end
      stream_id
    end

    # End the body of a request submitted with fin: false.
    # @param stream_id [Integer] the request's stream ID
    # @return [self]
    def finish_body(stream_id)
      @open_bodies.fetch(stream_id) << :eof
      @connection.resume_stream(stream_id)
      self
    end

    # Convenience method for GET request
    # @param url [String] URL to request
    # @param headers [Hash] additional headers
    # @return [Integer] stream ID
    def get(url, headers: {})
      submit(Request.get(url, headers: headers))
    end

    # Convenience method for POST request
    # @param url [String] URL to request
    # @param body [String, nil] request body
    # @param headers [Hash] additional headers
    # @return [Integer] stream ID
    def post(url, body: nil, headers: {})
      submit(Request.post(url, body: body, headers: headers))
    end

    # Convenience method for PUT request
    # @param url [String] URL to request
    # @param body [String, nil] request body
    # @param headers [Hash] additional headers
    # @return [Integer] stream ID
    def put(url, body: nil, headers: {})
      submit(Request.put(url, body: body, headers: headers))
    end

    # Convenience method for DELETE request
    # @param url [String] URL to request
    # @param headers [Hash] additional headers
    # @return [Integer] stream ID
    def delete(url, headers: {})
      submit(Request.delete(url, headers: headers))
    end

    # Convenience method for HEAD request
    # @param url [String] URL to request
    # @param headers [Hash] additional headers
    # @return [Integer] stream ID
    def head(url, headers: {})
      submit(Request.head(url, headers: headers))
    end

    # Pump pending writes to the QUIC layer
    #
    # @yield [stream_id, data, fin] for each pending write
    # @yieldparam stream_id [Integer] the stream ID
    # @yieldparam data [String] the data to write
    # @yieldparam fin [Boolean] true if this is the final data for the stream
    # @yieldreturn [Integer] number of bytes accepted by QUIC layer
    # @return [self]
    def pump_writes
      while (result = @connection.writev_stream)
        stream_id = result[:stream_id]
        data = result[:data]
        fin = result[:fin]

        bytes_written = yield(stream_id, data, fin) if block_given?
        bytes_written ||= data.bytesize

        @connection.add_write_offset(stream_id, bytes_written)
      end
      self
    end

    # Read data from QUIC layer into HTTP/3 connection
    # @param stream_id [Integer] stream ID
    # @param data [String] received data
    # @param fin [Boolean] true if this is the final data for the stream
    # @return [Integer] number of bytes consumed
    def read_stream(stream_id, data, fin: false)
      @connection.read_stream(stream_id, data, fin: fin)
    end

    # Notify that bytes have been acknowledged by the peer
    # @param stream_id [Integer] stream ID
    # @param n [Integer] number of bytes acknowledged
    # @return [self]
    def add_ack_offset(stream_id, n)
      @connection.add_ack_offset(stream_id, n)
      self
    end

    # Close the client connection
    # @return [nil]
    def close
      @connection.close
    end

    # Check if the connection is closed
    # @return [Boolean]
    def closed?
      @connection.closed?
    end

    private

    # The body block of a request left open: the queued pieces in order,
    # :wouldblock until #finish_body queues :eof, then nil (FIN).
    def next_piece(pieces)
      case pieces.first
      when nil then :wouldblock
      when :eof then nil
      else pieces.shift
      end
    end

    def setup_callbacks
      HTTP3::Nghttp3::Callbacks.new
        .on_begin_headers { |stream_id| on_begin_headers(stream_id) }
        .on_recv_header { |stream_id, name, value, flags| on_recv_header(stream_id, name, value, flags) }
        .on_end_headers { |stream_id, fin| on_end_headers(stream_id, fin) }
        .on_recv_data { |stream_id, data| on_recv_data(stream_id, data) }
        .on_end_stream { |stream_id| on_end_stream(stream_id) }
        .on_stream_close { |stream_id, app_error_code| on_stream_close(stream_id, app_error_code) }
        .on_shutdown { |id| @goaway_id = id }
    end

    def on_begin_headers(stream_id)
      # Response headers starting
      @responses[stream_id] ||= Response.new(stream_id: stream_id)
    end

    def on_recv_header(stream_id, name, value, _flags)
      response = @responses[stream_id]
      return unless response

      if name == ":status"
        response.status = value.to_i
      else
        response.headers[name] = value
      end
    end

    def on_end_headers(stream_id, _fin)
      # Headers complete
      response = @responses[stream_id]
      response&.write_headers
    end

    def on_recv_data(stream_id, data)
      response = @responses[stream_id]
      response&.append_body(data)
    end

    def on_end_stream(stream_id)
      response = @responses[stream_id]
      response&.finish
      @pending_requests.delete(stream_id)
      @stream_manager.close_stream(stream_id)
    end

    def on_stream_close(stream_id, _app_error_code)
      response = @responses[stream_id]
      response&.finish
      @pending_requests.delete(stream_id)
      @stream_manager.close_stream(stream_id)
    end
  end
end
