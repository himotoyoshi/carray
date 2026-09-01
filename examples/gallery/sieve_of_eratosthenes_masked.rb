# frozen_string_literal: true
#
# gallery/sieve_of_eratosthenes_masked.rb
#
# The sieve of Eratosthenes with CArray's first-class mask playing the
# role that a boolean flag array plays in the textbook version. Every
# CArray can carry a mask that marks individual cells as excluded;
# arithmetic and reductions propagate the mask automatically. Here
# the array simultaneously **is** the value grid and **has** the
# candidate flags — mask a cell to say "this number is out".
#
# See also `sieve_of_eratosthenes.rb` for the more portable boolean
# flag-array approach.

require "carray"

n = 199

# ------------------------------------------------------------
# The candidates
# ------------------------------------------------------------
# k[i] = i, the integers 0..n. Masking 0 and 1 removes them from the
# candidate set before the sieve runs. A masked cell means "no longer
# a candidate"; the underlying value is still there but skipped.
k = CArray.int32(n + 1).seq
k[0] = UNDEF
k[1] = UNDEF

# ------------------------------------------------------------
# Sieve
# ------------------------------------------------------------
# For each surviving p, mask out the multiples of p from p*p onward.
# `k[p] != UNDEF` tells us whether p is still a candidate — one
# scalar access, no whole-array boolean.
#
# (`k.mask[p]` reads the mask flag directly and is also O(1); either
# form beats `k.is_masked[p]`, which would allocate a same-shape
# boolean array just to look at one cell.)
#
# Same p*p optimisation as the boolean sieve: every k*p with k < p
# has a smaller prime factor and was already masked in an earlier
# iteration, so p*p is the first new multiple this pass can catch.
p = 2
while p * p <= n
  if k[p] != UNDEF
    k[ k.ge(p * p) & (k % p).eq(0) ] = UNDEF
  end
  p += 1
end

# ------------------------------------------------------------
# The primes
# ------------------------------------------------------------
# The unmasked cells of k are the primes themselves. `k[:is_not_masked]`
# is CArray's symbolic indexer sigil for "the cells that are not
# masked" — the same result as `k[k.is_not_masked]`, spelled shorter.
primes = k[:is_not_masked]
puts "primes up to #{n}:"
p primes
puts
puts "count: #{k.count_not_masked}"

# ------------------------------------------------------------
# The array in place — where the mask made the pattern visible
# ------------------------------------------------------------
# `k` still has the same shape as it started with; the sieve did not
# gather or filter anything. It just marked cells as excluded, and
# the mask carries that information. Reshaping k to a 20-by-10 grid
# and formatting each cell shows the primes in the positions of the
# integers they are, with non-primes rendered as `_`.
#
# The whole rendering is a CArray chain — `.format` applies a printf
# format per cell (mask-propagating), `.strip_mask("  _")` fills the
# masked cells with the underscore glyph, and `.join(sep, axis: k)`
# collapses the row axis to strings. The `:~` in `reshape` lets
# CArray infer the row count from the element total (=`n + 1`) and
# the given column count.
puts
puts "k as a grid (`_` = masked out):"
puts k.reshape(:~, 10).format("%3d").strip_mask("  _").join(" ", axis: 1).join("\n")

# ------------------------------------------------------------
# Pi(x) — the prime-counting function, cheaply
# ------------------------------------------------------------
# `k.is_not_masked` is the boolean survivor-flag; its cumsum gives
# the prime-counting function evaluated at every integer in [0, n],
# just as `prime.cumsum` did in the boolean version.
pi = k.is_not_masked.cumsum
puts
puts "prime-counting function at a few thresholds:"
[10, 50, 100, 199].each do |x|
  puts "  pi(#{x}) = #{pi[x]}"
end
