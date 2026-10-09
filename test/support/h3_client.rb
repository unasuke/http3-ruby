# frozen_string_literal: true

# H3TestClient: an HTTP/3 client on HTTP3::Nghttp3's bindings, the peer of
# the round-trip tests. It ships only with the tests, never in the gem.
require_relative "h3_client/headers"
require_relative "h3_client/request"
require_relative "h3_client/response"
require_relative "h3_client/stream_manager"
require_relative "h3_client/client"
require_relative "h3_client/quic_transport"
