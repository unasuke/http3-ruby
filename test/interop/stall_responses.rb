# frozen_string_literal: true

# A manual check that responses clients do not read cannot make
# HTTP3::Server use up its memory. Every connection asks for big each
# bodies and reads none of them. A worker writes an each body as the
# connection takes it, so the first three bodies keep the three workers
# (threads) waiting, with no more than send_buffer_size of each queued,
# and the other requests wait for a worker. A /small on another connection
# waits too, until the connections not reading have gone. (The workers
# wait with no time limit; the README says so.)
#
#   bundle exec ruby test/interop/stall_responses.rb [--connections 100] \
#     [--streams 100] [--timeout 120]
#
# Starts an HTTP3::Server in a child process, with /big (10 MiB, 16 KiB at
# a time) and /small, and prints the server's resident set size before and
# while the workers wait. Exits non-zero unless the server is still
# running, a /small on a new connection gets no answer within 2 seconds
# while the workers wait, and all of it once the connections not reading
# have closed; or when a connection fails or it takes more than --timeout
# seconds. Needs the extension compiled (bundle exec rake compile) and
# Linux, for /proc.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "http3"
require "logger"
require "optparse"
require "socket"
require "timeout"
require "tmpdir"
require_relative "../support/h3_client"
require_relative "../support/test_certificates"

options = {connections: 100, streams: 100, timeout: 120}
OptionParser.new do |opts|
  opts.on("--connections N", Integer, "Connections not reading (100)") { |v| options[:connections] = v }
  opts.on("--streams N", Integer, "Responses not read per connection (100)") { |v| options[:streams] = v }
  opts.on("--timeout SECONDS", Float, "Give up after this long (120)") { |v| options[:timeout] = v }
end.parse!

CHUNK = ("x" * 16_384).freeze
BIG = 10 * 1_024 * 1_024

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

def pump_for(clients, seconds)
  deadline = now + seconds
  clients.each(&:pump) while now < deadline
end

failures = []
check = lambda do |name, ok, detail = nil|
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{" (#{detail})" if detail}"
  failures << name unless ok
end

app = lambda do |env|
  if env["PATH_INFO"] == "/big"
    [200, {}, Enumerator.new { |y| (BIG / CHUNK.bytesize).times { y << CHUNK } }]
  else
    [200, {}, Enumerator.new { |y| y << "small" }]
  end
end

Dir.mktmpdir("http3-stall-") do |work|
  credentials = TestCertificates.generate_credentials(dir: work)
  port = free_port
  pid = fork do
    HTTP3::Server.new(
      app: app, bind: "127.0.0.1:#{port}", logger: Logger.new(File.join(work, "server.log")),
      certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path
    ).run
    exit!(0)
  rescue Exception => e # rubocop:disable Lint/RescueException
    warn e.full_message
    exit!(1)
  end
  stalled = []
  others = []
  begin
    Timeout.timeout(options[:timeout]) do
      stalled << connect(port, credentials.ca_file)
      puts "server RSS before: #{rss_kib(pid)} KiB"

      options[:connections].times do |i|
        client = (i == 0) ? stalled.first : connect(port, credentials.ca_file).tap { |c| stalled << c }
        # Not waiting for the status: a few streams use up the client's
        # window for the whole connection.
        options[:streams].times { client.pause(client.request(:get, "/big")) }
        client.pump
      end

      # For the workers to take the first bodies and stop.
      pump_for(stalled, 1)
      small = connect(port, credentials.ca_file).tap { |c| others << c }
      id = small.request(:get, "/small")
      pump_for([small, *stalled], 2)
      puts "server RSS while the workers wait: #{rss_kib(pid)} KiB"

      check.call("the server is running", alive?(pid))
      check.call("/small waits for a worker", small.response(id).nil? || small.response(id).status.nil?)
      stalled.each(&:close)
      # Within request_timeout (30 seconds) of the request, or it gets 503.
      small.pump_until(timeout: 20) { small.response(id)&.finished? }
      check.call("/small ends once those connections have closed", small.response(id).body == "small",
        small.response(id).status)
    end
  rescue Timeout::Error
    check.call("finished within #{options[:timeout]} seconds", false)
  rescue QUIC::Error => e
    # A server too busy queuing bodies to answer lets connections time out.
    puts "server RSS: #{rss_kib(pid)} KiB" if alive?(pid)
    check.call("the connections stayed up", false, "#{e.class}: #{e.message}")
  ensure
    (stalled + others).each(&:close)
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
