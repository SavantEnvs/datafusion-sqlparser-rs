#!/usr/bin/env bash
#
# mayhem/build.sh — build datafusion-sqlparser-rs's cargo-fuzz targets as
# sanitized libFuzzer binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via
# RUSTFLAGS), plus the KAT probe used by mayhem/test.sh.
#
# Targets produced (one Mayhemfile each):
#   /mayhem/fuzz_parse_sql_generic    — Parser::parse_sql under GenericDialect
#   /mayhem/kat                       — dynamically-linked known-answer probe (mayhem/test.sh)
#
# Upstream ships its OWN fuzz target (fuzz/fuzz_targets/fuzz_parse_sql.rs), but
# it is a HONGGFUZZ harness (honggfuzz::fuzz!), not a cargo-fuzz/libfuzzer-sys
# one — it cannot be built by `cargo fuzz build`. So we ported its API surface
# (the same Parser::parse_sql-over-dialects call) into an ADDITIVE mayhem/fuzz/
# crate with libfuzzer-sys, split across per-dialect targets (see the header
# comments in mayhem/fuzz/fuzz_targets/*.rs), and left upstream's fuzz/ untouched.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# DWARF gate (SPEC §6.2 item 10): rustc's own CUs land at DWARF4 and the ASan
# runtime archive at DWARF5; the gate reads only the FIRST .debug_info CU. The
# Dockerfile precompiles a tiny DWARF3 anchor object
# (/opt/toolchains/rust/dwarf3/anchor.o) and a cc-wrapper that PREPENDS it ahead
# of every other link input — empirically, prepend (not append) is required for
# its CU to land at .debug_info offset 0. $RUST_DEBUG_FLAGS wires that wrapper in
# via `-Clinker`, threaded through RUSTFLAGS on every cargo-fuzz build.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so we do NOT hard-code
#     `--offline` here (it would break this first, online build).
#   - Re-running on an already-built tree must also succeed (idempotent: every
#     step below is safe to repeat — `cp -f`, `cargo fuzz build` overwrites).
#   - Build-time budget: see the "Build-time budget" block below (#1097).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# $SANITIZER_FLAGS is the base image's CLANG-oriented ASan/UBSan contract
# (SPEC §6.1/§6.2 item 8); rustc ignores it and gets its OWN sanitizer flag via
# RUSTFLAGS `-Zsanitizer=address` below (the OSS-Fuzz Rust path). We still
# reference it here, informationally, so a future C shim added to this build
# (e.g. a cc-linked helper) picks up the same halt-on-UB contract as the rest
# of the fleet instead of silently reinventing it.
echo "SANITIZER_FLAGS (clang contract; informational for Rust — see RUSTFLAGS below)=${SANITIZER_FLAGS:-}"

cd "$SRC"

# DWARF<4 anchor (see header). RUST_DEBUG_FLAGS is the SPEC §6.2 item 10 knob —
# EDIT only if the anchor prefix moves; do not drop -Clinker or the gate regresses.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Clinker=/opt/toolchains/rust/dwarf3/cc-wrapper.sh}"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we
# pin it explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids
# ASan backtraces.
#
# -Ccodegen-units=16 (#1097): cargo-fuzz puts `-C codegen-units=1` in front of
# our RUSTFLAGS for release builds, which turns the sqlparser crate (~100k lines)
# into ONE single-threaded LLVM job — the whole critical path of a graded patch
# rebuild. rustc honours the LAST -Ccodegen-units, so this restores rustc's own
# release default (16). It only changes how LLVM partitions the work: the
# sanitizer (-Zsanitizer=address), the sancov instrumentation cargo-fuzz adds,
# opt-level, debug-assertions/overflow-checks and debuginfo are all unchanged.
# A FIXED 16 (not $MAYHEM_JOBS) so the binary does not vary with the machine.
# Measured cost/benefit (16 vCPU, 1-line src/parser patch, warm target/): the
# graded rebuild drops ~300-340 s -> ~210-230 s; the price is ~1.4x fewer exec/s
# (less cross-unit inlining), so do not compare edge/exec counts across this change.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cforce-frame-pointers -Ccodegen-units=16 $RUST_DEBUG_FLAGS"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# ── Build-time budget (rlenv-slow-build #1097) ────────────────────────────────
# rlenv re-runs THIS script on every graded patch inside a fixed 450 s build
# window (cargo repos keep target/, so deps are warm; the sqlparser crate itself
# is rebuilt for every patch that touches src/). The fuzz flavour of sqlparser is
# the long pole: cargo-fuzz forces `-C codegen-units=1` in release mode, so that
# one rustc ran on ONE core for 4-6 min; RUSTFLAGS above re-splits it into 16
# codegen units (same instrumentation and opt-level). Two scheduling changes use
# the other cores without changing any binary's flags:
#   1. the KAT probe (a separate, NON-sanitized build of the same patched sources)
#      is built CONCURRENTLY, in the background, instead of serially afterwards;
#   2. all fuzz targets are built by ONE `cargo fuzz build` (no target arg = every
#      [[bin]] in mayhem/fuzz/Cargo.toml), so sqlparser is compiled once and the
#      four harness crates compile/link in parallel instead of one after another.
# Every binary is still compiled from the patched tree on every run (cargo's own
# fingerprinting decides what is stale; nothing is cached outside target/).

# ── The KAT probe used by mayhem/test.sh (NORMAL flags — it is a functional
#    oracle, not a triage artifact, so no sanitizer/fuzz instrumentation and no
#    DWARF3 anchor here; RUSTFLAGS is unset for it). Built with cargo's default
#    `dev` profile: the oracle only parses three fixed statements, so -O buys it
#    nothing, while the dev profile compiles the crate in parallel codegen units
#    and keeps overflow checks + debug_assert! ON (stricter than --release). A
#    plain `cargo build` on the gnu target is already dynamically linked (unlike
#    Go, Rust needs no cgo-style trick for this) — we still assert it below so a
#    future static-link change (e.g. a musl target) can't silently weaken the
#    oracle. ───────────────────────────────────────────────────────────────────
echo "=== building /mayhem/kat (KAT probe, background, dev profile) ==="
KAT_LOG="$(mktemp -t mayhem-kat-build.XXXXXX)"
( cd mayhem/kat && exec env -u RUSTFLAGS cargo build ) >"$KAT_LOG" 2>&1 &
KAT_PID=$!
# Don't leave the background build running if the fuzz build below fails.
trap 'kill "$KAT_PID" 2>/dev/null || true' EXIT

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS, DWARF3 anchor) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it via rustup's
# `--default-toolchain`). A `+toolchain` override would make rustup try to
# install another channel into the locked /opt/toolchains/rust.
# No target argument: cargo-fuzz builds every [[bin]] of the fuzz crate, with
# exactly the flags a per-target `cargo fuzz build ... <target>` would use.
cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp -f "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Per-target dictionaries — copy into the FLAT /mayhem root, where each
#    Mayhemfile's `dict:` cmd entry points (SPEC item 5 / seed-corpus.md: a
#    referenced-but-absent dict makes libFuzzer exit 1 at 0 edges). ──────────
for t in "${FUZZ_TARGETS[@]}"; do
  d="mayhem/$t-mined-aa714e3/$t.dict"
  if [ -f "$d" ]; then
    cp -f "$d" "/mayhem/$t.dict"
    echo "copied dictionary /mayhem/$t.dict"
  fi
done

echo "=== waiting for /mayhem/kat (KAT probe) ==="
kat_rc=0; wait "$KAT_PID" || kat_rc=$?
trap - EXIT
cat "$KAT_LOG"; rm -f "$KAT_LOG"
[ "$kat_rc" -eq 0 ] || { echo "ERROR: KAT probe build failed (cargo exit $kat_rc)" >&2; exit 1; }
cp -f mayhem/kat/target/debug/kat /mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

echo "build.sh complete:"
ls -la /mayhem/fuzz_parse_sql_generic /mayhem/kat
