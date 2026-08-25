# The boolean data type

CArray's `:boolean` data type is a one-byte-per-cell truth type whose storage
is `uint8` holding the values `0` and `1`. It is what every comparison
produces (`a > 0`, `a.eq(b)`, …) and what masks and boolean indexing are
built on. [Element-wise operations](03_elementwise.md) introduced boolean
arrays in passing; this chapter is the complete treatment — including the
parts that are easy to get wrong.

One rule governs the whole surface:

> **Boolean participates in every numeric and order kernel as its `0`/`1`
> numeric storage, and those kernels return a numeric result. The operations
> that stay boolean are the *logical* family: `all` / `any` / `none`, the
> bitwise `& | ^ ~` / `not`, and the comparison operators.**

A boolean array is a normal `CArray` (`CArray.boolean(...)` builds one; there
is no separate class), so slicing, masking, reshaping, iteration, and
serialization all work as on any other array.

## Two representations, one boundary

A boolean cell has two representations, split by where the value goes:

| Where you meet it | What you get | Example |
|---|---|---|
| Any Ruby-land path (`inspect` printing, `b[i]`, `each`, `to_a`) | Ruby `true` / `false` (printed as `1` / `0`) | `b[0]` → `true`, `b.to_a` → `[true, false, true, true, false]` |
| Numeric-cast and serialize paths (`to_type(:int32)`, `Marshal`, `.ca` save, MemoryView export) | `uint8` `0` / `1` (raw storage bytes) | `b.to_type(:int32).to_a` → `[1, 0, 1, 1, 0]` |

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])

p b                    #  => [ 1, 0, 1, 1, 0 ]   (printed with 1/0 glyphs)
b[0]                   #  => true                 (Ruby-land, per cell)
b.to_a                 #  => [true, false, true, true, false]
b.each { |v| v }       #  yields true, false, true, true, false
b.to_type(:int32).to_a #  => [1, 0, 1, 1, 0]     (numeric downstream)
```

The one glyph twist is that `inspect` prints `1` / `0` rather than `t` / `f`.
In a printed grid the letters `t` / `f` are two narrow shapes that are hard
to tell apart, while `1` / `0` read cleanly and line up with neighbouring
numeric columns. The values inside the array are still Ruby `true` / `false`;
printing is just cosmetic.

Everywhere you actually hold the values as Ruby objects — indexing, iterating,
collecting via `to_a`, pattern-matching — you get real Ruby booleans, so the
usual idioms just work:

```ruby
b.to_a.each { |v| do_something if v }         #  runs only where true
b.to_a.filter { |v| v }                        #  keeps the true cells
case b[i] in true then ... end                 #  pattern match works
```

The numeric encoding shows up when you deliberately ask for it — a cast to
`:int32` for counting, `Marshal` and the binary format for storage, MemoryView
for handing bytes to another library. Those paths carry raw `uint8` `0` / `1`
because that is what the receiving side needs.

## Constructing boolean arrays

```ruby
CA_BOOLEAN([1, 0, 1])              #  from a literal (1/0 or true/false)
CArray.boolean(3) { |i| i < 2 }    #  block returning truthy/falsy → [1, 1, 0]
CArray.boolean(2, 3)               #  uninitialised 2×3 boolean

CA_INT([3, 0, 5]) > 0              #  comparison → [1, 0, 1]   (the usual way)
CA_INT([1, 2, 3]).eq(CA_INT([1, 0, 3]))   #  element-wise equality → [1, 0, 1]
```

Comparisons are the normal source of boolean arrays; you rarely build one by
hand.

### Casting a numeric array to boolean is strict (only 0/1)

`to_type(CA_BOOLEAN)` / `#boolean` require the values to already be `0` or
`1` and **raise** otherwise — they do not "truthy-coerce":

```ruby
CA_INT([0, 1, 0]).to_type(CA_BOOLEAN)   #  => [0, 1, 0]   ✓
CA_INT([0, 3, 0]).to_type(CA_BOOLEAN)
#  RuntimeError: out of range to cast to boolean (0 or 1)
CA_INT([2, 0]).boolean                  #  same error
```

To turn an arbitrary numeric array into a truth array, use a **comparison**,
which is the operation that actually expresses your intent:

```ruby
x.ne(0)      #  "non-zero?"  → boolean
x > 0        #  "positive?"  → boolean
```

## Element access and assignment

Assignment accepts **both** `true` / `false` and the integers `1` / `0`. Any
other value raises.

```ruby
b = CArray.boolean(4)
b[0] = true      #  1
b[1] = 1         #  1
b[2] = false     #  0
b[3] = 0         #  0
b[0] = 2         #  CArray::DataTypeError: can't cast object '2' to <boolean>

b[]  = [1, 0, 1, 0]   #  bulk assign
b[]  = true           #  broadcast-fill with 1
```

## Logical operators — stay boolean

`&` (and), `|` (or), `^` (xor), and `~` / `not` (negation) are the
truth-logic operators. They return a boolean array.

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])
c = CA_BOOLEAN([1, 1, 0, 1, 0])

b & c       #  => [ 1, 0, 0, 1, 0 ]
b | c       #  => [ 1, 1, 1, 1, 0 ]
b ^ c       #  => [ 0, 1, 1, 0, 0 ]
~b          #  => [ 0, 1, 0, 0, 1 ]   (bitwise-not on 0/1 = logical negation)
b.not       #  => [ 0, 1, 0, 0, 1 ]   (same result, spelled as a method)
```

### `!b` and `b == c` are *not* element-wise

Two Ruby operators look like they should be element-wise but are not:

```ruby
!b          #  => false — Ruby's `!` on the object (b is not nil/false).
            #     For element-wise negation use ~b or b.not.

b == c      #  => false — WHOLE-ARRAY structural equality (one Ruby boolean).
b.eq(c)     #  => [ 1, 0, 0, 1, 1 ] — element-wise equality (a boolean array).
```

Use `~` / `.not` for per-cell negation and `.eq` for per-cell equality.
`==` and `!` follow ordinary Ruby object semantics and collapse to a single
value.

## Comparison operators — produce boolean

The ordering and equality comparisons (`>`, `<`, `>=`, `<=`, `.eq`, `.ne`)
all return a boolean array. On boolean operands, `false < true` (that is,
`0 < 1`):

```ruby
b > c        #  => [ 0, 0, 1, 0, 0 ]
b.eq(c)      #  => [ 1, 0, 0, 1, 1 ]
```

## Arithmetic — promotes to a numeric type

Here boolean behaves as its `0`/`1` storage. **Arithmetic between booleans
promotes to `int64`** — signed, so that `b1 - b2` can reach `-1`:

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])
c = CA_BOOLEAN([1, 1, 0, 1, 0])

b + c       #  int64   [ 2, 1, 1, 2, 0 ]
b - c       #  int64   [ 0, -1, 1, 0, 0 ]    ← negative, hence signed
-b          #  int64   [ -1, 0, -1, -1, 0 ]
b * 2       #  int64   [ 2, 0, 2, 2, 0 ]
b + 1.0     #  float64 [ 2.0, 1.0, 2.0, 2.0, 1.0 ]
```

Mixing boolean with a numeric operand follows ordinary type promotion
(`bool + float → float64`, and so on). The classic "mask-multiply" idiom
works because a comparison is a `0`/`1` array:

```ruby
(x > 0) * weights     #  zero out the cells where x <= 0
a + (a > threshold)   #  add 1 where the condition holds
```

Note that `& | ^` stay boolean; only the arithmetic operators (`+ - * / %
**`, unary `-`) promote. The dispatcher distinguishes them automatically —
you never choose.

## Reductions

Boolean reductions split into three groups by what they return.

### Value reductions → integer

`sum` / `prod` / `min` / `max` / `minmax` / `cumsum` / `cumprod` / `cummax` /
`cummin` return integer values in the `0`/`1` domain (`uint64`):

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])

b.sum          #  => 3       (count of true — sum is the anchor)
b.prod         #  => 0       (1 iff all true)
b.min          #  => 0       (Integer, NOT false)
b.max          #  => 1       (Integer, NOT true)
b.minmax       #  => [0, 1]
b.cumsum       #  => uint64 [ 1, 1, 2, 3, 3 ]   (running count of true)
b.sum(axis: 0) #  => a uint64 CArray

(x > 0).sum    #  count how many pass
```

`min` / `max` overlap in *meaning* with `all` / `any` but differ in *type*:
`b.min` is `Integer 0/1`, while `b.all` is `true` / `false`. Reach for
`all` / `any` when you want a boolean, `min` / `max` when you want a number.

### Ratio reductions → float

`mean` / `variance` / `variancep` / `stddev` / `stddevp` treat the array as
0/1 samples:

```ruby
b.mean        #  => 0.6      (proportion of true = (x > 0).mean)
b.variance    #  => 0.3      (sample variance of the 0/1 values)
b.stddev      #  => 0.5477...
```

`(x > 0).mean` — "what fraction passes" — is one of the most useful
one-liners in the language.

### Logical folds → boolean

`all` / `any` / `none` are the reductions that stay boolean, returning a
real Ruby `true` / `false`:

```ruby
b.all         #  => false
b.any         #  => true
b.none        #  => false
```

### `count` — how many equal a value

`count(v)` counts matching cells. On a boolean array it accepts `true` /
`false` **and the integer literals `1` / `0`** (since storage is 0/1);
anything else raises:

```ruby
b.count(true)   #  => 3
b.count(1)      #  => 3      (1 is an alias for true)
b.count(false)  #  => 2
b.count(0)      #  => 2
b.count(2)      #  TypeError: only true / false / 1 / 0 are accepted

b.count         #  => present-cell count (no argument)
b.count(UNDEF)  #  => number of masked cells
```

## Order operations — sort, index, rank

`false` sorts before `true` (`0 < 1`). Position-returning methods give index
arrays; the value-returning `sort` keeps the boolean data type:

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])

b.sort         #  boolean [ 0, 0, 1, 1, 1 ]   (a view)
b.sort_index   #  => [1, 4, 0, 2, 3]          (stable sort indices)
b.min_index    #  => 1   (position of the first false)
b.max_index    #  => 0   (position of the first true)
```

`sort` returns a view; materialise with `.copy`, or assign back for an
in-place sort:

```ruby
b[] = b.sort   #  in-place (there is no `sort!`)
```

## Masking and Kleene three-valued logic

A masked (`UNDEF`) boolean cell means **"unknown / excluded"**. In printing
it shows as `_`:

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])
b[1] = UNDEF
p b    #  => [ 1, _, 1, 1, 0 ]
```

### `&` and `|` are value-aware across masks

For most operators a masked input simply propagates — the result cell is
masked. But `&` and `|` follow **Kleene three-valued logic**: when the
*known* operand alone determines the answer, the result is defined even
though the other operand is unknown.

Let `U` stand for `UNDEF`. The two decisive cases:

| Expression   | Result  | Why                                  |
|--------------|---------|--------------------------------------|
| `U \| true`  | `true`  | OR is true if either side is true    |
| `U \| false` | `U`     | still unknown                        |
| `U & false`  | `false` | AND is false if either side is false |
| `U & true`   | `U`     | still unknown                        |

```ruby
a  = CA_BOOLEAN([1, 0, 1, 0]); a[0] = UNDEF; a[1] = UNDEF   # [U, U, 1, 0]
bT = CA_BOOLEAN([1, 1, 1, 1])    #  all true
bF = CA_BOOLEAN([0, 0, 0, 0])    #  all false

a | bT   #  => [ 1, 1, 1, 1 ]     U|true  = true   (mask cleared)
a | bF   #  => [ U, U, 1, 0 ]     U|false = U      (still masked)
a & bT   #  => [ U, U, 1, 0 ]     U&true  = U
a & bF   #  => [ 0, 0, 0, 0 ]     U&false = false  (mask cleared)
```

This holds identically on the lazy path (`a.lazy | b`) — eager and lazy give
the same result.

### `^`, `~`, `not` propagate the mask

XOR and negation cannot be decided from one side, so a masked input stays
masked:

```ruby
a ^ bT   #  => [ U, U, 0, 1 ]     masked cells stay masked
a.not    #  => [ U, U, 0, 1 ]     negation of unknown is unknown
```

### Folds over masked booleans: `skip_masked:`

By default `all` / `any` / `none` **skip** masked cells — the usual "skip
missing" convention, matching the reductions in
[Reduction and statistics](04_reduction_and_statistics.md) — so an array
whose known cells are all true reduces to `true`. Pass
`skip_masked: false` to fold in Kleene style instead, where an unknown cell
that could change the answer makes the result `UNDEF`:

```ruby
m = CA_BOOLEAN([1, 1, 1]); m[2] = UNDEF        # [true, true, U]
m.all                      #  => true    (default: skip the unknown)
m.all(skip_masked: false)  #  => UNDEF   (the unknown could be false)

n = CA_BOOLEAN([0, 0, 0]); n[2] = UNDEF        # [false, false, U]
n.any                      #  => false
n.any(skip_masked: false)  #  => UNDEF
```

### Scalar `UNDEF` operators are not (fully) supported

Kleene logic is implemented for **array** operands. A bare scalar `UNDEF` on
either side of `&` / `|` is a known rough edge:

```ruby
UNDEF | true    #  NoMethodError   (loud — at least it fails visibly)
true  & UNDEF   #  => true         (SILENTLY WRONG: Ruby's `true & x` treats
                #     any non-nil/false x as true; Kleene would say UNDEF)
```

Do Kleene logic on **arrays**, where it is correct, not on scalar `UNDEF`
values.

### Masked arithmetic just propagates

Outside `&` / `|`, a masked boolean flows through arithmetic like any masked
cell — the result cell is masked:

```ruby
bm = CA_BOOLEAN([1, 0, 1]); bm[1] = UNDEF
bm + 1   #  => [ 2, UNDEF, 2 ]   (mask carried through)
```

## Boolean indexing and masks

A boolean array selects or assigns the cells where it is true — the everyday
use of booleans, covered in [Indexing and slicing](02_indexing_and_slicing.md):

```ruby
data = CA_INT([10, 20, 30, 40])

data[data > 15]        #  => [ 20, 30, 40 ]     (gather where true)
data[data > 15] = 0    #  => [ 10, 0, 0, 0 ]    (scatter where true)
```

Masks are stored as boolean arrays too (see
[Masks and missing values](05_masks.md)), so the same truth type underlies
both selection and missing-value handling.

## Conversions

```ruby
b.to_type(CA_INT32)   #  => int32 [ 1, 0, 1 ]     (widen to integer for numeric use)
b.int32               #  => same
b.to_a                #  => [true, false, true]   (Ruby-land; see the two
                      #     representations above)

#  numeric → boolean is strict (0/1 only); use a comparison instead
x.ne(0)               #  arbitrary numeric → boolean
```

## Pitfall checklist

| Pitfall | Reality |
|---|---|
| `!b` for negation | `!b` is Ruby object negation → `false`. Use `~b` or `b.not`. |
| `b == c` for element-wise | `==` is whole-array equality (one boolean). Use `b.eq(c)`. |
| `b.min` returns a boolean | No — `min` / `max` / `sum` / … return **Integer**. `all` / `any` / `none` return boolean. |
| `b + b` stays boolean | No — arithmetic promotes to `int64`. `& \| ^` stay boolean. |
| `CA_INT([2, 0]).boolean` | Raises — the cast is strict 0/1. Use `x.ne(0)` / `x > 0`. |
| `inspect` shows `1`/`0` but `b[i]` is `true` | Both are correct; the printed glyphs are cosmetic. |
| `true & UNDEF` | Silently `true` (Ruby semantics). Do Kleene on arrays, not scalar `UNDEF`. |
| `count(1.0)` on boolean | Raises — only `true` / `false` / `1` / `0` are accepted. |

## Quick recap

- Boolean is `uint8` storage holding `0` / `1`; comparisons produce it, and
  indexing and masks consume it.
- Two representations, split by destination: any Ruby-land path (`b[i]`,
  `each`, `to_a`, pattern matching) returns Ruby `true` / `false`; numeric
  casts and serialize paths (`to_type(:int32)`, `Marshal`, MemoryView) carry
  raw `uint8` `0` / `1`. `inspect` prints `1` / `0` glyphs for legibility
  but the underlying values are still Ruby booleans.
- The logical family stays boolean (`& | ^ ~ not`, comparisons,
  `all` / `any` / `none`); everything numeric promotes — arithmetic to
  `int64`, value reductions to integer, ratio reductions to float.
- `(x > 0).sum` counts, `(x > 0).mean` gives a proportion,
  `(x > 0) * w` zeroes the failing cells.
- Casting numeric → boolean is strict (0/1 only); express intent with a
  comparison instead.
- Masked `&` / `|` are Kleene: the known side decides when it can
  (`U | true → true`, `U & false → false`); `^` and `not` propagate the
  mask; `all` / `any` / `none` skip masked cells by default and fold in
  Kleene style with `skip_masked: false`.
