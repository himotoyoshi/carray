# Sweep author surface — element-wise macros on `xfer_all`

C ext authors writing CArray-aware kernels typically need one of three
things:

1. *per-element loops* over a single CArray with inline body and local
   state ("sum this", "find max", "predicate test")
2. *whole contig buffer access* to hand off to a third-party C library
   ("call FFTW on this buffer", "feed this to fitpack's solver")
3. *per-element loops* over several CArrays in parallel ("y = sqrt(x)",
   "(lon, lat) -> (x, y) projection")

The **sweep author surface** covers (1) and (2) with two macro families
built directly on the `xfer_all` primitive. They never call `ca_attach`
on a view's ancestor (= no "ancestor cascade" memory peak), they
automatically chunk large INPUT views (= bounded memory peak), and
they pick zero-copy alias when the source is a contig entity. The
author writes a normal C loop; everything else is the engine's job.

For (3) — multi-array element-wise — see the existing
`ca_call_cfunc_M_N` family. It now uses the same engine helper
internally, and a reentrant `ca_call_cfunc_M_N_r` variant is also
provided (= POSIX `_r` convention) that takes a trailing
`void *userdata` plumbed to every callback invocation. Use `_r` when
the kernel needs to share state with the caller (accumulators,
configuration flags, library plan handles) without resorting to
file-static / global plumbing — the simple-proj-carray and
carray-fftw3 migration path. The public API of the non-`_r`
variants is unchanged.

There is no `_ex`-suffix declarative variant (= mask policy enum +
params array bundled into one signature); that variant was explored
and rejected.

Multi-array kernels with heavy outer-state capture but no need to
factor a kernel out to a separate function are also expressible by
nesting two `CA_FOR_EACH_ELEMENT` loops or by dropping to
`ca_set_iterator` + a hand-rolled loop.

## Family 1: `CA_FOR_EACH_ELEMENT` (single-array per-cell loop)

Header: `ca_for_each_element.h`. State struct: `ca_each_state_t` (one
operand) or `ca_each_map_state_t` (input + output). Five forms cover the
common cases.

### Read-only

```c
ca_each_state_t st;
double x;
double sum = 0;
CA_FOR_EACH_ELEMENT(st, ca, double, x) {
  sum += x;
}
```

`x` is assigned per cell from the broadcast-shape view of `ca`. If
`ca` carries a mask, this form raises a `RuntimeError` (use the
`_MASKED` form instead).

### Read-only with mask byte

```c
ca_each_state_t st;
double x;
boolean8_t m;
ca_size_t cnt = 0;
CA_FOR_EACH_ELEMENT_MASKED(st, ca, double, x, m) {
  if (!m) cnt++;
}
```

`m` is the per-cell mask byte (`1` = masked, `0` = unmasked). When the
source has no mask, `m` is always `0`.

### Input → output map (no mask)

```c
ca_each_map_state_t st;
double in;
double out;
CA_FOR_EACH_ELEMENT_INOUT(st, ca_in, ca_out, double, double, in, out) {
  out = in * in;
}
```

`ca_in` and `ca_out` must have *strictly equal shape* (ndim + every
`dim[k]`); the engine raises on mismatch. The macro reads `in` per
cell, runs the body, and writes `out` back to `ca_out`. Mismatched
masks raise.

### Input → output with mask

```c
ca_each_map_state_t st;
double in, out;
boolean8_t m_in, m_out;
CA_FOR_EACH_ELEMENT_INOUT_MASKED(st, ca_in, ca_out, double, double,
                                  in, out, m_in, m_out) {
  if (m_in)         { m_out = 1; out = 0.0; }
  else if (in < 0)  { m_out = 1; out = 0.0; }
  else              { m_out = 0; out = sqrt(in); }
}
```

`m_in` reads INPUT mask (defaults `m_out = m_in` before the body, so
no-op propagation is the default). Author writes to `m_out` and `out`
land in `ca_out` and its mask. The mask propagation runs at release
time, so per-cell `m_out` writes are visible in the final
`ca_out.mask`.

> Note: when the source has no mask, `m_in` is always `0` and writes
> to `m_out` are silently dropped. If you need to *create* a mask in
> `ca_out` from a maskless source, the macro doesn't auto-allocate one;
> use `ca_create_mask(ca_out)` before the loop in that case.

### Write-only (fill / iota)

```c
ca_each_state_t st;
double out;
ca_size_t k = 0;
CA_FOR_EACH_ELEMENT_OUT(st, ca_out, double, out) {
  out = offset + step * (double) k;
  k++;
}
```

Author writes `out` per cell. `k` is the author's own counter (no
implicit cell index); the macro just iterates `chunk_n` cells per
chunk, and `k` survives across chunks because it's lexically captured.

### Memory peak guarantee

Non-alias INPUT views (`a[mask]`, `a.transpose`, `a[start..stop]`, ...)
materialise into a single chunk scratch (~32 KB at f64). A 10M-element
transpose view sees roughly 32 KB peak around the loop, not 80 MB.

### Constraints (same as `CA_FOR_EACH_FIBER`)

- `break;` from the body exits cleanly; the outer for's advance clause
  still runs release.
- `return;` from the body **leaks** scratch buffers and the OUTPUT
  attach. Restructure as `break;` and return after the macro.
- The macros are *not* statement-equivalent — they expand to nested
  `for` loops. Do not follow them with `else`.

## Family 2: `CA_WITH_BUFFER` (whole contig buffer to a library)

Header: `ca_for_buffer.h`. Two macros for read-only / writable access,
plus a function form for Ruby-exception safety.

### Read-only

```c
double *ptr;
ca_size_t n;
CA_WITH_BUFFER(ca, double, ptr, n) {
  /* ptr : double const * (n cells), native contig layout.
     Hand off to a library, scan in any direction, ... */
  some_library_read(ptr, n);
}
```

`ptr` is the alias of `ca->ptr` if `ca` is a contig entity (zero
copy), or a materialised contig buffer if `ca` is a view.

### Writable (= scatter back on exit)

```c
double *ptr;
ca_size_t n;
CA_WITH_BUFFER_WRITABLE(ca, double, ptr, n) {
  fftw_execute_dft(plan, ptr, ptr);
}
```

Same as read-only, plus `ca_sync` on block exit propagates writes back
to the view's storage. Author writes through a slice view land in the
parent.

### `break`-safe, `return`-leaks

Same convention as `CA_FOR_EACH_ELEMENT`. If your body must be safe
against arbitrary Ruby exceptions, use the function form below.

### Function form: `rb_ca_call_with_buffer` (rb_ensure-protected)

```c
typedef struct { double *out; } ud_t;

static void
my_body (void *user_data, void *ptr, ca_size_t n)
{
  ud_t *ud = (ud_t *) user_data;
  double *p = (double *) ptr;
  /* may rb_raise here; ensure runs anyway */
  ud->out[0] = sum(p, n);
}

VALUE
my_method (VALUE self, VALUE r_ca)
{
  ud_t ud = { ... };
  rb_ca_call_with_buffer(r_ca, /*writable=*/0, my_body, &ud);
  return ...;
}
```

This wraps the `ca_attach` / body / `ca_sync` (writable) / `ca_detach`
cycle in `rb_ensure`. If `body` raises a Ruby exception, `ca_sync` (if
writable) still runs so any partial writes propagate, then `ca_detach`
returns the attach, then the exception continues to unwind. Use this
whenever the body calls Ruby code or anything that can raise.

## Worked example: rewriting a typical ext gem call

Hand-written reduction over a CArray that takes an FFTW-style
in-place pass (writable + library call). The "before" form below is
what most `~/Dropbox/CArray/carray-fftw3/` and similar gems currently
write — `ca_attach_n`, raw pointer indexing, manual `ca_sync` +
`ca_detach`, no rb_ensure protection.

### Before (~60 lines, no exception safety)

```c
static VALUE
fftw_inplace_pass (VALUE self, VALUE r_in)
{
  CArray *ca;
  TypedData_Get_Struct(r_in, CArray, &carray_data_type, ca);
  ca_check_type(ca, CA_FLOAT64);

  ca_attach(ca);   /* may attach an ancestor for views */
  double *p = (double *) ca->ptr;
  ca_size_t n = ca->elements;

  /* ... plan setup ... */
  fftw_execute_dft(plan, p, p);   /* may raise if called via Ruby cb */

  ca_sync(ca);
  ca_detach(ca);
  return r_in;
}
```

### After (~10 lines, exception-safe via function form)

```c
typedef struct { fftw_plan plan; } ud_t;

static void
fftw_body (void *user_data, void *ptr, ca_size_t n)
{
  ud_t *ud = (ud_t *) user_data;
  fftw_execute_dft(ud->plan, (double *) ptr, (double *) ptr);
}

static VALUE
fftw_inplace_pass (VALUE self, VALUE r_in)
{
  ud_t ud = { /* plan = ... */ };
  rb_ca_call_with_buffer(r_in, /*writable=*/1, fftw_body, &ud);
  return r_in;
}
```

Or, if the body is short and exception-free:

```c
static VALUE
fftw_inplace_pass (VALUE self, VALUE r_in)
{
  CArray *ca;
  double *p;
  ca_size_t n;
  TypedData_Get_Struct(r_in, CArray, &carray_data_type, ca);
  CA_WITH_BUFFER_WRITABLE(ca, double, p, n) {
    fftw_execute_dft(plan, p, p);
  }
  return r_in;
}
```

## What's not here

- **Multi-array element-wise**: use the existing `ca_call_cfunc_M_N`
  family (unchanged in this phase). For outer-state-heavy patterns
  (PROJ-style), drop to `ca_set_iterator` + a hand-written loop, or
  nest two `CA_FOR_EACH_ELEMENT` loops.
- **Per-axis kernels** (reductions, scans, sliding windows): use the
  `CA_FOR_EACH_SLAB` / `CA_FOR_EACH_FIBER` families
  (`ca_kernel_iterator.h`).
- **Three or more operand `CA_FOR_EACH_ELEMENT`**: not provided yet
  (state_3_t / state_4_t would be needed; demand-driven future
  addition).
- **Profile-driven chunk size tuning**: the chunk target is `4096`
  elements (~32 KB at f64) by default. Replace at the engine level
  (`ca_chunk_compute_n`) if you measure something better for a
  specific dtype mix.

## See also

- `ext/ca_sweep_engine.{h,c}` — the engine (`ca_sweep_acquire_chunked`,
  `ca_sweep_next_chunk`, `ca_sweep_release_chunked`, `rb_ca_call_with_buffer`)
- `ext/ca_for_each_element.h` — ELEMENT macros
- `ext/ca_for_buffer.h` — WHOLE_BUFFER macros + function form
- `docs/HOW_TO_WRITE_KERNEL.md` — the kernel-author macro suite
  catalog (FIBER / SLAB) for higher-level per-axis loops
