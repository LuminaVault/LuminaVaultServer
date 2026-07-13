#!/usr/bin/env bash
# HER-310: `swift test` can die with SIGILL during process teardown (AsyncKit
# ConnectionPool deinit precondition) AFTER every test has already passed,
# which keeps the test jobs permanently red and un-requirable.
#
# This wrapper gates on the xunit result file instead of the raw exit code:
# the known signal-4 teardown is tolerated ONLY when the test log contains
# SwiftPM's explicit signal marker and xunit records zero failures/errors
# across a non-zero test count. SwiftPM maps its test child's signal to exit 1,
# so checking for a shell-style status >= 128 does not detect this crash.
# Any real test failure, build failure, or crash before results are written
# still fails the job.
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

if [ "$total_tests" -gt 0 ] && [ "$total_failures" -eq 0 ] &&
  grep -Eq 'unexpected signal code 4|Signal 4|Illegal instruction' "$log_path"; then
  echo "::warning::swift test exited with signal status ${status} after all ${total_tests} tests passed (HER-310 teardown SIGILL) — treating as success"
  exit 0
fi

echo "::error::swift test died with status ${status}; xunit shows tests=${total_tests} failures=${total_failures} — real failure"
exit "$status"
