# Lazy evaluation

The element-wise operations in [Element-wise operations](03_elementwise.md) are *eager*: every `+`, every `sqrt`, every comparison builds a full result array as soon as it runs. That is the right default — it is simple, the operations are fast, and the result is just another CArray you can do anything with.

But eager evaluation has a cost when you chain many operations together. Each intermediate array is allocated, filled, and then thrown away as soon as the next operation consumes it. For a deep chain over large arrays, that is a lot of memory traffic just to compute a single final answer.

*Lazy* evaluation gives you a way to describe the same chain without building those intermediates. You assemble a small expression tree, and the whole tree is evaluated in one pass when you finally ask for a concrete result.

## The eager picture, first

```ruby
a = CArray.float64(4).seq               #  => [ 0.0, 1.0, 2.0, 3.0 ]
b = CArray.float64(4).seq + 1.0         #  => [ 1.0, 2.0, 3.0, 4.0 ]

(a + b) * 2
#  => [ 2.0, 6.0, 10.0, 14.0 ]
```

Two arrays were allocated under the hood: one for `a + b`, and one for the multiplication. With four elements this is fine. With a few million, the intermediate is real memory.

## Turning a chain lazy

`a.lazy` returns a lightweight marker that wraps `a` without copying. Any element-wise operation on a lazy value builds a *node* in an expression tree instead of computing immediately.

```ruby
a = CArray.float64(4).seq
b = CArray.float64(4).seq + 1.0

expr = (a.lazy + b.lazy) * 2
expr.class
#  => CABinOp

expr
#  => <CABinOp ...>      a description of the tree, not a result
```

Nothing has been computed yet. `expr` is just a structure that knows: "add these two arrays, then multiply by 2". The arithmetic happens when you ask for a concrete answer.

## Materialising the result

There are three common ways to "ask for the answer":

```ruby
expr.to_ca                  #  => [ 2.0, 6.0, 10.0, 14.0 ]   full array
expr.sum                    #  => 32.0                       reduction
expr.copy                   #  => [ 2.0, 6.0, 10.0, 14.0 ]   independent array
```

- `to_ca` evaluates the whole tree in a single streamed pass and returns the values as a CArray.
- A reduction such as `sum`, `mean`, `min`, `max` evaluates the tree *and* reduces in the same pass — there is no intermediate full-size array at all.
- `copy` is what you reach for when you want an independent, writable entity. (See [Vocabulary](08_vocabulary.md) for the distinction between `to_ca` and `copy`.)

The expression tree itself is read-only:

```ruby
expr[0] = 99
#  => RuntimeError: can not store data to read-only array
```

This is by design. The tree is a recipe, not a buffer; if you need to write into the result, materialise first with `copy` and assign into that.

## Why this saves memory

A lazy chain stores *one description* of the calculation and produces *one* result buffer at the end. The chained eager equivalent allocates one intermediate per `+` or `*`. For large float64 arrays in a deep chain, that difference adds up to many megabytes of traffic between the CPU and main memory.

The shape and the type rules are unchanged — the lazy result has the same shape and the same promoted type it would have had under eager evaluation. Only the *timing* and *intermediate allocation* differ.

## `CArray.fuse` — writing the expression

Marking each operand with `.lazy` gets repetitive once there is more than one of them. `CArray.fuse` lets you write the expression itself:

```ruby
a = CArray.float64(4).seq
b = CArray.float64(4).seq + 1.0

result = CArray.fuse { (a + b) * 2 }
result.class
#  => CABinOp
result.to_ca
#  => [ 2.0, 6.0, 10.0, 14.0 ]
```

The block is **read, not run**. Its `a` is the array itself, so running it would compute the expression eagerly — the very thing we are avoiding. `fuse` reads the block's source, gives every name in it that holds an array a `.lazy`, and evaluates the result back where the block was written. Instance variables, methods on `self` and constants all still mean what they meant there.

What comes back is the expression, the same as from a hand-marked chain. It is computed where it is used — stored into an array, reduced, or asked for one with `to_ca`.

The classic example is a finite-difference stencil — many operands, modest arithmetic per cell, large arrays:

```ruby
u = CArray.float64(64, 64).seq
h = 0.1

laplacian = CArray.fuse {
  (u.shift(1, 0, fill_value: 0) + u.shift(-1, 0, fill_value: 0) +
   u.shift(0, 1, fill_value: 0) + u.shift(0, -1, fill_value: 0) - 4 * u) / h**2
}
laplacian.to_ca.class
#  => CArray
```

Five operands, one pass. Written eagerly the same expression allocates four intermediate arrays and walks each of them twice more; fused, the shifts are read once and the result written once. On a 2000x2000 float64 array that is about **2.2 times faster**, and the margin grows with the number of terms — a twelve-term sum is closer to **3.5 times**.

Note where `.lazy` is *not* needed. Views built inside the block — `shift` here, but equally `[]`, `transpose`, `reshape`, `flip`, `roll`, `window`, `diagonal`, `tile` — stay part of the expression on their own. You do not have to think about the order you build them in.

A polymorphic helper falls out of this naturally. Only names holding an array are marked; a `Float` or an `Integer` is left alone, so the same formula reads either way:

```ruby
using CArray::CoreExtensions    #  enables postfix .exp on Numeric

def magnus(t)
  CArray.fuse { 6.1078 * ((17.27 * t) / (t + 237.3)).exp }
end

magnus(25.0)
#  => 31.6767     a Float

magnus(CA_DOUBLE([0.0, 15.0, 25.0, 35.0])).to_ca
#  => [ 6.1078, 17.0529, 31.6767, 56.2250 ]
```

One formula, scalar or array, no type-checks needed at the call site.

### When the block cannot be read

A block written at an `irb` prompt, or inside `eval`, has no source file to read from, and `fuse` says so rather than quietly computing the expression the slow way. Mark the operands by hand there:

```ruby
a.lazy + b.lazy
```

That always works — it is what `fuse` writes for you.

## Compute a repeated subexpression before the block

Inside the block, a name that you assign does not hold a result. It holds a calculation.

```ruby
CArray.fuse {
  y = a * 2          # y is "multiply a by 2", not the doubled array
  y + y              # so the multiply runs twice
}
```

Naming it does not compute it, and using it twice does not reuse anything. This is the reverse of eager code, where assigning to a variable is exactly how you avoid repeating work.

Names from *outside* the block are different. Whatever they hold has already been calculated, so using one several times just reads the value several times.

```ruby
y = a * 2            # computed here, once
CArray.fuse { y + y }
```

The cost of getting this wrong is easy to measure. Here one expensive calculation is used `n` times inside the block (2000x2000 float64):

| times used | eager | fused | ratio |
|---|---|---|---|
| 1 | 0.0024 | 0.0020 | 1.18 |
| 2 | 0.0028 | 0.0040 | 0.70 |
| 3 | 0.0036 | 0.0059 | 0.61 |
| 4 | 0.0042 | 0.0078 | 0.54 |

Eager is flat — it computes once and reuses. Fused grows in proportion to how often you write it. Past two uses, fusion is losing.

### Example: Goff-Gratch

The saturation vapour pressure formula uses `TS / T` three times:

```ruby
TS, ES = 373.16, 1013.246
L = Math.log10(ES)

# TS / T written inside the block: the division runs three times per cell
CArray.fuse {
  r = TS / T
  (-7.90298 * (r - 1) + 5.02808 * r.log10 -
    1.3816e-7 * ((11.344 * (1 - T / TS)).exp10 - 1) +
    8.1328e-3 * ((-3.49149 * (r - 1)).exp10 - 1) + L).exp10
}

# computed before the block: one division per cell, and the rest still fuses
r = TS / T
CArray.fuse {
  (-7.90298 * (r - 1) + 5.02808 * r.log10 -
    1.3816e-7 * ((11.344 * (1 - T / TS)).exp10 - 1) +
    8.1328e-3 * ((-3.49149 * (r - 1)).exp10 - 1) + L).exp10
}
```

Measured on 1000x1000 float64, in units of one array copy:

| | cost |
|---|---|
| eager, with intermediate variables | 47.3 |
| everything inside `fuse` | 52.0 |
| `TS / T` computed first, rest fused | **34.9** |

The middle row is worth noticing: for this formula, fusing everything is *slower* than plain eager code. `exp10` and `log10` dominate the cost, so there is little memory traffic to save, and the repeated divisions cost more than the saving. Moving one line out of the block reverses the result.

Do not overdo it. Computing `r - 1` beforehand as well (also used twice, but only a subtraction) measured 35.8 — slightly worse. The question is not "is it repeated?" but:

> **Is repeating this calculation cheaper than computing it once and reading the values back?**

A division, `exp` or `log` is worth computing first. An add or a multiply is not.

### The same quantity, the opposite answer

Saturation vapour pressure is often computed not from Goff-Gratch but from a polynomial fit. Same physical quantity, and fusion now helps a great deal.

```ruby
C = [6.11583699, 0.444606896, 0.143177157e-1, 0.264224321e-3,
     0.299291081e-5, 0.203154182e-7, 0.702620698e-10, 0.379534310e-13,
     -0.321582393e-15]

CArray.fuse { C.reverse.inject { |acc, c| acc * T + c } }   # Horner
```

Measured on 2000x2000 float64, in units of one array copy:

| | cost | vs eager |
|---|---|---|
| Horner, eager | 34.2 | — |
| **Horner, fused** | **11.1** | **3.1x** |
| naive powers (`t**k`), eager | 123.8 | — |
| naive powers, fused | 37.7 | 3.3x |

Everything lines up in fusion's favour here:

- the arithmetic is one multiply and one add per term — cheap next to a memory read, so the intermediates were most of the cost;
- `T` is an array from outside the block, so using it eight times costs eight reads and no recalculation;
- Horner's rule builds a fresh `acc` each step, so nothing is repeated.

The naive form is worth a glance too. Writing `T**k` for each term recomputes the powers, and fusion cannot fix that — but it still removes the intermediates, so it gains 3.3x anyway. Rewriting to Horner gains a further 3.4x on top. **Choosing the algorithm and fusing it are independent wins.**

The pair is worth remembering:

| | fusion |
|---|---|
| Goff-Gratch (`exp10`, `log10`, a repeated division) | 0.9x — a loss |
| polynomial fit, Horner (multiply and add, nothing repeated) | 3.1x |

Same answer to four decimal places, opposite conclusion about fusion. It is the shape of the arithmetic that decides, not the problem being solved.

## Handing the expression on

Because what `fuse` returns is the expression and not a result, it travels. A helper can build one and let the caller decide when and how to evaluate it:

```ruby
def normalised(arr)
  CArray.fuse { (arr - arr.mean) / arr.stddev }
end

expr = normalised(CA_DOUBLE([1, 2, 3, 4, 5]))
expr.class
#  => CABinOp                   still an expression

expr.to_ca
#  => [ -1.2649, -0.6325, 0.0, 0.6325, 1.2649 ]
```

This is what lets you reuse the same expression on many datasets, let the caller pick the form to materialise into (`to_ca`, `sum`, `mean(axis: 0)`), or build a parametric expression once and evaluate it many times in a loop.

## Masks pass through

Masked elements (see [Masks](05_masks.md)) propagate through a lazy chain the same way they do through eager arithmetic. A position that is masked in any input stays masked in the result:

```ruby
a = CArray.float64(4).seq
a[1] = UNDEF
#  => [ 0.0, _, 2.0, 3.0 ]

(a.lazy + 100).to_ca
#  => [ 100.0, _, 102.0, 103.0 ]

a.lazy.sqrt.to_ca
#  => [ 0.0, _, 1.4142, 1.7321 ]
```

You do not have to do anything special — missingness carries through the tree, and only valid positions are evaluated.

## Lazy comparisons

Comparisons (`gt`, `eq`, `lt`, `<`, `>=`, ...) and the boolean combinations (`&`, `|`, `^`) build lazy nodes just like arithmetic does:

```ruby
a = CA_DOUBLE([0.0, 1.0, 2.0, 3.0, 4.0])

mask = (a.lazy.gt(1.0) & a.lazy.lt(4.0))
mask.to_ca
#  => [ 0, 1, 1, 1, 0 ]

mask.sum
#  => 3                  count of cells satisfying both conditions
```

A common pattern is to build a boolean expression lazily and reduce it directly — the intermediate boolean array is never allocated.

## When fusion pays

Fusion removes **memory traffic**, not arithmetic. Each cell is still visited once per node in the tree, and that walk is not free. So the win depends on how much of the eager cost was traffic in the first place.

Chaining k operations over a 1000x1000 float64 array:

| k | cheap ops (`+`, `*`) | `sqrt` | `exp10` |
|---|---|---|---|
| 2 | 1.48 | 1.64 | 1.24 |
| 4 | 2.01 | 1.91 | 1.31 |
| 8 | 2.26 | 2.21 | 1.33 |
| 16 | 2.25 | 2.40 | — |

Two readings:

- **More terms, more gain.** Each extra term is one more intermediate that eager has to allocate, fill and re-read.
- **Cheaper arithmetic, more gain.** With `exp10` the per-cell work dwarfs the traffic, so removing the traffic barely shows.

That is the opposite of the intuition "heavy per-cell work is what fusion is for". Heavy work is what makes fusion *irrelevant*; it is cheap work over large arrays that fusion helps.

Reach for fusion when:

- the chain is several operations long;
- the arithmetic is cheap (add, multiply, compare) relative to a memory read;
- the arrays are large enough that intermediates spill out of cache;
- no subexpression is used more than once (or the shared ones are computed before the block);
- you want a single helper that works for both scalars and arrays.

Stay eager when:

- the chain is one or two operations;
- the expression is dominated by transcendental calls;
- you want to keep an intermediate for inspection or reuse;
- you want to write into the result (eager results are mutable entities).

Finite-difference stencils sit squarely in the good case: the arithmetic is addition, the terms read different neighbours so nothing is shared, and the arrays are large. That is why the Laplacian above gains 2.2x while a thermodynamic formula gains nothing.

### In a time-stepping loop

The expression can be built once and reused. It refers to the array itself, not to a copy of its contents, so overwriting the array and evaluating again gives the new answer:

```ruby
c = alpha * dt / h**2
expr = CArray.fuse {
  u + c * (u.shift(1, 0) + u.shift(-1, 0) + u.shift(0, 1) + u.shift(0, -1) - 4 * u)
}

nstep.times do
  new = expr.to_ca
  u[1..-2, 1..-2] = new[1..-2, 1..-2]     # write back into the same buffer
end
```

Rebuilding the expression inside the loop measures the same — putting the expression together costs nothing next to walking a million cells — so use whichever reads better. What matters is that `u` is overwritten **in place**: `u = ...` would rebind the name and leave the expression looking at the old array.

Measured over 30 steps of a 1000x1000 diffusion problem, the fused loop runs **1.48 times** faster than the eager one. Note that the whole update has to be in the expression to get that: fusing only the Laplacian, then applying it with eager arithmetic, measured no gain at all — the remaining eager operations kept allocating the intermediates that fusion had just removed.

## Going back to eager

A lazy expression turns into a regular CArray the moment you call `to_ca`, `copy`, or any reduction. From there, everything works as in earlier chapters — you can index it, mutate it, mask it, pass it to a view method, hand it to MemoryView consumers. The lazy substrate is just a way to defer the work; once it is done, the result is an ordinary array.

```ruby
result = CArray.fuse { (a.sqrt + b) * 2 }.to_ca
result[0] = 0.0                   #  ordinary entity, writable
result + 1                        #  ordinary eager arithmetic
```

You can mix freely. A lazy view added to an eager array produces a lazy node; an eager operation on a materialised result produces another eager result. There is no mode to enter and leave — the wrapper is the lazy marker, and removing it (by materialising) is enough.
