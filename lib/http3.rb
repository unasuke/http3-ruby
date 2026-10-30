# frozen_string_literal: true

require_relative "http3/version"
require_relative "http3/http3"

require_relative "http3/request"
require_relative "http3/response"
require_relative "http3/body_pipe"
require_relative "http3/session"
require_relative "http3/rack_adapter"
require_relative "http3/server"

module HTTP3
  module Nghttp3
    class Error < StandardError; end
  end
end
