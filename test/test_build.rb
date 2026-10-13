# frozen_string_literal: true

require "test_helper"

# How the extension is built: nghttp3 is vendored at the version extconf.rb
# pins and linked statically, without exposing its symbols.
class TestBuild < Minitest::Test
  EXTCONF = File.expand_path("../ext/http3/extconf.rb", __dir__)

  def test_links_the_pinned_nghttp3
    pinned = File.read(EXTCONF)[/^NGHTTP3_VERSION = "(.+)"$/, 1]
    refute_nil pinned
    assert_equal pinned, HTTP3::Nghttp3.library_version.version_str
  end

  # -fvisibility=hidden hides the extension's own functions and
  # -Wl,--exclude-libs,ALL those of the static nghttp3, so that they cannot
  # collide with another nghttp3 in the same process.
  def test_exports_only_init_http3
    skip "checked with GNU nm on Linux only" unless RUBY_PLATFORM.include?("linux")
    so = $LOADED_FEATURES.find { |path| path.end_with?("/http3/http3.so") }
    begin
      output = IO.popen(["nm", "-D", "--defined-only", so], err: File::NULL, &:read)
    rescue Errno::ENOENT
      skip "nm is not installed"
    end
    symbols = output.lines.map { |line| line.split.last }
    assert_equal %w[Init_http3], symbols
  end
end
