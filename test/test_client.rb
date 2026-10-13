# frozen_string_literal: true

require "test_helper"

class TestClient < Minitest::Test
  def test_new_creates_client
    client = HTTP3::Nghttp3::Client.new
    assert_kind_of HTTP3::Nghttp3::Client, client
    assert_kind_of HTTP3::Nghttp3::Connection, client.connection
    assert_kind_of HTTP3::Nghttp3::Settings, client.settings
  end

  def test_new_with_custom_settings
    settings = HTTP3::Nghttp3::Settings.new
    settings.max_field_section_size = 16384
    client = HTTP3::Nghttp3::Client.new(settings: settings)
    assert_equal settings, client.settings
  end

  def test_streams_not_bound_initially
    client = HTTP3::Nghttp3::Client.new
    refute client.streams_bound?
  end

  def test_bind_streams_marks_bound
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    assert client.streams_bound?
  end

  def test_submit_raises_if_streams_not_bound
    client = HTTP3::Nghttp3::Client.new
    request = HTTP3::Nghttp3::Request.get("https://example.com/")
    assert_raises(HTTP3::Nghttp3::InvalidStateError) { client.submit(request) }
  end

  def test_submit_returns_stream_id
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    request = HTTP3::Nghttp3::Request.get("https://example.com/")
    stream_id = client.submit(request)
    assert_kind_of Integer, stream_id
    assert_equal 0, stream_id  # First client bidi stream
  end

  def test_submit_increments_stream_ids
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)

    stream1 = client.submit(HTTP3::Nghttp3::Request.get("https://example.com/1"))
    stream2 = client.submit(HTTP3::Nghttp3::Request.get("https://example.com/2"))
    stream3 = client.submit(HTTP3::Nghttp3::Request.get("https://example.com/3"))

    assert_equal 0, stream1
    assert_equal 4, stream2
    assert_equal 8, stream3
  end

  def test_submit_tracks_pending_request
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    request = HTTP3::Nghttp3::Request.get("https://example.com/")
    stream_id = client.submit(request)
    assert_equal request, client.pending_requests[stream_id]
  end

  def test_submit_creates_response_object
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    stream_id = client.submit(HTTP3::Nghttp3::Request.get("https://example.com/"))
    response = client.responses[stream_id]
    assert_kind_of HTTP3::Nghttp3::Response, response
    assert_equal stream_id, response.stream_id
  end

  def test_get_convenience_method
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    stream_id = client.get("https://example.com/path")
    assert_equal 0, stream_id
    request = client.pending_requests[stream_id]
    assert_equal "GET", request.method
    assert_equal "/path", request.path
  end

  def test_post_convenience_method
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    stream_id = client.post("https://example.com/api", body: '{"key":"value"}')
    request = client.pending_requests[stream_id]
    assert_equal "POST", request.method
    assert_equal '{"key":"value"}', request.body
  end

  def test_put_convenience_method
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    stream_id = client.put("https://example.com/api", body: "data")
    request = client.pending_requests[stream_id]
    assert_equal "PUT", request.method
  end

  def test_delete_convenience_method
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    stream_id = client.delete("https://example.com/api/1")
    request = client.pending_requests[stream_id]
    assert_equal "DELETE", request.method
  end

  def test_head_convenience_method
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    stream_id = client.head("https://example.com/")
    request = client.pending_requests[stream_id]
    assert_equal "HEAD", request.method
  end

  def test_pump_writes_yields_pending_data
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    client.submit(HTTP3::Nghttp3::Request.get("https://example.com/"))

    writes = []
    client.pump_writes do |stream_id, data, fin|
      writes << {stream_id: stream_id, data: data, fin: fin}
      data.bytesize
    end

    refute writes.empty?, "Expected some data to be written"
  end

  def test_pump_writes_returns_self
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    result = client.pump_writes { |_, data, _| data.bytesize }
    assert_same client, result
  end

  def test_add_ack_offset_returns_self
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    result = client.add_ack_offset(0, 100)
    assert_same client, result
  end

  def test_close_closes_connection
    client = HTTP3::Nghttp3::Client.new
    client.bind_streams(control: 2, qpack_encoder: 6, qpack_decoder: 10)
    refute client.closed?
    client.close
    assert client.closed?
  end

  def test_responses_hash_is_accessible
    client = HTTP3::Nghttp3::Client.new
    assert_kind_of Hash, client.responses
  end

  def test_pending_requests_hash_is_accessible
    client = HTTP3::Nghttp3::Client.new
    assert_kind_of Hash, client.pending_requests
  end
end
