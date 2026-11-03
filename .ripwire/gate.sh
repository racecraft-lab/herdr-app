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
# Exit 0 = PASS, 1 = FAIL, 3 = INCOMPLETE (nothing failed, but changed code
# compiled only for another OS was not tested here).
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
#                 one of its callers, transitively. A caller counts when ripwire
#                 resolved the edge (`ripwire --callers`, minus name-only edges
#                 and prov="split" arms, which credit tests that cannot call
#                 the code), or when Rust's path rules bind the call site to it
#                 (bare call in the same module, self::, super::, mod::, or the
#                 file's module with a `pub use` re-export). `main` also counts
#                 as reached when a passed test spawns the binary
#                 (CARGO_BIN_EXE_*), which ripwire does not model; that credit
#                 is not passed on to its callees. A definition whose cfg(...)
#                 is false on this host (cfg(not(target_os = "macos")) on a Mac)
#                 cannot be compiled, so no local run can test it: it is an
#                 OTHER-OS row, neither ok nor FAIL, and the gate ends
#                 INCOMPLETE (exit 3) unless something failed.
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
incomplete=0
summary=""
record() { # name rc pass_codes
  name=$1; rc=$2; ok=0
  for c in $3; do [ "$rc" = "$c" ] && ok=1; done
  if [ "$ok" = 1 ]; then verdict=pass; else verdict=FAIL; failed=1; fi
  summary="$summary
  $name: exit $rc ($verdict)"
}
verdict() { # name pass|INCOMPLETE|FAIL detail
  case $2 in pass) ;; INCOMPLETE) incomplete=1 ;; *) failed=1 ;; esac
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
          line = line (k > 1 ? "\t" : "") (v == "" ? "-" : v)
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

# hits_for RWROOT PREFIX NAME: cached call sites and `fn NAME` lines of NAME
# (FILE, line, enclosing definition, text), FILE repo-relative.
hits_for() {
  hf_f="$rd/hits-$(printf '%s' "$1" | tr '/.' '__')-$3.txt"
  if [ ! -f "$hf_f" ]; then
    ripwire "$1" --regex="(^|[^A-Za-z0-9_])${3}[[:space:]]*(::<[^>]*>)?\\(|fn[[:space:]]+${3}([^A-Za-z0-9_]|\$)" --grep-in=any --limit=100000 --legend=compact 2>/dev/null < /dev/null > "$hf_f.xml"
    grep -q 'capped="1"' "$hf_f.xml" && echo "capped" > "$hf_f.capped"
    awk '{ gsub(/<f p="/, "\n<f p=\""); gsub(/<hit l="/, "\n<hit l=\""); print }' "$hf_f.xml" | awk -v pre="$2" '
      /^<f p="/ { f = $0; sub(/^<f p="/, "", f); sub(/".*/, "", f); next }
      /^<hit l="/ { l = $0; sub(/^<hit l="/, "", l); sub(/".*/, "", l)
        i = ""; h = $0; sub(/<!\[CDATA\[.*/, "", h)
        if (match(h, / in="[^"]*"/)) i = substr(h, RSTART + 5, RLENGTH - 6)
        t = $0; sub(/^[^>]*><!\[CDATA\[/, "", t); sub(/\]\]><\/hit>.*/, "", t)
        print pre f "\t" l "\t" (i == "" ? "-" : i) "\t" t }' > "$hf_f"
  fi
  echo "$hf_f"
}

# at_rows RWROOT PREFIX FILE LINE: cached `ripwire --at` chain at FILE:LINE,
# one "name, kind, start, end" row per enclosing definition, outermost first.
at_rows() {
  ar_k="$rd/at-$(printf '%s_%s' "$3" "$4" | tr '/.' '__').txt"
  [ -f "$ar_k" ] || ripwire "$1" --at="${3#"$2"}:$4" --legend=compact 2>/dev/null < /dev/null | rows s n t l el > "$ar_k"
  echo "$ar_k"
}
# modchain ROWS: the inline modules (kind "other") around a location, a::b.
modchain() { awk -F'\t' '$2 == "other" { c = c (c == "" ? "" : "::") $1 } END { print c }' "$1"; }

# call_form TEXT NAME: how TEXT calls NAME: def, method, bare, "path P" or none.
call_form() {
  printf '%s\n' "$1" | awk -v nm="$2" '{
    s = $0
    while ((i = index(s, nm)) > 0) {
      before = substr(s, 1, i - 1); after = substr(s, i + length(nm)); pc = substr(before, length(before), 1)
      if (pc ~ /[A-Za-z0-9_]/ || after !~ /^[[:space:]]*(::<[^>]*>)?[[:space:]]*\(/) { s = after; continue }
      if (before ~ /fn[[:space:]]+$/) { print "def"; exit }
      if (pc == ".") { print "method"; exit }
      if (before ~ /::$/) { b = before; sub(/::$/, "", b); if (match(b, /[A-Za-z0-9_]+$/)) print "path " substr(b, RSTART); else print "path"; exit }
      print "bare"; exit
    }
    print "none" }'
}

# Host facts for cfg(...): target_os, target_family, target_arch.
case $(uname -s) in Darwin) host_os=macos ;; Linux) host_os=linux ;; *) host_os=$(uname -s | tr '[:upper:]' '[:lower:]') ;; esac
host_family=unix
case $(uname -m) in arm64|aarch64) host_arch=aarch64 ;; *) host_arch=$(uname -m) ;; esac

# cfg_eval PREDICATE: 1 if it holds on this host, 0 if not, u if unknown
# (features and other keys the gate cannot read).
cfg_eval() {
  printf '%s\n' "$1" | awk -v os="$host_os" -v fam="$host_family" -v arch="$host_arch" '
    function sk() { while (p <= n && substr(s, p, 1) ~ /[ \t]/) p++ }
    function id(  st) { sk(); st = p; while (p <= n && substr(s, p, 1) ~ /[A-Za-z0-9_]/) p++; return substr(s, st, p - st) }
    function qs(  st, v) { sk(); if (substr(s, p, 1) != "\"") return "\001"; p++; st = p; while (p <= n && substr(s, p, 1) != "\"") p++; v = substr(s, st, p - st); p++; return v }
    function ev(  k, v, r, acc, sawu, c) {
      k = id(); sk(); c = substr(s, p, 1)
      if ((k == "not" || k == "all" || k == "any") && c == "(") {
        p++
        if (k == "not") { r = ev(); sk(); if (substr(s, p, 1) == ")") p++; return r == "u" ? "u" : (r == "1" ? "0" : "1") }
        acc = (k == "all") ? "1" : "0"; sawu = 0
        while (1) {
          sk(); if (p > n) return "u"
          if (substr(s, p, 1) == ")") { p++; break }
          r = ev()
          if (k == "all" && r == "0") acc = "0"
          if (k == "any" && r == "1") acc = "1"
          if (r == "u") sawu = 1
          sk(); if (substr(s, p, 1) == ",") p++; else if (substr(s, p, 1) != ")") return "u"
        }
        if (k == "all") return acc == "0" ? "0" : (sawu ? "u" : "1")
        return acc == "1" ? "1" : (sawu ? "u" : "0")
      }
      if (c == "=") {
        p++; v = qs()
        if (k == "target_os") return v == os ? "1" : "0"
        if (k == "target_family") return v == fam ? "1" : "0"
        if (k == "target_arch") return v == arch ? "1" : "0"
        return "u"
      }
      if (k == "unix") return fam == "unix" ? "1" : "0"
      if (k == "windows") return fam == "windows" ? "1" : "0"
      if (k == "test" || k == "debug_assertions") return "1"
      return "u"
    }
    { s = $0; n = length(s); p = 1; print ev() }'
}

# attr_cfgs FILE LINE: the cfg(...) predicates in the attribute block right above LINE.
attr_cfgs() {
  [ "$2" -gt 1 ] || return 0
  head -n "$(( $2 - 1 ))" "$1" 2>/dev/null | awk '
    { a[NR] = $0 }
    END {
      for (i = NR; i >= 1; i--) {
        l = a[i]
        if (l ~ /^[[:space:]]*$/ || l ~ /^[[:space:]]*\/\//) continue
        if (l ~ /^[[:space:]]*#\[/) { if (match(l, /#\[cfg\(.*\)\]/)) print substr(l, RSTART + 6, RLENGTH - 8); continue }
        break
      }
    }'
}
# file_cfgs FILE: its inner #![cfg(...)] and the cfg on each `mod NAME;` that
# declares it, up to the crate root.
file_cfgs() {
  fc_f=$1
  while :; do
    sed -n '1,40p' "$fc_f" 2>/dev/null | sed -n 's/^[[:space:]]*#!\[cfg(\(.*\))\][[:space:]]*$/\1/p'
    fc_pd=$(pkgdir "$fc_f"); fc_rel=$(pkgrel "$fc_f")
    if [ "$fc_pd" = . ]; then fc_base=""; else fc_base="$fc_pd/"; fi
    case $fc_rel in src/main.rs|src/lib.rs) return 0 ;; src/*.rs) ;; *) return 0 ;; esac
    fc_m=${fc_rel#src/}; fc_m=${fc_m%.rs}; fc_m=${fc_m%/mod}; fc_name=${fc_m##*/}
    case $fc_m in
      */*) fc_par="${fc_base}src/${fc_m%/*}"; if [ -f "$fc_par.rs" ]; then fc_par="$fc_par.rs"; else fc_par="$fc_par/mod.rs"; fi ;;
      *) fc_par="${fc_base}src/main.rs"; [ -f "$fc_par" ] || fc_par="${fc_base}src/lib.rs" ;;
    esac
    [ -f "$fc_par" ] || return 0
    fc_l=$(grep -n -E "^[[:space:]]*(pub(\([^)]*\))?[[:space:]]+)?mod[[:space:]]+${fc_name}[[:space:]]*;" "$fc_par" | head -1 | cut -d: -f1)
    [ -n "$fc_l" ] && attr_cfgs "$fc_par" "$fc_l"
    fc_f=$fc_par
  done
}
# compiled RWROOT PREFIX FILE LINE: is the definition at FILE:LINE compiled on
# this host? Prints 1, u (a cfg the gate cannot read), or "0<TAB>cfg(...)".
compiled() {
  cp_k="$rd/cfg-$(printf '%s_%s' "$3" "$4" | tr '/.' '__').txt"
  if [ ! -f "$cp_k" ]; then
    cp_at=$(at_rows "$1" "$2" "$3" "$4")
    {
      attr_cfgs "$3" "$4"
      awk -F'\t' -v l="$4" '$2 == "other" && $3 < l { print $3 }' "$cp_at" | while read -r cp_ml; do attr_cfgs "$3" "$cp_ml"; done
      file_cfgs "$3"
    } > "$rd/cfgs.txt"
    cp_res=1
    while read -r cp_p; do
      case $(cfg_eval "$cp_p") in
        0) cp_res=$(printf '0\tcfg(%s)' "$cp_p"); break ;;
        u) cp_res=u ;;
      esac
    done < "$rd/cfgs.txt"
    printf '%s\n' "$cp_res" > "$cp_k"
  fi
  cat "$cp_k"
}

# def_info RWROOT PREFIX FILE LINE NAME: "free<TAB>chain" for the definition:
# free=1 when it is a plain fn of its module (not an impl method), from the
# scoped name ripwire gives its own definition line.
def_info() {
  di_chain=$(modchain "$(at_rows "$1" "$2" "$3" "$4")")
  di_scoped=$(awk -F'\t' -v f="$3" -v l="$4" '$1 == f && $2 == l { print $3; exit }' "$(hits_for "$1" "$2" "$5")")
  if [ "$di_scoped" = "$5" ] || { [ -n "$di_chain" ] && [ "$di_scoped" = "$di_chain::$5" ]; }; then di_free=1; else di_free=0; fi
  printf '%s\t%s\n' "$di_free" "$di_chain"
}

# direct_test FILE LINE NAME RWROOT PREFIX FREE: a passed test whose body calls
# NAME, in FILE itself or through a path naming FILE's module (mod::NAME). A
# plain fn is never credited through a method call of the same name.
direct_test() {
  dt_hits=$(hits_for "$4" "$5" "$3")
  dt_mod=$(modname "$1")
  while IFS="$tab" read -r h_f h_l h_in h_t; do
    [ "$h_in" != - ] || continue
    if [ "$h_f" != "$1" ]; then
      case $h_t in *"$dt_mod::$3"*) ;; *) continue ;; esac
    fi
    case $(call_form "$h_t" "$3") in def|none) continue ;; method) [ "$6" = 1 ] && continue ;; esac
    if dt_id=$(passed_test "$h_f" "$h_in"); then echo "$dt_id calls it at $h_f:$h_l"; return 0; fi
  done < "$dt_hits"
  return 1
}

# scope_callers RWROOT PREFIX FILE LINE NAME FREE CHAIN: callers of a plain fn
# that Rust's path rules bind to it, read from its call sites. Ripwire's
# resolver leaves many of these unbound (it reads fns in an inline `mod` as
# methods). Prints "file, line, scoped name" per caller definition.
#   bare NAME(..)      same file, same module, and the caller does not bind NAME itself
#   self::NAME(..)     same file, same module
#   super::NAME(..)    same file, a module directly inside NAME's module
#   M::NAME(..)        same file, M the innermost module holding NAME
#   F::NAME(..)        any file, F the file's module, and NAME at the file's top
#                      level or re-exported there with `pub use M::{.., NAME}`
scope_callers() {
  [ "$6" = 1 ] || return 0
  sc_hits=$(hits_for "$1" "$2" "$5")
  sc_mod=$(modname "$3"); sc_last=${7##*::}
  sc_reexp=0
  if [ -n "$7" ] && grep -Eq "^[[:space:]]*pub(\([^)]*\))?[[:space:]]+use[[:space:]]+(self::)?$7::(\{([^}]*[^A-Za-z0-9_])?$5([^A-Za-z0-9_][^}]*)?\}|$5[[:space:]]*;)" "$3"; then sc_reexp=1; fi
  while IFS="$tab" read -r h_f h_l h_in h_t; do
    [ "$h_in" != - ] || continue
    [ "$h_f" = "$3" ] && [ "$h_l" = "$4" ] && continue
    sc_form=$(call_form "$h_t" "$5")
    sc_p=""; case $sc_form in "path "*) sc_p=${sc_form#path } ;; esac
    case $sc_form in
      bare|"path self"|"path super") [ "$h_f" = "$3" ] || continue ;;
      "path "*)
        if [ "$sc_p" = "$sc_last" ] && [ -n "$7" ] && [ "$h_f" = "$3" ]; then :
        elif [ "$sc_p" = "$sc_mod" ] && { [ -z "$7" ] || [ "$sc_reexp" = 1 ]; }; then :
        else continue; fi ;;
      *) continue ;;
    esac
    sc_at=$(at_rows "$1" "$2" "$h_f" "$h_l")
    sc_cc=$(modchain "$sc_at")
    sc_def=$(awk -F'\t' '$2 == "fn" || $2 == "method" { d = $1 "\t" $3 "\t" $4 } END { print d }' "$sc_at")
    [ -n "$sc_def" ] || continue
    sc_cl=$(printf '%s\n' "$sc_def" | cut -f2); sc_cel=$(printf '%s\n' "$sc_def" | cut -f3)
    case $sc_form in
      bare)
        [ "$sc_cc" = "$7" ] || continue
        sed -n "${sc_cl},${sc_cel}p" "$h_f" | grep -Eq "(let|let[[:space:]]+mut|fn)[[:space:]]+$5([^A-Za-z0-9_]|$)" && continue ;;
      "path self") [ "$sc_cc" = "$7" ] || continue ;;
      "path super")
        case $sc_cc in *::*) sc_parent=${sc_cc%::*} ;; ?*) sc_parent="" ;; *) continue ;; esac
        [ "$sc_parent" = "$7" ] || continue ;;
    esac
    printf '%s\t%s\t%s\n' "$h_f" "$sc_cl" "$h_in"
  done < "$sc_hits"
}

# bin_spawn: a passed test in a tests/ target that runs this crate's binary.
bin_spawn() {
  bs_bin=$(sed -n 's/^name = "\(.*\)"/\1/p' Cargo.toml | head -1)
  ripwire . --grep="CARGO_BIN_EXE_$bs_bin" --grep-in=any --legend=compact 2>/dev/null < /dev/null > "$rd/bin-spawn.xml"
  awk '{ gsub(/<f p="/, "\n<f p=\""); gsub(/<hit l="/, "\n<hit l=\""); print }' "$rd/bin-spawn.xml" | awk '
    /^<f p="/ { f = $0; sub(/^<f p="/, "", f); sub(/".*/, "", f); next }
    /^<hit l="/ { l = $0; sub(/^<hit l="/, "", l); sub(/".*/, "", l); i = ""; h = $0; sub(/<!\[CDATA\[.*/, "", h)
      if (match(h, / in="[^"]*"/)) i = substr(h, RSTART + 5, RLENGTH - 6); print f "\t" l "\t" (i == "" ? "-" : i) }' |
  while IFS="$tab" read -r b_f b_l b_in; do
    case $b_f in tests/*) ;; *) continue ;; esac
    if b_id=$(passed_test "$b_f" "$b_in"); then echo "$b_id runs the binary ($b_f:$b_l)"; return 0; fi
  done
}

# reach RWROOT PREFIX FILE LINE NAME: search up the callers of the definition
# at FILE:LINE for a passed test. A caller counts when ripwire resolved the
# edge (not by name alone, not one arm of a split between same-named
# definitions), or when Rust's path rules bind its call (scope_callers). A
# caller compiled out on this host is skipped. Prints the evidence; exit 0 =
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
    q_info=$(def_info "$1" "$2" "$q_f" "$q_l" "$q_name"); q_free=${q_info%%"$tab"*}; q_mc=${q_info#*"$tab"}
    if rc_id=$(direct_test "$q_f" "$q_l" "$q_name" "$1" "$2" "$q_free"); then
      if [ "$rc_n" = 1 ]; then echo "$rc_id"; else echo "$rc_id; path $q_chain"; fi
      return 0
    fi
    if [ "$rc_n" = 1 ] && [ "$q_name" = main ] && [ "$q_f" = src/main.rs ] && rc_id=$(bin_spawn) && [ -n "$rc_id" ]; then
      echo "$rc_id; ripwire models no subprocess edge, and this credit covers main only"; return 0
    fi
    ripwire "$1" --callers="@${q_f#"$2"}:$q_l" --limit=100000 --legend=compact < /dev/null > "$rd/callers.xml" 2>&1 ||
      echo "  (ripwire --callers=@${q_f#"$2"}:$q_l refused: $(head -c 200 "$rd/callers.xml"))" >&2
    rows s n p via prov of_def < "$rd/callers.xml" | while IFS="$tab" read -r c_n c_p c_via c_prov c_od; do
      [ "$c_via" = name ] && continue
      [ "$c_prov" = split ] && continue
      if [ "$c_od" != - ] && ! printf '%s\n' "$c_od" | tr ' ' '\n' | grep -qv '~[ns]'; then continue; fi
      printf '%s%s\t%s\t%s\n' "$2" "${c_p%:*}" "${c_p##*:}" "$c_n"
    done > "$rd/callers.txt"
    scope_callers "$1" "$2" "$q_f" "$q_l" "$q_name" "$q_free" "$q_mc" >> "$rd/callers.txt"
    while IFS="$tab" read -r c_f c_l c_n; do
      grep -qxF "$c_f:$c_l" "$rc_v" && continue
      echo "$c_f:$c_l" >> "$rc_v"
      case $(compiled "$1" "$2" "$c_f" "$c_l") in 0*) continue ;; esac
      printf '%s\t%s\t%s\t%s\t%s\n' "$c_f" "$c_l" "${c_n##*::}" "$c_n" "$c_n -> $q_chain" >> "$rc_q"
    done < "$rd/callers.txt"
  done
  echo "no passed test reaches it ($rc_n definitions searched up its callers)"
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
        if [ "$in_tests" = 1 ]; then skip_to=$tests_el; echo "test	$us_f	${d_l:--}	${d_n:-tests}	${d_t:--}" >> "$rd/defs-$us_label.txt"; continue; fi
        if [ -z "$d_n" ]; then
          if [ "$(tail -1 "$rd/at.txt" | cut -f2)" = other ]; then echo "$us_f:$h_l" >> "$rd/outside-$us_label.txt"
          else echo "$us_f:$h_l (in $(tail -1 "$rd/at.txt" | cut -f1,2 | tr '\t' ' '), not a function)" >> "$rd/outside-$us_label.txt"; fi
          continue
        fi
        skip_to=$d_el
        if is_test_def "$us_f" "$d_l"; then kind="test"; else kind="code"; fi
        echo "$kind	$us_f	$d_l	$d_n	$d_t" >> "$rd/defs-$us_label.txt"
      done
    done
  done
  sort -u "$rd/defs-$us_label.txt" -o "$rd/defs-$us_label.txt"
  us_fail=0; us_code=0; us_tests=0; us_other=0
  {
    echo "untested-$us_label: functions and methods this change adds or edits, and the evidence that a passed test reaches each"
    while IFS="$tab" read -r d_kind d_f d_l d_n d_t; do
      if [ "$d_kind" = test ]; then us_tests=$((us_tests + 1)); continue; fi
      us_code=$((us_code + 1))
      if git cat-file -e "$merge_base:$d_f" 2>/dev/null && git show "$merge_base:$d_f" | grep -Eq "fn[[:space:]]+${d_n}[[:space:]]*[<(]"; then age=edited; else age=new; fi
      d_info=$(def_info "$us_root" "$us_pre" "$d_f" "$d_l" "$d_n")
      [ "${d_info%%"$tab"*}" = 1 ] && d_t=fn
      ack=$(awk -F'\t' -v k="$d_f:$d_n" '$1 == k { print $2; exit }' .ripwire_untested_acks 2>/dev/null)
      d_cfg=$(compiled "$us_root" "$us_pre" "$d_f" "$d_l")
      case $d_cfg in
        0*)
          # Compiled out here: no local test run can reach it, so it is neither ok nor a failure.
          ev="not compiled on $host_os, ${d_cfg#*"$tab"}; no test run on this host can reach it: run the gate where that cfg holds"
          if [ -n "$ack" ]; then echo "  ACKED $d_f:$d_l $d_n ($age $d_t): $ev; acked in .ripwire_untested_acks: $ack"
          else echo "  OTHER-OS $d_f:$d_l $d_n ($age $d_t): $ev"; us_other=$((us_other + 1)); fi
          continue ;;
      esac
      ev=$(reach "$us_root" "$us_pre" "$d_f" "$d_l" "$d_n"); r=$?
      [ "$d_cfg" = u ] && ev="$ev (a cfg here could not be evaluated; treated as compiled)"
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
    echo "  result: $us_code changed functions, $us_fail without a reaching test, $us_other compiled only for another OS (OTHER-OS)"
  } > "$us_rep"
  [ "$us_fail" = 0 ] || return 1
  [ "$us_other" = 0 ] || return 3
  return 0
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
          if [ "${r_run:--}" != - ]; then
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
  untested_step app . "" "$app_files"
  case $? in 0) v=pass ;; 3) v=INCOMPLETE ;; *) v=FAIL ;; esac
  verdict untested-app "$v" "see below"
fi
if [ -n "$kit_files" ]; then
  if tests_step kit vendor/gpui-kit vendor/gpui-kit/ "$kit_files"; then v=pass; else v=FAIL; fi
  verdict tests-kit "$v" "see below"
  untested_step kit vendor/gpui-kit vendor/gpui-kit/ "$kit_files"
  case $? in 0) v=pass ;; 3) v=INCOMPLETE ;; *) v=FAIL ;; esac
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
if [ "$incomplete" = 1 ]; then
  echo "gate: INCOMPLETE: every check that can run on $host_os passed, but changed code compiled only for another OS (OTHER-OS rows) was not tested; run the gate there, or ack it"
  exit 3
fi
echo "gate: PASS"
