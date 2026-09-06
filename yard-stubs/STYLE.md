# yard-stubs style guide

Conventions for writing YARD docstrings in `yard-stubs/`. Apply
mechanically; deviations need a stated reason.

## 1. Vocabulary (controlled set)

### 1.1 Receiver / argument naming

- Refer to the receiver as **`self`**, never "the object", "the array",
  "the receiver".
- Refer to arguments by their `@overload` name in backticks: `` `axis` ``,
  `` `other` ``. Do not capitalise.

### 1.2 Verb opening

Every method summary opens with exactly one of:

| Verb | Use when |
|---|---|
| **Returns** | the method returns a value derived from `self` |
| **Sets** | the method mutates `self` (alongside `@return [self]` or `@return [void]`) |
| **Yields** | the method takes a block as its primary interface |
| **Raises** | the method's purpose is to signal an error |

Forbidden: "Generates", "Creates a new", "Gets", "Computes" — replace
with "Returns".

Exception: constructors (`new`, factory class methods) open with
"Allocates" or "Builds".

### 1.3 Vocabulary

| Concept | Primary | Obsolete (mark `@deprecated`) | Co-equal |
|---|---|---|---|
| shape accessor | **`shape`** | `dim` | — |
| dimensionality | **`ndim`** | `rank` | — |
| element count | **`elements`** | `length` | `size` |
| position index | **`*_index`** | `arg*`, `*_addr` (except true flat-address APIs) | — |
| data type | **`data_type`** | `dtype` | — |
| view chain root | **`root_array`** | — | — |
| entity vs virtual | **entity / virtual** | — | — |
| mask-not-set | **not masked** | "valid", "live", "active" | — |

Obsolete aliases (`dim`, `rank`, `length`) MUST be tagged `@deprecated`
and refer the reader to the primary via `{#name}`. Co-equal aliases
(`size` ↔ `elements`) are not deprecated — document as plain
"Alias of {#name}."

### 1.4 Category labels (replace prose parentheticals)

Drop the inline `(Attribute)`, `(Inquiry)`, `(Masking, Inquiry)`,
`(Conversion, Destructive)` markers. Group methods by **`@!group`**
instead.

**Canonical group names (use these exact strings — YARD merges same-named
groups across files into one section, so a typo forks a section).** This
is the ground-truth vocabulary for CArray instance methods; pick the one
that fits and do not coin near-synonyms (`Sort`, `Search`, `Reordering`
all collapse into `Sorting and searching`):

- `Attributes` — structural accessors: `shape`, `ndim`, `bytes`, `parent`, `fields`, ...
- `Type inquiry` — `data_type`, `numeric?`, `float?`, `data_class`, `face?`, ...
- `State inquiry` — `entity?`, `virtual?`, `attached?`, `read_only?`, `empty?`, ...
- `Indexing and slicing` — `[]`, `[]=`, `fill`, `fill_copy`
- `Element access` — `elem_fetch`, `elem_store`, `elem_swap`, `elem_mask`, ...
- `Index and address conversion` — `addr2index`, `normalize_axis`, `valid_addr?`, ...
- `Iteration` — `each*`, `map*!`, `collect*!`, `*_slab`
- `Copy and conversion` — `copy`, `to_ca`, `template`, `to_a`, `dump_binary`, ...
- `Type casting` — `to_type`, `as_*`, type-name shorthands, `clip_*`, `coerce`
- `Views` — `reshape`, `transpose`, `refer`, `fake`, `grid`, `lazy`, `broadcast_to`, ...
- `Masking` — mask access and mutation, `value`, `mask_where`, ...
- `Sorting and searching` — `sort*`, `partition*`, `search*`, `bsearch*`, `linear_*`
- `Statistics` — `median`, `percentile`, `quantile`, `count`
- `Elementwise math` — arithmetic operators and their named forms (`/`, `%`, `fmod`, `divmod`), `round`, `frac`, ...
- `Scatter and generation` — `scatter_*!`, `seq`, `set`, `unset`, `where`
- `Random` — `random(!)`, `randomn(!)`, `shuffle(!)`
- `Attach lifecycle` — `attach`, `attach!`, `__attach__`, ...
- `Equality and hashing` — `==`, `eql?`, `hash`, `freeze`
- `Construction` — class-level builders (and `initialize`)

A method defined in a C file (parsed via `.yardopts`) can be pulled into
a group from a stub: give it a bare `def name; end` inside the desired
`@!group` in the stub — the group attaches while the C docstring stays
authoritative (see `yard-stubs/carray_cast.rb` for the cast family).

One stub file may use multiple groups, and a group name may be re-opened
(switch back and forth); YARD groups by name, not physical position. End
each group with `@!endgroup`.

## 2. `@overload` line

```ruby
# @overload shape
#   ...
def shape; end

# @overload template(data_type = self.data_type, bytes: 0)
#   ...
def template(*); end
```

- **No space** between method name and `(`.
- Keyword arguments use Ruby 3+ syntax (`bytes: 0`), not the `:bytes =>`
  form.
- Default values, when written, must reflect the C implementation's
  actual default. If you cannot verify, omit defaults.
- For methods with multiple call shapes, emit multiple `@overload`
  blocks. Each block's body is indented under it.

## 3. Required tags

Every overload block must have, in this order:

1. One-line summary (verb opening, ends with period).
2. Optional one-paragraph elaboration.
3. `@param` for each named argument (if any), with type and short
   description.
4. `@yield` / `@yieldparam` / `@yieldreturn` if a block is consumed.
5. **`@return [Type]` is required.** Use `[self]` for mutators, `[void]`
   when the return value is meaningless, `[Boolean]` for predicates.
6. `@raise [ErrorClass]` only when the method's purpose is to signal,
   or when a non-obvious error is raised.
7. `@example` is encouraged for non-trivial methods; one tight example
   beats three sprawling ones.

## 4. Type vocabulary

| Use | Not |
|---|---|
| `Integer` | `Fixnum`, `Numeric`, `Int` |
| `Float` | `Double` |
| `Boolean` | `TrueClass / FalseClass` (verbose), `Bool` |
| `Array<Integer>` | `Array of Integer` |
| `CArray` | `carray`, `Carray` |
| `Symbol` | `:sym` |
| `nil` (lowercase, inside brackets) | `Nil`, `NilClass` |

For union types use `[Integer, nil]`, not `[Integer or nil]`.

## 5. Prose mechanics

- Use **Markdown backticks** for code identifiers, not `<code>...</code>`.
- One blank comment line separates summary, elaboration, tags. Do not
  pad with extra blank lines.
- US English spelling (`behavior`, `analyze`). English only; no
  Japanese in stub prose.
- Active voice. "Returns the parent" not "The parent is returned".
- Sentences end with periods, including the summary line.
- Cross-references use `{ClassName#method}` or `{#method}` for
  same-class. Avoid hand-rolled hyperlinks.
- `{...}` in prose is parsed by YARD as a cross-reference link. If
  the braces are not a link (math notation like `sum_{j != axis}`,
  Ruby block sugar like `new(...){data}`), use backticks or
  rephrase — otherwise `rake yard` emits `Cannot resolve link`
  warnings. A sample line only escapes this when it is a real
  Markdown code block, i.e. indented four spaces past the
  surrounding prose (or written as `@example`); a two-space indent
  still reads as prose and its `#{i}` becomes a link.
- Link with `{...}` only to something that is in YARD's input set
  (`.yardopts`): `lib/**/*.rb` and `yard-stubs/**`. Stub coverage of
  the C surface is deliberately partial, so many real methods —
  `sort_index`, `rank_index`, `min_index`, `min_addr` — have no
  object to link to. Name those in backticks. The same applies to a
  method defined through `define_method` in a loop: YARD does not
  see it unless an `@!method` directive declares it.
- Positional and keyword arguments cannot share a name in a Ruby
  `def` even when the C impl accepts both (e.g. `random!(max = nil,
  max: nil)`). Rename the positional in the stub `def` to something
  unique (`max_pos`); the `@overload` line above it is what YARD
  renders, so user-facing docs are unaffected.

## 6. Worked example

Bad (existing C docstring):

```c
/* @overload mask= (new_mask)

(Mask, Modification)
Asigns <code>new_mask</code> to the mask array of <code>self</code>.
If <code>self</code> doesn't have a mask array, it will be created
before asignment.
*/
```

Good (stub form):

```ruby
# @!group Masking

# @overload mask=(new_mask)
#   Sets the mask array of `self` to `new_mask`. Allocates a mask
#   array first if `self` does not yet have one.
#   @param new_mask [CArray, Boolean] mask values, broadcast to
#     `self.shape`.
#   @return [CArray] `new_mask`.
def mask=(new_mask); end

# @!endgroup
```

Differences:
- `(Mask, Modification)` parenthetical removed; `@!group` carries it.
- `<code>` → backticks.
- Typo fixes (`Asigns` → `Sets`, `asignment` → assignment dropped).
- Explicit `@param` with type.
- Explicit `@return`.
- No space before `(new_mask)`.

## 7. Style drift detection

`rake stub_check` validates structural drift (method set vs C
extension). Style drift (vocabulary, tags) is reviewed at PR time
against this document. There is no automated style linter yet.
