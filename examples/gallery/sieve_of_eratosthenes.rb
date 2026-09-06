# frozen_string_literal: true
#
# gallery/sieve_of_eratosthenes.rb
#
# All primes up to n by the sieve of Eratosthenes. Each round marks off
# the multiples of a prime in one boolean-index assignment, without an
# inner loop over the multiples.

require "carray"

n = 200

# ------------------------------------------------------------
# The candidates and the "is prime" flags
# ------------------------------------------------------------
# k[i] = i — the integers 0..n. `k.true` returns a same-shape boolean
# array of all true, from which we clear the 0 and 1 cells (they are
# not primes). Below, prime[i] = true means "i is still a prime
# candidate".
k = CArray.int32(n + 1).seq

prime = k.true
prime[0] = false
prime[1] = false
#  Aside: `prime = k.true.scatter_replace!([0, 1], false)` writes the
#  same thing in one line. Two lines here read more directly because
#  the point is that 0 and 1 are the two exceptions to the rule.

# ------------------------------------------------------------
# Sieve
# ------------------------------------------------------------
# The multiples of p from p*p onward form the mask
#     ( k >= p*p ) & ( k % p == 0 )
# and boolean-index assignment clears them in one expression. No inner
# loop over the multiples.
#
# Why start from p*p rather than 2*p? Every multiple k*p with k < p
# has a prime factor smaller than p (some prime q that divides k),
# so it was already cleared when we processed that smaller prime.
# p*p is the first new multiple that only this iteration can catch.
p = 2
while p * p <= n
  if prime[p]
    prime[ k.ge(p * p) & (k % p).eq(0) ] = false
  end
  p += 1
end

# ------------------------------------------------------------
# The primes
# ------------------------------------------------------------
# k[prime] gathers the indices where prime is still true — the primes
# themselves. sum of the boolean gives the count directly.
primes = k[prime]
puts "primes up to #{n}:"
p primes
puts
puts "count: #{prime.sum}"

# ------------------------------------------------------------
# Pi(x) — the prime-counting function, cheaply
# ------------------------------------------------------------
# cumsum of the boolean is the prime-counting function evaluated at
# every integer in [0, n]. One expression, no Ruby loop.
pi = prime.cumsum
puts
puts "prime-counting function at a few thresholds:"
[10, 50, 100, 200].each do |x|
  puts "  pi(#{x}) = #{pi[x]}"
end
