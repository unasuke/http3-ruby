# frozen_string_literal: true

# A manual check that requests held open cannot make HTTP3::Server use up
# its memory. Every connection opens requests and sends their bodies
# without FIN, so that the server has to hold them; with its default limits
# it holds no more than max_connection_request_buffer (4 MiB) per
# connection and max_total_request_buffer (64 MiB) in all, and answers the
# rest with 503.
#
#   bundle exec ruby test/interop/hold_requests.rb [--connections 20] \
#     [--streams 100] [--bytes 1_000_000] [--timeout 120]
#
# Starts server.rb on a temporary directory and certificate, and prints the
# server's resident set size before and after. Exits non-zero unless some
# request got 503, the server is still running, and a GET on a new
# connection gets 200 afterwards, or when it takes more than --timeout
# seconds. Needs the extension compiled (bundle exec rake compile) and
# Linux, for /proc.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "http3"
require "optparse"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"
require_relative "../support/h3_client"
require_relative "../support/test_certificates"

options = {connections: 20, streams: 100, bytes: 1_000_000, timeout: 120}
OptionParser.new do |opts|
  opts.on("--connections N", Integer, "Connections to open (20)") { |v| options[:connections] = v }
  opts.on("--streams N", Integer, "Requests to hold open per connection (100)") { |v| options[:streams] = v }
  opts.on("--bytes N", Integer, "Bytes of body per request (1_000_000)") { |v| options[:bytes] = v }
  opts.on("--timeout SECONDS", Float, "Give up after this long (120)") { |v| options[:timeout] = v }
end.parse!

def rss_kib(pid)
  File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i
end

def alive?(pid)
  Process.wait(pid, Process::WNOHANG).nil?
rescue Errno::ECHILD
  false
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# The server binds the port only once it has started; retry until then.
def connect(port, ca_file, timeout: 10)
  deadline = now + timeout
  begin
    H3TestClient::QuicTransport.connect(port, ca_file: ca_file)
  rescue Errno::ECONNREFUSED, QUIC::Error
    raise if now > deadline

    sleep 0.1
    retry
  end
end

# A port nothing listens on now, for the server to bind.
def free_port
  sock = UDPSocket.new(Socket::AF_INET)
  sock.bind("127.0.0.1", 0)
  sock.addr[1]
ensure
  sock&.close
end

failures = []
check = lambda do |name, ok, detail = nil|
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{" (#{detail})" if detail}"
  failures << name unless ok
end

Dir.mktmpdir("http3-hold-") do |work|
  root = File.join(work, "www")
  Dir.mkdir(root)
  File.write(File.join(root, "index.html"), "hello from http3-ruby\n")
  credentials = TestCertificates.generate_credentials(dir: work)
  port = free_port
  pid = Process.spawn(
    RbConfig.ruby, File.join(__dir__, "server.rb"), "--root", root, "--bind", "127.0.0.1:#{port}",
    "--certificate", credentials.certificate_path, "--private-key", credentials.private_key_path
  )
  clients = []
  begin
    Timeout.timeout(options[:timeout]) do
      clients << connect(port, credentials.ca_file)
      puts "server RSS before: #{rss_kib(pid)} KiB"

      # One String for every body: the client needs no copy of each.
      body = ("x" * options[:bytes]).freeze
      ids = {}
      options[:connections].times do |i|
        client = (i == 0) ? clients.first : connect(port, credentials.ca_file).tap { |c| clients << c }
        ids[client] = Array.new(options[:streams]) { client.request(:post, "/", body: body, fin: false) }
        client.pump
      end
      # Pump until no answer has come for a second: a 503 for every
      # request that did not fit, none for those held open.
      answered = nil
      loop do
        quiet_until = now + 1
        clients.each(&:pump) while now < quiet_until
        count = ids.sum { |client, list| list.count { |id| client.response(id).status } }
        break if count == answered

        answered = count
      end
      statuses = ids.flat_map { |client, list| list.map { |id| client.response(id).status } }.tally
      puts "answers: #{statuses.map { |status, n| "#{status || "none (held open)"} x #{n}" }.join(", ")}"
      puts "server RSS after: #{rss_kib(pid)} KiB"

      check.call("some requests got 503", statuses.key?(503))
      check.call("the server is running", alive?(pid))
      client = connect(port, credentials.ca_file).tap { |c| clients << c }
      id = client.request(:get, "/index.html")
      client.pump_until(timeout: 10) { client.response(id).finished? }
      check.call("GET on a new connection", client.response(id).status == 200, client.response(id).status)
    end
  rescue Timeout::Error
    check.call("finished within #{options[:timeout]} seconds", false)
  ensure
    clients.each(&:close)
    begin
      Process.kill("TERM", pid)
      Timeout.timeout(10) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end

exit(failures.empty? ? 0 : 1)
