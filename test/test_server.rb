# frozen_string_literal: true

require "test_helper"

class TestServer < Minitest::Test
  def test_new_creates_server
    server = HTTP3::Nghttp3::Server.new
    assert_kind_of HTTP3::Nghttp3::Server, server
    assert_kind_of HTTP3::Nghttp3::Connection, server.connection
    assert_kind_of HTTP3::Nghttp3::Settings, server.settings
  end

  def test_new_with_custom_settings
    settings = HTTP3::Nghttp3::Settings.new
    settings.max_field_section_size = 16384
    server = HTTP3::Nghttp3::Server.new(settings: settings)
    assert_equal settings, server.settings
  end

  def test_streams_not_bound_initially
    server = HTTP3::Nghttp3::Server.new
    refute server.streams_bound?
  end

  def test_bind_streams_marks_bound
    server = HTTP3::Nghttp3::Server.new
    server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)
    assert server.streams_bound?
  end

  def test_bind_streams_returns_self
    server = HTTP3::Nghttp3::Server.new
    result = server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)
    assert_same server, result
  end

  def test_on_request_registers_handler
    server = HTTP3::Nghttp3::Server.new
    handler_called = false
    result = server.on_request { |_req, _res| handler_called = true }
    assert_same server, result
  end

  def test_pump_writes_returns_self
    server = HTTP3::Nghttp3::Server.new
    server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)
    result = server.pump_writes { |_, data, _| data.bytesize }
    assert_same server, result
  end

  def test_add_ack_offset_returns_self
    server = HTTP3::Nghttp3::Server.new
    server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)
    result = server.add_ack_offset(0, 100)
    assert_same server, result
  end

  def test_close_closes_connection
    server = HTTP3::Nghttp3::Server.new
    server.bind_streams(control: 3, qpack_encoder: 7, qpack_decoder: 11)
    refute server.closed?
    server.close
    assert server.closed?
  end

  def test_requests_hash_is_accessible
    server = HTTP3::Nghttp3::Server.new
    assert_kind_of Hash, server.requests
  end

  def test_responses_hash_is_accessible
    server = HTTP3::Nghttp3::Server.new
    assert_kind_of Hash, server.responses
  end
end
