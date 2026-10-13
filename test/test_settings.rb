# frozen_string_literal: true

require "test_helper"

class TestNghttp3Settings < Minitest::Test
  def test_settings_new_creates_empty_settings
    settings = HTTP3::Nghttp3::Settings.new
    assert_kind_of HTTP3::Nghttp3::Settings, settings
    assert_equal 0, settings.max_field_section_size
    assert_equal 0, settings.qpack_max_dtable_capacity
    assert_equal 0, settings.qpack_encoder_max_dtable_capacity
    assert_equal 0, settings.qpack_blocked_streams
    assert_equal false, settings.enable_connect_protocol
    assert_equal false, settings.h3_datagram
  end

  def test_settings_default_creates_settings_with_default_values
    settings = HTTP3::Nghttp3::Settings.default
    assert_kind_of HTTP3::Nghttp3::Settings, settings

    # Check default values from nghttp3_settings_default
    assert_operator settings.max_field_section_size, :>, 0
    assert_equal 0, settings.qpack_max_dtable_capacity
    assert_equal 4096, settings.qpack_encoder_max_dtable_capacity
    assert_equal 0, settings.qpack_blocked_streams
    assert_equal false, settings.enable_connect_protocol
  end

  def test_settings_max_field_section_size_getter_and_setter
    settings = HTTP3::Nghttp3::Settings.new
    settings.max_field_section_size = 16384
    assert_equal 16384, settings.max_field_section_size
  end

  def test_settings_qpack_max_dtable_capacity_getter_and_setter
    settings = HTTP3::Nghttp3::Settings.new
    settings.qpack_max_dtable_capacity = 4096
    assert_equal 4096, settings.qpack_max_dtable_capacity
  end

  def test_settings_qpack_encoder_max_dtable_capacity_getter_and_setter
    settings = HTTP3::Nghttp3::Settings.new
    settings.qpack_encoder_max_dtable_capacity = 8192
    assert_equal 8192, settings.qpack_encoder_max_dtable_capacity
  end

  def test_settings_qpack_blocked_streams_getter_and_setter
    settings = HTTP3::Nghttp3::Settings.new
    settings.qpack_blocked_streams = 100
    assert_equal 100, settings.qpack_blocked_streams
  end

  def test_settings_enable_connect_protocol_getter_and_setter
    settings = HTTP3::Nghttp3::Settings.new
    assert_equal false, settings.enable_connect_protocol

    settings.enable_connect_protocol = true
    assert_equal true, settings.enable_connect_protocol

    settings.enable_connect_protocol = false
    assert_equal false, settings.enable_connect_protocol
  end

  def test_settings_h3_datagram_getter_and_setter
    settings = HTTP3::Nghttp3::Settings.new
    assert_equal false, settings.h3_datagram

    settings.h3_datagram = true
    assert_equal true, settings.h3_datagram

    settings.h3_datagram = false
    assert_equal false, settings.h3_datagram
  end
end
