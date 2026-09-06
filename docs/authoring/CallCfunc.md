# The call_cfunc author surface

`ca_call_cfunc_*` is the **scalar-callback bridge**: it takes a plain C
function that operates on one cell at a time (`void (*)(void *p0, void
*p1, …)`) and runs it across whole CArray operands, handling data-type
adaptation, output allocation, mask propagation, broadcasting, and the
attach/sync lifecycle for you. It is how a C extension wraps an existing
scalar C math routine — `lgamma`, a GSL special function, a PROJ
coordinate transform — into a vectorized CArray operation.

It is one of three author surfaces. Pick by shape:

| You are writing… | Use |
|---|---|
| a standard op across all data types (sum, sqrt, `+`, sort, …) | the **mkkernel DSL** — [`MkKernelDSL.md`](MkKernelDSL.md) |
| a per-axis / reduction / scan / contig-fiber kernel | the **kernel_iterator** macros — [`HOW_TO_WRITE_KERNEL.md`](HOW_TO_WRITE_KERNEL.md) |
| a wrapper around a scalar C function (one cell in → one cell out, fixed data type) | **`ca_call_cfunc_*`** (this doc) |

`call_cfunc` is the oldest of the three (the "function/callback form"
sibling of the L0 per-element macro). It predates kernel_iterator and is
intentionally kept: it is the most ergonomic surface when you already
have a scalar C function and just want it applied element-wise with
automatic casting and masking. Companion gems (carray-gsl, a PROJ
binding, …) are its main consumers, and a few in-tree functions use it
(`CAMath.lgamma`, `CAMath.sph_to_xyz`).

> The whole `ca_call_cfunc_*` family is **generated** by
> `ext/mk_call_cfunc.rb` into `ext/carray_call_cfunc.c` +
> `ext/carray_call_cfunc.h` (declarations are pulled in via `carray.h`).
> Do not edit the generated files; to add an arity, edit the generator.

## Contents

- [Two layers](#two-layers)
- [The typed dispatcher `ca_call_cfunc_M_N`](#the-typed-dispatcher-ca_call_cfunc_m_n)
- [The raw layer `ca_call_cfunc_N` + fsync](#the-raw-layer-ca_call_cfunc_n--fsync)
- [Reentrant `_r` variants (userdata)](#reentrant-_r-variants-userdata)
- [What the bridge handles for you](#what-the-bridge-handles-for-you)
- [Arity matrix](#arity-matrix)
- [Discipline](#discipline)

## Two layers

- **Typed dispatcher** `ca_call_cfunc_M_N` — the surface you normally
  call. You declare the data type of each operand; it wraps inputs to
  their declared type, allocates the output(s), runs the kernel, and
  returns the result(s). `M` = number of **outputs**, `N` = number of
  **inputs**.
- **Raw layer** `ca_call_cfunc_N` — `N` already-prepared CArray operands
  plus an `fsync` string saying which are outputs. The typed dispatcher
  is a thin wrapper over this; call it directly only when you need to
  manage the operands yourself.

## The typed dispatcher `ca_call_cfunc_M_N`

This is the normal entry point. Signature shape (for `M` outputs, `N`
inputs):

```c
VALUE ca_call_cfunc_M_N(
    int8_t dty1, …, int8_t dtyM,     /* output data types  */
    int8_t dtx1, …, int8_t dtxN,     /* input data types   */
    void (*kernel)(void *p_out1, …, void *p_outM,
                   void *p_in1,  …, void *p_inN),
    VALUE rx1, …, VALUE rxN);        /* input CArray VALUEs */
```

The kernel's pointer order is **outputs first, then inputs** — the same
order as the data-type arguments. Each `void *` points at one cell of
the corresponding operand; cast it to the declared C type and read/write.

### Example: 1 output, 1 input (`lgamma`)

```c
static void
mathfunc_lgamma (void *p0, void *p1)
{
  *(double *) p0 = lgamma(*(double *) p1);   /* p0 = out, p1 = in */
}

static VALUE
rb_camath_lgamma (VALUE mod, VALUE rx1)
{
  return ca_call_cfunc_1_1(CA_DOUBLE, CA_DOUBLE,   /* out f64, in f64 */
                           mathfunc_lgamma, rx1);
}
```

(`CA_DOUBLE` is the `CA_FLOAT64` alias.) If `rx1` is an `int32` array it
is auto-cast to `float64` on read; the result is a fresh `float64` array
shaped like `rx1`. If `rx1` is a scalar (rank-0), the return is a Ruby
Float rather than a CArray (`M == 1` outputs scalar-fold; see below).

### Example: 3 outputs, 3 inputs (spherical → cartesian)

```c
static void
mathfunc_sph_to_xyz (void *p0, void *p1, void *p2,    /* x, y, z (out) */
                     void *p3, void *p4, void *p5)    /* r, theta, phi (in) */
{
  double r = *(double*)p3, theta = *(double*)p4, phi = *(double*)p5;
  *(double*) p0 = r * sin(theta) * cos(phi);
  *(double*) p1 = r * sin(theta) * sin(phi);
  *(double*) p2 = r * cos(theta);
}

static VALUE
rb_camath_sph_to_xyz (VALUE mod, VALUE rx1, VALUE rx2, VALUE rx3)
{
  return ca_call_cfunc_3_3(CA_DOUBLE, CA_DOUBLE, CA_DOUBLE,   /* 3 outputs */
                           CA_DOUBLE, CA_DOUBLE, CA_DOUBLE,   /* 3 inputs  */
                           mathfunc_sph_to_xyz, rx1, rx2, rx3);
}
```

**Return value:** `M == 1` returns the single output CArray (or a scalar
Ruby value when rank-0). `M > 1` returns a Ruby Array of the `M` outputs
(`[x, y, z]` above), each scalar-folded if rank-0.

**What the dispatcher does**, per output:
- each input is wrapped to its declared `dtx` via `rb_ca_wrap_readonly`
  (zero-cost when the type already matches, a `CAFake` cast view
  otherwise);
- each output is a fresh template (`rb_ca_template_n`) shaped by
  broadcasting the inputs, with the declared `dty` data type;
- it delegates to the raw `ca_call_cfunc_(M+N)` with the right `fsync`.

## The raw layer `ca_call_cfunc_N` + fsync

```c
VALUE ca_call_cfunc_N(void (*func)(void *p0, …, void *p_{N-1}),
                      const char *fsync,
                      VALUE rcx0, …, VALUE rcx_{N-1});
```

`N` is the **total** operand count (outputs + inputs). `fsync` is an
`N`-character string of `'1'` / `'0'`:

- `'1'` — this operand is an **output**: attach + sync-back (the kernel
  writes to it; changes are written through to the array).
- `'0'` — this operand is an **input**: read-only, never attached (see
  the attach-safety contract below).

Operands are passed in `fsync` order. The typed dispatcher builds the
`fsync` as `"1"*M + "0"*N` and passes outputs first — e.g. `ca_call_cfunc_1_1`
→ `"10"`, `ca_call_cfunc_3_3` → `"111000"`, `ca_call_cfunc_2_1` → `"110"`.

Call the raw layer directly only when you are managing operands yourself
(you already hold prepared CArray `VALUE`s and want explicit control over
which are written back) — for example an in-place transform that writes
back into an input array (`fsync = "1"`). Most code should use the typed
dispatcher.

## Reentrant `_r` variants (userdata)

Every raw and typed function has an `_r` sibling that threads a trailing
`void *userdata` to **every** per-cell callback invocation. This is the
POSIX `_r` convention (cf. `qsort_r`), and it is the idiomatic way to
give the kernel outer context — a scale factor, a configuration flag, a
library plan handle, a running counter — **without file-static or global
state**.

```c
typedef struct { double scale; double threshold; size_t hit_count; } ud_t;

/* kernel gains a trailing void *userdata */
static void
kernel_2_2 (void *p_y, void *p_x, void *p_a, void *p_b, void *userdata)
{
  ud_t *ud = (ud_t *) userdata;
  double a = *(double *) p_a, b = *(double *) p_b;
  *(double *) p_y = a * ud->scale;
  *(double *) p_x = b * ud->scale;
  if (a > ud->threshold) ud->hit_count++;   /* userdata may be MUTATED */
}

static VALUE
demo (VALUE self, VALUE r_a, VALUE r_b, VALUE r_scale, VALUE r_threshold)
{
  ud_t ud = { NUM2DBL(r_scale), NUM2DBL(r_threshold), 0 };
  VALUE result = ca_call_cfunc_2_2_r(CA_DOUBLE, CA_DOUBLE,   /* outputs */
                                     CA_DOUBLE, CA_DOUBLE,   /* inputs  */
                                     kernel_2_2, r_a, r_b, &ud);
  return rb_ary_new3(2, result, LONG2NUM((long) ud.hit_count));
}
```

The full runnable example is `examples/c-extensions/cfunc_r/cfunc_r.c`
(mirrored as the regression fixture `spec_ai/ext_cfunc_r_smoke/cfunc_r.c`).

> **Note — there is no `_ex` variant.** A proposed `ca_call_cfunc_M_N_ex`
> with declarative userdata / params / mask-policy slots was explored and
> **rejected**. The `_r` userdata
> passthrough covers the outer-state need; richer per-operand mask policy
> belongs in the kernel_iterator surface, not here.

## What the bridge handles for you

- **Data-type adaptation** — inputs are wrapped to their declared type
  (`rb_ca_wrap_readonly`); the kernel always sees the declared C type.
- **Output allocation** — outputs are templated from the (broadcast)
  input shape with the declared output type.
- **Broadcasting** — scalar operands collapse (stride 0); non-scalar
  operands must agree in shape (a shape mismatch raises). There is no
  implicit NumPy-style trailing-axis alignment (CArray policy).
- **Mask handling** — the masks of all **input** operands are OR-folded
  and propagated to the outputs; masked cells are **skipped** (the
  callback is not invoked for them). You never touch mask pointers.
- **Attach-safety** — input-only operands (`fsync == '0'`) are **never**
  attached: the engine alias-checks and, for non-alias views, uses
  `ALLOCV` + `ca_xfer_all` to get a contiguous read buffer. Only output
  operands (`fsync == '1'`) use `ca_attach` + `ca_sync`. This honors the
  input-only-operand invariant (no giant-parent materialise from a
  shrinking input view).
- **Scalar fold-back** — rank-0 outputs are returned as plain Ruby
  scalars, matching CArray's scalar surface.

The per-operand acquire/broadcast/mask/release lifecycle lives in
`ext/ca_sweep_engine.{c,h}`; each `ca_call_cfunc_N` keeps only the
arity-specific inner loop.

## Arity matrix

Generated by `ext/mk_call_cfunc.rb`:

- **Raw**: `ca_call_cfunc_1` … `ca_call_cfunc_7` (+ `_r`). Total operands
  1–7.
- **Typed** `ca_call_cfunc_M_N` (+ `_r`), `M` outputs × `N` inputs:

  | outputs `M` | available inputs `N` |
  |---|---|
  | 1 | 1, 2, 3, 4, 5, 6 |
  | 2 | 1, 2, 3, 4 |
  | 3 | 1, 2, 3 |

  (constrained by the raw max of 7 total operands). Need a pair outside
  this matrix, or more than 7 operands? Add it to `TYPED_PAIRS` /
  `RAW_ARITIES` in `ext/mk_call_cfunc.rb` and regenerate, or drop to the
  raw layer.

**Regenerating**: the generator runs at build time (extconf / Makefile
rule, same pattern as the other CArray generators). `CARRAY_DEV=1 rake
build_ext` picks up edits to `mk_call_cfunc.rb` automatically.

## Discipline

- **This is a scalar-callback bridge, not a kernel framework.** Use it
  to wrap an existing per-cell C function. For per-axis work, reductions,
  scans, or contig-fiber kernels, use kernel_iterator
  ([`HOW_TO_WRITE_KERNEL.md`](HOW_TO_WRITE_KERNEL.md)); for a standard op
  across the full data-type matrix, use the mkkernel DSL
  ([`MkKernelDSL.md`](MkKernelDSL.md)).
- **Don't hand-roll the attach lifecycle around a scalar function.**
  Reaching for `ca_attach_n` + a per-data-type kernel to apply a scalar C
  routine is the pre-3.0 pattern this surface replaced; it reintroduces
  the shrinking-view giant-parent materialise problem. Let `call_cfunc`
  own the lifecycle.
- **Carry outer state via `_r` userdata, not file-static / globals.**
- **Don't add a thin `mygem_*` wrapper** around `ca_call_cfunc_*`. Call
  the CArray primitive directly.

## See also

- [`HOW_TO_WRITE_KERNEL.md`](HOW_TO_WRITE_KERNEL.md) — the kernel_iterator
  C author surface (per-axis / reduction / scan / contig-fiber).
- [`MkKernelDSL.md`](MkKernelDSL.md) — the mkkernel DSL (standard op
  families across all data types).
- [`WritingCExtensions.md`](WritingCExtensions.md) — first-generation
  `ca_attach` / `ca_sync` C extension guide.
- `ext/mk_call_cfunc.rb` — the generator (arity matrix + template).
- `examples/c-extensions/cfunc_r/cfunc_r.c` — runnable `_r` example.
