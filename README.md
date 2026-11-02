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
| `.ripwire/gate.sh` | same path | Pre-PR gate: doctor, arch, quality-delta, test-gate |
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
- `--test-gate=<changed files>` with exit 4 treated as a failure.
- `--arch` against empty baselines, for both roots.
- `--lint --naming-locals` with every built-in rule (no `--lint-select`, no
  `--lint-ignore`), `--doc-drift --with-history`, `--dead-code`, `--clones`
  and `--quality-panel=strict`. These exit 0 by design and are reports only.

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
