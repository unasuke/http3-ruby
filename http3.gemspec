# frozen_string_literal: true

require_relative "lib/http3/version"

Gem::Specification.new do |spec|
  spec.name = "http3"
  spec.version = HTTP3::VERSION
  spec.authors = ["Yusuke Nakamura"]
  spec.email = ["yusuke1994525@gmail.com"]

  spec.summary = "[WIP] An HTTP/3 server for Ruby, built on nghttp3 and the quic gem"
  spec.description = "[WIP] HTTP/3 for Ruby: Ruby bindings for nghttp3 (HTTP/3 mapping over QUIC and QPACK), " \
    "built at install time and linked statically via mini_portile2."
  spec.homepage = "https://github.com/unasuke/http3-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/unasuke/http3-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/unasuke/http3-ruby/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .standard.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/http3/extconf.rb"]

  # nghttp3 is downloaded and built from source via mini_portile2
  spec.add_dependency "mini_portile2", "~> 2.8"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
