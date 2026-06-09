#!/usr/bin/env bash
#
# mayhem/test.sh — RUN iproute2's OWN functional suite (already built by mayhem/build.sh). exit 0 = pass.
# PATCH-grade oracle: after an agent patches the source, the grader rebuilds (build.sh) then runs this.
#
# THE ONE PRIVILEGE-FREE TEST: testsuite/tests/ss/ssfilter.t.
#   iproute2's testsuite/ ships 18 tests, but bridge/ip/tc all create dummy interfaces + qdiscs/filters
#   via `ip link add type dummy`, `tc qdisc add`, `ip link add type bridge`, ... and assert on `show`
#   output — they need CAP_NET_ADMIN + a network namespace (the suite Makefile prefixes them with
#   `sudo -E unshare -n`) + kernel modules, which our non-root image and a default `docker run` grader
#   do NOT have. ssfilter.t is the lone exception: it sets $TCPDIAG_FILE to a shipped socket capture
#   (testsuite/tests/ss/ss1.dump), so the `ss` binary parses socket info from that file instead of the
#   live kernel — NO root, NO netns, NO modules. It runs 12 filter-expression queries (e.g.
#   `src 10.0.0.1 and ( sport = 22 and dport = 50312 )`) and, via the lib/generic.sh `test_on` helper,
#   greps `ss`'s output for the expected connection line, printing [SUCCESS]/[FAILED] per assertion.
#   This asserts BEHAVIOR/OUTPUT (a no-op/broken `ss` that prints nothing fails every assertion), so a
#   PATCH that "fixes" a bug by making the program emit nothing or exit(0) FAILS this oracle.
#
# This script only RUNS the pre-built /mayhem/ss (built by build.sh with the project's NORMAL flags);
# it never compiles. If /mayhem/ss is missing, that's a build.sh bug — fail loudly.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

TOOL="iproute2-ssfilter"

# The test runner must already exist (build.sh produced it). Do NOT build here.
if [ ! -x "$SRC/ss" ]; then
  echo "test.sh: /mayhem/ss is missing — mayhem/build.sh did not produce the ss binary" >&2
  emit_ctrf "$TOOL" 0 1
  exit $?
fi

# ssfilter.t sources `. lib/generic.sh` and reads `$(dirname $0)/ss1.dump`, both relative — run from
# the testsuite dir so they resolve. The lib/generic.sh `__ts_cmd` helper expects: SS (the binary),
# STD_OUT/STD_ERR (per-command capture files it writes), and ERRF (failure log).
cd "$SRC/testsuite"
export SS="$SRC/ss"
STD_OUT=$(mktemp) STD_ERR=$(mktemp) ERRF=$(mktemp)
export STD_OUT STD_ERR ERRF
trap 'rm -f "$STD_OUT" "$STD_ERR" "$ERRF"' EXIT

out=$(sh tests/ss/ssfilter.t 2>&1)
echo "$out"

passed=$(printf '%s\n' "$out" | grep -c '\[SUCCESS\]')
failed=$(printf '%s\n' "$out" | grep -c '\[FAILED\]')

# Guard: if neither marker appeared, the harness never ran a single assertion (e.g. ss aborted before
# producing output, or the test framework changed). Treat that as a hard failure, not a silent pass.
if [ $(( passed + failed )) -eq 0 ]; then
  echo "test.sh: ssfilter.t produced no [SUCCESS]/[FAILED] markers — the suite did not run" >&2
  emit_ctrf "$TOOL" 0 1
  exit $?
fi

emit_ctrf "$TOOL" "$passed" "$failed"
exit $?
