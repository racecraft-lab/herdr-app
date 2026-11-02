# racecraft/tooling

Orphan branch of `racecraft-lab/herdr-app` that holds only our Ripwire and
agent config. It never carries upstream code, and no PR branch ever carries
these files. Check it out as its own worktree next to the main checkout:

```sh
git -C ../herdr-app worktree add ../herdr-app-tooling racecraft/tooling
./sync.sh push                     # copy into ../herdr-app and hide from git
./sync.sh push ../herdr-app-fix    # any other worktree
```

`sync.sh` copies real files (ripwire refuses symlinked sidecars) and adds the
names to the checkout's `.git/info/exclude`. `./sync.sh pull` brings back the
sidecars ripwire writes (`.ripwire_notes`, arch baselines, quality acks).
The workflow for agents is in `AGENTS.local.md`.

All worktrees share one `.git/info/exclude`, and it hides these names here
too. Updates to tracked files commit normally; a new file (such as a first
`.ripwire_quality_acks`) needs `git add -f`.

## Files

| Path | Synced to | Enforces |
|---|---|---|
| `.ripwire_arch_rules` | checkout root | App layering; `--arch` exit 2 on a new violation |
| `.ripwire_arch_baseline` | checkout root | Accepted debt on upstream master (none) |
| `.ripwire/gpui-kit/.ripwire_arch_rules` | same path | `vendor/gpui-kit` crate layering |
| `.ripwire/gpui-kit/.ripwire_arch_baseline` | same path | Its accepted debt (none) |
| `.ripwire/gate.sh` | same path | Pre-PR gate: doctor, arch, quality-delta, tests, untested code |
| `.ripwire_untested_acks` | checkout root (none yet) | Changed functions the maintainer accepts without a test, one `PATH:NAME<TAB>reason` per line |
| `.ripwire_notes` | checkout root | Field notes surfaced on matching files |
| `AGENTS.local.md`, `CLAUDE.local.md` | checkout root | Agent workflow; Claude Code import |
| `upstream-master/.ripwire_quality_baseline` | only a checkout at its pinned commit | Quality floor of upstream master |

## Settings: what is configuration and what is a command

Ripwire has no threshold configuration. Its only config file,
`.ripwire_config`, has one key (`register_macros`), which exempts
macro-registered tests from dead-code; it cannot match Rust `#[test]`
attributes, so this repo has none. The bars are fixed in the binary
(`--quality-panel` prints them: `bar_ccx=15 bar_loc=60 bar_nest=4
bar_params=5`; `--dmm` uses `loc<=15`, `cyclomatic<=5`, `params<=2`).
Strictness is chosen per command, so `.ripwire/gate.sh` runs the strictest
form of each:

- `--quality-delta=<merge-base>..HEAD` over all 12 kinds: no `--quality-kinds`,
  no `--scope`, no `.ripwire_quality_acks`.
- `--test-gate=<changed files>`, whose exit 4 the gate discharges with
  evidence instead of reading it as a failure (next section).
- `--arch` against empty baselines, for both roots.
- `--lint --naming-locals` with every built-in rule (no `--lint-select`, no
  `--lint-ignore`), `--doc-drift --with-history`, `--dead-code`, `--clones`
  and `--quality-panel=strict`. These exit 0 by design and are reports only.

## How the gate discharges `--test-gate`

`--test-gate` exits 4 whenever the change has any test to run or any impacted
symbol no test reaches, so on its own it fails nearly every branch. The gate
keeps both obligations and turns each into a check that needs evidence:

- **tests** (`<t>`/`<g>` rows). The gate runs `cargo test --locked
  --no-fail-fast`, the whole suite, and fails if it fails. Each test file
  ripwire names must then show up in that run: `tests/X.rs` as cargo's
  `Running tests/X.rs` line (the harness = false targets included), a
  `*.test.ts` file through `bun test`, or a row's `run=` command. A row with
  none of these fails as "no runner".
- **untested code**. For each changed line, `ripwire --at` names the function
  or method around it. Each one that is not test code must be reached by a
  test that passed in that run. Ripwire has no call edges out of in-file
  `#[cfg(test)]` modules, so the gate looks for the call itself:
  `ripwire --regex` finds the call sites of the name, and a site counts when
  its enclosing definition is a passed cargo test, in the same file or through
  `module::name`. Failing and ignored tests do not count. The gate then walks
  up `ripwire --callers` through resolved edges only, so a test that calls a
  caller also counts. Name-only edges are skipped, because they credit
  `tests/shot_pixels.rs` with code in `src/terminal.rs` it cannot call.
  `src/main.rs::main` counts as reached when a passed test spawns the binary
  (`CARGO_BIN_EXE_herdr-app`), which ripwire does not model; that credit stops
  at `main` and does not pass to its callees.
- The `<u>` rows are callers outside the change. Their gaps predate the
  change, so they are listed in full in `.ripwire/out/untested-radius-app.txt`
  and do not block.

Every row the gate prints says how it was discharged: the test target that
ran, or the passed test and call path that reaches each changed function.
`.ripwire_untested_acks` accepts a named function without a test. Like
`--quality-ack`, an entry is the maintainer's call, in its own reviewed commit
here, and the gate prints its reason. The file does not exist yet.

Limits:

- Reach is per function. A test that calls a function credits all of it,
  including a changed branch that test never takes.
- Ripwire records no call written inside a macro (`debug!(.., f())`) in code
  outside tests. A function called only that way reads as unreached.
- Only Rust definitions are checked. A changed function in `scripts/*.ts` gets
  no untested check, and ripwire's `<u>` rows leave changed symbols out, so
  nothing else catches it either.
- A changed line `ripwire --at` places in no definition goes to the printed
  "changed lines in no function" list and does not block. Doc comments,
  attributes and imports land there, and so would a line in a
  `macro_rules!` body or in a file ripwire parsed with errors
  (`parse_degraded="1"`). Read that list.
- `vendor/gpui-kit` crates cannot be tested from this checkout. Cargo refuses
  `cargo test -p gpui-base` ("requires dev-dependencies and is not a member of
  the workspace"), and the kit has no `Cargo.lock` for `--locked`. A branch
  that touches the kit therefore fails `tests-kit` until that changes.
- A caller that lost its only tested path, because a changed function stopped
  calling it, is not detected.

## Regenerating after a ripwire upgrade or a rules change

The quality baseline is stamped with its commit and with the ripwire build,
and only that build honors it. On a clean `upstream/master` worktree:

```sh
git -C ../herdr-app fetch upstream
git -C ../herdr-app worktree add --detach ../herdr-app-upstream-master upstream/master
cd ../herdr-app-upstream-master
ripwire . --quality-baseline              # before copying anything in
cp .ripwire_quality_baseline ../herdr-app-tooling/upstream-master/
cp ../herdr-app-tooling/.ripwire_arch_rules .
ripwire . --arch=.ripwire_arch_rules --baseline
mkdir -p .ripwire/gpui-kit && cp ../herdr-app-tooling/.ripwire/gpui-kit/.ripwire_arch_rules .ripwire/gpui-kit/
(cd .ripwire/gpui-kit && ripwire ../../vendor/gpui-kit --arch=.ripwire_arch_rules --baseline)
cp .ripwire_arch_baseline ../herdr-app-tooling/
cp .ripwire/gpui-kit/.ripwire_arch_baseline ../herdr-app-tooling/.ripwire/gpui-kit/
```

The arch baseline is read from the current directory, and its keys depend on
how the root is spelled, so always generate and check with the exact commands
the gate uses. Commit the result on this branch and push it to `origin`.

No `--index-out` artifact is committed. Measured on upstream master with
ripwire 0.6.9 it is 7.6 MB for the app root (3.3 MB lean + 4.2 MB rich) and
25.6 MB for gpui-kit. It is tied to the machine architecture, is not
byte-identical between runs, and goes stale with each commit, while the
default per-root cache already keeps local runs warm.

## MCP

No project-scoped server. The user-scope `ripwire --mcp` server (Claude Code)
and `[mcp_servers.ripwire]` (Codex) already take their root from the call's
`path=` or the launch directory, which is the checkout root. A pinned
`ripwire <root> --mcp` would add a second copy of the same tools and nothing
this repo needs: no MCP verb reads the arch rules or runs the gate.
