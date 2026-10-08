# frozen_string_literal: true

require_relative "http3/version"
require_relative "http3/http3"

# Helpers on top of the nghttp3 bindings
require_relative "http3/nghttp3/headers"
require_relative "http3/nghttp3/request"
require_relative "http3/nghttp3/response"
require_relative "http3/nghttp3/stream_manager"
require_relative "http3/nghttp3/client"
require_relative "http3/nghttp3/server"

require_relative "http3/request"
require_relative "http3/response"
require_relative "http3/session"
require_relative "http3/rack_adapter"
require_relative "http3/server"

module HTTP3
  module Nghttp3
    class Error < StandardError; end
  end
end
