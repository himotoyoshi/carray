# Lazy evaluation

The element-wise operations in [Element-wise operations](03_elementwise.md) are
*eager*: every `+`, every `sqrt`, every comparison builds a full result array as
soon as it runs. That is the right default — it is simple, the operations are
fast, and the result is just another CArray you can do anything with.

But eager evaluation has a cost when you chain many operations together. Each
intermediate array is allocated, filled, and then thrown away as soon as the
next operation consumes it. For a deep chain over large arrays, that is a lot
of memory traffic just to compute a single final answer.

*Lazy* evaluation gives you a way to describe the same chain without building
those intermediates. You assemble a small expression tree, and the whole tree
is evaluated in one pass when you finally ask for a concrete result.

## The eager picture, first

```ruby
a = CArray.float64(4).seq               #  => [ 0.0, 1.0, 2.0, 3.0 ]
b = CArray.float64(4).seq + 1.0         #  => [ 1.0, 2.0, 3.0, 4.0 ]

(a + b) * 2
#  => [ 2.0, 6.0, 10.0, 14.0 ]
```

Two arrays were allocated under the hood: one for `a + b`, and one for the
multiplication. With four elements this is fine. With a few million, the
intermediate is real memory.

## Turning a chain lazy

`a.lazy` returns a lightweight marker that wraps `a` without copying. Any
element-wise operation on a lazy value builds a *node* in an expression tree
instead of computing immediately.

```ruby
a = CArray.float64(4).seq
b = CArray.float64(4).seq + 1.0

expr = (a.lazy + b.lazy) * 2
expr.class
#  => CABinOp

expr
#  => <CABinOp ...>      a description of the tree, not a result
```

Nothing has been computed yet. `expr` is just a structure that knows: "add
these two arrays, then multiply by 2". The arithmetic happens when you ask
for a concrete answer.

## Materialising the result

There are three common ways to "ask for the answer":

```ruby
expr.to_ca                  #  => [ 2.0, 6.0, 10.0, 14.0 ]   full array
expr.sum                    #  => 32.0                       reduction
expr.copy                   #  => [ 2.0, 6.0, 10.0, 14.0 ]   independent array
```

- `to_ca` evaluates the whole tree in a single streamed pass and returns the
  values as a CArray.
- A reduction such as `sum`, `mean`, `min`, `max` evaluates the tree *and*
  reduces in the same pass — there is no intermediate full-size array at all.
- `copy` is what you reach for when you want an independent, writable entity.
  (See [Vocabulary](08_vocabulary.md) for the distinction between `to_ca`
  and `copy`.)

The expression tree itself is read-only:

```ruby
expr[0] = 99
#  => RuntimeError: can not store data to read-only array
```

This is by design. The tree is a recipe, not a buffer; if you need to write
into the result, materialise first with `copy` and assign into that.

## Why this saves memory

A lazy chain stores *one description* of the calculation and produces *one*
result buffer at the end. The chained eager equivalent allocates one
intermediate per `+` or `*`. For large float64 arrays in a deep chain, that
difference adds up to many megabytes of traffic between the CPU and main
memory.

The shape and the type rules are unchanged — the lazy result has the same
shape and the same promoted type it would have had under eager evaluation.
Only the *timing* and *intermediate allocation* differ.

## `CArray.fuse` — one expression, one result

When you have a single closed-form expression and just want the final array
back, `CArray.fuse` is the convenient surface. It wraps each CArray argument
with `.lazy` for you, runs the block, then materialises the result on the
way out.

```ruby
a = CArray.float64(4).seq
b = CArray.float64(4).seq + 1.0

result = CArray.fuse(a, b) { |x, y| (x + y) * 2 }
result.class
#  => CArray
result
#  => [ 2.0, 6.0, 10.0, 14.0 ]
```

Inside the block, `x` and `y` are lazy wrappers. The block returns a lazy
expression, and `fuse` calls `to_ca` on it for you. From the outside, it
looks like an ordinary array operation that just happens to skip the
intermediates.

The classic example is a finite-difference stencil — many operands, modest
arithmetic per cell, large arrays:

```ruby
u = CArray.float64(64, 64).seq
h = 0.1

laplacian = CArray.fuse(u) { |u|
  (u.shift(1, 0, fill_value: 0) + u.shift(-1, 0, fill_value: 0) +
   u.shift(0, 1, fill_value: 0) + u.shift(0, -1, fill_value: 0) - 4 * u) / h**2
}
laplacian.class
#  => CArray
```

A polymorphic helper falls out of this naturally. Arguments that are *not*
CArray (a `Float`, `Integer`, etc.) are passed through to the block
unchanged, so the same code works for a single scalar input:

```ruby
using CArray::CoreExtensions    #  enables postfix .exp on Numeric

def magnus(t)
  CArray.fuse(t) { |t| 6.1078 * ((17.27 * t) / (t + 237.3)).exp }
end

magnus(25.0)
#  => 31.6767     a Float

magnus(CA_DOUBLE([0.0, 15.0, 25.0, 35.0]))
#  => [ 6.1078, 17.0529, 31.6767, 56.2250 ]
```

One formula, scalar or array, no type-checks needed at the call site.

## `CArray.lazy` — keep the tree

`CArray.lazy(args) { ... }` is `fuse`'s sibling that **does not** materialise
on the way out. You get the lazy view back, and the caller decides when and
how to evaluate it.

```ruby
def normalised(arr)
  CArray.lazy(arr) { |a| (a - a.mean) / a.stddev }
end

expr = normalised(CA_DOUBLE([1, 2, 3, 4, 5]))
expr.class
#  => CABinOp                   still a lazy view

expr.to_ca
#  => [ -1.4142, -0.7071, 0.0, 0.7071, 1.4142 ]
```

This is useful when:

- you want to reuse the same expression on many datasets;
- you want the caller to choose the materialisation form
  (`to_ca`, `sum`, `mean(axis: 0)`, etc.);
- you want to build a parametric expression once and evaluate it many times
  in a loop.

If you cannot decide, prefer `fuse` — nothing escapes the block as a lazy
view, so callers never need to know the lazy machinery exists.

## Masks pass through

Masked elements (see [Masks](05_masks.md)) propagate through a lazy chain
the same way they do through eager arithmetic. A position that is masked in
any input stays masked in the result:

```ruby
a = CArray.float64(4).seq
a[1] = UNDEF
#  => [ 0.0, _, 2.0, 3.0 ]

(a.lazy + 100).to_ca
#  => [ 100.0, _, 102.0, 103.0 ]

a.lazy.sqrt.to_ca
#  => [ 0.0, _, 1.4142, 1.7321 ]
```

You do not have to do anything special — missingness carries through the
tree, and only valid positions are evaluated.

## Lazy comparisons

Comparisons (`gt`, `eq`, `lt`, `<`, `>=`, ...) and the boolean combinations
(`&`, `|`, `^`) build lazy nodes just like arithmetic does:

```ruby
a = CA_DOUBLE([0.0, 1.0, 2.0, 3.0, 4.0])

mask = (a.lazy.gt(1.0) & a.lazy.lt(4.0))
mask.to_ca
#  => [ 0, 1, 1, 1, 0 ]

mask.sum
#  => 3                  count of cells satisfying both conditions
```

A common pattern is to build a boolean expression lazily and reduce it
directly — the intermediate boolean array is never allocated.

## When to stay eager

Lazy is not always faster. Eager arithmetic is heavily optimised on
contiguous arrays, and a single `a + b` over an ordinary array hits a
vectorised path. Reach for lazy when:

- the chain is long enough that intermediates start to matter (deep stencils,
  multi-term polynomials, transcendental compositions);
- the arrays are large enough that intermediates spill out of cache;
- the per-cell work is heavy (`exp`, `log`, `sqrt`, compound expressions);
- you want a single helper that works for both scalars and arrays.

Stay with eager when:

- the chain is one or two operations on already-allocated arrays;
- you want to keep the intermediate around for inspection or reuse;
- you want to write into the result (eager results are normal entities,
  mutable from the start).

A simple test: if you find yourself reading the same large intermediate just
once and throwing it away, that intermediate is a candidate for fusion.

## Going back to eager

A lazy expression turns into a regular CArray the moment you call `to_ca`,
`copy`, or any reduction. From there, everything works as in earlier
chapters — you can index it, mutate it, mask it, pass it to a view method,
hand it to MemoryView consumers. The lazy substrate is just a way to defer
the work; once it is done, the result is an ordinary array.

```ruby
result = CArray.fuse(a, b) { |x, y| (x.sqrt + y) * 2 }
result[0] = 0.0                   #  ordinary entity, writable
result + 1                        #  ordinary eager arithmetic
```

You can mix freely. A lazy view added to an eager array produces a lazy
node; an eager operation on a materialised result produces another eager
result. There is no mode to enter and leave — the wrapper is the lazy
marker, and removing it (by materialising) is enough.
