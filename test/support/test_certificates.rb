# frozen_string_literal: true

require "fileutils"
require "openssl"
require "tmpdir"

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

  # A new set under a CA of its own, in dir (a new temporary directory,
  # removed after the Minitest run, when nil; a script that does not run
  # Minitest passes dir).
  def self.generate_credentials(ca_common_name: "http3 test CA", dir: nil)
    now = Time.now
    ca_key = OpenSSL::PKey::EC.generate("prime256v1")
    ca_name = OpenSSL::X509::Name.parse("/CN=#{ca_common_name}")
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

    if dir.nil?
      dir = Dir.mktmpdir("http3-test-")
      Minitest.after_run { FileUtils.remove_entry(dir) }
    end
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
