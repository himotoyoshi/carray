# Cast and Promote (author-facing)

The discipline for CArray's internal implementation (lib/ + ext/) when you need
to "accept a value of another type as an operand" or "bring two or more arrays
to a common dtype." Rather than inventing a bespoke cast on the spot every time
you write a new feature (the source of drift), **fall back to one of the
existing canonical routes on a single source.**

## The principle

The **promotion rules themselves already live on a single source.** What drifts
is not the rules but the **call-site wiring.** So the answer is never "write a
new coerce helper" — it is **route through one of the existing canonical paths.**

| What you want | Canonical route | Concretely |
|---|---|---|
| **Accept a non-CArray operand and bring it to a given dtype** | `wrap_readonly` / `wrap_writable` | `rb_ca_wrap_readonly(v, INT2NUM(dt))` / `CArray.wrap_readonly(v, :float64)` |
| **Bring two negotiable operands to a common type** | `result_type` → `to_type` on both | `CArray.result_type(a, b)` |
| **The binary op `a op b`** | binop coercion (automatic) | `a * b` runs through `rb_ca_cast_self_or_other` internally |
| **Make N arrays share one dtype** | `promote_list` | `CArray.promote_list(list, data_type:)` |
| **Just decide the N-ary common dtype** | `result_type` | `CArray.result_type(*args)` |

## `wrap_readonly` / `wrap_writable` are the proper type-coercion entry points

`rb_ca_wrap_readonly` / `rb_ca_wrap_writable` are the **canonical intake for
promoting a non-CArray source into an operand.** They convert
Numeric / Array / String / nil / `obj.to_ca` / a **MemoryView producer** into a
CArray/CScalar of the requested dtype. Using them is correct — it is precisely
this entry point that lets any object carrying an MV become an operand of a
CArray method.

**The name states what *you* promise, not what you get back.** Neither call
marks its result read-only or writable — you are declaring how you intend to
use the operand, and the entry point converts accordingly:

- `wrap_readonly` = "I will only read this, so bring it in as widely as you
  can." Because nothing is written back, a conversion that *copies* is
  perfectly fine, so this accepts almost anything: a Numeric / String /
  arbitrary object becomes a CScalar, an Array goes through `to_ca`.
- `wrap_writable` = "I am going to write into this, so only accept what can
  actually take a write." A copy would swallow the write silently, so the
  accepted sources are exactly those that can share storage with the result
  (a writable CArray, `nil`, an object whose `to_ca` honours
  `writable: true`, a writable MemoryView producer); everything else raises
  up front.

That single difference — is there a write to land? — is what makes one intake
wide and the other narrow. It is not an arbitrary asymmetry.

A corollary worth stating, since the name invites the opposite reading:
`wrap_readonly` does **not** protect the source. For a CArray whose dtype
already matches, it hands back the very same object, and a cast view writes
back through to the parent. Read-only-ness is inherited from the source
(`ca_is_readonly` walks the parent chain), never imposed here. Keeping the
promise is the caller's job.

**Note**: the `dt` in `wrap_readonly(v, dt)` is a **fixed target.** If the peer
is negotiable (i.e. it must be decided whether to meet the peer's dtype or your
own), first settle the common type with `result_type`, then pass
`wrap_readonly(v, common_type)`. It is only legitimate to hard-code the target
when it is a **hard type the kernel requires** (f64 for transcendental
functions, `CA_SIZE` for indices, `CA_BOOLEAN` for masks, and the like).

## Accepting a MemoryView producer as an operand

An MV producer (Numo + `numo/narray/memoryview`, Arrow, PyCall numpy, etc. —
note that bare Numo is *not* an MV) can be an operand at all three coercion
entry points:

| Entry point | How the MV is handled |
|---|---|
| binop coercion (`a * mv`) | `rb_ca_cast_self_or_other` turns it into a CArray via `wrap_memory_view` before classifying |
| `wrap_readonly` / `wrap_writable` | detects the MV producer → imports it → adapts to the requested dtype |
| `result_type` / `promote_list` | `ca_arg_to_data_type` **parses the MV's format** to derive the dtype |

**Format parsing is canonical (dtype derivation is separated from the import
strategy)**: "what dtype is this MV?" is decided at the single point
`ca_mv_data_type_from_format` (format string → data_type). This is
**independent** of whether the data is later brought in by copy
(`from_memory_view`) or zero-copy (`wrap_memory_view`). When `result_type` only
needs to know an MV operand's dtype, use `ca_mv_probe_data_type` (fetch the MV
and parse its format only — do not import the data). **Building a zero-copy view
with `wrap_memory_view` just to learn the dtype** is a bad shortcut that drags
in the import strategy, so it is not taken. Both routes (import and classify)
sharing the same single format-parse point is what "single source" means.

## Anti-pattern: one-sided `X.to_type(otherArray.data_type)`

**Unilaterally dropping a negotiable operand to the peer array's dtype** is a
breeding ground for truncation bugs.

```ruby
# Bad: coerce the kernel to the source dtype -> an int source truncates the float kernel to 0
prod = sv * kernel.to_type(sv.data_type)

# Good: delegate to binop -> result_type promotes (int source * float kernel -> float)
prod = sv * kernel
```

```ruby
# Bad: coerce self to the ref dtype -> a float query 1.5 truncates to 1 against an int ref and mis-matches
q = to_type(ref.data_type)

# Good: bring both to a common type with result_type
t = CArray.result_type(self, ref)
q = (data_type     == t) ? self : to_type(t)
r = (ref.data_type == t) ? ref  : ref.to_type(t)
```

**Test**: be suspicious when the target you drop to is "the peer array's dtype."
It is legitimate when the target is "a fixed type the kernel structurally
requires" (write that with `wrap_readonly`).

## Decision flow

1. Does the operand accept a non-CArray (Numeric/Array/String/MV)?
   → **`wrap_readonly` / `wrap_writable`** (decide the target dtype via 2/3 below)
2. Is the target dtype "a fixed type the kernel requires"? (f64 / CA_SIZE / CA_BOOLEAN etc.)
   → specify the fixed type directly
3. Is the target dtype "a negotiation to meet the peer array"?
   → settle the common type with **`result_type`**. Do not write the one-sided `to_type(peer.data_type)`
4. Is there an `a op b` binary op right after?
   → do nothing and **delegate to binop** (`a * b` promotes automatically). Do not coerce beforehand
5. Homogenizing N arrays?
   → **`promote_list`**

## Do not add a new helper

If it can be expressed by the five routes above, **do not add a new coerce
helper.** Call the CArray primitive directly. Writing the same
`result_type` → `to_type` in two or three places is not duplication — it is
**writing the canonical route out in the open**, and spelling out the known
vocabulary reads better than folding it into a single private helper. Consider a
helper only when there is genuine semantic value (a domain concept or a policy).

## Weight promotion in weighted reductions (landed 2026-07-08)

The array_arg of the core weighted reductions (wsum / wmean) used to wrap the
weights at a fixed `src->data_type` (`:match_source`), so an int source with
float weights truncated the weights (wmean → NaN). Because this core kernel is
the delegation target for the wsum/wmean of the window / block / slab iterators
too, removing the `.to_type` on the Ruby side still left the core re-truncating.

The fix (array_arg `data_type: :promote`): materialize the weights at the **f64
computation type**, separating the C type of the weight cell the reduce body
reads (the second type argument `T_W` of `CA_SLAB_REDUCE_ARRAY_T_EX`) from the
source cell type `T`. The reduce body is `(double) v * (double) w`, so f64
storage is exactly equivalent to "read the native weight and cast to double"
across all inputs — no truncation and no precision difference. Int weights keep
their integer values; float weights are not truncated. See the array_arg emit
plus the wsum/wmean definitions in `ext/mkkernel.rb`.
