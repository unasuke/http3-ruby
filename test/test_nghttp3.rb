# frozen_string_literal: true

require "test_helper"

class TestNghttp3 < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::HTTP3::VERSION
  end

  # Compile-time constant tests
  def test_nghttp3_version_constant
    assert_kind_of String, HTTP3::Nghttp3::NGHTTP3_VERSION
    assert_match(/\A\d+\.\d+\.\d+\z/, HTTP3::Nghttp3::NGHTTP3_VERSION)
  end

  def test_nghttp3_version_num_constant
    assert_kind_of Integer, HTTP3::Nghttp3::NGHTTP3_VERSION_NUM
    assert_operator HTTP3::Nghttp3::NGHTTP3_VERSION_NUM, :>, 0
  end

  def test_nghttp3_version_age_constant
    assert_kind_of Integer, HTTP3::Nghttp3::NGHTTP3_VERSION_AGE
    assert_equal 1, HTTP3::Nghttp3::NGHTTP3_VERSION_AGE
  end

  # Runtime version tests
  def test_library_version_returns_info_object
    info = HTTP3::Nghttp3.library_version
    assert_kind_of HTTP3::Nghttp3::Info, info
  end

  def test_library_version_info_attributes
    info = HTTP3::Nghttp3.library_version

    assert_respond_to info, :age
    assert_respond_to info, :version_num
    assert_respond_to info, :version_str
  end

  def test_library_version_info_age
    info = HTTP3::Nghttp3.library_version
    assert_kind_of Integer, info.age
    assert_equal 1, info.age
  end

  def test_library_version_info_version_num
    info = HTTP3::Nghttp3.library_version
    assert_kind_of Integer, info.version_num
    assert_equal HTTP3::Nghttp3::NGHTTP3_VERSION_NUM, info.version_num
  end

  def test_library_version_info_version_str
    info = HTTP3::Nghttp3.library_version
    assert_kind_of String, info.version_str
    assert_match(/\A\d+\.\d+\.\d+\z/, info.version_str)
    assert_equal HTTP3::Nghttp3::NGHTTP3_VERSION, info.version_str
  end

  def test_library_version_with_least_version_met
    info = HTTP3::Nghttp3.library_version(0)
    refute_nil info
    assert_kind_of HTTP3::Nghttp3::Info, info
  end

  def test_library_version_with_least_version_not_met
    info = HTTP3::Nghttp3.library_version(0xFFFFFF)
    assert_nil info
  end

  def test_info_cannot_be_instantiated_directly
    assert_raises(NoMethodError) do
      HTTP3::Nghttp3::Info.new
    end
  end

  def test_error_class_exists
    assert_kind_of Class, HTTP3::Nghttp3::Error
    assert_operator HTTP3::Nghttp3::Error, :<, StandardError
  end

  # Error code constant tests
  def test_error_code_constants_exist
    assert_equal(-101, HTTP3::Nghttp3::NGHTTP3_ERR_INVALID_ARGUMENT)
    assert_equal(-102, HTTP3::Nghttp3::NGHTTP3_ERR_INVALID_STATE)
    assert_equal(-103, HTTP3::Nghttp3::NGHTTP3_ERR_WOULDBLOCK)
    assert_equal(-104, HTTP3::Nghttp3::NGHTTP3_ERR_STREAM_IN_USE)
    assert_equal(-105, HTTP3::Nghttp3::NGHTTP3_ERR_MALFORMED_HTTP_HEADER)
    assert_equal(-107, HTTP3::Nghttp3::NGHTTP3_ERR_MALFORMED_HTTP_MESSAGING)
    assert_equal(-108, HTTP3::Nghttp3::NGHTTP3_ERR_QPACK_FATAL)
    assert_equal(-109, HTTP3::Nghttp3::NGHTTP3_ERR_QPACK_HEADER_TOO_LARGE)
    assert_equal(-110, HTTP3::Nghttp3::NGHTTP3_ERR_STREAM_NOT_FOUND)
    assert_equal(-111, HTTP3::Nghttp3::NGHTTP3_ERR_CONN_CLOSING)
    assert_equal(-112, HTTP3::Nghttp3::NGHTTP3_ERR_STREAM_DATA_OVERFLOW)
    assert_equal(-900, HTTP3::Nghttp3::NGHTTP3_ERR_FATAL)
    assert_equal(-901, HTTP3::Nghttp3::NGHTTP3_ERR_NOMEM)
    assert_equal(-902, HTTP3::Nghttp3::NGHTTP3_ERR_CALLBACK_FAILURE)
  end

  # err_is_fatal? tests
  def test_err_is_fatal_returns_true_for_fatal_errors
    # Fatal errors are those with error code < NGHTTP3_ERR_FATAL (-900)
    assert HTTP3::Nghttp3.err_is_fatal?(HTTP3::Nghttp3::NGHTTP3_ERR_NOMEM)          # -901
    assert HTTP3::Nghttp3.err_is_fatal?(HTTP3::Nghttp3::NGHTTP3_ERR_CALLBACK_FAILURE) # -902
  end

  def test_err_is_fatal_returns_false_for_non_fatal_errors
    # NGHTTP3_ERR_FATAL (-900) is the threshold, not a fatal error itself
    refute HTTP3::Nghttp3.err_is_fatal?(HTTP3::Nghttp3::NGHTTP3_ERR_FATAL)
    refute HTTP3::Nghttp3.err_is_fatal?(HTTP3::Nghttp3::NGHTTP3_ERR_INVALID_ARGUMENT)
    refute HTTP3::Nghttp3.err_is_fatal?(HTTP3::Nghttp3::NGHTTP3_ERR_WOULDBLOCK)
    refute HTTP3::Nghttp3.err_is_fatal?(HTTP3::Nghttp3::NGHTTP3_ERR_STREAM_NOT_FOUND)
  end

  # strerror tests
  def test_strerror_returns_string
    str = HTTP3::Nghttp3.strerror(HTTP3::Nghttp3::NGHTTP3_ERR_INVALID_ARGUMENT)
    assert_kind_of String, str
    refute_empty str
  end

  def test_strerror_returns_different_strings_for_different_errors
    str1 = HTTP3::Nghttp3.strerror(HTTP3::Nghttp3::NGHTTP3_ERR_INVALID_ARGUMENT)
    str2 = HTTP3::Nghttp3.strerror(HTTP3::Nghttp3::NGHTTP3_ERR_NOMEM)
    refute_equal str1, str2
  end

  # Error class hierarchy tests
  def test_specific_error_classes_exist
    error_classes = [
      HTTP3::Nghttp3::InvalidArgumentError,
      HTTP3::Nghttp3::InvalidStateError,
      HTTP3::Nghttp3::WouldBlockError,
      HTTP3::Nghttp3::StreamInUseError,
      HTTP3::Nghttp3::MalformedHTTPHeaderError,
      HTTP3::Nghttp3::MalformedHTTPMessagingError,
      HTTP3::Nghttp3::QPACKFatalError,
      HTTP3::Nghttp3::QPACKHeaderTooLargeError,
      HTTP3::Nghttp3::StreamNotFoundError,
      HTTP3::Nghttp3::ConnClosingError,
      HTTP3::Nghttp3::StreamDataOverflowError,
      HTTP3::Nghttp3::FatalError,
      HTTP3::Nghttp3::NoMemError,
      HTTP3::Nghttp3::CallbackFailureError
    ]

    error_classes.each do |klass|
      assert_kind_of Class, klass
      assert_operator klass, :<, HTTP3::Nghttp3::Error
    end
  end

  def test_error_classes_can_be_raised_and_caught
    assert_raises(HTTP3::Nghttp3::InvalidArgumentError) do
      raise HTTP3::Nghttp3::InvalidArgumentError, "test"
    end

    assert_raises(HTTP3::Nghttp3::Error) do
      raise HTTP3::Nghttp3::NoMemError, "test"
    end
  end
end
