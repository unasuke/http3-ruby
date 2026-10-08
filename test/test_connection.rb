# frozen_string_literal: true

require "test_helper"

class TestNghttp3Connection < Minitest::Test
  def test_client_new_creates_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    assert_kind_of HTTP3::Nghttp3::Connection, conn
    assert conn.client?
    refute conn.server?
    refute conn.closed?
  ensure
    conn&.close
  end

  def test_client_new_with_settings
    settings = HTTP3::Nghttp3::Settings.default
    conn = HTTP3::Nghttp3::Connection.client_new(settings)
    assert_kind_of HTTP3::Nghttp3::Connection, conn
  ensure
    conn&.close
  end

  def test_server_new_creates_connection
    conn = HTTP3::Nghttp3::Connection.server_new
    assert_kind_of HTTP3::Nghttp3::Connection, conn
    assert conn.server?
    refute conn.client?
    refute conn.closed?
  ensure
    conn&.close
  end

  def test_server_new_with_settings
    settings = HTTP3::Nghttp3::Settings.default
    conn = HTTP3::Nghttp3::Connection.server_new(settings)
    assert_kind_of HTTP3::Nghttp3::Connection, conn
  ensure
    conn&.close
  end

  def test_connection_cannot_be_instantiated_with_new
    # rb_undef_alloc_func causes TypeError with "allocator undefined" message
    assert_raises(TypeError) do
      HTTP3::Nghttp3::Connection.new
    end
  end

  def test_close_marks_connection_as_closed
    conn = HTTP3::Nghttp3::Connection.client_new
    refute conn.closed?
    conn.close
    assert conn.closed?
  end

  def test_close_can_be_called_multiple_times
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    conn.close # Should not raise
    assert conn.closed?
  end

  def test_bind_control_stream
    conn = HTTP3::Nghttp3::Connection.client_new
    # Stream ID 2 is typically used for control stream (client-initiated, unidirectional)
    result = conn.bind_control_stream(2)
    assert_same conn, result # Returns self for chaining
  ensure
    conn&.close
  end

  def test_bind_control_stream_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.bind_control_stream(2)
    end
  end

  def test_bind_qpack_streams
    conn = HTTP3::Nghttp3::Connection.client_new
    # Encoder stream ID 6, Decoder stream ID 10 (client-initiated, unidirectional)
    result = conn.bind_qpack_streams(6, 10)
    assert_same conn, result # Returns self for chaining
  ensure
    conn&.close
  end

  def test_bind_qpack_streams_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.bind_qpack_streams(6, 10)
    end
  end

  def test_method_chaining
    conn = HTTP3::Nghttp3::Connection.client_new
    result = conn
      .bind_control_stream(2)
      .bind_qpack_streams(6, 10)
    assert_same conn, result
  ensure
    conn&.close
  end

  # Stream operation tests

  def test_writev_stream_returns_hash_with_data
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.bind_control_stream(2)
    conn.bind_qpack_streams(6, 10)
    # After binding streams, there's initial settings data to send
    result = conn.writev_stream
    assert_kind_of Hash, result
    assert_includes result.keys, :stream_id
    assert_includes result.keys, :fin
    assert_includes result.keys, :data
    assert_kind_of Integer, result[:stream_id]
    assert_includes [true, false], result[:fin]
    assert_kind_of String, result[:data]
  ensure
    conn&.close
  end

  def test_writev_stream_returns_nil_when_exhausted
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.bind_control_stream(2)
    conn.bind_qpack_streams(6, 10)
    # Drain all pending data
    while (result = conn.writev_stream)
      conn.add_write_offset(result[:stream_id], result[:data].bytesize)
    end
    # Now should return nil
    assert_nil conn.writev_stream
  ensure
    conn&.close
  end

  def test_writev_stream_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.writev_stream
    end
  end

  def test_read_stream_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.read_stream(0, "test")
    end
  end

  def test_add_write_offset_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.add_write_offset(0, 10)
    end
  end

  def test_add_ack_offset_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.add_ack_offset(0, 10)
    end
  end

  def test_block_stream_returns_self
    conn = HTTP3::Nghttp3::Connection.client_new
    result = conn.block_stream(0)
    assert_same conn, result
  ensure
    conn&.close
  end

  def test_block_stream_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.block_stream(0)
    end
  end

  def test_unblock_stream_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.unblock_stream(0)
    end
  end

  def test_stream_writable_returns_boolean
    conn = HTTP3::Nghttp3::Connection.client_new
    result = conn.stream_writable?(0)
    assert_includes [true, false], result
  ensure
    conn&.close
  end

  def test_stream_writable_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.stream_writable?(0)
    end
  end

  def test_close_stream_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.close_stream(0, HTTP3::Nghttp3::H3_NO_ERROR)
    end
  end

  def test_shutdown_stream_write_returns_self
    conn = HTTP3::Nghttp3::Connection.client_new
    result = conn.shutdown_stream_write(0)
    assert_same conn, result
  ensure
    conn&.close
  end

  def test_shutdown_stream_write_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.shutdown_stream_write(0)
    end
  end

  def test_resume_stream_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.resume_stream(0)
    end
  end

  def test_h3_error_code_constants
    assert_equal 0x0100, HTTP3::Nghttp3::H3_NO_ERROR
    assert_equal 0x0101, HTTP3::Nghttp3::H3_GENERAL_PROTOCOL_ERROR
    assert_equal 0x0102, HTTP3::Nghttp3::H3_INTERNAL_ERROR
    assert_kind_of Integer, HTTP3::Nghttp3::H3_STREAM_CREATION_ERROR
    assert_kind_of Integer, HTTP3::Nghttp3::H3_CLOSED_CRITICAL_STREAM
    assert_kind_of Integer, HTTP3::Nghttp3::H3_FRAME_UNEXPECTED
    assert_kind_of Integer, HTTP3::Nghttp3::H3_FRAME_ERROR
    assert_kind_of Integer, HTTP3::Nghttp3::H3_EXCESSIVE_LOAD
    assert_kind_of Integer, HTTP3::Nghttp3::H3_ID_ERROR
    assert_kind_of Integer, HTTP3::Nghttp3::H3_SETTINGS_ERROR
    assert_kind_of Integer, HTTP3::Nghttp3::H3_MISSING_SETTINGS
    assert_kind_of Integer, HTTP3::Nghttp3::H3_REQUEST_REJECTED
    assert_kind_of Integer, HTTP3::Nghttp3::H3_REQUEST_CANCELLED
    assert_kind_of Integer, HTTP3::Nghttp3::H3_REQUEST_INCOMPLETE
    assert_kind_of Integer, HTTP3::Nghttp3::H3_MESSAGE_ERROR
    assert_kind_of Integer, HTTP3::Nghttp3::H3_CONNECT_ERROR
    assert_kind_of Integer, HTTP3::Nghttp3::H3_VERSION_FALLBACK
  end

  # HTTP operation tests

  def test_data_flag_constants
    assert_equal 0x00, HTTP3::Nghttp3::DATA_FLAG_NONE
    assert_equal 0x01, HTTP3::Nghttp3::DATA_FLAG_EOF
    assert_equal 0x02, HTTP3::Nghttp3::DATA_FLAG_NO_END_STREAM
  end

  def test_submit_request_without_body
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.bind_control_stream(2)
    conn.bind_qpack_streams(6, 10)

    headers = [
      HTTP3::Nghttp3::NV.new(":method", "GET"),
      HTTP3::Nghttp3::NV.new(":path", "/"),
      HTTP3::Nghttp3::NV.new(":scheme", "https"),
      HTTP3::Nghttp3::NV.new(":authority", "example.com")
    ]

    result = conn.submit_request(0, headers)
    assert_same conn, result
  ensure
    conn&.close
  end

  def test_submit_request_with_body
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.bind_control_stream(2)
    conn.bind_qpack_streams(6, 10)

    headers = [
      HTTP3::Nghttp3::NV.new(":method", "POST"),
      HTTP3::Nghttp3::NV.new(":path", "/"),
      HTTP3::Nghttp3::NV.new(":scheme", "https"),
      HTTP3::Nghttp3::NV.new(":authority", "example.com")
    ]

    result = conn.submit_request(0, headers, body: "test body")
    assert_same conn, result
  ensure
    conn&.close
  end

  def test_submit_request_raises_on_server_connection
    conn = HTTP3::Nghttp3::Connection.server_new
    headers = [HTTP3::Nghttp3::NV.new(":status", "200")]

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.submit_request(0, headers)
    end
  ensure
    conn&.close
  end

  def test_submit_request_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    headers = [HTTP3::Nghttp3::NV.new(":method", "GET")]

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.submit_request(0, headers)
    end
  end

  def test_submit_response_raises_on_client_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    headers = [HTTP3::Nghttp3::NV.new(":status", "200")]

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.submit_response(0, headers)
    end
  ensure
    conn&.close
  end

  def test_submit_response_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.server_new
    conn.close
    headers = [HTTP3::Nghttp3::NV.new(":status", "200")]

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.submit_response(0, headers)
    end
  end

  def test_submit_info_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.server_new
    conn.close
    headers = [HTTP3::Nghttp3::NV.new(":status", "100")]

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.submit_info(0, headers)
    end
  end

  def test_submit_trailers_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close
    trailers = [HTTP3::Nghttp3::NV.new("trailer-key", "value")]

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.submit_trailers(0, trailers)
    end
  end

  def test_submit_shutdown_notice_returns_self
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.bind_control_stream(2)
    conn.bind_qpack_streams(6, 10)
    result = conn.submit_shutdown_notice
    assert_same conn, result
  ensure
    conn&.close
  end

  def test_submit_shutdown_notice_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.submit_shutdown_notice
    end
  end

  def test_shutdown_returns_self
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.bind_control_stream(2)
    conn.bind_qpack_streams(6, 10)
    conn.submit_shutdown_notice
    result = conn.shutdown
    assert_same conn, result
  ensure
    conn&.close
  end

  def test_shutdown_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.shutdown
    end
  end

  def test_set_and_get_stream_user_data
    conn = HTTP3::Nghttp3::Connection.client_new
    data = {id: 123, name: "test"}

    result = conn.set_stream_user_data(0, data)
    assert_same conn, result

    retrieved = conn.get_stream_user_data(0)
    assert_equal data, retrieved
  ensure
    conn&.close
  end

  def test_get_stream_user_data_returns_nil_for_unknown_stream
    conn = HTTP3::Nghttp3::Connection.client_new
    result = conn.get_stream_user_data(999)
    assert_nil result
  ensure
    conn&.close
  end

  def test_stream_user_data_raises_on_closed_connection
    conn = HTTP3::Nghttp3::Connection.client_new
    conn.close

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.set_stream_user_data(0, "data")
    end

    assert_raises(HTTP3::Nghttp3::InvalidStateError) do
      conn.get_stream_user_data(0)
    end
  end
end
