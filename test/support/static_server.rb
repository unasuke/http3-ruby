# frozen_string_literal: true

# The server test_server_static.rb talks to, run as a process of its own
# (not forked from the tests) so that its memory does not depend on what
# the test process did before.
#
#   ruby test/support/static_server.rb ROOT CERTIFICATE KEY LOG
#
# Serves ROOT/static with Rack::Static, a few dynamic paths otherwise, all
# wrapped in Rack::Lint, and prints the port on stdout once it listens.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "http3"
require "logger"
require "rack"
require "rack/lint"
require "rack/static"

root, certificate_path, private_key_path, log_path = ARGV

# Yields more than the send buffer holds, then fails. The first chunk fills
# the buffer, so the response headers go out before the body is asked for
# more.
class FailingBody
  def each
    yield "x" * 100_000
    raise "the body failed"
  end

  def close
  end
end

# A body with only #each, no #to_ary.
class EachBody
  def each
    yield "one,"
    yield "two"
  end
end

dynamic = lambda do |env|
  case env["PATH_INFO"]
  when "/array" then [200, {"content-type" => "text/plain"}, ["a,", "b,", "c"]]
  when "/each" then [200, {"content-type" => "text/plain"}, EachBody.new]
  when "/raise" then raise "the app failed"
  when "/fail-midway" then [200, {"content-type" => "text/plain"}, FailingBody.new]
  else [404, {}, []]
  end
end

server = HTTP3::Server.new(
  app: Rack::Lint.new(Rack::Static.new(dynamic, urls: ["/static"], root: root)),
  bind: "127.0.0.1:0", certificate_path: certificate_path, private_key_path: private_key_path,
  logger: Logger.new(log_path), shutdown_timeout: 5
)
Thread.new do
  sleep 0.01 until server.local_address
  $stdout.puts server.local_address.ip_port
  $stdout.flush
end
server.run
