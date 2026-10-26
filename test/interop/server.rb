# frozen_string_literal: true

# An HTTP/3 server for interoperability checks: serves a directory with
# Rack::Files. See README.md for the checks that use it.
#
#   bundle exec ruby test/interop/server.rb --root DIR --bind 127.0.0.1:4433 \
#     --certificate cert.pem --private-key key.pem [--qlog-dir DIR] \
#     [--request-timeout SECONDS]

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "http3"
require "logger"
require "optparse"
require "rack"
require "rack/files"

options = {bind: "127.0.0.1:4433"}
OptionParser.new do |opts|
  opts.on("--root DIR", "Directory to serve") { |v| options[:root] = v }
  opts.on("--bind HOST:PORT", "Address to serve (not 0.0.0.0)") { |v| options[:bind] = v }
  opts.on("--certificate PATH", "PEM certificate chain") { |v| options[:certificate] = v }
  opts.on("--private-key PATH", "PEM private key") { |v| options[:private_key] = v }
  opts.on("--qlog-dir DIR", "Write one qlog file per connection") { |v| options[:qlog_dir] = v }
  opts.on("--request-timeout SECONDS", Float, "Answer 408 after this long (30)") { |v| options[:request_timeout] = v }
end.parse!
missing = %i[root certificate private_key].reject { |key| options[key] }
abort "missing: #{missing.map { |key| "--#{key.to_s.tr("_", "-")}" }.join(", ")}" unless missing.empty?

server = HTTP3::Server.new(
  app: Rack::Files.new(options[:root]),
  bind: options[:bind],
  certificate_path: options[:certificate],
  private_key_path: options[:private_key],
  qlog_dir: options[:qlog_dir],
  logger: Logger.new($stderr),
  **options.slice(:request_timeout)
)
Thread.new do
  sleep 0.01 until server.local_address
  warn "serving #{options[:root]} on #{server.local_address.inspect_sockaddr}"
end
server.run
