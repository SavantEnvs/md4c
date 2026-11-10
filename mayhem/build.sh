#!/usr/bin/env bash
# mayhem/build.sh — builds the sanitized fuzz harness (+ standalone reproducer) and the normal-flags md2html test binary.
# Runs in the commit image as `mayhem` in /mayhem; offline-safe and re-runnable (cmake/make only, no fetches).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Sanitized + instrumented project libs (md4c, md4c-html) in build/fuzz. `build/` is gitignored upstream,
#    so `git clean -ffdX` removes it. -fsanitize=fuzzer-no-link puts SanCov on the library itself (not only the
#    harness TU), which Mayhem needs to record edges.
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S . -B build/fuzz -DCMAKE_C_COMPILER="$CC" -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_HTML_LIBRARY=ON -DBUILD_MD2HTML_EXECUTABLE=OFF -DCMAKE_C_FLAGS="$FUZZ_CFLAGS"
cmake --build build/fuzz -j"$MAYHEM_JOBS"

# 2) Harness (upstream's OSS-Fuzz harness, in tree): libFuzzer binary + non-fuzzer standalone reproducer.
#    LeakSanitizer is turned off at build time via lsan_off.cc (SPEC 6.2 item 15).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/fuzz/lsan_off.o
HARNESS="$SRC/test/fuzzers/fuzz-mdhtml.c"
LIBS="build/fuzz/src/libmd4c-html.a build/fuzz/src/libmd4c.a"
$CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$HARNESS" -I"$SRC/src" $LIBS \
    build/fuzz/lsan_off.o -o /mayhem/fuzz-mdhtml
$CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" "$HARNESS" -I"$SRC/src" $LIBS \
    build/fuzz/lsan_off.o -o /mayhem/fuzz-mdhtml-standalone

# 3) Upstream test suite: md2html built with the project's NORMAL flags (no sanitizer, no -gdwarf-3),
#    in build/tests. mayhem/test.sh only runs it.
cmake -S . -B build/tests -DCMAKE_C_COMPILER="$CC" -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_HTML_LIBRARY=ON -DBUILD_MD2HTML_EXECUTABLE=ON -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"
cmake --build build/tests -j"$MAYHEM_JOBS"
