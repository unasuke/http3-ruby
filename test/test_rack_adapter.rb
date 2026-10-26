# frozen_string_literal: true

require "test_helper"
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

  def test_head_and_204_have_no_body_and_close_it
    body = ClosableBody.new
    assert_nil respond([200, {}, body], method: "HEAD").body
    assert body.closed
    assert_nil respond([204, {}, ["ignored"]]).body
  end

  def test_body_kinds
    assert_kind_of HTTP3::Body::Chunks, respond([200, {}, ["a", "b"]]).body
    assert_kind_of HTTP3::Body::Chunks, respond([200, {}, ClosableBody.new]).body
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

  private

  # A request with headers, and :method and :scheme ("https") unless headers
  # has them.
  def request(headers, method: "GET")
    defaults = [[":method", method], [":scheme", "https"]].reject { |name, _| headers.assoc(name) }
    HTTP3::Request.new(
      stream_id: 0,
      headers: [*defaults, *headers.select { |name, _| name.start_with?(":") },
        *headers.reject { |name, _| name.start_with?(":") }],
      body: "".b
    )
  end

  # The response to a request with headers, and the env the application got,
  # or nil if it was not called.
  def exchange(headers)
    env = nil
    adapter = HTTP3::RackAdapter.new(lambda do |e|
      env = e
      [200, {}, []]
    end)
    [adapter.call(request(headers), remote: REMOTE), env]
  end

  def env_for(headers)
    env = nil
    adapter = HTTP3::RackAdapter.new(lambda do |e|
      env = e
      [200, {}, []]
    end)
    headers = [[":path", "/"], [":authority", "localhost"], *headers] unless headers.assoc(":path")
    adapter.call(request(headers), remote: REMOTE)
    env
  end

  def respond(triple, method: "GET")
    adapter = HTTP3::RackAdapter.new(->(_env) { triple })
    adapter.call(request([[":path", "/"], [":authority", "localhost"]], method: method), remote: REMOTE)
  end
end
