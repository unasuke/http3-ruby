# frozen_string_literal: true

require "stringio"

module HTTP3
  # Calls a Rack 3 application for an HTTP3::Request and turns what it
  # returns into an HTTP3::Response.
  class RackAdapter
    # The application's response breaks the Rack 3 specification; the
    # server answers 500 instead.
    class InvalidResponse < StandardError; end

    # Connection-specific fields, which HTTP/3 forbids (RFC 9114 section
    # 4.2).
    CONNECTION_FIELDS = %w[connection keep-alive transfer-encoding upgrade proxy-connection].freeze

    def initialize(app)
      @app = app
    end

    # remote is the client's address, an Addrinfo. Raises whatever the
    # application raises, and InvalidResponse for a response that cannot be
    # sent; the Rack body is closed in both cases.
    def call(request, remote:)
      status, headers, body = @app.call(env_for(request, remote))
      response_for(request, status, headers, body)
    end

    private

    def env_for(request, remote)
      pseudo = {}
      fields = {}
      request.headers.each do |name, value|
        if name.start_with?(":")
          pseudo[name] ||= value
        else
          (fields[name] ||= []) << value
        end
      end

      path, query = pseudo.fetch(":path", "/").split("?", 2)
      scheme = pseudo.fetch(":scheme", "https")
      authority = pseudo[":authority"] || fields["host"]&.first || "localhost"
      server_name, server_port = split_authority(authority, scheme)

      env = {
        "REQUEST_METHOD" => pseudo.fetch(":method", "GET"),
        "SCRIPT_NAME" => "",
        "PATH_INFO" => path,
        "QUERY_STRING" => query || "",
        "SERVER_NAME" => server_name,
        "SERVER_PORT" => server_port,
        "SERVER_PROTOCOL" => "HTTP/3",
        "REMOTE_ADDR" => remote.ip_address,
        "HTTP_HOST" => authority,
        "rack.url_scheme" => scheme,
        "rack.input" => StringIO.new(request.body.b),
        "rack.errors" => $stderr
      }
      fields.each do |name, values|
        next if name == "host"

        # Cookies are split into one field each in HTTP/3 and joined with
        # "; " again (RFC 9114 section 4.2.1).
        env[env_key(name)] = values.join((name == "cookie") ? "; " : ", ")
      end
      env
    end

    def env_key(name)
      case name
      when "content-type" then "CONTENT_TYPE"
      when "content-length" then "CONTENT_LENGTH"
      else "HTTP_#{name.upcase.tr("-", "_")}"
      end
    end

    # "host", "host:port", "[v6]" or "[v6]:port"; the port defaults to the
    # scheme's.
    def split_authority(authority, scheme)
      default_port = (scheme == "http") ? "80" : "443"
      if (match = authority.match(/\A(\[[^\]]*\])(?::(\d+))?\z/))
        [match[1], match[2] || default_port]
      else
        host, port = authority.split(":", 2)
        [host, port || default_port]
      end
    end

    # The Rack body is closed here unless it goes on in the Response.
    def response_for(request, status, headers, body)
      response = nil
      status = Integer(status)
      headers = header_pairs(headers)

      method = request.headers.assoc(":method")&.last
      response = if method == "HEAD" || status < 200 || status == 204 || status == 304
        close_rack_body(body)
        Response.new(status: status, headers: headers, body: nil)
      else
        Response.new(status: status, headers: headers, body: body_for(body))
      end
    ensure
      close_rack_body(body) if response.nil?
    end

    # Rack 3 headers: lowercase names, each value a String or an Array of
    # them, one field per element.
    def header_pairs(headers)
      pairs = []
      headers.each do |name, value|
        name = name.to_s
        raise InvalidResponse, "header name #{name.inspect} has uppercase letters" if name.match?(/[A-Z]/)
        next if CONNECTION_FIELDS.include?(name)

        Array(value).each { |v| pairs << [name, v.to_s] }
      end
      pairs
    end

    def body_for(body)
      if body.respond_to?(:to_path)
        io = ::File.open(body.to_path, "rb")
        Body::File.new(io: io, offset: 0, length: io.size, rack_body: body)
      elsif body.respond_to?(:to_ary)
        # Rack 3 has to_ary close the body itself.
        Body::Chunks.new(enum: body.to_ary.each, rack_body: nil)
      elsif body.respond_to?(:each)
        Body::Chunks.new(enum: body.to_enum(:each), rack_body: body)
      else
        raise InvalidResponse, "streaming bodies (#{body.class}) are not supported"
      end
    end

    def close_rack_body(body)
      body.close if body.respond_to?(:close)
    end
  end
end
