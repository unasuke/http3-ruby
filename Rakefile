# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create

require "standard/rake"

require "rake/extensiontask"

task build: :compile

GEMSPEC = Gem::Specification.load("http3.gemspec")

Rake::ExtensionTask.new("http3", GEMSPEC) do |ext|
  ext.lib_dir = "lib/http3"
end

task default: %i[clobber compile test standard]
