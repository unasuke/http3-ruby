# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in http3.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rake-compiler"

gem "minitest", "~> 5.16"

gem "standard", "~> 1.3"

# Net::HTTP::Client, which http3/net/http plugs into, is only on this branch so far
gem "net-http", github: "nurse/net-http", branch: "http2"
