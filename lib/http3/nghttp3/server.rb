# frozen_string_literal: true

module HTTP3
  module Nghttp3
    # High-level HTTP/3 server
    #
    # Wraps the low-level Connection API with automatic request handling,
    # convenient response building, and stream management.
    #
    # @example Basic usage
    #   server = HTTP3::Nghttp3::Server.new
    #   server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)
    #
    #   server.on_request do |request, response|
    #     response.status = 200
    #     response.headers["content-type"] = "text/html"
    #     response.body = "<h1>Hello!</h1>"
    #   end
    #
    #   # Feed data from QUIC layer
    #   server.read_stream(stream_id, received_data, fin: false)
    #
    #   # Pump data to QUIC layer
    #   server.pump_writes do |stream_id, data, fin|
    #     quic.write(stream_id, data, fin)
    #   end
    class Server
      # @return [Connection] the underlying low-level connection
      attr_reader :connection

      # @return [Settings] the settings used for this server
      attr_reader :settings

      # @return [Hash{Integer => Request}] received requests by stream ID
      attr_reader :requests

      # @return [Hash{Integer => Response}] responses by stream ID
      attr_reader :responses

      # Create a new HTTP/3 server
      # @param settings [Settings, nil] settings to use (defaults to Settings.default)
      def initialize(settings: nil)
        @settings = settings || Settings.default
        @callbacks = setup_callbacks
        @connection = Connection.server_new(@settings, @callbacks)
        @stream_manager = StreamManager.new(is_server: true)
        @request_handler = nil
        @requests = {}
        @responses = {}
        @building_requests = {}  # Requests being built (headers not complete)
        @streams_bound = false
      end

      # Bind control and QPACK streams
      #
      # Must be called before handling requests. The stream IDs should be
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

      # Register a request handler
      #
      # The handler is called when a complete request is received.
      # The handler should set response.status and response.body (or use streaming).
      #
      # @yield [request, response] for each incoming request
      # @yieldparam request [Request] the incoming request
      # @yieldparam response [Response] the response object to populate
      # @return [self]
      def on_request(&block)
        @request_handler = block
        self
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

      # Close the server connection
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

      def setup_callbacks
        Callbacks.new
          .on_begin_headers { |stream_id| on_begin_headers(stream_id) }
          .on_recv_header { |stream_id, name, value, flags| on_recv_header(stream_id, name, value, flags) }
          .on_end_headers { |stream_id, fin| on_end_headers(stream_id, fin) }
          .on_recv_data { |stream_id, data| on_recv_data(stream_id, data) }
          .on_end_stream { |stream_id| on_end_stream(stream_id) }
          .on_stream_close { |stream_id, app_error_code| on_stream_close(stream_id, app_error_code) }
      end

      def on_begin_headers(stream_id)
        # Start building a new request
        @building_requests[stream_id] = {
          method: nil,
          scheme: nil,
          authority: nil,
          path: nil,
          headers: Headers.new,
          body: nil
        }
        @stream_manager.register_stream(stream_id, type: :bidi)
      end

      def on_recv_header(stream_id, name, value, _flags)
        req = @building_requests[stream_id]
        return unless req

        case name
        when ":method"
          req[:method] = value
        when ":scheme"
          req[:scheme] = value
        when ":authority"
          req[:authority] = value
        when ":path"
          req[:path] = value
        else
          req[:headers][name] = value
        end
      end

      def on_end_headers(stream_id, fin)
        # Headers complete, create immutable Request
        req_data = @building_requests[stream_id]
        return unless req_data

        @requests[stream_id] = Request.new(
          method: req_data[:method] || "GET",
          scheme: req_data[:scheme] || "https",
          authority: req_data[:authority],
          path: req_data[:path] || "/",
          headers: req_data[:headers]
        )

        # Create response object
        @responses[stream_id] = Response.new(stream_id: stream_id)

        # If request has no body (fin=true), process it immediately
        process_request(stream_id) if fin
      end

      def on_recv_data(stream_id, data)
        req_data = @building_requests[stream_id]
        if req_data
          req_data[:body] ||= +""
          req_data[:body] << data
        end
      end

      def on_end_stream(stream_id)
        # Request complete with body
        req_data = @building_requests.delete(stream_id)
        if req_data && @requests[stream_id].nil?
          # Headers weren't finalized yet, create request with body
          @requests[stream_id] = Request.new(
            method: req_data[:method] || "GET",
            scheme: req_data[:scheme] || "https",
            authority: req_data[:authority],
            path: req_data[:path] || "/",
            headers: req_data[:headers],
            body: req_data[:body]
          )
          @responses[stream_id] ||= Response.new(stream_id: stream_id)
        end

        process_request(stream_id)
      end

      def on_stream_close(stream_id, _app_error_code)
        @building_requests.delete(stream_id)
        @stream_manager.close_stream(stream_id)
      end

      def process_request(stream_id)
        request = @requests[stream_id]
        response = @responses[stream_id]
        return unless request && response && @request_handler

        # Call the request handler
        @request_handler.call(request, response)

        # Submit the response if status is set
        if response.status
          @connection.submit_response(stream_id, response.to_nv_array, body: response.effective_body)
        end
      end
    end
  end
end
