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

desc "Regenerate the type signatures in rbi/ and rbs/ from the YARD docs with sord"
task :types do
  unless Gem.loaded_specs.key?("sord")
    warn "sord is not in the bundle (it needs Ruby 3.3+), skipping types"
    next
  end
  {"rbi" => "--rbi", "rbs" => "--rbs"}.each do |format, flag|
    path = "#{format}/herringbone.#{format}"
    mkdir_p format
    sh "bundle exec sord gen #{path} #{flag} --skip-constants --no-sord-comments --replace-errors-with-untyped"
    # Sord copies constants' source, which breaks on heredocs and would put the version number in
    # the signatures, so they are skipped and VERSION is declared by hand
    version = (format == "rbi") ? "VERSION = T.let(T.unsafe(nil), String)" : "VERSION: String"
    signatures = File.read(path).sub(/^module Herringbone\n/) { "#{_1}  #{version}\n\n" }
    File.write(path, signatures)
  end
end

task default: [:"standard:fix", :"yard:lint", :types, :test]
