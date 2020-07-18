
puts %{
class CArray
end
class CScalar
end
module CA
end
}

Dir["*.c"].each do |file|
  open(file) { |io|
    while line = io.gets
      if line =~ /\A\s*\/\*\s*yard:/
        while line = io.gets
          case line
          when /\A\s*\*\//
            break
          else
            print line
          end
        end
        puts
      end
    end
}
end
