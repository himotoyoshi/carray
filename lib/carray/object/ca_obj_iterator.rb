# ----------------------------------------------------------------------------
#
#  carray/object/ca_obj_iterator.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CAIteratorArray < CAObject # :nodoc:

  def initialize (it)
    @it = it
    super(CA_OBJECT, @it.dim)
  end

  private

  def fetch_index (idx)
    return @it.kernel_at_index(idx)
  end

  def store_index (idx, val)
    @it.kernel_at_index(idx)[] = val
  end

  def copy_data (data)
    data.each_index do |*idx|
      data[*idx] = @it.kernel_at_index(idx)
    end
  end

  def sync_data (data)
    tmpl = @it.reference.template
    data.each_index do |*idx|
      @it.kernel_at_index(idx, tmpl)[] = data[*idx]
    end
    @it.reference[] = tmpl
  end

  def fill_data (data)
    tmpl = @it.reference.template
    CArray.each_index(*@it.dim) do |*idx|
      @it.kernel_at_index(idx, tmpl)[] = data
    end
    @it.reference[] = tmpl
  end

end
