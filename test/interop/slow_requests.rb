# frozen_string_literal: true

# A manual check that requests keeping the workers busy do not hold up the
# thread that drives the connections. HTTP3::Server runs in a child process
# with threads: 3. One connection keeps a /cpu (2 seconds of busy loop,
# which holds Ruby's GVL) and a /sleep (5 seconds) under way all the
# while, which take two of the workers; on the third, another connection
# asks for /small again and again, and new connections are set up in
# between. All of the workers are not taken, or /small would wait for one
# and the check measure the queue, not the GVL.
#
#   bundle exec ruby test/interop/slow_requests.rb [--duration 10] \
#     [--max-latency 0.25] [--priority N] [--timeout 120]
#
# Prints the median and the largest of the /small round trips and of the
# handshakes. Exits non-zero when the largest of either is over
# --max-latency seconds, when a request does not get 200, or when it takes
# more than --timeout seconds. --priority sets
# HTTP3::WorkerPool::WORKER_PRIORITY in the server (-3; 0 is the priority
# the other threads have), to compare. Needs the extension compiled
# (bundle exec rake compile).

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "http3"
require "logger"
require "optparse"
require "socket"
require "timeout"
require "tmpdir"
require_relative "../support/h3_client"
require_relative "../support/test_certificates"

options = {duration: 10, max_latency: 0.25, priority: nil, timeout: 120}
OptionParser.new do |opts|
  opts.on("--duration SECONDS", Float, "Measure for this long (10)") { |v| options[:duration] = v }
  opts.on("--max-latency SECONDS", Float, "Fail when a round trip takes longer (0.25)") { |v| options[:max_latency] = v }
  opts.on("--priority N", Integer, "The workers' priority (-3)") { |v| options[:priority] = v }
  opts.on("--timeout SECONDS", Float, "Give up after this long (120)") { |v| options[:timeout] = v }
end.parse!

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

def summary(seconds)
  sorted = seconds.sort
  format("%d, median %.4f s, largest %.4f s", sorted.size, sorted[sorted.size / 2], sorted.last)
end

failures = []
check = lambda do |name, ok, detail = nil|
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{" (#{detail})" if detail}"
  failures << name unless ok
end

app = lambda do |env|
  case env["PATH_INFO"]
  when "/cpu"
    deadline = now + 2
    nil while now < deadline
    [200, {}, ["cpu"]]
  when "/sleep"
    sleep 5
    [200, {}, ["sleep"]]
  else [200, {}, ["small"]]
  end
end

Dir.mktmpdir("http3-slow-") do |work|
  credentials = TestCertificates.generate_credentials(dir: work)
  port = free_port
  pid = fork do
    if options[:priority]
      HTTP3::WorkerPool.send(:remove_const, :WORKER_PRIORITY)
      HTTP3::WorkerPool.const_set(:WORKER_PRIORITY, options[:priority])
    end
    HTTP3::Server.new(
      app: app, bind: "127.0.0.1:#{port}", logger: Logger.new(File.join(work, "server.log")), threads: 3,
      certificate_path: credentials.certificate_path, private_key_path: credentials.private_key_path
    ).run
    exit!(0)
  rescue Exception => e # rubocop:disable Lint/RescueException
    warn e.full_message
    exit!(1)
  end
  clients = []
  begin
    Timeout.timeout(options[:timeout]) do
      busy = connect(port, credentials.ca_file).tap { |c| clients << c }
      probe = connect(port, credentials.ca_file).tap { |c| clients << c }
      puts "worker priority: #{options[:priority] || HTTP3::WorkerPool::WORKER_PRIORITY}"
      # path => the stream of the one under way
      under_way = %w[/cpu /sleep].to_h { |path| [path, busy.request(:get, path)] }
      busy_done = 0
      statuses = []
      # Until /cpu and /sleep have reached their workers.
      pump_for([busy], 0.5)

      smalls = []
      handshakes = []
      deadline = now + options[:duration]
      while now < deadline
        busy.pump
        under_way.each do |path, id|
          next unless busy.response(id).finished?

          statuses << busy.response(id).status
          busy_done += 1
          under_way[path] = busy.request(:get, path)
        end

        started = now
        id = probe.request(:get, "/small")
        probe.pump_until(timeout: 10) { probe.response(id).finished? }
        smalls << now - started
        statuses << probe.response(id).status

        started = now
        connect(port, credentials.ca_file).close
        handshakes << now - started
      end

      puts "/small: #{summary(smalls)}"
      puts "handshakes: #{summary(handshakes)}"
      puts "/cpu and /sleep done meanwhile: #{busy_done}"
      check.call("every response is 200", statuses.all?(200), statuses.reject { |s| s == 200 }.tally)
      check.call("/small within #{options[:max_latency]} s", smalls.max <= options[:max_latency], smalls.max.round(4))
      check.call("handshakes within #{options[:max_latency]} s", handshakes.max <= options[:max_latency],
        handshakes.max.round(4))
    end
  rescue Timeout::Error
    check.call("finished within #{options[:timeout]} seconds", false)
  rescue QUIC::Error, RuntimeError => e
    check.call("the requests went through", false, "#{e.class}: #{e.message}")
  ensure
    clients.each(&:close)
    begin
      Process.kill("TERM", pid)
      # Up to the 5 seconds of a /sleep, then the second the workers get.
      Timeout.timeout(15) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end

exit(failures.empty? ? 0 : 1)
