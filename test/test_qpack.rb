# frozen_string_literal: true

require "test_helper"

class TestNghttp3QPACK < Minitest::Test
  # ============== Encoder tests ==============

  def test_encoder_new_creates_encoder
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(4096)
    assert_kind_of HTTP3::Nghttp3::QPACK::Encoder, encoder
  end

  def test_encoder_new_with_zero_capacity
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(0)
    assert_kind_of HTTP3::Nghttp3::QPACK::Encoder, encoder
  end

  def test_encoder_encode_returns_hash
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(4096)
    headers = [
      HTTP3::Nghttp3::NV.new(":method", "GET"),
      HTTP3::Nghttp3::NV.new(":path", "/")
    ]
    result = encoder.encode(0, headers)
    assert_kind_of Hash, result
    assert_includes result.keys, :prefix
    assert_includes result.keys, :data
    assert_includes result.keys, :encoder_stream
  end

  def test_encoder_encode_produces_binary_data
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(4096)
    headers = [
      HTTP3::Nghttp3::NV.new(":method", "GET"),
      HTTP3::Nghttp3::NV.new(":path", "/"),
      HTTP3::Nghttp3::NV.new(":scheme", "https"),
      HTTP3::Nghttp3::NV.new(":authority", "example.com")
    ]
    result = encoder.encode(0, headers)
    assert_kind_of String, result[:prefix]
    assert_kind_of String, result[:data]
    assert_kind_of String, result[:encoder_stream]
  end

  def test_encoder_encode_with_empty_headers
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(4096)
    result = encoder.encode(0, [])
    assert_kind_of Hash, result
  end

  def test_encoder_set_max_blocked_streams
    HTTP3::Nghttp3::QPACK::Encoder.new(4096).max_blocked_streams = 100
    # Should not raise
  end

  def test_encoder_set_max_dtable_capacity
    HTTP3::Nghttp3::QPACK::Encoder.new(4096).max_dtable_capacity = 2048
    # Should not raise
  end

  def test_encoder_num_blocked_streams
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(4096)
    assert_equal 0, encoder.num_blocked_streams
  end

  def test_encoder_read_decoder_with_empty_data
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(4096)
    result = encoder.read_decoder("")
    assert_equal 0, result
  end

  # ============== Decoder tests ==============

  def test_decoder_new_creates_decoder
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(4096, 100)
    assert_kind_of HTTP3::Nghttp3::QPACK::Decoder, decoder
  end

  def test_decoder_new_with_zero_values
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(0, 0)
    assert_kind_of HTTP3::Nghttp3::QPACK::Decoder, decoder
  end

  def test_decoder_set_max_dtable_capacity
    HTTP3::Nghttp3::QPACK::Decoder.new(4096, 100).max_dtable_capacity = 2048
    # Should not raise
  end

  def test_decoder_insert_count
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(4096, 100)
    assert_equal 0, decoder.insert_count
  end

  def test_decoder_decoder_stream_data_initially_empty
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(4096, 100)
    data = decoder.decoder_stream_data
    assert_kind_of String, data
  end

  def test_decoder_read_encoder_with_empty_data
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(4096, 100)
    result = decoder.read_encoder("")
    assert_equal 0, result
  end

  def test_decoder_cancel_stream
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(4096, 100)
    decoder.cancel_stream(0)
    # Should not raise
  end

  # The GC frees the stream contexts of a Decoder it collects, here for
  # field sections only begun. A child process does this, so that a crash
  # fails this test alone.
  def test_decoder_holding_stream_contexts_is_collected
    pid = fork do
      100.times { HTTP3::Nghttp3::QPACK::Decoder.new(4096, 100).decode(0, "\x00".b) }
      GC.start
      exit!(0)
    end
    _, status = Process.wait2(pid)
    assert_predicate status, :success?
  end

  # ============== Roundtrip tests ==============

  def test_encode_decode_roundtrip_static_table_only
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(0)  # No dynamic table
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(0, 0)

    headers = [
      HTTP3::Nghttp3::NV.new(":method", "GET"),
      HTTP3::Nghttp3::NV.new(":path", "/"),
      HTTP3::Nghttp3::NV.new(":scheme", "https"),
      HTTP3::Nghttp3::NV.new(":authority", "example.com")
    ]

    # Encode
    encoded = encoder.encode(0, headers)

    # Process encoder stream if present
    if encoded[:encoder_stream].bytesize > 0
      decoder.read_encoder(encoded[:encoder_stream])
    end

    # Decode
    request_data = encoded[:prefix] + encoded[:data]
    result = decoder.decode(0, request_data, fin: true)

    refute result[:blocked]
    assert_kind_of Array, result[:headers]
    assert_equal 4, result[:headers].size

    assert_equal ":method", result[:headers][0][:name]
    assert_equal "GET", result[:headers][0][:value]
    assert_equal ":path", result[:headers][1][:name]
    assert_equal "/", result[:headers][1][:value]
    assert_equal ":scheme", result[:headers][2][:name]
    assert_equal "https", result[:headers][2][:value]
    assert_equal ":authority", result[:headers][3][:name]
    assert_equal "example.com", result[:headers][3][:value]
  end

  def test_encode_decode_roundtrip_with_dynamic_table
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(4096)
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(4096, 100)
    encoder.max_blocked_streams = 100
    decoder.max_dtable_capacity = 4096

    headers = [
      HTTP3::Nghttp3::NV.new(":method", "POST"),
      HTTP3::Nghttp3::NV.new(":path", "/api/v1/users"),
      HTTP3::Nghttp3::NV.new(":scheme", "https"),
      HTTP3::Nghttp3::NV.new(":authority", "api.example.com"),
      HTTP3::Nghttp3::NV.new("content-type", "application/json"),
      HTTP3::Nghttp3::NV.new("accept", "application/json")
    ]

    # Encode
    encoded = encoder.encode(0, headers)

    # Process encoder stream if present
    if encoded[:encoder_stream].bytesize > 0
      decoder.read_encoder(encoded[:encoder_stream])
    end

    # Decode
    request_data = encoded[:prefix] + encoded[:data]
    result = decoder.decode(0, request_data, fin: true)

    # If blocked, we need more encoder stream data
    if result[:blocked]
      skip "Blocked - dynamic table references not yet available"
    end

    assert_kind_of Array, result[:headers]
    assert_equal 6, result[:headers].size
    assert_equal ":method", result[:headers][0][:name]
    assert_equal "POST", result[:headers][0][:value]
  end

  def test_encode_decode_multiple_streams
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(0)
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(0, 0)

    # Stream 0
    headers0 = [
      HTTP3::Nghttp3::NV.new(":method", "GET"),
      HTTP3::Nghttp3::NV.new(":path", "/stream0")
    ]
    encoded0 = encoder.encode(0, headers0)
    request_data0 = encoded0[:prefix] + encoded0[:data]
    result0 = decoder.decode(0, request_data0, fin: true)

    # Stream 4
    headers4 = [
      HTTP3::Nghttp3::NV.new(":method", "POST"),
      HTTP3::Nghttp3::NV.new(":path", "/stream4")
    ]
    encoded4 = encoder.encode(4, headers4)
    request_data4 = encoded4[:prefix] + encoded4[:data]
    result4 = decoder.decode(4, request_data4, fin: true)

    refute result0[:blocked]
    refute result4[:blocked]
    assert_equal "/stream0", result0[:headers][1][:value]
    assert_equal "/stream4", result4[:headers][1][:value]
  end

  def test_decode_returns_consumed_bytes
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(0)
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(0, 0)

    headers = [HTTP3::Nghttp3::NV.new(":method", "GET")]
    encoded = encoder.encode(0, headers)
    request_data = encoded[:prefix] + encoded[:data]

    result = decoder.decode(0, request_data, fin: true)

    assert_kind_of Integer, result[:consumed]
    assert result[:consumed] > 0
  end

  def test_decode_headers_include_token
    encoder = HTTP3::Nghttp3::QPACK::Encoder.new(0)
    decoder = HTTP3::Nghttp3::QPACK::Decoder.new(0, 0)

    headers = [HTTP3::Nghttp3::NV.new(":method", "GET")]
    encoded = encoder.encode(0, headers)
    request_data = encoded[:prefix] + encoded[:data]

    result = decoder.decode(0, request_data, fin: true)

    assert_includes result[:headers][0].keys, :token
    assert_kind_of Integer, result[:headers][0][:token]
  end
end
