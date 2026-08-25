# 15a Common idioms

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

The primitive catalogue in [ch. 15](15_carray_h_helper_reference.md) tells
you *which function* to call. This chapter is the **idiom register** for
the recurring shapes those calls take. Option parsing, argument
unpacking, output allocation, the wrap-then-template dance — every
extension does these in roughly the same way, and when one extension
does it differently the next person to read it spends an hour figuring
out why.

If you are about to write a new bit of boilerplate at a Ruby method
boundary, the right thing is almost certainly already in this chapter.
Find the closest match, copy its shape, and move on. The point is not
that the idioms are clever — it's that they are **uniform**.

## Method-entry idioms

### Get the C struct

The shortest path from a `VALUE` argument to a `CArray *`:

```c
static VALUE
rb_ca_some_op (VALUE self, VALUE varg)
{
  CArray *ca;
  GetCArray(self, ca);          /* expands to TypedData_Get_Struct */
  /* ... */
}
```

`GetCArray` is defined in [ch. 15](15_carray_h_helper_reference.md) — it
accepts any concrete CArray subclass because every TypedData is
registered with `carray_data_type` as parent. **Never** call
`TypedData_Get_Struct` by hand: use `GetCArray`.

### Refuse to mutate a frozen receiver

Any method that writes through `self` opens with:

```c
rb_check_frozen(self);
```

This replaces the historical `rb_ca_modify(self)` — same effect, but it
is the Ruby-standard predicate, so reviewers don't have to remember a
CArray-specific check. Place it **before** allocation: a frozen-receiver
raise should not leak a half-built scratch buffer.

### Scan positional args + a trailing options Hash

The canonical "N positional + optional kwarg Hash" entry takes exactly
three forms:

```c
/* Form A — fixed positional count + options */
volatile VALUE rtype, rdim, ropt, rbytes = Qnil;
rb_scan_args(argc, argv, "21", &rtype, &rdim, &ropt);   /* 2 required, 1 optional */
rb_scan_options(ropt, "bytes", &rbytes);

/* Form B — Ruby 3.0 keyword args ("1:" = 1 required + kwarg Hash) */
VALUE ca_obj, kw_hash, axis_val = Qnil;
rb_scan_args(argc, argv, "1:", &ca_obj, &kw_hash);
rb_scan_options(kw_hash, "axis", &axis_val);

/* Form C — variadic *args + trailing options (CArray-style shorthand) */
volatile VALUE ropt = rb_pop_options(&argc, &argv);   /* pop trailing Hash */
volatile VALUE rdim = rb_ary_new4(argc, argv);
rb_scan_options(ropt, "bytes", &rbytes);
```

Rules of thumb:

- `rb_scan_args` is the Ruby-built-in: use its format string (`"21"`,
  `"11"`, `"1:"`, `"*:"`) for fixed signatures.
- `rb_pop_options` is the CArray shorthand for **"split off the trailing
  Hash from `argc/argv`"** — it mutates `argc` and the `argv` slice so the
  Hash is removed (or substituted with `Qnil`). Use it when the
  positionals are variadic and a fixed-format string doesn't fit.
- `rb_scan_options(opt_hash, "key1,key2,…", &v1, &v2, …)` extracts known
  keys. Unrecognised keys raise. The keys live in a single
  comma-separated string — it's not a typo.
- `volatile VALUE` for any VALUE that lives across a function call that
  may allocate (`rb_funcall`, `rb_scan_options`, etc.) — protects from
  the compacting GC. This is universal across CArray's C code.

### Parse an `axis:` argument

For methods that take `axis: 0` / `axis: [0, 1]` / `axis: nil`, never
hand-roll the parse. There are two helpers; pick by signature shape:

```c
/* Variadic — `a.sum(0, 1)` style */
int8_t axes[CA_RANK_MAX];
int8_t naxes = rb_ca_parse_reduce_axes(argc, argv, ca, axes);

/* Kwarg — `a.sort(axis: 1)` style */
int8_t axes[CA_RANK_MAX];
int8_t naxes = rb_ca_parse_reduce_axes_kw(axis_val, ca, axes);
```

Both accept Integer, an `Array` of Integers, or `Qnil/Qundef` (= full
reduction). They normalise negative axes Python-style, check for
duplicates, range, and overflow, and raise `ArgumentError` on any
violation. `naxes` is the count; `axes[0..naxes-1]` is sorted ascending
on return — exactly the shape `ca_iter_state_init_l2` and
`rb_ca_new_reduced` want.

### Type-coerce an input to a fixed data type

When a kernel demands `CA_FLOAT64` (or any specific type) and the
caller might pass an integer array:

```c
/* C-level: keeps the resulting CArray * for direct use */
CArray *cx = ca_wrap_readonly(rx_value, CA_FLOAT64);
/* cx points into a CAFake cast view (zero-cost when type matches);
   rx_value is rebound to that view on return. */

/* VALUE-level: when you just need the wrapped VALUE */
VALUE rx_f64 = rb_ca_wrap_readonly(rx, INT2NUM(CA_FLOAT64));
```

`rb_ca_wrap_readonly` is **pass-through** when the data type already
matches — no allocation, no copy, no CAFake. It costs only the type
check on the fast path; reach for it freely.

Use `rb_ca_wrap_writable` (or `ca_wrap_writable`) when the wrapped view
must accept writes. This is rare — most kernels write only to outputs
they allocated themselves.

### Validate shapes

Raise on mismatch — these are the canonical checks
([ch. 15](15_carray_h_helper_reference.md)):

```c
ca_check_same_shape (ca1, ca2);     /* full ndim + dim[] equality */
ca_check_same_elements (ca1, ca2);  /* total cell count only */
ca_check_same_ndim (ca1, ca2);
ca_check_same_data_type (ca1, ca2);
ca_check_shape (ca, ndim, dim);     /* against an explicit shape */
ca_check_type (ca, CA_FLOAT64);
```

Use the strongest one that fits the contract. Two operands the kernel
walks in lockstep need `ca_check_same_shape`; two operands that only
need to be broadcast-compatible need different handling
([ch. 13](13_sweep_author_surface.md), the sweep engine does the
broadcast itself).

## Output-allocation idioms

### Template from an input shape

For a single-input kernel whose output is shape-equal:

```c
VALUE vout = rb_ca_template_with_type(self, INT2NUM(CA_FLOAT64), Qnil);
CArray *co; GetCArray(vout, co);
```

`Qnil` for `rbytes` means "use the type's natural width". For `CA_FIXLEN`
pass an explicit `INT2NUM(width_in_bytes)`.

For a multi-input kernel whose output is shape-equal to the broadcast
of the inputs:

```c
VALUE vout = rb_ca_template_n(2, rx1, rx2);   /* broadcast-shape output */
```

The variadic count is the input count; the function broadcasts shape
across them. This is what `call_cfunc` ([ch. 14](14_call_cfunc.md)) uses
internally.

### Template for a reduction output

For a reduce kernel — output shape = input shape minus the slab axes:

```c
int8_t axes[CA_RANK_MAX];
int8_t naxes = rb_ca_parse_reduce_axes_kw(axis_val, ca, axes);

VALUE vout = rb_ca_new_reduced(self, axes, naxes, CA_FLOAT64, /*keep_axis=*/0);
CArray *co; GetCArray(vout, co);
```

`keep_axis = 1` preserves the reduced axes as size-1 (the `keepdims`
semantic). `keep_axis = 0` is the default — reduced axes collapse out.

When `naxes == ca->ndim` (full reduction), the result is a rank-0
`CScalar`. Most reduce kernels return a Ruby scalar in that case via
their `ruby_scalar:` wrapper — see [ch. 12](12_mkkernel_dsl.md).

### Allocate a brand-new entity

For a kernel that produces an output of a shape the input doesn't carry
(an `arange`-like generator, a histogram bin array, a fresh scratch):

```c
ca_size_t dim[1] = { n };
VALUE vout = rb_carray_new(CA_FLOAT64, 1, dim, 0, NULL);
CArray *co; GetCArray(vout, co);
```

`bytes = 0` says "use the type's natural width". The fifth `mask`
argument is `NULL` for "no mask".

For untrusted `dim[]` (it came from Ruby and might overflow `Π dim[i] *
bytes`):

```c
VALUE vout = rb_carray_new_safe(CA_FLOAT64, 1, dim, 0, NULL);
```

## Lifecycle idioms (when you can't use a higher-level surface)

### Attach a tuple of arrays, then detach in reverse order

When you genuinely need raw attach plumbing for N arrays
([ch. 4](04_attach_lifecycle.md), R4 rule — parent → child opening, child
→ parent closing):

```c
ca_attach_n(2, ca, ci);
/* ... kernel body that reads / writes ca->ptr, ci->ptr ... */
ca_detach_n(2, ca, ci);
```

The R1-R4 contract is in [ch. 4](04_attach_lifecycle.md); the short
version is: `_n` opens left-to-right and detaches right-to-left for you,
so it is symmetric.

For a WRITE path, interleave `ca_sync` before `ca_detach`:

```c
ca_attach_n(2, ca_in, ca_out);
/* ... write through ca_out->ptr ... */
ca_sync_n(1, ca_out);          /* push back */
ca_detach_n(2, ca_in, ca_out);
```

### Block-scoped attach

When the work is one self-contained chunk, prefer the block-form macro
that handles attach / sync / detach automatically — it's the same
discipline `attach!` enforces in Ruby, lifted to C:

```c
double   *p;
ca_size_t n;
CA_WITH_BUFFER_WRITABLE(ca, double, p, n) {
  /* p, n are the contig buffer + element count;
     ca_sync + ca_detach run on block exit */
  fftw_execute_dft(plan, p, p);
}
```

If the body may raise a Ruby exception, use `rb_ca_call_with_buffer`
(the `rb_ensure`-protected function form) instead —
[ch. 13](13_sweep_author_surface.md).

**Never** call `ca_attach` at a kernel entry as a shortcut for "give me
contig data". That is the materialise-everything anti-pattern the
iterator and sweep families exist to prevent
([ch. 10](10_author_surface_overview.md), principle 5).

## Mask-propagation idioms

### OR-fold input masks onto a fresh output

The default mask propagation a kernel performs on its output entity:

```c
ca_mask_overlay_safe(co, 2, ca1, ca2);
/* co inherits the union of ca1, ca2 masks. "safe" = uses xfer_all
   instead of ca_attach on the input masks, so no shrinking-view
   giant-parent materialise. */
```

This is what every multi-input arithmetic operator does (see
`carray_operator.c`); it's the idiom every new fusion / fma / clip-style
kernel should follow.

Variadic count comes first: `ca_mask_overlay_safe(co, n, m1, m2, …,
mn)`. For a 1-input map, `ca_mask_overlay_safe(co, 1, ca_in)` propagates
the single input mask.

### Overwrite (not OR) the output mask

When the kernel computes a fresh mask result (not a propagation):

```c
ca_copy_mask_overwrite(co, n, count, m1, m2, …);
```

Rare — the OR-fold is the default. Use this only when the kernel's
contract genuinely is "replace the output mask wholesale".

### Strip the mask

When the caller wants a non-masked copy with masked cells filled:

```c
CArray *result = ca_unmasked_copy(ca, &fill_value);
```

For Ruby-surface methods that take a `fill` parameter, prefer the
Ruby-level wrapper `rb_ca_unmask_copy` / `rb_ca_mask_fill_copy`
([ch. 15](15_carray_h_helper_reference.md)).

## Return-value idioms

### Scalar fold-back for a reduce kernel

A full reduction returns a Ruby scalar, not a rank-0 CArray. The pattern
the generated mkkernel dispatchers use (and that you should mirror in a
hand-written reduce):

```c
if ( naxes == ca->ndim ) {
  /* full reduction: return a Ruby scalar */
  double v = full_reduce_scalar(ca);
  return rb_float_new(v);
} else {
  /* per-axis: return a CArray */
  /* ... rb_ca_new_reduced + loop ... */
  return vout;
}
```

The scalar wrapper is picked by data type: `rb_float_new` for floats,
`LL2NUM` / `ULL2NUM` for ints, `BOOL2OBJ` for booleans, `rb_complex_new`
for complex. mkkernel exposes this via `ruby_scalar:` ([ch. 12](12_mkkernel_dsl.md)).

### Return self for in-place ops

A bang method (`#fill!`, `#sort!`) returns `self`:

```c
return self;
```

No allocation; the existing receiver is the result. Ruby idiom matches —
`Array#sort!`, `Array#fill` etc. do the same.

### Return a Ruby Array for multi-output kernels

For an `M > 1` outputs kernel:

```c
VALUE result = rb_ary_new_capa(M);
rb_ary_push(result, vout_x);
rb_ary_push(result, vout_y);
rb_ary_push(result, vout_z);
return result;
```

`rb_ary_new_capa(M)` pre-sizes the result so the pushes don't reallocate.
This is what `ca_call_cfunc_3_3` and fused `minmax` do.

## VALUE-handling idioms

### Always declare VALUEs that cross a possibly-allocating call `volatile`

```c
volatile VALUE ropt = rb_pop_options(&argc, &argv);
volatile VALUE rdim = rb_ary_new4(argc, argv);
```

The Ruby compacting GC can move objects across an allocating call; a
non-`volatile` VALUE may be cached in a register and miss the relocation.
The CArray convention is to mark **every** VALUE local with `volatile`
when in doubt — the cost is negligible, the bug it prevents is
catastrophic.

### Convert a Ruby Numeric to a C scalar

```c
double  d  = NUM2DBL(rv);
long    l  = NUM2LONG(rv);          /* or OBJ2LONG  — accepts coercible */
int64_t i  = NUM2LL(rv);            /* or OBJ2LL    — accepts coercible */
boolean8_t b = OBJ2BOOL(rv);
double complex c = NUM2CC(rv);      /* accepts Float / Integer / Complex */
```

The `NUM2*` family raises `TypeError` on non-numerics; the `OBJ2*`
family tries `to_int` / `to_f` first. Use `NUM2*` for documented
numeric-only parameters; use `OBJ2*` when accepting "anything coercible"
(Ruby idiom).

### Convert a C scalar back

```c
VALUE rv = rb_float_new(d);
VALUE rv = LL2NUM(i);              /* int64 → Bignum if needed */
VALUE rv = BOOL2OBJ(b);            /* → INT2FIX(0/1), NOT Qtrue/Qfalse */
VALUE rv = CC2NUM(c);              /* → Ruby Complex */
```

Note `BOOL2OBJ` returns `INT2FIX(0)` / `INT2FIX(1)` — CArray's bulk
boolean conversion idiom. For per-cell access where Ruby idiom calls for `true` /
`false`, the access path uses `Qtrue` / `Qfalse` directly.

## Error-raising idioms

### Standard error messages

Use the exception class Ruby would expect:

```c
rb_raise(rb_eArgError,    "expected Integer axis, got %s", rb_obj_classname(rv));
rb_raise(rb_eTypeError,   "can not convert to %s", ca_type_name[data_type]);
rb_raise(rb_eIndexError,  "index out of range (%lld <=> 0..%lld)", idx, dim-1);
rb_raise(rb_eRangeError,  "value out of range for %s", ca_type_name[data_type]);
rb_raise(rb_eRuntimeError,"internal: unexpected obj_type %d", ca->obj_type);
```

The `ArgError` / `TypeError` / `IndexError` / `RangeError` distinction
matches Ruby convention; `RuntimeError` is for internal invariants the
user should never hit (a bug, not a misuse).

### Don't editorialise

Error messages describe **what happened** — never compare with another
library:

```c
/* GOOD */
rb_raise(rb_eArgError, "shape mismatch: (%lld) vs (%lld)", n1, n2);

/* BAD — editorialising */
rb_raise(rb_eArgError, "broadcasting not supported (unlike NumPy)");
```

## Init / registration idioms

For `Init_<your_ext>` (the entry every C extension exports):

```c
void
Init_my_ext (void)
{
  VALUE m = rb_define_module("MyExt");

  /* method: VALUE entry_point(int argc, VALUE *argv, VALUE self) */
  rb_define_method(rb_cCArray, "my_method",      rb_ca_my_method,      -1);
  rb_define_method(rb_cCArray, "my_method!",     rb_ca_my_method_bang, -1);

  /* singleton on CArray */
  rb_define_singleton_method(rb_cCArray, "my_factory", rb_ca_s_my_factory, -1);

  /* alias */
  rb_define_alias(rb_cCArray, "my_alias", "my_method");

  /* module method on CAMath */
  rb_define_module_function(rb_mCAMath, "lgamma",  rb_camath_lgamma, 1);
}
```

Use `-1` arity (`int argc, VALUE *argv, VALUE self`) for any method
that takes options, axes, or variadic args. Fixed-arity methods take
the natural `(VALUE self, VALUE a, VALUE b, …)` signature with a
positive arity number.

`rb_cCArray` / `rb_mCAMath` / `rb_cCAView` / … are externs in `carray.h`
— see [ch. 15](15_carray_h_helper_reference.md).

## The structural pattern

Most kernel-binding C functions take exactly the same overall shape.
Once you see it, you see it everywhere:

```c
static VALUE
rb_ca_<op> (int argc, VALUE *argv, VALUE self)
{
  /* 1. Unpack arguments */
  volatile VALUE varg1, varg2, kw_hash, axis_val = Qnil;
  rb_scan_args(argc, argv, "2:", &varg1, &varg2, &kw_hash);
  rb_scan_options(kw_hash, "axis", &axis_val);

  /* 2. Bind self + parse axes */
  CArray *ca; GetCArray(self, ca);
  int8_t  axes[CA_RANK_MAX];
  int8_t  naxes = rb_ca_parse_reduce_axes_kw(axis_val, ca, axes);

  /* 3. Coerce + validate operands */
  VALUE rother = rb_ca_wrap_readonly(varg1, INT2NUM(CA_FLOAT64));
  CArray *cb; GetCArray(rother, cb);
  ca_check_same_shape(ca, cb);

  /* 4. Allocate output */
  VALUE vout = rb_ca_new_reduced(self, axes, naxes, CA_FLOAT64, 0);
  CArray *co; GetCArray(vout, co);

  /* 5. Propagate mask */
  ca_mask_overlay_safe(co, 2, ca, cb);

  /* 6. Run the kernel — kernel-iterator block-form, sweep, or call_cfunc */
  ca_iter_state st;
  int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, axes, naxes, 0);
  if ( rc != CA_ITER_OK ) rb_raise(rb_eRuntimeError, "init rc=%d", rc);
  /* ... slab walk ... */
  ca_iter_state_finish(&st);

  /* 7. Scalar fold or return */
  if ( naxes == ca->ndim ) return rb_ca_fetch_index(vout, NULL);
  return vout;
}
```

Numbered for emphasis, but the order is genuinely stable across the
hundred-ish methods in `ext/`. **If your new method's outline doesn't
match this skeleton, ask why** — the answer is usually that you should
have used the mkkernel DSL ([ch. 12](12_mkkernel_dsl.md)), which emits
exactly this code from a four-line declaration.

## See also

- [ch. 10 Author surface overview](10_author_surface_overview.md) — the
  four-surface map this chapter wires into.
- [ch. 12 The mkkernel DSL](12_mkkernel_dsl.md) — the generator that
  emits the skeleton above from a declaration.
- [ch. 15 carray.h helper reference](15_carray_h_helper_reference.md) —
  the catalogue of primitives these idioms use.

---
*When done, update the status row in [README](README.md).*
