# frozen_string_literal: true

# Net::HTTP::Client over HTTP/3: a proof of concept.
#
#   require "net/http"
#   require "http3/net/http"
#   client = Net::HTTP.client("https://example.com", protocols: [:http3])
#   client.get("/")
#
# Net::HTTP::Client, the new client of net-http this plugs into, is so far
# only on the http2 branch of github.com/nurse/net-http, which has to be in
# the Gemfile:
#
#   gem "net-http", github: "nurse/net-http", branch: "http2"
#
# That client has no way to add a protocol, so this prepends to its
# internals, as they are at 8ac46b0 of that branch: Client#initialize,
# Client#validate_options and ConnectionFactory.open. require raises
# LoadError when they are not there.
#
# Limits:
#
# - HTTP/3 is used only when asked for alone, with protocols: [:http3]:
#   there is no discovery (Alt-Svc, HTTPS records), and no racing against
#   or falling back to HTTP/2 or HTTP/1.1. :http3 with other protocols is
#   an ArgumentError.
# - https URLs only.
# - No proxy: one that proxy: settles on (:ENV, by default, takes it from
#   the environment) is a Net::HTTP::Client::ProtocolError.
# - TLS settings: ca_file, ca_path and verify_mode only. Of verify_mode,
#   OpenSSL::SSL::VERIFY_NONE alone has an effect, turning verification
#   off; any other value leaves it on, as by default.
# - A QUIC::Error comes out as it is, and is not retried.
# - It has not been tried under a Fiber scheduler.
#
# Known defects, kept from the prototype and marked in ClientSession:
#
# 1. The streams of finished requests are never closed in nghttp3 nor
#    dropped, so a connection slows down with every request it carries.
# 2. A response given up on (its block left before the body is read, or a
#    timeout) gets RESET_STREAM but no STOP_SENDING, and what has arrived
#    for it is left unread: the server keeps sending into flow-control
#    credit that never comes back, and a few of them stall the connection.
# 3. An error nghttp3 reports, such as for a malformed response, raises
#    HTTP3::Nghttp3::Error and leaves the connection open, so the pool
#    keeps lending a connection on which every request then fails.
# 4. The request body is read under the connection's lock, so a slow body
#    holds up every other request and the timers of its connection.
# 5. nghttp3's requests to reset a stream or to stop reading one are not
#    acted on: on_reset_stream, taking the request for the peer's reset,
#    fails the request on that stream with a
#    Net::HTTP::Client::ProtocolError but sends nothing, and on_stop_sending
#    is not set.
# 6. A QUIC::Error is not mapped onto the errors Net::HTTP::Client retries
#    or reports (a certificate that fails verification is
#    QUIC::Error::CertificateVerifyFailed), and TLS settings HTTP/3 cannot
#    take are refused only on connecting.
# 7. Any QUIC::Error from opening a stream, not only the peer's stream
#    limit, is waited out until write_timeout.

require "net/http"
require "http3"

module HTTP3
  # Net::HTTP::Client over HTTP/3; see the top of http3/net/http.rb.
  module NetHTTP
    # The private constants of Net::HTTP::Client the adapter uses.
    INTERNALS = %i[ResponseMethods ResponseBody Clock Wait ConnectionFactory].freeze
    # The parameters of ConnectionFactory.open the adapter prepends to.
    OPEN_PARAMETERS = [[:req, :request], [:req, :options], [:req, :operation], [:req, :proxy], [:key, :http]].freeze

    # For the adapter's own use. Check that klass, Net::HTTP::Client, has
    # what the adapter plugs into, and return INTERNALS by name. Raises
    # LoadError naming what is missing.
    def self.check_client(klass)
      missing = INTERNALS.reject { |name| klass.const_defined?(name, false) }
      internals = (INTERNALS - missing).to_h { |name| [name, klass.const_get(name, false)] }
      factory = internals[:ConnectionFactory]
      if factory && !(factory.respond_to?(:open) && factory.method(:open).parameters == OPEN_PARAMETERS)
        missing << :"ConnectionFactory.open"
      end
      missing << :validate_options unless klass.private_method_defined?(:validate_options)
      raise LoadError, load_error_message(missing) unless missing.empty?

      internals
    end

    def self.load_error_message(missing)
      "http3/net/http needs Net::HTTP::Client from net-http's http2 branch " \
        "(github.com/nurse/net-http) (missing: #{missing.join(", ")})"
    end
    private_class_method :load_error_message

    # For the adapter's own use. The protocols to let net-http check:
    # :http3 as :http1, which it takes.
    def self.stand_in(protocols)
      protocols.map { |protocol| (protocol == :http3) ? :http1 : protocol }
    end

    # For the adapter's own use.
    def self.check_alone(protocols)
      raise ArgumentError, ":http3 cannot be combined with other protocols" unless protocols == [:http3]
    end

    raise LoadError, load_error_message(["Net::HTTP::Client"]) unless ::Net::HTTP.const_defined?(:Client)

    check_client(::Net::HTTP::Client).each do |name, value|
      const_set(name, value)
      private_constant name
    end

    require_relative "http/client_session"

    # Prepended to Net::HTTP::Client. Client.new and the check of each
    # request take :http1 and :http2 alone, so they check :http3 as :http1
    # first, with everything else, and then that :http3 comes alone.
    module ClientOptions
      def initialize(base_url = nil, **options)
        protocols = Array(options[:protocols])
        if protocols.include?(:http3)
          super(base_url, **options.merge(protocols: NetHTTP.stand_in(protocols)))
          NetHTTP.check_alone(protocols)
          @options = @options.merge(protocols: [:http3].freeze).freeze
        else
          super
        end
      end

      private

      def validate_options(options)
        protocols = options[:protocols]
        return super unless protocols.is_a?(Array) && protocols.include?(:http3)

        super(options.merge(protocols: NetHTTP.stand_in(protocols)))
        NetHTTP.check_alone(protocols)
      end
    end

    # Prepended to ConnectionFactory's singleton class: protocols: [:http3]
    # connects over QUIC, with a ClientSession, instead of over TCP.
    module Connector
      def open(request, options, operation, proxy, http: nil)
        return super unless options[:protocols] == [:http3]

        begin
          uri = request.uri
          raise ::Net::HTTP::Client::ProtocolError, "HTTP/3 requires HTTPS" unless uri.scheme == "https"
          raise ::Net::HTTP::Client::ProtocolError, "HTTP/3 cannot be carried by an HTTP proxy" if proxy

          ClientSession.new(uri, options, operation)
        rescue Exception # rubocop:disable Lint/RescueException
          # As ConnectionFactory.open does: a cancelled or timed-out request
          # fails with that rather than with what it broke.
          operation.check!
          raise
        end
      end
    end

    ::Net::HTTP::Client.prepend(ClientOptions)
    ConnectionFactory.singleton_class.prepend(Connector)
  end
end
