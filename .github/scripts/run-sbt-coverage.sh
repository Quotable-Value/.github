#!/usr/bin/env bash
set -euo pipefail

# Run the caller-provided SBT coverage command with CI-friendly defaults.
#
# The reusable workflow owns the timeout so a stuck dependency update or test
# suite cannot leave the CodeBuild-backed GitHub Actions job running forever.
# The coverage command itself still decides pass/fail for tests and Jacoco
# thresholds; this wrapper only adds logging and timeout handling.

require_config() {
  : "${COVERAGE_COMMAND:?COVERAGE_COMMAND is required}"
  : "${COVERAGE_TIMEOUT_MINUTES:?COVERAGE_TIMEOUT_MINUTES is required}"
}

validate_timeout_minutes() {
  if ! [[ "$COVERAGE_TIMEOUT_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "COVERAGE_TIMEOUT_MINUTES must be a positive integer: $COVERAGE_TIMEOUT_MINUTES" >&2
    exit 2
  fi
}

print_run_context() {
  echo "Running SBT coverage command with ${COVERAGE_TIMEOUT_MINUTES} minute timeout."
  echo "Command: $COVERAGE_COMMAND"
}

run_command_with_timeout() {
  local status

  set +e
  timeout --kill-after=1m "${COVERAGE_TIMEOUT_MINUTES}m" bash -lc "$COVERAGE_COMMAND"
  status=$?
  set -e

  if [ "$status" -eq 124 ]; then
    echo "SBT coverage timed out after ${COVERAGE_TIMEOUT_MINUTES} minutes." >&2
  elif [ "$status" -eq 137 ]; then
    echo "SBT coverage was killed after exceeding the timeout grace period." >&2
  fi

  return "$status"
}

main() {
  require_config
  validate_timeout_minutes
  print_run_context
  run_command_with_timeout
}

main "$@"
