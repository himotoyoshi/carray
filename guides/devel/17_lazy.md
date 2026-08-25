# 17 Lazy evaluation

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

Lazy evaluation builds an **unevaluated expression tree** out of view objects and
materialises it on demand, so a chain like `a*b + c` can be computed in one fused
pass instead of allocating a temporary per operation. This chapter explains the
C-level machinery — the lazy view obj_types, how the tree is forced, and the
scratch arena. The Ruby-facing surface and performance break-even guidance
live in the user's guide (ch. 09).

## The tree is made of view objects

A lazy expression is not a special AST type — it is an ordinary CArray view chain
whose nodes are four lazy obj_types:

| Node | obj_type | File | Represents |
|------|----------|------|------------|
| CABinOp | `CA_OBJ_BINOP` | `ca_obj_binop.c` | a binary op (`a + b`) |
| CAMonOp | `CA_OBJ_MONOP` | `ca_obj_monop.c` | a unary op (`a.sin`) |
| CATriOp | `CA_OBJ_TRIOP` | `ca_obj_triop.c` | a ternary op (`a.fma(b, c)`, `a.clip(lo, hi)`) |
| CABinCmp | `CA_OBJ_BINCMP` | `ca_obj_bincmp.c` | a binary comparison (`a > b`) |
| CAMonCmp | `CA_OBJ_MONCMP` | `ca_obj_moncmp.c` | a unary comparison |

Each node holds its operand(s) (its parent(s)) and an **op-id** — a value of the
C enum `CA_MONOP_*` (`ca_monop_dispatch.h`) for the unary nodes or `CA_BINOP_*`
(`ca_binop_dispatch.h`) for the binary ones, stored in the node's `op_id` tail
field and mirrored to Ruby as the `OP_*` constants (`OP_NEG`, `OP_ADD`, …). It
names the operation deferred. Building `a.lazy * b + c` constructs a `CABinOp(OP_ADD)` whose left
parent is a `CABinOp(OP_MUL)` over `a` and `b`, and whose right parent is `c`.
Nothing has computed yet; the tree is just nodes pointing at operands.

Because these are views, they compose with the rest of the view algebra — a lazy
node can sit over a slice, a transpose, a scalar broadcast — and they obey the same
attach lifecycle. A scalar operand is represented as a CScalar broadcast with
element-stride 0 (or wrapped in CAUnboundRepeat), so `a.lazy + 1` needs no
temporary for the `1`.

## Forcing: how a tree becomes an entity

Three method names converge on "evaluate the tree into a real entity", with
different defaults — the distinction matters at the C level:

- **`copy`** always evaluates and returns a fresh entity (it owns data, always —
  [ch. 2](02_core_data_structures.md)).
- **`to_ca`** on an *entity or data view* is `self` (no work), but the five lazy
  types **override `to_ca` to mean `copy`** in `lib/carray/lazy.rb` — because a
  lazy view has no data yet, so "present me as a CArray" can only mean "evaluate
  me". This mirrors Ruby's `Enumerable#to_a` forcing a lazy enumerator.
- attaching the tree (the normal view attach, [ch. 4](04_attach_lifecycle.md))
  walks the operand chain and evaluates node by node into the buffer.

The evaluation walks the tree recursively: each node gathers its operands (which
may themselves be lazy, recursing), applies its opcode element-wise, and writes the
result. This is the fused pass — `a*b + c` reads `a`, `b`, `c` once and writes one
output, with no intermediate `a*b` array.

## The scratch arena

Recursive evaluation needs scratch buffers for intermediate operands, and a deep
chain acquires several at once. Allocating and freeing them per `to_ca` would
dominate the cost of small arrays. The **lazy arena** (`ext/carray_lazy.c`,
`ca_lazy_arena_enter` / `_leave`) is a slot-pool that keeps scratch buffers alive
across `to_ca` calls:

- it is a **slot pool**, not a single growable cursor: each `acquire` returns an
  independent `xmalloc`'d buffer that never moves, so simultaneous nested acquires
  (a deep CABinOp chain) hold stable pointers even as outer acquires grow the pool
  — a single-cursor stack would `realloc` and invalidate an inner pointer
  mid-kernel;
- the **first** `to_ca` pays the cold allocation; **subsequent** calls reuse warm
  slots;
- best-fit allocation keeps a small request (a mask scratch) from occupying a big
  slot;
- release happens in LIFO order in practice (acquire data, recurse into the right
  operand, unwind), which maximises reuse, though the pool does not require LIFO
  semantically.

Thread-safety is a non-goal here: the arena is global static state, consistent with
the project stance ([ch. 4](04_attach_lifecycle.md)).

## The three surfaces

`ext/carray_lazy.c` and `lib/carray/lazy.rb` expose three entry points that differ
in *when* materialisation happens, not in the tree they build:

- **`.lazy`** — a persistent lazy view; operations on it stay lazy until forced.
- **`CArray.fuse`** — a transient fusion scope that materialises at block exit
  (with shadow read-only semantics on the operands inside).
- **`CArray.lazy`** — a transient lazy scope with no auto-materialise.

The three surfaces and their block/shadow semantics, along with the measured
fuse-vs-eager break-even and the "small N, deep chain" cliff, are covered in
the user's guide.

## Cross-ndim is rejected in the lazy substrate too

The lazy substrate enforces the same broadcast rule as eager evaluation: two
operands of different `ndim` are an error, not a silent trailing-align. Size-1 axes
stretch; axes are never added implicitly. This is checked when the node is built,
so `a.lazy + b` with mismatched rank raises at construction, matching `a + b`
([ch. 6](06_view_algebra_and_castride.md),
`test_lazy_binop_p24.rb#test_cross_ndim_raise`). The integer-exponent `pow` has a
dedicated lazy fast path (`OP_IPOWER`, `ext/ca_op_ipower.c`).

## Adding a new lazy op

A lazy op and its eager counterpart share one thing: the per-`data_type` **kernel
table**. mkkernel ([ch. 12](12_mkkernel_dsl.md)) emits the eager elementwise
kernels as arrays `ca_monop_<name>[CA_NTYPE]` / `ca_binop_<name>[CA_NTYPE]`; the
eager path and the lazy `CAMonOp` / `CABinOp` **both** index those same tables.
The only difference is *when*: the eager path applies the kernel immediately, while
the lazy node stores its `op_id` and calls the kernel at force time
(`ca_monop_kernel_lookup(op_id, in_data_type)` inside the CAMonOp attach/xfer
path, `ca_obj_monop.c`). So "adding a lazy op" is really "give the existing
op-id a lazy node", and once the kernel table exists the work is table-wiring, not
new gather code.

Taking a unary op as the example (the binary side is symmetric across
`ca_binop_dispatch.{h,c}` and `ca_obj_binop.c`):

1. **Add the enum member.** Append a `CA_MONOP_<NAME>` to the enum in
   `ca_monop_dispatch.h`. Assign it a fresh trailing value — the numbers are a
   stable ABI (Ruby constants and callers reference them), so never renumber an
   existing op. Cast ops live in their own range at `CA_MONOP_CAST_BASE` (100) and
   up; keep normal ops below it.

2. **Provide the kernel table.** Add `extern ca_monop_func_t ca_monop_<name>[CA_NTYPE];`
   to `ca_monop_dispatch.h` and register the op in the mkkernel generator so
   `carray_kernels.c` emits `ca_monop_<name>` ([ch. 12](12_mkkernel_dsl.md)). This
   is the same table the eager path uses — do not hand-write a parallel kernel.

3. **Wire the dispatch** in `ca_monop_dispatch.c`:
   - add `case CA_MONOP_<NAME>: return ca_monop_<name>[in_data_type];` to
     `ca_monop_kernel_lookup`;
   - classify its **output data_type**: a *preserve* op needs nothing (the default
     in `ca_lazy_promote_monop` returns the input data_type); a *widening* op
     (integer/boolean parent → `CA_FLOAT64`) must be recognised by
     `ca_monop_is_widening` — either land it inside the contiguous
     `CA_MONOP_WIDENING_BEGIN … END` range or add it to the explicit list in that
     predicate;
   - `ca_monop_kernel_input_data_type` then follows automatically: when the kernel
     wants a wider input than the parent supplies, the CAMonOp builder inserts a
     `CAMonOp(:cast_<data_type>)` node before this op (the "cast-before" route).

4. **Expose the Ruby constant.** In `Init_ca_obj_monop` (`ca_obj_monop.c`) add
   `rb_define_const(rb_cCAMonOp, "OP_<NAME>", INT2NUM(CA_MONOP_<NAME>));`. This is
   the `OP_*` name `lib/carray/lazy.rb` uses.

5. **Wire the Ruby surface.** In `lib/carray/lazy.rb`, add the method that builds a
   `CAMonOp` node with the new `OP_<NAME>` op-id (the lazy analogue of the eager
   method). No C changes beyond the above are needed — the node's attach path
   already routes any op-id through `ca_monop_kernel_lookup`.

Binary ops follow the same five steps against `ca_binop_dispatch.{h,c}` and
`ca_obj_binop.c` (`CA_BINOP_*` enum, `ca_binop_<name>[common_dt]` tables, the
`OP_*` constants on `CABinOp`). Triadic ops (`fma`, `fms`, `clip`) follow the
same pattern one arity up — `ca_triop_dispatch.{h,c}`, `ca_obj_triop.c`,
`CA_TRIOP_*` enum, `ca_triop_<name>[common_dt]` tables, `OP_*` constants on
`CATriOp` — dispatched from `LAZY_TRIOP_OP_IDS` in `lib/carray/lazy.rb`. An op
whose lazy evaluation can't be expressed as a straight kernel index — e.g. the
integer-exponent `pow` — gets a dedicated node path instead (`OP_IPOWER` /
`CA_BINOP_IPOWER`, `ext/ca_op_ipower.c`); the data-type-changing `arg` gets a
preserve-dtype primitive (`OP_ARG_I`) chain-composed with `cast_<float>` in
`lib/carray/lazy.rb`, same trick as `abs` / `imag`.

Two extra pitfalls to watch when adding a Ruby-facing op:

- **C-alias-snapshot trap.** `rb_define_alias` snapshots the target method
  entry at Init time. If the aliased canonical name is later redefined by
  `lib/carray/lazy.rb` for lazy dispatch, the alias keeps pointing at the
  original eager entry and silently falls to eager. Fix: `alias_method
  :<alias>, :<canonical>` in `lib/carray/lazy.rb` after the redefinition.
  Precedents in the file (`pow`, `fmax`/`fmin`, `add`/`sub`/`mul`/…) show the
  pattern.
- **Silent degradation review.** A missing lazy entry does not raise — the
  chain quietly materialises and runs eager. Ordinary users cannot tell, so
  the discipline is proactive: after adding any op or view class, sweep the
  coverage against the `LAZY_*_OP_IDS` tables.

## Where to go next

- The view algebra these nodes compose with → [ch. 6](06_view_algebra_and_castride.md).
- The attach lifecycle the force path runs through → [ch. 4](04_attach_lifecycle.md).
- The `to_ca` / `copy` semantics the force rules implement → [ch. 2](02_core_data_structures.md).

---
*When done, update the status row in [README](README.md).*
