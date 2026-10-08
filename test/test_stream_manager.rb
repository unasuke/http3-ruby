# frozen_string_literal: true

require "test_helper"

class TestStreamManager < Minitest::Test
  def test_client_bidi_stream_ids_start_at_0
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    assert_equal 0, manager.allocate_bidi_stream_id
  end

  def test_server_bidi_stream_ids_start_at_1
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: true)
    assert_equal 1, manager.allocate_bidi_stream_id
  end

  def test_client_uni_stream_ids_start_at_2
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    assert_equal 2, manager.allocate_uni_stream_id
  end

  def test_server_uni_stream_ids_start_at_3
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: true)
    assert_equal 3, manager.allocate_uni_stream_id
  end

  def test_bidi_stream_ids_increment_by_4
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    assert_equal 0, manager.allocate_bidi_stream_id
    assert_equal 4, manager.allocate_bidi_stream_id
    assert_equal 8, manager.allocate_bidi_stream_id
    assert_equal 12, manager.allocate_bidi_stream_id
  end

  def test_uni_stream_ids_increment_by_4
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    assert_equal 2, manager.allocate_uni_stream_id
    assert_equal 6, manager.allocate_uni_stream_id
    assert_equal 10, manager.allocate_uni_stream_id
  end

  def test_allocate_registers_stream_as_open
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    id = manager.allocate_bidi_stream_id
    assert manager.stream_active?(id)
  end

  def test_register_stream_tracks_external_stream
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    manager.register_stream(100, type: :bidi)
    assert manager.stream_active?(100)
  end

  def test_close_stream_marks_as_closed
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    id = manager.allocate_bidi_stream_id
    assert manager.stream_active?(id)
    manager.close_stream(id)
    refute manager.stream_active?(id)
  end

  def test_remove_stream_deletes_from_tracking
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    id = manager.allocate_bidi_stream_id
    manager.remove_stream(id)
    assert_nil manager.stream_info(id)
  end

  def test_active_stream_ids_returns_open_streams
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    id1 = manager.allocate_bidi_stream_id
    id2 = manager.allocate_bidi_stream_id
    id3 = manager.allocate_bidi_stream_id
    manager.close_stream(id2)

    active = manager.active_stream_ids
    assert_includes active, id1
    refute_includes active, id2
    assert_includes active, id3
  end

  def test_stream_info_returns_type_and_state
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    id = manager.allocate_bidi_stream_id
    info = manager.stream_info(id)
    assert_equal :bidi, info[:type]
    assert_equal :open, info[:state]
  end

  def test_stream_info_returns_nil_for_unknown_stream
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    assert_nil manager.stream_info(999)
  end

  # Stream type detection tests
  def test_client_initiated_detection
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    # Client-initiated: 0, 4, 8, ... (LSB is 0)
    assert manager.client_initiated?(0)
    assert manager.client_initiated?(4)
    assert manager.client_initiated?(8)
    # Server-initiated: 1, 5, 9, ... (LSB is 1)
    refute manager.client_initiated?(1)
    refute manager.client_initiated?(5)
  end

  def test_server_initiated_detection
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    # Server-initiated: 1, 5, 9, ... (LSB is 1)
    assert manager.server_initiated?(1)
    assert manager.server_initiated?(5)
    assert manager.server_initiated?(9)
    # Client-initiated: 0, 4, 8, ... (LSB is 0)
    refute manager.server_initiated?(0)
    refute manager.server_initiated?(4)
  end

  def test_bidirectional_detection
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    # Bidirectional: bit 1 is 0 (0, 1, 4, 5, 8, 9, ...)
    assert manager.bidirectional?(0)
    assert manager.bidirectional?(1)
    assert manager.bidirectional?(4)
    assert manager.bidirectional?(5)
    # Unidirectional: bit 1 is 1 (2, 3, 6, 7, ...)
    refute manager.bidirectional?(2)
    refute manager.bidirectional?(3)
  end

  def test_unidirectional_detection
    manager = HTTP3::Nghttp3::StreamManager.new(is_server: false)
    # Unidirectional: bit 1 is 1 (2, 3, 6, 7, ...)
    assert manager.unidirectional?(2)
    assert manager.unidirectional?(3)
    assert manager.unidirectional?(6)
    assert manager.unidirectional?(7)
    # Bidirectional: bit 1 is 0
    refute manager.unidirectional?(0)
    refute manager.unidirectional?(1)
  end
end
