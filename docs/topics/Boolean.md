# Boolean — the 0/1 truth type

CArray's `:boolean` data type is a **one-byte-per-cell truth type whose storage is
`uint8` holding the values `0` and `1`**. It is what every comparison produces
(`a > 0`, `a.eq(b)`, …) and what masks and boolean indexing are built on.

The single rule that governs its whole surface is:

> **Boolean participates in every numeric / order kernel as its `0`/`1` numeric
> storage, and those kernels return a numeric result. The operations that stay
> boolean are the *logical* family: `all` / `any` / `none`, the bitwise
> `& | ^ ~` / `not`, and the comparison operators.**

Boolean is a normal `CArray` (`CArray.boolean(...)` builds one; there is no
separate class), so slicing, masking, reshaping, iteration, and serialization
all work as on any other array. This document focuses on the parts that are
*easy to get wrong* — chiefly the three different ways a boolean cell is shown,
and how masking turns `&` / `|` into three-valued (Kleene) logic.

---

## 1. Two representations, one boundary

A boolean cell has two representations, split by where the value goes:

| Where you meet it | What you get | Example |
|---|---|---|
| **Ruby-land** (`inspect` printing, `b[i]`, `each`, `each_with_addr`, `elem_fetch`, CScalar `value`, `to_a`) | Ruby `true` / `false` (printed as `1` / `0`) | `b[0]` → `true`, `b.to_a` → `[true, false, true, true, false]` |
| **Numeric cast / serialize** (`to_type(numeric)`, `Marshal`, `.ca` save, MemoryView export, cast_table `BOOL2OBJ` for `to_type(:object)`) | `uint8` `0` / `1` (raw storage) | `b.to_type(:int32).to_a` → `[1, 0, 1, 1, 0]` |

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])

p b                     # => shows [ 1, 0, 1, 1, 0 ]   (inspect: 1/0 glyphs for legibility)
b[0]                    # => true                       (Ruby-land)
b[1]                    # => false
b.to_a                  # => [true, false, true, true, false]
b.each { |v| v }        # yields true, false, true, true, false
b.to_type(:int32).to_a  # => [1, 0, 1, 1, 0]           (numeric cast keeps 0/1)
```

Why this split:

- **Any path that hands a value to Ruby returns `true`/`false`** — including
  `b.to_a` — so Ruby idioms (`if v`, `case v in true`, `.filter { |v| v }`,
  `.each { |v| ... if v }`) work directly on both the CArray and the collected
  Array. This unifies `each` and `to_a` under the same rule and eliminates the
  historical trap where `if b.to_a[i]` was silently true even on `false` cells
  (because Ruby considers Integer `0` truthy).
- **Numeric casts and serialize paths keep the raw `uint8` `0`/`1`** because
  their downstream is numeric — a count via `to_type(:int32).sum`, bytes on
  disk, or a MemoryView consumer. Inventing a boolean encoding at that
  boundary would break the round-trip.
- **`inspect` prints `1`/`0` for readability.** The letters `t`/`f` are two
  narrow lowercase glyphs that share strokes and are hard to tell apart in a
  grid; `1`/`0` read cleanly and line up with neighbouring numeric columns.
  The values inside the array are still Ruby booleans — the printing is
  cosmetic. (Earlier 3.x previews printed `t`/`f`; that was reverted.)

---

## 2. Constructing boolean arrays

```ruby
CA_BOOLEAN([1, 0, 1])              # from a literal (1/0 or true/false)
CArray.boolean(3) { |i| i < 2 }    # block returning truthy/falsy → [1,1,0]
CArray.boolean(2, 3)               # uninitialised 2×3 boolean

CA_INT([3, 0, 5]) > 0              # comparison → boolean [1,0,1]   (the usual way)
CA_INT([1, 2, 3]).eq(CA_INT([1, 0, 3]))   # elementwise equality → [1,0,1]
```

Comparisons are the normal source of boolean arrays; you rarely build one by
hand.

### ⚠️ Casting a numeric array to boolean is strict (only 0/1)

`to_type(CA_BOOLEAN)` / `#boolean` require the values to already be `0` or `1`
and **raise** otherwise — they do not "truthy-coerce":

```ruby
CA_INT([0, 1, 0]).to_type(CA_BOOLEAN)   # => [0, 1, 0]   ✓
CA_INT([0, 3, 0]).to_type(CA_BOOLEAN)   # RuntimeError: out of range to cast to boolean (0 or 1)
CA_INT([2, 0]).boolean                  # same error
```

To turn an arbitrary numeric array into a truth array, use a **comparison**,
which is the operation that actually expresses your intent:

```ruby
x.ne(0)      # "non-zero?"  → boolean
x > 0        # "positive?"  → boolean
```

---

## 3. Element access and assignment

Assignment accepts **both** `true`/`false` and the integers `1`/`0`. Any other
value raises.

```ruby
b = CArray.boolean(4)
b[0] = true      # 1
b[1] = 1         # 1
b[2] = false     # 0
b[3] = 0         # 0
b[0] = 2         # CArray::DataTypeError: can't cast object '2' to <boolean>

b[]  = [1, 0, 1, 0]   # bulk assign
b[]  = true           # broadcast-fill with 1
```

---

## 4. Logical operators — stay boolean

`&` (and), `|` (or), `^` (xor), and `~` / `not` (negation) are the truth-logic
operators. They **return a boolean array**.

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])
c = CA_BOOLEAN([1, 1, 0, 1, 0])

(b & c)     # boolean [1, 0, 0, 1, 0]
(b | c)     # boolean [1, 1, 1, 1, 0]
(b ^ c)     # boolean [0, 1, 1, 0, 0]
(~b)        # boolean [0, 1, 0, 0, 1]   (bitwise-not on 0/1 = logical negation)
b.not       # boolean [0, 1, 0, 0, 1]   (same result, spelled as a method)
```

### ⚠️ `!b` and `b == c` are *not* elementwise

Two Ruby operators look like they should be elementwise but are not:

```ruby
!b          # => false   — Ruby's `!` on the object (b is not nil/false → !b is false).
            #              For elementwise negation use ~b or b.not.

b == c      # => false   — WHOLE-ARRAY structural equality (one Ruby boolean).
b.eq(c)     # => [1,0,0,1,1]   — elementwise equality (a boolean array).
```

Use `~` / `.not` for per-cell negation and `.eq` for per-cell equality. `==` and
`!` follow ordinary Ruby object semantics and collapse to a single value.

---

## 5. Comparison operators — produce boolean

The ordering / equality comparisons (`>`, `<`, `>=`, `<=`, `.eq`, `.ne`) all
return a boolean array (`false < true`, i.e. `0 < 1`):

```ruby
b > c        # boolean [0, 0, 1, 0, 0]
b.eq(c)      # boolean [1, 0, 0, 1, 1]
```

---

## 6. Arithmetic — promotes to a numeric type

Here boolean behaves as its `0`/`1` storage. **Arithmetic between booleans
promotes to `int64`** — signed, so that `b1 - b2` can reach `-1`:

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])
c = CA_BOOLEAN([1, 1, 0, 1, 0])

(b + c)     # int64  [2, 1, 1, 2, 0]
(b - c)     # int64  [0, -1, 1, 0, 0]     ← negative, hence signed
(-b)        # int64  [-1, 0, -1, -1, 0]
(b * 2)     # int64  [2, 0, 2, 2, 0]
(b + 1.0)   # float64 [2.0, 1.0, 2.0, 2.0, 1.0]   (bool + float → float)
```

Mixing boolean with a numeric operand follows ordinary type promotion
(`bool + float → float64`, etc.). The classic "mask-multiply" idiom works
because a comparison is a `0`/`1` array:

```ruby
(x > 0) * weights    # zero out the cells where x <= 0
a + (a > threshold)  # add 1 where the condition holds
```

> Note: `& | ^` stay boolean (§4); only the arithmetic operators
> (`+ - * / % **`, unary `-`) promote. The dispatcher distinguishes them
> automatically — you never choose.

---

## 7. Reductions

Boolean reductions split into three groups by what they return.

### Value reductions → `uint64` (Integer)

`sum` / `prod` / `min` / `max` / `minmax` / `cumsum` / `cumprod` / `cummax` /
`cummin` return integer `0`/`1`-domain values (`u64`):

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])

b.sum          # => 3       (count of true — sum is the anchor)
b.prod         # => 0       (1 iff all true)
b.min          # => 0       (Integer, NOT false)
b.max          # => 1       (Integer, NOT true)
b.minmax       # => [0, 1]
b.cumsum       # => uint64 [1, 1, 2, 3, 3]   (running count of true)
b.sum(axis: 0) # => a uint64 CArray

(x > 0).sum    # count how many pass
```

`min` / `max` overlap in *meaning* with `all` / `any` but differ in *type*:
`b.min` is `Integer 0/1`, while `b.all` is `true`/`false`. Reach for `all`/`any`
when you want a boolean, `min`/`max` when you want a number.

### Ratio reductions → `float64`

`mean` / `variance` / `variancep` / `stddev` / `stddevp` treat the array as
Bernoulli 0/1 samples:

```ruby
b.mean        # => 0.6     (proportion of true = (x > 0).mean)
b.variance    # => 0.3     (sample variance of the 0/1 values)
b.stddev      # => 0.5477...
```

### Logical folds → `boolean`

`all` / `any` / `none` are the reductions that stay boolean:

```ruby
b.all         # => false   (TrueClass/FalseClass, a real Ruby boolean)
b.any         # => true
b.none        # => false
```

### `count` — how many equal a value

`count(v)` counts matching cells. On a boolean array it accepts `true`/`false`
**and the integer literals `1`/`0`** (since storage is 0/1); anything else
raises:

```ruby
b.count(true)   # => 3
b.count(1)      # => 3      (1 is an alias for true)
b.count(false)  # => 2
b.count(0)      # => 2
b.count(2)      # TypeError: v must be true / false / 1 / 0
b.count(1.0)    # TypeError  (1.0 is a Float, not one of true/false/1/0)

b.count         # => present-cell count (no argument)
b.count(UNDEF)  # => number of masked cells
```

---

## 8. Order operations — sort, argmin, rank

`false` sorts before `true` (`0 < 1`). Position-returning methods give indices;
value-returning `sort` keeps the boolean dtype.

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])

b.sort         # boolean [0, 0, 1, 1, 1]   (a view; inspect shows 0/1)
b.sort_index   # => [1, 4, 0, 2, 3]        (stable argsort, index array)
b.min_index    # => 1   (position of the first false)
b.max_index    # => 0   (position of the first true)
```

`sort` returns a view (`CARemap`); materialise with `.copy`, or assign back for
an in-place sort:

```ruby
b[] = b.sort   # in-place (there is no `sort!`)
```

---

## 9. Masking and Kleene three-valued logic

A masked (`UNDEF`) boolean cell means **"unknown / excluded"**. In printing it
shows as `_`:

```ruby
b = CA_BOOLEAN([1, 0, 1, 1, 0])
b[1] = UNDEF
p b    # => [ 1, _, 1, 1, 0 ]
```

### `&` and `|` are Kleene (value-aware) across masks

For most operators a masked input simply propagates (the result cell is masked).
But `&` and `|` follow **Kleene three-valued logic**: when the *known* operand
alone determines the answer, the result is defined even though the other operand
is unknown.

Let `U` = `UNDEF`. The two decisive cases:

| Expression | Result | Why |
|---|---|---|
| `U \| true` | `true` | OR is true if either side is true |
| `U \| false` | `U` | still unknown |
| `U & false` | `false` | AND is false if either side is false |
| `U & true` | `U` | still unknown |

```ruby
a  = CA_BOOLEAN([1, 0, 1, 0]); a[0] = UNDEF; a[1] = UNDEF   # [U, U, 1, 0]
bT = CA_BOOLEAN([1, 1, 1, 1])   # all true
bF = CA_BOOLEAN([0, 0, 0, 0])   # all false

a | bT   # => [1, 1, 1, 1]        U|true  = true   (mask cleared)
a | bF   # => [U, U, 1, 0]        U|false = U       (still masked)
a & bT   # => [U, U, 1, 0]        U&true  = U
a & bF   # => [0, 0, 0, 0]        U&false = false  (mask cleared)
```

This holds identically on the **lazy** path (`a.lazy | b`) — eager and lazy give
the same result.

### `^`, `~`, `not` propagate the mask

XOR and negation cannot be decided from one side, so a masked input stays masked:

```ruby
a ^ bT   # => [U, U, 0, 1]     masked cells stay masked
a.not    # => [U, U, 0, 1]     negation of unknown is unknown
```

### Folds over masked booleans: `skip_masked:`

By default `all` / `any` / `none` **skip** masked cells (the usual "skip missing"
convention), so an all-known-true-so-far array reduces to `true`. Pass
`skip_masked: false` to fold in Kleene style, where an unknown cell that could
change the answer makes the result `UNDEF`:

```ruby
m = CA_BOOLEAN([1, 1, 1]); m[2] = UNDEF        # [true, true, U]
m.all                      # => true    (default: skip the unknown)
m.all(skip_masked: false)  # => UNDEF   (the unknown could be false)

n = CA_BOOLEAN([0, 0, 0]); n[2] = UNDEF        # [false, false, U]
n.any                      # => false
n.any(skip_masked: false)  # => UNDEF
```

### ⚠️ Scalar `UNDEF` operators are not (fully) supported

Kleene logic is implemented for **array** operands. A bare scalar `UNDEF` on
either side of `&` / `|` is a known rough edge:

```ruby
UNDEF | true    # NoMethodError   (loud — at least it fails visibly)
true  & UNDEF   # => true         (SILENTLY WRONG: Ruby's `true & x` treats any
                #                   non-nil/false x as true; Kleene would say UNDEF)
```

Do Kleene logic on **arrays**, where it is correct, not on scalar `UNDEF`
values. (Full scalar three-valued operators are deferred.)

### Masked arithmetic just propagates

Outside `&`/`|`, a masked boolean flows through arithmetic like any masked cell —
the result cell is masked:

```ruby
bm = CA_BOOLEAN([1, 0, 1]); bm[1] = UNDEF
(bm + 1)   # => [2, UNDEF, 2]   (mask carried through)
```

---

## 10. Boolean indexing and masks

A boolean array selects or assigns the cells where it is true — the everyday use
of booleans:

```ruby
data = CA_INT([10, 20, 30, 40])

data[data > 15]        # => [20, 30, 40]   (gather where true)
data[data > 15] = 0    # => [10, 0, 0, 0]  (scatter where true)
```

Masks are stored as boolean arrays too, so the same truth type underlies both
selection and missing-value handling.

---

## 11. Conversions

```ruby
b.to_type(CA_INT32)   # => int32  [1, 0, 1]      (widen to integer for numeric use)
b.int32               # => same
b.to_a                # => [true, false, true]   (Ruby-land, see §1)

# numeric → boolean is strict (0/1 only); use a comparison instead (§2)
x.ne(0)               # arbitrary numeric → boolean
```

---

## 12. Pitfall checklist

| Pitfall | Reality |
|---|---|
| `inspect` shows `1`/`0` but `b[i]` is `true` | Both are correct; the printed glyphs are cosmetic. |
| `!b` for negation | `!b` is Ruby object negation → `false`. Use `~b` or `b.not`. |
| `b == c` for elementwise | `==` is whole-array equality (one boolean). Use `b.eq(c)`. |
| `b.min` returns a boolean | No — `min`/`max`/`sum`/… return **Integer** (`u64`). `all`/`any`/`none` return boolean. |
| `b + b` stays boolean | No — arithmetic promotes to `int64`. `& | ^` stay boolean. |
| `CA_INT([2,0]).boolean` | Raises — cast is strict 0/1. Use `x.ne(0)` / `x > 0`. |
| `inspect` shows `1`/`0` but `b[i]` is `true` | Both are correct; they are different views (§1). |
| `true & UNDEF` | Silently `true` (Ruby semantics). Do Kleene on arrays, not scalar `UNDEF`. |
| `count(1.0)` on boolean | Raises — only `true`/`false`/`1`/`0` are accepted. |

## See also

- [CAFace.md](CAFace.md) — masks and view semantics that boolean arrays plug into.
- [CastAndPromote.md](../authoring/CastAndPromote.md) — the type-promotion rules that decide
  `bool + int → int64`, `bool + float → float64`, etc.
