# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "http3"

require "minitest/autorun"
require "fileutils"
require "logger"
require "openssl"
require "rbconfig"
require "tmpdir"
require_relative "support/h3_client"
require_relative "support/test_certificates"

# HTTP3::Server in a child process, so that a test can send it signals and
# watch its memory without measuring itself.
module TestServerProcess
  START_TIMEOUT = 10
  STOP_TIMEOUT = 15

  # Fork a child serving the Rack app the block builds (in the child) on
  # 127.0.0.1 and an unused port; returns [pid, port]. The server logs to
  # log_path.
  def start_server(log_path:, **options, &build_app)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      server = HTTP3::Server.new(app: build_app.call, bind: "127.0.0.1:0", logger: Logger.new(log_path), **options)
      Thread.new do
        sleep 0.01 until server.local_address
        writer.puts(server.local_address.ip_port)
        writer.close
      end
      server.run
      # Not exit: the parent's at_exit hooks (Minitest's included) must not
      # run here.
      exit!(0)
    rescue Exception => e # rubocop:disable Lint/RescueException
      warn e.full_message
      exit!(1)
    end
    writer.close
    raise "the server did not start" unless reader.wait_readable(START_TIMEOUT)

    port = Integer(reader.gets, 10)
    [pid, port]
  ensure
    reader&.close
  end

  # Run the server script in a new Ruby process with args; returns
  # [pid, port] once the script has printed its port.
  def spawn_server(script, *args)
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, script, *args, out: writer)
    writer.close
    raise "the server did not start" unless reader.wait_readable(START_TIMEOUT)

    port = Integer(reader.gets, 10)
    [pid, port]
  ensure
    reader&.close
  end

  # Send SIGTERM and wait for the child to exit; returns its status.
  def stop_server(pid)
    Process.kill("TERM", pid)
    wait_server(pid)
  rescue Errno::ESRCH
    nil
  end

  def wait_server(pid, timeout: STOP_TIMEOUT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", pid)
        Process.wait(pid)
        raise "the server did not exit within #{timeout} seconds"
      end

      sleep 0.01
    end
  end

  # The resident set size of process pid, in KiB (Linux).
  def rss_kib(pid)
    File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i
  end
end
