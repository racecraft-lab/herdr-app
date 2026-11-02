#!/bin/sh
# Pre-PR Ripwire gate for a herdr-app branch, at the strictest settings
# ripwire 0.6.9 offers. Run from the checkout root of the branch under test:
#
#   .ripwire/gate.sh [BASE_REF]      # BASE_REF defaults to upstream/master
#   NO_FETCH=1 .ripwire/gate.sh      # skip `git fetch upstream`
#
# The quality delta compares the committed branch (HEAD) with its merge-base
# with BASE_REF. The test steps build, index and run the working tree, since
# that is what cargo compiles and ripwire reads. Commit first, so both measure
# the same code; the gate warns when they differ.
#
# BLOCKING checks (the gate exits 1 if any fails):
#   doctor        ripwire --doctor                         exit 1 = unhealthy setup
#   arch-app      --arch=.ripwire_arch_rules               exit 2 = new violation
#   arch-kit      gpui-kit --arch (own root, own baseline) exit 2 = new violation
#   delta-app     --quality-delta=MERGE_BASE..HEAD         exit 2 = gating rows
#   delta-kit     same, vendor/gpui-kit root (if touched)  exit 2 = gating rows
#   tests-app     --test-gate=<changed files> exits 4 while it names tests to
#   untested-app  run or untested code. The gate discharges both obligations
#                 with evidence, and fails when the evidence is missing or bad:
#     tests-*     The gate runs `cargo test --locked --no-fail-fast` (the whole
#                 suite, every target even after a failure), which must pass. Each test file ripwire names (<t>/<g> rows) must
#                 show up in that run: tests/X.rs as cargo's "Running
#                 tests/X.rs" line, *.test.ts|js through `bun test FILE`, a
#                 row's run= command as given. A row with no runner FAILS.
#     untested-*  Each function or method the change adds or edits (the
#                 definition around each changed line, `ripwire --at`) must be
#                 reached by a test that passed in that run: a passed test that
#                 calls it (`ripwire --regex` names the enclosing test; ripwire's
#                 graph has no edges out of #[cfg(test)] modules), or that calls
#                 one of its resolved callers, transitively (`ripwire --callers`;
#                 name-only edges are ignored, because they credit tests that
#                 cannot call the code). `main` also counts as reached when a
#                 passed test spawns the binary (CARGO_BIN_EXE_*), which ripwire
#                 does not model; that credit is not passed on to its callees.
#                 An entry in .ripwire_untested_acks (`PATH:NAME<TAB>reason`,
#                 maintainer-reviewed commits on racecraft/tooling only) is
#                 printed with its reason and does not block. Ripwire's <u> rows
#                 (impacted callers outside the change that no test reaches) are
#                 pre-existing gaps: listed in full in .ripwire/out, not blocking.
#   tests-kit / untested-kit: the same for vendor/gpui-kit when the branch
#                 touches it, through `cargo test --locked -p <crate>`.
# Any other non-zero ripwire exit (1 refusal, 5 memory stop, 6 partial answer)
# also fails, and so does a capped row list. All 12 quality kinds run (no
# --quality-kinds), with no --scope and no quality acks.
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
rd="$out/reach"
mkdir -p "$out"
# Never report a previous run's result for a check this run skips.
rm -f "$out"/*.xml "$out"/*.txt
rm -rf "$rd"
mkdir -p "$rd"
tab=$(printf '\t')
search_cap=${UNTESTED_SEARCH_CAP:-200}

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
  echo "gate: warning: tracked files have uncommitted changes; the quality delta does NOT measure them, the test steps do" >&2
fi
git ls-files --others --exclude-standard > "$out/untracked.txt"
if [ -s "$out/untracked.txt" ]; then
  echo "gate: warning: untracked files are tested and checked for untested code, but not in the quality delta: $(paste -sd' ' - < "$out/untracked.txt")" >&2
fi

# Changed files that still exist in the working tree, split by ripwire root.
# --test-gate refuses a file the index lacks, so drop every path that
# `ripwire --skipped` lists (unsupported type, oversize, excluded). vendor/
# is pruned from the app root; vendor/gpui-kit is checked as its own root.
{ git diff --name-only --diff-filter=d "$merge_base"; cat "$out/untracked.txt"; } | sort -u > "$out/changed.txt"
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
verdict() { # name pass|FAIL detail
  [ "$2" = pass ] || failed=1
  summary="$summary
  $1: $2 ($3)"
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
fi

# ---------------------------------------------------------------------------
# Test obligations. Helpers first.

# rows TAG ATTR...: one tab-separated line of the named attributes per <TAG>
# element on stdin, XML entities decoded; the legend comment is skipped.
rows() {
  rows_tag=$1; shift
  awk -v tag="$rows_tag" -v attrs="$*" '
    BEGIN { na = split(attrs, A, " ") }
    { s = $0
      while ((i = index(s, "<!--")) > 0) {
        j = index(substr(s, i), "-->")
        s = (j > 0) ? substr(s, 1, i - 1) substr(s, i + j + 2) : substr(s, 1, i - 1)
      }
      while (match(s, "<" tag " [^>]*>")) {
        e = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); line = ""
        for (k = 1; k <= na; k++) {
          v = ""
          if (match(e, " " A[k] "=\"[^\"]*\"")) v = substr(e, RSTART + length(A[k]) + 3, RLENGTH - length(A[k]) - 4)
          gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v); gsub(/&quot;/, "\"", v); gsub(/&apos;/, "\047", v); gsub(/&amp;/, "\\&", v)
          line = line (k > 1 ? "\t" : "") v
        }
        print line
      } }'
}

# The cargo package directory (repo-relative) that owns FILE: "." for the app.
pkgdir() {
  pk_d=$(dirname "$1")
  while [ "$pk_d" != . ] && [ ! -f "$pk_d/Cargo.toml" ]; do pk_d=$(dirname "$pk_d"); done
  echo "$pk_d"
}
pkgrel() { # FILE -> path inside its package
  pr_d=$(pkgdir "$1")
  if [ "$pr_d" = . ]; then echo "$1"; else echo "${1#"$pr_d"/}"; fi
}
# Rust module path of a src/ FILE inside its crate ("" for the crate root).
modpath() {
  mp_r=$(pkgrel "$1")
  case $mp_r in src/*) ;; *) return 0 ;; esac
  mp_m=${mp_r#src/}; mp_m=${mp_m%.rs}
  case $mp_m in main|lib|mod) mp_m="" ;; */mod) mp_m=${mp_m%/mod} ;; esac
  printf '%s\n' "$mp_m" | sed 's#/#::#g'
}
# The name another module calls FILE's items through: its last module segment.
modname() {
  mn_m=$(modpath "$1")
  if [ -n "$mn_m" ]; then echo "${mn_m##*::}"; else basename "$1" .rs; fi
}
# The cargo test target a tests/ FILE belongs to, as cargo's Running line spells it.
test_target() {
  case $1 in
    tests/*/*) echo "tests/$(echo "$1" | cut -d/ -f2)/main.rs" ;;
    *) echo "$1" ;;
  esac
}

# parse_cargo PKGDIR LOG: append the targets that ran to ran.txt and every
# passed test to ok.txt (PKGDIR, target, test name). Ignored tests are not ok.
parse_cargo() {
  awk -v pd="$1" -v ran="$rd/ran.txt" -v ok="$rd/ok.txt" -v counts="$rd/counts.txt" '
    /^[[:space:]]*Running / { t = $0; sub(/^[[:space:]]*Running /, "", t); sub(/ \(.*$/, "", t); print pd "\t" t >> ran; cur = t; next }
    /^test .* \.\.\. ok$/ { n = $0; sub(/^test /, "", n); sub(/ \.\.\. ok$/, "", n); print pd "\t" cur "\t" n >> ok }
    /^test result: / { print pd "\t" cur "\t" $4 >> counts }
  ' "$2"
  touch "$rd/ran.txt" "$rd/ok.txt" "$rd/counts.txt"
}

# passed_test FILE SCOPE: is the definition SCOPE in FILE a test that passed in
# this run? Prints its cargo name.
passed_test() {
  pt_pd=$(pkgdir "$1"); pt_rel=$(pkgrel "$1")
  case $pt_rel in
    tests/*)
      pt_t=$(test_target "$pt_rel")
      awk -F'\t' -v pd="$pt_pd" -v t="$pt_t" '$1 == pd && $2 == t { f = 1 } END { exit !f }' "$rd/ran.txt" || return 1
      if awk -F'\t' -v pd="$pt_pd" -v t="$pt_t" '$1 == pd && $2 == t { f = 1 } END { exit !f }' "$rd/ok.txt"; then
        awk -F'\t' -v pd="$pt_pd" -v t="$pt_t" -v n="$2" '$1 == pd && $2 == t && $3 == n { f = 1 } END { exit !f }' "$rd/ok.txt" || return 1
        echo "$pt_t::$2"
      else
        echo "$pt_t (harness = false target, ran and passed)"
      fi
      return 0 ;;
    src/*)
      pt_m=$(modpath "$1"); pt_n=$2
      [ -n "$pt_m" ] && pt_n="$pt_m::$2"
      if awk -F'\t' -v pd="$pt_pd" -v n="$pt_n" '$1 == pd && $2 ~ /^unittests / && $3 == n { f = 1 } END { exit !f }' "$rd/ok.txt"; then
        echo "$pt_n"; return 0
      fi
      # A module declared with #[path] or inline: accept one unique suffix match.
      pt_s=$(awk -F'\t' -v pd="$pt_pd" -v s="::$2" '$1 == pd && $2 ~ /^unittests / && length($3) > length(s) && substr($3, length($3) - length(s) + 1) == s { print $3 }' "$rd/ok.txt" | sort -u)
      if [ -n "$pt_s" ] && [ "$(printf '%s\n' "$pt_s" | wc -l | tr -d ' ')" = 1 ]; then echo "$pt_s"; return 0; fi
      return 1 ;;
  esac
  return 1
}

# hits_for RWROOT PREFIX NAME: cached call sites of NAME (FILE, line,
# enclosing definition, text), FILE repo-relative.
hits_for() {
  hf_f="$rd/hits-$(printf '%s' "$1" | tr '/.' '__')-$3.txt"
  if [ ! -f "$hf_f" ]; then
    ripwire "$1" --regex="(^|[^A-Za-z0-9_])${3}[[:space:]]*(::<[^>]*>)?\\(" --grep-in=any --limit=100000 --legend=compact 2>/dev/null < /dev/null > "$hf_f.xml"
    grep -q 'capped="1"' "$hf_f.xml" && echo "capped" > "$hf_f.capped"
    awk '{ gsub(/<f p="/, "\n<f p=\""); gsub(/<hit l="/, "\n<hit l=\""); print }' "$hf_f.xml" | awk -v pre="$2" '
      /^<f p="/ { f = $0; sub(/^<f p="/, "", f); sub(/".*/, "", f); next }
      /^<hit l="/ { l = $0; sub(/^<hit l="/, "", l); sub(/".*/, "", l)
        i = ""; h = $0; sub(/<!\[CDATA\[.*/, "", h)
        if (match(h, / in="[^"]*"/)) i = substr(h, RSTART + 5, RLENGTH - 6)
        t = $0; sub(/^[^>]*><!\[CDATA\[/, "", t); sub(/\]\]><\/hit>.*/, "", t)
        print pre f "\t" l "\t" i "\t" t }' > "$hf_f"
  fi
  echo "$hf_f"
}

# direct_test FILE LINE NAME RWROOT PREFIX: a passed test whose body calls NAME,
# in FILE itself or through a path naming FILE's module (mod::NAME).
direct_test() {
  dt_hits=$(hits_for "$4" "$5" "$3")
  dt_mod=$(modname "$1")
  while IFS="$tab" read -r h_f h_l h_in h_t; do
    [ -n "$h_in" ] || continue
    if [ "$h_f" != "$1" ]; then
      case $h_t in *"$dt_mod::$3"*) ;; *) continue ;; esac
    fi
    if dt_id=$(passed_test "$h_f" "$h_in"); then echo "$dt_id calls it at $h_f:$h_l"; return 0; fi
  done < "$dt_hits"
  return 1
}

# bin_spawn: a passed test in a tests/ target that runs this crate's binary.
bin_spawn() {
  bs_bin=$(sed -n 's/^name = "\(.*\)"/\1/p' Cargo.toml | head -1)
  ripwire . --grep="CARGO_BIN_EXE_$bs_bin" --grep-in=any --legend=compact 2>/dev/null < /dev/null > "$rd/bin-spawn.xml"
  awk '{ gsub(/<f p="/, "\n<f p=\""); gsub(/<hit l="/, "\n<hit l=\""); print }' "$rd/bin-spawn.xml" | awk '
    /^<f p="/ { f = $0; sub(/^<f p="/, "", f); sub(/".*/, "", f); next }
    /^<hit l="/ { l = $0; sub(/^<hit l="/, "", l); sub(/".*/, "", l); i = ""; h = $0; sub(/<!\[CDATA\[.*/, "", h)
      if (match(h, / in="[^"]*"/)) i = substr(h, RSTART + 5, RLENGTH - 6); print f "\t" l "\t" i }' |
  while IFS="$tab" read -r b_f b_l b_in; do
    case $b_f in tests/*) ;; *) continue ;; esac
    if b_id=$(passed_test "$b_f" "$b_in"); then echo "$b_id runs the binary ($b_f:$b_l)"; return 0; fi
  done
}

# reach RWROOT PREFIX FILE LINE NAME: search up the resolved callers of the
# definition at FILE:LINE for a passed test. Prints the evidence; exit 0 =
# reached, 1 = no passed test reaches it, 2 = search capped.
reach() {
  rc_q="$rd/queue"; rc_v="$rd/visited"
  printf '%s\t%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$5" "$5" > "$rc_q"
  printf '%s:%s\n' "$3" "$4" > "$rc_v"
  rc_n=0
  while [ -s "$rc_q" ]; do
    IFS="$tab" read -r q_f q_l q_name q_scope q_chain < "$rc_q"
    tail -n +2 "$rc_q" > "$rc_q.next"; mv "$rc_q.next" "$rc_q"
    rc_n=$((rc_n + 1))
    if [ "$rc_n" -gt "$search_cap" ]; then echo "search stopped after $search_cap definitions (UNTESTED_SEARCH_CAP)"; return 2; fi
    if [ "$rc_n" -gt 1 ] && rc_id=$(passed_test "$q_f" "$q_scope"); then
      echo "passed test $rc_id -> $q_chain"; return 0
    fi
    if rc_id=$(direct_test "$q_f" "$q_l" "$q_name" "$1" "$2"); then
      if [ "$rc_n" = 1 ]; then echo "$rc_id"; else echo "$rc_id; path $q_chain"; fi
      return 0
    fi
    if [ "$rc_n" = 1 ] && [ "$q_name" = main ] && [ "$q_f" = src/main.rs ] && rc_id=$(bin_spawn) && [ -n "$rc_id" ]; then
      echo "$rc_id; ripwire models no subprocess edge, and this credit covers main only"; return 0
    fi
    ripwire "$1" --callers="@${q_f#"$2"}:$q_l" --limit=100000 --legend=compact < /dev/null > "$rd/callers.xml" 2>&1 ||
      echo "  (ripwire --callers=@${q_f#"$2"}:$q_l refused: $(head -c 200 "$rd/callers.xml"))" >&2
    rows s n p via of_def < "$rd/callers.xml" > "$rd/callers.txt"
    while IFS="$tab" read -r c_n c_p c_via c_od; do
      [ "$c_via" = name ] && continue
      if [ -n "$c_od" ] && ! printf '%s\n' "$c_od" | tr ' ' '\n' | grep -qv '~n'; then continue; fi
      c_f="$2${c_p%:*}"; c_l=${c_p##*:}
      grep -qxF "$c_f:$c_l" "$rc_v" && continue
      echo "$c_f:$c_l" >> "$rc_v"
      printf '%s\t%s\t%s\t%s\t%s\n' "$c_f" "$c_l" "${c_n##*::}" "$c_n" "$c_n -> $q_chain" >> "$rc_q"
    done < "$rd/callers.txt"
  done
  echo "no passed test reaches it ($rc_n definitions searched up its resolved callers)"
  return 1
}

# is_test_def FILE START_LINE: test code by place (tests/, benches/) or by an
# attribute on the definition itself: #[test], #[x::test], #[cfg(test)]. Only
# the attribute and comment block right above START_LINE counts; the first
# other line ends it, so an attribute on an earlier item never leaks down.
is_test_def() {
  case $(pkgrel "$1") in tests/*|benches/*) return 0 ;; esac
  [ "$2" -gt 1 ] || return 1
  head -n "$(( $2 - 1 ))" "$1" 2>/dev/null | awk '
    { a[NR] = $0 }
    END {
      for (i = NR; i >= 1; i--) {
        l = a[i]
        if (l ~ /^[[:space:]]*$/ || l ~ /^[[:space:]]*\/\//) continue
        if (l ~ /^[[:space:]]*#\[/) {
          if (l ~ /#\[([A-Za-z_][A-Za-z0-9_]*::)*test(\(|\])/ || l ~ /#\[cfg\(test\)\]/) found = 1
          continue
        }
        break
      }
      exit !found
    }'
}

# untested_step LABEL RWROOT PREFIX FILES: the changed definitions of one root.
untested_step() {
  us_label=$1; us_root=$2; us_pre=$3
  us_rep="$out/untested-$us_label.txt"
  : > "$rd/defs-$us_label.txt"; : > "$rd/outside-$us_label.txt"
  printf '%s\n' "$4" | tr ',' '\n' | while read -r us_rel; do
    [ -n "$us_rel" ] || continue
    us_f="$us_pre$us_rel"
    case $us_f in *.rs) ;; *) echo "$us_f (not Rust: no definitions checked)" >> "$rd/outside-$us_label.txt"; continue ;; esac
    if grep -qxF "$us_f" "$out/untracked.txt"; then
      echo "1 $(wc -l < "$us_f" | tr -d ' ')"
    else
      git diff -U0 --no-color "$merge_base" -- "$us_f" | sed -n 's/^@@ -[0-9,]* +\([0-9][0-9]*\)\(,\([0-9][0-9]*\)\)\{0,1\} @@.*/\1 \3/p'
    fi | while read -r h_start h_count; do
      [ -n "$h_count" ] || h_count=1
      if [ "$h_count" = 0 ]; then
        # A deletion after line h_start: the definition holding both sides of it was edited.
        ripwire "$us_root" --at="$us_rel:$h_start" --legend=compact 2>/dev/null < /dev/null | rows s n t l el | tail -1 > "$rd/at-a.txt"
        ripwire "$us_root" --at="$us_rel:$((h_start + 1))" --legend=compact 2>/dev/null < /dev/null | rows s n t l el | tail -1 > "$rd/at-b.txt"
        if [ -s "$rd/at-a.txt" ] && cmp -s "$rd/at-a.txt" "$rd/at-b.txt"; then
          h_lines=$h_start
        else
          echo "$us_f: lines deleted after line $h_start, between definitions" >> "$rd/outside-$us_label.txt"; continue
        fi
      else
        h_lines=$(awk -v a="$h_start" -v n="$h_count" 'BEGIN { for (i = a; i < a + n; i++) print i }')
      fi
      skip_to=0
      for h_l in $h_lines; do
        [ "$h_l" -le "$skip_to" ] && continue
        ripwire "$us_root" --at="$us_rel:$h_l" --legend=compact 2>/dev/null < /dev/null | rows s n t l el > "$rd/at.txt"
        if [ ! -s "$rd/at.txt" ]; then echo "$us_f:$h_l" >> "$rd/outside-$us_label.txt"; continue; fi
        in_tests=0; d_n=""; d_t=""; d_l=""; d_el=""
        while IFS="$tab" read -r a_n a_t a_l a_el; do
          if [ "$a_t" = other ] && [ "$a_n" = tests ]; then in_tests=1; tests_el=$a_el; fi
          case $a_t in fn|method) d_n=$a_n; d_t=$a_t; d_l=$a_l; d_el=$a_el ;; esac
        done < "$rd/at.txt"
        if [ "$in_tests" = 1 ]; then skip_to=$tests_el; echo "test	$us_f	$d_l	${d_n:-tests}	$d_t" >> "$rd/defs-$us_label.txt"; continue; fi
        if [ -z "$d_n" ]; then
          echo "$us_f:$h_l (in $(tail -1 "$rd/at.txt" | cut -f1,2 | tr '\t' ' '), not a function)" >> "$rd/outside-$us_label.txt"; continue
        fi
        skip_to=$d_el
        if is_test_def "$us_f" "$d_l"; then kind="test"; else kind="code"; fi
        echo "$kind	$us_f	$d_l	$d_n	$d_t" >> "$rd/defs-$us_label.txt"
      done
    done
  done
  sort -u "$rd/defs-$us_label.txt" -o "$rd/defs-$us_label.txt"
  us_fail=0; us_code=0; us_tests=0
  {
    echo "untested-$us_label: functions and methods this change adds or edits, and the evidence that a passed test reaches each"
    while IFS="$tab" read -r d_kind d_f d_l d_n d_t; do
      if [ "$d_kind" = test ]; then us_tests=$((us_tests + 1)); continue; fi
      us_code=$((us_code + 1))
      if git cat-file -e "$merge_base:$d_f" 2>/dev/null && git show "$merge_base:$d_f" | grep -Eq "fn[[:space:]]+${d_n}[[:space:]]*[<(]"; then age=edited; else age=new; fi
      ack=$(awk -F'\t' -v k="$d_f:$d_n" '$1 == k { print $2; exit }' .ripwire_untested_acks 2>/dev/null)
      ev=$(reach "$us_root" "$us_pre" "$d_f" "$d_l" "$d_n"); r=$?
      if [ "$r" = 0 ]; then
        echo "  ok    $d_f:$d_l $d_n ($age $d_t): $ev"
      elif [ -n "$ack" ]; then
        echo "  ACKED $d_f:$d_l $d_n ($age $d_t): $ev; acked in .ripwire_untested_acks: $ack"
      else
        echo "  FAIL  $d_f:$d_l $d_n ($age $d_t): $ev"
        us_fail=$((us_fail + 1))
      fi
    done < "$rd/defs-$us_label.txt"
    for c in "$rd"/hits-*.capped; do [ -f "$c" ] && { echo "  FAIL  a call-site search was capped ($c); evidence may be missing"; us_fail=$((us_fail + 1)); }; done
    echo "  test code changed (needs no test of its own): $(awk -F'\t' '$1 == "test" { n++ } END { print n + 0 }' "$rd/defs-$us_label.txt") test functions or test modules"
    if [ -s "$rd/outside-$us_label.txt" ]; then
      # One FILE:a-b,c entry per file for plain line numbers; other notes as they are.
      echo "  changed lines in no function (docs, attributes, imports; nothing to test): $(awk -F: '
        function flush() { if (a != "") r = r (r == "" ? "" : ",") (a == b ? a : a "-" b); a = "" }
        NF == 2 && $2 ~ /^[0-9]+$/ {
          if ($1 == f && $2 == b + 1) { b = $2; next }
          flush()
          if ($1 != f) { if (f != "") out = out " " f ":" r; f = $1; r = "" }
          a = $2; b = $2; next }
        { other = other " " $0 }
        END { flush(); if (f != "") out = out " " f ":" r; print substr(out other, 2) }' "$rd/outside-$us_label.txt")"
    fi
    echo "  result: $us_code changed functions, $us_fail without a reaching test"
  } > "$us_rep"
  grep -q '^  result: .*, 0 without' "$us_rep"
}

# run_cargo PKGDIR LOG ARGS...: run cargo test, parse its log; exit = cargo's.
run_cargo() {
  rc_pd=$1; rc_log=$2; shift 2
  cargo test --locked --no-fail-fast "$@" < /dev/null > "$rc_log" 2>&1
  rc_rc=$?
  parse_cargo "$rc_pd" "$rc_log"
  return $rc_rc
}

# tests_step LABEL RWROOT PREFIX FILES: run --test-gate, run the suite, and
# discharge every test row it names.
tests_step() {
  ts_label=$1; ts_root=$2; ts_pre=$3; ts_files=$4
  ts_xml="$out/tests-$ts_label.xml"; ts_rep="$out/tests-$ts_label.txt"
  ripwire "$ts_root" --test-gate="$ts_files" --limit=100000 --legend=compact > "$ts_xml" 2>&1
  ts_rw=$?
  ts_fail=0
  {
    echo "tests-$ts_label: ripwire --test-gate exit $ts_rw"
    case $ts_rw in 0|4) ;; *) echo "  FAIL  ripwire refused or stopped (exit $ts_rw): $(head -c 300 "$ts_xml")"; ts_fail=1 ;; esac
    if grep -q 'tests_capped="1"\|untested_capped="1"' "$ts_xml"; then echo "  FAIL  ripwire capped the row list; raise --limit"; ts_fail=1; fi
    # The suite. The app runs it whole; gpui-kit runs each crate the change touches.
    if [ "$ts_label" = app ]; then
      run_cargo . "$out/cargo-test-app.txt"; ts_c=$?
      echo "  cargo test --locked --no-fail-fast: exit $ts_c, $(grep '^test result:' "$out/cargo-test-app.txt" | awk '{ p += $4; f += $6; i += $8 } END { print p + 0 " passed, " f + 0 " failed, " i + 0 " ignored" }') ($(grep -c '^[[:space:]]*Running ' "$out/cargo-test-app.txt") targets; log .ripwire/out/cargo-test-app.txt)"
      [ "$ts_c" = 0 ] || { echo "  FAIL  the suite failed: $(grep -E '^test .* \.\.\. FAILED$|^error' "$out/cargo-test-app.txt" | sed 's/^test //; s/ \.\.\. FAILED$//' | sort -u | paste -sd' ' -)"; ts_fail=1; }
    else
      printf '%s\n' "$ts_files" | tr ',' '\n' | while read -r k_rel; do [ -n "$k_rel" ] && pkgdir "$ts_pre$k_rel"; done | sort -u > "$rd/kit-pkgs.txt"
      while read -r k_pd; do
        k_name=$(sed -n 's/^name = "\(.*\)"/\1/p' "$k_pd/Cargo.toml" | head -1)
        k_log="$out/cargo-test-kit-$k_name.txt"
        if [ "$k_pd" = vendor/gpui-kit ] || [ -z "$k_name" ]; then echo "  FAIL  $k_pd is no crate the gate can test"; ts_fail=1; continue; fi
        run_cargo "$k_pd" "$k_log" -p "$k_name"; k_c=$?
        echo "  cargo test --locked --no-fail-fast -p $k_name: exit $k_c (log .ripwire/out/$(basename "$k_log"))"
        [ "$k_c" = 0 ] || { echo "  FAIL  $k_name tests did not pass: $(grep -m1 '^error' "$k_log")"; ts_fail=1; }
      done < "$rd/kit-pkgs.txt"
    fi
    # Every test file ripwire names, by how it ran.
    { rows t p run < "$ts_xml"; rows g p < "$ts_xml" | tr ',' '\n'; } | while IFS="$tab" read -r r_p r_run; do
      [ -n "$r_p" ] || continue
      r_f="$ts_pre$r_p"; r_pd=$(pkgdir "$r_f"); r_rel=$(pkgrel "$r_f")
      case $r_rel in
        tests/*.rs)
          r_t=$(test_target "$r_rel")
          if awk -F'\t' -v pd="$r_pd" -v t="$r_t" '$1 == pd && $2 == t { f = 1 } END { exit !f }' "$rd/ran.txt"; then
            r_n=$(awk -F'\t' -v pd="$r_pd" -v t="$r_t" '$1 == pd && $2 == t { print $3; exit }' "$rd/counts.txt")
            case $r_n in
              "") r_note="harness = false, so cargo prints no test count" ;;
              0) r_note="0 tests on this platform (cfg-gated), so it checked nothing here" ;;
              *) r_note="$r_n passed" ;;
            esac
            echo "  ran   $r_f: in cargo test (\"Running $r_t\" in the log), $r_note; it passes only with the suite above"
          else
            echo "  FAIL  $r_f: named by ripwire, but cargo never ran it"; echo x >> "$rd/rowfail-$ts_label"
          fi ;;
        *.test.ts|*.test.js|*.spec.ts|*.spec.js)
          if bun test "./$r_f" < /dev/null > "$rd/bun.txt" 2>&1; then echo "  ran   $r_f: bun test passed"
          else echo "  FAIL  $r_f: bun test failed or bun is missing: $(tail -3 "$rd/bun.txt" | tr '\n' ' ')"; echo x >> "$rd/rowfail-$ts_label"; fi ;;
        *)
          if [ -n "$r_run" ]; then
            if ( cd "$ts_root" && sh -c "$r_run" ) < /dev/null > "$rd/run.txt" 2>&1; then echo "  ran   $r_f: run=\"$r_run\" passed"
            else echo "  FAIL  $r_f: run=\"$r_run\" failed: $(tail -3 "$rd/run.txt" | tr '\n' ' ')"; echo x >> "$rd/rowfail-$ts_label"; fi
          else
            echo "  FAIL  $r_f: no runner (not a cargo test target, no run= from ripwire)"; echo x >> "$rd/rowfail-$ts_label"
          fi ;;
      esac
    done
    [ -f "$rd/rowfail-$ts_label" ] && ts_fail=1
    echo "  rows: $(grep -o 'tests="[0-9]*"' "$ts_xml" | head -1) test files named; result: $( [ "$ts_fail" = 0 ] && echo pass || echo FAIL)"
    # Ripwire's untested blast radius: callers outside the change. Report only.
    rows u sym p l ccx < "$ts_xml" | awk -F'\t' -v pre="$ts_pre" '{ print pre $2 ":" $3 "\t" $1 "\tccx=" $4 }' > "$out/untested-radius-$ts_label.txt"
    echo "  report: $(wc -l < "$out/untested-radius-$ts_label.txt" | tr -d ' ') impacted callers outside the change that no test reaches (ripwire <u> rows, pre-existing): .ripwire/out/untested-radius-$ts_label.txt"
  } > "$ts_rep"
  [ "$ts_fail" = 0 ] && ! grep -q '^  FAIL' "$ts_rep"
}

if [ -n "$app_files" ]; then
  if tests_step app . "" "$app_files"; then v=pass; else v=FAIL; fi
  verdict tests-app "$v" "see below"
  if untested_step app . "" "$app_files"; then v=pass; else v=FAIL; fi
  verdict untested-app "$v" "see below"
fi
if [ -n "$kit_files" ]; then
  if tests_step kit vendor/gpui-kit vendor/gpui-kit/ "$kit_files"; then v=pass; else v=FAIL; fi
  verdict tests-kit "$v" "see below"
  if untested_step kit vendor/gpui-kit vendor/gpui-kit/ "$kit_files"; then v=pass; else v=FAIL; fi
  verdict untested-kit "$v" "see below"
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
for f in tests-app untested-app tests-kit untested-kit; do
  [ -f "$out/$f.txt" ] && sed 's/^/  /' "$out/$f.txt"
done
echo "gate: reports:"
grep -o '<lint [^>]*>' "$out/lint.xml" | sed 's#^#  #'
grep -o '<dead-code [^>]*>' "$out/dead-code.xml" | sed 's#^#  #' | cut -c1-200
grep -o '<clones [^>]*>' "$out/clones.xml" | sed 's#^#  #' | cut -c1-200
grep -o '<doc-drift [^>]*>' "$out/doc-drift.xml" | sed 's#^#  #'
echo "gate: full output in $out/"
if [ "$failed" = 1 ]; then echo "gate: FAIL"; exit 1; fi
echo "gate: PASS"
