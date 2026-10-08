# frozen_string_literal: true

require "mkmf"

# Makes all symbols private by default to avoid unintended conflict
# with other gems. To explicitly export symbols you can use RUBY_FUNC_EXPORTED
# selectively, or entirely remove this flag.
append_cflags("-fvisibility=hidden")

unless have_library("nghttp3", "nghttp3_version")
  abort "nghttp3 library not found"
end

unless have_header("nghttp3/nghttp3.h")
  abort "nghttp3/nghttp3.h not found"
end

create_makefile("http3/http3")
