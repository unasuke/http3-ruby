# frozen_string_literal: true

require "stringio"
require "uri"

module HTTP3
  # Calls a Rack 3 application for an HTTP3::Request and turns what it
  # returns into an HTTP3::Response. Several threads may call it at once,
  # each for a request of its own.
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

    # A body read with each goes through a Body::Pipe of pipe_capacity
    # bytes, whose wake is wake.
    def initialize(app, pipe_capacity:, wake:)
      @app = app
      @pipe_capacity = pipe_capacity
      @wake = wake
      @refusals = Hash.new(0)
      @refusals_lock = Thread::Mutex.new
    end

    # Returns [response, fill]. remote is the client's address, an
    # Addrinfo. CONNECT is answered with 501, and a request the Rack env
    # cannot carry with 400, without calling the application;
    # #take_refusals counts them. Raises whatever the application raises,
    # and InvalidResponse for a response that cannot be sent; the Rack body
    # is closed in both cases.
    #
    # fill is nil, the Rack body closed already, unless the body is read
    # with each: its response has a Body::Pipe, and fill, called once the
    # response has been handed over, writes the body to it and closes the
    # Rack body.
    def call(request, remote:)
      # The server cannot open a tunnel (RFC 9114 section 4.4), and a
      # CONNECT request has neither :scheme nor :path, so the env would be
      # made up. The Session leaves nghttp3's enable_connect_protocol off,
      # so nghttp3 refuses the :protocol of an extended CONNECT (RFC 9220).
      return [refuse(501), nil] if request.headers.assoc(":method")&.last == "CONNECT"

      env = env_for(request, remote)
    rescue BadRequest
      # Not logged: the client sent it, the server did not fail.
      [refuse(400), nil]
    else
      status, headers, body = @app.call(env)
      response_for(request, status, headers, body)
    end

    # The requests answered without the application since the last call,
    # as {status => count}; the count starts over.
    def take_refusals
      @refusals_lock.synchronize do
        refusals = @refusals
        @refusals = Hash.new(0)
        refusals
      end
    end

    private

    def refuse(status)
      @refusals_lock.synchronize { @refusals[status] += 1 }
      Response.new(status: status, headers: [], body: nil)
    end

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
        "rack.input" => request.input,
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

    # [response, fill]. The Rack body is closed here, before anything is
    # sent, unless fill goes on with it, or to_ary has closed it (body_for
    # yields then). Rack 3 only says it is closed "typically after" the
    # body has been sent, and the Body::File reads the file through a
    # descriptor of its own.
    def response_for(request, status, headers, body)
      status = Integer(status)
      # A 1xx is no final response, which is all HTTP/3 can send here (Rack
      # Lint only asks for 100 or more).
      unless (200..599).cover?(status)
        raise InvalidResponse, "status #{status} is not a final status (200..599)"
      end
      headers = header_pairs(headers)
      # A 204 must not have one (RFC 9110 section 8.6); it is dropped as the
      # connection-specific fields are.
      headers = headers.reject { |pair| pair.first == "content-length" } if status == 204
      length = content_length(headers)

      method = request.headers.assoc(":method")&.last
      if method == "HEAD" || status == 204 || status == 304
        # No body is sent, so content-length is not held against one.
        return [Response.new(status: status, headers: headers, body: nil), nil]
      end

      sent, fill = body_for(body, length) { body = nil }
      [Response.new(status: status, headers: headers, body: sent), fill]
    ensure
      begin
        close_rack_body(body)
      rescue
        # The response goes nowhere: a 500 replaces it.
        sent.io.close if sent.is_a?(Body::File)
        raise
      end
    end

    # The content-length among headers, as an Integer, or nil if there is
    # none. The message leaves the value out, as header_pairs's do.
    def content_length(headers)
      values = headers.filter_map { |name, value| value if name == "content-length" }
      return nil if values.empty?
      raise InvalidResponse, "content-length is given more than once" if values.size > 1
      raise InvalidResponse, "content-length is not a number" unless values.first.match?(/\A\d+\z/)

      Integer(values.first, 10)
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

    # [the body to send, fill]. One whose length is known before it is
    # sent, a file or an Array, is held against length, the content-length,
    # now; one read with each, as fill reads it. body_for yields when the
    # Rack body is no longer for response_for to close.
    def body_for(body, length)
      if body.respond_to?(:to_path)
        io = ::File.open(body.to_path, "rb")
        if length && io.size != length
          size = io.size
          io.close
          raise length_mismatch(size)
        end
        [Body::File.new(io: io, offset: 0, length: io.size, rack_body: nil), nil]
      elsif body.respond_to?(:to_ary)
        # Rack 3 has to_ary close the body itself.
        chunks = body.to_ary
        yield
        # Checked before anything is sent, which Session#fill_bodies would
        # only find out once the headers have gone.
        chunks.each do |chunk|
          raise InvalidResponse, "body chunk must be a String (got #{chunk.class})" unless chunk.is_a?(String)
        end
        size = chunks.sum(&:bytesize)
        raise length_mismatch(size) if length && size != length

        [Body::Chunks.new(enum: chunks.each, rack_body: nil), nil]
      elsif body.respond_to?(:each)
        pipe = Body::Pipe.new(capacity: @pipe_capacity, wake: @wake)
        yield
        [pipe, -> { fill(body, pipe, length) }]
      else
        raise InvalidResponse, "streaming bodies (#{body.class}) are not supported"
      end
    end

    # Write the chunks of body's each to pipe, and end it. A chunk that is
    # not a String, one that takes the body past length bytes, an end short
    # of it, and an exception from each fail the pipe, and the stream is
    # aborted then, since the headers have gone. A pipe the server has given
    # up on (the client reset the stream, say) makes write raise
    # StreamClosed, and the body stops there, without failing. The Rack
    # body is closed in every case; an exception from its close is raised.
    def fill(body, pipe, length)
      size = 0
      body.each do |chunk|
        raise InvalidResponse, "body chunk must be a String (got #{chunk.class})" unless chunk.is_a?(String)

        size += chunk.bytesize
        if length && size > length
          raise InvalidResponse, "the body is at least #{size} bytes but content-length says otherwise"
        end

        pipe.write(chunk)
      end
      raise length_mismatch(size) if length && size < length

      pipe.finish
    rescue StreamClosed
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      # Even exit, on a worker, ends only the body.
      pipe.fail(e)
    ensure
      close_rack_body(body)
    end

    def length_mismatch(size)
      InvalidResponse.new("the body is #{size} bytes but content-length says otherwise")
    end

    def close_rack_body(body)
      body.close if body.respond_to?(:close)
    end
  end
end
