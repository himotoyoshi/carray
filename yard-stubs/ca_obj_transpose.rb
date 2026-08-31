# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CATranspose and CArray#transpose / #T defined in
# ext/ca_obj_transpose.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Permuted-axis view of the parent.  Pure `CAStride` typedef: only
# the dim / stride layout differs.  No data is copied; writes go
# through to the parent.
class CATranspose < CAStride
end

# Mask companion of {CATranspose}.
# @private
class CATransposeMask < CATranspose
end

class CArray
  # @!group Views

  # @overload transpose
  #   Returns a {CATranspose} view of `self` with the dimension order
  #   reversed (`view.shape[k] == self.shape[ndim-1-k]`).
  #   @return [CATranspose]
  # @overload transpose(*imap)
  #   Returns a {CATranspose} view of `self` permuted by `imap`, a
  #   permutation of `0 ... self.ndim`.  Element
  #   `view[i_0, ..., i_{n-1}]` aliases parent element with axis `k`
  #   sourced from `i` at position `imap[k]`.
  #   @param imap [Array<Integer>] permutation of `0 ... ndim`.
  #   @return [CATranspose]
  #   @raise [ArgumentError] when `imap.length != ndim`.
  #   @raise [RuntimeError] when an entry of `imap` is out of range
  #     or duplicated.
  def transpose(*imap); end

  # Alias of {#transpose}.
  def T(*imap); end

  # @!endgroup
end
