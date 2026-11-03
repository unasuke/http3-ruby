# frozen_string_literal: true

require "test_helper"

class TestNghttp3Callbacks < Minitest::Test
  def test_callbacks_new_creates_callbacks
    callbacks = HTTP3::Nghttp3::Callbacks.new
    assert_kind_of HTTP3::Nghttp3::Callbacks, callbacks
  end

  # Test all callback setters return self for chaining
  def test_on_acked_stream_data_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_acked_stream_data { |stream_id, datalen| }
    assert_same callbacks, result
  end

  def test_on_stream_close_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_stream_close { |stream_id, app_error_code| }
    assert_same callbacks, result
  end

  def test_on_recv_data_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_recv_data { |stream_id, data| }
    assert_same callbacks, result
  end

  def test_on_deferred_consume_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_deferred_consume { |stream_id, consumed| }
    assert_same callbacks, result
  end

  def test_on_begin_headers_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_begin_headers { |stream_id| }
    assert_same callbacks, result
  end

  def test_on_recv_header_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_recv_header { |stream_id, name, value, flags| }
    assert_same callbacks, result
  end

  def test_on_end_headers_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_end_headers { |stream_id, fin| }
    assert_same callbacks, result
  end

  def test_on_begin_trailers_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_begin_trailers { |stream_id| }
    assert_same callbacks, result
  end

  def test_on_recv_trailer_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_recv_trailer { |stream_id, name, value, flags| }
    assert_same callbacks, result
  end

  def test_on_end_trailers_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_end_trailers { |stream_id, fin| }
    assert_same callbacks, result
  end

  def test_on_stop_sending_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_stop_sending { |stream_id, app_error_code| }
    assert_same callbacks, result
  end

  def test_on_end_stream_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_end_stream { |stream_id| }
    assert_same callbacks, result
  end

  def test_on_reset_stream_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_reset_stream { |stream_id, app_error_code| }
    assert_same callbacks, result
  end

  def test_on_shutdown_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_shutdown { |id| }
    assert_same callbacks, result
  end

  def test_on_recv_settings_accepts_block_and_returns_self
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks.on_recv_settings { |settings| }
    assert_same callbacks, result
  end

  def test_method_chaining
    callbacks = HTTP3::Nghttp3::Callbacks.new
    result = callbacks
      .on_begin_headers { |stream_id| }
      .on_recv_header { |stream_id, name, value, flags| }
      .on_end_headers { |stream_id, fin| }
      .on_recv_data { |stream_id, data| }
      .on_end_stream { |stream_id| }
    assert_same callbacks, result
  end

  def test_client_connection_with_callbacks
    callbacks = HTTP3::Nghttp3::Callbacks.new
    conn = HTTP3::Nghttp3::Connection.client_new(nil, callbacks)
    assert_kind_of HTTP3::Nghttp3::Connection, conn
    assert conn.client?
  ensure
    conn&.close
  end

  def test_server_connection_with_callbacks
    callbacks = HTTP3::Nghttp3::Callbacks.new
    conn = HTTP3::Nghttp3::Connection.server_new(nil, callbacks)
    assert_kind_of HTTP3::Nghttp3::Connection, conn
    assert conn.server?
  ensure
    conn&.close
  end

  def test_client_connection_with_settings_and_callbacks
    settings = HTTP3::Nghttp3::Settings.default
    callbacks = HTTP3::Nghttp3::Callbacks.new
    callbacks.on_recv_header { |stream_id, name, value, flags| }

    conn = HTTP3::Nghttp3::Connection.client_new(settings, callbacks)
    assert_kind_of HTTP3::Nghttp3::Connection, conn
  ensure
    conn&.close
  end

  def test_server_connection_with_settings_and_callbacks
    settings = HTTP3::Nghttp3::Settings.default
    callbacks = HTTP3::Nghttp3::Callbacks.new
    callbacks.on_recv_header { |stream_id, name, value, flags| }

    conn = HTTP3::Nghttp3::Connection.server_new(settings, callbacks)
    assert_kind_of HTTP3::Nghttp3::Connection, conn
  ensure
    conn&.close
  end

  # The server's on_recv_settings gets the SETTINGS the client sent, as
  # nghttp3 parsed them, and nothing else. Four of them differ from the
  # defaults, so that none can pass for another.
  def test_on_recv_settings_gets_the_peer_settings
    settings = HTTP3::Nghttp3::Settings.default
    settings.max_field_section_size = 12_345
    settings.qpack_max_dtable_capacity = 1_024
    settings.qpack_blocked_streams = 7
    settings.h3_datagram = true
    client = HTTP3::Nghttp3::Connection.client_new(settings)
    client.bind_control_stream(2)
    client.bind_qpack_streams(6, 10)

    received = []
    callbacks = HTTP3::Nghttp3::Callbacks.new
    callbacks.on_recv_settings { |peer| received << peer }
    server = HTTP3::Nghttp3::Connection.server_new(nil, callbacks)
    server.bind_control_stream(3)
    server.bind_qpack_streams(7, 11)

    while (out = client.writev_stream)
      server.read_stream(out[:stream_id], out[:data], fin: out[:fin])
      client.add_write_offset(out[:stream_id], out[:data].bytesize)
    end

    expected = {
      max_field_section_size: 12_345, qpack_max_dtable_capacity: 1_024, qpack_blocked_streams: 7,
      enable_connect_protocol: false, h3_datagram: true
    }
    assert_equal [expected], received
  ensure
    client&.close
    server&.close
  end

  def test_connection_without_callbacks_still_works
    # Ensure backward compatibility - nil callbacks should work
    conn = HTTP3::Nghttp3::Connection.client_new
    assert_kind_of HTTP3::Nghttp3::Connection, conn
  ensure
    conn&.close
  end
end
