# Conditional selection

CArray gathers four related tools for "pick a value per cell based on a
boolean condition" into one family. They all produce a new array with
the same shape as the input; they differ in **where the condition lives**
and **how the branches are supplied**.

| method | receiver | branches | evaluation | in one sentence |
|---|---|---|---|---|
| `cond.then_else(x, y)` | boolean CArray | 2 **values** | both eager | "if `cond` then `x` else `y`" |
| `self.replace_where(cond, b)` | value CArray | 1 replacement | eager | "copy of `self` with `cond` cells replaced by `b`" |
| `self.conditional(cond, f_then, f_else)` | value CArray | 2 **callables** | **per region** | "apply `f_then` to `self[cond]`, `f_else` to `self[cond.not]`" |
| `CArray.select(condlist, choicelist, default:)` | (class method) | N **values** | eager | "first-match multi-way CASE" |

All four live in [lib/carray/conditional.rb](../../lib/carray/conditional.rb)
and are loaded eagerly with the rest of `carray/basics`.

Everything below works after `require "carray"`.

---

## 1. `cond.then_else(x, y)` — boolean receiver, two values

The classic three-way pick: the receiver is a boolean CArray, and the
two branches are supplied as values.

```ruby
grade = CA_INT32([72, 45, 88, 60, 30, 95])
pass  = grade >= 60
pass.then_else(1, 0)
# => [1, 0, 1, 1, 0, 1]
```

Both branches are ordinary values (Numeric or CArray). They are
evaluated **eagerly and in full** — passing `f(x)` for the `then`
branch means `f(x)` runs over every cell, not just the ones where
`cond` is true. To carry arbitrary Ruby objects (Strings, Symbols),
wrap at least one branch in a `CA_OBJECT` array so the result
`data_type` resolves to `:object`:

```ruby
pass.then_else(CA_OBJECT(["PASS"] * grade.elements),
               CA_OBJECT(["FAIL"] * grade.elements))
# => ["PASS", "FAIL", "PASS", "PASS", "FAIL", "PASS"]
```

Mask rule: a masked cell in `cond` produces `UNDEF` in the result
(matches the receiver's mask semantics).

**When to reach for `then_else`:**

- Value 1 vs. value 2 (labels, sentinels, constants).
- Both branches are cheap to compute over the whole array.
- The condition is naturally computed first (`grade >= 60`,
  `sensor.online?`).

---

## 2. `self.replace_where(cond, b)` — patch just the true cells

Non-destructive form of `a[cond] = b`. Returns a copy of `self` with
cells where `cond` is true replaced by `b` (a scalar or same-shape
CArray).

```ruby
scores = CA_FLOAT64([12.5, -3.2, 88.0, -0.1, 42.0])
scores.replace_where(scores < 0, 0.0)
# => [12.5, 0.0, 88.0, 0.0, 42.0]
```

Unlike `then_else`, `replace_where` **preserves `self`'s `data_type`**;
the replacement is coerced into that type. Mask handling matches the
destructive indexer.

**When to reach for `replace_where`:**

- Sanitising outliers, clipping to a floor/ceiling.
- Overwriting a small subset while keeping the rest.
- Chain-friendly non-destructive form when `a[cond] = b` would mutate
  an operand you want to keep.

---

## 3. `self.conditional(cond, then_fn, else_fn)` — lazy per region

The complement of `then_else`. The **receiver is the value array**, and
the two branches are **callables** that see only their own subset:

```ruby
x = CArray.float64(6).span(-2.0..3.0)

y = x.conditional(x > 0,
                  ->(v) { v.log },       # only sees positive cells
                  ->(v) { -v })          # only sees non-positive cells

y.to_a
# => [2.0, 1.0, -0.0, 0.0, 0.6931..., 1.0986...]
```

The two callables get **just the cells they need**. `x.log` is *never*
called on a negative value — no `NaN`, no domain warning, no dummy fill
gymnastics. This is the safe way to write piecewise functions whose
branches have restricted domains.

Compare with the eager alternative:

```ruby
# Eager form has to compute log(x) on the *whole* array.
safe = x.copy
safe[x <= 0] = 1.0                       # dummy fill to avoid domain error
(x > 0).then_else(safe.log, -x)
```

Rules:

- `cond` must be a same-shape boolean CArray.
- Each callable can return a CArray (matching the subset shape) or a
  scalar (broadcast to the subset).
- Result `data_type` is `CArray.result_type(y_then, y_else)`, or the
  explicit `data_type:` keyword when given.
- Masked cells in `cond` propagate to `UNDEF` in the result.

**When to reach for `conditional`:**

- One branch has a restricted domain (`log`, `sqrt`, integer division
  by cell-dependent divisor, table lookup that only works on valid
  labels).
- Branch evaluation is *expensive* and you want to skip the unused
  region.
- You want a functional per-region primitive rather than an in-place
  scatter.

Performance is close to the eager evaluate-then-mask form (~5% slower
at N=1M in a mixed-domain test), and it drops the dummy-fill boilerplate.

---

## 4. `CArray.select(condlist, choicelist, default:)` — N-way CASE

Multi-way ternary select. For each cell, picks the value from the first
`choicelist[k]` whose matching `condlist[k]` is true. Falls back to
`default` where no condition holds.

```ruby
x = CArray.float64(6).span(-5.0..5.0)

CArray.select([x < 0, x < 2],
              [-x,    x * 10],
              default: 999)
# => [5.0, 3.0, 1.0, 10.0, 999.0, 999.0]
```

Priority is **left-to-right in `condlist`**: when several conditions
are true at the same cell, the **earliest one wins** (first-match
semantics, same as `np.select`).

Rules:

- `condlist` and `choicelist` are Arrays of equal length (≥ 1).
- Every entry in `condlist` is a same-shape boolean CArray.
- Each `choicelist[k]` is either a same-shape CArray or a scalar
  broadcast to every cell.
- Result `data_type` is the promotion of every choice plus `default`
  via `CArray.result_type`, or the explicit `data_type:`.

**When to reach for `CArray.select`:**

- Three or more branches (`then_else` and `conditional` are strictly
  two-way).
- All branches are eager values (no domain-safety concerns).
- Classification into a discrete set of outputs.

For classifications with restricted-domain branches, chain
`conditional` calls or pre-compute safe intermediates and feed them
into `select`.

---

## 5. Choosing between the four

| you have | you want | reach for |
|---|---|---|
| a boolean CArray and two values | pick per cell | `cond.then_else(x, y)` |
| a value CArray and one replacement | patch true cells only | `self.replace_where(cond, b)` |
| a value CArray and two branch **functions**, one with a limited domain | apply each function to its own region | `self.conditional(cond, f_then, f_else)` |
| N conditions, N choice values, first-match semantics | multi-way CASE | `CArray.select(condlist, choicelist, default:)` |

Or, following the "who computes what where":

```
                     branches are…
                   +-----------------+---------------------+
                   |    VALUES       |     CALLABLES       |
+------------------+-----------------+---------------------+
| BOOLEAN receiver | then_else       |  (n/a: pass a       |
| = "cond first"   |                 |   callable's result |
|                  |                 |   to then_else)     |
+------------------+-----------------+---------------------+
| VALUE receiver   | replace_where   | conditional         |
| = "data first"   |   (1 branch)    |   (2 branches,      |
|                  | select          |    per-region)      |
|                  |   (N branches)  |                     |
+------------------+-----------------+---------------------+
```

`conditional` is the only entry point that runs a callable on a
**subset** of the data — the domain-safety property comes from that
alone.

---

## 6. Application patterns

Some concrete uses. Every example is self-contained.

### 6.1 Sanitise negatives to zero (floor)

```ruby
data.replace_where(data < 0, 0.0)
```

### 6.2 Clip to a symmetric range

```ruby
CArray.select([x < -1.0, x > 1.0],
              [-1.0,      1.0],
              default: x)
```

`clip` in the standard library covers this — use `select` when the
per-branch value depends on the cell (e.g. `[-x, x/2]`).

### 6.3 Domain-safe log with a fallback

```ruby
x.conditional(x > 0,
              ->(v) { v.log },              # only sees positives
              ->(_) { Float::NAN })         # marks non-positives as NaN
```

Or with a mask instead of NaN:

```ruby
x.conditional(x > 0,
              ->(v) { v.log },
              ->(_) { UNDEF })
```

### 6.4 Piecewise polynomial / analytic definition

Absolute value via `conditional` (illustration; `abs` is a builtin):

```ruby
x.conditional(x >= 0,
              ->(v) { v },
              ->(v) { -v })
```

Soft-plus, numerically stable:

```ruby
# log(1 + e^x)  ─ for large x this overflows; conditional keeps the fast
# path on the safe side.
x.conditional(x < 20,
              ->(v) { (1 + v.exp).log },
              ->(v) { v })                  # for v >> 0, log(1+e^v) ≈ v
```

### 6.5 Grade → letter classification

```ruby
grade = CA_INT32([95, 72, 45, 88, 60, 30, 82])

# Numeric tier: A=4, B=3, C=2, D=1, F=0
CArray.select([grade >= 90, grade >= 80, grade >= 70, grade >= 60],
              [4,           3,           2,           1],
              default: 0)
# => [4, 2, 0, 3, 1, 0, 3]
```

Note the priority: an `A` cell (grade ≥ 90) is also true for `≥ 80`
and `≥ 70`, so the order in `condlist` matters. Highest priority first.

For letter labels, wrap at least one choice in `CA_OBJECT` so the
result `data_type` becomes `:object`:

```ruby
n = grade.elements
CArray.select([grade >= 90, grade >= 80, grade >= 70, grade >= 60],
              [CA_OBJECT(["A"] * n),
               CA_OBJECT(["B"] * n),
               CA_OBJECT(["C"] * n),
               CA_OBJECT(["D"] * n)],
              default: CA_OBJECT(["F"] * n))
# => ["A", "C", "F", "B", "D", "F", "B"]
```

### 6.6 Label-based masking with a lookup fallback

```ruby
# valid_labels is a small set; unknown labels get UNDEF.
labels.conditional(labels.is_in(valid_labels),
                   ->(v) { table.project(v) },   # only run on valid labels
                   ->(_) { UNDEF })
```

Same idea as domain-safe log: the lookup only sees inputs known to be
in `valid_labels`.

### 6.7 Sign function (three-way partition)

```ruby
CArray.select([x < 0, x > 0],
              [-1,     1],
              default: 0)
```

### 6.8 Windsorise (clip to per-cell bounds)

```ruby
CArray.select([x < lo, x > hi],
              [lo,     hi],
              default: x)
```

Where `lo`, `hi` are cell-wise bounds (e.g. per-column median ± k·σ
broadcast to `x`'s shape).

### 6.9 Nested piecewise (three-branch domain-safe)

`conditional` is 2-branch by design. For three-branch domain-safe
piecewise, nest:

```ruby
# x < 0 -> -x, 0 <= x < 1 -> x, x >= 1 -> log(x)
x.conditional(x < 0,
              ->(v) { -v },
              ->(v) {
                v.conditional(v >= 1,
                              ->(w) { w.log },     # safe: w >= 1
                              ->(w) { w })         # 0 <= w < 1
              })
```

An N-branch domain-safe primitive is not in the family; nest
`conditional`, or pre-compute safe intermediates and feed them into
`CArray.select`.

---

## 7. Rules of thumb

- Prefer `then_else` when the condition is already a boolean and both
  branches are cheap values.
- Prefer `replace_where` for "leave most of it alone".
- Prefer `conditional` when a branch has a restricted domain, or when
  branch evaluation is expensive and you want to skip the unused side.
- Prefer `CArray.select` for three or more discrete outputs with
  first-match priority.

All four propagate `UNDEF` through their condition inputs, so masked
data flows through naturally without extra handling on your side.
