# frozen_string_literal: true

require "stringio"
require "uri"

module HTTP3
  # Calls a Rack 3 application for an HTTP3::Request and turns what it
  # returns into an HTTP3::Response.
  class RackAdapter
    # The application's response breaks the Rack 3 specification; the
    # server answers 500 instead.
    class InvalidResponse < StandardError; end

    # The request cannot be put in a Rack env; it is answered with 400.
    class BadRequest < StandardError; end
    private_constant :BadRequest

    # The schemes a Rack env may carry (Rack also allows ws and wss, which
    # HTTP/3 has no use for).
    SCHEMES = %w[http https].freeze

    # An authority, "host" or "host:port" (RFC 3986 section 3.2), as Rack
    # Lint checks HTTP_HOST: the port is digits, of any number, or none.
    AUTHORITY = /\A(?<host>#{URI::RFC3986_Parser::HOST})(?::(?<port>\d*))?\z/

    # Connection-specific fields, which HTTP/3 forbids (RFC 9114 section
    # 4.2).
    CONNECTION_FIELDS = %w[connection keep-alive transfer-encoding upgrade proxy-connection].freeze

    # A response field name: a token (RFC 9110 section 5.6.2), lowercase.
    FIELD_NAME = /\A[!#$%&'*+\-.^_`|~0-9a-z]+\z/

    # What a field value must not hold (RFC 9114 section 4.2, and the Rack 3
    # specification).
    FORBIDDEN_IN_VALUE = /[\0\r\n]/

    def initialize(app)
      @app = app
    end

    # remote is the client's address, an Addrinfo. CONNECT is answered with
    # 501, and a request the Rack env cannot carry with 400, without calling
    # the application. Raises whatever the application raises, and
    # InvalidResponse for a response that cannot be sent; the Rack body is
    # closed in both cases.
    def call(request, remote:)
      # The server cannot open a tunnel (RFC 9114 section 4.4), and a
      # CONNECT request has neither :scheme nor :path, so the env would be
      # made up. The Session leaves nghttp3's enable_connect_protocol off,
      # so nghttp3 refuses the :protocol of an extended CONNECT (RFC 9220).
      return Response.new(status: 501, headers: [], body: nil) if request.headers.assoc(":method")&.last == "CONNECT"

      env = env_for(request, remote)
    rescue BadRequest
      # Not logged: the client sent it, the server did not fail.
      Response.new(status: 400, headers: [], body: nil)
    else
      status, headers, body = @app.call(env)
      response_for(request, status, headers, body)
    end

    private

    # Raises BadRequest for what Rack does not allow, or allows in a form
    # the application might read differently from the client, in this
    # order: a scheme other than http and https, a fragment in the path, an
    # authority that is not one (RFC 3986 section 3.2), and an :authority
    # and a host field that disagree (RFC 9114 section 4.3.1). nghttp3 has
    # already refused a request without :scheme, :path, or both :authority
    # and host (but CONNECT); the defaults are for calling the adapter
    # directly.
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

      # nghttp3 takes either case of http and https; Rack wants them in
      # lowercase.
      scheme = pseudo.fetch(":scheme", "https").downcase
      raise BadRequest, "scheme #{scheme} is not http or https" unless SCHEMES.include?(scheme)

      # nghttp3 lets a fragment through; Rack forbids one.
      target = pseudo.fetch(":path", "/")
      raise BadRequest, "the path has a fragment" if target.include?("#")

      path, query = target.split("?", 2)
      host = fields["host"]&.first
      authority = pseudo[":authority"] || host || "localhost"
      match = AUTHORITY.match(authority) or raise BadRequest, "the authority is malformed"
      if pseudo[":authority"] && host && host != pseudo[":authority"]
        raise BadRequest, ":authority and host differ"
      end

      port = match[:port]
      port = (scheme == "http") ? "80" : "443" if port.nil? || port.empty?

      env = {
        "REQUEST_METHOD" => pseudo.fetch(":method", "GET"),
        "SCRIPT_NAME" => "",
        "PATH_INFO" => path,
        "QUERY_STRING" => query || "",
        "SERVER_NAME" => match[:host],
        "SERVER_PORT" => port,
        "SERVER_PROTOCOL" => "HTTP/3",
        "REMOTE_ADDR" => remote.ip_address,
        "HTTP_HOST" => authority,
        "rack.url_scheme" => scheme,
        "rack.input" => StringIO.new(request.body.b),
        "rack.errors" => $stderr
      }
      fields.each do |name, values|
        next if name == "host"
        # "x_forwarded_for" would become HTTP_X_FORWARDED_FOR just like
        # "x-forwarded-for", letting a client slip a value past a proxy that
        # only removes or overwrites the latter. Such names are dropped, as
        # nginx and Puma do.
        next if name.include?("_")

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
    # them, one field per element. nghttp3 sends names and values as they
    # are, so a name that is not a token (":status", say) or a value with
    # NUL, CR or LF would reach the client, or a proxy that turns the
    # response into HTTP/1.1, as fields the application never meant. The
    # message leaves the value out, since it goes to the log.
    def header_pairs(headers)
      pairs = []
      headers.each do |name, value|
        name = name.to_s
        raise InvalidResponse, "header name #{name.inspect} has uppercase letters" if name.match?(/[A-Z]/)
        raise InvalidResponse, "header name #{name.inspect} is not a token" unless name.match?(FIELD_NAME)
        next if CONNECTION_FIELDS.include?(name)

        Array(value).each do |v|
          v = v.to_s
          raise InvalidResponse, "header #{name} has NUL, CR or LF in its value" if v.match?(FORBIDDEN_IN_VALUE)

          pairs << [name, v]
        end
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
