# AGENTS.local.md: Ripwire workflow for this fork (racecraft-lab/herdr-app)

Local rules for agents working in this checkout. They add to `AGENTS.md`; they
never override it. These files come from the `racecraft/tooling` branch and
are hidden from git by `.git/info/exclude`. Never commit them to a PR branch
and never mention them in an upstream PR.

Ripwire 0.6.9 is on PATH as `ripwire`. Pass one flag per argument, run every
command from the checkout root, and check `ripwire --help=--FLAG` before using
a flag you have not used here. Add `--legend=compact` to every XML verb.

## Files

| File | What it does |
|---|---|
| `.ripwire_arch_rules` | Intended layering of the app root, with each rule's intent |
| `.ripwire_arch_baseline` | Accepted layering debt on upstream master (empty: no debt) |
| `.ripwire/gpui-kit/` | The same pair for `vendor/gpui-kit`, which runs as its own root |
| `.ripwire_notes` | Field notes that `--for`, `--expand` and `--edit-check` surface |
| `.ripwire/gate.sh` | The pre-PR gate below, at the strictest settings |
| `.ripwire_untested_acks` | Changed functions the maintainer accepts without a test (none yet) |
| `CLAUDE.local.md` | Imports `AGENTS.md` and this file for Claude Code |

There is no quality baseline here on purpose. Ripwire honors one only at the
exact commit and build it was pinned at, and a bare `--quality-delta` deletes
a stale one. The gate uses the range form, which reads no sidecar.

## 1. Orient

- Task in words: `ripwire . --for="<task, with exact symbols and file names>" --legend=compact`.
- Known symbol: `ripwire . --expand=SYM --legend=compact` (use the `file:name` it prints to pick one).
- Stack trace or compiler error: `ripwire . --from-trace=FILE --legend=compact`.
- Known literal or small known file: plain `rg` or a read is fine.
- Before writing a new function: `ripwire . --exemplar="<what it does>" --legend=compact`.

## 2. Before you edit

For every existing symbol you will change:

```sh
ripwire . --impact=SYM --legend=compact   # everything that reaches it (transitive)
ripwire . --uses=SYM --legend=compact     # every read, write and import site
```

After each edit: `ripwire . --edit-check=SYM --legend=compact`. A
`contract-change` you did not intend is a bug.

## 3. Pre-PR gate (blocking)

Commit first, then run from the branch's checkout root:

```sh
.ripwire/gate.sh            # vs the merge-base with upstream/master
```

It fails (exit 1) when any of these fails:

- `ripwire . --doctor` (exit 1).
- `ripwire . --arch=.ripwire_arch_rules` (exit 2 = a new layering violation).
- `cd .ripwire/gpui-kit && ripwire ../../vendor/gpui-kit --arch=.ripwire_arch_rules`.
- `ripwire . --quality-delta=<merge-base>..HEAD`: all 12 kinds, no `--scope`,
  no acks (exit 2 = existing code got worse). The same for `vendor/gpui-kit`
  when the branch touches it.
- `tests-app`: `ripwire . --test-gate=<changed files>` names test files to
  run. The gate runs `cargo test --locked --no-fail-fast` itself, and fails if
  the suite fails or if a named file did not run in it (or has no runner).
- `untested-app`: every function or method the change adds or edits must be
  reached by a test that passed in that run. The gate prints the test and
  call path for each, or `FAIL` with how far it searched.
- The same two for `vendor/gpui-kit` when touched. Its crates cannot be
  tested from this checkout yet, so that step fails closed.

A changed definition whose `cfg(...)` is false on this machine (a
`cfg(not(target_os = "macos"))` stub on a Mac) is not compiled here, so it
gets an `OTHER-OS` row. If nothing failed, the gate then ends `INCOMPLETE`
with exit 3, not `PASS`. Say in the PR which definitions still need a run on
another OS.

Ripwire does not model in-file `#[cfg(test)]` unit tests as tests here. It
names only `tests/*.rs` targets, and it reports new `#[test]` functions as
new-symbol `dead-code`, which never gates. The gate makes up for this: a
passed cargo test that calls the function counts. So when `untested-app`
fails, add a unit test that calls the function (or a tested caller of it).
`README.md` on the tooling branch lists what the check cannot see.

The `<u>` rows (impacted callers no test reaches) are outside the change and
do not block; the full list is in `.ripwire/out/untested-radius-app.txt`.
The gate does not run the bun script tests unless ripwire names one, so run
`just test` too, and say in the PR which tests ran.

`--quality-delta` exit 0 means nothing that already existed got worse. It
does not mean no new debt: read every `origin="new-symbol"` row, and fix
each one that is not a false positive.

The gate also writes report-only lenses to `.ripwire/out/`. Ripwire exits 0 on
them by design; read them and fix what your branch added:
`--lint --naming-locals` (every built-in rule), `--dead-code`, `--clones`,
`--doc-drift --with-history` and `--quality-panel=strict`.

Never acknowledge a finding to pass the gate. `--quality-ack` and
`.ripwire_untested_acks` are for debt the maintainer accepted, in its own
reviewed commit on `racecraft/tooling`.

## What ripwire cannot see here

- Rust edges: only `mod NAME;` in `src/main.rs` resolves to a file. `use
  crate::...`, nested `mod`, crate imports and `#[path]` modules do not, so
  rules marked INERT in `.ripwire_arch_rules` do not gate yet.
- `vendor/` is pruned from the app root. Only `vendor/gpui-kit` is checked, as
  its own root; changes to other vendored crates are not measured.
- The range form cannot measure `short-horizon-churn` (`churn="unavailable"`).
- Every count marked `counts_floor` is a floor, and zero means "none found".

## Keeping the tooling current

The source of truth is the `racecraft/tooling` branch, checked out at
`../herdr-app-tooling`. From there:

- `./sync.sh status` shows what differs from this checkout.
- `./sync.sh pull` copies sidecars ripwire wrote here (`--note-add`,
  `--baseline-update`, `--quality-ack`) back to the tooling worktree. Commit
  them on `racecraft/tooling` and push to `origin`. Every worktree shares one
  `.git/info/exclude` that hides these names, so a file the branch does not
  track yet (such as a first `.ripwire_quality_acks`) needs `git add -f`.
- `./sync.sh push [CHECKOUT]` copies tooling changes into a checkout. Pass the
  path for another worktree, such as `../herdr-app-fix`.
- Regenerate baselines on a clean `upstream/master` worktree after a ripwire
  upgrade or a layering change. `README.md` on the tooling branch has the
  commands.
- Add a `deny path` line to `.ripwire_arch_rules` when upstream adds a mod or
  frame page under `defaults/`.
