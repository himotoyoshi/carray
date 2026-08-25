# 12 The mkkernel DSL

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

`ext/mkkernel.rb` is CArray's kernel code generator. It takes a compact
Ruby declaration of an operation — a reduction, a map, a scan, a sort, a
search, or an element-wise math op — and emits all the per-data-type C
helpers, the data-type dispatcher, and the `rb_define_method` registration
into `ext/carray_kernels.c`.

This chapter is the **author-side reference** for the DSL: every entry
point, every option, the cross-cutting conventions, and where the
generated C lands. The kernel-iterator macros the generated C sits on are
in [ch. 11](11_kernel_iterator.md); the helper primitives are in
[ch. 15](15_carray_h_helper_reference.md).

> **The DSL is the default landing point for new ops.** Do not hand-write
> a kernel wrapper into `carray_math.c` / `carray_stat.c`. If an
> operation fits one of the nine forms below, declare it here. Bypassing
> the DSL to add a hand-written wrapper is a discipline violation. The exception — a
> genuinely dedicated kernel that no DSL form can express — is itself a
> documented decision.

## Why a generator

A single kernel for one data type is tolerable to hand-write. But CArray
ships every numeric reduction across ~10 source data types, each with
its own accumulator init (`INT32_MAX` vs `+INFINITY` for `min`), its own
Ruby-scalar wrapper (`LL2NUM` for ints, `rb_float_new` for floats), and
a dispatcher that switches on the source data type. The C preprocessor
stops being the right tool once per-data-type `init` overrides enter
the picture.

The generator takes ~140 lines of DSL for the `sum` / `prod` / `min` /
`max` family and emits ~570 lines of C. More importantly it makes the
*shape* of a kernel declarative: you state the fold, the generator owns
the boilerplate (slab walk via the kernel iterator, mask handling,
dispatch, Ruby registration).

## Build pipeline

The generator runs at build time. `extconf.rb` regenerates
`carray_kernels.c` when `mkkernel.rb` is newer, and the generated
`Makefile` has the same dependency rule. To regenerate by hand:

```
cd ext && ruby mkkernel.rb > carray_kernels.c
```

`make` then compiles the new `.c`. `make distclean` removes the
generated file (it is not checked in). The normal dev loop —
`CARRAY_DEV=1 rake build_ext` — picks up DSL edits automatically.

Kernel declarations live at the **bottom** of `ext/mkkernel.rb` (from
the `MkKernel.reduce :sum` block onward). The machinery above them —
option parsing, the `emit_*` functions — is the generator itself and is
out of scope for kernel authors. To add a kernel, append one
declaration to the bottom section.

> ⚠️ When you edit `mkkernel.rb`, run a **full** distclean rebuild
> (`rake clean_ext && rake build_ext`) — the generator is a stronger dependency
> than `*.h`, and incremental `make` has been observed to skip recompilation after
> generator edits. This is the same header-touch / merge rebuild rule that
> [ch. 19](19_build_generators_testing.md) owns.

## The data-type vocabulary

`MkKernel::DTYPES` is the master table. Each entry carries the C type,
the `CA_*` enum, the Ruby-VALUE wrapper, the `NUM2*` cast, and the
`limit_hi` / `limit_lo` sentinels:

| key | C type | `CA_*` | notes |
|---|---|---|---|
| `:i8` … `:i64` | `int8_t` … `int64_t` | `CA_INT8` … | signed ints |
| `:u8` … `:u64` | `uint8_t` … `uint64_t` | `CA_UINT8` … | unsigned; `limit_lo = 0` |
| `:f32` `:f64` | `float` `double` | `CA_FLOAT32/64` | `limit_*` = `±INFINITY` |
| `:bool` | `boolean8_t` | `CA_BOOLEAN` | **not** in `ALL_NUMERIC` |
| `:ca_size` | `ca_size_t` | `CA_SIZE` | output type for index kernels |
| `:cmplx64` `:cmplx128` | `cmplx*_t` | `CA_CMPLX64/128` | math family only |
| `:object` | `VALUE` | `CA_OBJECT` | per-cell Ruby callback |
| `:fixlen` | `char` | `CA_FIXLEN` | byte-width `b1`; bincmp only |

Convenience source lists:

| alias | members |
|---|---|
| `ALL_NUMERIC` | `i8 u8 i16 u16 i32 u32 i64 u64 f32 f64` |
| `FLOAT_DTYPES` | `f32 f64` |
| `INT_DTYPES` | the 8 integer types |
| `SINT_DTYPES` / `UINT_DTYPES` | signed / unsigned ints |
| `CMPLX_DTYPES` | `cmplx64 cmplx128` |
| `MATH_TYPES` | `ALL_NUMERIC + CMPLX_DTYPES + bool + object` |
| `MATH_NUMERIC` | `ALL_NUMERIC + CMPLX_DTYPES` |
| `BOOL_DTYPES` / `OBJECT_DTYPES` | `[:bool]` / `[:object]` |

`:bool`, `:ca_size`, `:cmplx*`, `:object`, `:fixlen` are deliberately
**excluded from `ALL_NUMERIC`** — you opt into each by listing it in
`source:` explicitly. This keeps `sum` / `min` / `variance` from
silently generating boolean or complex variants where the semantics
are ambiguous.

## Cross-cutting conventions

These apply across multiple entry points; the per-entry sections
reference them rather than repeating.

### Output data-type resolution

The `output:` field accepts three forms:

- `:preserve` — output data type equals the source data type (used by
  `min` / `max` / `cummax`).
- a Symbol (e.g. `:f64`, `:i64`, `:ca_size`) — a fixed output data
  type for every source.
- a **family-keyed Hash** — data-type-conditional output, scanned in
  declaration order, first matching family wins. Family aliases are
  `:numeric` / `:int` / `:float` / `:complex` / `:bool` / `:object`,
  plus an optional `default:`. Example from `cumsum`:

  ```ruby
  output: { numeric: :f64, complex: :cmplx128, object: :object }
  ```

### Expression placeholders

Two distinct placeholder dialects exist depending on the entry point:

- **reduce / scan** bind named variables in the C body: `v` (the
  loaded cell, typed `T_LOAD`), `acc` (the accumulator, typed by
  `state:`), `r` (the output cell, in `scan` `step:`). Implicit C
  widening handles `int → double`. `value_arg` exposes `value_arg`;
  `array_arg` exposes the per-cell auxiliary `w`. `acc_type:
  :load_type` additionally exposes `first` (int, 1 on the first
  unmasked cell).
- **monop / binop / triop / moncmp / bincmp** use the mkmath
  positional convention: `#1` = first input cell, `#2` = second, `#3`
  = third / output, etc. For monop `#1` is input and `#2` is output;
  for binop `#1` `#2` are inputs and `#3` is output; for triop inputs
  are `#1` `#2` `#3` and output is `#4`. These bodies are full C
  **statements** — they end in `;` and conventionally parenthesize
  each placeholder (e.g. `(#3) = (#1) + (#2);`) because the
  placeholder may be a complex lvalue. bincmp expr additionally
  substitutes `<type>` (the C type) and `<epsilon>` (e.g.
  `DBL_EPSILON`); for fixlen bincmp the raw pointers `p1` / `p2` and
  byte widths `b1` / `b2` are also in scope.

### Family-keyed Hash bodies

Wherever a body expression is data-type dependent, pass a Hash keyed
by data-type family aliases instead of a String. The family vocabulary
is `:numeric` / `:int` / `:float` / `:complex` / `:bool` / `:object`,
used for `expr:` (math family), `reduce:` / `init:` / `step:` /
`finish:` (reduce / scan), and `body:` (search). A Hash key may also
be an **explicit array of data-type symbols** (e.g.
`[:bool] + MkKernel::ALL_NUMERIC => "..."`), which the cmp family uses
to group fixlen / bool+numeric / complex / object branches. A plain
String means "same expression for all sources in `source:`". Example
(`cummax`):

```ruby
step: { numeric: "if (v > acc) acc = v; r = acc",
        object:  'if (acc == Qnil) acc = v; else if (RTEST(rb_funcall(v, rb_intern(">"), 1, acc))) acc = v; r = acc' }
```

### The `:object` branch

`CA_OBJECT` (arbitrary Ruby objects, one `VALUE` per cell) is
supported by adding `:object` to `source:` and supplying an `:object`
family body that uses `rb_funcall` / `rb_equal` / comparison instead
of C operators. **By discipline, new reduce / scan / sort /
search kernels should include the `:object` branch by default**;
restricting to numeric requires a justification comment. Typical
`:object` idioms:

- equality: `rb_equal(v, query_val)`
- ordering: `NUM2INT(rb_funcall(v, rb_intern("<=>"), 1, query_val))`
- arithmetic: `rb_funcall(acc, rb_intern("+"), 1, v)`

Sentinel discipline: identity-less reductions (`min` / `max` /
`argmin` …) use `Qundef` as the `:object` init (the mask policy
replaces never-touched slabs with UNDEF, so `Qundef` never reaches
`finish`). **Scan** kernels (`cummax` / `cummin`) instead use a real
Ruby value sentinel such as `Qnil`, because a scan's masked-cell
branch leaks `acc` into the output and `Qundef` would surface as an
invalid value.

### The SIMD license (`reduction_kind:`)

By default a reduce kernel uses the generic `CA_SLAB_REDUCE_T_EX`
macro ([ch. 11](11_kernel_iterator.md)). Setting `reduction_kind:`
licenses a SIMD-friendly contig-branch macro variant that emits
`#pragma omp simd reduction(...)`:

- `:plus` / `:min` / `:max` / `:star` — single-accumulator licensed
  forms, selecting `CA_SLAB_REDUCE_T_{PLUS,MIN,MAX,STAR}_EX`.
- `:induction` — for counters (e.g. `cnt++`).
- a **Hash** for multi-accumulator kernels, keyed by state var:
  `reduction_kind: { acc: :plus, sumsq: :plus, cnt: :induction }`.
  The kind of `state.keys.first` drives the macro's formal
  accumulator; other state vars are auto-vectorised by the compiler.

This changes the floating-point reduction contract from bit-exact to
ε-close (relative error `< 1e-14`). Kernels with a `_strict` /
`_safe` suffix **must not** carry a `reduction_kind` — they keep the
non-reassoc path.

## The nine entry points

### `MkKernel.reduce`

Fold a slab to a scalar (or, with `axes`, fold along axes). The
generated method is variadic over axes — `a.sum`, `a.sum(0)`,
`a.sum(0, 1)` — with a full-array flatten when no axis is given.

```ruby
MkKernel.reduce :name,
  init:        "0",            # accumulator init (String / Hash)
  reduce:      "acc += v",     # per-cell fold (binds v, acc)
  source:      MkKernel::ALL_NUMERIC,
  output:      :f64,           # or :preserve, or a family Hash
  ruby_scalar: :rb_float_new,
  fallback:    :wrap_to_f64    # or :raise
```

Required: `name`, `source:`, `output:`, `init:`, `reduce:`. Common
options:

| option | meaning |
|---|---|
| `init:` | accumulator init. String (single-acc) or Hash (multi-state / per-family). Special tokens `T_LIMIT_HI` / `T_LIMIT_LO` resolve per source type to `INT*_MAX` / `±INFINITY`. |
| `reduce:` | per-cell fold statement. Binds `v`, `acc`. String or family Hash. |
| `output:` | see [output resolution](#output-data-type-resolution). |
| `ruby_scalar:` | VALUE wrapper for the full-reduction scalar. `:rb_float_new` / `:LL2NUM` / `:auto` (derive from output). |
| `fallback:` | unsupported sources: `:raise` (default) or `:wrap_to_f64` (re-run the f64 helper via `rb_ca_wrap_readonly`). |
| `mask_policy:` | `nil` / `:strict` / `:all_masked` / `:min_count`. Controls how the dispatcher folds masked-cell counts into the result (UNDEF when policy is violated). |
| `reduction_kind:` | SIMD license, see [above](#the-simd-license-reduction_kind). |
| `semantics:` | `:fiber_local` (default) or `:view_flat`. |
| `replaces_legacy:` | rebind an existing public method (Symbol) or `true` (same name) to this kernel at Init time. |
| `bind_ruby:` | `false` to emit the C entry without a Ruby method (consumed at C level by a hand-written dispatcher). |

The generator emits one `<name>_ki_native_<dtype>` helper per source
data type, a dispatcher `<name>_ki_dispatch` that switches on
`src->data_type`, and a Ruby method binding that handles
`(self, *axes)` argv parsing via `rb_ca_parse_reduce_axes`.

**Multi-state form** (variance / wsum / wmean / similar). Omit the
single-acc sugar and pass `state:` (a Hash of accumulator name →
type), `init:` and `reduce:` as Hashes, and a `finish:` expression
that computes the result from the state vars. `state.keys` ordering
matters: the first key becomes the macro's formal accumulator.
`finish:` defaults to the first state var name when omitted. Example
(`variance`):

```ruby
MkKernel.reduce :variance,
  state:          { acc:   { numeric: :f64, complex: :cmplx128 },
                    sumsq: :double,
                    cnt:   :int64_t },
  init:           { acc: "0", sumsq: "0", cnt: "0" },
  reduce:         { numeric: "(acc += v, sumsq += (double)v*(double)v, cnt++)",
                    complex: "..." },
  reduction_kind: { acc: :plus, sumsq: :plus, cnt: :induction },
  finish:         { numeric: "cnt > 1 ? (sumsq - acc*acc/(double)cnt) / (double)(cnt - 1) : 0",
                    complex: "..." },
  source:         MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  output:         :f64, ruby_scalar: :rb_float_new, fallback: :raise,
  mask_policy:    :min_count, replaces_legacy: true
```

**`value_arg:`** adds one scalar Ruby argument cast to the kernel's
input type and exposed as `value_arg` in the body. The generated
method signature becomes `(self, val, *axes)`:

```ruby
MkKernel.reduce :count_equal,
  init: "0", reduce: "if (v == value_arg) acc += 1",
  reduction_kind: :plus,
  source: MkKernel::ALL_NUMERIC, output: :i64, ruby_scalar: :LL2NUM,
  value_arg: { target: :T_IN }, mask_policy: :min_count, bind_ruby: false
```

`value_arg`'s `target:` accepts `:T_IN` (cast to source data type) or
a specific type symbol; for `(β)` broadcast acceptance the value can
be a 0-d / 1-d CArray.

**`array_arg:`** adds a per-cell auxiliary operand (a second CArray)
exposed as `w`, with scalar / 1-D axis-broadcast / same-shape
acceptance. Used by `wsum` / `wmean`:

```ruby
MkKernel.reduce :wsum,
  init: "0.0", reduce: "acc += (double) v * (double) w",
  reduction_kind: :plus,
  source: MkKernel::ALL_NUMERIC, output: :f64, ruby_scalar: :rb_float_new,
  array_arg: { name: :weights, data_type: :match_source,
               shape: :rev5_strict, mask: :overlay },
  mask_policy: :min_count, replaces_legacy: true
```

The macro generates the parallel `ca_iter_state` for the weights and
emits a `CA_SLAB_REDUCE_ARRAY_T_*` body that binds both `v` and `w`.
`array_arg` and `value_arg` cannot coexist, and `array_arg` requires
`fallback: :raise`.

**`outputs: 2`** is the fused multi-output form (e.g. fused
`minmax`). `finish:` must be a 2-entry Hash; `value_arg` /
`array_arg` / `semantics: :view_flat` / non-`:none` `reduction_kind`
are rejected in this form.

### `MkKernel.map`

Element-wise transform: input shape == output shape, one cell at a
time. The generated method takes no arguments.

```ruby
MkKernel.map :name,
  source:   MkKernel::ALL_NUMERIC,
  output:   :f64,          # or :preserve
  expr:     "r = sqrt((double) v)",   # binds v (input), r (output)
  fallback: :wrap_to_f64   # or :raise
```

The emitted body uses `CA_SLAB_MAP_T`. Note that `:preserve` +
`:wrap_to_f64` is rejected (the fallback produces f64, contradicting
`:preserve`).

### `MkKernel.scan`

Cumulative / prefix scan along one axis: input shape == output shape,
a running accumulator per fiber. Each fiber starts at `init`
independently.

```ruby
MkKernel.scan :cumsum,
  source:       MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES + [:object],
  output:       { numeric: :f64, complex: :cmplx128, object: :object },
  init:         { numeric: "0", complex: "0", object: "INT2FIX(0)" },
  step:         { numeric: "acc += v; r = acc", ... },
  fallback:     :raise,
  axis_default: :flatten
```

`step:` binds `v` (input), `acc` (accumulator), `r` (output). The
emitted body uses `CA_SLAB_SCAN_T` (or `CA_SLAB_SCAN_TA` when
`acc_type: :load_type` is set). Options beyond the shared set:

| option | meaning |
|---|---|
| `acc_type:` | `nil` → `acc` is `T_OUT` (default). `:load_type` → `acc` is `T_LOAD` (the last seen *input* value, for adjacent-compare scans like `uniq_scan`); also exposes `first` (int, 1 on the first unmasked cell). |
| `axis_default:` | `nil` → `axis:` is required. `:flatten` → no-arg form flattens and scans the 1-D result (legacy `cumsum` / `cumprod` / `cummax` / `cummin` / `cumcount`). |

Multi-axis scan is intentionally unsupported (semantically
ambiguous); users chain (`a.cumsum(1).cumsum(2)`).

### `MkKernel.sort`

Per-fiber sort returning **positions** (not sorted values): input
shape == output shape, one axis. Stability is always guaranteed via a
`(value, index)` tie-break inside the cmp function. The internal sort
kernels live in `ca_sort_kernels.h` (= not in the public umbrella;
the generated dispatcher pulls them in).

```ruby
MkKernel.sort :sort_index,
  source:          MkKernel::ALL_NUMERIC + [:object],
  output:          :ca_size,
  semantics:       :fiber_local,   # 0..dim[axis]-1
  nan_policy:      :end,
  fallback:        :raise,
  replaces_legacy: :sort_index
```

| option | meaning |
|---|---|
| `semantics:` | `:fiber_local` → output in `0..dim[axis]-1` (a per-fiber axis-local index). `:view_flat` → view-flat address (`0..elements-1`), suitable to feed `ca_remap_new`; used by the internal `sort_addr`. |
| `nan_policy:` | `:end` only (NaN sorts to the end). |
| `algorithm:` | `:full` (default, stable sort), `:partition` (quickselect; method takes `(axis, kth)`), or `:rank`. |
| `mask_self:` | `:raise` (default) or `:skip`. |
| `bind_ruby:` | `false` for internal-only kernels (e.g. `sort_addr`, consumed by `sort(axis:)` at C level). |

Sort kind selection (radix vs comparison) is not exposed on the Ruby
surface in 3.0.

### `MkKernel.search`

Per-`(base, query)` scalar return: one slab axis on `self`, query
broadcast against the base shape (with tail-append for incompatible
shapes). The generated method takes a `val` argument and an `axis:`
keyword. Unlike the other forms, **the author writes the inner
per-slab C body**; the generator emits the outer `(query × base)`
walk.

```ruby
MkKernel.search :find_value_index,
  source:    MkKernel::ALL_NUMERIC + [:object],
  output:    :ca_size,
  body:      {
    int:    "result = -1; for (...) { ... if (v == query_val) { result = i; break; } }",
    float:  "...",
    object: "... if (rb_equal(v, query_val)) ..."
  },
  no_match:  "-1",
  mask_self: :raise,
  fallback:  :raise
```

The body binds:

| Identifier | Type | Meaning |
|---|---|---|
| `slab_ptr` | `char *` | base pointer of the current slab |
| `slab_n` | `ca_size_t` | length |
| `slab_stride` | `ca_size_t` | byte stride along the slab axis |
| `query_val` | `T_LOAD` | the query cell |
| `result` | (writeable) | write the answer here |
| `mask_in` | `boolean8_t *` | NULL if no mask, forwarded only when `mask_self: :skip` |

| option | meaning |
|---|---|
| `body:` | String (uniform) or Hash with `:int` / `:float` (required) and optional `:object`. |
| `no_match:` | sentinel C expression written when nothing matches (default `"-1"`). |
| `no_match_check:` | optional C expression overriding the default `==` no-match test. |
| `mask_self:` | `:raise` (bsearch family — global reject if any masked), `:skip` (forward per-slab mask via `mask_in`), `:ignore`. |
| `runtime_args:` | Array of optional positionals; currently only `:eps` (float-fuzzy compare). |
| `semantics:` | `:fiber_local` or `:view_flat` (e.g. `bsearch` vs `bsearch_addr`). |

For `:object`, `eps` is ill-defined and silently ignored (exact
equality only).

### `MkKernel.monop` and `MkKernel.monfunc`

Eager unary element-wise op `T -> T` (or widening to f64). Emits a
kernel matching the mkmath calling convention and registers
`CArray#<name>` plus `CArray#<name>!`.

```ruby
MkKernel.monop :neg,
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {                          # #1 = input, #2 = output
    numeric: "(#2) = -(#1);",
    complex: "(#2) = -(#1);",
    object:  '(#2) = rb_funcall((#1), rb_intern("-@"), 0);',
  }

MkKernel.monfunc :rsqrt,
  source: MkKernel::FLOAT_DTYPES + MkKernel::CMPLX_DTYPES + [:object],
  expr:   {
    float:   "(#2) = 1.0 / sqrt(#1);",
    complex: "(#2) = 1.0 / csqrt(#1);",
    object:  MkKernel.obj_float_math("1.0 / sqrt(<v>)", "rsqrt"),
  }
```

| option | meaning |
|---|---|
| `expr:` | mkmath-placeholder body (`#1` input, `#2` output). String or family Hash. |
| `op:` | public method name (defaults to `name`). |
| `bind:` | `true` (default) registers `#name` + `#name!`; `false` emits the kernel only. |
| `cmath:` | whether the complex branch may use `<complex.h>` functions. |
| `widening:` | auto-cast integer input to f64. Auto-detected from `source:` when omitted (no integer source ⇒ auto-cast). |
| `output:` | `:preserve` (default) or a family Hash (e.g. `abs` demoting complex → real f64). |

`monfunc` is a declarative alias of `monop` signalling "this is a
math function" and relying on `widening`'s auto-detect. For the
per-cell `:object` math branch,
`MkKernel.obj_float_math(double_expr, fallback_method)` builds an
expression that computes Float/Integer/Rational in C and falls back
to `rb_funcall` for other element types.

### `MkKernel.binop` and `MkKernel.triop`

`binop` is a binary element-wise op `(T, T) -> T`; `triop` is a
3-input / 1-output fused op (e.g. `fma`, `clip`).

```ruby
MkKernel.binop :pmax,
  source: MkKernel::ALL_NUMERIC + [:object],
  expr:   {                              # #1 #2 inputs, #3 output
    int:    "(#3) = (#1) > (#2) ? (#1) : (#2);",
    float:  "(#3) = fmax(#1, #2);",
    object: '(#3) = rb_funcall(rb_assoc_new((#1),(#2)), rb_intern("max"), 0);',
  }

MkKernel.binop :add,        # op: gives the operator method name
  op:     "+",
  source: MkKernel::MATH_NUMERIC + [:object],
  expr:   {
    numeric: "(#3) = (#1) + (#2);",
    complex: "(#3) = (#1) + (#2);",
    object:  '(#3) = rb_funcall((#1), rb_intern("+"), 1, (#2));',
  }
```

| option | meaning |
|---|---|
| `op:` | `:auto` (default → register the method named `name`). Pass `"+"` etc. for a different operator name, or `nil` to skip Ruby registration (internal kernels like `and_i` exposed via hand-written boolean-coercing wrappers). |
| `bind:` | as monop. |
| `bang:` (triop) | register the `!` form (default `true`). |

triop placeholders: `#1` `#2` `#3` inputs, `#4` output. triop kernels
run eagerly via the `rb_ca_call_triop` C bridge; per-axis / view
universality / the mask SIMD fast path are inherited from the kernel
signature.

### `MkKernel.moncmp` and `MkKernel.bincmp`

Element-wise predicates returning `boolean8_t` (1 byte 0/1).
`moncmp` is `T -> bool` (read-only, no `!` form); `bincmp` is
`(T, T) -> bool` with byte-width params for FIXLEN comparison.

```ruby
MkKernel.bincmp :gt,
  op:     "gt",
  source: [:fixlen, :bool] + MkKernel::ALL_NUMERIC + [:object],
  expr:   {
    [:fixlen] => "int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2); (#3) = ( cmp > 0 || ( cmp == 0 && b1 > b2 ) );",
    ([:bool] + MkKernel::ALL_NUMERIC) => "(#3) = ( (#1) > (#2) );",
    [:object] => '(#3) = RTEST(rb_funcall((#1), rb_intern(">"), 1, (#2))) ? 1 : 0;',
  }
MkKernel.alias_bincmp :">", :gt    # public > is an alias of gt

MkKernel.bincmp :is_close,
  source:    MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  tolerance: true,
  expr:      {
    int:     "(#3) = (fabs((double)(#1) - (double)(#2)) <= tol) ? 1 : 0;",
    float:   "(#3) = (fabs((#1) - (#2)) <= tol) ? 1 : 0;",
    complex: "(#3) = (cabs((#1) - (#2)) <= tol) ? 1 : 0;",
  }
```

`tolerance: true` gives the op an arity-2 Ruby wrapper
`(self, other, tol_val)` and binds `tol` in the expr; non-tolerance
ops are arity-1 and pass `tol = 0.0`. bincmp expr additionally
substitutes `<type>` (C type) and `<epsilon>` (e.g. `FLT_EPSILON`).
In practice the `eq` / `ne` / `gt` / `lt` / `ge` / `le` family is
generated from a single metaprogramming loop over a spec table, since
they share structure across fixlen / bool+numeric / complex /
object.

### Aliases

No kernel is emitted; only an `rb_define_alias` entry:

```ruby
MkKernel.alias_monop  :"-@", :neg     # unary minus → neg
MkKernel.alias_binop  "add", "+"      # add → +
MkKernel.alias_bincmp ">",   "gt"     # > → gt
```

## What the generator emits, per declaration

Each declaration produces a coherent C unit in `carray_kernels.c`:

1. **Per-source-dtype native helper** — one C function per data type
   in `source:`, named `<name>_ki_native_<dtype>`. Body comes
   straight from the appropriate slab macro
   (`CA_SLAB_REDUCE_T_*_EX`, `CA_SLAB_MAP_T`, `CA_SLAB_SCAN_T*`, …)
   with the author's `init` / `reduce` / `step` / `expr` substituted
   into the macro identifiers.
2. **Per-source-dtype `_object` helper** when `:object` is in
   `source:` — uses `rb_funcall` / `rb_equal` bodies; outside the
   SIMD-licensed pragma path by construction.
3. **Dispatcher** — `<name>_ki_dispatch(self, axes, naxes, ...)`,
   switching on `src->data_type` and routing to the right native
   helper. Handles `fallback: :wrap_to_f64` by wrapping the source
   via `rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64))` and
   recursing.
4. **Ruby method binding** — when `bind_ruby:` is not `false`, an
   `rb_define_method` for `CArray#<op_name>` (plus `#<op_name>!` for
   monop / triop). The dispatcher runs through
   `rb_ca_parse_reduce_axes` / `rb_ca_parse_reduce_axes_kw` /
   `rb_pop_options` as appropriate.
5. **Init-time `replaces_legacy:` rebind** — when set, an entry in
   `Init_carray_kernels` runs `rb_define_method` (or
   `rb_define_alias`) that overrides an existing legacy method
   symbol to point at the new kernel.

The data-type dispatcher is mechanically identical across reduce /
map / scan / sort / search; the math-family dispatchers
(`monop` / `binop` / `triop` / `moncmp` / `bincmp`) instead populate
the per-data-type op-tables declared in `ca_monop_dispatch.h` /
`ca_binop_dispatch.h` / `ca_triop_dispatch.h` /
`ca_moncmp_dispatch.h` / `ca_bincmp_dispatch.h` and rely on the
existing `rb_ca_call_monop` etc. drivers
([ch. 15](15_carray_h_helper_reference.md), pulled in via
`carray_math_kernel.h`).

## Discipline checklist

Before adding a kernel:

1. **Use the DSL.** Do not add a hand-written wrapper to
   `carray_math.c` / `carray_stat.c`. The DSL is the default landing
   point.
2. **Include the `:object` branch by default** for reduce / scan /
   sort / search. Restricting to numeric needs a justification
   comment.
3. **Boolean is opt-in.** `:bool` is excluded from `ALL_NUMERIC`. Only
   the `:plus` family (`sum` = count, `mean` = proportion) accepts
   boolean; the `:min` / `:max` / `:variance` / `:star` families
   reject it (use `.all` / `.any`).
4. **SIMD license is ε-close.** `reduction_kind:` trades
   bit-exactness for speed. `_strict` / `_safe` kernels must not
   carry it.
5. **Position-returning kernels use `*_index` / `*_addr`**, never
   `arg*`. `_index` is an axis-local position; `_addr` is a true
   view-flat address.
6. **Regenerate and test:** `CARRAY_DEV=1 rake build_ext`
   regenerates and compiles; run `rake spec_ai` to verify. After
   editing `mkkernel.rb`, prefer `rake clean_ext && rake build_ext`
   for the first verification ([ch. 19](19_build_generators_testing.md)).

## See also

- `HOW_TO_WRITE_KERNEL.md` — the
  kernel-iterator surface the generated helpers sit on.
- [ch. 11 The kernel iterator](11_kernel_iterator.md) — the macro
  suite the generator emits.
- [ch. 15 carray.h helper reference](15_carray_h_helper_reference.md)
  — the primitives the generated code calls into.

---
*When done, update the status row in [README](README.md).*
