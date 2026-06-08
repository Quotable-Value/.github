#!/usr/bin/env bash
set -euo pipefail

: "${COMMENT_FILE:?COMMENT_FILE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "comment_file=$COMMENT_FILE" >> "$GITHUB_OUTPUT"

python3 "$script_dir/write-sbt-jacoco-summary.py"

if [ -s "$COMMENT_FILE" ]; then
  cat "$COMMENT_FILE" >> "$GITHUB_STEP_SUMMARY"
  echo "has_structured_summary=true" >> "$GITHUB_OUTPUT"
else
  echo "No Jacoco XML report was found." >> "$GITHUB_STEP_SUMMARY"
  echo "has_structured_summary=false" >> "$GITHUB_OUTPUT"
fi
