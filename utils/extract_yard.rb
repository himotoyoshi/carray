
Dir["*.c"].each do |file|
  open(file) { |io|
    while line = io.gets
      if line =~ /\A\s*\/\*\s*(@overload\s+(.*))$/
        method_spec = $2
        #        puts "  # " + line
        while line = io.gets
          case line
          when /\A\s*\*\//
            puts "  def " + method_spec
            puts "  end"
            break
          else
            print "  # " + line
          end
        end
        puts
      end
    end
  }
end
