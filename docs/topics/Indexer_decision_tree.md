# CArray indexer reference

`CArray.scan_index(dim, idx)` classifies a Ruby-level index expression
(the array of arguments passed to `[]` or `[]=`) into one of CArray's
*index regions* and returns a structured description of it. This
document enumerates every input pattern the classifier recognises,
the region it produces, and the format of the returned index payload.

This is a wire-format reference. The intended audience is gem
authors who wrap CArray and need to translate CArray's `[]` syntax
into another representation — for example, a NetCDF variable wrapper
that turns a `ca[i, 0..3, nil]` call into a `start` / `count` / `stride`
triple for the NetCDF library. Casual users normally do not need it.

The Ruby return shape is:

```ruby
info = CArray.scan_index(dim, idx)
info.type     # one of the CA_REG_* constants (see §1)
info.index    # payload — shape depends on info.type (see §4)
```

---

## 1. Terminology

- `ndim` — dimensionality of the target CArray (`dim.size`).
- `argc` — number of arguments passed (`idx.size`).
- `arg`, `argv[i]` — the i-th index argument.
- `cs` — when `argv[i]` is itself a CArray, its contents.
- `info.type` — one of:
  `CA_REG_ALL`, `_ADDRESS`, `_FLATTEN`, `_ADDRESS_COMPLEX`,
  `_POINT`, `_BLOCK`, `_SELECT`, `_ITERATOR`, `_REPEAT`,
  `_GRID`, `_MAPPING`, `_METHOD_CALL`, `_MEMBER`.
- `info.index_type[i]` — when populated, one of `CA_IDX_SCALAR`,
  `_ALL`, `_BLOCK`, `_SYMBOL`, `_REPEAT`.
- `CA_IDX_REPEAT` is not produced by the classifier directly: when
  `:%` is detected, `info.type` is set to `REPEAT` and per-axis
  classification is skipped, so `index_type[]` is left unpopulated.

---

## 2. Top-level dispatch

The classifier first inspects `argc` and returns early for several
shapes.

### 2.1 `argc == 0` → `CA_REG_ALL`

```ruby
ca[]   # info.type = ALL, info.index = []
```

### 2.2 `argc == 1`, shape-independent special cases

Evaluated in order; the first match wins.

| condition                                                    | region          | `info.index`                       |
|--------------------------------------------------------------|-----------------|------------------------------------|
| `argv[0]` is `Symbol`, `strlen(sym) > 1`                     | `METHOD_CALL`   | `[]` (`info.symbol = arg`)         |
| `argv[0] == false` or `:~`                                   | `ALL`           | `[]`  (`:~` = rubber sigil, RB.1)  |
| `argv[0]` is integer CArray, `ndim == 1`, `cs.ndim == 1`     | `GRID`          | `[]`                               |
| `argv[0]` is integer CArray (other shape)                    | `MAPPING`       | `[]`                               |
| `argv[0]` is boolean CArray of the array's shape, or 1-D with `cs.elements == ca.elements` | `SELECT` | `[]` (`info.select = cs`) |
| `argv[0]` is boolean CArray of another shape (more than one axis) | raises `ArgumentError` | —                       |
| `argv[0]` is 1-D boolean CArray, element count mismatch      | raises `ArgumentError` | —                            |
| `argv[0]` is CArray of any other data_type                   | raises `IndexError`   | —                            |
| `argv[0]` is a `String`                                      | `MEMBER`        | `[]` (`info.symbol = :"field"`)    |

`METHOD_CALL` is not a table of accepted keys: downstream it evaluates
`a[:m, x]` as `a[a.m(x)]` — the symbol is sent to the receiver with the
remaining arguments and the answer is re-entered as the index. Only a
public method is called, as `a.m(x)` written out would reach one, so
`a[:puts]` raises `NoMethodError` rather than running `Kernel#puts`. The
length test is the whole gate, so a single-character symbol never reaches
it.  The arguments after the symbol are the method's, whatever they are:
`:_`, `:>` and the other index markers among them are passed to the
method, not read as markers.  A method that returns a Ruby Array has it
read as a list of keys, one per axis (`a[:m]` returning `[1, 2]` is
`a[1, 2]`), so a method can return a key for every axis; a CArray it
returns is read as one key.  `a[:m, x] = v` computes the index the same
way and stores through it, writing only the cells it picks.

### 2.3 `argc == 1`, `ndim > 1`

| condition                                  | region              | `info.index`                       |
|--------------------------------------------|---------------------|------------------------------------|
| `argv[0]` is `Integer` or `Float`          | `ADDRESS`           | `[addr]` (the key read as `key(v)`, §3.3.1) |
| `argv[0] == nil`                           | `FLATTEN`           | `[]`                               |
| anything else (`Range`, `ArithSeq`, `Array`, …) | `ADDRESS_COMPLEX` | `[[start, count, step]]` (see §2.4) |

When `argc == 1`, `ndim == 1`, and `argv[0]` is an `Integer` or `Float`, none of
the above match and the call falls through to the main loop (§3),
where it is classified as `POINT` with a single SCALAR axis.

### 2.4 `ADDRESS_COMPLEX` projection

`ADDRESS_COMPLEX` is the region used when a single non-integer index
addresses the flattened array. The `[start, count, step]` triple in
`info.index[0]` is obtained by a recursive scan in flat (1-D)
address space:

```ruby
CArray.scan_index([3, 3], [1..2])
# => type = ADDRESS_COMPLEX, index = [[1, 2, 1]]
```

---

## 3. Main loop

Reached when `argc >= 1` and none of the §2 special cases applied.

### 3.1 Pre-scan for special symbols

The full `argv` is scanned once for three symbols:

```
for i in 0..argc-1:
  if argv[i] == :%    → is_repeat = 1; break
  if argv[i] == false or :~ → has_rubber = 1   # :~ = rubber sigil (RB.1)
    if argc > ndim + 1 → raise IndexError
```

`:%` may appear at any position; the first occurrence ends the scan
and pins the region:

- `:%` anywhere → `REPEAT`, `info.index = []`.

### 3.2 Arity validation

```
if !has_rubber && ndim != argc
  raise IndexError
```

### 3.3 Per-axis classification

Each `argv[i]` is classified, populating `info.index_type[i]` and
`info.index[i]`.

| `argv[i]`                                       | `index_type`        | `index[i]` payload                          | error path                                   |
|-------------------------------------------------|---------------------|---------------------------------------------|----------------------------------------------|
| `Integer` or `Float`                            | `SCALAR`            | `scalar = key(v)` (§3.3.1, negative normalised) | `IndexError` on out-of-range (an Integer past int64 included) and on a `Float` that is not an exact integer |
| `nil`                                           | `ALL`               | none                                        | —                                            |
| `false` or `:~`                                 | rubber expansion: fill `rndim = ndim - argc + 1` axes with `ALL` (`:~` = rubber sigil, RB.1; `false` legacy) | — | —                  |
| `Range`                                         | `BLOCK`             | `{start, count, step = ±1}` (see §3.3.1)    | range check; an empty range (`2...2`, or `2..` at the end) is `{start, 0, 1}` and may start at the end of the axis |
| `Enumerator::ArithmeticSequence`                | `BLOCK`             | `{start, count, step}` (step from the seq)  | `step == 0` raises `ArgumentError`            |
| `[nil]`                                         | `ALL`               | none                                        | —                                            |
| `[Range]`                                       | (re-enters Range path) | —                                        | —                                            |
| `[Integer]`                                     | `BLOCK`             | `{start = k, count = 1, step = 1}`          | range check                                  |
| `[nil, step]`                                   | `BLOCK`             | `{start = 0, count = (dim-1)/step + 1, step}`; a negative step reads the first cell only; `count = 0` when `dim == 0` | `step == 0` raises                           |
| `[Range, step]`                                 | `BLOCK`             | `{start, count, step}`                      | range check; `step == 0` raises              |
| `[start, count]`                                | `BLOCK`             | `{start, count, step = 1}`                  | range check on `start` and `start+count-1`; with `count == 0` `start` may be the end of the axis |
| `[start, count, step]`                          | `BLOCK`             | `{start, count, step}`                      | range check; `step == 0` raises              |
| `Array` of any other length                     | raises `IndexError` | —                                           | —                                            |
| `:>`                                            | `SYMBOL`            | `{id = :>, spec = nil}`                     | slab-axis (iterator) marker (SI.2)           |
| `:_`                                            | raises `IndexError` | —                                           | newaxis — handled at `[]` / `[]=`, not here  |
| any other `Symbol`                              | raises `IndexError` | —                                           | (use `:>` instead)                           |
| boolean / integer CArray                        | sets `is_grid = 1`, breaks the loop | —                           | — (see §3.6)                                 |
| CArray of any other data_type                   | raises `IndexError` | —                                           | —                                            |
| anything else                                   | raises `IndexError` | —                                           | —                                            |

#### 3.3.1 Range / ArithmeticSequence detail

```
iv_beg = arg.begin    (nil → start = 0)
iv_end = arg.end      (nil → last = -1)
iv_excl = arg.exclude_end?

start = key(iv_beg)   or 0
last  = key(iv_end)   or -1
excl  = RTEST(iv_excl)
step  = key(arg.step) if ArithmeticSequence,
        else ±1 (+1 when last >= start, -1 otherwise)

key(v): the one rule for a key that names a position, a scalar key
        included.  Positions are int64 (ca_size_t):
        - an Integer that fits int64, Bignum included, is that position
          (an axis of a view that holds no memory can be longer than a
          Fixnum reaches); the range check is the usual one
        - an Integer past int64 is past every axis: out of range
          (IndexError) as an endpoint or a scalar key, and a step larger
          than any axis (one cell) as a step
        - a Float with no fraction and |v| <= 2**53 is that integer (a
          count from `sum` is a Float); past 2**53 a Float cannot tell
          neighbouring integers apart, so it raises IndexError as an
          invalid key, as a Float with a fraction, NaN or Inf does
        - anything else raises IndexError
        A Float CArray is not an index array.

if dim[i] == 0: a range starting at 0 reads no cells; any other start
                is out of range

if last < 0: last += dim[i]      # plain addition, no bounds check

if (excl && start == last) || (iv_end is nil && start == dim[i]):
  # no cells: the start may be the end of the axis, 0 <= start <= dim[i]
  index[i].block = {start, count = 0, step = 1}
else:
  normalise and bounds-check start  (0 <= start < dim[i])
  if excl: last += (last >= start ? -1 : +1)
  bounds-check last
  count = |last - start| / |step| + 1
  bounds-check start + (count - 1) * step
  index[i].block = {start, count, step}
```

With an explicit step (an ArithmeticSequence or `[range, step]`) the
step says the direction, as it does in Ruby: a step that points away
from the end reads no cells (`(0..4).step(-1)`), and an endless one with
a negative step goes down to the first cell (`3.step(by: -1)` reads 3,
2, 1, 0).  A plain Range has no step, and one that ends before it starts
reads backwards.

### 3.6 Keys beside a CArray (`GRID`)

When a CArray is among the keys, the region is a grid (or, for a boolean
on axis 0 with plain keys elsewhere, the faster `CASelectAxis`).  Every
key that is not a CArray is read exactly as above, so a key picks the
same cells whichever view is built:

- an Integer picks one cell and drops its axis (`a[i, 1]` has the shape
  of `i`);
- a Range, an ArithmeticSequence or an Array form picks its run;
- `nil` picks the whole axis, and the rubber marker expands as above;
- an integer CArray picks the cells it lists along its axis; a boolean
  one the cells it marks, and it must be as long as the axis.

### 3.4 Arity recheck after rubber expansion

```
if ndim != info.ndim
  raise IndexError
```

### 3.5 `ITERATOR` post-pass

When the loop produces a region tentatively classified as `ITERATOR`
(i.e. one of the axes used `:>`), every `CA_IDX_SCALAR` axis is
rewritten in place as `CA_IDX_BLOCK {start = k, count = 1, step = 1}`:

```ruby
CArray.scan_index([3, 3], [0, :>])
# => CA_REG_ITERATOR, index = [[0, 1, 1], [:>, nil]]
#                              ^^^^^^^^^ SCALAR 0 has been expanded
```

This transformation is performed in the classifier; the comparable
`SCALAR`-keeps-scalar and `ALL`-expands-to-`[0, dim, 1]` behaviour
for the `BLOCK` region happens later in projection (§4).

### 3.6 Final region

```
is_point = true
is_all   = true
is_iterator = false
is_grid  = (set during §3.3 or false)

for i in 0..ndim-1:
  case index_type[i]
  when SCALAR: is_all   = false
  when ALL:    is_point = false
  when SYMBOL: is_iterator = true; break
  when BLOCK:  is_point = false; is_all = false
  end

if is_repeat == 1: region = REPEAT
elif is_grid:        region = GRID
elif is_iterator:    region = ITERATOR
elif is_point:       region = POINT       # all axes SCALAR
elif is_all:         region = BLOCK       # all axes ALL (i.e. ndim×nil)
else:                region = BLOCK       # any mix of SCALAR / ALL / BLOCK
```

Note that a fully-`nil` form such as `ca[nil, nil]` is classified as
`BLOCK`, not `ALL`. The `ALL` region applies only to `ca[]` and
`ca[false]`; in `BLOCK`, every axis is populated in `info.index`.

---

## 4. `info.index` projection

The Ruby-side wrapper materialises `info.index` from the C-level
classification according to the region:

| region            | `info.index`                                                          |
|-------------------|-----------------------------------------------------------------------|
| `ALL`             | `[]`                                                                  |
| `ADDRESS`         | `[addr]`                                                              |
| `FLATTEN`         | `[]`                                                                  |
| `ADDRESS_COMPLEX` | `[[start, count, step]]` (computed by recursive scan in flat space)   |
| `POINT`           | `[i, j, ...]` (the per-axis `index[i].scalar`)                        |
| `BLOCK`           | per axis: SCALAR → `Integer`, ALL → `[0, dim[i], 1]`, BLOCK → `[start, count, step]` |
| `ITERATOR`        | per axis: SCALAR → `Integer`, ALL → `[0, dim[i], 1]`, BLOCK → `[start, count, step]`, SYMBOL → `[:>, spec]` |
| `SELECT`          | `[]`                                                                  |
| `REPEAT`          | `[]`                                                                  |
| `GRID`            | `[]`                                                                  |
| `MAPPING`         | `[]`                                                                  |
| `METHOD_CALL`     | `[]`                                                                  |
| `MEMBER`          | `[]`                                                                  |

In the `BLOCK` projection, an `ALL` axis is **expanded** into a
three-element triple `[0, dim[i], 1]`, while a `SCALAR` axis is left
as a plain `Integer` (it is *not* wrapped in a one-element array).
The distinction matters to consumers that need to tell a "single-cell
axis" apart from a "one-cell block": a translation layer over NetCDF
hyperslab notation, for example, treats them differently.

---

## 5. Error catalog

| trigger                                              | exception class    | message                                                                                       |
|------------------------------------------------------|--------------------|-----------------------------------------------------------------------------------------------|
| element-count mismatch on boolean-CArray `SELECT`    | `ArgumentError`     | `mismatch of # of elements ( %lld <=> %lld ) in reference by selection`                       |
| boolean `SELECT` of another shape (more than one axis) | `ArgumentError`   | `boolean selector of shape %s for an array of shape %s (...)`                                  |
| boolean key in a grid not as long as its axis        | `ArgumentError`     | `mismatch of # of elements ( %lld <=> %lld ) in reference by selection on axis %d`            |
| `argc == 1` with CArray of an invalid data_type      | `IndexError`       | `data_type %s is invalid for reference by selection/mapping(should be boolean or integer)`     |
| rubber dim overflow (`argc > ndim + 1`)              | `IndexError`       | `index specification exceeds the ndim of carray (%i)`                                          |
| arity mismatch without rubber dim                    | `IndexError`       | `%i indices given for a carray of ndim %i`                                                     |
| integer axis out of range                            | `IndexError`       | `[]: index %lld is out of range for length %lld on axis %d` (`[]=` for a store)                |
| `Range` / `ArithmeticSequence` endpoint out of range | `IndexError`       | same as above                                                                                  |
| `step == 0` (`ArithmeticSequence`)                   | `ArgumentError`     | `step in index equals to 0 in block reference`                                                 |
| `step == 0` (`[nil, step]`)                          | `ArgumentError`     | same as above                                                                                  |
| `step == 0` (`[Range, step]`)                        | `ArgumentError`     | same as above                                                                                  |
| `step == 0` (`[s, c, step]`)                         | `ArgumentError`     | same as above                                                                                  |
| `Array` of length other than 1, 2, 3                 | `IndexError`       | `invalid form of index range at %i-dim (should be [start[,count[,step]]], [range, step])`     |
| `Symbol` other than `:>` in an axis position         | `IndexError`       | `symbol :%s is invalid as the index for slab iterator (use :> instead)`                       |
| arity mismatch after rubber expansion                | `IndexError`       | `%i indices given for a carray of ndim %i`                                                     |
| multi-arg form with CArray of an invalid data_type   | `IndexError`       | `data_type %s is invalid for reference by gridding at %i-dim (should be boolean or integer)`  |
| any unrecognised argument                            | `IndexError`       | `object '%s' is invalid for the index for reference at %i-dim`                                |

---

## 6. Fast paths

The classifier short-circuits two common shapes before entering the
main loop. Both are observable only via timing; the resulting
`info.type` and `info.index` are identical to the general path.

```c
/* POINT fast path: argc == ndim, every argv[i] is a FIXNUM */
if (argc >= 1 && argc == ndim) {
  if (all FIXNUM_P(argv[i])) {
    info.type = POINT;
    populate info.index from FIX2LONG;
    return;
  }
}

/* ADDRESS fast path: argc == 1, ndim > 1, argv[0] is a FIXNUM */
if (argc == 1 && ndim > 1 && FIXNUM_P(argv[0])) {
  info.type = ADDRESS;
  populate info.index;
  return;
}
```

`Bignum` and `Float` values fail `FIXNUM_P` and fall through to the
general path, which reads them by `key(v)` (§3.3.1): an Integer that fits
int64 is an address checked against the element count, one past int64 is
out of range with `IndexError`.
