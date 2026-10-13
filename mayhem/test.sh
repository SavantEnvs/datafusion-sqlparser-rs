#!/usr/bin/env bash
#
# datafusion-sqlparser-rs/mayhem/test.sh — RUN the project's own Rust test
# suite and a known-answer probe, and emit a CTRF summary. exit 0 iff nothing
# failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `cargo test` — upstream's suite (tests/sqlparser_*.rs, ~1500+ #[test]s) is
#     a genuine known-answer suite: it feeds real SQL text and asserts the exact
#     parsed AST / re-rendered SQL, not just "didn't panic". So it asserts
#     BEHAVIOUR, not "exits 0".
#
#  2) The KAT probe /mayhem/kat — `cargo test` links its test binaries the same
#     way a normal `cargo build` does on this (gnu) target: DYNAMICALLY linked,
#     UNLIKE Go's `go test`/statically-linked binaries. In principle the sabotage
#     shim's LD_PRELOAD constructor would also fire inside a cargo-test binary —
#     but that binary's own libtest harness runs every #[test] IN-PROCESS from a
#     single entrypoint, so an early process-wide _exit(0) just looks like "the
#     test binary produced no output", which is indistinguishable from a build
#     failure and easy to reward-hack around (e.g. by "fixing" a crash so the
#     process exits 0 some other way). The spec treats `cargo test` alone as
#     equivalent to the `go test`/`cargo test` trap for exactly this reason: it's
#     one big harness process, not a small, unconditional, VALUE-asserting probe.
#     /mayhem/kat is a tiny, separate, dynamically-linked binary whose entire job
#     is to parse three fixed SQL statements and print exact values; when
#     neutered it prints nothing and the exact-string assertions below fail. A
#     patch that stubs the parser to dodge a crash cannot reproduce these values
#     either, so this is a real value-asserting, sabotage-detecting oracle.
#
# This script only RUNS things — mayhem/build.sh already built the fuzz targets,
# pre-built the test suite, and built /mayhem/kat.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/rust/cargo/bin:$PATH"
export CARGO_HOME="${CARGO_HOME:-/opt/toolchains/rust/cargo}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own cargo test suite (host toolchain, NORMAL flags) ────────
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 2
fi

echo "=== running: cargo test (workspace default features) ==="
TESTLOG="$SRC/mayhem-build/cargo-test.log"
mkdir -p "$SRC/mayhem-build"
env -u RUSTFLAGS cargo test --no-fail-fast -- -Z unstable-options --format json --report-time \
  > "$TESTLOG" 2>"$SRC/mayhem-build/cargo-test.err"
rc=$?
if [ "$rc" -ne 0 ] && ! grep -qE '"type": *"test"' "$TESTLOG" 2>/dev/null; then
  # Nightly's libtest --format json needs -Z unstable-options even on a nightly
  # toolchain when invoked via `cargo test` (not `cargo +nightly test`); if that
  # combination isn't accepted here, fall back to the normal human-readable
  # runner and parse its summary line instead of per-test JSON.
  echo "cargo test --format json unavailable, falling back to plain cargo test" >&2
  env -u RUSTFLAGS cargo test --no-fail-fast \
    > "$TESTLOG" 2>"$SRC/mayhem-build/cargo-test.err"
  rc=$?
fi
tail -40 "$TESTLOG" || true
[ -s "$SRC/mayhem-build/cargo-test.err" ] && { echo "--- stderr (tail) ---"; tail -20 "$SRC/mayhem-build/cargo-test.err"; }

if grep -qE '"type": *"test"' "$TESTLOG" 2>/dev/null; then
  PASSED=$(grep -cE '"type": *"test".*"event": *"ok"' "$TESTLOG" 2>/dev/null || true)
  FAILED=$(grep -cE '"type": *"test".*"event": *"failed"' "$TESTLOG" 2>/dev/null || true)
  SKIPPED=$(grep -cE '"type": *"test".*"event": *"ignored"' "$TESTLOG" 2>/dev/null || true)
else
  # Plain-text libtest summary lines: "test result: ok. 1234 passed; 0 failed; 3 ignored; ..."
  PASSED=$(grep -oE '[0-9]+ passed'  "$TESTLOG" | awk '{s+=$1} END{print s+0}')
  FAILED=$(grep -oE '[0-9]+ failed'  "$TESTLOG" | awk '{s+=$1} END{print s+0}')
  SKIPPED=$(grep -oE '[0-9]+ ignored' "$TESTLOG" | awk '{s+=$1} END{print s+0}')
fi
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test results parsed — the suite did not run (cargo exit $rc)" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 1
fi
# A non-zero cargo exit with zero counted failures means a build/harness error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A
# `[ -f ... ]` guard here is how a probe silently stops running and the oracle
# quietly degrades to the cargo-test-only (weaker) case.
echo "=== KAT probe: /mayhem/kat (parses fixed SQL; asserts parsed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

# Expected values — computed directly against this build (see mayhem/kat/main.rs):
#   SELECT a, b, c FROM t WHERE a > 1        -> 3 projection items
#   CREATE TABLE orders (id INT, name TEXT, total DOUBLE) -> table name "orders"
#   select   1+2   as   x   from    dual     -> normalized "SELECT 1 + 2 AS x FROM dual"
kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or parser broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "SELECT projection count"       'KAT_PROJECTION_COUNT=3'
kat_expect "CREATE TABLE name"             'KAT_TABLE_NAME=orders'
kat_expect "round-trip normalization"      'KAT_ROUNDTRIP=SELECT 1 + 2 AS x FROM dual'

emit_ctrf "cargo-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
