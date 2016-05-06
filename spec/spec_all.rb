dirname = File.dirname(__FILE__)
$:.unshift(File.join(dirname, "..", "lib"))


require "carray"
  
Dir.chdir(File.dirname(__FILE__)) {
  Dir["**/*_spec.rb"].sort.each do |file|
    load(file)
  end
}