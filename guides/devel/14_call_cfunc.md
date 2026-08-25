# 14 call_cfunc

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

`ca_call_cfunc_*` is the **scalar-callback bridge**: it takes a plain C
function that operates on one cell at a time
(`void (*)(void *p0, void *p1, …)`) and runs it across whole CArray
operands, handling data-type adaptation, output allocation, mask
propagation, broadcasting, and the attach / sync lifecycle for you. It is
how a C extension wraps an existing scalar C math routine — `lgamma`,
a GSL special function, a PROJ coordinate transform — into a vectorised
CArray operation.

It is one of three author surfaces. Pick by shape:

| You are writing… | Use |
|---|---|
| a standard op across all data types (sum, sqrt, `+`, sort, …) | the **mkkernel DSL** — [ch. 12](12_mkkernel_dsl.md) |
| a per-axis / reduction / scan / contig-fiber kernel | the **kernel iterator** — [ch. 11](11_kernel_iterator.md) |
| a wrapper around a scalar C function (one cell in → one cell out, fixed data type) | **`ca_call_cfunc_*`** (this chapter) |

`call_cfunc` is the oldest of the three (the "function/callback form"
sibling of the L0 per-element macro). It predates the kernel iterator
and is intentionally kept: it is the most ergonomic surface when you
already have a scalar C function and just want it applied element-wise
with automatic casting and masking. Companion gems (carray-gsl, a PROJ
binding, …) are its main consumers, and a few in-tree functions use it
(`CAMath.lgamma`, `CAMath.sph_to_xyz`).

This chapter is the developer-framing reference for the surface, with
complete signature listings.

> The whole `ca_call_cfunc_*` family is **generated** by
> `ext/mk_call_cfunc.rb` into `ext/carray_call_cfunc.c` +
> `ext/carray_call_cfunc.h`. Declarations are pulled in transparently
> via `carray.h`'s umbrella include. Do not edit the generated files;
> to add an arity, edit the generator. See [the arity matrix](#arity-matrix).

## The two layers

- **Typed dispatcher `ca_call_cfunc_M_N`** — the surface you normally
  call. You declare the data type of each operand; it wraps inputs to
  their declared type, allocates the output(s), runs the kernel, and
  returns the result(s). `M` = number of **outputs**, `N` = number of
  **inputs**.
- **Raw layer `ca_call_cfunc_N`** — `N` already-prepared CArray
  operands plus an `fsync` string saying which are outputs. The typed
  dispatcher is a thin wrapper over this; call it directly only when
  you need to manage the operands yourself.

Both layers have **reentrant `_r` siblings** that thread a `void *userdata`
through to every callback invocation.

## The typed dispatcher `ca_call_cfunc_M_N`

This is the normal entry point. The signature shape for `M` outputs and
`N` inputs:

```c
VALUE ca_call_cfunc_M_N(
    int8_t dty1, …, int8_t dtyM,     /* output data types */
    int8_t dtx1, …, int8_t dtxN,     /* input data types  */
    void (*kernel)(void *p_out1, …, void *p_outM,
                   void *p_in1,  …, void *p_inN),
    VALUE rx1, …, VALUE rxN);        /* input CArray VALUEs */
```

The kernel's pointer order is **outputs first, then inputs** — the same
order as the data-type arguments. Each `void *` points at one cell of
the corresponding operand; cast it to the declared C type and read /
write.

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

(`CA_DOUBLE` is the `CA_FLOAT64` alias.) If `rx1` is an `int32` array
it is auto-cast to `float64` on read; the result is a fresh `float64`
array shaped like `rx1`. If `rx1` is a scalar (rank-0), the return is
a Ruby Float rather than a CArray (`M == 1` outputs scalar-fold; see
below).

### Example: 3 outputs, 3 inputs (spherical → cartesian)

```c
static void
mathfunc_sph_to_xyz (void *p0, void *p1, void *p2,    /* x, y, z (out) */
                     void *p3, void *p4, void *p5)    /* r, theta, phi (in) */
{
  double r = *(double *) p3, theta = *(double *) p4, phi = *(double *) p5;
  *(double *) p0 = r * sin(theta) * cos(phi);
  *(double *) p1 = r * sin(theta) * sin(phi);
  *(double *) p2 = r * cos(theta);
}

static VALUE
rb_camath_sph_to_xyz (VALUE mod, VALUE rx1, VALUE rx2, VALUE rx3)
{
  return ca_call_cfunc_3_3(CA_DOUBLE, CA_DOUBLE, CA_DOUBLE,   /* 3 outputs */
                           CA_DOUBLE, CA_DOUBLE, CA_DOUBLE,   /* 3 inputs  */
                           mathfunc_sph_to_xyz, rx1, rx2, rx3);
}
```

### Return value

`M == 1` returns the single output CArray (or a scalar Ruby value when
rank-0). `M > 1` returns a Ruby Array of the `M` outputs (`[x, y, z]`
above), each scalar-folded if rank-0.

### What the dispatcher does, per output

- Each input is wrapped to its declared `dtx` via
  `rb_ca_wrap_readonly` ([ch. 15](15_carray_h_helper_reference.md)) —
  zero-cost when the type already matches, a `CAFake` cast view
  otherwise.
- Each output is a fresh template (`rb_ca_template_n`) shaped by
  broadcasting the inputs, with the declared `dty` data type.
- It delegates to the raw `ca_call_cfunc_(M+N)` with `fsync` built as
  `"1"*M + "0"*N` (outputs first).

## The raw layer `ca_call_cfunc_N` + fsync

```c
VALUE ca_call_cfunc_N(void (*func)(void *p0, …, void *p_{N-1}),
                      const char *fsync,
                      VALUE rcx0, …, VALUE rcx_{N-1});
```

`N` is the **total** operand count (outputs + inputs). `fsync` is an
`N`-character string of `'1'` / `'0'`:

- `'1'` — this operand is an **output**: attach + sync-back (the
  kernel writes to it; changes are written through to the array).
- `'0'` — this operand is an **input**: read-only, never attached
  (see the attach-safety contract below).

Operands are passed in `fsync` order. The typed dispatcher's `fsync`:

| Dispatcher | `fsync` |
|---|---|
| `ca_call_cfunc_1_1` | `"10"` |
| `ca_call_cfunc_2_1` | `"110"` |
| `ca_call_cfunc_1_2` | `"100"` |
| `ca_call_cfunc_3_3` | `"111000"` |
| `ca_call_cfunc_2_4` | `"110000"` |

Call the raw layer directly only when you are managing operands
yourself — for example an in-place transform that writes back into an
input array (`fsync = "1"`). Most code should use the typed dispatcher.

## Reentrant `_r` variants (userdata)

Every raw and typed function has an `_r` sibling that threads a
trailing `void *userdata` to **every** per-cell callback invocation.
This is the POSIX `_r` convention (cf. `qsort_r`), and it is the
idiomatic way to give the kernel outer context — a scale factor, a
configuration flag, a library plan handle, a running counter —
**without** file-static or global state.

```c
typedef struct {
  double scale;
  double threshold;
  size_t hit_count;
} ud_t;

/* kernel gains a trailing void *userdata */
static void
kernel_2_2 (void *p_y, void *p_x, void *p_a, void *p_b, void *userdata)
{
  ud_t *ud = (ud_t *) userdata;
  double a = *(double *) p_a, b = *(double *) p_b;
  *(double *) p_y = a * ud->scale;
  *(double *) p_x = b * ud->scale;
  if (a > ud->threshold) ud->hit_count++;       /* userdata may be MUTATED */
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

The full runnable example is
`samples/c-extensions/cfunc_r/cfunc_r.c` (mirrored as the regression
fixture `spec_ai/ext_cfunc_r_smoke/cfunc_r.c`).

> **There is no `_ex` variant.** A proposed `ca_call_cfunc_M_N_ex` with
> declarative userdata / params / mask-policy slots was explored and
> **rejected**. The `_r` userdata
> passthrough covers the outer-state need; richer per-operand mask
> policy belongs in the kernel-iterator surface, not here.

## What the bridge handles for you

- **Data-type adaptation** — inputs are wrapped to their declared type
  (`rb_ca_wrap_readonly`); the kernel always sees the declared C type.
- **Output allocation** — outputs are templated from the (broadcast)
  input shape with the declared output type.
- **Broadcasting** — scalar operands collapse (stride 0); non-scalar
  operands must agree in shape (a shape mismatch raises). There is no
  implicit NumPy-style trailing-axis alignment (CArray policy).
- **Mask handling** — the masks of all **input** operands are OR-folded
  into a single mask byte array and propagated to the outputs; masked
  cells are **skipped** (the callback is not invoked for them). You
  never touch mask pointers.
- **Attach-safety** — input-only operands (`fsync == '0'`) are
  **never** attached: the engine alias-checks via `ca_iter_can_alias`
  and, for non-alias views, uses `xmalloc` + `ca_xfer_all` to get a
  contiguous read buffer. Only output operands (`fsync == '1'`) use
  `ca_attach` + `ca_sync`. This honors the input-only-operand
  invariant (no giant-parent materialise from a shrinking input
  view).
- **Scalar fold-back** — rank-0 outputs are returned as plain Ruby
  scalars, matching CArray's scalar surface.

The per-operand acquire / broadcast / mask / release lifecycle lives in
`ext/ca_sweep_engine.{c,h}` (the same engine the sweep family uses,
[ch. 13](13_sweep_author_surface.md)); each `ca_call_cfunc_N` keeps
only the arity-specific inner loop.

## Arity matrix

Generated by `ext/mk_call_cfunc.rb`:

**Raw layer**: `ca_call_cfunc_1` … `ca_call_cfunc_7` (+ `_r`). Total
operands 1–7. Their full signatures (from `carray_call_cfunc.h`):

```c
VALUE ca_call_cfunc_1 (void (*func)(void *p0),
                       const char *fsync, VALUE rcx0);
VALUE ca_call_cfunc_2 (void (*func)(void *p0, void *p1),
                       const char *fsync, VALUE rcx0, VALUE rcx1);
VALUE ca_call_cfunc_3 (void (*func)(void *p0, void *p1, void *p2),
                       const char *fsync, VALUE rcx0, VALUE rcx1, VALUE rcx2);
/* ... through ca_call_cfunc_7 ... */

VALUE ca_call_cfunc_1_r (void (*func)(void *p0, void *userdata),
                         const char *fsync, VALUE rcx0, void *userdata);
/* ... through ca_call_cfunc_7_r ... */
```

**Typed dispatcher** `ca_call_cfunc_M_N` (+ `_r`), `M` outputs × `N`
inputs:

| outputs `M` | available inputs `N` |
|---|---|
| 1 | 1, 2, 3, 4, 5, 6 |
| 2 | 1, 2, 3, 4 |
| 3 | 1, 2, 3 |

Constrained by the raw max of 7 total operands. Need a pair outside
this matrix, or more than 7 operands? Add it to `TYPED_PAIRS` /
`RAW_ARITIES` in `ext/mk_call_cfunc.rb` and regenerate, or drop to
the raw layer.

Sample typed signatures (output and input data types listed first,
then the kernel, then the operand VALUEs):

```c
VALUE ca_call_cfunc_1_1 (int8_t dty,  int8_t dtx1,
                         void (*mathfunc)(void *, void *),
                         volatile VALUE rx1);
VALUE ca_call_cfunc_2_2 (int8_t dty1, int8_t dty2,
                         int8_t dtx1, int8_t dtx2,
                         void (*mathfunc)(void *, void *, void *, void *),
                         volatile VALUE rx1, volatile VALUE rx2);
VALUE ca_call_cfunc_3_3 (int8_t dty1, int8_t dty2, int8_t dty3,
                         int8_t dtx1, int8_t dtx2, int8_t dtx3,
                         void (*mathfunc)(void *, void *, void *,
                                          void *, void *, void *),
                         volatile VALUE rx1, volatile VALUE rx2, volatile VALUE rx3);
```

The `_r` variants add a trailing `void *userdata` to every callback's
signature **and** to the dispatcher's argument list.

**Regenerating**: the generator runs at build time (extconf /
Makefile rule, same pattern as the other CArray generators).
`CARRAY_DEV=1 rake build_ext` picks up edits to `mk_call_cfunc.rb`
automatically.

## Naming

`ca_call_cfunc_*` takes `CArray *`-like inputs in spirit, but the
entry-point signatures actually accept `VALUE`s (it's a Ruby-level
bridge). The current name is a historical quirk — by the prefix
convention (`rb_ca_*` for VALUE inputs, `ca_*` for `CArray *`), a future
rename to `rb_ca_call_cfunc_*` would align with it. Until
then, keep the `ca_*` prefix in mind when reading the source; the
function takes VALUEs.

## Discipline

- **This is a scalar-callback bridge, not a kernel framework.** Use
  it to wrap an existing per-cell C function. For per-axis work,
  reductions, scans, or contig-fiber kernels, use the kernel iterator
  ([ch. 11](11_kernel_iterator.md)); for a standard op across the
  full data-type matrix, use the mkkernel DSL
  ([ch. 12](12_mkkernel_dsl.md)).
- **Don't hand-roll the attach lifecycle around a scalar function.**
  Reaching for `ca_attach_n` + a per-data-type kernel to apply a
  scalar C routine is the pre-3.0 pattern this surface replaced; it
  reintroduces the shrinking-view giant-parent materialise problem.
  Let `call_cfunc` own the lifecycle.
- **Carry outer state via `_r` userdata, not file-static / globals.**
- **Don't add a thin `mygem_*` wrapper** around `ca_call_cfunc_*`.
  Call the CArray primitive directly rather than inflating the
  vocabulary with a parallel name.
- **One scalar per call.** The bridge invokes the callback once per
  cell. For a kernel that needs the whole fiber at once (sort,
  search, FFT), use the kernel iterator's FIBER family or
  `CA_WITH_BUFFER` ([ch. 13](13_sweep_author_surface.md)).

## See also

- [ch. 11 The kernel iterator](11_kernel_iterator.md) — the
  per-axis / reduction / scan / contig-fiber surface.
- [ch. 12 The mkkernel DSL](12_mkkernel_dsl.md) — declarative
  generation for standard op families across all data types.
- [ch. 13 The sweep author surface](13_sweep_author_surface.md) —
  whole-buffer / flat-element surfaces sharing the same engine.
- [ch. 15 carray.h helper reference](15_carray_h_helper_reference.md)
  — the primitives the bridge calls into.
- `ext/mk_call_cfunc.rb` — the generator (arity matrix + template).
- `samples/c-extensions/cfunc_r/cfunc_r.c` — runnable `_r` example.

---
*When done, update the status row in [README](README.md).*
