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

task default: [:"standard:fix", :"yard:lint", :test]
