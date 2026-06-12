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
  COVERAGE_MAX_ATTEMPTS="${COVERAGE_MAX_ATTEMPTS:-2}"
}

validate_timeout_minutes() {
  if ! [[ "$COVERAGE_TIMEOUT_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "COVERAGE_TIMEOUT_MINUTES must be a positive integer: $COVERAGE_TIMEOUT_MINUTES" >&2
    exit 2
  fi
}

validate_max_attempts() {
  if ! [[ "$COVERAGE_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
    echo "COVERAGE_MAX_ATTEMPTS must be a positive integer: $COVERAGE_MAX_ATTEMPTS" >&2
    exit 2
  fi
}

print_run_context() {
  echo "Running SBT coverage command with ${COVERAGE_TIMEOUT_MINUTES} minute timeout."
  echo "Maximum attempts: $COVERAGE_MAX_ATTEMPTS"
  echo "Command: $COVERAGE_COMMAND"
}

is_retryable_dependency_failure() {
  local log_file=$1

  grep -Eiq \
    'download failed|ResolveException|stream was reset|Connection reset|SocketTimeoutException|Could not transfer artifact|Server access Error|Remote host terminated the handshake' \
    "$log_file"
}

print_timeout_failure() {
  local status=$1

  if [ "$status" -eq 124 ]; then
    echo "SBT coverage timed out after ${COVERAGE_TIMEOUT_MINUTES} minutes." >&2
  elif [ "$status" -eq 137 ]; then
    echo "SBT coverage was killed after exceeding the timeout grace period." >&2
  fi
}

run_command_with_timeout() {
  local status
  local attempt=1
  local log_file

  while [ "$attempt" -le "$COVERAGE_MAX_ATTEMPTS" ]; do
    log_file=$(mktemp)
    echo "SBT coverage attempt ${attempt}/${COVERAGE_MAX_ATTEMPTS}"

    set +e
    timeout --kill-after=1m "${COVERAGE_TIMEOUT_MINUTES}m" bash -lc "$COVERAGE_COMMAND" 2>&1 | tee "$log_file"
    status=${PIPESTATUS[0]}
    set -e

    print_timeout_failure "$status"

    if [ "$status" -eq 0 ]; then
      rm -f "$log_file"
      return 0
    fi

    if [ "$attempt" -ge "$COVERAGE_MAX_ATTEMPTS" ] || ! is_retryable_dependency_failure "$log_file"; then
      rm -f "$log_file"
      return "$status"
    fi

    rm -f "$log_file"
    echo "SBT dependency download failed; retrying coverage command after $((attempt * 15)) seconds." >&2
    sleep "$((attempt * 15))"
    attempt=$((attempt + 1))
  done

  return "$status"
}

main() {
  require_config
  validate_timeout_minutes
  validate_max_attempts
  print_run_context
  run_command_with_timeout
}

main "$@"
