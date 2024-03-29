# ----------------------------------------------------------------------------
#
#  carray/string.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require "date"

class CArray

  def self.format (fmt, *argv)
    raise "no parameters given" if argv.empty?
    return argv.shift.zip(*argv).map { |params| Kernel::format(fmt, *params) }.to_ca
  end

  def str_len ()
    return convert(:int, &:length)
  end

  def str_size ()
    return convert(:int, &:size)
  end

  def str_bytesize ()
    return convert(:int, &:bytesize)
  end

  def str_gsub (*args, &block)
    return convert() {|s| s.gsub(*args, &block) }
  end

  def str_sub (*args, &block)
    return convert() {|s| s.sub(*args, &block) }
  end

  def str_encode (*args)
    return convert() {|s| s.encode(*args) }
  end

  def str_force_encoding (encoding)
    return convert() {|s| s.force_encoding(encoding) }
  end

  def str_encoding ()
    return convert(&:encoding)
  end

  def str_is_end_with (*args)
    return test {|s| s.end_with?(*args) }
  end

  def str_is_start_with (*args)
    return test {|s| s.start_with?(*args) }
  end

  def str_includes (substr)
    return test {|s| s.include?(substr) }
  end

  alias str_contains str_includes

  def str_index (*args)
    return convert(:int) {|s| s.index(*args) }
  end

  def str_rindex (*args)
    return convert(:int) {|s| s.rindex(*args) }
  end

  def str_intern ()
    return convert(&:intern)
  end

  def str_scrub ()
    return convert(&:scrub)
  end

  def str_downcase ()
    return convert(&:downcase)
  end

  def str_upcase ()
    return convert(&:upcase)
  end

  def str_capitalize ()
    return convert(&:capitalize)
  end

  def str_swapcase ()
    return convert(&:swapcase)
  end

  def str_chomp (*args)
    return convert() {|s| s.chomp(*args) }
  end

  def str_chop ()
    return convert(&:chop)
  end

  def str_chr ()
    return convert(&:chr)
  end

  def str_clear ()
    return convert(&:clear)
  end

  def str_count (*args)
    return convert(:int) {|s| s.count(*args) }
  end

  def str_delete (*args)
    return convert() {|s| s.delete(*args) }
  end

  def str_delete_prefix (prefix)
    return convert() {|s| s.delete_prefix(prefix) }
  end

  def str_delete_suffix (suffix)
    return convert() {|s| s.delete_suffix(suffix) }
  end

  def str_dump ()
    return convert(&:dump)
  end

  def str_center (*args)
    return convert() {|s| s.center(*args) }
  end

  def str_ljust (*args)
    return convert() {|s| s.ljust(*args) }
  end

  def str_rjust (*args)
    return convert() {|s| s.rjust(*args) }
  end

  def str_to_i ()
    return convert(&:to_i)
  end

  def str_to_f ()
    return convert(&:to_f)
  end

  def str_to_r ()
    return convert(&:to_r)
  end

  def str_strip ()
    return convert(&:strip)
  end

  def str_rstrip ()
    return convert(&:rstrip)
  end

  def str_lstrip ()
    return convert(&:lstrip)
  end

  def str_is_empty ()
    return test(&:empty?)
  end

  def str_matches (*args)
    if args.size == 1 && args.first.is_a?(Regexp)
      regexp = args.first
      return test {|v| v =~ regexp }
    else
      mask = template(:boolean) { false }
      args.each do |str|
        addr = search(str)
        mask[addr] = true if addr
      end
      return mask
    end
  end
  
  def str_extract (regexp, replace = '\0')
    return convert {|s| regexp.match(s) {|m| m[0].sub(regexp, replace) } || "" }
  end
    
end

