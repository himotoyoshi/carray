# Contributing to Ruby/CArray

Thanks for looking. This file says which form a contribution is best sent
in, so that neither of us spends effort on something that cannot land.

## What to send

| What you have | How to send it |
|---|---|
| **A bug report or a feature request** | Open an issue. |
| **A small, self-contained bug fix** | Open a pull request. |
| **Anything larger** | Open an issue first. |

CArray 3.0 was built the way the README describes: designed and reviewed
by me, implemented in collaboration with AI coding tools. That has a
consequence worth saying plainly, because it is not visible from outside.
Code here gets rewritten as a matter of course — mine included. A patch
that touches the internals is likely to be reimplemented rather than
merged, and not because anything is wrong with it. That is simply how
work moves through this repository.

So a description travels further than a diff. An issue saying what you
were trying to do, what happened, and what you expected can be acted on
directly. A patch for the same thing may end up read for the problem it
describes and then written again — a poor return on your evening.

A small, self-contained bug fix is the exception. Send it as a pull
request.

When a change starts from your issue, the changelog entry will say so.

## Opening an issue

Issues in English or Japanese are both fine.

For a bug, include:

- CArray version (`CArray::VERSION`), Ruby version, OS, and compiler
- The smallest script that shows the problem
- What you expected and what you got

And, where they apply, the three things most CArray bugs turn on:

- the **data type** of the arrays involved
- whether any of them carries a **mask**
- whether you are working on an **entity or a view** (`a[0..1, nil]`,
  `transpose`, `reshape` and friends return views that share storage)

Please say which OS you are on even if the bug looks portable. Behaviour
has differed between macOS and Linux in this library before — SEGVs, NaN
results and warnings that appear on one and not the other — so "works on
my machine" is not evidence about yours.

Note that 3.0.x is still moving: behaviour can change between releases.
A change recorded in [CHANGELOG.md](CHANGELOG.md) is a change, not a bug.
If a documented change breaks something for you, that is still worth an
issue — say what it broke.

For a feature request, describe the problem rather than the API you have
in mind. What you were trying to compute, and what made it awkward, is
the part that carries; the shape it should take is the part most likely
to change on the way in.

Performance reports are welcome as reproducible scripts. The benchmark
suite used for development is not part of this repository, so a number on
its own cannot be checked against anything; a script can be run.

## Sending a fix

Ruby 3.0 or later is required. Build and test:

```sh
rake build_ext     # build the C extension in place
rake test          # every test suite, plus the yard-stubs drift check
```

`rake test` must report no failures. It is also the default task, so a bare
`rake` does the same thing.

It runs two separate bodies of tests, and only one of them is yours to
add to:

- `spec/Classes`, `spec/Features` and `spec/UnitTest` are written by hand.
  A test for your fix goes here. Both rspec and test/unit are in use —
  follow whichever the neighbouring file uses.
- `spec/spec_ai` is a large set of regression pins written alongside the
  3.0 rewrite with AI tooling, which is what the name records. They pin
  behaviour rather than describe it, and many are named after development
  phases that mean nothing from outside. You are not expected to read them
  or to add to them. If one fails on your change, do not edit it to pass —
  say which one failed; either your change broke something the pin was
  guarding, or the pin was guarding an accident.

Then, in the same pull request:

- If you touched `ext/*.c`, check the matching `yard-stubs/*.rb`. Those
  stubs are the source of the user-facing documentation, and a stub that
  disagrees with the code shows users something untrue. `rake stub_check`
  catches a missing or phantom method, not a stale description.
- Add an entry to [CHANGELOG.md](CHANGELOG.md), at the top of the
  unreleased section, opening with `- Fix:`. Write it for someone who hit
  the bug: what behaves differently now, not how the code was wrong.

Keep the commit message to a subject line and a line or two of context.
Anything a user needs to know belongs in the changelog entry rather than
in the commit.

## Working on the code

`guides/devel/` is the developer's guide — architecture, the core data
structures, memory management, the mask, the kernel iterator, the
MemoryView protocol. Start at `guides/devel/00_glossary.md`. It is written
for someone changing the C extension, and it is the fastest way in.

`guides/users/` is the user's guide, which is often enough to tell whether
something is a bug or the documented behaviour.

## License

By submitting a pull request, you agree that your contribution is licensed
under the MIT License, the same terms as the rest of the project.
