# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

namespace :yard do
  desc "Check the YARD documentation in lib/ with yard-lint (config in .yard-lint.yml)"
  task :lint do
    if Gem.loaded_specs.key?("yard-lint")
      sh "bundle exec yard-lint --no-progress lib/"
    else
      warn "yard-lint is not in the bundle (it needs Ruby 3.3+), skipping yard:lint"
    end
  end
end

# Where each format's signatures live: sig/ is where RBS tooling looks in a gem, rbi/ is Sorbet's
SIGNATURES = {"rbs" => "sig/herringbone.rbs", "rbi" => "rbi/herringbone.rbi"}.freeze
# Standard libraries the RBS refers to, also listed in sig/manifest.yaml for users of the gem
RBS_LIBRARIES = %w[date].freeze

desc "Regenerate the type signatures in rbi/ and sig/ from the YARD docs with sord"
task :types do
  unless Gem.loaded_specs.key?("sord")
    warn "sord is not in the bundle (it needs Ruby 3.3+), skipping types"
    next
  end
  SIGNATURES.each do |format, path|
    mkdir_p File.dirname(path)
    sh "bundle exec sord gen #{path} --#{format} --skip-constants --no-sord-comments --replace-errors-with-untyped"
    # Sord copies constants' source, which breaks on heredocs and would put the version number in
    # the signatures, so they are skipped and VERSION is declared by hand
    version = (format == "rbi") ? "VERSION = T.let(T.unsafe(nil), String)" : "VERSION: String"
    signatures = File.read(path).sub(/^module Herringbone\n/) { "#{_1}  #{version}\n\n" }
    # Skipping constants loses `S = Thrift::Struct`, which every Format struct inherits from
    signatures.gsub!(/ < Herringbone::Format::S$/, " < Herringbone::Thrift::Struct")
    # A bare Struct would be Thrift::Struct inside Thrift, and RBS wants its type argument
    signatures.gsub!(/ < Struct$/, (format == "rbi") ? " < ::Struct" : " < ::Struct[untyped]")
    # The optional gems ship no RBS, and their types would not resolve without them anyway
    signatures.gsub!(/\b(Numo|ActiveRecord)(::\w+)+/, "untyped") if format == "rbs"
    File.write(path, signatures)
  end
  Rake::Task[:"types:validate"].invoke
end

namespace :types do
  desc "Check that sig/herringbone.rbs is valid RBS"
  task :validate do
    sh "bundle exec rbs -I sig #{RBS_LIBRARIES.map { "-r #{_1}" }.join(" ")} validate"
  end
end

task default: [:test, :"standard:fix", :"yard:lint", :types]
