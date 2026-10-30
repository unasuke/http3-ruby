# frozen_string_literal: true

require "test_helper"
require "rack/lint"
require "socket"

# HTTP3::RackAdapter's conversions, without a connection.
class TestRackAdapter < Minitest::Test
  REMOTE = Addrinfo.udp("198.51.100.7", 51_234)

  def test_env_from_pseudo_headers
    env = env_for([[":path", "/a/b?x=1&y=2"], [":authority", "example.com:8443"]])
    assert_equal "GET", env["REQUEST_METHOD"]
    assert_equal "/a/b", env["PATH_INFO"]
    assert_equal "x=1&y=2", env["QUERY_STRING"]
    assert_equal "example.com", env["SERVER_NAME"]
    assert_equal "8443", env["SERVER_PORT"]
    assert_equal "example.com:8443", env["HTTP_HOST"]
    assert_equal "https", env["rack.url_scheme"]
    assert_equal "HTTP/3", env["SERVER_PROTOCOL"]
    assert_equal "198.51.100.7", env["REMOTE_ADDR"]
  end

  # rack.input is the request's input itself, not a copy of it, and
  # Rack::Lint takes it.
  def test_rack_input_is_the_request_input
    input = StringIO.new("payload".b)
    env = env_for([[":path", "/"], [":authority", "localhost"]], input: input)
    assert_same input, env["rack.input"]

    adapter = new_adapter(Rack::Lint.new(->(e) { [200, {}, [e["rack.input"].read]] }))
    request = request([[":path", "/"], [":authority", "localhost"]], method: "POST", input: StringIO.new("payload".b))
    response, = adapter.call(request, remote: REMOTE)
    assert_equal 200, response.status
    assert_equal ["payload"], response.body.enum.to_a
  end

  # A request the Rack env cannot carry is answered with 400, and the
  # application is not called.
  def test_schemes_other_than_http_and_https_get_400
    [[[":scheme", "file"], [":path", "etc/passwd"]], [[":scheme", "ftp"], [":path", "/"]]].each do |headers|
      response, env = exchange([*headers, [":authority", "localhost"]])
      assert_equal 400, response.status, headers.inspect
      assert_empty response.headers
      assert_nil response.body
      assert_nil env
    end
  end

  def test_scheme_is_lowercased
    env = env_for([[":scheme", "HTTPS"], [":path", "/"], [":authority", "localhost"]])
    assert_equal "https", env["rack.url_scheme"]
  end

  # Rack forbids a fragment, which nghttp3 lets through.
  def test_path_with_a_fragment_gets_400
    response, env = exchange([[":path", "/a#b"], [":authority", "localhost"]])
    assert_equal 400, response.status
    assert_nil env
  end

  def test_malformed_authority_gets_400
    ["example.com:abc", "a:b:c", "[2001:db8::1", "2001:db8::1]"].each do |authority|
      response, env = exchange([[":path", "/"], [":authority", authority]])
      assert_equal 400, response.status, authority
      assert_nil env
    end
    response, env = exchange([[":path", "/"], ["host", "example.com:abc"]])
    assert_equal 400, response.status
    assert_nil env
  end

  # The port is checked for digits only, as Rack Lint does; an empty one
  # is the scheme's.
  def test_authority_ports
    env = env_for([[":path", "/"], [":authority", "example.com:"]])
    assert_equal ["example.com", "443"], env.values_at("SERVER_NAME", "SERVER_PORT")
    env = env_for([[":scheme", "http"], [":path", "/"], [":authority", "example.com"]])
    assert_equal ["example.com", "80"], env.values_at("SERVER_NAME", "SERVER_PORT")
    env = env_for([[":path", "/"], [":authority", "[2001:db8::1]:8443"]])
    assert_equal ["[2001:db8::1]", "8443"], env.values_at("SERVER_NAME", "SERVER_PORT")
    assert_equal "[2001:db8::1]:8443", env["HTTP_HOST"]
  end

  # RFC 9114 section 4.3.1: if both are present, they must be the same.
  def test_authority_and_host_that_differ_get_400
    response, env = exchange([[":path", "/"], [":authority", "a.example"], ["host", "b.example"]])
    assert_equal 400, response.status
    assert_nil env
    env = env_for([[":path", "/"], [":authority", "a.example"], ["host", "a.example"]])
    assert_equal "a.example", env["HTTP_HOST"]
  end

  # The server opens no tunnels: CONNECT, which has neither :scheme nor
  # :path, gets 501 before anything else is looked at.
  def test_connect_gets_501
    adapter_called = false
    adapter = new_adapter(lambda do |_env|
      adapter_called = true
      [200, {}, []]
    end)
    request = HTTP3::Request.new(stream_id: 0, headers: [[":method", "CONNECT"], [":authority", "example.com:443"]],
      input: StringIO.new("".b))
    response, fill = adapter.call(request, remote: REMOTE)
    assert_equal 501, response.status
    assert_empty response.headers
    assert_nil response.body
    assert_nil fill
    refute adapter_called
  end

  # The 400s and 501s the adapter answers itself are counted until
  # take_refusals; a 400 from the application is not.
  def test_refusals_are_counted_until_taken
    adapter = new_adapter(->(_env) { [400, {}, []] })
    connect = HTTP3::Request.new(stream_id: 0, headers: [[":method", "CONNECT"], [":authority", "example.com:443"]],
      input: StringIO.new("".b))
    assert_equal 501, adapter.call(connect, remote: REMOTE).first.status
    assert_equal 400, adapter.call(request([[":scheme", "ftp"], [":path", "/"], [":authority", "localhost"]]),
      remote: REMOTE).first.status
    assert_equal 400, adapter.call(request([[":path", "/"], [":authority", "localhost"]]), remote: REMOTE).first.status

    assert_equal({400 => 1, 501 => 1}, adapter.take_refusals)
    assert_empty adapter.take_refusals
  end

  def test_repeated_fields_are_joined_and_cookies_with_semicolons
    env = env_for([["accept", "a"], ["accept", "b"], ["cookie", "x=1"], ["cookie", "y=2"],
      ["content-type", "text/plain"]])
    assert_equal "a, b", env["HTTP_ACCEPT"]
    assert_equal "x=1; y=2", env["HTTP_COOKIE"]
    assert_equal "text/plain", env["CONTENT_TYPE"]
    refute env.key?("HTTP_CONTENT_TYPE")
  end

  # "x_forwarded_for" must not pass for "x-forwarded-for".
  def test_fields_with_underscores_are_dropped
    env = env_for([["x_forwarded_for", "203.0.113.9"], ["content_type", "text/evil"], ["x-real", "ok"]])
    refute env.key?("HTTP_X_FORWARDED_FOR")
    refute env.key?("HTTP_CONTENT_TYPE")
    refute env.key?("CONTENT_TYPE")
    assert_equal "ok", env["HTTP_X_REAL"]
  end

  def test_connection_specific_response_fields_are_dropped_and_arrays_split
    response = respond([200, {"connection" => "close", "set-cookie" => ["a=1", "b=2"]}, ["x"]])
    assert_equal [["set-cookie", "a=1"], ["set-cookie", "b=2"]], response.headers
  end

  def test_uppercase_response_field_names_are_refused_and_the_body_closed
    body = ClosableBody.new
    assert_raises(HTTP3::RackAdapter::InvalidResponse) { respond([200, {"Content-Type" => "text/plain"}, body]) }
    assert body.closed
  end

  # nghttp3 would send these as they are: a value with CR or LF could
  # become fields of its own behind a proxy, ":status" a pseudo-header.
  def test_response_fields_http3_cannot_carry_are_refused
    [":status", "x a", "x\r\nset-cookie", ""].each do |name|
      assert_raises(HTTP3::RackAdapter::InvalidResponse, name.inspect) { respond([200, {name => "v"}, []]) }
    end
    ["a\r\nset-cookie: session=1", "a\nb", "a\0b", ["ok", "a\rb"]].each do |value|
      error = assert_raises(HTTP3::RackAdapter::InvalidResponse, value.inspect) do
        respond([200, {"x-a" => value}, []])
      end
      refute_match(/session=1/, error.message)
    end
    assert_equal [["x-a", "tab\tand space"]], respond([200, {"x-a" => "tab\tand space"}, []]).headers
  end

  # Only a final status can end a response; the body is closed.
  def test_status_that_is_not_final_is_refused
    [99, 100, 199, 600].each do |status|
      body = ClosableBody.new
      error = assert_raises(HTTP3::RackAdapter::InvalidResponse, status.to_s) { respond([status, {}, body]) }
      assert_equal "status #{status} is not a final status (200..599)", error.message
      assert body.closed, status.to_s
    end
    assert_equal 599, respond([599, {}, []]).status
  end

  def test_content_length_must_be_one_number
    {["3", "3"] => "content-length is given more than once", "abc" => "content-length is not a number",
     "-1" => "content-length is not a number"}.each do |value, message|
      error = assert_raises(HTTP3::RackAdapter::InvalidResponse, value.inspect) do
        respond([200, {"content-length" => value}, ["abc"]])
      end
      assert_equal message, error.message
    end
    assert_equal [["content-length", "3"]], respond([200, {"content-length" => "3"}, ["abc"]]).headers
  end

  # A body whose length is known is held against content-length before
  # anything is sent; the Rack body is closed once, and the file too.
  def test_content_length_a_known_body_does_not_have
    body = ArrayBody.new(["abc"], 0)
    error = assert_raises(HTTP3::RackAdapter::InvalidResponse) { respond([200, {"content-length" => "4"}, body]) }
    assert_equal "the body is 3 bytes but content-length says otherwise", error.message
    assert_equal 1, body.closes

    Dir.mktmpdir do |dir|
      path = File.join(File.realpath(dir), "file")
      File.write(path, "content")
      body = CountedPathBody.new(path, 0)
      error = assert_raises(HTTP3::RackAdapter::InvalidResponse) { respond([200, {"content-length" => "8"}, body]) }
      assert_equal "the body is 7 bytes but content-length says otherwise", error.message
      assert_equal 1, body.closes
      assert_empty descriptors_of(path) if File.directory?("/proc/self/fd")
    end
  end

  # Before, a chunk that is not a String was only found once the headers
  # had gone; now the response is refused, with or without content-length.
  def test_array_body_chunks_must_be_strings
    error = assert_raises(HTTP3::RackAdapter::InvalidResponse) { respond([200, {}, ["a", 1]]) }
    assert_equal "body chunk must be a String (got Integer)", error.message
  end

  # A body read with each goes through a Body::Pipe, which fill, on the
  # worker, writes it to; fill closes the Rack body once it is done.
  def test_each_body_goes_through_a_pipe
    body = CountingBody.new(["ab", "cd"], 0, 0)
    response, fill = respond_with_fill([200, {}, body])
    assert_kind_of HTTP3::Body::Pipe, response.body
    assert_equal 0, body.closes
    assert_equal [["ab", "cd"], :eof], drain(response, fill)
    assert_equal 1, body.closes
  end

  # fill counts the body as it reads it: the chunk that takes it past
  # content-length fails the pipe, and so does an end short of it. The
  # stream is aborted then, since the headers have gone.
  def test_each_body_is_counted_against_content_length
    {"3" => [["ab"], "the body is at least 4 bytes but content-length says otherwise"],
     "5" => [["ab", "cd"], "the body is 4 bytes but content-length says otherwise"]}.each do |length, (chunks, message)|
      body = CountingBody.new(["ab", "cd"], 0, 0)
      sent, ended = drain(*respond_with_fill([200, {"content-length" => length}, body]))
      assert_equal chunks, sent, length
      assert_kind_of HTTP3::RackAdapter::InvalidResponse, ended
      assert_equal message, ended.message
      assert_equal 1, body.closes, length
    end
    body = CountingBody.new(["ab", "cd"], 0, 0)
    assert_equal [["ab", "cd"], :eof], drain(*respond_with_fill([200, {"content-length" => "4"}, body]))
  end

  def test_each_body_chunks_must_be_strings
    body = CountingBody.new(["ab", 1], 0, 0)
    sent, ended = drain(*respond_with_fill([200, {}, body]))
    assert_equal ["ab"], sent
    assert_kind_of HTTP3::RackAdapter::InvalidResponse, ended
    assert_equal "body chunk must be a String (got Integer)", ended.message
    assert_equal 1, body.closes
  end

  def test_each_that_raises_fails_the_pipe
    body = FailingBody.new(0)
    sent, ended = drain(*respond_with_fill([200, {}, body]))
    assert_equal ["ab"], sent
    assert_kind_of RuntimeError, ended
    assert_equal "each failed", ended.message
    assert_equal 1, body.closes
  end

  # Once the server has given up on the stream (the client reset it, say),
  # the next write raises StreamClosed, and fill stops there without
  # failing; the Rack body is closed all the same.
  def test_fill_stops_once_the_stream_is_gone
    body = CountingBody.new(["ab", "cd", "ef"], 0, 0)
    response, fill = respond_with_fill([200, {}, body])
    failures = []
    response.body.define_singleton_method(:fail) { |error| failures << error }
    response.body.cancel
    assert_nil fill.call
    assert_empty failures
    assert_equal 1, body.yielded
    assert_equal 1, body.closes
  end

  # Only an each body leaves its close to fill: a file, an Array and no
  # body at all have none, and their Rack bodies are closed by the time
  # call returns.
  def test_other_bodies_are_closed_by_call
    Dir.mktmpdir do |dir|
      path = File.join(dir, "file")
      File.write(path, "content")
      body = CountedPathBody.new(path, 0)
      response, fill = respond_with_fill([200, {}, body])
      assert_nil fill
      assert_equal 1, body.closes
      assert_nil response.body.rack_body
      response.body.io.close
    end
    body = ArrayBody.new(["a"], 0)
    response, fill = respond_with_fill([200, {}, body])
    assert_nil fill
    assert_equal 1, body.closes
    assert_nil response.body.rack_body
    body = CountingBody.new(["x"], 0, 0)
    response, fill = respond_with_fill([204, {}, body])
    assert_nil fill
    assert_nil response.body
    assert_equal 1, body.closes
  end

  # No body is sent for HEAD, 204 or 304, so content-length is not held
  # against one; a 204 must not have one at all (RFC 9110 section 8.6).
  def test_content_length_without_a_body
    assert_equal [["content-length", "100"]], respond([200, {"content-length" => "100"}, ["x"]], method: "HEAD").headers
    assert_equal [["content-length", "100"]], respond([304, {"content-length" => "100"}, []]).headers
    assert_empty respond([204, {"content-length" => "100"}, []]).headers
  end

  def test_head_and_204_have_no_body_and_close_it
    body = ClosableBody.new
    assert_nil respond([200, {}, body], method: "HEAD").body
    assert body.closed
    assert_nil respond([204, {}, ["ignored"]]).body
  end

  def test_body_kinds
    assert_kind_of HTTP3::Body::Chunks, respond([200, {}, ["a", "b"]]).body
    assert_kind_of HTTP3::Body::Pipe, respond([200, {}, ClosableBody.new]).body
    Dir.mktmpdir do |dir|
      path = File.join(dir, "file")
      File.write(path, "content")
      body = respond([200, {}, PathBody.new(path)]).body
      assert_kind_of HTTP3::Body::File, body
      assert_equal 7, body.length
      body.io.close
    end
    assert_raises(HTTP3::RackAdapter::InvalidResponse) { respond([200, {}, ->(stream) {}]) }
  end

  ClosableBody = Struct.new(:closed) do
    def each
      yield "chunk"
    end

    def close
      self.closed = true
    end
  end

  PathBody = Struct.new(:to_path) do
    def each
      yield File.binread(to_path)
    end
  end

  # A file body that counts its closes.
  CountedPathBody = Struct.new(:to_path, :closes) do
    def each
      yield File.binread(to_path)
    end

    def close
      self.closes += 1
    end
  end

  # A Rack 3 body with to_ary, which closes it.
  ArrayBody = Struct.new(:chunks, :closes) do
    def each(&)
      chunks.each(&)
    end

    def to_ary
      close
      chunks
    end

    def close
      self.closes += 1
    end
  end

  # A body read with each only, which counts the chunks it yields and its
  # closes.
  CountingBody = Struct.new(:chunks, :yielded, :closes) do
    def each
      chunks.each do |chunk|
        self.yielded += 1
        yield chunk
      end
    end

    def close
      self.closes += 1
    end
  end

  # A body whose each raises after its first chunk.
  FailingBody = Struct.new(:closes) do
    def each
      yield "ab"
      raise "each failed"
    end

    def close
      self.closes += 1
    end
  end

  private

  # A request with headers, and :method and :scheme ("https") unless headers
  # has them, whose body is input.
  def request(headers, method: "GET", input: StringIO.new("".b))
    defaults = [[":method", method], [":scheme", "https"]].reject { |name, _| headers.assoc(name) }
    HTTP3::Request.new(
      stream_id: 0,
      headers: [*defaults, *headers.select { |name, _| name.start_with?(":") },
        *headers.reject { |name, _| name.start_with?(":") }],
      input: input
    )
  end

  # The response to a request with headers, and the env the application got,
  # or nil if it was not called.
  def exchange(headers)
    env = nil
    adapter = new_adapter(lambda do |e|
      env = e
      [200, {}, []]
    end)
    [adapter.call(request(headers), remote: REMOTE).first, env]
  end

  def env_for(headers, input: StringIO.new("".b))
    env = nil
    adapter = new_adapter(lambda do |e|
      env = e
      [200, {}, []]
    end)
    headers = [[":path", "/"], [":authority", "localhost"], *headers] unless headers.assoc(":path")
    adapter.call(request(headers, input: input), remote: REMOTE)
    env
  end

  # The descriptors of this process open on path (Linux).
  def descriptors_of(path)
    Dir.children("/proc/self/fd").map(&:to_i).select do |fd|
      File.readlink("/proc/self/fd/#{fd}") == path
    rescue Errno::ENOENT
      false
    end
  end

  def respond(triple, method: "GET")
    respond_with_fill(triple, method: method).first
  end

  # [response, fill] for the application's triple.
  def respond_with_fill(triple, method: "GET")
    adapter = new_adapter(->(_env) { triple })
    adapter.call(request([[":path", "/"], [":authority", "localhost"]], method: method), remote: REMOTE)
  end

  def new_adapter(app)
    HTTP3::RackAdapter.new(app, pipe_capacity: 65_536, wake: -> {})
  end

  # Call fill on a thread of its own, as a worker does, and take what it
  # writes to the response's pipe until the end: [the chunks, :eof or the
  # exception that ended the body].
  def drain(response, fill)
    pipe = response.body
    filler = Thread.new(&fill)
    chunks = []
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      taken = pipe.take
      case taken
      when String then chunks << taken
      when nil
        raise "the body did not end" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.001
      else
        filler.join(5)
        return [chunks, taken]
      end
    end
  end
end
