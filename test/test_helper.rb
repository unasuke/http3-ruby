# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "http3"

require "minitest/autorun"
require "fileutils"
require "openssl"
require "rbconfig"
require "tmpdir"
require_relative "support/h3_client"

# A test CA and a server certificate it signed for 127.0.0.1, with the
# server's private key, as files.
module TestCertificates
  Credentials = Data.define(:ca_file, :certificate_path, :private_key_path)

  # One set per test run, shared by every test that asks.
  def credentials
    TestCertificates.credentials
  end

  def self.credentials
    @credentials ||= generate_credentials
  end

  # A new set in a new temporary directory, removed after the run.
  def self.generate_credentials
    now = Time.now
    ca_key = OpenSSL::PKey::EC.generate("prime256v1")
    ca_name = OpenSSL::X509::Name.parse("/CN=http3 test CA")
    ca_cert = OpenSSL::X509::Certificate.new
    ca_cert.version = 2
    ca_cert.serial = 1
    ca_cert.subject = ca_name
    ca_cert.issuer = ca_name
    ca_cert.public_key = ca_key
    ca_cert.not_before = now - 60
    ca_cert.not_after = now + 86_400
    factory = OpenSSL::X509::ExtensionFactory.new(ca_cert, ca_cert)
    ca_cert.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
    ca_cert.add_extension(factory.create_extension("keyUsage", "keyCertSign,cRLSign", true))
    ca_cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))

    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 2
    cert.subject = OpenSSL::X509::Name.parse("/CN=localhost")
    cert.issuer = ca_name
    cert.public_key = key
    cert.not_before = now - 60
    cert.not_after = now + 86_400
    factory = OpenSSL::X509::ExtensionFactory.new(ca_cert, cert)
    cert.add_extension(factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
    cert.add_extension(factory.create_extension("extendedKeyUsage", "serverAuth"))
    cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))

    dir = Dir.mktmpdir("http3-test-")
    Minitest.after_run { FileUtils.remove_entry(dir) }
    credentials = Credentials.new(
      ca_file: File.join(dir, "ca.pem"),
      certificate_path: File.join(dir, "server.pem"),
      private_key_path: File.join(dir, "server.key")
    )
    File.write(credentials.ca_file, ca_cert.to_pem)
    File.write(credentials.certificate_path, cert.to_pem)
    File.write(credentials.private_key_path, key.private_to_pem)
    credentials
  end
end

# HTTP3::Server in a process of its own, so that a test can watch its
# memory without measuring itself.
module TestServerProcess
  START_TIMEOUT = 10
  STOP_TIMEOUT = 15

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
