#!/bin/sh
# Pre-PR Ripwire gate for a herdr-app branch, at the strictest settings
# ripwire 0.6.9 offers. Run from the checkout root of the branch under test:
#
#   .ripwire/gate.sh [BASE_REF]      # BASE_REF defaults to upstream/master
#   NO_FETCH=1 .ripwire/gate.sh      # skip `git fetch upstream`
#
# It compares the committed branch (HEAD) against its merge-base with
# BASE_REF, so commit first: uncommitted edits are not measured.
#
# BLOCKING checks (the gate exits 1 if any fails):
#   doctor        ripwire --doctor                         exit 1 = unhealthy setup
#   arch-app      --arch=.ripwire_arch_rules               exit 2 = new violation
#   arch-kit      gpui-kit --arch (own root, own baseline) exit 2 = new violation
#   delta-app     --quality-delta=MERGE_BASE..HEAD         exit 2 = gating rows
#   delta-kit     same, vendor/gpui-kit root (if touched)  exit 2 = gating rows
#   tests-app     --test-gate=<changed files>              exit 4 = tests to run
#   tests-kit     same, vendor/gpui-kit root (if touched)     or untested radius
# Any other non-zero exit (1 refusal, 5 memory stop, 6 partial answer) also
# fails. All 12 quality kinds run (no --quality-kinds), with no --scope and no
# quality acks. Exit 4 from --test-gate is blocking by policy: discharge it by
# running the named tests and `just test`, then record that in the PR.
#
# REPORT-ONLY lenses (ripwire exits 0 on these by design; read the files):
#   lint (every built-in rule, --naming-locals), dead-code, clones,
#   doc-drift --with-history, quality-panel=strict.
# Their full output lands in .ripwire/out/.
set -u

base_ref=${1:-upstream/master}
root=$(git rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1
out="$root/.ripwire/out"
mkdir -p "$out"
# Never report a previous run's result for a check this run skips.
rm -f "$out"/*.xml "$out"/*.txt

for f in .ripwire_arch_rules .ripwire_arch_baseline .ripwire/gpui-kit/.ripwire_arch_rules .ripwire/gpui-kit/.ripwire_arch_baseline; do
  if [ ! -f "$f" ]; then
    echo "gate: missing $f; run sync.sh push from the racecraft/tooling worktree" >&2
    exit 1
  fi
done

if [ "${NO_FETCH:-0}" != 1 ]; then
  git fetch --quiet upstream || echo "gate: warning: git fetch upstream failed; using local refs" >&2
fi
merge_base=$(git merge-base "$base_ref" HEAD) || { echo "gate: no merge-base with $base_ref" >&2; exit 1; }
head_sha=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "gate: warning: tracked files have uncommitted changes; they are NOT measured" >&2
fi

# Changed files on the branch that still exist at HEAD, split by ripwire
# root. --test-gate refuses a file the index lacks, so drop every path that
# `ripwire --skipped` lists (unsupported type, oversize, excluded). vendor/
# is pruned from the app root; vendor/gpui-kit is checked as its own root.
git diff --name-only --diff-filter=d "$merge_base" HEAD > "$out/changed.txt"
ripwire . --skipped --legend=compact 2>/dev/null | grep -o '<f p="[^"]*"' | sed 's/^<f p="//; s/"$//' > "$out/skipped-app.txt"
ripwire vendor/gpui-kit --skipped --legend=compact 2>/dev/null | grep -o '<f p="[^"]*"' | sed 's/^<f p="//; s/"$//' > "$out/skipped-kit.txt"
app_files=$(grep -v '^vendor/' "$out/changed.txt" | grep -vxF -f "$out/skipped-app.txt" | paste -sd, -)
kit_files=$(grep '^vendor/gpui-kit/' "$out/changed.txt" | sed 's#^vendor/gpui-kit/##' | grep -vxF -f "$out/skipped-kit.txt" | paste -sd, -)
other_vendor=$(grep '^vendor/' "$out/changed.txt" | grep -v '^vendor/gpui-kit/' | paste -sd' ' -)

failed=0
summary=""
record() { # name rc pass_codes
  name=$1; rc=$2; ok=0
  for c in $3; do [ "$rc" = "$c" ] && ok=1; done
  if [ "$ok" = 1 ]; then verdict=pass; else verdict=FAIL; failed=1; fi
  summary="$summary
  $name: exit $rc ($verdict)"
}
run() { # name file pass_codes cmd...
  name=$1; file=$2; codes=$3; shift 3
  "$@" > "$out/$file" 2>&1
  rc=$?
  record "$name" "$rc" "$codes"
}

echo "gate: HEAD $head_sha vs merge-base $merge_base ($base_ref)"
echo "gate: app files: ${app_files:-none}"
echo "gate: gpui-kit files: ${kit_files:-none}"
[ -n "$other_vendor" ] && echo "gate: NOT MEASURED (vendor/ outside gpui-kit): $other_vendor"

run doctor doctor.xml 0 ripwire . --doctor
run arch-app arch-app.xml 0 ripwire . --arch=.ripwire_arch_rules --legend=compact
( cd .ripwire/gpui-kit && ripwire ../../vendor/gpui-kit --arch=.ripwire_arch_rules --legend=compact ) > "$out/arch-kit.xml" 2>&1
record arch-kit $? 0
run delta-app delta-app.xml 0 ripwire . --quality-delta="$merge_base..$head_sha" --legend=compact
if [ -n "$kit_files" ]; then
  run delta-kit delta-kit.xml 0 ripwire vendor/gpui-kit --quality-delta="$merge_base..$head_sha" --legend=compact
  run tests-kit tests-kit.xml 0 ripwire vendor/gpui-kit --test-gate="$kit_files" --legend=compact
fi
if [ -n "$app_files" ]; then
  run tests-app tests-app.xml 0 ripwire . --test-gate="$app_files" --legend=compact
fi

# Report-only lenses (always exit 0 by design).
ripwire . --lint --naming-locals --legend=compact > "$out/lint.xml" 2>&1
ripwire . --dead-code --legend=compact > "$out/dead-code.xml" 2>&1
ripwire . --clones --legend=compact > "$out/clones.xml" 2>&1
ripwire . --doc-drift --with-history --legend=compact > "$out/doc-drift.xml" 2>&1
ripwire . --quality-panel=strict --legend=compact > "$out/quality-panel.xml" 2>&1
if grep -q 'count_capped="1"' "$out/lint.xml"; then
  echo "gate: warning: a lint rule hit its match budget; re-run with the findings_next= command in $out/lint.xml" >&2
fi

echo "gate: blocking checks:$summary"
for f in arch-app arch-kit delta-app delta-kit tests-app tests-kit; do
  [ -f "$out/$f.xml" ] || continue
  grep -o '<arch [^>]*>\|<quality-delta [^>]*>\|<test-gate [^>]*>' "$out/$f.xml" | head -1 | sed "s#^#  $f: #" | cut -c1-400
done
echo "gate: reports:"
grep -o '<lint [^>]*>' "$out/lint.xml" | sed 's#^#  #'
grep -o '<dead-code [^>]*>' "$out/dead-code.xml" | sed 's#^#  #' | cut -c1-200
grep -o '<clones [^>]*>' "$out/clones.xml" | sed 's#^#  #' | cut -c1-200
grep -o '<doc-drift [^>]*>' "$out/doc-drift.xml" | sed 's#^#  #'
echo "gate: full output in $out/"
if [ "$failed" = 1 ]; then echo "gate: FAIL"; exit 1; fi
echo "gate: pass"
