# Checking Face lift soundness — the single-Face invariant

Face lift is the mechanism that keeps a [Face](../topics/CAFace.md) at the top of its view
chain. It is deployed by hand at ~two dozen view-creating methods and is *not*
centralizable, so it must be **verified**, not assumed. This document defines
what "sound" means for lift (the **single-Face invariant**), gives a quick way
to check any Face view, explains the mechanism precisely enough to reason about
failures, and states the two failure modes and the tests that catch each.

Read [`CAFace.md`](../topics/CAFace.md) §1.3 / §6 / §8 first for the Face model.

---

## 0. The invariant, and how to check it

**Soundness = the single-Face invariant.** For any view derived from a Face `f`,
the result chain must contain **exactly one Face — the top wrapper** — and its
parent must not be a Face:

```
result.face?              # => true    (identity kept — not a bare view)
face_depth(result) == 1   #            (no redundant middle Face)
result.parent.face?       # => false   (the node under the Face is a plain view)
```

A one-shot probe for any Face view:

```ruby
def face_depth(v)          # count Face nodes down the parent chain (flag-based)
  n = 0; x = v
  while x.respond_to?(:parent) && x.parent
    n += 1 if x.face?
    x = x.parent
  end
  n += 1 if x.respond_to?(:face?) && x.face?
  n
end

c = CArray.const_string(%w[aa bb cc dd])
face_depth(c[1..3])          # => 1   (sound)
face_depth(c[1..3][0..1])    # => 1   (sound — nesting must NOT grow Faces)
```

`face?` is flag-based (`CA_FLAG_IS_FACE`), so it counts CAObject-based Faces too
— use it, not `is_a?(CAFace)`.

The automated version of this check is the registry test
`spec/spec_ai/test_face_double_lift.rb` (§7); the rest of this document explains
what the check is verifying and how to keep it passing.

## 1. What lift guarantees

A Face is always the **outermost** node in its view chain
([`CAFace.md`](../topics/CAFace.md) §1.3, invariants #2/#3). Referencing a Face returns
the same Face class:

```ruby
dt = CArray.time(int64_entity, unit: "1 day")   # CATime
dt[1..3].class            # => CATime
dt.reshape(2, 3).class    # => CATime
```

and the chain underneath is a single Face over a plain view over storage:

```
CATime[ CABlock[ int64_entity ] ]        # ✔ one Face, on top

CABlock[ CATime[ int64_entity ] ]        # ✘ Face buried  (never)
CATime[ CABlock[ CATime[ int64_entity ] ] ]  # ✘ redundant middle Face
```

The third shape is the bug this mechanism exists to prevent.

## 2. Why a swap is needed

A fetch-path builder (`rb_ca_fetch_method` in `ext/carray_access.c`) builds its
view on the operand **as given** — for a Face operand `self`, that means the new
`CABlock` / `CASelect` / `CAGrid` has `view->parent == self` (the Face). This is
correct and normal: a view's parent is what you sliced. But left alone it yields
`CABlock[CATime[entity]]` — the Face is now *inside* the chain, not on top.

Lift fixes this by (a) re-wrapping the view under a fresh Face of the same class
(the Face returns to the top) and (b) **swapping the view down one level** so it
no longer sits on the old Face but on the old Face's parent. The two steps
together turn `CABlock[CATime[entity]]` into `CATime[CABlock[entity]]` — one
Face, on top, over the plain view, over storage.

`CAFace.md` §8.3 states the rule: *"the reference node and the Face are swapped
once. There is no Face stack walk."*

## 3. `ca_face_lift` — the single funnel

Every view-creating method routes through one function, `ca_face_lift`
(`ext/ca_obj_face.c`), deployed at ~two dozen return sites via the macro
`CA_FACE_LIFT_IF_FACE(obj, self, ca)`. It does four things; the swap is the
middle one:

```c
VALUE
ca_face_lift (VALUE view, VALUE face_parent)
{
  CArray *view_ca;
  TypedData_Get_Struct(view, CArray, &carray_data_type, view_ca);

  {
    CArray *fp, *p;
    TypedData_Get_Struct(face_parent, CArray, &carray_data_type, fp);

    /* (a) data_type: full strip to storage — surface concern (§8 #7). */
    p = fp;
    while (p && ca_is_face(p)) p = ((CAView *) p)->parent;
    if (p && p->data_type != view_ca->data_type)
      view_ca->data_type = p->data_type;

    /* (b) parent pointer: ONE-level local swap — structural concern (§8.3). */
    if ( ((CAView *) view_ca)->parent == fp
         && ! ca_test_flag(view_ca, CA_FLAG_MULTI_PARENTS) ) {
      ((CAView *) view_ca)->parent = ((CAView *) fp)->parent;  /* C pointer */
      rb_ca_set_parent(view, rb_ca_parent(face_parent));       /* @parent ivar */
    }
  }

  /* (c) wrap the view under a fresh Face of face_parent's class (dsize-driven
         struct copy carries the tail state), and pin it as GC root. */
  VALUE lifted = rb_ca_face_template(face_parent, view_ca, view_ca->dim);
  rb_ca_set_parent(lifted, view);

  /* (d) carry Ruby-ivar state for CAObject-based Faces. */
  if ( rb_respond_to(face_parent, id_copy_state) )
    rb_funcall(lifted, id_copy_state, 1, face_parent);

  return lifted;
}
```

Because it is a single funnel, the swap fixes **every** single-parent view path
(slice, gather, boolean-select, sort, reshape, transpose, …) and nested chains,
at one site.

### 3.1 The GC ivar must move in lockstep

Ruby `#parent` reads the `@parent` **ivar** (`rb_ca_parent`), not the C
`->parent` pointer. Moving only the C pointer would leave `view.parent` (Ruby)
still reporting the old Face. So the swap updates **both**: the C pointer *and*
`rb_ca_set_parent(view, rb_ca_parent(face_parent))` (the one-level-up VALUE).
Keeping the two in lockstep is mandatory — it is also what lets the dropped
middle Face be garbage-collected.

## 4. Two axes, deliberately separate

The `data_type` rewrite and the `parent` swap look similar but answer different
questions, and use different strides:

| axis | what | how far | why |
|---|---|---|---|
| **`data_type`** | the view's *surface* type | **full strip** to storage | invariant #7: `Face.parent.data_type` must be the storage type so Ruby escape-hatch overrides (`parent.subtract(other.parent)`) dispatch on storage, not on the `CA_FIXLEN` gate surface. |
| **`parent` pointer** | the view's *structural* parent | **one level** (`fp->parent`) | §8.3: put the view exactly where the Face sat; preserve any inner Face the user stacked. |

Do not collapse them into one walk. The data_type is a property of *this* view
(it must always show storage), so a full strip is right. The parent is a
*position* in the chain (one slot down), so one level is right.

## 5. One level, never a walk

`fp->parent` is one step down. If the user has **stacked a distinct Face**
underneath (`CAFace.md` §8.3 — "explicit stacking is the user's
responsibility"), one level lands on that inner Face and **preserves** it:

```ruby
td  = int64_entity.timedelta(unit: "1 day")   # CATimedelta  (Face over entity)
tag = MyTag.new(td)                           # MyTag (CAObject Face) over CATimedelta

tag[1..2]
#  one-level swap →  MyTag[ CABlock[ CATimedelta[ entity ] ] ]   ✔ inner Face kept
#  strip walk     →  MyTag[ CABlock[ entity ] ]                  ✘ CATimedelta destroyed
```

A strip-to-storage walk would silently delete the inner `CATimedelta` — a
correctness bug, and a violation of §8.3's "no stack walk". This is the reason
the swap is one level. The regression test
`spec/spec_ai/test_face_double_lift.rb` pins the preservation.

## 6. Adding a new view-creating method

Two steps, both mechanical:

1. **Deploy the lift.** Place `CA_FACE_LIFT_IF_FACE(obj, self, ca)` just before
   the `return` of the new method (the same place `[]`, `reshape`, `sort`, …
   already have it). Without it, a Face operand yields a plain view — the result
   is not a Face at all (identity silently lost).
2. **Register it for coverage.** Add a row to the `OPS` table in
   `spec/spec_ai/test_face_double_lift.rb`. That table is the canonical
   "must-preserve-Face" registry; the test asserts, for every op × every Face,
   that the result is a Face and the chain is single-Face.

There is no way to centralize step 1 into a single funnel (view creation is
per-method and not uniform), so the registry in step 2 is the mechanism that
keeps the per-site discipline honest.

## 7. Two failure modes, two nets

| failure | symptom | caught by |
|---|---|---|
| **wrong swap** | lift ran but `view->parent` still the Face → `Face → view → Face → storage` | `result.parent.face? == false` assertion (registry test); a `CARRAY_DEV` post-lift tripwire is a planned addition |
| **forgot lift** | macro omitted → lift never ran → result is a plain view, not a Face | `result.face? == true` assertion (registry test) — the tripwire *cannot* see this (it only fires when lift runs) |

The two are distinct: a post-lift assertion covers the first but structurally
cannot see the second, which is why the coverage registry asserts `result.face?`
independently.

## 8. Multi-parent views (CAStack)

`CAStack` has `CA_FLAG_MULTI_PARENTS` and K parent slots. The in-lift one-level
swap can only move the single `->parent` slot, so `CAStack` is **excluded** from
the swap (the `! ca_test_flag(view_ca, CA_FLAG_MULTI_PARENTS)` guard). Instead it
is fixed at construction: `ca_stack_setup_with_axis` **pre-strips every parent
one level** (Face → its storage parent) before setup, and the builders strip the
`@parent` GC ivar to match. So a stacked Face lifts to `CATime[CAStack[entity,
…]]` — one Face on top, non-Face parents. The `#parents` accessor still returns
the originals (a plain-array stack keeps object identity). Values, shape, and the
Face's state are unchanged.

The tripwire (§7) therefore covers `CAStack` too (it checks slot 0, which the
pre-strip makes storage); only the in-lift *swap* excludes multi-parent, because
`CAStack` is handled at build time, not at lift.

## 9. Invariants recap

From [`CAFace.md`](../topics/CAFace.md) §8, the ones this mechanism upholds:

- **#2 / #3** — a view-creating method on a Face returns a Face, on top, via a
  single one-level swap (no stack walk).
- **#7** — `Face.parent.data_type == storage` across the chain (the full-strip
  `data_type` rewrite; independent of the parent swap).

The pointer-equality guard (`view->parent == fp`) means the swap fires only for
a view built directly on the Face; a result built on already-stripped storage
(e.g. the ordering kernels in `carray_order.c`, which strip before building) is
a no-op — already single-Face.

## See also

- [`CAFace.md`](../topics/CAFace.md) — the Face substrate (model, C-level and CAObject
  paths, `storage_to_scalar` / `scalar_to_storage`, invariants).
- [`FaceOrderingSearch.md`](../authoring/FaceOrderingSearch.md) — how a Face joins the
  ordering / search kernels (which strip-then-lift).
