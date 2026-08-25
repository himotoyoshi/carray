# utils/

Developer-only scripts run against a **built** CArray. These are
repository tooling, not part of the library: `utils/` is not listed in
`carray.gemspec`, so nothing here ships in the installed gem.

Most are invoked through `rake`; run them directly only for ad-hoc
inspection. All of them expect the extension to be built first
(`rake build_ext`).

## Invariant guards (wired into `rake`)

These fail the build when a tracked invariant drifts. Keep them green.

### `check_stub_drift.rb` — `rake stub_check`

Cross-checks `yard-stubs/**/*.rb` (the source of the YARD documentation)
against the methods actually defined on the live CArray-family classes.

- **ERROR** (exit 1): a stub documents a method that does not exist on
  the live class — a phantom. The docs would lie to the user.
- **INFO**: a live method that no stub covers yet. Reported as a
  coverage table, does not fail the build.

When you add a new tracked class (e.g. a new Face) on the C side, add it
to `TRACKED_CLASSES` at the top of the script.

```sh
ruby -I lib -I ext utils/check_stub_drift.rb
```

### `check_kernel_surface_freeze.rb`

Freeze guard for the **frozen** kernel_iterator author surface (the
macros, raw-API entry points, enum tokens, and slab `st` fields that
ext-gem kernels compile against). Fails if any frozen identifier
disappears from `ext/ca_kernel_iterator.h` (renamed or removed), turning
a downstream-breaking rename red instead of silent. It checks presence
only, not arity or semantics — those live in the spec_ai kernel tests.

See `docs/authoring/HOW_TO_WRITE_KERNEL.md` §0 and the banner in
`ext/ca_kernel_iterator.h` for the frozen/internal split.

```sh
ruby utils/check_kernel_surface_freeze.rb
```

## Diagnostics (run by hand)

### `monkey_patch_methods.rb`

Lists everything `require "carray"` adds to `Kernel`, `Object`,
`Numeric`, `Float`, `Integer`, `Rational`, and the global constant table
(computed as the before/after diff of loading the library). The working
companion to `devel/MONKEY_PATCH_AUDIT.md` for the 3.0 monkey-patch
slim-up.

```sh
ruby -I lib -I ext utils/monkey_patch_methods.rb
```
