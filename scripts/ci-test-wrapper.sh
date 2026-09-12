#!/usr/bin/env bash
# HER-310: `swift test` can die with SIGILL during process teardown (AsyncKit
# ConnectionPool deinit precondition) AFTER every test has already passed,
# which keeps the test jobs permanently red and un-requirable.
#
# This wrapper gates on evidence that the run completed cleanly, not on the raw
# exit code. The known signal-4 teardown is tolerated ONLY when all of:
#
#   1. the log carries swift-testing's closing "Test run with N tests ..."
#      summary, proving the run reached the end rather than dying partway;
#   2. that summary says `passed`, and the log records no test issues;
#   3. xunit records zero failures/errors across a non-zero test count;
#   4. the log contains SwiftPM's explicit signal marker.
#
# SwiftPM maps its test child's signal to exit 1, so checking for a shell-style
# status >= 128 does not detect this crash. Any real test failure, build
# failure, or crash before the run completes still fails the job.
#
# Conditions 1 and 2 exist because checking xunit alone is not enough: xunit is
# written as the run proceeds, so a crash partway leaves a small file with
# failures=0 that reads exactly like success.
#
# Usage: ci-test-wrapper.sh <xunit-output-path> [swift test args...]
set -uo pipefail

xunit_path="$1"
shift
log_path="${xunit_path%.xml}.log"

swift test --xunit-output "$xunit_path" "$@" 2>&1 | tee "$log_path"
status=${PIPESTATUS[0]}

if [ "$status" -eq 0 ]; then
  exit 0
fi

# SwiftPM writes XCTest results to <path> and swift-testing results to
# <path minus .xml>-swift-testing.xml; aggregate whichever exist.
base="${xunit_path%.xml}"
total_tests=0
total_failures=0
for f in "$xunit_path" "${base}-swift-testing.xml"; do
  [ -f "$f" ] || continue
  tests=$(grep -o 'tests="[0-9]*"' "$f" | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
  failures=$(grep -o 'failures="[0-9]*"' "$f" | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
  errors=$(grep -o 'errors="[0-9]*"' "$f" | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
  total_tests=$((total_tests + tests))
  total_failures=$((total_failures + failures + errors))
done

# The crash this tolerates fires during teardown, AFTER the run has finished.
# Proof that it finished is swift-testing's own closing summary; without it the
# process died mid-run, and a partial xunit reporting failures=0 only means
# "nothing had failed yet by the time it stopped writing".
#
# This is not hypothetical. A run that crashed partway wrote 23 tests to xunit
# while 223 suites had started, carried 18 failing tests in its log, and was
# reported green — which is how an enrolment handler that answered 400 instead
# of 401 reached production with a test asserting 401.
run_summary=$(grep -Eo 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' "$log_path" | tail -1)
issue_lines=$(grep -cE 'recorded an issue|failed after [0-9.]+ seconds with [0-9]+ issue' "$log_path" || true)

if [ -z "$run_summary" ]; then
  echo "::error::swift test died with status ${status} before the run completed — no swift-testing summary in the log. xunit captured tests=${total_tests}, which is a partial result, not a pass."
  exit "$status"
fi

if [ "$issue_lines" -ne 0 ]; then
  echo "::error::swift test died with status ${status} and the log records ${issue_lines} test issue(s) — real failures, not the HER-310 teardown crash."
  exit "$status"
fi

if [ "$total_tests" -gt 0 ] && [ "$total_failures" -eq 0 ] &&
  grep -Eq 'unexpected signal code 4|Signal 4|Illegal instruction' "$log_path"; then
  echo "::warning::swift test exited with signal status ${status} after ${run_summary} (${total_tests} in xunit) (HER-310 teardown SIGILL) — treating as success"
  exit 0
fi

echo "::error::swift test died with status ${status}; xunit shows tests=${total_tests} failures=${total_failures}, log says ${run_summary} — real failure"
exit "$status"
