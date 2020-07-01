#
#
#

GEMSPEC = "carray.gemspec"

task :install do
  spec = eval File.read(GEMSPEC)
  version_h = `ruby ext/version.rb`.chomp
  if spec.version.to_s != version_h
    STDERR.puts "Mismatch in version between carray.gemspec and version.h"
    STDERR.puts "  carray.gemspec - #{spec.version.to_s }"
    STDERR.puts "  version.h      - #{version_h}"
    STDERR.puts "Please check!"
    exit(1)
  end
  system %{
    gem build #{GEMSPEC}; gem install #{spec.full_name}.gem
  }
end

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new


__END__
require 'rake'
require 'rake/testtask'
require 'rspec/core/rake_task'

task :default => :test

GEMSPEC = "carray.gemspec"

task :install do
  spec = eval File.read(GEMSPEC)
  system %{
    gem build #{GEMSPEC}; gem install #{spec.full_name}.gem
  }
end

desc "Run the tests"
Rake::TestTask::new(:test) do |t|
  t.test_files = FileList['test/test_ALL.rb']
  t.verbose = true
end

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/**/*_spec.rb"
  t.rspec_opts = ["-c", "-fs"]
end