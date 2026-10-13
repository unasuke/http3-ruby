# frozen_string_literal: true

require "test_helper"

class TestRequest < Minitest::Test
  def test_new_creates_request
    request = HTTP3::Nghttp3::Request.new(
      method: "GET",
      path: "/",
      scheme: "https",
      authority: "example.com"
    )
    assert_kind_of HTTP3::Nghttp3::Request, request
    assert_equal "GET", request.method
    assert_equal "/", request.path
    assert_equal "https", request.scheme
    assert_equal "example.com", request.authority
  end

  def test_method_is_uppercased
    request = HTTP3::Nghttp3::Request.new(method: "get", path: "/")
    assert_equal "GET", request.method
  end

  def test_method_accepts_symbol
    request = HTTP3::Nghttp3::Request.new(method: :post, path: "/")
    assert_equal "POST", request.method
  end

  def test_request_is_frozen
    request = HTTP3::Nghttp3::Request.new(method: "GET", path: "/")
    assert request.frozen?
    assert request.method.frozen?
    assert request.path.frozen?
  end

  def test_new_with_headers
    request = HTTP3::Nghttp3::Request.new(
      method: "GET",
      path: "/",
      headers: {"accept" => "text/html"}
    )
    assert_equal "text/html", request.headers["accept"]
  end

  def test_new_with_body
    request = HTTP3::Nghttp3::Request.new(
      method: "POST",
      path: "/api",
      body: '{"key":"value"}'
    )
    assert_equal '{"key":"value"}', request.body
    assert request.body?
  end

  def test_body_returns_false_for_nil_body
    request = HTTP3::Nghttp3::Request.new(method: "GET", path: "/")
    refute request.body?
  end

  def test_body_returns_false_for_empty_body
    request = HTTP3::Nghttp3::Request.new(method: "POST", path: "/", body: "")
    refute request.body?
  end

  def test_to_nv_array_returns_nv_objects
    request = HTTP3::Nghttp3::Request.new(
      method: "GET",
      scheme: "https",
      authority: "example.com",
      path: "/test",
      headers: {"accept" => "*/*"}
    )
    nvs = request.to_nv_array
    assert_kind_of Array, nvs
    assert nvs.all? { |nv| nv.is_a?(HTTP3::Nghttp3::NV) }

    names = nvs.map(&:name)
    assert_includes names, ":method"
    assert_includes names, ":scheme"
    assert_includes names, ":authority"
    assert_includes names, ":path"
    assert_includes names, "accept"

    method_nv = nvs.find { |nv| nv.name == ":method" }
    assert_equal "GET", method_nv.value
  end

  def test_to_nv_array_omits_authority_if_nil
    request = HTTP3::Nghttp3::Request.new(method: "GET", path: "/")
    nvs = request.to_nv_array
    names = nvs.map(&:name)
    refute_includes names, ":authority"
  end

  # Factory method tests
  def test_get_creates_get_request
    request = HTTP3::Nghttp3::Request.get("https://example.com/path")
    assert_equal "GET", request.method
    assert_equal "https", request.scheme
    assert_equal "example.com", request.authority
    assert_equal "/path", request.path
  end

  def test_get_with_query_string
    request = HTTP3::Nghttp3::Request.get("https://example.com/search?q=test")
    assert_equal "/search?q=test", request.path
  end

  def test_get_with_port
    request = HTTP3::Nghttp3::Request.get("https://example.com:8443/path")
    assert_equal "example.com:8443", request.authority
  end

  def test_get_with_default_port_omits_port
    request = HTTP3::Nghttp3::Request.get("https://example.com:443/path")
    assert_equal "example.com", request.authority
  end

  def test_get_with_headers
    request = HTTP3::Nghttp3::Request.get("https://example.com/", headers: {"accept" => "text/html"})
    assert_equal "text/html", request.headers["accept"]
  end

  def test_post_creates_post_request
    request = HTTP3::Nghttp3::Request.post("https://example.com/api", body: "data")
    assert_equal "POST", request.method
    assert_equal "data", request.body
  end

  def test_put_creates_put_request
    request = HTTP3::Nghttp3::Request.put("https://example.com/api", body: "data")
    assert_equal "PUT", request.method
    assert_equal "data", request.body
  end

  def test_delete_creates_delete_request
    request = HTTP3::Nghttp3::Request.delete("https://example.com/api/1")
    assert_equal "DELETE", request.method
    assert_equal "/api/1", request.path
  end

  def test_head_creates_head_request
    request = HTTP3::Nghttp3::Request.head("https://example.com/")
    assert_equal "HEAD", request.method
  end

  def test_patch_creates_patch_request
    request = HTTP3::Nghttp3::Request.patch("https://example.com/api", body: "data")
    assert_equal "PATCH", request.method
  end

  def test_options_creates_options_request
    request = HTTP3::Nghttp3::Request.options("https://example.com/api")
    assert_equal "OPTIONS", request.method
  end

  def test_inspect_returns_readable_string
    request = HTTP3::Nghttp3::Request.get("https://example.com/path")
    inspect_str = request.inspect
    assert_includes inspect_str, "GET"
    assert_includes inspect_str, "https"
    assert_includes inspect_str, "example.com"
    assert_includes inspect_str, "/path"
  end
end
