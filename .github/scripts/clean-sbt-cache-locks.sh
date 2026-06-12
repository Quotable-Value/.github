#!/usr/bin/env bash
set -euo pipefail

# Remove lock files that should not be restored into the next GitHub Actions run.
#
# The reusable workflow caches dependency artifacts between CodeBuild-backed
# runners. It should not cache lock files, because a fresh runner can interpret
# a restored lock as work still owned by another SBT/Ivy/Coursier process.
# This script is intentionally narrow: it removes lock files only and leaves
# dependency metadata in place so cache restores still speed up later runs.

existing_directories=()

add_directory_if_present() {
  local directory="$1"

  if [ -d "$directory" ]; then
    existing_directories+=("$directory")
  fi
}

remove_file_if_present() {
  local file="$1"

  if [ -f "$file" ]; then
    rm -fv "$file"
  fi
}

remove_locks_under_directory() {
  local directory="$1"

  find "$directory" -type f -name "*.lock" -print -delete 2>/dev/null || true
}

clean_known_sbt_locks() {
  remove_file_if_present "$HOME/.ivy2/.sbt.ivy.lock"
}

collect_cache_directories() {
  add_directory_if_present "$HOME/.cache/coursier"
  add_directory_if_present "$HOME/.ivy2/cache"
  add_directory_if_present "$HOME/.sbt"
}

clean_lock_files_from_cache_directories() {
  local directory

  for directory in "${existing_directories[@]}"; do
    remove_locks_under_directory "$directory"
  done
}

main() {
  clean_known_sbt_locks
  collect_cache_directories
  clean_lock_files_from_cache_directories
}

main "$@"
