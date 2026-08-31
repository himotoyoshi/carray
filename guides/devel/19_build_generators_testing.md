# 19 Build, generators, and testing

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

The operational knowledge for working on the tree day to day: how it builds, what
is generated and by which generator, the development build discipline, and the
test suites. This chapter is the one place that is legitimately about *workflow*
rather than internals — but it is developer workflow, not user usage.

## The build flow

In-place build:

```sh
cd ext && ruby extconf.rb && make
```

or from the repo root:

```sh
rake build_ext     # cd ext && ruby extconf.rb && make
rake clean_ext     # cd ext && make distclean
rake test          # every suite below, plus stub_check; also the default task
rake spec          # :build_ext + spec/*_spec.rb
rake spec_ai       # :build_ext + spec_ai/
rake spec_unit     # :build_ext + spec/UnitTest/
```

`extconf.rb` requires `ruby/memory_view.h` (Ruby 3.0+), which the
[MemoryView](18_memory_view_protocol.md) support depends on.

### Why rake-compiler is not used

`rake compile` (`Rake::ExtensionTask`) was tried and abandoned: the generator
preprocessing (`carray_cast_func.rb`, `carray_stat_proc.rb`, `carray_math.rb` /
`mkmath.rb`) reads `carray_config.h` from the cwd and writes generated `.c` into
the cwd, while rake-compiler runs extconf in `tmp/<plat>/…`, so generated files
never reach `ext/` and the build comes up short (missing `conj`, etc.). The
in-place `rake build_ext` matches the generators' cwd assumptions exactly.

### The header-touch / merge rebuild rule

**After editing any `ext/*.h` (or merging a branch), do a full distclean rebuild:**

```sh
rake clean_ext && rake build_ext
```

Incremental `make` has been observed repeatedly to keep a stale binary after a
header change — the exact mechanism is unconfirmed, but `make distclean` (which
deletes the Makefile and all `.o`s) is the only reliable fix; `rm -f *.o` is not
enough. Always confirm a fix actually took with a quick probe (one bench or one
behaviour check), not just the build's exit code (memory:
stale-build-after-git-ops). And when running ad-hoc `ruby -Iext -Ilib -e …` in a
worktree, assert the loaded bundle path — a momentarily-missing local bundle makes
`require "carray"` silently fall back to the installed gem's stale bundle, which
manifests as phantom bugs (memory: worktree-gem-shadow).

## The generators

Several `.c` files are **generated — never hand-edit them**; edit the generator:

| Generator | Emits | Covered in |
|-----------|-------|------------|
| `ext/mkkernel.rb` | `carray_kernels.c` — typed kernel coverage | [ch. 12](12_mkkernel_dsl.md) |
| `ext/mk_call_cfunc.rb` | `carray_call_cfunc.c` — vectorised scalar-func dispatch | [ch. 14](14_call_cfunc.md) |
| `ext/mkmath.rb` + `carray_math.rb` | math-function kernels | — |
| `ext/carray_cast_func.rb` | cast functions | — |
| `ext/carray_stat_proc.rb` | (retired in E.7; stub remains for diff minimisation) | — |

Generator comments are emitted into the output, so even a comment fix goes in the
generator. Adding a new `ext/*.c` requires re-running `extconf.rb` (existing build
trees only; a fresh checkout is fine). A 3.x simplification of the math generator
is planned.

## The development build discipline: `CARRAY_DEV=1`

**Every dev machine must export `CARRAY_DEV=1` permanently.** The smoke surface is
excluded from the release binary, so without
the env var, ~41 spec_ai files (~639 tests) silently `omit` and regression-detection
drops:

```sh
echo 'export CARRAY_DEV=1' >> ~/.zshrc      # or .bashrc, or direnv
echo $CARRAY_DEV                            # must print 1
```

Run a release build (smoke excluded) deliberately with `CARRAY_DEV= rake build_ext`
or `unset CARRAY_DEV`. `rake install` (gem build) always runs a release build, so
smoke never reaches gem users. Daily dev runs smoke-in.

### Baseline test counts

These are the drift-detection reference (a future session should match them):

| Build | tests | assertions | failures | omissions |
|-------|------:|-----------:|---------:|----------:|
| dev (`CARRAY_DEV=1`) | 4213 | 86683 | 0 | 65 |
| release (gem build) | 3574 | 75303 | 0 | 64 |
| rspec (both) | 267 examples | — | 0 | 7 pending |

A dev build that reports the *release* counts means `CARRAY_DEV` is not set.
(These numbers are themselves a snapshot — verify against the current tree and
update them in the `done` pass.)

## The test suites

There are three, in two frameworks, and `rake test` runs all of them.

- **`spec_ai/`** — the `test/unit` suite, and the one 3.0 grew. Rich on
  MemoryView and CAStride (`test_memory_view*.rb`, `test_ca_obj_stride*.rb`,
  `test_castride_family.rb`, `ext_memory_view_test/` for the C-side MV borrower
  peer). `rake spec_ai`.
- **`spec/*_spec.rb`** — the RSpec suite carried over from 2.x; `rake spec`, or
  `ruby spec/spec_all.rb`. Not exhaustive, but it is the only thing pinning
  parts of the 2.x surface: `rank` / `dim0`–`dim3` / `size0`, the type
  predicates, the `elem_*` family, `inherit_mask`, `bind` / `bind_with`.
  spec_ai does not call any of those.
- **`spec/UnitTest/`** — one `test/unit` file, also from 2.x, applying the same
  mixin to nine view classes. `rake spec_unit`.

When you delete or change behaviour, run `rake test` rather than one suite — a
unit pass alone has missed library-load failures and old-contract regressions
before (memory: run-tests-after-deletion).

## The bench / smoke discipline

For any performance work ([ch. 10](10_author_surface_overview.md), [ch. 12](12_mkkernel_dsl.md)):

- run under `CARRAY_DEV=1`;
- generate bench data with `{ |i| rand(...) }`, **never** `{ rand(...) }` (the
  arity-0 broadcast trap that turns a varied array into one repeated value);
- use sufficient iterations (50+/sample, median-of-7, warmup, GC.start interleave);
- **show the measured numbers and let the maintainer judge** — don't self-grade a
  result (memory: show-bench-dont-self-judge).

## Where to go next

- The generators in depth → [ch. 12](12_mkkernel_dsl.md), [ch. 14](14_call_cfunc.md).
- The kernel surface the smoke tests exercise → [ch. 11](11_kernel_iterator.md).

---
*When done, update the status row in [README](README.md).*
