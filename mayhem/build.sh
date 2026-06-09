#!/usr/bin/env bash
#
# mayhem/build.sh — build iproute2's Mayhem targets AND the functional-test binary:
#   * fuzz_get_rate        libFuzzer harness over get_rate() (lib/utils_math.c -> lib/libutil.a)
#   * fuzz_get_rate-standalone   non-fuzzer run-once reproducer for the same harness
#   * ip                   the `ip` CLI, fuzzed as a file-input target (`ip -batch @@`)
#   * ss                   the `ss` CLI, built with the project's NORMAL flags (NOT the fuzz
#                          sanitizer flags) and stashed at /mayhem/ss for mayhem/test.sh to RUN.
#                          test.sh runs testsuite/tests/ss/ssfilter.t against it — a real behavior
#                          oracle (ss reads a shipped socket capture via $TCPDIAG_FILE, no root/netns).
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract: CC, CXX, LIB_FUZZING_ENGINE,
# SANITIZER_FLAGS (ASan+UBSan, halting), STANDALONE_FUZZ_MAIN, SRC=/mayhem.
#
# iproute2 specifics: it has a hand-written ./configure (NOT autoconf) + recursive make. CC and the
# build flags are taken from make command-line overrides — CC defaults to gcc, and CFLAGS is appended
# (`CFLAGS := ... $(CFLAGS)`) so a passed CFLAGS adds onto the project's own warnings/opt flags. The
# whole project is built with $SANITIZER_FLAGS (CFLAGS + LDFLAGS) so the FUZZED code — get_rate and
# everything the `ip` binary touches — is instrumented, not just the harness. The C++ harness links
# the sanitized lib/libutil.a directly (as the original integration did).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENVIRONMENT (overridable), with sane defaults. SANITIZER_FLAGS uses `=`
# (not `:=`) so an explicit EMPTY value (--build-arg SANITIZER_FLAGS=) is honored and builds with
# NO sanitizers (program's natural crash). The rest default on empty too.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"

export DEBUG_FLAGS

cd "$SRC"

# 1) Build the whole project with clang + sanitizers so get_rate (in libutil.a) and the `ip`
#    binary are instrumented. Inject the sanitizers via CCOPTS, NOT CFLAGS: the Makefile builds
#    its CFLAGS as `CFLAGS := $(WFLAGS) $(CCOPTS) -I../include ... $(CFLAGS)`, and a make command-line
#    `CFLAGS=` override would REPLACE that whole line (command-line beats `:=`), dropping the -I
#    include paths. CCOPTS (default `-O2 -pipe`) is the project's own knob for compile flags and is
#    folded into CFLAGS, so overriding it keeps the includes. LDFLAGS carries the sanitizer runtime
#    into the linked `ip` binary.
make distclean >/dev/null 2>&1 || true
./configure
# netem/ builds host helper tools (maketable, pareto, ...) and RUNS them at build time to
# generate .dist data tables. Those tools are ASan-instrumented too and leak on exit (benign,
# in throwaway codegen helpers), which LeakSanitizer would turn into a build-failing abort.
# Disable leak detection for the build so it doesn't false-fail; the fuzz targets themselves are
# still fully ASan/UBSan-instrumented.
ASAN_OPTIONS=detect_leaks=0 make -j"$MAYHEM_JOBS" \
    CC="$CC" \
    CCOPTS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

# The `ip` file-input target (`ip -batch @@`). Copy the built binary to a distinct path —
# /mayhem/ip is already the source subdirectory, so the target is /mayhem/ip_bin (matched in
# mayhem/Mayhemfile_ip).
cp ip/ip /mayhem/ip_bin

# 2) libFuzzer harness over get_rate(). Links the sanitized lib/libutil.a (built above).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/fuzz_get_rate.cpp" \
    "$SRC/lib/libutil.a" \
    -o /mayhem/fuzz_get_rate

# 3) Standalone (non-fuzzer) reproducer: run-once driver that reads one input file and calls
#    LLVMFuzzerTestOneInput once, then crashes naturally (no libFuzzer runtime). The harness is C++,
#    so compile the C driver as a C object FIRST (keeps its LLVMFuzzerTestOneInput ref in C linkage),
#    then link with clang++.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
    "$SRC/mayhem/fuzz_get_rate.cpp" /tmp/standalone_main.o \
    "$SRC/lib/libutil.a" \
    -o /mayhem/fuzz_get_rate-standalone

# 4) Functional-test binary: build `ss` (misc/ss) with the project's NORMAL flags — a clean,
#    independent build, NOT the fuzz sanitizer flags — consistent with "test suite built with
#    normal flags" so mayhem/test.sh stays an honest PATCH oracle (test.sh only RUNS it).
#    `ss` is what testsuite/tests/ss/ssfilter.t exercises: it sets $TCPDIAG_FILE to the shipped
#    capture (testsuite/tests/ss/ss1.dump) so `ss` reads socket info from a file instead of the live
#    kernel — runs with no root, no netns, no kernel modules. We distclean first to drop the
#    sanitized objects, reconfigure, and build the whole project so misc/ depends resolve, then stash
#    the result at /mayhem/ss. (A patched-source rebuild during PATCH grading reuses this same path.)
make distclean >/dev/null 2>&1 || true
./configure
make -j"$MAYHEM_JOBS" CC="$CC"
cp misc/ss /mayhem/ss

echo "build.sh: built /mayhem/{ip_bin,fuzz_get_rate,fuzz_get_rate-standalone,ss}"
