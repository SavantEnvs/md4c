#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS md4c's own test suite against the md2html built by mayhem/build.sh (build/tests).
# Asserts output: every CommonMark/extension spec example (markdown -> expected HTML), the md2html
# command-line tests and the pathological-input regexes, plus direct known-answer probes from bash.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"
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

PROG="$SRC/build/tests/md2html/md2html"
[ -x "$PROG" ] || { echo "md2html missing: $PROG (mayhem/build.sh must build it)" >&2; emit_ctrf md4c-testsuite 0 1 0; exit 1; }

passed=0; failed=0

# Direct known-answer probes (bash compares the output, so a neutered md2html cannot hide).
kat() {
  local desc="$1" opts="$2" input="$3" expected="$4" actual
  # shellcheck disable=SC2086
  actual="$(printf '%b' "$input" | "$PROG" $opts 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then passed=$((passed+1)); else
    failed=$((failed+1)); echo "KAT FAIL: $desc: got [$actual], want [$expected]" >&2; fi
}
kat heading     ""                 '# Hello\n'                 '<h1>Hello</h1>'
kat emphasis    ""                 '*a* **b**\n'               '<p><em>a</em> <strong>b</strong></p>'
kat code-block  ""                 '```c\nint x;\n```\n'       $'<pre><code class="language-c">int x;\n</code></pre>'
kat strike-on   "--fstrikethrough" '~~x~~\n'                   '<p><del>x</del></p>'
kat strike-off  ""                 '~~x~~\n'                   '<p>~~x~~</p>'
kat entity      ""                 '&copy; &amp;\n'            '<p>© &amp;</p>'

# Upstream suites. Mirrors scripts/run-tests.py but one runner process per file so counts can be parsed.
cd "$SRC/test"

out="$(python3 prog-tests.py "$PROG" 2>&1)"; rc=$?
n="$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]*\) tests\? in.*/\1/p' | tail -1)"
if [ "$rc" -eq 0 ] && [ -n "$n" ] && [ "$n" -gt 0 ]; then passed=$((passed+n)); else
  failed=$((failed+1)); echo "prog-tests.py failed (rc=$rc)" >&2; printf '%s\n' "$out" | tail -20 >&2; fi

for spec in *.txt; do
  out="$(python3 run-testsuite.py -s "$spec" -p "$PROG" 2>&1)"; rc=$?
  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ errored, [0-9]+ skipped$' | tail -1)"
  if [ -z "$line" ]; then
    failed=$((failed+1)); echo "run-testsuite.py $spec: no summary (rc=$rc)" >&2; printf '%s\n' "$out" | tail -20 >&2; continue
  fi
  p="$(echo "$line" | awk '{print $1}')"; f="$(echo "$line" | awk '{print $3}')"; e="$(echo "$line" | awk '{print $5}')"
  passed=$((passed+p)); failed=$((failed+f+e))
  [ $((f+e)) -eq 0 ] || { echo "spec $spec: $line" >&2; printf '%s\n' "$out" | head -40 >&2; }
done

out="$(python3 pathological-tests.py -p "$PROG" 2>&1)"; rc=$?
line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ errored$' | tail -1)"
if [ -z "$line" ]; then
  failed=$((failed+1)); echo "pathological-tests.py: no summary (rc=$rc)" >&2; printf '%s\n' "$out" | tail -20 >&2
else
  p="$(echo "$line" | awk '{print $1}')"; f="$(echo "$line" | awk '{print $3}')"; e="$(echo "$line" | awk '{print $5}')"
  passed=$((passed+p)); failed=$((failed+f+e))
  [ $((f+e)) -eq 0 ] || { echo "pathological: $line" >&2; printf '%s\n' "$out" | tail -30 >&2; }
fi

emit_ctrf md4c-testsuite "$passed" "$failed" 0
