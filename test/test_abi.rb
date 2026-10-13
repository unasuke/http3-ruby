# frozen_string_literal: true

require "test_helper"

# Loading http3 looks the quic gem's C function table up by its ABI major
# version. HTTP3::Testing.load_quic_api repeats that lookup for any major.
class TestABI < Minitest::Test
  def test_loads_the_table_it_was_built_against
    assert HTTP3::Testing.load_quic_api(1)
  end

  def test_raises_load_error_for_another_major_version
    error = assert_raises(LoadError) { HTTP3::Testing.load_quic_api(2) }
    assert_match(/ABI major version 2/, error.message)
    assert_includes error.message, "quic #{QUIC::VERSION}"
  end
end
