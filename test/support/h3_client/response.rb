# frozen_string_literal: true

module H3TestClient
  # An HTTP/3 response object
  #
  # Can be used for both:
  # - Client-side: receiving response from server (populated via callbacks)
  # - Server-side: building response to send to client
  class Response
    # @return [Integer] stream ID
    attr_reader :stream_id

    # @return [Integer, nil] HTTP status code
    attr_accessor :status

    # @return [Headers] response headers
    attr_reader :headers

    # @return [String, nil] response body (for simple responses)
    attr_accessor :body

    # Create a new response
    # @param stream_id [Integer] the stream ID this response belongs to
    # @param status [Integer, nil] HTTP status code
    # @param headers [Hash, Headers, nil] response headers
    # @param body [String, nil] response body
    def initialize(stream_id:, status: nil, headers: nil, body: nil)
      @stream_id = stream_id
      @status = status
      @headers = headers.is_a?(Headers) ? headers : Headers.new(headers || {})
      @body = body
      @body_chunks = []
      @headers_sent = false
      @finished = false
    end

    # Convert to HTTP3::Nghttp3::NV array for low-level HTTP3::Nghttp3::Connection API (server-side)
    # @return [Array<NV>] array of HTTP3::Nghttp3::NV objects for status and headers
    def to_nv_array
      nvs = []
      nvs << HTTP3::Nghttp3::NV.new(":status", @status.to_s) if @status
      @headers.each { |name, value| nvs << HTTP3::Nghttp3::NV.new(name, value) }
      nvs
    end

    # Mark headers as sent (for streaming responses)
    # @param extra_headers [Hash] additional headers to merge before sending
    # @return [self]
    def write_headers(extra_headers = {})
      raise HTTP3::Nghttp3::InvalidStateError, "Headers already sent" if @headers_sent
      @headers.merge!(extra_headers) unless extra_headers.empty?
      @headers_sent = true
      self
    end

    # Check if headers have been sent
    # @return [Boolean]
    def headers_sent?
      @headers_sent
    end

    # Write a chunk of body data (for streaming responses)
    # @param chunk [String] body chunk to write
    # @return [self]
    def write(chunk)
      raise HTTP3::Nghttp3::InvalidStateError, "Response already finished" if @finished
      @body_chunks << chunk.to_s
      self
    end

    # Get all body chunks written so far
    # @return [Array<String>]
    def body_chunks
      @body_chunks.dup
    end

    # Get combined body from chunks
    # @return [String]
    def body_from_chunks
      @body_chunks.join
    end

    # Mark the response as finished
    # @return [self]
    def finish
      @finished = true
      self
    end

    # Check if the response is finished
    # @return [Boolean]
    def finished?
      @finished
    end

    # Check if response has a body
    # @return [Boolean]
    def body?
      (@body && !@body.empty?) || !@body_chunks.empty?
    end

    # Get the effective body (either set body or joined chunks)
    # @return [String, nil]
    def effective_body
      return @body if @body && !@body.empty?
      return nil if @body_chunks.empty?
      body_from_chunks
    end

    # Append data to body (for client-side receiving)
    # @param data [String] data to append
    # @return [self]
    def append_body(data)
      @body ||= +""
      @body << data
      self
    end

    # String representation
    def inspect
      status_str = @status ? @status.to_s : "pending"
      finished_str = @finished ? " finished" : ""
      "#<#{self.class} stream_id=#{@stream_id} status=#{status_str}#{finished_str}>"
    end
  end
end
