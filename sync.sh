#!/bin/sh
# Copy the Ripwire and agent config between this racecraft/tooling worktree
# and a herdr-app checkout. Real files, not symlinks: ripwire refuses to read
# or write its sidecars through a symlink, and --quality-ack replaces one.
#
#   ./sync.sh status [CHECKOUT]   show what differs (default: show only)
#   ./sync.sh push   [CHECKOUT]   tooling -> checkout (after you change config here)
#   ./sync.sh pull   [CHECKOUT]   checkout -> tooling (after ripwire wrote a sidecar,
#                                 e.g. --note-add, --baseline-update, --quality-ack)
#   add --force after the verb to overwrite a file changed on both sides.
#
# CHECKOUT defaults to the main herdr-app checkout next to this worktree.
# Safe to re-run: unchanged files are left alone. A file missing on the
# source side is never deleted on the other side. Each checkout keeps the
# hash of every file at its last sync in .ripwire/.sync-state, so a file
# changed on BOTH sides since then is reported as a conflict and skipped.
# The quality baseline is pushed only into a checkout whose HEAD equals the
# commit it was pinned at, because ripwire deletes a sidecar pinned at any
# other commit. The script also keeps the checkout's .git/info/exclude
# hiding every synced name, so git status stays clean.
set -u

here=$(cd "$(dirname "$0")" && pwd)
verb=${1:-status}
[ $# -gt 0 ] && shift
force=0
if [ "${1:-}" = "--force" ]; then force=1; shift; fi
checkout=${1:-$(dirname "$here")/herdr-app}
checkout=$(cd "$checkout" 2>/dev/null && pwd) || { echo "sync: no checkout at ${1:-default path}" >&2; exit 1; }

case "$verb" in status|push|pull) ;; *) echo "usage: sync.sh status|push|pull [--force] [CHECKOUT]" >&2; exit 2 ;; esac
if [ "$checkout" = "$here" ]; then echo "sync: CHECKOUT is the tooling worktree itself" >&2; exit 2; fi
git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1 || { echo "sync: $checkout is not a git checkout" >&2; exit 1; }

# Files that live at the same relative path on both sides.
files=".ripwire_arch_rules
.ripwire_arch_baseline
.ripwire_notes
.ripwire_quality_acks
.ripwire/gate.sh
.ripwire/gpui-kit/.ripwire_arch_rules
.ripwire/gpui-kit/.ripwire_arch_baseline
AGENTS.local.md
CLAUDE.local.md"
# Names hidden from git in the checkout (shared by all its worktrees).
excludes="/.ripwire_arch_rules
/.ripwire_arch_baseline
/.ripwire_notes
/.ripwire_quality_acks
/.ripwire_quality_baseline
/.ripwire/
/AGENTS.local.md
/CLAUDE.local.md"

state="$checkout/.ripwire/.sync-state"
hash() { [ -f "$1" ] && shasum -a 256 "$1" | cut -d' ' -f1 || echo none; }
recorded() { [ -f "$state" ] && grep "	$1\$" "$state" | cut -f1 || true; }
changes=0
newstate=""

for f in $files; do
  t="$here/$f"; c="$checkout/$f"
  for p in "$t" "$c"; do
    if [ -L "$p" ]; then echo "sync: $p is a symlink; replace it with a regular file" >&2; exit 1; fi
  done
  ht=$(hash "$t"); hc=$(hash "$c"); hr=$(recorded "$f")
  if [ "$ht" = "$hc" ]; then
    [ "$ht" != none ] && newstate="$newstate$ht	$f
"
    continue
  fi
  if [ "$verb" = push ]; then src=$t; dst=$c; hs=$ht; hd=$hc; else src=$c; dst=$t; hs=$hc; hd=$ht; fi
  if [ "$verb" = status ]; then
    echo "differs: $f (tooling=$(echo "$ht" | cut -c1-8) checkout=$(echo "$hc" | cut -c1-8))"
    changes=1; [ -n "$hr" ] && newstate="$newstate$hr	$f
"
    continue
  fi
  if [ "$hs" = none ]; then
    echo "skip (missing on source side, never deleted): $f"
    [ -n "$hr" ] && newstate="$newstate$hr	$f
"
    continue
  fi
  # Never overwrite a destination file that changed since the last sync
  # (or was never synced) unless --force.
  if [ "$hd" != none ] && [ "$hd" != "$hr" ] && [ "$force" = 0 ]; then
    if [ -z "$hr" ]; then why="never synced and differs"
    elif [ "$hs" = "$hr" ]; then why="changed only on the $verb destination; run the other direction"
    else why="changed on both sides since last sync"; fi
    echo "SKIP ($why; --force overwrites): $f"
    [ -n "$hr" ] && newstate="$newstate$hr	$f
"
    changes=1
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "$verb: $f"
  changes=1
  newstate="$newstate$hs	$f
"
done

# Quality baseline: only into a checkout at the exact pinned commit.
qb="$here/upstream-master/.ripwire_quality_baseline"
if [ -f "$qb" ]; then
  pinned=$(sed -n 's/^head //p' "$qb" | head -1)
  head=$(git -C "$checkout" rev-parse HEAD)
  if [ "$pinned" = "$head" ]; then
    if [ "$verb" = push ] && ! cmp -s "$qb" "$checkout/.ripwire_quality_baseline"; then
      cp "$qb" "$checkout/.ripwire_quality_baseline"; echo "push: .ripwire_quality_baseline (HEAD is the pinned $pinned)"
    fi
  elif [ "$verb" = status ]; then
    echo "info: quality baseline pinned at $pinned; checkout HEAD is $head, so it is not synced there"
  fi
fi

if [ "$verb" = push ] || [ "$verb" = pull ]; then
  mkdir -p "$checkout/.ripwire"
  printf '%s' "$newstate" > "$state"
  ex="$(git -C "$checkout" rev-parse --git-common-dir)"
  case "$ex" in /*) ;; *) ex="$checkout/$ex" ;; esac
  ex="$ex/info/exclude"
  mkdir -p "$(dirname "$ex")"; touch "$ex"
  missing=""
  for e in $excludes; do grep -qxF "$e" "$ex" || missing="$missing$e
"; done
  if [ -n "$missing" ]; then
    printf '\n# racecraft/tooling: Ripwire and agent config, synced by sync.sh.\n%s' "$missing" >> "$ex"
    echo "exclude: added to $ex:"; printf '%s' "$missing" | sed 's/^/  /'
  fi
fi
[ "$changes" = 0 ] && echo "sync: $verb: nothing to do ($checkout)"
exit 0
