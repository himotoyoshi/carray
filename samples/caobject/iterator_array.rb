# !!! LEGACY -- does not run as-is on CArray 3.0. !!!
#
# Concept-only artifact, kept for reference.  This used to work when
# `CAIterator#ca` shipped with the gem and lazily wrapped every
# CAIterator instance as a CAObject; it was removed in 3.0 because
# CAIterator#[] / #[]= give the same read / write access without the
# CAObject wrap and the IS-A CArray exposure was rarely actually
# needed.
#
# The CAIterator subclasses bundled with CArray 3.0 may not even
# expose all the methods this wrapper expects (#dim / #reference /
# #kernel_at_index(idx[, ref])); some have been retired / reshaped in
# the slab.rb redesign.  Treat the body below as a worked example of
# the pattern "wrap an arbitrary iterator-shaped object as a CAObject
# with read / write-back via a fresh template", not as a drop-in
# helper.
#
#   # The intended call shape (DO NOT EXPECT THIS TO RUN VERBATIM)
#   it  = ca.windows(3)
#   ary = CAIteratorArray.new(it)
#   ary[0]                  # would have been: slab at outer index 0
#   ary[i, j] = some_slab   # would have written back via the iterator
#
# If you ever need this pattern for your own iterator-shaped object,
# adapt the body to whatever surface your iterator exposes today.

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
