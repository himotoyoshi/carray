#
#
#

require 'rake'
require 'rake/testtask'
require 'rspec/core/rake_task'

task :default => :test

desc "Run the tests"
Rake::TestTask::new(:test) do |t|
  t.test_files = FileList['test/test_ALL.rb']
  t.verbose = true
end

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/**/*_spec.rb"
  t.rspec_opts = ["-c", "-fs"]
end