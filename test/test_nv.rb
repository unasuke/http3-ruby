# frozen_string_literal: true

require "test_helper"

class TestNghttp3NV < Minitest::Test
  # NV flag constant tests
  def test_nv_flag_constants_exist
    assert_equal 0x00, HTTP3::Nghttp3::NV_FLAG_NONE
    assert_equal 0x01, HTTP3::Nghttp3::NV_FLAG_NEVER_INDEX
    assert_equal 0x02, HTTP3::Nghttp3::NV_FLAG_NO_COPY_NAME
    assert_equal 0x04, HTTP3::Nghttp3::NV_FLAG_NO_COPY_VALUE
    assert_equal 0x08, HTTP3::Nghttp3::NV_FLAG_TRY_INDEX
  end

  def test_nv_new_creates_nv_with_name_and_value
    nv = HTTP3::Nghttp3::NV.new(":method", "GET")
    assert_kind_of HTTP3::Nghttp3::NV, nv
    assert_equal ":method", nv.name
    assert_equal "GET", nv.value
    assert_equal 0, nv.flags
  end

  def test_nv_new_with_flags
    nv = HTTP3::Nghttp3::NV.new(":path", "/", flags: HTTP3::Nghttp3::NV_FLAG_NEVER_INDEX)
    assert_equal ":path", nv.name
    assert_equal "/", nv.value
    assert_equal HTTP3::Nghttp3::NV_FLAG_NEVER_INDEX, nv.flags
  end

  def test_nv_name_is_frozen
    nv = HTTP3::Nghttp3::NV.new("content-type", "text/html")
    assert nv.name.frozen?
    assert nv.value.frozen?
  end

  def test_nv_with_various_headers
    headers = [
      [":method", "POST"],
      [":path", "/api/v1/users"],
      [":scheme", "https"],
      [":authority", "example.com"],
      ["content-type", "application/json"],
      ["accept", "*/*"]
    ]

    headers.each do |name, value|
      nv = HTTP3::Nghttp3::NV.new(name, value)
      assert_equal name, nv.name
      assert_equal value, nv.value
    end
  end
end
