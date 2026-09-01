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
  `_GRID`, `_MAPPING`, `_METHOD_CALL`, `_MEMBER`, `_ATTRIBUTE`.
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
| `argv[0]` is boolean CArray, `cs.elements == ca.elements`    | `SELECT`        | `[]` (`info.select = cs`)          |
| `argv[0]` is boolean CArray, element count mismatch          | raises `RuntimeError` | —                            |
| `argv[0]` is CArray of any other data_type                   | raises `IndexError`   | —                            |
| `argv[0]` is `String` starting with `@`                      | `ATTRIBUTE`     | `[]` (`info.symbol = :name`)       |
| `argv[0]` is any other `String`                              | `MEMBER`        | `[]` (`info.symbol = :"field"`)    |

### 2.3 `argc == 1`, `ndim > 1`

| condition                                  | region              | `info.index`                       |
|--------------------------------------------|---------------------|------------------------------------|
| `argv[0]` is `Integer`                     | `ADDRESS`           | `[addr]`                           |
| `argv[0] == nil`                           | `FLATTEN`           | `[]`                               |
| anything else (`Range`, `ArithSeq`, `Array`, …) | `ADDRESS_COMPLEX` | `[[start, count, step]]` (see §2.4) |

When `argc == 1`, `ndim == 1`, and `argv[0]` is an `Integer`, none of
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
| `Integer`                                       | `SCALAR`            | `scalar = k` (negative normalised)          | `IndexError` on out-of-range                 |
| `nil`                                           | `ALL`               | none                                        | —                                            |
| `false` or `:~`                                 | rubber expansion: fill `rndim = ndim - argc + 1` axes with `ALL` (`:~` = rubber sigil, RB.1; `false` legacy) | — | —                  |
| `Range`                                         | `BLOCK`             | `{start, count, step = ±1}` (see §3.3.1)    | range check; `start == last && excl` degenerates to `{start, 0, 1}` |
| `Enumerator::ArithmeticSequence`                | `BLOCK`             | `{start, count, step}` (step from the seq)  | `step == 0` raises `RuntimeError`            |
| `[nil]`                                         | `ALL`               | none                                        | —                                            |
| `[Range]`                                       | (re-enters Range path) | —                                        | —                                            |
| `[Integer]`                                     | `BLOCK`             | `{start = k, count = 1, step = 1}`          | range check                                  |
| `[nil, step]`                                   | `BLOCK`             | `{start = 0, count = dim/step + 1, step}`   | `step == 0` raises                           |
| `[Range, step]`                                 | `BLOCK`             | `{start, count, step}`                      | range check; `step == 0` raises              |
| `[start, count]`                                | `BLOCK`             | `{start, count, step = 1}`                  | range check on `start` and `start+count-1`   |
| `[start, count, step]`                          | `BLOCK`             | `{start, count, step}`                      | range check; `step == 0` raises              |
| `Array` of any other length                     | raises `IndexError` | —                                           | —                                            |
| `:>`                                            | `SYMBOL`            | `{id = :>, spec = nil}`                     | slab-axis (iterator) marker (SI.2)           |
| `:_`                                            | raises `IndexError` | —                                           | newaxis — handled at `[]` / `[]=`, not here  |
| any other `Symbol`                              | raises `IndexError` | —                                           | (use `:>` instead)                           |
| boolean / integer CArray                        | sets `is_grid = 1`, breaks the loop | —                           | —                                            |
| CArray of any other data_type                   | raises `IndexError` | —                                           | —                                            |
| anything else                                   | raises `IndexError` | —                                           | —                                            |

#### 3.3.1 Range / ArithmeticSequence detail

```
iv_beg = arg.begin    (nil → start = 0)
iv_end = arg.end      (nil → last = -1)
iv_excl = arg.exclude_end?

start = NUM2SIZE(iv_beg)   or 0
last  = NUM2SIZE(iv_end)   or -1
excl  = RTEST(iv_excl)
step  = NUM2SIZE(arg.step) if ArithmeticSequence,
        else ±1 (+1 when last >= start, -1 otherwise)

normalise start
if last < 0: last += dim[i]      # plain addition, no bounds check

if excl && start == last:
  index[i].block = {start, count = 0, step = 1}
else:
  if excl: last += (last >= start ? -1 : +1)
  bounds-check last
  count = |last - start| / |step| + 1
  bounds-check start + (count - 1) * step
  index[i].block = {start, count, step}
```

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
| `ATTRIBUTE`       | `[]`                                                                  |

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
| element-count mismatch on boolean-CArray `SELECT`    | `RuntimeError`     | `mismatch of # of elements ( %lld <=> %lld ) in reference by selection`                       |
| `argc == 1` with CArray of an invalid data_type      | `IndexError`       | `data_type %s is invalid for reference by selection/mapping(should be boolean or integer)`     |
| rubber dim overflow (`argc > ndim + 1`)              | `IndexError`       | `index specification exceeds the ndim of carray (%i)`                                          |
| arity mismatch without rubber dim                    | `IndexError`       | `number of indices exceeds the ndim of carray (%i > %i)`                                       |
| integer axis out of range                            | `IndexError`       | `index out of range at %i-dim ( %lld <=> 0..%lld )`                                            |
| `Range` / `ArithmeticSequence` endpoint out of range | `IndexError`       | `index %lld is out of range (0..%lld) at %i-dim`                                                |
| `step == 0` (`ArithmeticSequence`)                   | `RuntimeError`     | `step in index equals to 0 in block reference`                                                 |
| `step == 0` (`[nil, step]`)                          | `RuntimeError`     | same as above                                                                                  |
| `step == 0` (`[Range, step]`)                        | `RuntimeError`     | same as above                                                                                  |
| `step == 0` (`[s, c, step]`)                         | `RuntimeError`     | same as above                                                                                  |
| `Array` of length other than 1, 2, 3                 | `IndexError`       | `invalid form of index range at %i-dim (should be [start[,count[,step]]], [range, step])`     |
| `Symbol` other than `:>` in an axis position         | `IndexError`       | `symbol :%s is invalid as the index for slab iterator (use :> instead)`                       |
| arity mismatch after rubber expansion                | `IndexError`       | `number of indices does not equal to the ndim (%i != %i)`                                      |
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

`Bignum` values fail `FIXNUM_P` and fall through to the general path,
where `rb_obj_is_kind_of(arg, rb_cInteger)` plus `NUM2SIZE` handles
them with identical semantics.
