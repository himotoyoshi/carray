# yard-stubs/

**THIS DIRECTORY IS DOCUMENTATION ONLY. DO NOT `require` THESE FILES.**

The `.rb` files under `yard-stubs/` are **YARD docstring carriers** for
methods defined in the C extension (`ext/*.c`). They contain no
implementation — every method body is `; end`. The real implementations
live in C and are bound by `Init_*` via `rb_define_method` /
`rb_define_singleton_method`.

## Why this exists

C extension docstrings (`/* @overload ... */` in `ext/*.c`) work in
YARD but have friction in practice: editing a doc requires touching C
source, and impl + doc drift easily within the same file. Moving the
docstrings into Ruby stubs gives:

- doc-only PRs without C edits
- native Ruby syntax for `@overload` / `@example`
- file-level 1:1 mapping (`ext/foo.c` ↔ `yard-stubs/foo.rb`) checkable
  by tooling

## Discipline

- **Never `require` a file under `yard-stubs/`**. Doing so would
  redefine C methods as empty stubs and break the library.
- The gemspec includes only `lib/**/*.rb`, so these files are
  automatically excluded from the published gem.
- Method bodies are always `; end`. No default values for arguments
  (signature truth lives in the C `Init_*` table and in `@overload`).
- One stub file per `ext/*.c`. New stub additions land alongside an
  entry removal from `.yardopts` (the C file is no longer the YARD
  input for that area).

## Drift detection

`rake stub_check` (see `utils/check_stub_drift.rb`) compares the set
of methods listed in stubs against `CArray.instance_methods(false)`
on a freshly loaded library, and fails on mismatch.
