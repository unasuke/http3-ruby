# frozen_string_literal: true

# A manual check that requests held open cannot make HTTP3::Server use up
# its memory or its disk. Every connection opens requests and sends their
# bodies without FIN, so that the server has to hold them; with its default
# limits it holds no more than max_connection_request_buffer (4 MiB) per
# connection and max_total_request_buffer (64 MiB) in all in memory, and
# writes a body over request_body_buffer_size (64 KiB) to a temporary file,
# of which it holds no more than 16 MiB and 16 files per connection and
# max_total_request_spool (1 GiB) and max_total_request_spool_files (256)
# in all. It answers the rest with 503.
#
#   bundle exec ruby test/interop/hold_requests.rb [--connections 20] \
#     [--streams 100] [--bytes 1_000_000] [--timeout 120] \
#     [--request-timeout SECONDS]
#
# Starts server.rb on a temporary directory and certificate, and prints the
# server's resident set size before and after, and the temporary files it
# holds. Exits non-zero unless some request got 503, the temporary files
# stay within the limits of every connection and of the server, the server
# is still running, and a GET on a new connection gets 200 afterwards, or
# when it takes more than --timeout seconds. With --request-timeout, passed
# on to server.rb, every request held open has to get 408 once that has
# passed, and no temporary file be left open, too. Needs the extension
# compiled (bundle exec rake compile) and Linux, for /proc.

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
  opts.on("--request-timeout SECONDS", Float, "The server's request_timeout (30)") do |v|
    options[:request_timeout] = v
  end
end.parse!

def rss_kib(pid)
  File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i
end

# The temporary files without a name that process pid holds in
# Dir.tmpdir, as [count, bytes] (Linux).
def spool_files(pid)
  sizes = Dir.children("/proc/#{pid}/fd").filter_map do |fd|
    path = "/proc/#{pid}/fd/#{fd}"
    target = File.readlink(path)
    File.stat(path).size if target.start_with?(Dir.tmpdir) && target.end_with?(" (deleted)")
  rescue Errno::ENOENT
    nil
  end
  [sizes.size, sizes.sum]
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
  timeout_args = options[:request_timeout] ? ["--request-timeout", options[:request_timeout].to_s] : []
  pid = Process.spawn(
    RbConfig.ruby, File.join(__dir__, "server.rb"), "--root", root, "--bind", "127.0.0.1:#{port}",
    "--certificate", credentials.certificate_path, "--private-key", credentials.private_key_path, *timeout_args
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
      # Pump until no answer has come for a second, once some have: a 503
      # for every request that did not fit, none for those held open. The
      # first 503s come only once a connection has filled its limits, which
      # with bodies going to temporary files takes the server seconds.
      answered = nil
      loop do
        quiet_until = now + 1
        clients.each(&:pump) while now < quiet_until
        count = ids.sum { |client, list| list.count { |id| client.response(id).status } }
        break if count == answered && count.positive?

        answered = count
      end
      statuses = ids.flat_map { |client, list| list.map { |id| client.response(id).status } }.tally
      puts "answers: #{statuses.map { |status, n| "#{status || "none (held open)"} x #{n}" }.join(", ")}"
      puts "server RSS after: #{rss_kib(pid)} KiB"
      files, bytes = spool_files(pid)
      puts "server temporary files: #{files}, #{bytes / 1024} KiB"

      check.call("some requests got 503", statuses.key?(503))
      # Every connection holds no more than 16 files and 16 MiB in them
      # (max_connection_request_spool_files, max_connection_request_spool),
      # and the server no more than 256 files and 1 GiB.
      connections = options[:connections]
      check.call("the temporary files stay within the limits",
        files <= [16 * connections, 256].min && bytes <= [16 * 1_024 * 1_024 * connections, 1_073_741_824].min,
        "#{files} files, #{bytes} bytes")
      check.call("the server is running", alive?(pid))
      if options[:request_timeout]
        # Those not refused at once: still held, or already past the time.
        held = ids.to_h { |client, list| [client, list.reject { |id| client.response(id).status == 503 }] }
        wait_until = now + options[:request_timeout] + 10
        until held.all? { |client, list| list.all? { |id| client.response(id).status } } || now > wait_until
          clients.each(&:pump)
        end
        timed_out = held.sum { |client, list| list.count { |id| client.response(id).status == 408 } }
        count = held.sum { |_, list| list.size }
        check.call("the requests held open got 408", count.positive? && timed_out == count, "#{timed_out} of #{count}")
        files, bytes = spool_files(pid)
        check.call("no temporary file is left open", files.zero?, "#{files} files, #{bytes} bytes")
      end
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
