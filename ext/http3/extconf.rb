# frozen_string_literal: true

require "mkmf"
require "mini_portile2"

# nghttp3 is downloaded and built at install time and linked statically, so
# installing needs no system package and always gets this version.
# nghttp3_conn_read_stream2 needs 1.12.0 or later. nghttp3 depends on nothing
# but libc, so its version does not have to follow the quic gem's ngtcp2.
NGHTTP3_VERSION = "1.13.1"
NGHTTP3_SHA256 = "07160f28af3ddc3e8b95c8bbefe08c650e7cf303375141b6ca35cc89b319f70d"

nghttp3 = MiniPortile.new("nghttp3", NGHTTP3_VERSION)
nghttp3.files = [{
  url: "https://github.com/ngtcp2/nghttp3/releases/download/v#{NGHTTP3_VERSION}/nghttp3-#{NGHTTP3_VERSION}.tar.gz",
  sha256: NGHTTP3_SHA256
}]
# The release tarball ships configure, so no autotools are needed.
nghttp3.configure_options = [
  "--enable-lib-only",
  "--disable-shared",
  "--with-pic"
]
nghttp3.cook

nghttp3.mkmf_config(static: "nghttp3")
# Without it, nghttp3.h declares the functions for a shared library.
append_cflags("-DNGHTTP3_STATICLIB")

abort "nghttp3/nghttp3.h not found" unless have_header("nghttp3/nghttp3.h")
abort "libnghttp3 not linkable" unless have_func("nghttp3_version", "nghttp3/nghttp3.h")

# The quic gem's C function table, through which HTTP3::Session drives a
# QUIC connection. The header ships in the quic gem; the table itself is
# looked up at load time with rb_ext_resolve_symbol (Ruby 3.3 or later).
require "quic/ext_include"
append_cppflags("-I#{QUIC::EXT_INCLUDE_DIR}")
abort "quic/ext.h not found (the quic gem 0.0.3 or later provides it)" unless have_header("quic/ext.h")
abort "rb_ext_resolve_symbol not found (Ruby 3.3 or later is required)" unless
  have_func("rb_ext_resolve_symbol", "ruby.h")

# Makes all symbols private by default to avoid unintended conflict
# with other gems. To explicitly export symbols you can use RUBY_FUNC_EXPORTED
# selectively, or entirely remove this flag.
append_cflags("-fvisibility=hidden")
append_ldflags("-Wl,--exclude-libs,ALL") # Unexport symbols from the static nghttp3

create_makefile("http3/http3")
