# CAObject subclasses

`CAObject` is the way to make something that is **not** a CArray behave like
one. The authoritative store stays where it is — a nested Ruby Array, another
gem's buffer, a file, or a rule that computes values on demand — and the
subclass supplies callbacks that CArray's engine calls to read and write it.

These are written entirely in Ruby. That is the point: `CAObject` is the
**prototype path**. Get the semantics right here, and move to C only when the
per-callback cost starts to matter (see
[CAObject.md](../../docs/topics/CAObject.md) §4, "the prototyping ladder").

Not to be confused with its neighbour on the shelf,
[`../face/`](../face/): a **Face** puts a meaning on storage CArray already
holds, while a `CAObject` stands in for storage CArray does not hold at all.
(A Face can be *built* on `CAObject` with `face: true` — then the storage
callbacks below are not needed at all, and `face/` is where to look.)

## Running

```sh
ruby -Iext -Ilib examples/caobject/nested.rb
```

Each file runs on its own and prints what it does. To use one, copy it, or
pull it in with `require_relative`.

## Read `nested.rb` first

`CANestedArray` wraps a rectangular nested Ruby Array (`[[1.0, 2.0], [3.0,
4.0]]`) and is the only one here that defines the **full template set**, so it
is the reference card for the protocol:

| callback | called for |
|---|---|
| `fetch_index` / `store_index` | one cell by multi-index — `a[i, j]` |
| `fetch_addr` / `store_addr` | one cell by flat address (row-major) |
| `copy_data` / `sync_data` | the whole array at once — `a.copy`, write-back |
| `fill_data` | a scalar broadcast over the array — `a[] = 0` |
| `create_mask` | the mask lifecycle hook |

Defining the whole set is what makes every access path work, including
partial-region materialisation through a chain of views (`a[range,
range].copy`, `a.transpose.copy`) without ever building the whole structure.

You do **not** have to define them all. One fetcher is the minimum; the rest
are opt-ins that turn a per-cell path into a bulk one. What each file here
actually defines:

| file | callbacks defined | writable |
|---|---|---|
| `nested.rb` | the full set above | yes |
| `link.rb` | `fetch_addr`, `copy_data`, `create_mask` | no |
| `pack.rb` | `fetch_index`, `copy_data` | no |
| `recurrence.rb` | `fetch_addr`, `copy_data` | no |

## The patterns

- **`nested.rb`** — a nested Ruby Array as the authoritative store. The
  complete protocol, and the one to copy when your store is an ordinary Ruby
  object you can index.
- **`link.rb`** — a reactive view. Reads recompute through a block evaluator,
  so the array stays in step with its inputs. `fetch_addr` evaluates the block
  for one cell; `copy_data` evaluates it for the whole shape with vectorised
  CArray operations, which is far faster than going cell by cell — the general
  lesson about `copy_data`.
- **`pack.rb`** — multi-parent assembly: N arrays presented behind a leading
  axis. The sources live in a plain Ruby ivar rather than the single `:parent`
  slot, because there is no one antecedent.
- **`recurrence.rb`** — values defined by a rule rather than stored at all.
  Cells are computed on demand and remembered, which is the shape to copy for
  a lazily evaluated sequence.

## See also

- [CAObject.md](../../docs/topics/CAObject.md) — the full callback contract,
  the mask hooks, Face mode, and when *not* to reach for `CAObject`.
- [`../c-extensions/`](../c-extensions/) — where a prototype goes when it
  outgrows Ruby.
