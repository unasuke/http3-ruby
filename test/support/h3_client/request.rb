# frozen_string_literal: true

require "uri"

module H3TestClient
  # An immutable HTTP/3 request object
  #
  # Represents an HTTP request with method, path, headers, and optional body.
  # Can be created directly or via convenience factory methods.
  class Request
    # @return [String] HTTP method (GET, POST, etc.)
    attr_reader :method

    # @return [String] URL scheme (https, http)
    attr_reader :scheme

    # @return [String, nil] authority (host:port)
    attr_reader :authority

    # @return [String] request path
    attr_reader :path

    # @return [Headers] request headers
    attr_reader :headers

    # @return [String, nil] request body
    attr_reader :body

    # Create a new request
    # @param method [String, Symbol] HTTP method
    # @param path [String] request path
    # @param scheme [String] URL scheme (default: "https")
    # @param authority [String, nil] authority (host:port)
    # @param headers [Hash, Headers] additional headers
    # @param body [String, nil] request body
    def initialize(method:, path:, scheme: "https", authority: nil, headers: {}, body: nil)
      @method = method.to_s.upcase.freeze
      @scheme = scheme.to_s.freeze
      @authority = authority&.to_s&.freeze
      @path = path.to_s.freeze
      @headers = headers.is_a?(Headers) ? headers : Headers.new(headers)
      @body = body&.dup&.freeze
      freeze
    end

    # Convert to HTTP3::Nghttp3::NV array for low-level HTTP3::Nghttp3::Connection API
    # @return [Array<NV>] array of HTTP3::Nghttp3::NV objects for pseudo-headers and headers
    def to_nv_array
      nvs = []
      nvs << HTTP3::Nghttp3::NV.new(":method", @method)
      nvs << HTTP3::Nghttp3::NV.new(":scheme", @scheme)
      nvs << HTTP3::Nghttp3::NV.new(":authority", @authority) if @authority
      nvs << HTTP3::Nghttp3::NV.new(":path", @path)
      @headers.each { |name, value| nvs << HTTP3::Nghttp3::NV.new(name, value) }
      nvs
    end

    # Check if request has a body
    # @return [Boolean]
    def body?
      !@body.nil? && !@body.empty?
    end

    # String representation
    def inspect
      "#<#{self.class} #{@method} #{@scheme}://#{@authority}#{@path}>"
    end

    class << self
      # Create a GET request
      # @param url [String] full URL
      # @param headers [Hash] additional headers
      # @return [Request]
      def get(url, headers: {})
        build_from_url("GET", url, headers: headers)
      end

      # Create a POST request
      # @param url [String] full URL
      # @param body [String, nil] request body
      # @param headers [Hash] additional headers
      # @return [Request]
      def post(url, body: nil, headers: {})
        build_from_url("POST", url, body: body, headers: headers)
      end

      # Create a PUT request
      # @param url [String] full URL
      # @param body [String, nil] request body
      # @param headers [Hash] additional headers
      # @return [Request]
      def put(url, body: nil, headers: {})
        build_from_url("PUT", url, body: body, headers: headers)
      end

      # Create a DELETE request
      # @param url [String] full URL
      # @param headers [Hash] additional headers
      # @return [Request]
      def delete(url, headers: {})
        build_from_url("DELETE", url, headers: headers)
      end

      # Create a HEAD request
      # @param url [String] full URL
      # @param headers [Hash] additional headers
      # @return [Request]
      def head(url, headers: {})
        build_from_url("HEAD", url, headers: headers)
      end

      # Create a PATCH request
      # @param url [String] full URL
      # @param body [String, nil] request body
      # @param headers [Hash] additional headers
      # @return [Request]
      def patch(url, body: nil, headers: {})
        build_from_url("PATCH", url, body: body, headers: headers)
      end

      # Create an OPTIONS request
      # @param url [String] full URL
      # @param headers [Hash] additional headers
      # @return [Request]
      def options(url, headers: {})
        build_from_url("OPTIONS", url, headers: headers)
      end

      private

      def build_from_url(method, url, body: nil, headers: {})
        uri = URI.parse(url)
        authority = (uri.port == uri.default_port) ? uri.host : "#{uri.host}:#{uri.port}"
        path = uri.request_uri.empty? ? "/" : uri.request_uri

        new(
          method: method,
          scheme: uri.scheme || "https",
          authority: authority,
          path: path,
          headers: headers,
          body: body
        )
      end
    end
  end
end
