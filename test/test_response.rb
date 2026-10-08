# frozen_string_literal: true

require "test_helper"

class TestResponse < Minitest::Test
  def test_new_creates_response
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    assert_kind_of HTTP3::Nghttp3::Response, response
    assert_equal 0, response.stream_id
    assert_nil response.status
    assert_nil response.body
  end

  def test_new_with_status
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    assert_equal 200, response.status
  end

  def test_new_with_headers_hash
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, headers: {"content-type" => "text/html"})
    assert_equal "text/html", response.headers["content-type"]
  end

  def test_new_with_headers_object
    headers = HTTP3::Nghttp3::Headers.new({"content-type" => "text/html"})
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, headers: headers)
    assert_equal "text/html", response.headers["content-type"]
  end

  def test_new_with_body
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, body: "Hello")
    assert_equal "Hello", response.body
  end

  def test_status_is_writable
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    response.status = 404
    assert_equal 404, response.status
  end

  def test_body_is_writable
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    response.body = "Hello"
    assert_equal "Hello", response.body
  end

  def test_headers_bracket_assignment
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    response.headers["content-type"] = "application/json"
    assert_equal "application/json", response.headers["content-type"]
  end

  def test_to_nv_array_returns_nv_objects
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    response.headers["content-type"] = "text/html"
    nvs = response.to_nv_array
    assert_kind_of Array, nvs
    assert nvs.all? { |nv| nv.is_a?(HTTP3::Nghttp3::NV) }

    status_nv = nvs.find { |nv| nv.name == ":status" }
    assert_equal "200", status_nv.value
  end

  def test_to_nv_array_omits_status_if_nil
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    nvs = response.to_nv_array
    names = nvs.map(&:name)
    refute_includes names, ":status"
  end

  # Streaming response tests
  def test_write_headers_marks_headers_sent
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    refute response.headers_sent?
    response.write_headers
    assert response.headers_sent?
  end

  def test_write_headers_with_extra_headers
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    response.write_headers({"x-custom" => "value"})
    assert_equal "value", response.headers["x-custom"]
  end

  def test_write_headers_raises_if_already_sent
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    response.write_headers
    assert_raises(HTTP3::Nghttp3::InvalidStateError) { response.write_headers }
  end

  def test_write_appends_chunk
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    response.write("chunk1")
    response.write("chunk2")
    assert_equal ["chunk1", "chunk2"], response.body_chunks
  end

  def test_write_returns_self
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    result = response.write("chunk")
    assert_same response, result
  end

  def test_write_raises_if_finished
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    response.finish
    assert_raises(HTTP3::Nghttp3::InvalidStateError) { response.write("chunk") }
  end

  def test_body_from_chunks_joins_chunks
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    response.write("Hello, ")
    response.write("World!")
    assert_equal "Hello, World!", response.body_from_chunks
  end

  def test_finish_marks_response_finished
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    refute response.finished?
    response.finish
    assert response.finished?
  end

  def test_body_returns_true_with_body
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, body: "Hello")
    assert response.body?
  end

  def test_body_returns_true_with_chunks
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    response.write("chunk")
    assert response.body?
  end

  def test_body_returns_false_without_body_or_chunks
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    refute response.body?
  end

  def test_effective_body_returns_body_if_set
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, body: "Hello")
    assert_equal "Hello", response.effective_body
  end

  def test_effective_body_returns_chunks_if_no_body
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    response.write("chunk1")
    response.write("chunk2")
    assert_equal "chunk1chunk2", response.effective_body
  end

  def test_effective_body_returns_nil_if_empty
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    assert_nil response.effective_body
  end

  def test_append_body_appends_data
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    response.append_body("Hello")
    response.append_body(" World")
    assert_equal "Hello World", response.body
  end

  def test_inspect_returns_readable_string
    response = HTTP3::Nghttp3::Response.new(stream_id: 4, status: 200)
    inspect_str = response.inspect
    assert_includes inspect_str, "stream_id=4"
    assert_includes inspect_str, "200"
  end

  def test_inspect_shows_pending_for_nil_status
    response = HTTP3::Nghttp3::Response.new(stream_id: 0)
    inspect_str = response.inspect
    assert_includes inspect_str, "pending"
  end

  def test_inspect_shows_finished
    response = HTTP3::Nghttp3::Response.new(stream_id: 0, status: 200)
    response.finish
    inspect_str = response.inspect
    assert_includes inspect_str, "finished"
  end
end
